import AVFoundation
import XCTest

@testable import AmplitudeVideoAnalytics

// Scope: bare AVPlayer only (no item, no media); playback-driven events are covered by the integration tests.
final class AVPlayerAdapterTests: XCTestCase {
    private let deliveryQueue = DispatchQueue(label: "test.delivery")

    /// Barrier: every event the adapter has already enqueued has run by the time this returns.
    private func flush() {
        deliveryQueue.sync {}
    }

    func testSampleOfBarePlayerIsZeroPositionAndNilDuration() {
        let player = AVPlayer()
        let sut = AVPlayerAdapter(player)
        XCTAssertEqual(sut.sample(), PlayerSample(position: 0, duration: nil))
    }

    func testSampleIsNilAfterThePlayerIsReleased() {
        var player: AVPlayer? = AVPlayer()
        let sut = AVPlayerAdapter(player!)
        deliveryQueue.sync { sut.startObserving(deliveryQueue: deliveryQueue) }
        player = nil
        deliveryQueue.sync {
            XCTAssertNil(sut.sample(), "a session must notice its player is gone while still observing")
            sut.stopObserving()
        }
    }

    func testStartThenStopObservingDoesNotCrash() {
        let player = AVPlayer()
        let sut = AVPlayerAdapter(player)
        withExtendedLifetime(player) {
            deliveryQueue.sync {
                sut.startObserving(deliveryQueue: deliveryQueue)
                sut.stopObserving()
            }
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
            deliveryQueue.sync {
                sut.startObserving(deliveryQueue: deliveryQueue)
                sut.startObserving(deliveryQueue: deliveryQueue)
                sut.stopObserving()
            }
        }
    }

    func testDeinitAfterStartObservingDoesNotCrash() {
        let player = AVPlayer()
        var sut: AVPlayerAdapter? = AVPlayerAdapter(player)
        withExtendedLifetime(player) {
            deliveryQueue.sync { sut?.startObserving(deliveryQueue: deliveryQueue) }
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
        deliveryQueue.sync { sut.startObserving(deliveryQueue: deliveryQueue) }

        // A bare player with no item goes to `.waitingToPlayAtSpecifiedRate` on `play()`.
        player.play()
        flush()
        XCTAssertEqual(deliveryQueue.sync { received }, [])
        player.pause()
        flush()
        XCTAssertEqual(deliveryQueue.sync { received }, [.paused])

        deliveryQueue.sync { sut.stopObserving() }
        player.play()
        flush()
        XCTAssertEqual(deliveryQueue.sync { received }, [.paused], "nothing after teardown")
    }

    // The Model 2 guarantee: an event reaching the queue after `stopObserving()` is dropped by
    // construction, not by a narrow race. Model 1 measured 7 late deliveries out of 49,501 here.
    func testNoEventArrivesAfterStopObserving() {
        var lateEvents = 0
        for _ in 0..<200 {
            let player = AVPlayer()
            let sut = AVPlayerAdapter(player)
            var stopped = false
            sut.onEvent = { _ in if stopped { lateEvents += 1 } }
            deliveryQueue.sync { sut.startObserving(deliveryQueue: deliveryQueue) }

            let churn = DispatchQueue(label: "churn")
            let done = expectation(description: "churn")
            churn.async {
                for _ in 0..<400 {
                    player.play()
                    player.pause()
                }
                done.fulfill()
            }
            Thread.sleep(forTimeInterval: 0.002)
            deliveryQueue.sync {
                sut.stopObserving()
                stopped = true
            }
            wait(for: [done], timeout: 20)
            flush()
        }
        XCTAssertEqual(deliveryQueue.sync { lateEvents }, 0)
    }

    // Regression: must not register `object: nil` notification observers, or it would react to
    // notifications posted by any unrelated `AVPlayerItem` elsewhere in the process.
    func testDoesNotReactToUnrelatedPlayerItemNotifications() {
        let player = AVPlayer() // no currentItem
        let sut = AVPlayerAdapter(player)
        var receivedEvents: [PlayerEvent] = []
        sut.onEvent = { receivedEvents.append($0) }
        withExtendedLifetime(player) {
            deliveryQueue.sync { sut.startObserving(deliveryQueue: deliveryQueue) }

            let unrelatedObject = NSObject()
            NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: unrelatedObject)
            NotificationCenter.default.post(name: .AVPlayerItemTimeJumped, object: unrelatedObject)

            flush()
            XCTAssertTrue(deliveryQueue.sync { receivedEvents }.isEmpty)
            deliveryQueue.sync { sut.stopObserving() }
        }
    }
}
