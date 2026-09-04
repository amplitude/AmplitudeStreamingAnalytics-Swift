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

protocol Player: AnyObject {
    func sample() -> PlayerSample?
    // Fires on any thread.
    var onEvent: ((PlayerEvent) -> Void)? { get set }
    func startObserving()
    func stopObserving()
}
