import Foundation

struct PlayerSample: Equatable {
    let position: TimeInterval
    let duration: TimeInterval?
}

enum PlayerEvent: Equatable {
    case played
    case paused
    case seeking
    case ended
    case error(message: String?)
}

/// Everything here is confined to the queue handed to `startObserving(deliveryQueue:)`: the SDK
/// calls `sample()`, `stopObserving()` and sets `onEvent` on it, and implementations must deliver
/// `onEvent` on it too. That confinement is what makes a lock unnecessary on either side.
protocol Player: AnyObject {
    func sample() -> PlayerSample?
    var onEvent: ((PlayerEvent) -> Void)? { get set }
    /// Retain `deliveryQueue` and deliver every event on it, however the underlying player reports.
    func startObserving(deliveryQueue: DispatchQueue)
    func stopObserving()
}
