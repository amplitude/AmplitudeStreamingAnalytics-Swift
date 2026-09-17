import Foundation

@testable import AmplitudeVideoAnalytics

/// A `Player` that does only what `Player.swift` documents, and records what the SDK does to it.
///
/// `FakePlayer` is scripted by the observer's own tests to provoke behaviour. This one is the other way round:
/// it is the subject of `PlayerContractTests`, where every assertion is about the SDK's side of the bargain.
final class MockPlayer: Player {
    /// Marks the queue the SDK promised to call from, so calls arriving elsewhere can be counted rather than
    /// crashing the suite the way `dispatchPrecondition` would.
    static let queueKey = DispatchSpecificKey<UInt8>()
    private static let queueToken: UInt8 = 1

    static func claim(_ queue: DispatchQueue) {
        queue.setSpecific(key: queueKey, value: queueToken)
    }

    private let lock = NSLock()

    private var positionValue: TimeInterval = 0
    private var durationValue: TimeInterval?
    /// Kept past `stopObserving()`, so a test can still deliver through it: see `fire(_:detached:)`.
    private var handler: ((PlayerEvent) -> Void)?
    private var isObservingValue = false
    private var onStartObservingValue: (() -> Void)?

    private var callsInFlight = 0
    private var overlapsValue = 0
    private var callsOffTheQueueValue = 0
    private var reentrantCallsValue = 0
    private var playheadCallsValue = 0
    private var startObservingValue = 0
    private var stopObservingValue = 0
    /// Non-nil only while this player is inside `onEvent`; re-entrancy is a call on that same thread.
    private var deliveringThread: Thread?

    // MARK: - what the SDK did

    /// Calls that overlapped another, so the SDK broke "one at a time".
    var overlaps: Int { lock.withLock { overlapsValue } }
    /// Calls that arrived somewhere other than the queue the SDK named.
    var callsOffTheQueue: Int { lock.withLock { callsOffTheQueueValue } }
    /// Calls made from inside `onEvent`, on the thread delivering it.
    var reentrantCalls: Int { lock.withLock { reentrantCallsValue } }
    var playheadCalls: Int { lock.withLock { playheadCallsValue } }
    var startObservingCount: Int { lock.withLock { startObservingValue } }
    var stopObservingCount: Int { lock.withLock { stopObservingValue } }
    var isObserving: Bool { lock.withLock { isObservingValue } }

    // MARK: - what the test scripts

    var position: TimeInterval {
        get { lock.withLock { positionValue } }
        set { lock.withLock { positionValue = newValue } }
    }

    var duration: TimeInterval? {
        get { lock.withLock { durationValue } }
        set { lock.withLock { durationValue = newValue } }
    }

    /// Runs inside `startObserving`, once the handler is set: a player that replays its state synchronously.
    var onStartObserving: (() -> Void)? {
        get { lock.withLock { onStartObservingValue } }
        set { lock.withLock { onStartObservingValue = newValue } }
    }

    /// Delivers `event` from the calling thread, as a real player does, flagging the window so any call the
    /// SDK makes back into us from inside it is caught. A detached player says nothing, unless `detached`
    /// asks for the callback a real one can still have in flight as `stopObserving()` lands.
    func fire(_ event: PlayerEvent, detached: Bool = false) {
        let handler = lock.withLock { () -> ((PlayerEvent) -> Void)? in
            deliveringThread = Thread.current
            return isObservingValue || detached ? self.handler : nil
        }
        handler?(event)
        lock.withLock { deliveringThread = nil }
    }

    // MARK: - Player

    func playhead() -> Playhead {
        enter()
        defer { leave() }
        // Widens the window so a genuinely concurrent call is seen rather than missed by luck.
        Thread.sleep(forTimeInterval: 0.0002)
        return lock.withLock {
            playheadCallsValue += 1
            return Playhead(position: positionValue, duration: durationValue)
        }
    }

    func startObserving(onEvent: @escaping (PlayerEvent) -> Void) {
        enter()
        defer { leave() }
        let hook: (() -> Void)? = lock.withLock {
            handler = onEvent
            isObservingValue = true
            startObservingValue += 1
            return onStartObservingValue
        }
        hook?()
    }

    func stopObserving() {
        enter()
        defer { leave() }
        lock.withLock {
            isObservingValue = false
            stopObservingValue += 1
        }
    }

    // MARK: - bookkeeping

    private func enter() {
        let onQueue = DispatchQueue.getSpecific(key: Self.queueKey) == Self.queueToken
        lock.withLock {
            if !onQueue { callsOffTheQueueValue += 1 }
            if let deliveringThread, deliveringThread == Thread.current { reentrantCallsValue += 1 }
            callsInFlight += 1
            if callsInFlight > 1 { overlapsValue += 1 }
        }
    }

    private func leave() {
        lock.withLock { callsInFlight -= 1 }
    }
}
