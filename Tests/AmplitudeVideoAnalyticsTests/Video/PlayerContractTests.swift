import AmplitudeSwift
import XCTest

@testable import AmplitudeVideoAnalytics

/// The `Player` contract as executable tests: one per numbered promise in the brain's
/// `2026-09-10-player-protocol-contract` note.
///
/// Every promise constrains the **SDK**, not the player, so `MockPlayer` does only what the docs ask of a
/// conformer and records what the SDK does to it. That is the difference from `PlayerObserverTests`, which
/// provokes our implementation with things a player should never do. A failure here means the documentation
/// is a lie; a failure there means we mishandle abuse.
final class PlayerContractTests: XCTestCase {

    // MARK: - threading

    /// 1. The SDK calls `playhead()`, `startObserving()` and `stopObserving()` from one queue, one at a time.
    func testThePlayerIsCalledFromOneQueueOneAtATime() {
        let contract = Contract(label: "one-queue")
        contract.start()

        let group = DispatchGroup()
        for worker in 0..<6 {
            DispatchQueue.global().async(group: group) {
                for step in 0..<25 {
                    contract.player.position = TimeInterval(step)
                    switch (worker + step) % 5 {
                    case 0: contract.player.fire(.played)
                    case 1: contract.player.fire(.seeked)
                    case 2: contract.queue.async { contract.tick() }
                    // Built, not read: reading the player here would be a call this test is counting.
                    case 3: contract.player.fire(.seeking(from: Playhead(position: TimeInterval(step),
                                                                        duration: 100)))
                    default: contract.player.fire(.paused)
                    }
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 30), .success, "workers hung")
        contract.finish()

        XCTAssertEqual(contract.player.overlaps, 0, "two calls into the player overlapped")
        XCTAssertEqual(contract.player.callsOffTheQueue, 0, "a call arrived off the SDK's own queue")
    }

    /// 2. The SDK never calls back into the player from inside `onEvent` — `.seeking` carries its own reading
    /// as an associated value precisely so this stays absolute.
    func testThePlayerIsNeverCalledFromInsideOnEvent() {
        let everyKind: [PlayerEvent] = [.played, .seeking(from: Playhead(position: 3, duration: 100)),
                                        .seeked, .paused, .ended, .error(message: "boom"), .released]
        // One contract each: `.error` and `.released` end the viewing, and a shared one would leave every
        // event after them firing into a detached player, testing nothing.
        for event in everyKind {
            let contract = Contract(label: "no-reentrancy-\(event)")
            contract.start()
            contract.player.fire(.played)         // a live viewing, so nothing is dropped before it is read
            contract.drain()

            contract.player.fire(event)
            contract.drain()

            XCTAssertEqual(contract.player.reentrantCalls, 0, "the SDK re-entered the player on \(event)")
        }
    }

    /// 3. `onEvent` may be called from any thread, including synchronously from inside `startObserving()`.
    func testAnEventFiredFromInsideStartObservingOpensTheViewing() {
        let contract = Contract(label: "sync-replay")
        contract.player.onStartObserving = { [player = contract.player] in player.fire(.played) }

        contract.start()
        contract.drain()

        XCTAssertEqual(contract.phases, [.playing], "the replayed .played opened the viewing")
    }

    // MARK: - lifetime

    /// 4. The SDK holds the conformer for the life of the viewing.
    func testTheSDKHoldsThePlayerAfterTheCallerLetsGo() {
        let queue = DispatchQueue(label: "contract-holds-player")
        let recorder = StateLog()
        weak var weakPlayer: MockPlayer?
        var observer: PlayerObserver?

        // The only strong reference left when this scope exits is the SDK's own.
        autoreleasepool {
            let player = MockPlayer()
            player.claim(queue)
            weakPlayer = player
            observer = PlayerObserver(player: player, queue: queue, logger: nil) { recorder.record($0) }
                makePulse: { PulseTimer(interval: 3600, queue: queue, handler: $0) }
            queue.sync { observer?.start() }
        }

        XCTAssertNotNil(weakPlayer, "the SDK let the player deallocate mid-viewing")
        weakPlayer?.fire(.played)
        queue.sync {}; queue.sync {}

        XCTAssertEqual(recorder.states.map(\.phase), [.playing], "events still land after the caller let go")
        XCTAssertNotNil(observer)
    }

    /// 5. `.released` ends the viewing, closing an open play and committing `.final`.
    func testReleasedEndsTheViewing() {
        let contract = Contract(label: "released")
        contract.start()
        contract.play(from: 0, to: 20)
        contract.player.fire(.released)
        contract.drain()

        XCTAssertEqual(contract.phases, [.playing, .playing, .stopped(.untracked), .final])
        XCTAssertEqual(contract.last?.watchTime, 20)
    }

    /// 6. After `stopObserving()` the SDK ignores everything.
    func testNothingIsCommittedAfterTheSDKDetaches() {
        let contract = Contract(label: "after-detach")
        contract.start()
        contract.player.fire(.played)
        contract.drain()
        contract.finish()
        XCTAssertFalse(contract.player.isObserving, "the SDK detached")

        let statesAtDetach = contract.states.count
        [PlayerEvent.played, .seeked, .released, .error(message: nil)].forEach {
            contract.player.fire($0, detached: true)
            contract.drain()
        }

        XCTAssertEqual(contract.states.count, statesAtDetach, "no state was committed after detaching")
    }

    // MARK: - readings

    /// 7. `playhead()` is read once per event, and once per pulse while playing. `.seeking` carries its own
    /// reading and costs none; a released player is not read at all.
    func testThePlayheadIsReadOncePerEventAndOncePerTick() {
        let contract = Contract(label: "read-count")
        contract.start()
        let afterStart = contract.player.playheadCalls

        contract.player.fire(.played)
        contract.drain()
        XCTAssertEqual(contract.player.playheadCalls - afterStart, 1, "one reading for the event")

        for _ in 0..<5 { contract.tickAndDrain() }
        XCTAssertEqual(contract.player.playheadCalls - afterStart, 6, "one reading per tick, no more")

        var reads = 6
        for event in [PlayerEvent.seeked, .paused, .played, .ended] {
            contract.player.fire(event)
            contract.drain()
            reads += 1
            XCTAssertEqual(contract.player.playheadCalls - afterStart, reads, "one reading for \(event)")
        }

        contract.player.fire(.seeking(from: Playhead(position: 10, duration: 100)))
        contract.drain()
        XCTAssertEqual(contract.player.playheadCalls - afterStart, reads, "`.seeking` carries its own reading")

        contract.player.fire(.released)
        contract.drain()
        XCTAssertEqual(contract.player.playheadCalls - afterStart, reads, "a released player is not read")

        // `.error` ends the viewing, so it needs a contract of its own to be counted.
        let failing = Contract(label: "read-count-error")
        failing.start()
        failing.player.fire(.played)
        failing.drain()
        let afterPlay = failing.player.playheadCalls

        failing.player.fire(.error(message: "boom"))
        failing.drain()
        XCTAssertEqual(failing.player.playheadCalls - afterPlay, 1, "one reading for .error")
    }

    /// 8. An invalid position or duration is replaced with the last good reading, and logged every time.
    func testInvalidReadingsAreReplacedAndAlwaysLogged() {
        let contract = Contract(label: "invalid-readings")
        contract.start()
        contract.play(from: 0, to: 10)

        contract.player.position = .nan
        contract.tickAndDrain()
        contract.player.position = -5
        contract.tickAndDrain()
        contract.player.position = 10                 // good again, so only the duration is at fault below
        contract.player.duration = .infinity
        contract.tickAndDrain()

        XCTAssertEqual(contract.last?.position, 10, "the last good position stands")
        XCTAssertEqual(contract.last?.duration, 100, "the last good duration stands")
        XCTAssertEqual(contract.logger.messages(at: .error).count, 3, "one report per bad reading")
    }

    /// 9. The SDK never reads the playhead while ending a viewing on `.released`.
    func testAReleasedPlayerIsNotReadWhileEndingTheViewing() {
        let contract = Contract(label: "released-not-read")
        contract.start()
        contract.play(from: 0, to: 40)

        contract.player.position = 999                // whatever a dead player might answer
        contract.player.fire(.released)
        contract.drain()

        XCTAssertEqual(contract.last?.watchTime, 40, "the garbage reading never reached watch time")
    }

    // MARK: - events

    /// 10. Order does not matter and repeats are free for `.played`, `.paused` and `.ended`.
    func testRepeatsAndOutOfOrderEventsLandTheSameAsTheCanonicalOrder() {
        let canonical = Contract(label: "canonical")
        canonical.start()
        canonical.player.fire(.played)
        canonical.drain()
        canonical.play(from: 0, to: 10)
        canonical.player.fire(.paused)
        canonical.drain()

        let messy = Contract(label: "messy")
        messy.start()
        messy.player.fire(.paused)                    // nothing to pause
        messy.player.fire(.played)
        messy.player.fire(.played)                    // already playing
        messy.drain()
        messy.play(from: 0, to: 10)
        messy.player.fire(.paused)
        messy.player.fire(.paused)                    // already paused
        messy.drain()

        XCTAssertEqual(messy.phases, canonical.phases)
        XCTAssertEqual(messy.last?.watchTime, canonical.last?.watchTime)
    }

    /// 10, continued. The same for a play that reaches its end: `.ended` before any play is nothing to end,
    /// and a repeat of it is not a second ending.
    func testRepeatedAndOutOfOrderEndedLandsTheSameAsTheCanonicalOrder() {
        let canonical = Contract(label: "canonical-end")
        canonical.start()
        canonical.player.fire(.played)
        canonical.drain()
        canonical.play(from: 0, to: 10)
        canonical.player.fire(.ended)
        canonical.drain()

        let messy = Contract(label: "messy-end")
        messy.start()
        messy.player.fire(.ended)                     // nothing to end
        messy.player.fire(.played)
        messy.drain()
        messy.play(from: 0, to: 10)
        messy.player.fire(.ended)
        messy.player.fire(.ended)                     // already ended
        messy.drain()

        XCTAssertEqual(messy.phases, canonical.phases)
        XCTAssertEqual(messy.last?.watchTime, canonical.last?.watchTime)
    }

    /// 11. `.seeked` re-bases and never books, with or without a `.seeking` before it.
    func testSeekedRebasesWithoutBooking() {
        for name in ["seeked alone", "seeked twice"] {
            let contract = Contract(label: name)
            contract.start()
            contract.play(from: 0, to: 5)

            contract.player.position = 60
            contract.player.fire(.seeked)
            if name == "seeked twice" { contract.player.fire(.seeked) }
            contract.drain()
            contract.play(from: 60, to: 62)

            XCTAssertEqual(contract.last?.watchTime, 7, "\(name): the jump is not watch time")
            XCTAssertEqual(contract.last?.position, 62, "\(name)")
        }
    }

    /// 12. `.seeking` is optional: watch time is correct without it and exact with it.
    func testSeekingIsOptionalAndMakesWatchTimeExact() {
        for (name, sendsSeeking, expected) in [("without", false, 7.0), ("with", true, 7.5)] {
            let contract = Contract(label: "seeking-\(name)")
            contract.start()
            contract.play(from: 0, to: 5)

            contract.player.position = 5.5            // played on; no tick has sampled this yet
            if sendsSeeking { contract.player.fire(.seeking(from: contract.player.playhead())) }
            contract.player.position = 60
            contract.player.fire(.seeked)
            contract.drain()
            contract.play(from: 60, to: 62)

            XCTAssertEqual(contract.last?.watchTime, expected, "\(name) .seeking")
        }
    }

    /// 12, continued. `.seeking` is free to repeat: a second one reports the playhead before *its* seek, which
    /// is already past the first jump, so booking that delta would count the first jump as watched. Each one is
    /// answered from the value it carried, not from a fresh read — here the player has already moved on both
    /// times, so trusting its playhead would book 85 seconds that nobody watched.
    func testRepeatedSeekingBooksNothingAndIsAnsweredFromTheCarriedPlayhead() {
        let contract = Contract(label: "seeking-scrub")
        contract.start()
        contract.play(from: 0, to: 5)

        contract.player.position = 60                 // the first jump has already landed
        contract.player.fire(.seeking(from: Playhead(position: 5, duration: 100)))   // but the player reports where it left
        contract.player.position = 90                 // and the second jump lands too
        contract.player.fire(.seeking(from: Playhead(position: 60, duration: 100)))  // still scrubbing, leaving 60
        contract.player.fire(.seeked)
        contract.drain()
        contract.play(from: 90, to: 92)

        XCTAssertEqual(contract.last?.watchTime, 7, "neither jump is watch time")
        XCTAssertEqual(contract.states.map(\.position), [0, 5, 5, 60, 90, 92],
                       "each seek publishes the playhead it carried, repeats included")
    }

    /// 13. `.paused` is not for buffering: a stall costs nothing, and needs no event.
    func testAStallCostsNothingAndNeedsNoEvent() {
        let contract = Contract(label: "stall")
        contract.start()
        contract.play(from: 0, to: 10)

        for _ in 0..<5 { contract.tickAndDrain() }    // the playhead does not move: a stall

        XCTAssertEqual(contract.last?.watchTime, 10, "elapsed time during a stall is not watch time")
        XCTAssertEqual(contract.last?.phase, .playing, "and the play stays open")
    }
}

/// One observer, its queue, its player, and the states it published.
private final class Contract {
    let player = MockPlayer()
    let logger = ContractLogger()
    let queue: DispatchQueue

