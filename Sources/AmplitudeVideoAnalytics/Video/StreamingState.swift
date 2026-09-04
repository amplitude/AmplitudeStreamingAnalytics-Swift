import Foundation

/// Raw values are wire taxonomy shared with the browser SDK.
enum StreamingStopReason: String {
    case timeout, paused, ended, error, untracked
}

/// One view session as of an instant: the player's last reading, plus what only the session knows —
/// its ids and the watch time accrued so far.
struct StreamingState {
    let viewSessionId: String
    let playId: String
    let insertId: String
    let at: Date
    let startTime: TimeInterval
    let position: TimeInterval
    let duration: TimeInterval?
    let watchDuration: TimeInterval
    let stopReason: StreamingStopReason?
    let errorMessage: String?
}
