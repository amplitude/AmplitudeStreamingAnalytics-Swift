import XCTest

@testable import AmplitudeVideoAnalytics

final class PlayerObserverTests: XCTestCase {

    // MARK: - phases

    func testFirstPlayEntersPlayingAtThePosition() {
        let harness = PlayerObserverHarness(label: "first-play")
        harness.player.position = 10
        harness.handle(.played)

        XCTAssertEqual(harness.phases, [.playing])
        XCTAssertEqual(harness.last?.position, 10)
        XCTAssertEqual(harness.last?.duration, 100)
        XCTAssertEqual(harness.last?.watchTime, 0)
    }

    func testSignalsThatDoNotFitThePhaseAreIgnoredAndLogged() {
        let harness = PlayerObserverHarness(label: "ignored")
        harness.handle(.paused)                      // nothing to pause
        XCTAssertTrue(harness.states.isEmpty)
        XCTAssertEqual(harness.observer.state.phase, .idle)

        harness.handle(.played)
        harness.handle(.played)                      // already playing
        harness.handle(.paused)
        harness.refresh()                            // a tick while stopped publishes nothing

        XCTAssertEqual(harness.phases, [.playing, .stopped(.paused)])
        XCTAssertEqual(harness.logger.messages(at: .debug).count, 2, "the two dropped events, not the idle tick")
    }

    func testPauseClosesThePlayWithItsWatchTime() {
        let harness = PlayerObserverHarness(label: "pause")
        harness.handle(.played)
        harness.play(30)
        harness.handle(.paused)

        XCTAssertEqual(harness.phases, [.playing, .stopped(.paused)])
        XCTAssertEqual(harness.last?.position, 30)
        XCTAssertEqual(harness.last?.watchTime, 30)
    }

    func testEndedThenPlayedIsAReplayAndWatchTimeIsCumulative() {
        let harness = PlayerObserverHarness(label: "replay")
        harness.handle(.played)
        harness.play(100)
        harness.handle(.ended)
        harness.player.position = 0                  // a replay rewinds
        harness.handle(.played)
        harness.play(20)
        harness.handle(.paused)

        XCTAssertEqual(harness.phases, [.playing, .stopped(.ended), .playing, .stopped(.paused)])
        XCTAssertEqual(harness.last?.watchTime, 120)
    }

    // MARK: - accrual

    func testTicksPublishTheReadingAndAccrue() {
        let harness = PlayerObserverHarness(label: "ticks")
        harness.handle(.played)
        for _ in 1...10 {
            harness.play(5)
            harness.refresh()
        }

        XCTAssertEqual(harness.states.count, 11)
        XCTAssertEqual(harness.last?.phase, .playing)
        XCTAssertEqual(harness.last?.position, 50)
        XCTAssertEqual(harness.last?.watchTime, 50)
    }

    func testSeekingExcludesTheJumpAndNothingElse() {
        let harness = PlayerObserverHarness(label: "seek")
        harness.handle(.played)
        harness.play(5)
        harness.refresh()
        harness.handle(.seekStarted)
        harness.player.position = 60
        harness.handle(.seekEnded)
        harness.play(2)
        harness.refresh()

        XCTAssertEqual(harness.last?.watchTime, 7)
        XCTAssertEqual(harness.phases, Array(repeating: .playing, count: 5), "no new phase from seeking alone")
        XCTAssertEqual(harness.states.map(\.isSeeking), [false, false, true, false, false])
    }

    func testTicksWhileSeekingMovePositionAndBookNothing() {
        let harness = PlayerObserverHarness(label: "seek-tick")
        harness.handle(.played)
        harness.play(5)
        harness.refresh()
        harness.handle(.seekStarted)
        harness.player.position = 60
        harness.refresh()

        XCTAssertEqual(harness.last?.position, 60)
        XCTAssertEqual(harness.last?.watchTime, 5, "the tick moves position but books no watch time")
        XCTAssertEqual(harness.last?.isSeeking, true)
    }

    func testSeekEndedWithoutStartIsIgnored() {
        let harness = PlayerObserverHarness(label: "seek-end-only")
        harness.handle(.played)
        harness.play(5)
        harness.refresh()
        harness.handle(.seekEnded)

        XCTAssertEqual(harness.states.count, 2, "a seekEnded without a start publishes nothing")
        XCTAssertEqual(harness.last?.watchTime, 5)
        XCTAssertEqual(harness.logger.messages(at: .debug).count, 1)
    }

