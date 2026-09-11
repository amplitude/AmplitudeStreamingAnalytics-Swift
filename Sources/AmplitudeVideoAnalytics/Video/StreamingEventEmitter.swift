import Foundation

/// Turns successive `PlayerState`s into the two wire events. Owns the ids; knows nothing about players or
/// queues. Called by one owner from one queue.
struct StreamingEventEmitter {
    /// What one play owns. `rowId` is the server row its stops share: `liveStop` opens it, `finalStop` closes it.
    private struct Play {
        let id = UUID().uuidString
        let rowId = UUID().uuidString
        let startedId = UUID().uuidString
        let startTime: TimeInterval
    }

    let streamSessionId = UUID().uuidString

    private let options: VideoTrackingOptions
    /// Non-nil exactly while a play is open.
    private var play: Play?

    init(options: VideoTrackingOptions) {
        self.options = options
    }

    /// The emitter after `state`, and its events in tracking order. Instants carry `forcePulse`; the opening
    /// live stop does not, because it rides the STARTED request.
    func events(for state: PlayerState, at now: Date) -> (emitter: StreamingEventEmitter, events: [DelayedEvent]) {
        switch (play, state.phase) {
        case (nil, .playing):
            let play = Play(startTime: state.position)
            return (tracking(play), [liveStop(play, state, at: now), started(play, state, at: now)])
        case (.some(let play), .playing):
            return (self, [liveStop(play, state, at: now)])
        case (.some(let play), .stopped(let reason)):
            return (tracking(nil), [finalStop(play, state, at: now, reason: reason)])
        case (.some(let play), _):
            return (tracking(nil), [finalStop(play, state, at: now, reason: .untracked)])
        default:
            return (self, [])
        }
    }

    private func started(_ play: Play, _ state: PlayerState, at now: Date) -> DelayedEvent {
        let event = StreamingEvents.started(options: options,
                                            state: streamingState(play, state, at: now, insertId: play.startedId))
        event.markForcePulse()
        return event
    }

    /// Holds the row open at the latest reading: refreshed in place by every tick, superseded by `finalStop`.
    private func liveStop(_ play: Play, _ state: PlayerState, at now: Date) -> DelayedEvent {
        StreamingEvents.stopped(options: options,
                                state: streamingState(play, state, at: now, insertId: play.rowId, reason: .timeout))
    }

    private func finalStop(_ play: Play,
                           _ state: PlayerState,
                           at now: Date,
                           reason: PlayerState.StopReason) -> DelayedEvent {
        let event = StreamingEvents.stopped(options: options,
                                            state: streamingState(play, state, at: now,
                                                                  insertId: play.rowId,
                                                                  reason: reason.wireReason,
                                                                  errorMessage: reason.errorMessage))
        event.markForcePulse()
        return event
    }

    private func streamingState(_ play: Play,
                                _ state: PlayerState,
                                at now: Date,
                                insertId: String,
                                reason: StreamingStopReason? = nil,
                                errorMessage: String? = nil) -> StreamingState {
        StreamingState(streamSessionId: streamSessionId,
                       playId: play.id,
                       insertId: insertId,
                       at: now,
                       startTime: play.startTime,
                       position: state.position,
                       duration: state.duration,
                       streamDuration: state.watchTime,
                       stopReason: reason,
                       errorMessage: errorMessage)
    }

    private func tracking(_ play: Play?) -> StreamingEventEmitter {
        var copy = self
        copy.play = play
        return copy
    }
}

private extension PlayerState.StopReason {
    var wireReason: StreamingStopReason {
        switch self {
        case .paused: return .paused
        case .ended: return .ended
        case .error: return .error
        case .untracked: return .untracked
        }
    }

    var errorMessage: String? {
        guard case .error(let message) = self else { return nil }
        return message
    }
}
