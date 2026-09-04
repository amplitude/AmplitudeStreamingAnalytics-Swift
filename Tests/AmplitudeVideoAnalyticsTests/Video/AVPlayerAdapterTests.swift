import AVFoundation
import XCTest

@testable import AmplitudeVideoAnalytics

// Scope: bare AVPlayer only (no item, no media); playback-driven events are covered by the integration tests.
final class AVPlayerAdapterTests: XCTestCase {
    func testSampleOfBarePlayerIsZeroPositionAndNilDuration() {
        let player = AVPlayer()
        let sut = AVPlayerAdapter(player)
        XCTAssertEqual(sut.sample(), PlayerSample(position: 0, duration: nil))
    }

    func testSampleIsNilAfterThePlayerIsReleased() {
        var player: AVPlayer? = AVPlayer()
        let sut = AVPlayerAdapter(player!)
        sut.startObserving { _ in }
        player = nil
        XCTAssertNil(sut.sample(), "a session must notice its player is gone while still observing")
        sut.stopObserving()
    }

    func testStartThenStopObservingDoesNotCrash() {
        let player = AVPlayer()
        let sut = AVPlayerAdapter(player)
        withExtendedLifetime(player) {
            sut.startObserving { _ in }
            sut.stopObserving()
        }
    }

    func testStopObservingWithoutStartIsSafe() {
        let sut = AVPlayerAdapter(AVPlayer())
        sut.stopObserving()
    }

    func testDoubleStartThenSingleStopIsSafe() {
        let player = AVPlayer()
        let sut = AVPlayerAdapter(player)
        withExtendedLifetime(player) {
            sut.startObserving { _ in }
            sut.startObserving { _ in }
            sut.stopObserving()
        }
    }

    func testDeinitAfterStartObservingDoesNotCrash() {
        let player = AVPlayer()
        var sut: AVPlayerAdapter? = AVPlayerAdapter(player)
        withExtendedLifetime(player) {
            sut?.startObserving { _ in }
            sut = nil
        }
    }

    func testDeinitWithoutStartObservingDoesNotCrash() {
        var sut: AVPlayerAdapter? = AVPlayerAdapter(AVPlayer())
        XCTAssertNotNil(sut)
        sut = nil
    }

    func testWaitingEmitsNothingAndPausedEmitsPaused() {
        let player = AVPlayer()
        let sut = AVPlayerAdapter(player)
        var received: [PlayerEvent] = []
        sut.startObserving { received.append($0) }

        // A bare player with no item goes to `.waitingToPlayAtSpecifiedRate` on `play()`.
        player.play()
        XCTAssertEqual(received, [])
        player.pause()
        XCTAssertEqual(received, [.paused])

        sut.stopObserving()
        player.play()
        XCTAssertEqual(received, [.paused], "nothing after teardown")
    }

    // Regression: must not register `object: nil` notification observers, or it would react to
    // notifications posted by any unrelated `AVPlayerItem` elsewhere in the process.
    func testDoesNotReactToUnrelatedPlayerItemNotifications() {
        let player = AVPlayer() // no currentItem
        let sut = AVPlayerAdapter(player)
        var receivedEvents: [PlayerEvent] = []
        withExtendedLifetime(player) {
            sut.startObserving { receivedEvents.append($0) }

            let unrelatedObject = NSObject()
            NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: unrelatedObject)
            NotificationCenter.default.post(name: .AVPlayerItemTimeJumped, object: unrelatedObject)

            XCTAssertTrue(receivedEvents.isEmpty)
            sut.stopObserving()
        }
    }
}
