import AVFoundation
import XCTest

@testable import AmplitudeVideoAnalytics

// Scope: these tests only exercise a bare `AVPlayer()` with no item / no network media, so they
// stay CI- and simulator-safe. Real playback-driven event emission (`.played` / `.ended` / etc.
// from actual media) is NOT unit-tested here — it is covered by the demo app (Task 9b).
final class AVPlayerVideoPlayerTests: XCTestCase {
    func testDurationIsNilForBarePlayer() {
        let sut = AVPlayerVideoPlayer(AVPlayer())
        XCTAssertNil(sut.duration)
    }

    func testCurrentTimeIsZeroForBarePlayer() {
        let sut = AVPlayerVideoPlayer(AVPlayer())
        XCTAssertEqual(sut.currentTime, 0)
    }

    func testStartThenStopObservingDoesNotCrash() {
        let sut = AVPlayerVideoPlayer(AVPlayer())
        sut.startObserving()
        sut.stopObserving()
    }

    func testStopObservingWithoutStartIsSafe() {
        let sut = AVPlayerVideoPlayer(AVPlayer())
        sut.stopObserving()
    }

    func testDoubleStartThenSingleStopIsSafe() {
        let sut = AVPlayerVideoPlayer(AVPlayer())
        sut.startObserving()
        sut.startObserving()
        sut.stopObserving()
    }

    func testDeinitAfterStartObservingDoesNotCrash() {
        var sut: AVPlayerVideoPlayer? = AVPlayerVideoPlayer(AVPlayer())
        sut?.startObserving()
        sut = nil
    }

    func testDeinitWithoutStartObservingDoesNotCrash() {
        var sut: AVPlayerVideoPlayer? = AVPlayerVideoPlayer(AVPlayer())
        XCTAssertNotNil(sut)
        sut = nil
    }

    func testOnEventIsSettableAndClearedSafelyOnTeardown() {
        let player = AVPlayer()
        let sut = AVPlayerVideoPlayer(player)
        var receivedEvents: [VideoPlayerEvent] = []
        sut.onEvent = { receivedEvents.append($0) }
        sut.startObserving()

        // A bare player with no item transitions to `.waitingToPlayAtSpecifiedRate` on `play()`,
        // so this proves `onEvent` is actually wired up (not just settable) before teardown.
        player.play()
        XCTAssertEqual(receivedEvents, [.buffering])

        sut.stopObserving()
        sut.onEvent = nil

        // No further events after teardown, even though `play()` already changed player state.
        player.pause()
        XCTAssertEqual(receivedEvents, [.buffering])
    }

    /// Regression test: when the player has no `currentItem` at `startObserving()` time, this
    /// instance must not register `object: nil` notification observers — otherwise it would react
    /// to `.AVPlayerItemDidPlayToEndTime` / `.AVPlayerItemTimeJumped` notifications posted by any
    /// unrelated `AVPlayerItem` elsewhere in the process.
    func testDoesNotReactToUnrelatedPlayerItemNotifications() {
        let sut = AVPlayerVideoPlayer(AVPlayer()) // no currentItem
        var receivedEvents: [VideoPlayerEvent] = []
        sut.onEvent = { receivedEvents.append($0) }
        sut.startObserving()

        // A plain, unrelated object standing in for "some other AVPlayerItem elsewhere in the
        // process" — NotificationCenter matches by object identity, not type, so this is
        // sufficient to prove `sut` isn't registered with `object: nil` without touching any
        // real media.
        let unrelatedObject = NSObject()
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: unrelatedObject)
        NotificationCenter.default.post(name: .AVPlayerItemTimeJumped, object: unrelatedObject)

        XCTAssertTrue(receivedEvents.isEmpty)
        sut.stopObserving()
    }
}
