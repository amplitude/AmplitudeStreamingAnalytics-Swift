import XCTest

@testable import AmplitudeVideoAnalytics

/// Threading and lifetime behaviour of ``VideoSession``.
///
/// `Player` may be called on any thread and may fire `onEvent` on any thread; the session is the
/// player's only consumer and touches it from one queue, so the player's own storage is what has
/// to tolerate the crossing. These tests pin down what that buys.
///
/// `stop()` hops with `queue.async`, so these drain the queue before asserting.
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

    /// `stop()` is safe from any thread, player-callback threads included.
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

    /// `stop()` used to be `queue.sync`, which stalled the caller behind unrelated queue work.
    /// Apps call it from `viewWillDisappear`/`deinit` on the main thread, so it must not block.
    func testStopDoesNotBlockTheCallerBehindQueueWork() {
        let harness = VideoSessionHarness(label: "non-blocking")
        harness.queue.async { Thread.sleep(forTimeInterval: 0.3) }

        let start = Date()
        harness.session.stop()
        let blocked = Date().timeIntervalSince(start)

        XCTAssertLessThan(blocked, 0.1, "stop() returns immediately, it does not wait on the queue")
        harness.drain()
        XCTAssertTrue(harness.session.isFinal, "and the session is finalized once the queue gets there")
    }

    /// `stop()` from the session's own queue is exactly what `queue.sync` used to trap on.
    /// `onEmit` and `onFinal` both run there, so this has to be ordinary.
    func testStopFromTheSessionQueueIsSafe() {
        let harness = VideoSessionHarness(label: "reentrant")
        harness.session.onEmit = { [weak session = harness.session] _ in session?.stop() }

        harness.onQueue { harness.session.handle(.played) }
        harness.drain()

        XCTAssertTrue(harness.session.isFinal)
        XCTAssertEqual(harness.finalizedCount, 1)
    }

    /// The same from `onFinal`, which runs inside `finish()` itself.
    func testStopFromInsideOnFinalIsSafe() {
        let harness = VideoSessionHarness(label: "reentrant-final")
        let finals = Counter()
        harness.session.onFinal = { [weak session = harness.session] in
            finals.increment()
            session?.stop()
        }

        harness.session.stop()
        harness.drain()
        harness.drain()   // the re-entrant stop enqueues one more hop

        XCTAssertTrue(harness.session.isFinal)
        XCTAssertEqual(finals.value, 1, "the re-entrant stop is a no-op, not a second finalize")
    }

    private final class Counter {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    /// In-flight player events cannot jump ahead of a `stop()` that was requested after them,
    /// and anything arriving afterwards is dropped rather than emitted.
    func testEventsArrivingAfterStopAreDropped() {
        let harness = VideoSessionHarness(label: "after-stop")
        harness.onQueue { harness.session.start() }
        harness.onQueue { harness.session.handle(.played) }

        harness.session.stop()
        harness.drain()
        let afterStop = harness.emitted.count

        harness.player.fire(.played)
        harness.player.fire(.paused)
        harness.drain()

        XCTAssertEqual(harness.emitted.count, afterStop, "a final session emits nothing further")
        XCTAssertEqual(harness.finalizedCount, 1)
    }

    // MARK: - start() after stop()

    /// `stop()` is public and can land at any moment, so a `start()` that follows it must not
    /// re-attach the player to a dead session — that would observe forever, produce nothing, and
    /// never be torn down again.
    func testStartOnAFinalSessionDoesNothing() {
        let harness = VideoSessionHarness(label: "restart")
        harness.onQueue { harness.session.handle(.played) }
        harness.session.stop()
        harness.drain()

        XCTAssertTrue(harness.session.isFinal)
        XCTAssertNil(harness.player.onEvent, "stop() detached the player")
        XCTAssertEqual(harness.player.stopObservingCount, 1)

        harness.onQueue { harness.session.start() }

        XCTAssertNil(harness.player.onEvent, "the player stays detached")
        XCTAssertEqual(harness.player.startObservingCount, 0, "observation is not restarted")
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
        // Assigned separately: `weak let` is rejected before Swift 6.2.
        weak var weakSession: VideoSession?
        weakSession = harness!.session

        harness = nil

        XCTAssertNil(weakSession, "no retain cycle: the session does deallocate")
        XCTAssertEqual(emittedBeforeDrop, 2, "the snapshot and the start, nothing else")
        XCTAssertEqual(finalizedBeforeDrop, 0, "CHARACTERIZATION: onFinal never fires")
    }

}