    func testDuplicateSeekStartedIsIgnored() {
        let harness = PlayerObserverHarness(label: "duplicate-seek-started")
        harness.handle(.played)
        harness.handle(.seekStarted)
        let statesAfterFirstSeekStarted = harness.states.count
        harness.handle(.seekStarted)

        XCTAssertEqual(harness.states.count, statesAfterFirstSeekStarted, "a duplicate seekStarted publishes nothing")
        XCTAssertEqual(harness.last?.isSeeking, true)

        harness.handle(.seekEnded)

        XCTAssertEqual(harness.states.count, statesAfterFirstSeekStarted + 1)
        XCTAssertEqual(harness.last?.isSeeking, false)
    }

    func testPlayedClearsSeeking() {
        let harness = PlayerObserverHarness(label: "played-clears-seeking")
        harness.handle(.played)
        harness.play(5)
        harness.refresh()
        harness.handle(.paused)
        harness.handle(.seekStarted)                  // a seek can start while paused
        harness.player.position = 60
        harness.handle(.played)
        harness.play(3)
        harness.refresh()
        let statesBeforeLateSeekEnded = harness.states.count
        harness.handle(.seekEnded)                    // late: .played already cleared isSeeking

        XCTAssertEqual(harness.states.count, statesBeforeLateSeekEnded, "the late seekEnded publishes nothing")
        XCTAssertEqual(harness.last?.isSeeking, false)
        XCTAssertEqual(harness.last?.watchTime, 8, "accrual continued once .played cleared seeking")
    }

    func testPauseWhileSeekingClosesAndClearsSeeking() {
        let harness = PlayerObserverHarness(label: "pause-while-seeking")
        harness.handle(.played)
        harness.play(5)
        harness.refresh()
        harness.handle(.seekStarted)
        harness.player.position = 60
        harness.handle(.paused)

        XCTAssertEqual(harness.phases, [.playing, .playing, .playing, .stopped(.paused)])
        XCTAssertEqual(harness.last?.position, 60)
        XCTAssertEqual(harness.last?.watchTime, 5, "the in-flight seek is not booked")
        XCTAssertEqual(harness.last?.isSeeking, false)
    }

    func testBackwardsMovementIsNotWatchTime() {
        let harness = PlayerObserverHarness(label: "backwards")
        harness.handle(.played)
        harness.play(5)
        harness.refresh()
        harness.player.position = 2
        harness.refresh()
        XCTAssertEqual(harness.last?.watchTime, 5)

        harness.play(3)
        harness.refresh()
        XCTAssertEqual(harness.last?.watchTime, 8, "accrual resumes from the new position")
    }

    // MARK: - errors

    func testErrorWhilePlayingClosesWithTheMessageAndFinishes() {
        let harness = PlayerObserverHarness(label: "error-playing")
        harness.handle(.played)
        harness.play(20)
        harness.handle(.error(message: "boom"))

        XCTAssertEqual(harness.phases, [.playing, .stopped(.error(message: "boom")), .final])
        XCTAssertEqual(harness.states[1].watchTime, 20)
        XCTAssertEqual(harness.player.stopObservingCount, 1)
        XCTAssertNil(harness.player.onEvent)
        XCTAssertEqual(harness.logger.messages(at: .error).count, 1)
        XCTAssertTrue(harness.logger.messages(at: .error)[0].contains("boom"))
    }

    /// Browser parity: with no open play there is nothing to attach the error to.
    func testErrorWhileNotPlayingIsLoggedAndIgnored() {
        let harness = PlayerObserverHarness(label: "error-idle")
        harness.handle(.error(message: "bad url"))
        XCTAssertTrue(harness.states.isEmpty)

        harness.handle(.played)
        harness.handle(.paused)
        harness.handle(.error(message: nil))
        XCTAssertEqual(harness.phases, [.playing, .stopped(.paused)])
        XCTAssertEqual(harness.logger.messages(at: .error).count, 2)
    }

    // MARK: - readings

    func testInvalidReadingsAreReplacedAndEachIsReported() {
        let harness = PlayerObserverHarness(label: "bad-readings")
        harness.handle(.played)
        harness.play(5)
        harness.refresh()

        harness.player.position = .nan
        harness.refresh()
        XCTAssertEqual(harness.last?.position, 5, "the last good position stands")
        XCTAssertEqual(harness.last?.watchTime, 5)

        harness.player.position = -1
        harness.player.duration = .infinity
        harness.refresh()
        XCTAssertEqual(harness.last?.position, 5)
        XCTAssertEqual(harness.last?.duration, 100, "the last good duration stands")

        harness.player.position = 10
        harness.player.duration = 100
        harness.refresh()
        XCTAssertEqual(harness.last?.watchTime, 10, "accrual picks up from the last good reading")
        XCTAssertEqual(harness.last?.duration, 100)

        XCTAssertEqual(harness.logger.messages(at: .error).count, 3, "one report per bad reading")
    }

    // MARK: - the player goes away

