import Foundation

struct PlayerState: Equatable {
    enum StopReason: Equatable {
        case paused
        case ended
        case error(message: String?)
        case untracked
    }

    enum Phase: Equatable {
        case idle
        case playing
        /// A play closed for this reason. The next `.played` is a replay.
        case stopped(StopReason)
        case final
    }

    var phase: Phase = .idle
    var position: TimeInterval = 0
    var duration: TimeInterval?
    var watchTime: TimeInterval = 0

    func with(_ change: (inout PlayerState) -> Void) -> PlayerState {
        var copy = self
        change(&copy)
        return copy
    }
}
