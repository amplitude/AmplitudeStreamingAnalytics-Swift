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
        let sut = AVPlayerVideoPlayer(AVPlayer())
        var receivedEvents: [VideoPlayerEvent] = []
        sut.onEvent = { receivedEvents.append($0) }
        sut.startObserving()
        sut.stopObserving()
        sut.onEvent = nil
        XCTAssertTrue(receivedEvents.isEmpty)
    }
}
