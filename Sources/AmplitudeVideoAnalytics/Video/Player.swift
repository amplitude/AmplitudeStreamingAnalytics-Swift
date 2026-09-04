import Foundation

/// A reading of the playhead. `rate` is the playback speed at that instant — 0 when the playhead
/// is not advancing — which is what bounds how far it could legitimately have moved since the
/// previous reading.
struct PlayerSample: Equatable {
    let position: TimeInterval
    let duration: TimeInterval?
    let rate: Double
}

enum PlayerEvent: Equatable {
    case played
    case paused
    case seeking
    case ended
    case error(message: String?)
}

/// The consumer drives an implementation from one queue: `sample()`, `startObserving()`,
/// and `stopObserving()` are never called concurrently.
///
/// `onEvent` is *fired* on any thread, however — including re-entrantly from inside
/// `startObserving()` — so the handler's storage has to tolerate a read on an arbitrary
/// thread concurrent with a write from the consumer's queue. Events fired on different threads
/// also reach the consumer in no particular order, which is why each one carries the reading
/// taken when it fired rather than leaving the consumer to sample later.
protocol Player: AnyObject {
    func sample() -> PlayerSample?
    /// Begins delivering events to `onEvent` (fires on any thread). `stopObserving()` clears the handler.
    func startObserving(onEvent: @escaping (PlayerEvent, PlayerSample?) -> Void)
    func stopObserving()
}
