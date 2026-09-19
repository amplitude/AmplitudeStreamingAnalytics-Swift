import AVFoundation
import XCTest
import AmplitudeSwift

@testable import AmplitudeStreamingAnalytics

// MARK: - Finding 1: teardown() cannot be overridden (SDK limitation)
// BasePlugin.teardown() is `public` not `open`, so external plugins cannot override it.
// Finalization happens in deinit, which captures sessions and transport by value before
// dispatching async. This test verifies the deinit path works correctly.

final class DeinitFinalizationTests: XCTestCase {

    /// deinit emits final stop events for active sessions via the captured transport.
    func testDeinitEmitsFinalStopEvents() {
        let uploader = FakeDelayedEventsUploader()
        uploader.autoSettle = .success(DelayedResponseBody(id: "d", expiration: 1, flushed: nil))
        let amplitude = Amplitude(configuration: Configuration(
            apiKey: "deinit-\(UUID().uuidString)",
            instanceName: "deinit-\(UUID().uuidString)",
            autocapture: [], offline: true))
        let config = StreamingAnalyticsConfig()
        let configuration = DelayedEventsConfiguration(pulseInterval: 0.05, ttlMs: 1_234)
        let tracker = DelayedEventTracker(amplitudeConfiguration: amplitude.configuration,
                                          configuration: configuration,
                                          httpClient: uploader,
                                          snapshots: makeSnapshotStore())
        let transport = DelayedEvents(amplitude: amplitude, configuration: configuration, tracker: tracker)

        let player = FakePlayer()

        autoreleasepool {
            let plugin = StreamingAnalyticsPlugin(config: config,
                                                  delayedEventsFactory: { _, _ in transport },
                                                  pulseTimerFactory: PulseTimer.init)
            amplitude.add(plugin: plugin)
            plugin.trackPlayer(player: player, content: PlayerContent())
            player.fire(.played)

            let arrived = expectation(description: "play arrived")
            uploader.whenUploadArrives(matching: { !$0.events.isEmpty }, notify: { arrived.fulfill() })
            wait(for: [arrived], timeout: 5)

            amplitude.remove(plugin: plugin)
        }

        let finalStop = expectation(description: "final stop uploaded")
        uploader.whenUploadArrives(matching: isUntrackedStop, notify: { finalStop.fulfill() })
        wait(for: [finalStop], timeout: 5)
    }
}

/// The closing event a viewing sends when it ends without the player saying why.
func isUntrackedStop(_ body: DelayedRequestBody) -> Bool {
    body.instantEvents?.contains { $0.eventProperties?["stop_reason"] as? String == "untracked" } == true
}

// MARK: - Finding 2 (fixed): finish() safe from the serial queue
// The previous session type self-dispatched finish() onto its own queue so it could be called
// safely from anywhere. PlayerObserver drops that wrapper: finish() is documented as "called on
// queue by the owner", so the owner (here, the test) is the one that confines the call to `queue`.

final class StopDeadlockTests: XCTestCase {

    /// finish() called from a block already running on the queue must complete without deadlocking.
    func testFinishCalledFromTheQueueDoesNotDeadlock() {
        let queue = DispatchQueue(label: "com.amplitude.streamingAnalytics.test")
        let player = FakePlayer()
        player.duration = 100
        var published: [PlayerState] = []
        let observer = PlayerObserver(player: player, queue: queue, pulseInterval: 3600) { published.append($0) }
        queue.sync { observer.start() }
        player.fire(.played)
        queue.sync {} // drain the play event

        let completed = expectation(description: "finish completed")

        queue.async {
            observer.finish()
            completed.fulfill()
        }

        wait(for: [completed], timeout: 2.0)
        queue.sync {}
        XCTAssertEqual(published.last?.phase, .final, "observer finalized after finish() from within the queue")
    }

    /// finish() called via queue.sync from an external thread still works correctly.
    func testFinishCalledFromExternalThread() {
        let queue = DispatchQueue(label: "com.amplitude.streamingAnalytics.external")
        let player = FakePlayer()
        player.duration = 100
        var published: [PlayerState] = []
        let observer = PlayerObserver(player: player, queue: queue, pulseInterval: 3600) { published.append($0) }
        queue.sync { observer.start() }
        player.fire(.played)
        queue.sync {} // drain

        queue.sync { observer.finish() }
        queue.sync {} // drain the publishes finish() enqueued
        XCTAssertEqual(published.last?.phase, .final, "observer finalized after finish() from an external thread")
    }
}

// MARK: - Finding 3 (fixed): stopObserving() clears onEvent, no isEmitting needed

final class StopObservingClearsOnEventTests: XCTestCase {

    /// After finish(), `end()` has called `stopObserving()`, so the player drops its handler and later events never
    /// reach the observer; a `.final` observer would drop them anyway.
    func testNoEventsLeakAfterFinish() {
        let player = FakePlayer()
        let queue = DispatchQueue(label: "test.emit.fix")
        var changeCount = 0
        let observer = PlayerObserver(player: player, queue: queue, pulseInterval: 3600) { _ in changeCount += 1 }

        queue.sync { observer.start() }
        player.fire(.played)
        queue.sync {}
        queue.sync {} // second drain: waits for the async publish commit() enqueued while handling .played

        queue.sync { observer.finish() }
        queue.sync {} // second drain: waits for finish()'s own async publish before reading the count
        let countAfterFinish = changeCount

        player.fire(.played)
        queue.sync {}
        queue.sync {}

        XCTAssertEqual(changeCount, countAfterFinish,
                       "No events should leak after finish()")
    }

