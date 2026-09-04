import AVFoundation
import XCTest
import AmplitudeSwift

@testable import AmplitudeVideoAnalytics

final class StreamingAnalyticsPluginTests: XCTestCase {
    private var uploader: FakeDelayedEventsUploader!
    private var amplitude: Amplitude!
    private var plugin: StreamingAnalyticsPlugin!

    override func setUp() {
        super.setUp()
        uploader = FakeDelayedEventsUploader()
        uploader.autoSettle = .success(DelayedResponseBody(id: "d", expiration: 1, flushed: nil))
        amplitude = Amplitude(configuration: Configuration(apiKey: "plugin-\(UUID().uuidString)",
                                                           instanceName: "plugin-\(UUID().uuidString)",
                                                           autocapture: [],
                                                           offline: true))
        var config = StreamingAnalyticsConfig()
        config.sampleInterval = 0.05
        config.delayedEventTtl = 1.234
        plugin = StreamingAnalyticsPlugin(config: config,
                                          transport: makeTransport(on: amplitude, uploading: uploader))
        amplitude.add(plugin: plugin)
    }

    /// A distinctive TTL, so a test can tell this transport's configuration from the default.
    /// Both collaborators are explicit: one test builds its own pair and must not reach the shared ones.
    private func makeTransport(on amplitude: Amplitude, uploading uploader: FakeDelayedEventsUploader) -> DelayedEvents {
        let configuration = DelayedEventsConfiguration(ttlMs: 1_234)
        let tracker = DelayedEventTracker(amplitudeConfiguration: amplitude.configuration,
                                          configuration: configuration,
                                          httpClient: uploader)
        return DelayedEvents(amplitude: amplitude, configuration: configuration, tracker: tracker)
    }

    override func tearDown() {
        plugin = nil
        amplitude = nil
        uploader = nil
        super.tearDown()
    }

    func testPlayRoutesStartedToInstantAndSnapshotToDelayed() {
        let player = FakePlayer()
        plugin.trackVideo(player: player, options: VideoTrackingOptions(contentId: "ep-1"))
        player.fire(.played)

        waitForUpload { $0.instantEvents?.contains { $0.eventType == StreamingEvents.startedType } == true }
        waitForUpload { $0.events.contains { $0.eventType == StreamingEvents.stoppedType } }
        let snapshot = uploader.bodies.flatMap(\.events).first { $0.eventType == StreamingEvents.stoppedType }!
        XCTAssertEqual(snapshot.eventProperties?["stop_reason"] as? String, "timeout")
        XCTAssertEqual(uploader.bodies.last?.ttlMs, 1_234)
    }

    func testPauseAfterTicksCarriesAccruedWatchDurationAndFinalizesTheRow() {
        let player = FakePlayer()
        plugin.trackVideo(player: player, options: VideoTrackingOptions())
        player.fire(.played)
        waitForUpload { !$0.events.isEmpty }

        player.position = 30
        Thread.sleep(forTimeInterval: 0.15)   // at least one tick at 0.05 s
        player.fire(.paused)

        waitForUpload { $0.instantEvents?.contains { $0.eventProperties?["stop_reason"] as? String == "paused" } == true }
        let final = uploader.bodies.last!
        let stopped = final.instantEvents!.first { $0.eventType == StreamingEvents.stoppedType }!
        XCTAssertGreaterThan(stopped.eventProperties?["stream_duration"] as? TimeInterval ?? 0, 0,
                             "some watch time should have accrued between play and pause")
        XCTAssertEqual(final.ttlMs, 0, "no live snapshot left, so the row is finalized")
    }

    func testRetrackingTheSamePlayerStopsThePreviousSession() {
        let player = FakePlayer()
        let first = plugin.trackVideo(player: player, options: VideoTrackingOptions())
        player.fire(.played)
        waitForUpload { !$0.events.isEmpty }

        let second = plugin.trackVideo(player: player, options: VideoTrackingOptions())

        waitForUpload { $0.instantEvents?.contains { $0.eventProperties?["stop_reason"] as? String == "untracked" } == true }
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(plugin.activeSessionCount, 1)
        XCTAssertEqual(player.stopObservingCount, 1)
        XCTAssertEqual(player.startObservingCount, 2)
    }

    func testPlayerGoneIsNoticedByTheTick() {
        let player = FakePlayer()
        plugin.trackVideo(player: player, options: VideoTrackingOptions())
        player.fire(.played)
        waitForUpload { !$0.events.isEmpty }

        player.isGone = true

        waitForUpload { $0.instantEvents?.contains { $0.eventProperties?["stop_reason"] as? String == "untracked" } == true }
        XCTAssertEqual(plugin.activeSessionCount, 0)
    }

