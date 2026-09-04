import Foundation

@testable import AmplitudeVideoAnalytics

/// Scriptable `Player`. `isGone` makes `sample()` return nil, standing in for a deallocated player.
///
/// Every stored property is behind the lock, `onEvent` included: the consumer writes it from its
/// own queue while `fire` reads it on whatever thread is standing in for AVFoundation's, which is
/// exactly the shape ``Player`` asks implementations to tolerate. `AVPlayerAdapter` does the same.
final class FakePlayer: Player {
    private let lock = NSLock()
    private var positionValue: TimeInterval = 0
    private var durationValue: TimeInterval?
    private var isGoneValue = false
    private var rateValue: Double = 1
    private var handler: ((PlayerEvent, PlayerSample?) -> Void)?
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

    var isGone: Bool {
        get { lock.withLock { isGoneValue } }
        set { lock.withLock { isGoneValue = newValue } }
    }

    /// Playback speed reported with every reading. 1 unless a test is exercising the clamp.
    var rate: Double {
        get { lock.withLock { rateValue } }
        set { lock.withLock { rateValue = newValue } }
    }

    var onEvent: ((PlayerEvent, PlayerSample?) -> Void)? {
        get { lock.withLock { handler } }
        set { lock.withLock { handler = newValue } }
    }

    var startObservingCount: Int { lock.withLock { startObservingValue } }
    var stopObservingCount: Int { lock.withLock { stopObservingValue } }

    var onStartObserving: (() -> Void)? {
        get { lock.withLock { onStartObservingValue } }
        set { lock.withLock { onStartObservingValue = newValue } }
    }

    func sample() -> PlayerSample? {
        lock.withLock {
            isGoneValue ? nil : PlayerSample(position: positionValue, duration: durationValue, rate: rateValue)
        }
    }

    func startObserving() {
        // Called outside the lock: the hook re-enters through `fire`.
        let hook: (() -> Void)? = lock.withLock {
            startObservingValue += 1
            return onStartObservingValue
        }
        hook?()
    }

    func stopObserving() {
        lock.withLock { stopObservingValue += 1 }
    }

    /// Takes the reading at fire time, as `AVPlayerAdapter` does.
    func fire(_ event: PlayerEvent) { onEvent?(event, sample()) }
}
