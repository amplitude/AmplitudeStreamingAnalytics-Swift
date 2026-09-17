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
        XCTAssertTrue(harness.states.isEmpty, "nothing published means nothing left idle")

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

    /// `.seeked` alone keeps watch time correct; `.seeking` makes it exact, because its reading predates the jump
    /// and so recovers the half second played since the last pulse. Same viewing, same jump, both ways.
    func testSeekingRecoversThePlayBetweenTheLastPulseAndTheJump() {
        for (name, sendsSeeking, expected) in [("seeked only", false, 7.0), ("seeking first", true, 7.5)] {
            let harness = PlayerObserverHarness(label: "seek-\(name)")
            harness.handle(.played)
            harness.play(5)
            harness.refresh()
            harness.play(0.5)                         // played on; no pulse has sampled this yet
            if sendsSeeking { harness.handle(.seeking(from: harness.player.playhead())) }
            harness.player.position = 60              // the jump
            harness.handle(.seeked)
            harness.play(2)
            harness.refresh()

            XCTAssertEqual(harness.last?.watchTime, expected, "\(name)")
            XCTAssertEqual(harness.last?.position, 62, "\(name)")
            XCTAssertEqual(harness.phases, Array(repeating: .playing, count: harness.states.count),
                           "\(name): a seek never moves the phase")
        }
    }

    /// A second `.seeking` reports the playhead before *its* seek, which is already past the first jump. Booking
    /// that delta would count the first jump as watched.
    func testASecondSeekingDoesNotBookTheFirstJump() {
        let harness = PlayerObserverHarness(label: "seek-scrub")
        harness.handle(.played)
        harness.play(5)
        harness.refresh()
        harness.handle(.seeking(from: harness.player.playhead()))   // pre-jump, at 5
        harness.player.position = 60                                // the first jump lands
        harness.handle(.seeking(from: harness.player.playhead()))   // still scrubbing: pre-jump for the second, at 60
        harness.player.position = 90
        harness.handle(.seeked)
        harness.play(2)
        harness.refresh()

        XCTAssertEqual(harness.last?.watchTime, 7, "neither jump is watch time")
        XCTAssertEqual(harness.last?.position, 92)
        // A repeat is free, not dropped: it publishes its re-based position so a consumer does not go stale
        // mid-scrub. Only the accrual is suppressed, which the watch time above pins.
        XCTAssertEqual(harness.states.map(\.position), [0, 5, 5, 60, 90, 92])
        XCTAssertEqual(harness.states.map(\.watchTime), [0, 5, 5, 5, 5, 7])
    }

    /// The pulse books nothing mid-seek and does not end the seek; only an event does.
    func testATickDuringASeekBooksNothingAndLeavesTheSeekOpen() {
        let harness = PlayerObserverHarness(label: "seek-tick")
        harness.handle(.played)
        harness.play(5)
        harness.refresh()
        harness.handle(.seeking(from: harness.player.playhead()))
        harness.player.position = 60
        harness.refresh()

        XCTAssertEqual(harness.last?.watchTime, 5, "the tick does not book the jump")
        XCTAssertEqual(harness.last?.position, 60, "but it does move position")

        harness.player.position = 70
        harness.refresh()
        XCTAssertEqual(harness.last?.watchTime, 5, "still seeking: a later tick books nothing either")

        harness.handle(.seeked)
        harness.play(2)
        harness.refresh()
        XCTAssertEqual(harness.last?.watchTime, 7, "the seek ended and accrual resumed")
    }

    /// A seek before the first play publishes nothing — there is no play to re-base — and the play that
    /// follows still books only what it watches, because nothing accrues out of `.idle`.
    func testASeekBeforeTheFirstPlayPublishesNothingAndCostsNothing() {
        let harness = PlayerObserverHarness(label: "seek-before-play")
        harness.player.position = 60
        harness.handle(.seeking(from: harness.player.playhead()))
        harness.handle(.seeked)

        XCTAssertTrue(harness.states.isEmpty, "no .idle payload reaches the consumer")

        harness.handle(.played)
        harness.play(2)
        harness.refresh()

        XCTAssertEqual(harness.phases, [.playing, .playing])
        XCTAssertEqual(harness.last?.position, 62)
        XCTAssertEqual(harness.last?.watchTime, 2, "the 60s jump before the play is not watch time")
    }

    /// Any event ends the seek, so an unmatched `.seeking` cannot stall accrual past the next thing the player says.
    func testAnEventDuringASeekBooksNothingAndEndsTheSeek() {
        let harness = PlayerObserverHarness(label: "seek-interrupted")
        harness.handle(.played)
        harness.play(5)
        harness.refresh()
        harness.handle(.seeking(from: harness.player.playhead()))
        harness.player.position = 60
        harness.handle(.paused)                       // lands before `.seeked` ever does

        XCTAssertEqual(harness.last?.watchTime, 5, "the jump is not watch time")
        XCTAssertEqual(harness.last?.position, 60)

        harness.handle(.played)
        harness.play(3)
        harness.refresh()
        XCTAssertEqual(harness.last?.watchTime, 8, "the pause ended the seek; accrual resumed")
    }

    /// `.seeking` is answered from the playhead it carries, so a player that seeks the instant it emits — legal,
    /// the contract only asks that `.seeking` be sent first — still measures exactly. Reading the player back
    /// after the event hopped onto the queue booked the whole jump: 62s for a viewing that watched 7.5s.
    func testSeekingIsAnsweredFromItsPayloadEvenWhenThePlayerMovesAtOnce() {
        let harness = PlayerObserverHarness(label: "seek-carried")
        harness.handle(.played)
        harness.play(5)
        harness.refresh()

        harness.play(0.5)
        harness.player.fire(.seeking(from: harness.player.playhead()))  // fired, not yet handled
        harness.player.position = 60                                    // it moves before the queue runs
        harness.drain()

        harness.handle(.seeked)
        harness.play(2)
        harness.refresh()

        XCTAssertEqual(harness.last?.watchTime, 7.5, "the jump is not booked; the 0.5s before it is")
    }

    /// An event the phase drops still ends the seek, so it has to publish its re-based position too. Dropping
    /// it left `state` behind the jump with the seek closed, and the next pulse booked the whole jump.
    func testAnIgnoredEventEndsTheSeekAndStillRebases() {
        let harness = PlayerObserverHarness(label: "seek-ignored")
        harness.handle(.played)
        harness.play(5)
        harness.refresh()
        harness.handle(.seeking(from: harness.player.playhead()))
        harness.player.position = 60
        harness.handle(.played)                       // already playing: no transition, but the seek is over

        XCTAssertEqual(harness.last?.position, 60, "the jump landed in the published state")
        XCTAssertEqual(harness.last?.watchTime, 5, "and cost nothing")

        harness.play(2)
        harness.refresh()
        XCTAssertEqual(harness.last?.watchTime, 7, "the next tick books only what played after the jump")
    }

    func testSeekedWhileStoppedRebasesWithoutBooking() {
        let harness = PlayerObserverHarness(label: "seek-while-stopped")
        harness.handle(.played)
        harness.play(5)
        harness.refresh()
        harness.handle(.paused)
        harness.player.position = 60                  // a seek while paused
        harness.handle(.seeked)
        harness.handle(.played)
        harness.play(3)
        harness.refresh()

        XCTAssertEqual(harness.phases, [.playing, .playing, .stopped(.paused), .stopped(.paused), .playing, .playing])
        XCTAssertEqual(harness.last?.watchTime, 8, "5 before the seek, 3 after; the jump is not watched")
    }

    func testPauseAfterASeekClosesAtTheRebasedPosition() {
        let harness = PlayerObserverHarness(label: "pause-after-seek")
        harness.handle(.played)
        harness.play(5)
        harness.refresh()
        harness.player.position = 60
        harness.handle(.seeked)
        harness.handle(.paused)

        XCTAssertEqual(harness.phases, [.playing, .playing, .playing, .stopped(.paused)])
        XCTAssertEqual(harness.last?.position, 60)
        XCTAssertEqual(harness.last?.watchTime, 5, "the jump is not booked by the seek or by the pause after it")
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

    /// An error ends the viewing whatever the phase — a player that has failed is done. With no open play
    /// there is nothing to close, so the viewing goes straight to `.final`.
    func testErrorBeforeAnyPlayEndsTheViewingWithNoStop() {
        let harness = PlayerObserverHarness(label: "error-idle")
        harness.handle(.error(message: "bad url"))

        XCTAssertEqual(harness.phases, [.final], "nothing to close, but the viewing is over")
        XCTAssertEqual(harness.player.stopObservingCount, 1)
        XCTAssertEqual(harness.logger.messages(at: .error).count, 1)
        XCTAssertTrue(harness.logger.messages(at: .error)[0].contains("bad url"))
    }

    func testErrorWhileStoppedEndsTheViewingWithoutReopeningThePlay() {
        let harness = PlayerObserverHarness(label: "error-paused")
        harness.handle(.played)
        harness.play(5)
        harness.handle(.paused)
        harness.handle(.error(message: nil))

        XCTAssertEqual(harness.phases, [.playing, .stopped(.paused), .final],
                       "the pause stands as the play's reason; the error only ends the viewing")
        XCTAssertEqual(harness.last?.watchTime, 5)
        XCTAssertEqual(harness.logger.messages(at: .error).count, 1)
        XCTAssertTrue(harness.logger.messages(at: .error)[0].contains("no message"))
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
        harness.refresh()                             // the pulse: the last reading taken while it was alive
        harness.play(0.5)                             // played on, then died before the next pulse
        harness.handle(.released)

        XCTAssertEqual(harness.phases, [.playing, .playing, .stopped(.untracked), .final])
        XCTAssertEqual(harness.states[2].position, 40)
        XCTAssertEqual(harness.states[2].watchTime, 40, "playback since the last reading is not recovered")
        XCTAssertEqual(harness.player.stopObservingCount, 1)
    }

    /// The contract asks a released player to answer from its cache, but cannot enforce it. Nothing is read from
    /// a player that has said it is gone, so whatever it would have answered cannot reach watch time.
    func testAReleasedPlayerIsNeverRead() {
        let harness = PlayerObserverHarness(label: "released-garbage")
        harness.handle(.played)
        harness.play(40)
        harness.refresh()
        harness.player.position = 999                 // a conformer answering garbage once it is gone
        harness.handle(.released)

        XCTAssertEqual(harness.states[2].position, 40, "closed at the last reading taken while it was alive")
        XCTAssertEqual(harness.states[2].watchTime, 40)
        XCTAssertEqual(harness.last?.phase, .final)
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
