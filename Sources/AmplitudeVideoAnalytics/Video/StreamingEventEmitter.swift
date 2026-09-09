import Foundation

/// Turns successive `PlayerState`s into the two wire events. Owns the ids; knows nothing about players or
/// queues. Called by one owner from one queue.
final class StreamingEventEmitter {
    let streamSessionId = UUID().uuidString

    private let options: VideoTrackingOptions
    private var playId = ""
    private var snapshotInsertId = ""
    private var startTime: TimeInterval = 0
    private var wasPlaying = false

    init(options: VideoTrackingOptions) {
        self.options = options
    }

    /// Events for `state`, in tracking order. Instants carry `forcePulse`; the opening snapshot does not,
    /// because it rides the STARTED request.
    func events(for state: PlayerState, at now: Date) -> [DelayedEvent] {
        defer { wasPlaying = state.phase == .playing }
        switch (wasPlaying, state.phase) {
        case (false, .playing):
            playId = UUID().uuidString
            snapshotInsertId = UUID().uuidString
            startTime = state.position
            let started = StreamingEvents.started(options: options,
                                                  state: streamingState(state, at: now, reason: nil, insertId: UUID().uuidString))
            started.markForcePulse()
            return [snapshot(state, at: now), started]
        case (true, .playing):
            return [snapshot(state, at: now)]
        case (true, .stopped(let reason)):
            return [stop(state, at: now, reason: reason)]
        case (true, _):
            return [stop(state, at: now, reason: .untracked)]
        default:
            return []
        }
    }

    private func snapshot(_ state: PlayerState, at now: Date) -> DelayedEvent {
        StreamingEvents.stopped(options: options, state: streamingState(state, at: now, reason: .timeout))
    }

    private func stop(_ state: PlayerState, at now: Date, reason: PlayerState.StopReason) -> DelayedEvent {
        let (wireReason, errorMessage) = reason.wireReason
        let event = StreamingEvents.stopped(options: options,
                                            state: streamingState(state, at: now, reason: wireReason, errorMessage: errorMessage))
        event.markForcePulse()
        return event
    }

    private func streamingState(_ state: PlayerState,
                                at now: Date,
                                reason: StreamingStopReason?,
                                errorMessage: String? = nil,
                                insertId: String? = nil) -> StreamingState {
        StreamingState(streamSessionId: streamSessionId,
                       playId: playId,
                       insertId: insertId ?? snapshotInsertId,
                       at: now,
                       startTime: startTime,
                       position: state.position,
                       duration: state.duration,
                       streamDuration: state.watchTime,
                       stopReason: reason,
                       errorMessage: errorMessage)
    }
}

private extension PlayerState.StopReason {
    var wireReason: (StreamingStopReason, errorMessage: String?) {
        switch self {
        case .paused: return (.paused, nil)
        case .ended: return (.ended, nil)
        case .error(let message): return (.error, message)
        case .untracked: return (.untracked, nil)
        }
    }
}