    private let observer: PlayerObserver
    private let recorder = StateLog()
    private let ticker = Ticker()

    init(label: String) {
        player.duration = 100
        let queue = DispatchQueue(label: "contract-\(label)")
        player.claim(queue)
        self.queue = queue

        let recorder = self.recorder
        let ticker = self.ticker
        observer = PlayerObserver(player: player, queue: queue, logger: logger) { recorder.record($0) }
            makePulse: { tick in
                ticker.tick = tick
                return PulseTimer(interval: 3600, queue: queue, handler: tick)
            }
    }

    func start() {
        queue.sync { observer.start() }
        drain()
    }

    /// Two syncs: the first waits for the work, the second for the publish that work enqueued.
    func drain() { queue.sync {}; queue.sync {} }

    func tick() { ticker.tick?() }
    func tickAndDrain() { queue.sync { tick() }; drain() }
    func finish() { queue.sync { observer.finish() }; drain() }

    /// Opens a play if one is not open, moves the playhead, and lets a tick book it.
    func play(from start: TimeInterval, to end: TimeInterval) {
        if phases.last != .playing {
            player.position = start
            player.fire(.played)
            drain()
        }
        player.position = end
        tickAndDrain()
    }

    var states: [PlayerState] { recorder.states }
    var phases: [PlayerState.Phase] { states.map(\.phase) }
    var last: PlayerState? { states.last }

    fileprivate final class Ticker {
        var tick: (() -> Void)?
    }
}

/// Records what the SDK logged. File-private so it cannot collide with the observer suite's own fake.
private final class ContractLogger: Logger, @unchecked Sendable {
    typealias LogLevel = LogLevelEnum

    var logLevel = LogLevelEnum.debug.rawValue

    private let lock = NSLock()
    private var recorded: [(level: LogLevelEnum, message: String)] = []

    func error(message: String) { record(.error, message) }
    func warn(message: String) { record(.warn, message) }
    func log(message: String) { record(.log, message) }
    func debug(message: String) { record(.debug, message) }

    func messages(at level: LogLevelEnum) -> [String] {
        lock.withLock { recorded.filter { $0.level == level }.map(\.message) }
    }

    private func record(_ level: LogLevelEnum, _ message: String) {
        lock.withLock { recorded.append((level, message)) }
    }
}

/// Records every state the observer publishes; written on the observer's queue, read from XCTest's thread.
private final class StateLog {
    private let lock = NSLock()
    private var recorded: [PlayerState] = []
    func record(_ state: PlayerState) { lock.withLock { recorded.append(state) } }
    var states: [PlayerState] { lock.withLock { recorded } }
}
