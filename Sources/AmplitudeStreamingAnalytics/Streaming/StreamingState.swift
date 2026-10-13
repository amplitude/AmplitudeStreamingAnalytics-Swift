import Foundation

/// Raw values are wire taxonomy shared with the browser SDK.
enum StreamingStopReason: String {
    case timeout, paused, ended, error, untracked
}

/// Raw values are wire taxonomy. Only `video` is sent: an audio-only item is not told apart yet.
enum StreamingMediaType: String {
    case video, audio
}

/// One stream session as of an instant: the player's last reading, plus what only the session knows —
/// its ids and the play time accrued so far, both in this play and across the session.
struct StreamingState {
    let streamSessionId: String
    let playId: String
    let insertId: String
    let at: Date
    let startPosition: TimeInterval
    let position: TimeInterval
    let duration: TimeInterval?
    let playTime: TimeInterval
    let playTimeTotal: TimeInterval
    let stopReason: StreamingStopReason?
    let errorMessage: String?
}
