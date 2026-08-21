import AmplitudeSwift
import Foundation

private extension DelayedState {
    var isEmpty: Bool { entries.isEmpty && pendingInstantEvents.isEmpty }
}

/// Keeps one snapshot per `insert_id` alive on the server until it is finalized.
///
/// State is keyed by delay id, one key per server row. All of it lives behind a serial queue and
/// is persisted before the network is touched, so a kill mid-flight leaves something the next
/// launch can flush.
final class DelayedEventPipeline {
    // Browser parity (`EVENTS_SIZE_LIMIT = 4 * 10_000`). Sized for `pendingInstantEvents` piling
    // up during an outage — roughly thirty offline resumes — not for snapshot count.
    private static let maxStateBytes = 40_000

    /// Fixed for this launch; only its *persisted* record goes away, when the key drains.
    let currentDelayId = UUID().uuidString

    private let configuration: Configuration
    private let store: DelayedSnapshotStore
    private let httpClient: DelayedEventsUploading
    private let logger: (any Logger)?
    private let defaultTimeoutMs: Int64
    private let queue = DispatchQueue(label: "delayedEvents.amplitude.com")
    private var timer: PulseTimer?
    private var current = DelayedState(entries: [:], pendingInstantEvents: [])
    /// Delay ids from earlier launches whose server rows may still be live.
    private var carriedOver: [String: DelayedState]
    private var revisionCounter = 0

    init(configuration: Configuration,
         store: DelayedSnapshotStore,
         httpClient: DelayedEventsUploading,
         pulseInterval: TimeInterval = 60,
         defaultTimeoutMs: Int64 = 3_600_000) {
        self.configuration = configuration
        self.store = store
        self.httpClient = httpClient
        self.logger = configuration.loggerProvider
        self.defaultTimeoutMs = defaultTimeoutMs
        self.carriedOver = store.load()?.states ?? [:]
        timer = PulseTimer(interval: pulseInterval, queue: queue) { [weak self] in
            self?.pulse()
        }
        updateTimer()
    }

    func track(_ event: BaseEvent, delay: DelayConfig) {
        queue.async { [weak self] in
            self?.performTrack(event, delay: delay)
        }
    }

    /// Drains what previous launches left behind, each under its own delay id.
    func flushPersistedEntries() {
        queue.async { [weak self] in
            guard let self else { return }
            self.flushCarriedOverKeys()
        }
    }

    // MARK: - queue-confined state

    private func performTrack(_ event: BaseEvent, delay: DelayConfig) {
        guard let insertId = event.insertId else {
            logger?.error(message: "Delayed event dropped: no insert_id on \(event.eventType)")
            return
        }

        let previous = current
        let shouldPulseNow: Bool
        switch delay {
        case .delayed(let timeout):
            // A non-positive TTL is the row's delete signal, never what an upsert means.
            let timeoutMs = timeout > 0 ? Int64(timeout * 1000) : defaultTimeoutMs
            let isFirstSighting = current.entries[insertId] == nil
            revisionCounter += 1
            current.entries[insertId] = DelayedEntry(event: event,
                                                     timeoutMs: timeoutMs,
                                                     revision: revisionCounter)
            // Later refreshes ride the timer; only a new snapshot needs the row created now.
            shouldPulseNow = isFirstSighting
        case .instant:
            current.entries.removeValue(forKey: insertId)
            current.pendingInstantEvents.append(event)
            shouldPulseNow = true
        }

        guard withinSizeLimit() else {
            current = previous
            logger?.error(message: "Delayed event dropped: state would exceed "
                + "\(Self.maxStateBytes) bytes (insert_id=\(insertId))")
            return
        }

        persist()
        updateTimer()
        if shouldPulseNow {
            pulse()
        }
    }

    private func pulse() {
        if !current.isEmpty {
            pulseCurrentKey()
        }
        flushCarriedOverKeys()
    }

    private func pulseCurrentKey() {
        let live = current.entries.sorted { $0.key < $1.key }
        // Longest TTL wins so a short-lived snapshot cannot expire a longer-lived one early.
        // With none left, `timeout: 0` ingests the instants and deletes the row.
        let timeoutMs = live.map(\.value.timeoutMs).max() ?? 0
        send(delayId: currentDelayId,
             events: live.map(\.value.event),
             timeoutMs: timeoutMs,
             sentRevisions: live.reduce(into: [:]) { $0[$1.key] = $1.value.revision })
    }

