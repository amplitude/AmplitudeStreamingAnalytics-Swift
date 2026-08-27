import AmplitudeSwift
import Foundation

/// Keeps delayed events alive on the ingestion server until they are finalized.
/// Every request is a full-replace upsert of one server row, so each send carries the complete
/// live set. A tracked event must not be mutated after being handed over; refresh via `update(_:)`.
final class DelayedEventTracker {
    private let configuration: Configuration
    private let httpClient: DelayedEventsUploading
    private let logger: (any Logger)?
    private let delayTimeoutMs: Int64

    // All mutable state is confined to this serial queue; HTTP completions hop back onto it.
    private let queue = DispatchQueue(label: "com.amplitude.delayedEventTracker")
    private var delayId = UUID().uuidString
    private var entries = OrderedEntries()

    // One request at a time: bodies fully replace the same row, so overlapping ones can land out of order.
    private var needsSend = false
    private var needsFlush = false
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
        timer = PulseTimer(interval: pulseInterval, queue: queue) { [weak self] in
            self?.setNeedsSend()
        }
    }

    /// Routes on the event's own kind, so callers state intent where they build the event.
    func track(_ event: DelayedEvent) {
        switch event.kind {
        case .instant: add(event, kind: .instant)
        case .delayed: add(event, kind: .delayed)
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
            // The pulse would re-upsert the row this request has the server delete.
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
            self.reset()
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

    /// Deferred by a hop so tracks landing in the same tick share one request.
    private func setNeedsSend() {
        guard !needsSend else { return }
        needsSend = true
        queue.async { self.sendPendingRequest() }
    }

    private func sendPendingRequest() {
        guard !requestInFlight else { return }
        guard !entries.isEmpty else {
            reset()
            return
        }
        guard needsSend || needsFlush else { return }
        // A flush outranks a plain send: only it has the server ingest the row and delete it.
        let flushing = needsFlush
        needsSend = false
        needsFlush = false
        send(flushing: flushing)
    }

    private func reset() {
        needsSend = false
        needsFlush = false
        timer.suspend()
    }

    private func send(flushing: Bool) {
        let (body, settledIds) = makeRequestBody(flushing: flushing)
        requestInFlight = true
        // TODO: retry failed uploads with backoff.
        // TODO: persist entries so in-flight events survive process death.
        // TODO: buffer changes and send on a size or time threshold; sending per change is a
        //       staging choice while the server-side integration is being landed.
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
                self.sendPendingRequest()
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
