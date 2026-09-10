import AVFoundation
import XCTest

@testable import AmplitudeVideoAnalytics

// Scope: bare AVPlayer only (no item, no media); playback-driven events are covered by the integration tests.
final class AVPlayerAdapterTests: XCTestCase {
    func testPlayheadOfBarePlayerIsZeroPositionAndNilDuration() {
        let player = AVPlayer()
        let sut = AVPlayerAdapter(player)
        XCTAssertEqual(sut.playhead(), Playhead(position: 0, duration: nil))
    }

    func testReleasingThePlayerEmitsReleased() {
        let events = EventRecorder()
        let released = expectation(description: "released")
        // The pool drains the references AVFoundation autoreleased while the player was being set up.
        let sut = autoreleasepool { () -> AVPlayerAdapter in
            var player: AVPlayer? = AVPlayer()
            let adapter = AVPlayerAdapter(player!)
            adapter.startObserving { event in
                events.record(event)
                if event == .released { released.fulfill() }
            }
            player = nil
            return adapter
        }

        wait(for: [released], timeout: 2)
        XCTAssertEqual(events.events, [.released])
        XCTAssertEqual(sut.playhead(), Playhead(position: 0, duration: nil))
        sut.stopObserving()
    }

    func testStopObservingBeforeReleaseEmitsNothing() {
        let events = EventRecorder()
        let unexpectedEvent = expectation(description: "no events after stopObserving before release")
        unexpectedEvent.isInverted = true
        autoreleasepool {
            var player: AVPlayer? = AVPlayer()
            let adapter = AVPlayerAdapter(player!)
            adapter.startObserving { event in
                events.record(event)
                unexpectedEvent.fulfill()
            }
            adapter.stopObserving()
            player = nil
        }

        wait(for: [unexpectedEvent], timeout: 0.3)
        XCTAssertTrue(events.events.isEmpty)
    }

    func testTwoAdaptersOnOnePlayerDoNotCrossFireReleased() {
        let player = AVPlayer()
        let firstEvents = EventRecorder()
        let firstReleased = expectation(description: "first adapter fires .released")
        firstReleased.isInverted = true
        let first = AVPlayerAdapter(player)
        let second = AVPlayerAdapter(player)
        withExtendedLifetime(player) {
            first.startObserving { event in
                firstEvents.record(event)
                if event == .released { firstReleased.fulfill() }
            }
            second.startObserving { _ in }
            second.stopObserving()
        }

        wait(for: [firstReleased], timeout: 0.3)
        XCTAssertTrue(firstEvents.events.isEmpty)
        first.stopObserving()
    }

    func testStartObservingOnAReleasedPlayerReportsReleased() {
        let events = EventRecorder()
        let sut = autoreleasepool { () -> AVPlayerAdapter in
            var player: AVPlayer? = AVPlayer()
            let adapter = AVPlayerAdapter(player!)
            player = nil
            return adapter
        }

        // AVFoundation completes a player's last release asynchronously, so the weak reference can
        // still be alive when `startObserving` runs; `.released` may only arrive afterward.
        let released = expectation(description: "released")
        sut.startObserving { event in
            events.record(event)
            if event == .released { released.fulfill() }
        }
        wait(for: [released], timeout: 2)
        XCTAssertEqual(events.events, [.released])
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

            XCTAssertTrue(receivedEvents.isEmpty)
            sut.stopObserving()
        }
    }
}

/// Events are emitted from the adapter's queue or the releasing thread but read back from the test thread.
private final class EventRecorder {
    private let lock = NSLock()
    private var recorded: [PlayerEvent] = []
    func record(_ event: PlayerEvent) { lock.withLock { recorded.append(event) } }
    var events: [PlayerEvent] { lock.withLock { recorded } }
}