    private func flushCarriedOverKeys() {
        var agedOut = false
        var rehomed: [BaseEvent] = []
        for delayId in carriedOver.keys.sorted() {
            guard var state = carriedOver[delayId], !state.isEmpty else { continue }

            if hasOutlivedItsTimeout(state) {
                // The row already TTL-expired and ingested, so resending its snapshots would
                // only duplicate. Instants ingest from a request body alone, so these were
                // never delivered and move to the current key instead of dying with the row.
                logger?.debug(message: "Delayed events key \(delayId) aged out: dropping "
                    + "\(state.entries.count) snapshot(s), keeping "
                    + "\(state.pendingInstantEvents.count) instant event(s)")
                rehomed += state.pendingInstantEvents
                carriedOver.removeValue(forKey: delayId)
                agedOut = true
                continue
            }

            // Entries become instant events so one `timeout: 0` request ingests the lot and
            // deletes the row.
            state.pendingInstantEvents += state.entries.sorted { $0.key < $1.key }.map(\.value.event)
            state.entries = [:]
            carriedOver[delayId] = state
            persist()
            send(delayId: delayId, events: [], timeoutMs: 0, sentRevisions: [:])
        }
        guard agedOut else { return }
        // Re-homed instants predate anything queued on the current key, so they go first.
        current.pendingInstantEvents.insert(contentsOf: rehomed, at: 0)
        persist()
        updateTimer()
    }

    private func send(delayId: String,
                      events: [BaseEvent],
                      timeoutMs: Int64,
                      sentRevisions: [String: Int]) {
        // Claimed, not copied: instants leave the state before the request goes out so two
        // overlapping requests can never both carry them. A failure puts them back up front.
        var instantEvents: [BaseEvent] = []
        mutate(delayId) {
            instantEvents = $0.pendingInstantEvents
            $0.pendingInstantEvents = []
        }
        persist()

        let body = DelayedRequestBody(apiKey: configuration.apiKey,
                                      id: delayId,
                                      timeout: timeoutMs,
                                      events: events,
                                      instantEvents: instantEvents.isEmpty ? nil : instantEvents)

        httpClient.upload(body) { [weak self] result in
            self?.queue.async {
                self?.handle(result,
                             delayId: delayId,
                             timeoutMs: timeoutMs,
                             sentRevisions: sentRevisions,
                             instantEvents: instantEvents)
            }
        }
    }

    private func handle(_ result: Result<DelayedResponseBody, Error>,
                        delayId: String,
                        timeoutMs: Int64,
                        sentRevisions: [String: Int],
                        instantEvents: [BaseEvent]) {
        switch result {
        case .success:
            // Only `timeout: 0` clears anything server-side. A live-TTL snapshot must be resent
            // every pulse, because the upsert replaces the row wholesale rather than merging.
            if timeoutMs == 0 {
                mutate(delayId) { removeSentEntries(&$0, sentRevisions) }
            }
        case .failure(let error):
            if case DelayedEventsError.httpError(let code, _) = error, code == 400 || code == 413 {
                // Never going to be accepted; retrying forever would block everything behind it.
                logger?.error(message: "Delayed events request rejected with HTTP \(code), "
                    + "dropping \(sentRevisions.count) entry(ies) and "
                    + "\(instantEvents.count) instant event(s)")
                mutate(delayId) { removeSentEntries(&$0, sentRevisions) }
            } else {
                mutate(delayId) { $0.pendingInstantEvents.insert(contentsOf: instantEvents, at: 0) }
            }
        }
        persist()
        updateTimer()
    }

    /// Removes only what this request sent, at the revision it sent — a snapshot refreshed
    /// mid-flight carries a newer revision and survives.
    private func removeSentEntries(_ state: inout DelayedState, _ sentRevisions: [String: Int]) {
        for (insertId, revision) in sentRevisions where state.entries[insertId]?.revision == revision {
            state.entries.removeValue(forKey: insertId)
        }
    }

    private func mutate(_ delayId: String, _ body: (inout DelayedState) -> Void) {
        if delayId == currentDelayId {
            body(&current)
        } else {
            var state = carriedOver[delayId] ?? DelayedState(entries: [:], pendingInstantEvents: [])
            body(&state)
            carriedOver[delayId] = state
        }
    }

    private func hasOutlivedItsTimeout(_ state: DelayedState) -> Bool {
        let newest = state.entries.values.max { ($0.event.timestamp ?? 0) < ($1.event.timestamp ?? 0) }
        guard let newest, let timestamp = newest.event.timestamp else { return false }
        return Int64(Date().timeIntervalSince1970 * 1000) - timestamp > newest.timeoutMs
    }

    private func snapshot() -> DelayedStore {
        var states = carriedOver.filter { !$0.value.isEmpty }
        if !current.isEmpty {
            states[currentDelayId] = current
        }
        return DelayedStore(states: states)
    }

    /// A drained key leaves the file entirely; `currentDelayId` survives in memory regardless.
    private func persist() {
        carriedOver = carriedOver.filter { !$0.value.isEmpty }
        store.save(snapshot())
    }

    /// Unencodable counts as over the limit — it could not be persisted either way.
    private func withinSizeLimit() -> Bool {
        guard let data = try? JSONEncoder().encode(snapshot()) else { return false }
        return data.count <= Self.maxStateBytes
    }

    private func updateTimer() {
        if current.isEmpty && carriedOver.isEmpty {
            timer?.suspend()
        } else {
            timer?.resume()
        }
    }
}
