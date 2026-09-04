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
        sut.startObserving()
        player = nil
        XCTAssertNil(sut.sample(), "a session must notice its player is gone while still observing")
        sut.stopObserving()
    }

    func testStartThenStopObservingDoesNotCrash() {
        let player = AVPlayer()
        let sut = AVPlayerAdapter(player)
        withExtendedLifetime(player) {
            sut.startObserving()
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
            sut.startObserving()
            sut.startObserving()
            sut.stopObserving()
        }
    }

    func testDeinitAfterStartObservingDoesNotCrash() {
        let player = AVPlayer()
        var sut: AVPlayerAdapter? = AVPlayerAdapter(player)
        withExtendedLifetime(player) {
            sut?.startObserving()
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
        sut.onEvent = { received.append($0) }
        sut.startObserving()

        // A bare player with no item goes to `.waitingToPlayAtSpecifiedRate` on `play()`.
        player.play()
        XCTAssertEqual(received, [])
        player.pause()
        XCTAssertEqual(received, [.paused])

        sut.stopObserving()
        sut.onEvent = nil
        player.play()
        XCTAssertEqual(received, [.paused], "nothing after teardown")
    }

    // Regression: `onEvent` is written by the SDK's queue while AVFoundation delivers events on its
    // own threads. Meaningful under `--sanitize=thread`; unsanitized it only catches a crash.
    func testOnEventCanBeReplacedWhileEventsAreDelivered() {
        let player = AVPlayer()
        let sut = AVPlayerAdapter(player)
        let received = LockedCounter()
        sut.onEvent = { _ in received.increment() }
        sut.startObserving()

        let replaced = expectation(description: "handler replaced repeatedly")
        DispatchQueue.global().async {
            for _ in 0..<500 {
                sut.onEvent = { _ in received.increment() }
            }
            replaced.fulfill()
        }
        for _ in 0..<500 {
            player.play()
            player.pause()
        }
        wait(for: [replaced], timeout: 10)

        sut.stopObserving()
        sut.onEvent = nil
        XCTAssertGreaterThan(received.value, 0, "the pauses must have reached some handler")
    }

    // Regression: must not register `object: nil` notification observers, or it would react to
    // notifications posted by any unrelated `AVPlayerItem` elsewhere in the process.
    func testDoesNotReactToUnrelatedPlayerItemNotifications() {
        let player = AVPlayer() // no currentItem
        let sut = AVPlayerAdapter(player)
        var receivedEvents: [PlayerEvent] = []
        sut.onEvent = { receivedEvents.append($0) }
        withExtendedLifetime(player) {
            sut.startObserving()

            let unrelatedObject = NSObject()
            NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: unrelatedObject)
            NotificationCenter.default.post(name: .AVPlayerItemTimeJumped, object: unrelatedObject)

            XCTAssertTrue(receivedEvents.isEmpty)
            sut.stopObserving()
        }
    }
}

private final class LockedCounter {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() {
        lock.withLock { count += 1 }
    }
}
