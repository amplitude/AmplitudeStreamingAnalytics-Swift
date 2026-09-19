import AmplitudeSwift
import Foundation

/// Keeps delayed events alive on the ingestion server until they are finalized.
///
/// Tracking writes to disk; the network is touched on the pulse and once when outstanding work
/// appears in a row that held none. A failed request changes no state, so the next pulse resends
/// it — that is the whole retry mechanism. Every request is a full-replace upsert of one server
/// row, so each send carries that row's complete live set. Do not mutate a tracked event; refresh
/// it by tracking a fresh one with the same id.
final class DelayedEventTracker {
    private let amplitudeConfiguration: Configuration
    private let configuration: DelayedEventsConfiguration
    private let httpClient: DelayedEventsUploading
    private let snapshots: DelayedSnapshotStore
    private let logger: (any Logger)?

    // All mutable state is confined to this serial queue; HTTP completions hop back onto it.
    private let queue = DispatchQueue(label: "com.amplitude.delayedEventTracker")
    private var delayId = UUID().uuidString
    /// Every outstanding row. `states[delayId]` is this launch's; every other key was minted by an
    /// earlier launch and still has a live server row.
    private var store: DelayedStore
    private var inFlight: Set<String> = []
    private var owedSends: Set<String> = []
    private var owedFinalizations: Set<String> = []
    private var isSendScheduled = false
    /// Tracker-wide, not per entry: a per-entry counter restarts at 0 once finalization deletes an
    /// entry, so a recreated entry could false-match the revision an in-flight request sent.
    private var lastRevision = 0
    private var timer: PulseTimer!

    convenience init(amplitudeConfiguration: Configuration,
                     configuration: DelayedEventsConfiguration,
                     httpClient: DelayedEventsUploading) {
        self.init(amplitudeConfiguration: amplitudeConfiguration,
                  configuration: configuration,
                  httpClient: httpClient,
                  snapshots: DelayedSnapshotStore(apiKey: amplitudeConfiguration.apiKey,
                                                  instanceName: amplitudeConfiguration.instanceName,
                                                  logger: amplitudeConfiguration.loggerProvider))
    }

    init(amplitudeConfiguration: Configuration,
         configuration: DelayedEventsConfiguration,
         httpClient: DelayedEventsUploading,
         snapshots: DelayedSnapshotStore) {
        self.amplitudeConfiguration = amplitudeConfiguration
        self.configuration = configuration
        self.httpClient = httpClient
        self.snapshots = snapshots
        self.logger = amplitudeConfiguration.loggerProvider
        self.store = snapshots.load() ?? DelayedStore(states: [:])
        timer = PulseTimer(interval: configuration.pulseInterval, queue: queue) { [weak self] in
            self?.pulse()
        }
        guard !store.isEmpty else { return }
        // Carried-over work is an appearance too, and nothing else would wake the pulse for it.
        timer.resume()
        queue.async { self.pulse() }
    }

    func track(_ event: DelayedEvent) {
        guard let insertId = event.insertId, !insertId.isEmpty else {
            logger?.error(message: "DelayedEventTracker: insert_id is required on tracked events")
            return
        }
        queue.async { self.admit(event, insertId: insertId) }
    }

    /// Has the server ingest and delete every outstanding row now. A row with a request already out
    /// keeps that request instead: its completion no longer drops state, so nothing is lost.
    func flush() {
        queue.async {
            for key in self.store.states.keys {
                self.owedFinalizations.insert(key)
                self.scheduleSend(for: key)
            }
        }
    }

    /// Drops local state without sending; the server ingests each abandoned row at TTL expiry.
    func discard() {
        queue.async {
            self.store = DelayedStore(states: [:])
            self.delayId = UUID().uuidString
            self.owedSends.removeAll()
            self.owedFinalizations.removeAll()
            self.commit()
        }
    }

    private func admit(_ event: DelayedEvent, insertId: String) {
        let state = store.states[delayId] ?? DelayedState(entries: [:], pendingInstantEvents: [])
        let move = Self.move(tracking: event, insertId: insertId, in: state, revision: nextRevision())
        var candidate = store
        candidate.states[delayId] = move.state
        guard admits(candidate, insertId: insertId) else { return }
        store = candidate
        if move.persists {
            commit()
        }
        if move.sends {
            scheduleSend(for: delayId)
        }
    }

    /// One encode answers both questions: an event that will not encode would poison every later
    /// request, and the cap is measured on the store the write would leave behind.
    private func admits(_ candidate: DelayedStore, insertId: String) -> Bool {
        guard let encoded = try? JSONEncoder().encode(candidate) else {
            logger?.warn(message: "DelayedEventTracker: cannot encode event, rejecting event with id=\(insertId)")
            return false
        }
        guard encoded.count <= configuration.eventsSizeLimit else {
            logger?.warn(message: "DelayedEventTracker: events size limit reached, rejecting event with id=\(insertId)")
            return false
        }
        return true
    }

    private func nextRevision() -> Int {
        lastRevision += 1
        return lastRevision
    }

    private func pulse() {
        store.states.keys.forEach { scheduleSend(for: $0) }
    }

    /// Deferred by a hop so tracks landing in the same tick share one request.
    private func scheduleSend(for key: String) {
        owedSends.insert(key)
        guard !isSendScheduled else { return }
        isSendScheduled = true
        queue.async { self.sendOwed() }
    }

    private func sendOwed() {
        isSendScheduled = false
        let ready = owedSends.subtracting(inFlight)
        owedSends.subtract(ready)
        for key in ready.sorted() {
            send(key, finalizing: owedFinalizations.remove(key) != nil)
        }
    }

