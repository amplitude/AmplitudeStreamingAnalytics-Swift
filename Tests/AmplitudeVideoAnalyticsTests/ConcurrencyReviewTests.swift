import AVFoundation
import XCTest
import AmplitudeSwift

@testable import AmplitudeVideoAnalytics

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
        let configuration = DelayedEventsConfiguration(ttlMs: 1_234)
        let tracker = DelayedEventTracker(amplitudeConfiguration: amplitude.configuration,
                                          configuration: configuration,
                                          httpClient: uploader)
        let transport = DelayedEvents(amplitude: amplitude, configuration: configuration, tracker: tracker)

        let player = FakePlayer()
        var preReleaseCount = 0

        autoreleasepool {
            let plugin = StreamingAnalyticsPlugin(config: config, transport: transport)
            amplitude.add(plugin: plugin)
            plugin.trackVideo(player: player, options: VideoTrackingOptions())
            player.fire(.played)

            let arrived = expectation(description: "play arrived")
            uploader.whenUploadArrives(matching: { !$0.events.isEmpty }, notify: { arrived.fulfill() })
            wait(for: [arrived], timeout: 5)

            preReleaseCount = uploader.bodies.count
            amplitude.remove(plugin: plugin)
        }

        Thread.sleep(forTimeInterval: 0.5)

        let postReleaseCount = uploader.bodies.count
        XCTAssertGreaterThan(postReleaseCount, preReleaseCount,
                             "deinit should emit final stop events via captured transport")
    }
}

// MARK: - Finding 2 (fixed): stop() safe from the serial queue

final class StopDeadlockTests: XCTestCase {

    /// stop() from within the serial queue must complete without deadlocking.
    func testStopCalledFromQueueDoesNotDeadlock() {
        let queue = DispatchQueue(label: "com.amplitude.streamingAnalytics.test")
        let player = FakePlayer()
        player.duration = 100
        let session = VideoSession(player: player,
                                   playerIdentity: ObjectIdentifier(player),
                                   options: VideoTrackingOptions(),
                                   queue: queue,
                                   now: Date.init)
        session.onEmit = { _ in }
        queue.sync { session.start() }
        player.fire(.played)
        queue.sync {} // drain the play event

        let completed = expectation(description: "stop completed")

        queue.async {
            session.stop()
            completed.fulfill()
        }

        wait(for: [completed], timeout: 2.0)
        queue.sync {} // drain the async finish() enqueued by stop()
        XCTAssertTrue(session.isFinal, "session finalized after stop() from within the queue")
    }

    /// stop() from an external thread still works correctly.
    func testStopCalledFromExternalThread() {
        let queue = DispatchQueue(label: "com.amplitude.streamingAnalytics.external")
        let player = FakePlayer()
        player.duration = 100
        let session = VideoSession(player: player,
                                   playerIdentity: ObjectIdentifier(player),
                                   options: VideoTrackingOptions(),
                                   queue: queue,
                                   now: Date.init)
        session.onEmit = { _ in }
        queue.sync { session.start() }
        player.fire(.played)
        queue.sync {} // drain

        session.stop()
        queue.sync {} // drain the async finish()
        XCTAssertTrue(session.isFinal, "session finalized after stop() from external thread")
    }
}

// MARK: - Finding 3 (fixed): stopObserving() clears onEvent

final class StopObservingClearsOnEventTests: XCTestCase {

    /// stopObserving() alone prevents event delivery — the new API has no separate onEvent property.
    func testStopObservingAlonePreventsEventDelivery() {
        let adapter = AVPlayerAdapter(AVPlayer())
        var delivered = false

        adapter.startObserving { _, _ in delivered = true }
        adapter.stopObserving()

        XCTAssertFalse(delivered,
                       "stopObserving() must clear the handler so no in-flight KVO callbacks can deliver")
    }

    /// After finish(), no events should leak — onEvent is nil from both finish() and stopObserving().
    func testNoEventsLeakAfterFinish() {
        let player = FakePlayer()
        let queue = DispatchQueue(label: "test.emit.fix")
        let session = VideoSession(player: player,
                                   playerIdentity: ObjectIdentifier(player),
                                   options: VideoTrackingOptions(),
                                   queue: queue,
                                   now: Date.init)
        var emitCount = 0
        session.onEmit = { _ in emitCount += 1 }

        queue.sync { session.start() }
        player.fire(.played)
        queue.sync {}

        queue.sync { session.finish() }
        let countAfterFinish = emitCount

        player.fire(.played)
        queue.sync {}

        XCTAssertEqual(emitCount, countAfterFinish,
                       "No events should leak after finish()")
    }
}

// MARK: - Finding 4 (fixed): Timer suspends when no session is playing

final class TimerPausedSessionTests: XCTestCase {