    func testReleasedWhilePlayingClosesUntrackedAtTheLastReadingThenEnds() {
        let harness = PlayerObserverHarness(label: "released-playing")
        harness.handle(.played)
        harness.play(40)
        harness.handle(.released)

        XCTAssertEqual(harness.phases, [.playing, .stopped(.untracked), .final])
        XCTAssertEqual(harness.states[1].position, 40)
        XCTAssertEqual(harness.states[1].watchTime, 40)
        XCTAssertEqual(harness.player.stopObservingCount, 1)
    }

    func testReleasedWhileStoppedEndsOnly() {
        let harness = PlayerObserverHarness(label: "released-stopped")
        harness.handle(.played)
        harness.handle(.paused)
        harness.handle(.released)

        XCTAssertEqual(harness.phases, [.playing, .stopped(.paused), .final])
        XCTAssertEqual(harness.player.stopObservingCount, 1)
    }

    func testPlayedAfterReleasedIsDropped() {
        let harness = PlayerObserverHarness(label: "played-after-released")
        harness.handle(.played)
        harness.handle(.released)
        let statesAfterReleased = harness.states.count

        harness.handle(.played)

        XCTAssertEqual(harness.states.count, statesAfterReleased, "no new states after .final")
        XCTAssertEqual(harness.player.startObservingCount, 1)
    }

    // MARK: - the pulse

    func testThePulseBooksReadingsOnItsOwn() {
        let harness = PlayerObserverHarness(label: "pulse", pulseInterval: 0.05)
        harness.handle(.played)

        let deadline = Date().addingTimeInterval(0.3)
        while Date() < deadline {
            harness.play(0.01)
            Thread.sleep(forTimeInterval: 0.01)
        }
        harness.drain()

        XCTAssertGreaterThan(harness.last?.watchTime ?? 0, 0, "the pulse booked watch time on its own")
    }

    func testThePulseStopsWhenPlaybackStops() {
        let harness = PlayerObserverHarness(label: "pulse-stops", pulseInterval: 0.05)
        harness.handle(.played)
        harness.play(1)
        harness.handle(.paused)

        let statesAfterPause = harness.states.count
        Thread.sleep(forTimeInterval: 0.3)

        XCTAssertEqual(harness.states.count, statesAfterPause, "no ticks commit while paused")
    }

    func testStartTwiceAttachesOnce() {
        let harness = PlayerObserverHarness(label: "start-twice", pulseInterval: 0.05)
        harness.onQueue { harness.observer.start() }

        XCTAssertEqual(harness.player.startObservingCount, 1, "the second start() is a no-op")

        harness.finish()
        let statesAfterFinish = harness.states.count
        Thread.sleep(forTimeInterval: 0.2)

        XCTAssertEqual(harness.states.count, statesAfterFinish, "no pulse from the second start() survived to fire")
    }

    // MARK: - finish and lifetime

    func testFinishWhilePlayingClosesUntrackedAndIsIdempotent() {
        let harness = PlayerObserverHarness(label: "finish")
        harness.handle(.played)
        harness.finish()
        harness.finish()

        XCTAssertEqual(harness.phases, [.playing, .stopped(.untracked), .final])
        XCTAssertEqual(harness.player.stopObservingCount, 1)
    }

    func testFinishWithNoOpenPlayPublishesOnlyFinal() {
        let harness = PlayerObserverHarness(label: "finish-idle")
        harness.finish()

        XCTAssertEqual(harness.phases, [.final])
        XCTAssertEqual(harness.player.stopObservingCount, 1)
    }

    func testAFinalObserverIsDetachedAndIgnoresTicksAndStart() {
        let harness = PlayerObserverHarness(label: "after-final", started: false)
        harness.onQueue { harness.observer.start() }
        harness.handle(.played)
        harness.finish()
        XCTAssertNil(harness.player.onEvent, "finish() detached the player")

        harness.handle(.played)
        harness.refresh()
        harness.onQueue { harness.observer.start() }

        XCTAssertEqual(harness.phases, [.playing, .stopped(.untracked), .final])
        XCTAssertEqual(harness.player.startObservingCount, 1, "observation is not restarted")
        XCTAssertNil(harness.player.onEvent)
    }

    func testStartWiresEventsThroughTheQueueAndSurvivesASynchronousReplay() {
        let harness = PlayerObserverHarness(label: "wiring", started: false)
        harness.player.onStartObserving = { [player = harness.player] in player.fire(.played) }

        harness.onQueue { harness.observer.start() }
        harness.drain()

        XCTAssertEqual(harness.player.startObservingCount, 1)
        XCTAssertEqual(harness.phases, [.playing], "the replayed .played opened the viewing")
    }
}
