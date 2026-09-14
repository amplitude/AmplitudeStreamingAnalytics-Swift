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
                                          transport: makeTransport(on: amplitude, uploading: uploader),
                                          makePulse: PulseTimer.init)
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

    func testPauseCarriesAccruedWatchDurationAndFinalizesTheRow() {
        let player = FakePlayer()
        plugin.trackVideo(player: player, options: VideoTrackingOptions())
        player.fire(.played)
        waitForUpload { !$0.events.isEmpty }

        player.position = 30
        player.fire(.paused)

        waitForUpload { $0.instantEvents?.contains { $0.eventProperties?["stop_reason"] as? String == "paused" } == true }
        let final = uploader.bodies.last!
        let stopped = final.instantEvents!.first { $0.eventType == StreamingEvents.stoppedType }!
        // The plumbing: whatever the observer accrued reaches the wire. The total is the same whether or
        // not a pulse sampled the advance first, so this does not depend on timing; the pulse itself is
        // covered against a controllable seam in PlayerObserverTests.
        XCTAssertEqual(stopped.eventProperties?["stream_duration"] as? TimeInterval, 30)
        XCTAssertEqual(final.ttlMs, 0, "no live snapshot left, so the row is finalized")
    }

    /// The pulse each viewing gets runs at the configured `sampleInterval`, and its tick books the playhead
    /// advance into the live snapshot. The tick is fired by hand, so nothing here races a real timer.
    /// Its own `Amplitude`: a second transport on a host that already has one is never reached.
    func testConfiguredSampleIntervalDrivesTheViewingsPulse() {
        var pulseInterval: TimeInterval?
        var tick: (() -> Void)?
        var pulseQueue: DispatchQueue?

        let host = Amplitude(configuration: Configuration(apiKey: "pulse-\(UUID().uuidString)",
                                                          instanceName: "pulse-\(UUID().uuidString)",
                                                          autocapture: [],
                                                          offline: true))
        let ownUploader = FakeDelayedEventsUploader()
        ownUploader.autoSettle = .success(DelayedResponseBody(id: "d", expiration: 1, flushed: nil))
        // A brisk transport pulse, so the refreshed snapshot reaches the uploader without a flush.
        let configuration = DelayedEventsConfiguration(pulseInterval: 0.05, ttlMs: 1_234)
        let tracker = DelayedEventTracker(amplitudeConfiguration: host.configuration,
                                          configuration: configuration,
                                          httpClient: ownUploader)
        let transport = DelayedEvents(amplitude: host, configuration: configuration, tracker: tracker)

        var config = StreamingAnalyticsConfig()
        config.sampleInterval = 0.25
        let pulsed = StreamingAnalyticsPlugin(config: config, transport: transport) { interval, queue, handler in
            pulseInterval = interval
            pulseQueue = queue
            tick = handler
            return PulseTimer(interval: 3_600, queue: queue, handler: handler)
        }
        host.add(plugin: pulsed)

        let player = FakePlayer()
        pulsed.trackVideo(player: player, options: VideoTrackingOptions())
        player.fire(.played)

        let opened = expectation(description: "the play opened the row")
        ownUploader.whenUploadArrives(matching: { !$0.events.isEmpty }, notify: { opened.fulfill() })
        wait(for: [opened], timeout: 5)

        XCTAssertEqual(pulseInterval, 0.25, "the viewing's pulse runs at the configured sampleInterval")

        let sampled = expectation(description: "the tick's advance reached the wire")
        ownUploader.whenUploadArrives(matching: { body in
            body.events.contains { $0.eventType == StreamingEvents.stoppedType
                && ($0.eventProperties?["stream_duration"] as? TimeInterval ?? 0) == 30 }
        }, notify: { sampled.fulfill() })

        player.position = 30
        pulseQueue?.sync { tick?() }

        wait(for: [sampled], timeout: 5)
    }

    func testRetrackingTheSamePlayerStopsThePreviousSession() {
        let player = FakePlayer()
        plugin.trackVideo(player: player, options: VideoTrackingOptions())
        player.fire(.played)
        waitForUpload { !$0.events.isEmpty }

        plugin.trackVideo(player: player, options: VideoTrackingOptions())

        waitForUpload { $0.instantEvents?.contains { $0.eventProperties?["stop_reason"] as? String == "untracked" } == true }
        XCTAssertEqual(plugin.activeSessionCount, 1)
        XCTAssertEqual(player.stopObservingCount, 1, "the previous observer stopped")
        XCTAssertEqual(player.startObservingCount, 2, "retracking started a new observer")
    }

    func testStopTrackingEndsTheViewing() {
        let player = FakePlayer()
        plugin.trackVideo(player: player, options: VideoTrackingOptions())
        player.fire(.played)
        waitForUpload { !$0.events.isEmpty }

        plugin.stopTracking(player: player)

        waitForUpload { $0.instantEvents?.contains { $0.eventProperties?["stop_reason"] as? String == "untracked" } == true }
        XCTAssertEqual(plugin.activeSessionCount, 0)
        XCTAssertEqual(player.stopObservingCount, 1, "the viewing stopped observing the player")
    }

    func testStopTrackingAnUntrackedPlayerDoesNothing() {
        let player = FakePlayer()
        plugin.stopTracking(player: player)
        XCTAssertEqual(plugin.activeSessionCount, 0)
        XCTAssertEqual(player.stopObservingCount, 0)
    }

    /// The previous viewing must stop observing *before* the new one subscribes. Both observers share one
    /// `Player`, so a teardown that lands late clears the subscription the new viewing just installed and
    /// the replacement viewing goes deaf.
    func testRetrackingLeavesTheNewViewingObserving() {
        let player = FakePlayer()
        plugin.trackVideo(player: player, options: VideoTrackingOptions())
        player.fire(.played)
        waitForUpload { !$0.events.isEmpty }

        plugin.trackVideo(player: player, options: VideoTrackingOptions())
        waitForUpload { $0.instantEvents?.contains { $0.eventProperties?["stop_reason"] as? String == "untracked" } == true }

        XCTAssertNotNil(player.onEvent, "the replacement viewing is still subscribed to the player")
    }

    func testTwoPlayersAreTwoViewings() {
        let first = FakePlayer()
        let second = FakePlayer()
        plugin.trackVideo(player: first, options: VideoTrackingOptions())
        plugin.trackVideo(player: second, options: VideoTrackingOptions())
        XCTAssertEqual(plugin.activeSessionCount, 2)

        first.fire(.played)
        waitForUpload { !$0.events.isEmpty }
        first.fire(.released)

        waitForUpload { $0.instantEvents?.contains { $0.eventProperties?["stop_reason"] as? String == "untracked" } == true }
        XCTAssertEqual(plugin.activeSessionCount, 1)
    }

    func testReleasedPlayerEndsItsViewing() {
        let player = FakePlayer()
        plugin.trackVideo(player: player, options: VideoTrackingOptions())
        player.fire(.played)
        waitForUpload { !$0.events.isEmpty }

        player.fire(.released)

        waitForUpload { $0.instantEvents?.contains { $0.eventProperties?["stop_reason"] as? String == "untracked" } == true }
        XCTAssertEqual(plugin.activeSessionCount, 0)
    }

    func testTrackVideoBeforeSetupIsInert() {
        let detached = StreamingAnalyticsPlugin()
        let player = FakePlayer()
        detached.trackVideo(player: player, options: VideoTrackingOptions())
        player.fire(.played)

        XCTAssertEqual(player.startObservingCount, 0, "nothing to track: the plugin was never added to an Amplitude instance")
        XCTAssertEqual(detached.activeSessionCount, 0)
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
        integrator.trackVideo(player: player, options: VideoTrackingOptions())

        XCTAssertEqual(integrator.transport?.configuration.ttlMs,
                       Int64(StreamingAnalyticsConfig().delayedEventTtl * 1000))
        XCTAssertEqual(integrator.activeSessionCount, 1)
        XCTAssertEqual(player.startObservingCount, 1, "a live session: start() only observes while not final")

        // Released without ever playing: no play is open, so this emits no events and the plugin's
        // real transport — built by setup(), with a real uploader — is never asked to send anything.
        player.fire(.released)

        let deadline = Date().addingTimeInterval(2)
        while integrator.activeSessionCount != 0 && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertEqual(integrator.activeSessionCount, 0)
    }

    func testAVPlayerOverloadTracksThroughTheAdapter() {
        let player = AVPlayer()
        plugin.trackVideo(player: player, options: VideoTrackingOptions())
        XCTAssertEqual(plugin.activeSessionCount, 1)
        plugin.trackVideo(player: player, options: VideoTrackingOptions())
        XCTAssertEqual(plugin.activeSessionCount, 1, "re-tracking the same AVPlayer replaces its session")
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

    private func waitForUpload(matching predicate: @escaping (DelayedRequestBody) -> Bool, timeout: TimeInterval = 5) {
        let arrived = expectation(description: "matching upload")
        uploader.whenUploadArrives(matching: predicate) { arrived.fulfill() }
        wait(for: [arrived], timeout: timeout)
    }
}