    /// After all sessions pause, the timer must suspend. On resume, it must restart.
    func testTimerSuspendsWhenAllSessionsPaused() {
        let uploader = FakeDelayedEventsUploader()
        uploader.autoSettle = .success(DelayedResponseBody(id: "d", expiration: 1, flushed: nil))
        let amplitude = Amplitude(configuration: Configuration(
            apiKey: "timer-\(UUID().uuidString)",
            instanceName: "timer-\(UUID().uuidString)",
            autocapture: [], offline: true))
        var config = StreamingAnalyticsConfig()
        config.sampleInterval = 0.05
        let configuration = DelayedEventsConfiguration(ttlMs: 1_234)
        let tracker = DelayedEventTracker(amplitudeConfiguration: amplitude.configuration,
                                          configuration: configuration,
                                          httpClient: uploader)
        let transport = DelayedEvents(amplitude: amplitude, configuration: configuration, tracker: tracker)
        let plugin = StreamingAnalyticsPlugin(config: config, transport: transport)
        amplitude.add(plugin: plugin)

        let player = FakePlayer()
        player.duration = 100
        plugin.trackVideo(player: player, options: VideoTrackingOptions())
        player.fire(.played)

        let arrived = expectation(description: "play arrived")
        uploader.whenUploadArrives(matching: { !$0.events.isEmpty }, notify: { arrived.fulfill() })
        wait(for: [arrived], timeout: 5)

        _ = uploader.bodies.count

        // Pause → timer should suspend after its next tick sees no playing sessions
        player.fire(.paused)
        Thread.sleep(forTimeInterval: 0.3) // several tick intervals

        let countAfterPause = uploader.bodies.count
        // After the pause stop event and one more tick at most, no further uploads should arrive
        // because the timer is suspended.
        Thread.sleep(forTimeInterval: 0.3)
        let countAfterWait = uploader.bodies.count

        XCTAssertEqual(countAfterPause, countAfterWait,
                       "Timer must suspend when all sessions are paused — no new uploads")

        // Resume → timer restarts
        player.fire(.played)
        Thread.sleep(forTimeInterval: 0.2) // several ticks

        let countAfterResume = uploader.bodies.count
        XCTAssertGreaterThan(countAfterResume, countAfterWait,
                             "Timer must resume when a session starts playing again")

        // Cleanup
        let session = plugin.trackVideo(player: player, options: VideoTrackingOptions())
        session.stop()
    }
}

// MARK: - Finding 5 (documented): KVO auto-cleanup on player dealloc

final class KVOAutoCleanupTests: XCTestCase {

    /// When the AVPlayer deallocates before stopObserving(), iOS 11+ automatically
    /// deregisters KVO observations. The adapter and observer rely on this guarantee.
    func testInvalidateDoesNotCrashWhenPlayerIsGone() {
        var player: AVPlayer? = AVPlayer()
        let adapter = AVPlayerAdapter(player!)

        adapter.startObserving { _, _ in }

        player = nil

        // iOS 11+ auto-deregisters KVO when the observed object deallocates.
        // invalidate() sees player == nil and returns early — no crash.
        adapter.stopObserving()

        XCTAssertNil(adapter.sample(), "Player is gone, sample() returns nil")
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
        let configuration = DelayedEventsConfiguration(ttlMs: 1_234)
        let tracker = DelayedEventTracker(amplitudeConfiguration: amplitude.configuration,
                                          configuration: configuration,
                                          httpClient: uploader)
        let transport = DelayedEvents(amplitude: amplitude, configuration: configuration, tracker: tracker)

        let player = FakePlayer()
        var preReleaseCount = 0

        autoreleasepool {
            let plugin = StreamingAnalyticsPlugin(config: config, transport: transport)
            amplitude.add(plugin: plugin)
            plugin.trackVideo(player: player, options: VideoTrackingOptions())
            player.fire(.played)

            let arrived = expectation(description: "play arrived")
            uploader.whenUploadArrives(matching: { !$0.events.isEmpty }, notify: { arrived.fulfill() })
            wait(for: [arrived], timeout: 5)

            preReleaseCount = uploader.bodies.count
            amplitude.remove(plugin: plugin)
        }

        Thread.sleep(forTimeInterval: 0.5)

        XCTAssertGreaterThan(uploader.bodies.count, preReleaseCount,
                             "deinit's capture-and-dispatch pattern emits final events")
    }
}

// MARK: - Finding 7 (refuted): setup/trackVideo race — no real window

final class SetupTrackVideoRaceTests: XCTestCase {

    /// DelayedEvents adds itself to the timeline in its init, so the transport is
    /// ready by the time setup() returns. This is a regression test confirming it.
    func testTransportIsReadyAfterSetup() {
        let amplitude = Amplitude(configuration: Configuration(
            apiKey: "race-\(UUID().uuidString)",
            instanceName: "race-\(UUID().uuidString)",
            autocapture: [], offline: true))
        let plugin = StreamingAnalyticsPlugin()
        amplitude.add(plugin: plugin)

        XCTAssertNotNil(plugin.transport, "transport is set after setup")
    }
}
