import XCTest

@testable import AmplitudeVideoAnalytics

/// How `stream_duration` is accrued, and what the `.seeking` anchor-drop does and does not cover.
///
/// The anchor-drop assumes `.seeking` reaches the session before anything else samples the
/// playhead. Nothing enforces that: `.seeking` arrives via `queue.async` while `player.sample()`
/// reads the playhead live, and under `AVPlayerAdapter` the two signals that race here originate
/// on different threads — `.paused` from KVO on `timeControlStatus`, `.seeking` from an
/// `AVPlayerItemTimeJumped` notification.
///
/// Tests marked CHARACTERIZATION record behaviour that is currently wrong. They are written to
/// pass today so the suite stays green, and each one says what its assertion becomes once fixed.
final class VideoSessionAccrualTests: XCTestCase {

    // MARK: - the ordering the anchor-drop assumes

    func testSeekingBeforeTheStopExcludesTheJump() {
        let harness = VideoSessionHarness(label: "seek-ordered", duration: 600)
        harness.onQueue {
            harness.session.handle(.played)          // position 0
            harness.player.position = 10
            harness.session.refresh()                // 10s genuinely watched
            harness.session.handle(.seeking)         // anchor dropped first
            harness.player.position = 500
            harness.session.handle(.paused)
        }
        XCTAssertEqual(harness.lastStreamDuration, 10, "the scrub is excluded")
    }

    func testTicksWithoutTimeJumpsAccrueEveryDelta() {
        let harness = VideoSessionHarness(label: "ticks", duration: 600)
        harness.onQueue {
            harness.session.handle(.played)
            for tick in 1...10 {
                harness.player.position = TimeInterval(tick) * 5
                harness.session.refresh()
            }
            harness.session.handle(.paused)
        }
        XCTAssertEqual(harness.lastStreamDuration, 50)
    }

    // MARK: - CHARACTERIZATION: the ordering is not guaranteed

    /// Scrub-then-pause is the everyday trigger: the user drags the scrubber (the playhead jumps)
    /// and the app pauses. `.paused` and `.seeking` are delivered on two different threads and
    /// each hops onto the session queue independently, so whichever enqueues first wins. When
    /// `.paused` wins, `handleStop` samples the post-jump playhead and books the whole jump.
    ///
    /// FIX: stop relying on cross-event ordering. Clamping each delta to wall-clock elapsed
    /// (× rate) is immune to delivery order and subsumes the existing negative clamp. This test
    /// then asserts 10 — the same as `testSeekingBeforeTheStopExcludesTheJump`.
    func testCharacterization_seekingAfterTheStopBooksTheJumpAsWatchTime() {
        let harness = VideoSessionHarness(label: "seek-raced", duration: 600)
        harness.onQueue {
            harness.session.handle(.played)          // position 0
            harness.player.position = 10
            harness.session.refresh()                // 10s genuinely watched
            harness.player.position = 500            // user scrubs to 8:20
            harness.session.handle(.paused)          // .paused hop wins the race
            harness.session.handle(.seeking)         // .seeking hop arrives too late
        }
        XCTAssertEqual(harness.lastStreamDuration, 500,
                       "CHARACTERIZATION: 490s of scrub booked as watch time; the truth is 10")
    }

    /// The anchor-drop never banks the pending delta, it discards it. One time jump per tick
    /// therefore accrues nothing at all — the shape a live stream would produce if it posts
    /// `AVPlayerItemTimeJumped` at least once per pulse.
    ///
    /// FIX: the same wall-clock clamp. This test then asserts 50, matching
    /// `testTicksWithoutTimeJumpsAccrueEveryDelta`.
    func testCharacterization_aTimeJumpPerTickAccruesNothing() {
        let harness = VideoSessionHarness(label: "jump-storm", duration: 600)
        harness.onQueue {
            harness.session.handle(.played)
            for tick in 1...10 {
                harness.player.position = TimeInterval(tick) * 5
                harness.session.handle(.seeking)
                harness.session.refresh()
            }
            harness.session.handle(.paused)
        }
        XCTAssertEqual(harness.lastStreamDuration, 0,
                       "CHARACTERIZATION: 50s watched, 0s reported")
    }

    // MARK: - CHARACTERIZATION: errors outside a play

    /// `handle(.error)` guards on `isPlaying`, which is justified as browser parity for an error
    /// before the first play. It also swallows an error *after* a pause: nothing is emitted and
    /// the session stays open until `stop()` or the player vanishing.
    ///
    /// FIX: if the parity rule is really "before the first play", guard on `playId.isEmpty`
    /// instead. This test then asserts a fourth event and `isFinal == true`.
    func testCharacterization_errorWhilePausedIsSwallowedAndLeavesTheSessionOpen() {
        let harness = VideoSessionHarness(label: "error-paused")
        harness.onQueue {
            harness.session.handle(.played)
            harness.player.position = 20
            harness.session.handle(.paused)
            harness.session.handle(.error(message: "network died while paused"))
        }

        XCTAssertEqual(harness.emitted.count, 3, "CHARACTERIZATION: the error emits nothing")
        XCTAssertFalse(harness.session.isFinal, "CHARACTERIZATION: the session survives a fatal error")
        XCTAssertEqual(harness.finalizedCount, 0)
    }

    /// Contrast, and the behaviour the guard is actually there for.
    func testErrorBeforeTheFirstPlayIsIgnoredWithoutEndingTheSession() {
        let harness = VideoSessionHarness(label: "error-first")
        harness.onQueue { harness.session.handle(.error(message: "boom")) }

        XCTAssertTrue(harness.emitted.isEmpty)
        XCTAssertFalse(harness.session.isFinal)
    }
}
