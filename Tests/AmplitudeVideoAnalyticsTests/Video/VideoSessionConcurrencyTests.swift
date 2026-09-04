import XCTest

@testable import AmplitudeVideoAnalytics

/// Threading and lifetime behaviour of ``VideoSession``.
///
/// `Player` may be called on any thread and may fire `onEvent` on any thread; the session is the
/// player's only consumer and touches it from one queue, so the player's own storage is what has
/// to tolerate the crossing. These tests pin down what that buys and where it stops.
///
/// Tests marked CHARACTERIZATION record behaviour that is currently wrong. They are written to
/// pass today so the suite stays green, and each one says what its assertion becomes once fixed.
final class VideoSessionConcurrencyTests: XCTestCase {

    // MARK: - what the confinement does buy

    func testConcurrentPlayerEventsAndStopFinalizeExactlyOnce() {
        for iteration in 0..<200 {
            let harness = VideoSessionHarness(label: "stress-\(iteration)")
            harness.onQueue { harness.session.start() }

            let group = DispatchGroup()
            for worker in 0..<6 {
                DispatchQueue.global().async(group: group) {
                    for step in 0..<20 {
                        harness.player.position = TimeInterval(step)
                        switch (worker + step) % 5 {
                        case 0: harness.player.fire(.played)
                        case 1: harness.player.fire(.paused)
                        case 2: harness.player.fire(.seeking)
                        case 3: harness.queue.async { harness.session.refresh() }
                        default: harness.player.fire(.ended)
                        }
                    }
                }
            }
            DispatchQueue.global().async(group: group) {
                Thread.sleep(forTimeInterval: 0.0005)
                harness.session.stop()
            }

            XCTAssertEqual(group.wait(timeout: .now() + 10), .success, "iteration \(iteration) hung")
            harness.drain()

            XCTAssertEqual(harness.finalizedCount, 1, "iteration \(iteration): onFinal fires exactly once")
            XCTAssertEqual(harness.player.stopObservingCount, 1,
                           "iteration \(iteration): the player is detached exactly once")
            XCTAssertTrue(harness.session.isFinal)
        }
    }

