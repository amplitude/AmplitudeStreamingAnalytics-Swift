import Foundation

@testable import AmplitudeVideoAnalytics

/// Scriptable `Player`. The lock is for the tests, not the contract: `Player` promises nothing about threads;
/// tests script the player from the XCTest thread and fire events from others, so the fake's storage must survive that.
final class FakePlayer: Player {
    private let lock = NSLock()
    private var positionValue: TimeInterval = 0
    private var durationValue: TimeInterval?
    private var handler: ((PlayerEvent) -> Void)?
    private var startObservingValue = 0
    private var stopObservingValue = 0
    private var onStartObservingValue: (() -> Void)?

    var position: TimeInterval {
        get { lock.withLock { positionValue } }
        set { lock.withLock { positionValue = newValue } }
    }

    var duration: TimeInterval? {
        get { lock.withLock { durationValue } }
        set { lock.withLock { durationValue = newValue } }
    }

    /// Runs inside `startObserving`, after the handler is set: a player that replays its current state synchronously.
    var onStartObserving: (() -> Void)? {
        get { lock.withLock { onStartObservingValue } }
        set { lock.withLock { onStartObservingValue = newValue } }
    }

    var onEvent: ((PlayerEvent) -> Void)? { lock.withLock { handler } }
    var startObservingCount: Int { lock.withLock { startObservingValue } }
    var stopObservingCount: Int { lock.withLock { stopObservingValue } }

    func playhead() -> Playhead {
        lock.withLock { Playhead(position: positionValue, duration: durationValue) }
    }

    func startObserving(onEvent: @escaping (PlayerEvent) -> Void) {
        let hook: (() -> Void)? = lock.withLock {
            handler = onEvent
            startObservingValue += 1
            return onStartObservingValue
        }
        hook?()
    }

    func stopObserving() {
        lock.withLock {
            handler = nil
            stopObservingValue += 1
        }
    }

    /// Delivers `event` on the calling thread, as a real player would.
    func fire(_ event: PlayerEvent) { onEvent?(event) }
}
