import Foundation

/// Lifecycle events a `VideoPlayer` implementation reports through `onEvent`.
public enum VideoPlayerEvent: Equatable {
    case played, paused, seeking, buffering, bufferingEnded, ended
    case error(message: String?)
}

/// Abstraction over a concrete video player (e.g. AVPlayer) that the SDK observes.
public protocol VideoPlayer: AnyObject {
    var currentTime: TimeInterval { get }
    /// `nil` indicates live / unknown duration content.
    var duration: TimeInterval? { get }
    var onEvent: ((VideoPlayerEvent) -> Void)? { get set }
    func startObserving()
    func stopObserving()
}
