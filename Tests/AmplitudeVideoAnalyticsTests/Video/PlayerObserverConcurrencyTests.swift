import XCTest

@testable import AmplitudeVideoAnalytics

/// `Player` may fire on any thread; the observer hops every event onto the owner's queue and is the only
/// thing that calls the player.
final class PlayerObserverConcurrencyTests: XCTestCase {

    func testConcurrentPlayerEventsAndFinishFinalizeExactlyOnce() {
        for iteration in 0..<200 {
            let harness = PlayerObserverHarness(label: "stress-\(iteration)", started: false)
            harness.onQueue { harness.observer.start() }

            let group = DispatchGroup()
            for worker in 0..<6 {
                DispatchQueue.global().async(group: group) {
                    for step in 0..<20 {
                        harness.player.position = TimeInterval(step)
                        switch (worker + step) % 5 {
                        case 0: harness.player.fire(.played)
                        case 1: harness.player.fire(.paused)
                        case 2: harness.player.fire(.seeking)
                        case 3: harness.queue.async { harness.tick() }
                        default: harness.player.fire(.ended)
                        }
                    }
                }
            }
            DispatchQueue.global().async(group: group) {
                Thread.sleep(forTimeInterval: 0.0005)
                harness.queue.async { harness.observer.finish() }
            }

            XCTAssertEqual(group.wait(timeout: .now() + 10), .success, "iteration \(iteration) hung")
            harness.drain()

            XCTAssertEqual(harness.finalizedCount, 1, "iteration \(iteration): .final exactly once")
            XCTAssertEqual(harness.player.startObservingCount, 1, "iteration \(iteration): attached exactly once")
            XCTAssertEqual(harness.player.stopObservingCount, 1, "iteration \(iteration): detached exactly once")
            XCTAssertEqual(harness.last?.phase, .final, "iteration \(iteration): .final published last")
        }
    }

    /// `onChange` fires only after the transition that produced it has returned, so re-entering the observer
    /// from inside it is safe: a `finish()` called from there still reaches `.final` exactly once.
    func testOnChangeRunsAfterTheTransitionReturns() {
        let harness = PlayerObserverHarness(label: "after-transition")
        harness.onEveryState { [weak observer = harness.observer] state in
            guard state.phase == .playing else { return }      // the one commit this test triggers
            observer?.finish()
        }

        harness.handle(.played)
        harness.drain()                               // let the finish() called from the hook publish

        XCTAssertEqual(harness.finalizedCount, 1)
        XCTAssertEqual(harness.player.stopObservingCount, 1)
    }

    func testDroppingTheOwnerReleasesTheObserver() {
        var harness: PlayerObserverHarness? = PlayerObserverHarness(label: "dropped", started: false)
        harness?.onQueue { harness?.observer.start() }
        harness?.handle(.played)
        // Assigned separately: `weak let` is rejected before Swift 6.2.
        weak var weakObserver: PlayerObserver?
        weakObserver = harness?.observer

        harness = nil

        XCTAssertNil(weakObserver, "no retain cycle through the player's handler or onChange")
    }
}