    private func send(_ key: String, finalizing: Bool) {
        guard let state = store.states[key], !state.isEmpty else { return }
        let entryEvents = Self.inTimestampOrder(state.entries).map(\.event)
        // A carried-over row has no future: everything it holds goes out as instants, so one
        // request ingests the lot and has the server delete the row.
        let carriedOver = key != delayId
        let instants = state.pendingInstantEvents + (carriedOver ? entryEvents : [])
        let ingesting = carriedOver || finalizing || state.entries.isEmpty
        let body = DelayedRequestBody(apiKey: amplitudeConfiguration.apiKey,
                                      id: key,
                                      ttlMs: ingesting ? 0 : configuration.ttlMs,
                                      events: carriedOver ? [] : entryEvents,
                                      instantEvents: instants.isEmpty ? nil : instants)
        let sent = SentRequest(key: key,
                               revisions: state.entries.mapValues(\.revision),
                               instantCount: state.pendingInstantEvents.count,
                               ingesting: ingesting)
        inFlight.insert(key)
        httpClient.upload(body) { [weak self] result in
            guard let self else { return }
            self.queue.async { self.complete(sent, result) }
        }
    }

    private func complete(_ sent: SentRequest, _ result: Result<DelayedResponseBody, Error>) {
        inFlight.remove(sent.key)
        switch result {
        case .success:
            settle(sent,
                   droppingEntries: sent.ingesting,
                   rotatingDelayId: sent.ingesting && sent.key == delayId)
        case .failure(let error) where Self.isPermanent(error):
            logger?.error(message: "DelayedEventTracker: delayed events request rejected, "
                + "dropping what it carried: \(error)")
            settle(sent, droppingEntries: true, rotatingDelayId: false)
        case .failure(let error):
            // Changing nothing is the retry: the next pulse resends the same body.
            logger?.error(message: "DelayedEventTracker: delayed events request failed: \(error)")
        }
        sendOwed()
    }

    private func settle(_ sent: SentRequest, droppingEntries: Bool, rotatingDelayId: Bool) {
        guard let state = store.states[sent.key] else { return }
        let settled = state.dropping(revisions: droppingEntries ? sent.revisions : [:],
                                     instantCount: sent.instantCount)
        store.states[sent.key] = settled
        if rotatingDelayId, !settled.isEmpty {
            rotateDelayId(carrying: settled)
        }
        commit()
    }

    /// The server has finalized and deleted this row; survivors move to one it has never seen.
    /// Everything keyed by the retired id follows it, or an owed send would address a gone row.
    private func rotateDelayId(carrying state: DelayedState) {
        let retired = delayId
        store.states[retired] = nil
        delayId = UUID().uuidString
        store.states[delayId] = state
        if owedSends.remove(retired) != nil { owedSends.insert(delayId) }
        if owedFinalizations.remove(retired) != nil { owedFinalizations.insert(delayId) }
    }

    /// The file mirrors `store`, and the pulse runs exactly while something is outstanding.
    private func commit() {
        store.states = store.states.filter { !$0.value.isEmpty }
        snapshots.persist(store)
        if store.isEmpty {
            timer.suspend()
        } else {
            timer.resume()
        }
    }

    /// 400 and 413 say the payload itself is the problem, so resending it can only fail again.
    private static func isPermanent(_ error: Error) -> Bool {
        guard case DelayedEventsError.httpError(let code, _) = error else { return false }
        return code == 400 || code == 413
    }

    /// `entries` is a dictionary, so the wire array needs an order of its own.
    private static func inTimestampOrder(_ entries: [String: DelayedEntry]) -> [DelayedEntry] {
        entries.sorted { left, right in
            let leftAt = left.value.event.timestamp ?? 0
            let rightAt = right.value.event.timestamp ?? 0
            return leftAt == rightAt ? left.key < right.key : leftAt < rightAt
        }.map(\.value)
    }

    /// What a track does to one row. `persists` is false only for a refresh of something already on
    /// disk; `sends` marks the appearance of the row's first live entry.
    private struct StateMove {
        let state: DelayedState
        let persists: Bool
        let sends: Bool
    }

    private static func move(tracking event: DelayedEvent,
                             insertId: String,
                             in state: DelayedState,
                             revision: Int) -> StateMove {
        var next = state
        guard event.kind == .delayed else {
            // An instant is never a refresh: for a live id it finalizes the entry and replaces it.
            next.entries[insertId] = nil
            next.pendingInstantEvents.append(event)
            return StateMove(state: next, persists: true, sends: false)
        }
        let isRefresh = state.entries[insertId] != nil
        next.entries[insertId] = DelayedEntry(event: event, revision: revision)
        return StateMove(state: next, persists: !isRefresh, sends: state.entries.isEmpty)
    }

    /// What one request carried, so its completion only drops what it actually sent.
    private struct SentRequest {
        let key: String
        let revisions: [String: Int]
        let instantCount: Int
        let ingesting: Bool
    }
}

private extension DelayedState {
    /// An entry refreshed mid-flight carries a newer revision than the one sent and survives.
    /// Instants are appended to the back, so the sent ones are exactly the front `instantCount`.
    func dropping(revisions: [String: Int], instantCount: Int) -> DelayedState {
        var next = self
        for (insertId, revision) in revisions where next.entries[insertId]?.revision == revision {
            next.entries[insertId] = nil
        }
        next.pendingInstantEvents.removeFirst(min(instantCount, next.pendingInstantEvents.count))
        return next
    }
}
