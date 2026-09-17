import AVFoundation
import XCTest
import AmplitudeSwift

@testable import AmplitudeStreamingAnalytics

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
        let transport = makeTransport(on: amplitude, uploading: uploader)
        plugin = StreamingAnalyticsPlugin(config: config,
                                          delayedEventsFactory: { _, _ in transport },
                                          pulseTimerFactory: PulseTimer.init)
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
        plugin.trackPlayer(player: player, content: PlayerContent(contentId: "ep-1"))
        player.fire(.played)

        waitForUpload { $0.instantEvents?.contains { $0.eventType == StreamingEvents.startedType } == true }
        waitForUpload { $0.events.contains { $0.eventType == StreamingEvents.stoppedType } }
        let snapshot = uploader.bodies.flatMap(\.events).first { $0.eventType == StreamingEvents.stoppedType }!
        XCTAssertEqual(snapshot.eventProperties?["stop_reason"] as? String, "timeout")
        XCTAssertEqual(uploader.bodies.last?.ttlMs, 1_234)
    }

    func testPauseCarriesAccruedWatchDurationAndFinalizesTheRow() {
        let player = FakePlayer()
        plugin.trackPlayer(player: player, content: PlayerContent())
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
        let pulsed = StreamingAnalyticsPlugin(
            config: config,
            delayedEventsFactory: { _, _ in transport },
            pulseTimerFactory: { interval, queue, handler in
                pulseInterval = interval
                pulseQueue = queue
                tick = handler
                return PulseTimer(interval: 3_600, queue: queue, handler: handler)
            })
        host.add(plugin: pulsed)

        let player = FakePlayer()
        pulsed.trackPlayer(player: player, content: PlayerContent())
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

    /// One viewing per player: the second call is refused and the first viewing keeps running, rather than
    /// being ended by a caller who only meant to start one.
    func testRetrackingTheSamePlayerIsRefusedAndLeavesTheViewingRunning() {
        let player = FakePlayer()
        plugin.trackPlayer(player: player, content: PlayerContent())
        player.fire(.played)
        waitForUpload { !$0.events.isEmpty }

        plugin.trackPlayer(player: player, content: PlayerContent())

        XCTAssertEqual(plugin.activeSessionCount, 1)
        XCTAssertEqual(player.startObservingCount, 1, "no second observer subscribed")
        XCTAssertEqual(player.stopObservingCount, 0, "the running viewing was not torn down")
        XCTAssertNotNil(player.onEvent, "the original viewing is still subscribed to the player")
        XCTAssertFalse(uploader.bodies.contains(where: isUntrackedStop), "the running viewing did not send a closing event")
    }

    /// The refusal is on a *live* viewing. One that ended on its own has already evicted itself — its `.final`
    /// reaches the plugin on the same serial queue `trackPlayer` uses — so the player can be tracked again.
    func testTrackingAgainAfterTheViewingEndedOnItsOwnIsAllowed() {
        let player = FakePlayer()
        plugin.trackPlayer(player: player, content: PlayerContent())
        player.fire(.played)
        waitForUpload { !$0.events.isEmpty }

        player.fire(.released)
        waitForUpload(matching: isUntrackedStop)

        plugin.trackPlayer(player: player, content: PlayerContent())

        XCTAssertEqual(plugin.activeSessionCount, 1, "the ended viewing evicted itself, so this one registered")
        XCTAssertEqual(player.startObservingCount, 2)
    }

    func testStopTrackingEndsTheViewing() {
        let player = FakePlayer()
        plugin.trackPlayer(player: player, content: PlayerContent())
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

    func testTwoPlayersAreTwoViewings() {
        let first = FakePlayer()
        let second = FakePlayer()
        plugin.trackPlayer(player: first, content: PlayerContent())
        plugin.trackPlayer(player: second, content: PlayerContent())
        XCTAssertEqual(plugin.activeSessionCount, 2)

        first.fire(.played)
        waitForUpload { !$0.events.isEmpty }
        first.fire(.released)

        waitForUpload { $0.instantEvents?.contains { $0.eventProperties?["stop_reason"] as? String == "untracked" } == true }
        XCTAssertEqual(plugin.activeSessionCount, 1)
    }

    func testReleasedPlayerEndsItsViewing() {
        let player = FakePlayer()
        plugin.trackPlayer(player: player, content: PlayerContent())
        player.fire(.played)
        waitForUpload { !$0.events.isEmpty }

        player.fire(.released)

        waitForUpload { $0.instantEvents?.contains { $0.eventProperties?["stop_reason"] as? String == "untracked" } == true }
        XCTAssertEqual(plugin.activeSessionCount, 0)
    }

    func testTrackPlayerBeforeSetupIsInert() {
        let detached = StreamingAnalyticsPlugin()
        let player = FakePlayer()
        detached.trackPlayer(player: player, content: PlayerContent())
        player.fire(.played)

        XCTAssertEqual(player.startObservingCount, 0, "nothing to track: the plugin was never added to an Amplitude instance")
        XCTAssertEqual(detached.activeSessionCount, 0)
    }

    /// The TTL a customer gets is not theirs to set, and the config states it in seconds while the wire
    /// counts milliseconds. The factory reports the configuration the plugin built, so the conversion is
    /// pinned to a literal rather than to a repeat of the production expression.
    func testTheDefaultTtlInSecondsReachesTheTransportInMilliseconds() {
        var built: DelayedEventsConfiguration?
        let host = Amplitude(configuration: Configuration(apiKey: "ttl-\(UUID().uuidString)",
                                                          instanceName: "ttl-\(UUID().uuidString)",
                                                          autocapture: [],
                                                          offline: true))
        let ownUploader = FakeDelayedEventsUploader()
        let integrator = StreamingAnalyticsPlugin(
            config: StreamingAnalyticsConfig(),
            delayedEventsFactory: { amplitude, configuration in
                built = configuration
                let tracker = DelayedEventTracker(amplitudeConfiguration: amplitude.configuration,
                                                  configuration: configuration,
                                                  httpClient: ownUploader)
                return DelayedEvents(amplitude: amplitude, configuration: configuration, tracker: tracker)
            },
            pulseTimerFactory: PulseTimer.init)

        host.add(plugin: integrator)

        XCTAssertEqual(built?.ttlMs, 3_600_000, "delayedEventTtl is one hour, stated in seconds")
    }

    /// The only path a customer takes: public init, then amplitude.add(plugin:) builds the transport in
    /// setup. Nothing plays, so the real uploader that setup wires up is never asked to send.
    func testPublicInitTracksThroughTheTransportItBuilds() {
        let integrator = StreamingAnalyticsPlugin()
        let host = Amplitude(configuration: Configuration(apiKey: "integrator-\(UUID().uuidString)",
                                                          instanceName: "integrator-\(UUID().uuidString)",
                                                          autocapture: [],
                                                          offline: true))

        host.add(plugin: integrator)
        let player = FakePlayer()
        integrator.trackPlayer(player: player, content: PlayerContent())

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
        plugin.trackPlayer(player: player, content: PlayerContent())
        XCTAssertEqual(plugin.activeSessionCount, 1)
        plugin.trackPlayer(player: player, content: PlayerContent())
        XCTAssertEqual(plugin.activeSessionCount, 1, "re-tracking the same AVPlayer is refused")
        XCTAssertTrue(uploader.bodies.isEmpty, "no play, nothing sent")
    }

    func testDeinitFinalizesLiveSessions() {
        let player = FakePlayer()
        plugin.trackPlayer(player: player, content: PlayerContent())
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
