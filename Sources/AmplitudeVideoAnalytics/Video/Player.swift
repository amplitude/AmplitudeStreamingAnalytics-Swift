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

/// The SDK never calls into your `Player` from inside an `onEvent` callback.
protocol Player: AnyObject {
    func sample() -> PlayerSample?
    // `onEvent` fires on any thread.
    func startObserving(onEvent: @escaping (PlayerEvent) -> Void)
    func stopObserving()
}
