import Foundation

/// Where the playhead is. `duration` is nil when the length is unknown — a live stream, or an item that has
/// not loaded it yet. It is reported as given, so answering nil after a real length might reclassify the viewing
/// as live.
struct Playhead: Equatable {
    let position: TimeInterval
    let duration: TimeInterval?
}

/// What a player reports. Send each as it happens; order does not matter and repeats are free.
enum PlayerEvent: Equatable {
    /// Playback started or resumed.
    case played
    /// Playback stopped without reaching the end. Not for buffering.
    case paused
    /// Optional, only before the playhead moves: makes watch time exact. Free to repeat; any other event ends it.
    case seeking
    /// The playhead moved by something other than playing. Required if your player can seek, or the SDK
    /// counts the jump as watched.
    case seeked
    /// Playback reached the end. A later `.played` is a new play.
    case ended
    /// Playback failed.
    case error(message: String?)
    /// The player is gone and will report nothing more; this ends the viewing. Hold your player weakly and
    /// send it as soon as the player deallocates.
    case released
}

/// Reports one player to the SDK: you say what it does and where its playhead is, the SDK works out how much
/// was watched. It counts playhead movement rather than elapsed time, so a stall costs nothing but a jump you
/// do not report is counted as watched. `AVPlayerAdapter` is the built-in conformer for `AVPlayer`.
///
/// The SDK calls the three methods below from one queue, one at a time: they need no locking against each other.
protocol Player: AnyObject {
    /// Where the playhead is now, read from the player and remembered. Once the player is gone, answer with
    /// the last reading — a call can already be under way when it dies.
    func playhead() -> Playhead

    /// Called once by the SDK to start tracking: attach, keep `onEvent`, and call it from any thread,
    /// including before this returns. The SDK never calls back into you from inside it.
    func startObserving(onEvent: @escaping (PlayerEvent) -> Void)

    /// Called by the SDK when the viewing ends, possibly twice or without ever starting. Detach everything.
    func stopObserving()
}