    func testTrackVideoBeforeSetupIsInert() {
        let detached = StreamingAnalyticsPlugin()
        let player = FakePlayer()
        let session = detached.trackVideo(player: player, options: VideoTrackingOptions())
        player.fire(.played)

        XCTAssertEqual(player.startObservingCount, 0)
        XCTAssertEqual(detached.activeSessionCount, 0)
        XCTAssertTrue(session.isFinal)
    }

    /// The only path a customer takes: public init, then amplitude.add(plugin:) builds the transport
    /// in setup. The TTL is not theirs to set, so this pins the default reaching the transport.
    func testPublicInitBuildsTheTransportOnSetupWithTheDefaultTtl() {
        let integrator = StreamingAnalyticsPlugin()
        let host = Amplitude(configuration: Configuration(apiKey: "integrator-\(UUID().uuidString)",
                                                          instanceName: "integrator-\(UUID().uuidString)",
                                                          autocapture: [],
                                                          offline: true))

        host.add(plugin: integrator)
        let player = FakePlayer()
        let session = integrator.trackVideo(player: player, options: VideoTrackingOptions())

        XCTAssertEqual(integrator.transport?.configuration.ttlMs,
                       Int64(StreamingAnalyticsConfig().delayedEventTtl * 1000))
        XCTAssertEqual(integrator.activeSessionCount, 1)
        XCTAssertEqual(player.startObservingCount, 1)
        XCTAssertFalse(session.isFinal)
        session.stop()
        XCTAssertEqual(integrator.activeSessionCount, 0)
    }

    func testAVPlayerOverloadTracksThroughTheAdapter() {
        let player = AVPlayer()
        let session = plugin.trackVideo(player: player, options: VideoTrackingOptions())
        XCTAssertEqual(plugin.activeSessionCount, 1)
        session.stop()
        XCTAssertEqual(plugin.activeSessionCount, 0)
        XCTAssertTrue(uploader.bodies.isEmpty, "no play, nothing sent")
    }

    func testDeinitFinalizesLiveSessions() {
        let player = FakePlayer()
        plugin.trackVideo(player: player, options: VideoTrackingOptions())
        player.fire(.played)
        waitForUpload { !$0.events.isEmpty }

        amplitude.remove(plugin: plugin)
        plugin = nil

        waitForUpload { $0.instantEvents?.contains { $0.eventProperties?["stop_reason"] as? String == "untracked" } == true }
        XCTAssertEqual(player.stopObservingCount, 1)
    }

    func testRefreshAndSendPutsTheCurrentPositionOnTheWireWithoutFinalizing() {
        let uploader = FakeDelayedEventsUploader()
        uploader.autoSettle = .success(DelayedResponseBody(id: "d", expiration: 1, flushed: nil))
        let amplitude = Amplitude(configuration: Configuration(apiKey: "plugin-\(UUID().uuidString)",
                                                               instanceName: "plugin-\(UUID().uuidString)",
                                                               autocapture: [],
                                                               offline: true))
        let player = FakePlayer()
        var config = StreamingAnalyticsConfig()
        config.sampleInterval = 3600   // no refresh interferes; refreshAndSend must sample on its own
        let slow = StreamingAnalyticsPlugin(config: config,
                                            transport: makeTransport(on: amplitude, uploading: uploader))
        amplitude.add(plugin: slow)
        slow.trackVideo(player: player, options: VideoTrackingOptions())
        player.fire(.played)
        waitForUpload(on: uploader) { !$0.events.isEmpty }

        player.position = 42
        slow.refreshAndSend()

        waitForUpload(on: uploader) { $0.events.first?.eventProperties?["position"] as? TimeInterval == 42 }
        XCTAssertEqual(uploader.bodies.last?.ttlMs, 1_234)
        withExtendedLifetime(slow) {}
    }

    #if (os(iOS) || os(tvOS) || os(visionOS) || targetEnvironment(macCatalyst)) && !AMPLITUDE_DISABLE_UIKIT
    func testDidEnterBackgroundTriggersRefreshAndPulse() {
        let player = FakePlayer()
        plugin.trackVideo(player: player, options: VideoTrackingOptions())
        player.fire(.played)
        waitForUpload { !$0.events.isEmpty }

        player.position = 7
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)

        waitForUpload { $0.events.first?.eventProperties?["position"] as? TimeInterval == 7 }
    }
    #endif

    private func waitForUpload(matching predicate: @escaping (DelayedRequestBody) -> Bool, timeout: TimeInterval = 5) {
        waitForUpload(on: uploader, matching: predicate, timeout: timeout)
    }

    private func waitForUpload(on uploader: FakeDelayedEventsUploader,
                               matching predicate: @escaping (DelayedRequestBody) -> Bool,
                               timeout: TimeInterval = 5) {
        let arrived = expectation(description: "matching upload")
        uploader.whenUploadArrives(matching: predicate) { arrived.fulfill() }
        wait(for: [arrived], timeout: timeout)
    }
}
