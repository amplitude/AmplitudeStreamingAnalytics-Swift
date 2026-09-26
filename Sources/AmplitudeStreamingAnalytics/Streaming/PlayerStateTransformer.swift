import Foundation

/// Turns successive `PlayerState`s into the two wire events. Owns the ids; knows nothing about players or
/// queues. Called by one owner from one queue.
final class PlayerStateTransformer {
    /// What one play owns. Both its stops carry `stopInsertId`, so the final one replaces the pending one.
    private struct Play {
        let id = UUID().uuidString
        let startInsertId = UUID().uuidString
        let stopInsertId = UUID().uuidString
        let startTime: TimeInterval
    }

    private let streamSessionId = UUID().uuidString
    private let content: PlayerContent
    /// Non-nil exactly while a play is open.
    private var play: Play?

    init(content: PlayerContent) {
        self.content = content
    }

    /// The events for `state`, in tracking order. Instants carry `forcePulse`; the pending stop does not,
    /// because it rides whichever request the next instant forces.
    func events(for state: PlayerState, at now: Date) -> [DelayedEvent] {
        var start: DelayedEvent?

        if play == nil, state.phase == .playing {
            let opened = Play(startTime: state.position)
            self.play = opened
            start = self.start(opened, state, at: now)
        }

        guard let play else { return [] }

        // The pending stop goes first: the forced start triggers the request, so the row must already be in
        // the live set or that request ships with nothing to keep it alive.
        if state.phase == .playing {
            return [pendingStop(play, state, at: now), start].compactMap { $0 }
        }

        self.play = nil
        return [stop(play, state, at: now, reason: state.phase.stopReason)]
    }

    private func start(_ play: Play, _ state: PlayerState, at now: Date) -> DelayedEvent {
        let event = StreamingEvents.started(content: content,
                                            state: streamingState(play, state, at: now, insertId: play.startInsertId))
        event.markForcePulse()
        return event
    }

    private func pendingStop(_ play: Play, _ state: PlayerState, at now: Date) -> DelayedEvent {
        StreamingEvents.stopped(content: content,
                                state: streamingState(play, state, at: now,
                                                      insertId: play.stopInsertId,
                                                      stopReason: .timeout))
    }

    private func stop(_ play: Play,
                      _ state: PlayerState,
                      at now: Date,
                      reason: PlayerState.StopReason) -> DelayedEvent {
        let event = StreamingEvents.stopped(content: content,
                                            state: streamingState(play, state, at: now,
                                                                  insertId: play.stopInsertId,
                                                                  stopReason: reason.streamingStopReason,
                                                                  errorMessage: reason.errorMessage))
        event.markForcePulse()
        return event
    }

    private func streamingState(_ play: Play,
                                _ state: PlayerState,
                                at now: Date,
                                insertId: String,
                                stopReason: StreamingStopReason? = nil,
                                errorMessage: String? = nil) -> StreamingState {
        StreamingState(streamSessionId: streamSessionId,
                       playId: play.id,
                       insertId: insertId,
                       at: now,
                       startTime: play.startTime,
                       position: state.position,
                       duration: state.duration,
                       playTime: state.playTime,
                       stopReason: stopReason,
                       errorMessage: errorMessage)
    }
}

private extension PlayerState.Phase {
    var stopReason: PlayerState.StopReason {
        guard case .stopped(let reason) = self else { return .untracked }
        return reason
    }
}

private extension PlayerState.StopReason {
    var streamingStopReason: StreamingStopReason {
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