    /// `stop()` hops with `queue.sync`, so it is safe from a thread that is *not* the session's
    /// queue — player callbacks included, since those reach the session with `queue.async`.
    func testStopFromAPlayerCallbackThreadDoesNotBlockForever() {
        let harness = VideoSessionHarness(label: "callback-thread")
        harness.onQueue { harness.session.start() }

        let finished = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            // Stands in for AVFoundation delivering on its own thread.
            harness.player.fire(.played)
            harness.session.stop()
            finished.signal()
        }

        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success,
                       "stop() from a player-callback thread must not deadlock")
        harness.drain()
        XCTAssertTrue(harness.session.isFinal)
    }

    /// The flip side: `queue.sync` means the caller waits for whatever else the queue is doing.
    /// Apps call `stop()` from `viewWillDisappear`/`deinit` on the main thread.
    func testStopBlocksTheCallerUntilTheQueueDrains() {
        let harness = VideoSessionHarness(label: "blocking")
        harness.queue.async { Thread.sleep(forTimeInterval: 0.2) }

        let start = Date()
        harness.session.stop()
        let blocked = Date().timeIntervalSince(start)

        XCTAssertGreaterThan(blocked, 0.15,
                             "stop() is synchronous: its latency is whatever the shared queue owes")
    }

    /// In-flight player events cannot jump ahead of a `stop()` that was requested after them,
    /// and anything arriving afterwards is dropped rather than emitted.
    func testEventsArrivingAfterStopAreDropped() {
        let harness = VideoSessionHarness(label: "after-stop")
        harness.onQueue { harness.session.start() }
        harness.onQueue { harness.session.handle(.played) }

        harness.session.stop()
        let afterStop = harness.emitted.count

        harness.player.fire(.played)
        harness.player.fire(.paused)
        harness.drain()

        XCTAssertEqual(harness.emitted.count, afterStop, "a final session emits nothing further")
        XCTAssertEqual(harness.finalizedCount, 1)
    }

    // MARK: - CHARACTERIZATION: start() does not check isFinal

    /// `start()` is the only queue-confined entry point without a `!isFinal` guard, so a `start()`
    /// that lands after a `stop()` re-attaches the player to a dead session. `handle` then drops
    /// everything as final and nothing ever calls `stopObserving()` again: the player is observed
    /// forever, producing nothing.
    ///
    /// FIX: `guard !isFinal else { return }` at the top of `start()`. This test then becomes
    /// `XCTAssertNil(player.onEvent)` and `XCTAssertEqual(player.startObservingCount, 0)`.
    func testCharacterization_startOnAFinalSessionReArmsThePlayer() {
        let harness = VideoSessionHarness(label: "restart")
        harness.onQueue { harness.session.handle(.played) }
        harness.session.stop()

        XCTAssertTrue(harness.session.isFinal)
        XCTAssertNil(harness.player.onEvent, "stop() detached the player")
        XCTAssertEqual(harness.player.stopObservingCount, 1)

        harness.onQueue { harness.session.start() }

        XCTAssertTrue(harness.session.isFinal, "still final")
        XCTAssertNotNil(harness.player.onEvent, "CHARACTERIZATION: handler re-installed on a dead session")
        XCTAssertEqual(harness.player.startObservingCount, 1, "CHARACTERIZATION: observation restarted")
        XCTAssertEqual(harness.player.stopObservingCount, 1, "CHARACTERIZATION: never torn down again")

        let before = harness.emitted.count
        harness.player.fire(.played)
        harness.drain()
        XCTAssertEqual(harness.emitted.count, before, "observed for nothing")
    }

    // MARK: - CHARACTERIZATION: dropping the handle

    /// `VideoSession` has no `deinit`, so releasing the last reference mid-play emits no
    /// `untracked` stop and never calls `onFinal` — the owner keeps a dead registry entry and the
    /// open row waits out the server TTL. This is at odds with "you do not need to keep this
    /// handle" in the type's own doc comment.
    ///
    /// FIX: either a `deinit` that finalizes, or a doc comment saying the owner holds the session
    /// until it is final. This test then asserts a third emitted event with `stop_reason:
    /// untracked` and `finalizedCount == 1`.
    func testCharacterization_droppingTheSessionMidPlayStrandsTheOpenRow() {
        var harness: VideoSessionHarness? = VideoSessionHarness(label: "dropped")
        harness!.onQueue {
            harness!.session.start()
            harness!.session.handle(.played)
        }
        let emittedBeforeDrop = harness!.emitted.count
        let finalizedBeforeDrop = harness!.finalizedCount
        weak let weakSession = harness!.session

        harness = nil

        XCTAssertNil(weakSession, "no retain cycle: the session does deallocate")
        XCTAssertEqual(emittedBeforeDrop, 2, "the snapshot and the start, nothing else")
        XCTAssertEqual(finalizedBeforeDrop, 0, "CHARACTERIZATION: onFinal never fires")
    }

    // MARK: - re-entrancy (opt-in: these crash the process)

    /// `stop()` is `queue.sync`, and `onEmit`/`onFinal` both run *on that queue*. Calling `stop()`
    /// from either does not deadlock — libdispatch traps the process:
    ///
    ///     EXC_BREAKPOINT (SIGTRAP)
    ///     BUG IN CLIENT OF LIBDISPATCH: dispatch_sync called on queue already owned by current thread
    ///
    /// Verified 2026-09-04 against 76c6219 by running each of these alone and reading the crash
    /// report. They cannot run in the normal suite because they take the test process with them.
    ///
    ///     PROBE_CRASH=1 swift test --filter testReentrantStopFromOnEmitTrapsTheProcess
    ///
    /// FIX: make `stop()` async, or detect re-entrancy, rather than documenting it. Note the
    /// current doc comment on `stop()` names `Player` callbacks as the hazard — those are the one
    /// caller that is safe (see `testStopFromAPlayerCallbackThreadDoesNotBlockForever`).
    func testReentrantStopFromOnEmitTrapsTheProcess() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PROBE_CRASH"] != nil,
                          "crashes the test process; run deliberately with PROBE_CRASH=1")
        let harness = VideoSessionHarness(label: "reentrant-emit")
        harness.session.onEmit = { [weak session = harness.session] _, _ in session?.stop() }
        harness.onQueue { harness.session.handle(.played) }
        XCTFail("unreachable: the dispatch_sync above traps")
    }

    func testReentrantStopFromOnFinalTrapsTheProcess() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PROBE_CRASH"] != nil,
                          "crashes the test process; run deliberately with PROBE_CRASH=1")
        let harness = VideoSessionHarness(label: "reentrant-final")
        harness.session.onFinal = { [weak session = harness.session] in session?.stop() }
        harness.session.stop()
        XCTFail("unreachable: the dispatch_sync above traps")
    }
}
