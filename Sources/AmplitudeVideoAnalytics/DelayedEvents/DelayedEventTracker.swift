import AmplitudeSwift
import Foundation

/// Keeps delayed events alive on the ingestion server until they are finalized.
/// Every request is a full-replace upsert of one server row, so each send carries the
/// complete live set. A tracked event must not be mutated after being handed over;
/// to refresh a snapshot, pass a fresh `BaseEvent` with the same `insertId` to `update(_:)`.
final class DelayedEventTracker {
    private let configuration: Configuration
    private let httpClient: DelayedEventsUploading
    private let logger: (any Logger)?
    private let delayTimeoutMs: Int64

    /// A send that is owed but not yet on the wire. At most one can be outstanding:
    /// every request fully replaces the server row, so a deferred send is a debt, not a queue.
    private enum Pending {
        case send
        case flush
    }

    // All mutable state is confined to this serial queue; HTTP completions hop back onto it.
    private let queue = DispatchQueue(label: "com.amplitude.delayedEventTracker")
    private var delayId = UUID().uuidString
    private var entries = OrderedEntries()
    private var pending: Pending?
    private var uploading = false
    private var timer: PulseTimer!

    init(configuration: Configuration,
         httpClient: DelayedEventsUploading,
         pulseInterval: TimeInterval = DelayedEventsDefaults.pulseInterval,
         delayTimeoutMs: Int64 = DelayedEventsDefaults.delayTimeoutMs) {
        self.configuration = configuration
        self.httpClient = httpClient
        self.logger = configuration.loggerProvider
        self.delayTimeoutMs = delayTimeoutMs
        timer = PulseTimer(interval: pulseInterval, queue: queue) { [weak self] in
            self?.sendNow(.send)
        }
    }

    func track(_ event: BaseEvent) {
        add(event, kind: .instant)
    }

    func trackDelayed(_ event: BaseEvent) {
        add(event, kind: .delayed)
    }

    func update(_ event: BaseEvent) {
        guard let insertId = insertId(of: event) else { return }
        queue.async {
            guard self.entries[insertId] != nil,
                  let entry = self.admissibleEntry(event, kind: .delayed, insertId: insertId) else { return }
            self.entries.upsert(entry, for: insertId)
            // No send: updates arrive far faster than the pulse and ride the next one.
        }
    }

    func flush() {
        queue.async {
            // Entries stay local until the request settles; suspend the pulse so it cannot
            // re-upsert the row the server is deleting. A queued plain send is upgraded to
            // this flush rather than sent alongside it.
            self.timer.suspend()
            self.sendNow(.flush)
        }
    }

    /// Drops local state without sending; the server ingests the abandoned row at TTL expiry.
    func discard() {
        queue.async {
            self.entries.removeAll()
            self.delayId = UUID().uuidString
            self.pending = nil
            self.timer.suspend()
        }
    }

    private func add(_ event: BaseEvent, kind: Entry.Kind) {
        guard let insertId = insertId(of: event) else { return }
        queue.async {
            if let entry = self.admissibleEntry(event, kind: kind, insertId: insertId) {
                self.entries.upsert(entry, for: insertId)
                self.timer.resume()
                self.scheduleSend()
            } else {
                // A rejected add also evicts any queued entry under the same id.
                self.entries.remove(insertId)
                self.suspendPulseIfIdle()
            }
        }
    }

    /// Records a send owed by an add. Adds landing before the hop runs share the one request.
    private func scheduleSend() {
        guard pending == nil else { return }  // an owed flush is never downgraded to a plain send
        pending = .send
        queue.async { self.drain() }
    }

    /// Records a send owed by the pulse or by `flush()`, and pays it at once if the gate is open.
    private func sendNow(_ kind: Pending) {
        if kind == .flush || pending == nil { pending = kind }
        drain()
    }

    /// Issues the owed send, unless a request is already in flight — every body fully replaces
    /// the same server row, so overlapping requests can land out of order and restore stale
    /// state. The debt is paid instead by the in-flight request's completion.
    private func drain() {
        guard !uploading, let kind = pending else { return }
        pending = nil
        send(flushing: kind == .flush)
    }

    private func send(flushing: Bool) {
        guard !entries.isEmpty else { return }
        // Built here rather than when the send was owed, so a deferred request carries
        // current state instead of the snapshot as of the moment it was requested.
        let (body, settledIds) = makeRequestBody(flushing: flushing)
        uploading = true
        // TODO: retry failed uploads with backoff.
        // TODO: persist entries so in-flight events survive process death.
        httpClient.upload(body) { [weak self] result in
            guard let self else { return }
            if case .failure(let error) = result {
                self.logger?.error(message: "DelayedEventTracker: delayed events request failed: \(error)")
            }
            self.queue.async {
                self.uploading = false
                // Settled entries leave the set whether the request succeeded or not.
                settledIds.forEach { self.entries.remove($0) }
                self.suspendPulseIfIdle()
                self.drain()
            }
        }
    }

    private func makeRequestBody(flushing: Bool) -> (body: DelayedRequestBody, settledIds: [String]) {
        var delayedEvents: [BaseEvent] = []
        var instantEvents: [BaseEvent] = []
        var settledIds: [String] = []
        for (insertId, entry) in entries.inOrder {
            switch entry.kind {
            case .delayed: delayedEvents.append(entry.event)
            case .instant: instantEvents.append(entry.event)
            }
            if flushing || entry.kind == .instant { settledIds.append(insertId) }
        }
        // `delayTimeoutMs` keeps the row alive; 0 has the server ingest and delete it.
        let timeout: Int64 = (flushing || delayedEvents.isEmpty) ? 0 : delayTimeoutMs
        let body = DelayedRequestBody(apiKey: configuration.apiKey,
                                      id: delayId,
                                      timeout: timeout,
                                      events: delayedEvents,
                                      instantEvents: instantEvents.isEmpty ? nil : instantEvents)
        return (body, settledIds)
    }

    /// Never resumes: `flush()` suspends the pulse while its entries are still in flight.
    private func suspendPulseIfIdle() {
        if entries.isEmpty {
            timer.suspend()
        }
    }

    private func admissibleEntry(_ event: BaseEvent, kind: Entry.Kind, insertId: String) -> Entry? {
        switch entries.admissibleEntry(event, kind: kind, for: insertId) {
        case .success(let entry):
            return entry
        case .failure(.unencodable):
            logger?.warn(message: "DelayedEventTracker: cannot encode event, rejecting event with id=\(insertId)")
            return nil
        case .failure(.wouldExceedSizeLimit):
            logger?.warn(message: "DelayedEventTracker: events size limit reached, rejecting event with id=\(insertId)")
            return nil
        }
    }

    private func insertId(of event: BaseEvent) -> String? {
        guard let insertId = event.insertId, !insertId.isEmpty else {
            logger?.error(message: "DelayedEventTracker: insert_id is required on tracked events")
            return nil
        }
        return insertId
    }
}