    /// A finished observer must deallocate once its owner drops it: nothing the plugin hands `onChange`
    /// may close over the observer strongly, or the viewing outlives the player it was tracking.
    /// The reference is dropped by assignment, not by scope: once a closure has captured a local, a debug
    /// build can keep it alive to the end of the function and the weak check would pass for the wrong reason.
    func testFinishedObserverDeallocatesWhenItsOwnerDropsIt() {
        let player = FakePlayer()
        let queue = DispatchQueue(label: "test.release")
        weak var released: PlayerObserver?

        var observer: PlayerObserver? = PlayerObserver(player: player, queue: queue, pulseInterval: 3600) { _ in }
        released = observer
        queue.sync { observer?.start() }
        player.fire(.played)
        queue.sync {}
        queue.sync {}
        queue.sync { observer?.finish() }
        queue.sync {}
        observer = nil

        XCTAssertNil(released, "onChange must not keep the finished observer alive via a self-reference")
    }
}

// MARK: - Finding 5 (documented): KVO auto-cleanup on player dealloc

final class KVOAutoCleanupTests: XCTestCase {

    /// When the AVPlayer deallocates before stopObserving(), iOS 11+ automatically
    /// deregisters KVO observations. The adapter and observer rely on this guarantee.
    func testInvalidateDoesNotCrashWhenPlayerIsGone() {
        var player: AVPlayer? = AVPlayer()
        let adapter = AVPlayerAdapter(player!)

        adapter.startObserving { _ in }

        player = nil

        // iOS 11+ auto-deregisters KVO when the observed object deallocates.
        // invalidate() sees player == nil and returns early — no crash.
        adapter.stopObserving()

        XCTAssertEqual(adapter.playhead().position, 0,
                       "Player is gone; playhead() reports the last known reading instead of crashing")
    }
}

// MARK: - Finding 6: deinit off-queue reads (SDK limitation — no teardown override)
// BasePlugin.teardown() is `public` not `open`, so finalization can only happen in deinit.
// The deinit reads sessions/transport off-queue then dispatches async to finalize.
// This is safe because no other reference can mutate those properties at deinit time.

final class DeinitOffQueueReadTests: XCTestCase {

    /// deinit captures sessions and transport, then dispatches finalization async.
    /// This verifies the capture-and-dispatch pattern completes without crashing.
    func testDeinitCaptureAndDispatchWorks() {
        let uploader = FakeDelayedEventsUploader()
        uploader.autoSettle = .success(DelayedResponseBody(id: "d", expiration: 1, flushed: nil))
        let amplitude = Amplitude(configuration: Configuration(
            apiKey: "offqueue-\(UUID().uuidString)",
            instanceName: "offqueue-\(UUID().uuidString)",
            autocapture: [], offline: true))
        var config = StreamingAnalyticsConfig()
        config.sampleInterval = 3600
        let configuration = DelayedEventsConfiguration(pulseInterval: 0.05, ttlMs: 1_234)
        let tracker = DelayedEventTracker(amplitudeConfiguration: amplitude.configuration,
                                          configuration: configuration,
                                          httpClient: uploader,
                                          snapshots: makeSnapshotStore())
        let transport = DelayedEvents(amplitude: amplitude, configuration: configuration, tracker: tracker)

        let player = FakePlayer()

        autoreleasepool {
            let plugin = StreamingAnalyticsPlugin(config: config,
                                                  delayedEventsFactory: { _, _ in transport },
                                                  pulseTimerFactory: PulseTimer.init)
            amplitude.add(plugin: plugin)
            plugin.trackPlayer(player: player, content: PlayerContent())
            player.fire(.played)

            let arrived = expectation(description: "play arrived")
            uploader.whenUploadArrives(matching: { !$0.events.isEmpty }, notify: { arrived.fulfill() })
            wait(for: [arrived], timeout: 5)

            amplitude.remove(plugin: plugin)
        }

        let finalStop = expectation(description: "final stop uploaded")
        uploader.whenUploadArrives(matching: isUntrackedStop, notify: { finalStop.fulfill() })
        wait(for: [finalStop], timeout: 5)
    }
}

// MARK: - Finding 7 (refuted): setup/trackPlayer race — no real window

final class SetupTrackPlayerRaceTests: XCTestCase {

    /// DelayedEvents adds itself to the timeline in its init, so the transport is
    /// ready by the time setup() returns. This is a regression test confirming it.
    func testTransportIsReadyAfterSetup() {
        let amplitude = Amplitude(configuration: Configuration(
            apiKey: "race-\(UUID().uuidString)",
            instanceName: "race-\(UUID().uuidString)",
            autocapture: [], offline: true))
        let plugin = StreamingAnalyticsPlugin()
        amplitude.add(plugin: plugin)

        // Observed rather than read off the plugin: `track` registers a viewing only when the
        // transport is already there, so a live count is the transport's readiness.
        let player = FakePlayer()
        plugin.trackPlayer(player: player, content: PlayerContent())

        XCTAssertEqual(plugin.activeSessionCount, 1, "transport is set after setup, so the viewing registered")
    }
}
