import AmplitudeSwift
import Foundation

/// Keeps one snapshot per `insert_id` alive on the server until it is finalized.
///
/// All state lives behind a serial queue: `track` hands work off to it, uploads report
/// back onto it, and the pulse timer fires on it. The timer is suspended whenever there
/// is nothing outstanding, so an idle pipeline costs nothing.
///
/// Every mutation is persisted before the network is touched, so a process kill mid-flight
/// leaves a snapshot on disk that the next launch can flush (`flushPersistedEntries`).
final class DelayedEventPipeline {
    /// Ceiling on the persisted state. A mutation that would exceed it is reverted rather
    /// than written, so one pathological event cannot poison the whole snapshot file.
    private static let maxStateBytes = 4000

    private let configuration: Configuration
    private let store: DelayedSnapshotStore
    private let httpClient: DelayedEventsUploading
    private let logger: (any Logger)?
    private let defaultTimeoutMs: Int64
    private let queue = DispatchQueue(label: "delayedEvents.amplitude.com")
    private var timer: PulseTimer?
    private var state: DelayedState

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
        self.state = store.load() ?? DelayedState(delayId: UUID().uuidString,
                                                  entries: [:],
                                                  pendingInstantEvents: [])
        timer = PulseTimer(interval: pulseInterval, queue: queue) { [weak self] in
            self?.pulse()
        }
    }

    func track(_ event: BaseEvent, delay: DelayConfig) {
        queue.async { [weak self] in
            self?.performTrack(event, delay: delay)
        }
    }

    /// Flushes whatever a previous process left behind: every loaded entry is marked final
    /// so the next pulse ingests it, rather than letting it expire server-side.
    func flushPersistedEntries() {
        queue.async { [weak self] in
            guard let self, !self.state.entries.isEmpty else { return }
            for insertId in self.state.entries.keys {
                self.state.entries[insertId]?.isFinal = true
            }
            self.store.save(self.state)
            self.updateTimer()
            self.pulse()
        }
    }

    // MARK: - queue-confined state

    private func performTrack(_ event: BaseEvent, delay: DelayConfig) {
        guard let insertId = event.insertId else {
            logger?.error(message: "Delayed event dropped: no insert_id on \(event.eventType)")
            return
        }

        let previous = state
        let shouldPulseNow: Bool
        if let timeout = delay.timeout {
            let existing = state.entries[insertId]
            if timeout > 0 {
                // Upsert: newest snapshot wins, TTL extended. Only the first sighting needs
                // an immediate pulse — later refreshes ride the timer.
                state.entries[insertId] = DelayedEntry(event: event,
                                                       timeoutMs: Int64(timeout * 1000),
                                                       isFinal: existing?.isFinal ?? false)
                shouldPulseNow = existing == nil
            } else {
                // timeout <= 0 means finalize now; keep the TTL we last sent in case the
                // flush fails and the entry has to wait for a retry.
                state.entries[insertId] = DelayedEntry(event: event,
                                                       timeoutMs: existing?.timeoutMs ?? defaultTimeoutMs,
                                                       isFinal: true)
                shouldPulseNow = true
            }
        } else {
            state.pendingInstantEvents.append(event)
            shouldPulseNow = true
        }

        guard withinSizeLimit(state) else {
            state = previous
            logger?.error(message: "Delayed event dropped: state would exceed "
                + "\(Self.maxStateBytes) bytes (insert_id=\(insertId))")
            return
        }

        store.save(state)
        updateTimer()
        if shouldPulseNow {
            pulse()
        }
    }

    private func pulse() {
        // Finals first, one per pulse: each needs its own `timeout: 0` request, and a
        // successful one re-pulses to drain whatever is left.
        if let (insertId, entry) = nextFinalEntry() {
            send(events: [entry.event], timeoutMs: 0, entryIds: [insertId], removeEntriesOnSuccess: true)
            return
        }

        let outstanding = state.entries.sorted { $0.key < $1.key }
        if !outstanding.isEmpty {
            // One upsert covers every live snapshot; the longest TTL wins so nothing expires early.
            let timeoutMs = outstanding.map(\.value.timeoutMs).max() ?? defaultTimeoutMs
            send(events: outstanding.map(\.value.event),
                 timeoutMs: timeoutMs,
                 entryIds: outstanding.map(\.key),
                 removeEntriesOnSuccess: false)
            return
        }

        if !state.pendingInstantEvents.isEmpty {
            // Nothing delayed to piggyback on: `timeout: 0` with no events makes the server
            // ingest the instant events immediately (it merges them into `events`).
            send(events: [], timeoutMs: 0, entryIds: [], removeEntriesOnSuccess: false)
        }
    }

    private func nextFinalEntry() -> (String, DelayedEntry)? {
        state.entries
            .filter { $0.value.isFinal }
            .sorted { $0.key < $1.key }
            .first
            .map { ($0.key, $0.value) }
    }

    private func send(events: [BaseEvent],
                      timeoutMs: Int64,
                      entryIds: [String],
                      removeEntriesOnSuccess: Bool) {
        // Instant events are claimed before the request goes out so two overlapping
        // requests can never both carry them (the server would ingest them twice).
        // A failed request puts them back at the front of the queue.
        let instantEvents = state.pendingInstantEvents
        state.pendingInstantEvents = []

        let body = DelayedRequestBody(apiKey: configuration.apiKey,
                                      id: state.delayId,
                                      timeout: timeoutMs,
                                      events: events,
                                      instantEvents: instantEvents.isEmpty ? nil : instantEvents)

        httpClient.upload(body) { [weak self] result in
            self?.queue.async {
                self?.handle(result,
                             entryIds: entryIds,
                             instantEvents: instantEvents,
                             removeEntriesOnSuccess: removeEntriesOnSuccess)
            }
        }
    }

    private func handle(_ result: Result<DelayedResponseBody, Error>,
                        entryIds: [String],
                        instantEvents: [BaseEvent],
                        removeEntriesOnSuccess: Bool) {
        switch result {
        case .success:
            if removeEntriesOnSuccess {
                for insertId in entryIds {
                    state.entries.removeValue(forKey: insertId)
                }
            }
            store.save(state)
            updateTimer()
            if removeEntriesOnSuccess && !state.entries.isEmpty {
                pulse()
            }
        case .failure(let error):
            if case DelayedEventsError.httpError(let code, _) = error, code == 400 || code == 413 {
                // The server will never accept this payload; retrying it forever would
                // block everything behind it, so drop it (instant events included).
                logger?.error(message: "Delayed events request rejected with HTTP \(code), "
                    + "dropping \(entryIds.count) entry(ies) and \(instantEvents.count) instant event(s)")
                for insertId in entryIds {
                    state.entries.removeValue(forKey: insertId)
                }
            } else {
                state.pendingInstantEvents.insert(contentsOf: instantEvents, at: 0)
            }
            store.save(state)
            updateTimer()
        }
    }

    /// A state that cannot even be encoded is treated as over the limit — it could not be
    /// persisted anyway, so the mutation that produced it has to be reverted.
    private func withinSizeLimit(_ state: DelayedState) -> Bool {
        guard let data = try? JSONEncoder().encode(state) else { return false }
        return data.count <= Self.maxStateBytes
    }

    private func updateTimer() {
        if state.entries.isEmpty && state.pendingInstantEvents.isEmpty {
            timer?.suspend()
        } else {
            timer?.resume()
        }
    }
}
