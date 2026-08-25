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

    // All mutable state is confined to this serial queue; HTTP completions hop back onto it.
    private let queue = DispatchQueue(label: "com.amplitude.delayedEventTracker")
    private var delayId = UUID().uuidString
    private var entries = OrderedEntries()

    // Only one request is ever in flight. Every body fully replaces the same server row, so
    // overlapping requests can land out of order and restore stale state — and one still in
    // flight when `flush()` runs could recreate the row the flush had the server delete.
    // While a request is in flight the tracker only records what the next one must do;
    // its completion issues it. There is never a backlog: the newest state supersedes.
    private var needsSend = false      // a request is owed: entries changed, or the pulse came due
    private var needsFlush = false     // `flush()` asked for ingestion: next request carries `timeout: 0`
    private var requestInFlight = false
    private var timer: PulseTimer!

    init(configuration: Configuration,
         httpClient: DelayedEventsUploading,
         pulseInterval: TimeInterval = DelayedEventsDefaults.pulseInterval,
         delayTimeoutMs: Int64 = DelayedEventsDefaults.delayTimeoutMs) {
        self.configuration = configuration
        self.httpClient = httpClient
        self.logger = configuration.loggerProvider
        self.delayTimeoutMs = delayTimeoutMs
        // The handler runs on `queue` — `PulseTimer` schedules its source there.
        timer = PulseTimer(interval: pulseInterval, queue: queue) { [weak self] in
            self?.setNeedsSend()  // re-send the live set so the server keeps pushing its TTL out
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
            // re-upsert the row the server is deleting.
            self.timer.suspend()
            self.needsFlush = true
            self.sendPendingRequest()
        }
    }

    /// Drops local state without sending; the server ingests the abandoned row at TTL expiry.
    func discard() {
        queue.async {
            self.entries.removeAll()
            self.delayId = UUID().uuidString
            self.needsSend = false
            self.needsFlush = false
            self.timer.suspend()
        }
    }

    private func add(_ event: BaseEvent, kind: Entry.Kind) {
        guard let insertId = insertId(of: event) else { return }
        queue.async {
            if let entry = self.admissibleEntry(event, kind: kind, insertId: insertId) {
                self.entries.upsert(entry, for: insertId)
                self.timer.resume()
                self.setNeedsSend()
            } else {
                // A rejected add also evicts any queued entry under the same id.
                self.entries.remove(insertId)
                self.suspendPulseIfIdle()
            }
        }
    }

    /// Records that a request is owed, and sends it on the next queue hop — so several tracks
    /// landing in the same tick share one request instead of each issuing their own.
    private func setNeedsSend() {
        guard !needsSend else { return }  // a hop is already pending, and will see this change too
        needsSend = true
        queue.async { self.sendPendingRequest() }
    }

    /// The one place a request is issued. Sends whatever the tracker currently owes, unless
    /// a request is already in flight — in which case that request's completion calls back
    /// here and sends it then.
    private func sendPendingRequest() {
        guard needsSend || needsFlush, !entries.isEmpty else { return }  // nothing to say
        guard !requestInFlight else { return }  // say it when the wire is free; the completion calls back
        // A flush outranks a plain send: it is the request that has the server ingest the row
        // and delete it, so letting a plain send go in its place would drop the ingestion.
        let flushing = needsFlush
        needsSend = false
        needsFlush = false
        send(flushing: flushing)
    }

    private func send(flushing: Bool) {
        // Built now rather than when the send was first owed, so a request deferred behind an
        // in-flight one carries current state instead of a stale snapshot.
        let (body, settledIds) = makeRequestBody(flushing: flushing)
        requestInFlight = true
        // TODO: retry failed uploads with backoff.
        // TODO: persist entries so in-flight events survive process death.
        // TODO: buffer changes and send on a size or time threshold, rather than a request per
        //       change with the pulse as the only other trigger. Sending as soon as state changes
        //       is deliberate for now — it keeps the server-side integration simple to land and
        //       verify; persistence would double as that buffer.
        httpClient.upload(body) { [weak self] result in
            guard let self else { return }
            if case .failure(let error) = result {
                self.logger?.error(message: "DelayedEventTracker: delayed events request failed: \(error)")
            }
            self.queue.async {
                self.requestInFlight = false
                // Settled entries leave the set whether the request succeeded or not.
                settledIds.forEach { self.entries.remove($0) }
                self.suspendPulseIfIdle()
                self.sendPendingRequest()  // anything that accumulated while this was in flight
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
