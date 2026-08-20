import AmplitudeSwift
import Foundation

private extension DelayedState {
    var isEmpty: Bool { entries.isEmpty && pendingInstantEvents.isEmpty }
}

/// Keeps one snapshot per `insert_id` alive on the server until it is finalized.
///
/// State is keyed by delay id, one key per server row. `currentDelayId` is minted fresh on every
/// init and fixed for the launch; keys left behind by earlier launches are carried over and
/// flushed under their own original ids, since those are the rows that actually exist.
///
/// All state lives behind a serial queue: `track` hands work off to it, uploads report back onto
/// it, and the pulse timer fires on it. The timer is suspended whenever there is nothing
/// outstanding, so an idle pipeline costs nothing.
///
/// Every mutation is persisted before the network is touched, so a process kill mid-flight leaves
/// state on disk that the next launch can flush (`flushPersistedEntries`).
final class DelayedEventPipeline {
    /// Ceiling on the whole persisted file, across every key. Matches the browser's
    /// `EVENTS_SIZE_LIMIT = 4 * 10_000` (40,000 bytes, not the "4KB" its comment claims). The
    /// binding constraint is `pendingInstantEvents` during an outage, not snapshot count: an
    /// enriched snapshot is well under 2 KB, so this absorbs roughly thirty offline resumes.
    private static let maxStateBytes = 40_000

    /// Fixed for this launch. Only the *persisted* record of a delay id goes away, when its key
    /// drains — which is what keeps the id from being pinned for the life of the install.
    let currentDelayId = UUID().uuidString

    private let configuration: Configuration
    private let store: DelayedSnapshotStore
    private let httpClient: DelayedEventsUploading
    private let logger: (any Logger)?
    private let defaultTimeoutMs: Int64
    private let queue = DispatchQueue(label: "delayedEvents.amplitude.com")
    private var timer: PulseTimer?
    private var current = DelayedState(entries: [:], pendingInstantEvents: [])
    /// Delay ids minted by earlier launches whose server rows may still be live.
    private var carriedOver: [String: DelayedState]
    /// Monotonic within the launch, which is all the in-flight guard needs — nothing is in
    /// flight at launch, so a revision reloaded from disk cannot produce a false match.
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

    /// Drains the keys previous launches left behind: each goes out under its own delay id so the
    /// server ingests it instead of letting the row sit until its TTL fires.
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
            // A non-positive TTL would send the row's delete signal, which is never what an
            // upsert means; fall back rather than drop the row out from under other snapshots.
            let timeoutMs = timeout > 0 ? Int64(timeout * 1000) : defaultTimeoutMs
            let isFirstSighting = current.entries[insertId] == nil
            revisionCounter += 1
            current.entries[insertId] = DelayedEntry(event: event,
                                                     timeoutMs: timeoutMs,
                                                     revision: revisionCounter)
            // Later refreshes ride the timer; only a new snapshot needs the row created now.
            shouldPulseNow = isFirstSighting
        case .instant:
            // An instant for a live snapshot *is* its finalization, in one mutation: the entry
            // leaves `events` and the event rides `instant_events` in the very next request,
            // alongside whatever snapshots are still live.
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
        // With no live snapshots left, `timeout: 0` ingests the instants and deletes the row —
        // the only thing that legitimately deletes it.
        let timeoutMs = live.map(\.value.timeoutMs).max() ?? 0
        send(delayId: currentDelayId,
             events: live.map(\.value.event),
             timeoutMs: timeoutMs,
             sentRevisions: live.reduce(into: [:]) { $0[$1.key] = $1.value.revision })
    }

    private func flushCarriedOverKeys() {
        var dropped = false
        for delayId in carriedOver.keys.sorted() {
            guard var state = carriedOver[delayId], !state.isEmpty else { continue }

            if hasOutlivedItsTimeout(state) {
                // The server row has already TTL-expired and been ingested, so flushing would
                // only produce a duplicate. Dropping it also bounds the offline-relaunch case.
                logger?.debug(message: "Delayed events key \(delayId) dropped unsent: "
                    + "its newest snapshot is past its own timeout")
                carriedOver.removeValue(forKey: delayId)
                dropped = true
                continue
            }

            // Everything under an old id goes out at once: the entries become instant events so
            // one `timeout: 0` request ingests the lot and deletes the row.
            state.pendingInstantEvents += state.entries.sorted { $0.key < $1.key }.map(\.value.event)
            state.entries = [:]
            carriedOver[delayId] = state
            persist()
            send(delayId: delayId, events: [], timeoutMs: 0, sentRevisions: [:])
        }
        if dropped {
            persist()
            updateTimer()
        }
    }

    private func send(delayId: String,
                      events: [BaseEvent],
                      timeoutMs: Int64,
                      sentRevisions: [String: Int]) {
        // Instant events are claimed, not copied: they leave the state before the request goes
        // out, so two overlapping requests can never both carry them (the server would ingest
        // them twice). A failed request puts them back at the front of the queue.
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
            // `timeout: 0` made the server ingest the body and delete the row, so what this
            // request carried is gone server-side. Nothing else is: a snapshot upserted at a
            // live TTL has to be resent on every pulse, because the upsert replaces the row
            // wholesale rather than merging into it.
            if timeoutMs == 0 {
                mutate(delayId) { removeSentEntries(&$0, sentRevisions) }
            }
        case .failure(let error):
            if case DelayedEventsError.httpError(let code, _) = error, code == 400 || code == 413 {
                // The server will never accept this payload; retrying it forever would block
                // everything behind it, so drop it (instant events included).
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

    /// Only removes what this request actually sent, at the revision it sent. A snapshot
    /// refreshed while the request was in flight carries a newer revision and survives.
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

    /// True once the newest snapshot under a key is older than its own TTL.
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

    /// A state that cannot even be encoded is treated as over the limit — it could not be
    /// persisted anyway, so the mutation that produced it has to be reverted.
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
