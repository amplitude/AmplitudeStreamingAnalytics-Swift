import XCTest

@testable import AmplitudeVideoAnalytics

/// How `stream_duration` is accrued.
///
/// Watch time is playhead advance bounded by what playback could have covered in the wall time
/// between two readings. That bound is what excludes a jump, and it holds no matter when — or
/// whether — a `.seeking` event turns up, which matters because events fired on different threads
/// reach the session's queue in no particular order.
final class VideoSessionAccrualTests: XCTestCase {

    func testPlaybackAccruesEveryTick() {
        let harness = VideoSessionHarness(label: "ticks", duration: 600)
        harness.onQueue {
            harness.session.handle(.played)
            for _ in 1...10 {
                harness.play(forSeconds: 5)
                harness.session.refresh()
            }
            harness.session.handle(.paused)
        }
        XCTAssertEqual(harness.lastStreamDuration, 50)
    }

    // MARK: - jumps are excluded because they outrun wall time

    func testScrubIsExcludedWhenSeekingArrivesFirst() {
        let harness = VideoSessionHarness(label: "seek-ordered", duration: 600)
        harness.onQueue {
            harness.session.handle(.played)
            harness.play(forSeconds: 10)
            harness.session.refresh()
            harness.session.handle(.seeking)
            harness.scrub(to: 500)
            harness.session.handle(.paused)
        }
        XCTAssertEqual(harness.lastStreamDuration, 10, "only the 10s actually watched")
    }

    /// The case that used to book the whole scrub as watch time. `.paused` and `.seeking` are
    /// delivered on two different threads under `AVPlayerAdapter` — KVO on `timeControlStatus`
    /// and an `AVPlayerItemTimeJumped` notification — so `.paused` can reach the queue first.
    /// The result must not depend on which one wins.
    func testScrubIsExcludedEvenWhenSeekingArrivesAfterTheStop() {
        let harness = VideoSessionHarness(label: "seek-raced", duration: 600)
        harness.onQueue {
            harness.session.handle(.played)
            harness.play(forSeconds: 10)
            harness.session.refresh()
            harness.scrub(to: 500)                   // user scrubs to 8:20
            harness.session.handle(.paused)          // .paused hop wins the race
            harness.session.handle(.seeking)         // .seeking hop arrives too late to help
        }
        XCTAssertEqual(harness.lastStreamDuration, 10, "the 490s jump is not watch time")
    }

    /// And with no seek signal at all — the shape a live stream produces if it never posts one.
    func testScrubIsExcludedWithNoSeekingEventAtAll() {
        let harness = VideoSessionHarness(label: "seek-absent", duration: 600)
        harness.onQueue {
            harness.session.handle(.played)
            harness.play(forSeconds: 10)
            harness.session.refresh()
            harness.scrub(to: 500)
            harness.session.handle(.paused)
        }
        XCTAssertEqual(harness.lastStreamDuration, 10)
    }

    /// A time jump before every tick used to discard all accrual, because the anchor was dropped
    /// and the pending delta went with it. Nothing is discarded now; only the jump is excluded.
    func testATimeJumpPerTickStillAccruesTheWatchedTime() {
        let harness = VideoSessionHarness(label: "jump-storm", duration: 600)
        harness.onQueue {
            harness.session.handle(.played)
            for _ in 1...10 {
                harness.play(forSeconds: 5)
                harness.session.handle(.seeking)
                harness.session.refresh()
            }
            harness.session.handle(.paused)
        }
        XCTAssertEqual(harness.lastStreamDuration, 50, "50s watched, 50s reported")
    }

    func testBackwardsMovementIsNeverNegative() {
        let harness = VideoSessionHarness(label: "backwards", duration: 600)
        harness.onQueue {
            harness.session.handle(.played)
            harness.play(forSeconds: 5)
            harness.session.refresh()
            harness.scrub(to: 2)
            harness.session.refresh()
        }
        XCTAssertEqual(harness.lastStreamDuration, 5)
    }

    /// Time passing while paused is not watch time, and does not enlarge the next allowance
    /// beyond what the playhead actually covered.
    func testTimePassingWhilePausedIsNotWatchTime() {
        let harness = VideoSessionHarness(label: "paused-gap", duration: 600)
        harness.onQueue {
            harness.session.handle(.played)
            harness.play(forSeconds: 10)
            harness.session.handle(.paused)
            harness.wait(seconds: 300)
            harness.session.handle(.played)
            harness.play(forSeconds: 5)
            harness.session.handle(.paused)
        }
        XCTAssertEqual(harness.lastStreamDuration, 15, "10s + 5s, not the 300s spent paused")
    }

    /// Faster-than-realtime playback must not be clipped by the clamp.
    func testDoubleRatePlaybackAccruesTheFullPlayheadAdvance() {
        let harness = VideoSessionHarness(label: "2x", duration: 600)
        harness.player.rate = 2
        harness.onQueue {
            harness.session.handle(.played)
            harness.clock.advance(10)
            harness.scrub(to: 20)        // 10s of wall time, 20s of playhead at 2x
            harness.session.refresh()
            harness.session.handle(.paused)
        }
        XCTAssertEqual(harness.lastStreamDuration, 20)
    }

    // MARK: - errors

    /// An error after the first play ends the session whether or not a play is currently open.
    func testErrorWhilePausedEndsTheSession() {
        let harness = VideoSessionHarness(label: "error-paused")
        harness.onQueue {
            harness.session.handle(.played)
            harness.play(forSeconds: 20)
            harness.session.handle(.paused)
            harness.session.handle(.error(message: "network died while paused"))
        }

        XCTAssertEqual(harness.emitted.count, 3, "the row was already finalized by the pause")
        XCTAssertTrue(harness.session.isFinal, "but the session is over")
        XCTAssertEqual(harness.finalizedCount, 1)
    }

    func testErrorWhilePlayingFinalizesWithTheMessage() {
        let harness = VideoSessionHarness(label: "error-playing")
        harness.onQueue {
            harness.session.handle(.played)
            harness.play(forSeconds: 20)
            harness.session.handle(.error(message: "boom"))
        }

        XCTAssertEqual(harness.stopReason(at: 2), "error")
        XCTAssertEqual(harness.emitted[2].eventProperties?["error_message"] as? String, "boom")
        XCTAssertTrue(harness.session.isFinal)
    }

    /// Nothing has played, so there is no row to finalize and nothing to report.
    func testErrorBeforeTheFirstPlayIsIgnoredWithoutEndingTheSession() {
        let harness = VideoSessionHarness(label: "error-first")
        harness.onQueue { harness.session.handle(.error(message: "boom")) }

        XCTAssertTrue(harness.emitted.isEmpty)
        XCTAssertFalse(harness.session.isFinal)
    }
}
