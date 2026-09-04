import Foundation

@testable import AmplitudeVideoAnalytics

/// Scriptable `Player`. `isGone` makes `sample()` return nil, standing in for a deallocated player.
final class FakePlayer: Player {
    private let lock = NSLock()
    private var positionValue: TimeInterval = 0
    private var durationValue: TimeInterval?
    private var isGoneValue = false

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

    var onEvent: ((PlayerEvent) -> Void)?
    private(set) var startObservingCount = 0
    private(set) var stopObservingCount = 0
    var onStartObserving: (() -> Void)?

    func sample() -> PlayerSample? {
        lock.withLock { isGoneValue ? nil : PlayerSample(position: positionValue, duration: durationValue) }
    }

    func startObserving() {
        startObservingCount += 1
        onStartObserving?()
    }

    func stopObserving() {
        stopObservingCount += 1
    }

    func fire(_ event: PlayerEvent) { onEvent?(event) }
}
