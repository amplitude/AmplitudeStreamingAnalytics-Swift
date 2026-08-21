import AmplitudeSwift
import Foundation

/// Keeps one snapshot per `insert_id` alive on the server until it is finalized.
///
/// State is keyed by delay id, one key per server row. All of it lives behind a serial queue and
/// is persisted before the network is touched, so a kill mid-flight leaves something the next
/// launch can flush.
final class DelayedEventPipeline {
    // Browser parity (`EVENTS_SIZE_LIMIT = 4 * 10_000`), sized for `pendingInstantEvents` piling up during an outage — roughly thirty offline resumes — not for snapshot count.
    private static let maxStateBytes = 40_000
    private static let minTimeoutMs: Int64 = 1
    // The servlet's `MAX_TIMEOUT_MS`; anything larger comes back as a 400.
    private static let maxTimeoutMs: Int64 = 86_400_000

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
    private var inFlight: Set<String> = []
    /// Keys whose send was skipped because one was already out; re-pulsed on completion.
    private var coalesced: Set<String> = []
    /// How many of a key's `pendingInstantEvents` — always a prefix — a live request carries.
    /// In memory only: the events themselves stay persisted until a terminal response.
    private var claimedInstantCounts: [String: Int] = [:]

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

    func flushPersistedEntries() {
        queue.async { [weak self] in
            self?.flushCarriedOverKeys()
        }
    }

    /// Test seam: every production call site satisfies `flush`'s guard by construction.
    func flushForTesting(_ delayId: String) {
        queue.async { [weak self] in
            self?.flush(delayId)
        }
    }

    /// Test seam: lets a test sequence on the queue instead of polling against a deadline.
    func drainForTesting() {
        queue.sync {}
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
            let isFirstSighting = current.entries[insertId] == nil
            revisionCounter += 1
            current.entries[insertId] = DelayedEntry(event: event,
                                                     timeoutMs: clampedTimeoutMs(timeout),
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

    /// A converted `0` would read as the row's delete signal rather than an upsert, and
    /// `Int64(Double)` traps on non-finite or out-of-range input.
    private func clampedTimeoutMs(_ timeout: TimeInterval) -> Int64 {
        guard timeout.isFinite, timeout > 0 else { return defaultTimeoutMs }
        let milliseconds = timeout * 1000
        if milliseconds <= Double(Self.minTimeoutMs) { return Self.minTimeoutMs }
        if milliseconds >= Double(Self.maxTimeoutMs) { return Self.maxTimeoutMs }
        return Int64(milliseconds)
    }

    private func pulse() {
        pulseCurrentKey()
        flushCarriedOverKeys()
    }

    private func pulseCurrentKey() {
        guard !current.isEmpty else { return }
        if current.entries.isEmpty {
            flush(currentDelayId)
        } else {
            upsert(currentDelayId)
        }
    }

    private func flushCarriedOverKeys() {
        for delayId in carriedOver.keys.sorted() where !(carriedOver[delayId]?.isEmpty ?? true) {
            flush(delayId)
        }
    }

    /// Keep-alive. Longest TTL wins, so a short-lived snapshot cannot expire a longer-lived one.
    private func upsert(_ delayId: String) {
        let live = state(for: delayId).entries.sorted { $0.key < $1.key }
        send(delayId: delayId,
             events: live.map(\.value.event),
             timeoutMs: live.map(\.value.timeoutMs).max() ?? defaultTimeoutMs,
             sentRevisions: live.reduce(into: [:]) { $0[$1.key] = $1.value.revision })
    }

    /// Finalizes a key: entries ride `instant_events`, so one `timeout: 0` request ingests them from the body and deletes the row.
    private func flush(_ delayId: String) {
        // Carried-over keys are abandoned by definition, but the current key's live snapshots
        // belong to players still running — finalizing them would delete the row underneath.
        guard delayId != currentDelayId || current.entries.isEmpty else {
            logger?.error(message: "Refusing to flush the current delay id: "
                + "\(current.entries.count) snapshot(s) are still live")
            return
        }
        mutate(delayId) { state in
            state.pendingInstantEvents += state.entries.sorted { $0.key < $1.key }.map(\.value.event)
            state.entries = [:]
        }
        persist()
        send(delayId: delayId, events: [], timeoutMs: 0, sentRevisions: [:])
    }

    private func send(delayId: String,
                      events: [BaseEvent],
                      timeoutMs: Int64,
                      sentRevisions: [String: Int]) {
        // One request per delay id: uploads are otherwise unordered, and an upsert landing after
        // a `timeout: 0` recreates a row that then TTL-expires and re-ingests stale data.
        guard !inFlight.contains(delayId) else {
            coalesced.insert(delayId)
            return
        }
        let alreadyClaimed = claimedInstantCounts[delayId] ?? 0
        let instantEvents = Array(state(for: delayId).pendingInstantEvents.dropFirst(alreadyClaimed))
        claimedInstantCounts[delayId] = alreadyClaimed + instantEvents.count
        inFlight.insert(delayId)

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
                             claimedInstants: instantEvents.count)
            }
        }
    }

    private func handle(_ result: Result<DelayedResponseBody, Error>,
                        delayId: String,
                        timeoutMs: Int64,
                        sentRevisions: [String: Int],
                        claimedInstants: Int) {
        switch result {
        case .success:
            mutate(delayId) { state in
                dropClaimedInstants(&state, claimedInstants)
                // A live-TTL snapshot must be resent every pulse, because the upsert replaces
                // the row wholesale rather than merging. Only `timeout: 0` clears it server-side.
                if timeoutMs == 0 { removeSentEntries(&state, sentRevisions) }
            }
        case .failure(let error):
            if case DelayedEventsError.httpError(let code, _) = error, code == 400 || code == 413 {
                // Never going to be accepted; retrying forever would block everything behind it.
                logger?.error(message: "Delayed events request rejected with HTTP \(code), "
                    + "dropping \(sentRevisions.count) entry(ies) and "
                    + "\(claimedInstants) instant event(s)")
                mutate(delayId) { state in
                    dropClaimedInstants(&state, claimedInstants)
                    removeSentEntries(&state, sentRevisions)
                }
            }
            // Otherwise the claim just lapses: the instants never left the persisted state, so
            // there is nothing to restore and no freed space to have been refilled meanwhile.
        }
        claimedInstantCounts[delayId] = nil
        inFlight.remove(delayId)
        persist()
        updateTimer()
        guard coalesced.remove(delayId) != nil, !state(for: delayId).isEmpty else { return }
        if delayId == currentDelayId {
            pulseCurrentKey()
        } else {
            flush(delayId)
        }
    }

    private func dropClaimedInstants(_ state: inout DelayedState, _ claimed: Int) {
        state.pendingInstantEvents.removeFirst(min(claimed, state.pendingInstantEvents.count))
    }

    /// Only what this request sent, at the revision it sent: a mid-flight refresh survives.
    private func removeSentEntries(_ state: inout DelayedState, _ sentRevisions: [String: Int]) {
        for (insertId, revision) in sentRevisions where state.entries[insertId]?.revision == revision {
            state.entries.removeValue(forKey: insertId)
        }
    }

    private func state(for delayId: String) -> DelayedState {
        delayId == currentDelayId
            ? current
            : carriedOver[delayId] ?? DelayedState(entries: [:], pendingInstantEvents: [])
    }

    private func mutate(_ delayId: String, _ body: (inout DelayedState) -> Void) {
        if delayId == currentDelayId {
            body(&current)
        } else {
            var state = self.state(for: delayId)
            body(&state)
            carriedOver[delayId] = state
        }
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
        store.persist(snapshot())
    }

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
