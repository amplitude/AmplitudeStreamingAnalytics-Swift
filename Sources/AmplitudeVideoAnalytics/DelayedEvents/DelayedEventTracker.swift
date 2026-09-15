import AmplitudeSwift
import Foundation

/// Keeps delayed events alive on the ingestion server until they are finalized.
/// Every request is a full-replace upsert of one server row, so each send carries the complete
/// live set. Do not mutate a tracked event; refresh it by tracking a fresh one with the same id.
final class DelayedEventTracker {
    private let amplitudeConfiguration: Configuration
    private let configuration: DelayedEventsConfiguration
    private let httpClient: DelayedEventsUploading
    private let logger: (any Logger)?

    // All mutable state is confined to this serial queue; HTTP completions hop back onto it.
    private let queue = DispatchQueue(label: "com.amplitude.delayedEventTracker")
    private var delayId = UUID().uuidString
    private var entries: OrderedEntries

    // One request at a time: bodies fully replace the same row, so overlapping ones can land out of order.
    private var needsSend = false
    private var needsFlush = false
    private var requestInFlight = false
    private var keepAlives: [BackgroundTask] = []
    private var timer: PulseTimer!

    init(amplitudeConfiguration: Configuration,
         configuration: DelayedEventsConfiguration,
         httpClient: DelayedEventsUploading) {
        self.amplitudeConfiguration = amplitudeConfiguration
        self.configuration = configuration
        self.httpClient = httpClient
        self.logger = amplitudeConfiguration.loggerProvider
        entries = OrderedEntries(eventsSizeLimit: configuration.eventsSizeLimit)
        timer = PulseTimer(interval: configuration.pulseInterval, queue: queue) { [weak self] in
            self?.setNeedsSend()
        }
    }

    /// `sending` is the caller's decision, not the event's: the tracker admits the event either way
    /// and only asks for a request when told. `forcePulse` is read by whoever owns the batch.
    func track(_ event: DelayedEvent, sending: Bool) {
        guard let insertId = event.insertId, !insertId.isEmpty else {
            logger?.error(message: "DelayedEventTracker: insert_id is required on tracked events")
            return
        }
        queue.async {
            // An instant is never a refresh: sending it finalizes the live entry.
            if event.kind == .delayed, self.entries[insertId] != nil {
                self.update(event, insertId: insertId, sending: sending)
            } else {
                self.add(event, insertId: insertId, sending: sending)
            }
        }
    }

    private func update(_ event: DelayedEvent, insertId: String, sending: Bool) {
        // A rejected refresh leaves the live entry standing; no send, it rides the next pulse.
        guard let entry = admissibleEntry(event, insertId: insertId) else { return }
        entries.upsert(entry, for: insertId)
        if sending {
            setNeedsSend()
        }
    }

    /// Sends the live set without waiting for the pulse interval.
    func pulseNow() {
        queue.async { self.setNeedsSend() }
    }

    /// Parks an assertion so whichever request goes next carries it, without asking for that request.
    /// Backgrounding claims one before the send it wants has been decided on.
    func keepAwake(_ keepAlive: BackgroundTask) {
        queue.async { self.keepAlives.append(keepAlive) }
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

    private func add(_ event: DelayedEvent, insertId: String, sending: Bool) {
        if let entry = admissibleEntry(event, insertId: insertId) {
            entries.upsert(entry, for: insertId)
            timer.resume()
            if sending {
                setNeedsSend()
            }
        } else {
            suspendPulseIfIdle()
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
        // Nothing will be sent, so nothing needs the app awake.
        keepAlives = []
        timer.suspend()
    }

    private func send(flushing: Bool) {
        let (body, settledIds) = makeRequestBody(flushing: flushing)
        requestInFlight = true
        // TODO: retry failed uploads with backoff.
        // TODO: persist entries so in-flight events survive process death.
        // TODO: buffer changes and send on a size or time threshold; sending per change is a
        //       staging choice while the server-side integration is being landed.
        let keepAlives = self.keepAlives
        self.keepAlives = []
        // Captured, not called: they end when this closure is released after the request settles.
        httpClient.upload(body) { [weak self, keepAlives] result in
            _ = keepAlives
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
        var delayedEvents: [DelayedEvent] = []
        var instantEvents: [DelayedEvent] = []
        var settledIds: [String] = []
        for (insertId, entry) in entries.inOrder {
            switch entry.kind {
            case .delayed: delayedEvents.append(entry.event)
            case .instant: instantEvents.append(entry.event)
            }
            if flushing || entry.kind == .instant { settledIds.append(insertId) }
        }
        // The TTL keeps the row alive; 0 has the server ingest and delete it.
        let ttlMs: Int64 = (flushing || delayedEvents.isEmpty) ? 0 : configuration.ttlMs
        let body = DelayedRequestBody(apiKey: amplitudeConfiguration.apiKey,
                                      id: delayId,
                                      ttlMs: ttlMs,
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

    private func admissibleEntry(_ event: DelayedEvent, insertId: String) -> Entry? {
        switch entries.admissibleEntry(event, for: insertId) {
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
}
