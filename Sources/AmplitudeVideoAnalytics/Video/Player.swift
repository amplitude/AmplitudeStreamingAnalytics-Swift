import Foundation

/// Where the playhead is. `duration` is nil when the content has no known length — a live stream, or an item whose
/// length has not loaded yet. Unless the app sets `VideoTrackingOptions.deliveryMode`, `delivery_mode` is derived
/// from it: nil reports `live`, a value reports `on_demand`.
struct Playhead: Equatable {
    let position: TimeInterval
    let duration: TimeInterval?
}

/// What a player reports. Duplicate and out-of-order events are tolerated: the SDK acts on transitions and drops
/// the rest.
enum PlayerEvent: Equatable {
    /// Playback is running. Ignored while a play is already open.
    case played
    /// Playback is not running. Ignored when no play is open.
    case paused
    /// The playhead began moving to a new position. Nothing counts as watch time until `.seekEnded`;
    /// `.played`, `.paused` and `.ended` also close a pending seek.
    case seekStarted
    /// The playhead settled at its new position. The SDK reads it and resumes counting.
    case seekEnded
    /// Played to the end. A later `.played` is a replay with a fresh `play_id`.
    case ended
    /// Playback failed. Ends the viewing only while playing; otherwise it is logged and ignored.
    case error(message: String?)
    /// The player went away. Ends the viewing; the SDK reads the playhead once more and expects the last known values.
    case released
}

/// What the SDK observes to track one viewing: report what your player does, and answer where the playhead is.
/// The SDK computes watch time. `AVPlayerAdapter` is the built-in implementation.
///
/// Threading: `playhead()`, `startObserving()` and `stopObserving()` are only ever called from one serial queue,
/// never concurrently, so an implementation needs no locking for them. `onEvent` may fire on any thread, including
/// synchronously from inside `startObserving()`; the SDK hops onto its own queue and never calls back into the
/// player from inside the callback.
///
/// Readings: `playhead()` is polled about once a second while playing and after every event. A non-finite or
/// negative position or duration is replaced with the last good reading rather than trusted. After `.released` it
/// answers the last known reading.
///
/// Send `.released` when your player is deallocated or otherwise finished for good; `AVPlayerAdapter` does this
/// from the player's deallocation.
protocol Player: AnyObject {
    func playhead() -> Playhead
    func startObserving(onEvent: @escaping (PlayerEvent) -> Void)
    func stopObserving()
}
