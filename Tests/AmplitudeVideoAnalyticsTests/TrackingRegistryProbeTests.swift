import XCTest
import AmplitudeSwift

@testable import AmplitudeVideoAnalytics

/// Hammers the registry from many threads. A green run proves only the interleavings it happened to
/// hit, so the orderings that matter are forced deterministically as well.
final class TrackingRegistryProbeTests: XCTestCase {
    private var uploader: FakeDelayedEventsUploader!
    private var amplitude: Amplitude!
    private var plugin: StreamingAnalyticsPlugin!

    override func setUp() {
        super.setUp()
        uploader = FakeDelayedEventsUploader()
        uploader.autoSettle = .success(DelayedResponseBody(id: "d", expiration: 1, flushed: nil))
        amplitude = Amplitude(configuration: Configuration(apiKey: "probe-\(UUID().uuidString)",
                                                           instanceName: "probe-\(UUID().uuidString)",
                                                           autocapture: [],
                                                           offline: true))
        var config = StreamingAnalyticsConfig()
        config.sampleInterval = 0.01
        let configuration = DelayedEventsConfiguration(pulseInterval: 0.01, ttlMs: 1_234)
        let tracker = DelayedEventTracker(amplitudeConfiguration: amplitude.configuration,
                                          configuration: configuration,
                                          httpClient: uploader)
        let transport = DelayedEvents(amplitude: amplitude, configuration: configuration, tracker: tracker)
        plugin = StreamingAnalyticsPlugin(config: config,
                                          delayedEventsFactory: { _, _ in transport },
                                          pulseTimerFactory: PulseTimer.init)
        amplitude.add(plugin: plugin)
    }

    override func tearDown() {
        plugin = nil
        amplitude = nil
        uploader = nil
        super.tearDown()
    }

    /// Reading the count takes the plugin's queue, so repeated reads drain the work already enqueued —
    /// a handler, then the publish that handler enqueued, then anything that publish enqueued.
    @discardableResult
    private func drain() -> Int {
        _ = plugin.activeSessionCount
        _ = plugin.activeSessionCount
        return plugin.activeSessionCount
    }

    /// A tracked viewing is subscribed to its player, and an evicted one is not, so the registry's count
    /// must equal the number of players holding a handler. If a stale `.final` ever evicted a live
    /// viewing, the count would fall below the number of still-subscribed players.
    func testRegistryAgreesWithSubscriptionsUnderConcurrentTrackStopAndEvents() {
        let players = (0..<4).map { _ -> FakePlayer in
            let player = FakePlayer()
            player.duration = 100
            return player
        }

        for round in 0..<40 {
            DispatchQueue.concurrentPerform(iterations: 96) { step in
                let player = players[step % players.count]
                switch (step / players.count) % 8 {
                case 0, 5: self.plugin.trackVideo(player: player, options: VideoTrackingOptions())
                case 1: self.plugin.stopTracking(player: player)
                case 2: player.fire(.played)
                case 3: player.fire(.paused)
                case 4: player.fire(.seeked)
                case 6: player.fire(.error(message: "probe"))
                default: player.fire(.released)
                }
            }

            let live = drain()
            let subscribed = players.filter { $0.onEvent != nil }.count
            XCTAssertEqual(live, subscribed, "round \(round): registry and player subscriptions disagree")
            XCTAssertLessThanOrEqual(live, players.count, "round \(round): more viewings than players")
        }

        // Whatever the storm did, the registry can still be driven back to a known state.
        for player in players { plugin.stopTracking(player: player) }
        XCTAssertEqual(drain(), 0, "every viewing stopped")
        XCTAssertTrue(players.allSatisfy { $0.onEvent == nil }, "no player left subscribed")

        for player in players { plugin.trackVideo(player: player, options: VideoTrackingOptions()) }
        XCTAssertEqual(drain(), players.count, "every player tracked again after the storm")
        XCTAssertTrue(players.allSatisfy { $0.onEvent != nil }, "every player subscribed again")
    }

    /// Two threads racing to track the same player: exactly one viewing may result, and it must be
    /// subscribed. This is the case the refusal guard exists for.
    func testConcurrentTrackOfOnePlayerYieldsExactlyOneViewing() {
        for round in 0..<200 {
            let player = FakePlayer()
            DispatchQueue.concurrentPerform(iterations: 8) { _ in
                self.plugin.trackVideo(player: player, options: VideoTrackingOptions())
            }
            XCTAssertEqual(drain(), 1, "round \(round): one viewing per player")
            XCTAssertEqual(player.startObservingCount, 1, "round \(round): only one observer subscribed")
            XCTAssertNotNil(player.onEvent, "round \(round): the surviving viewing is subscribed")

            plugin.stopTracking(player: player)
            XCTAssertEqual(drain(), 0)
        }
    }

    /// Forced ordering, not a race: the self-end is enqueued first, so its eviction has already run by the
    /// time a later `trackVideo` is served, and the player can be tracked again.
    func testSelfEndEvictsBeforeALaterTrackIsServed() {
        let player = FakePlayer()
        plugin.trackVideo(player: player, options: VideoTrackingOptions())
        player.fire(.played)
        drain()

        player.fire(.error(message: "boom"))
        drain()
        plugin.trackVideo(player: player, options: VideoTrackingOptions())

        XCTAssertEqual(drain(), 1, "the ended viewing evicted itself, so this one registered")
        XCTAssertEqual(player.startObservingCount, 2)
        XCTAssertNotNil(player.onEvent)
    }

    /// `stopTracking` removes the entry synchronously but its `.final` is published later, so the next
    /// `trackVideo` is allowed and installs a new viewing *before* that `.final` lands. The stale publish
    /// must not evict the viewing that replaced it.
    func testStopThenTrackKeepsTheNewViewingRegistered() {
        let player = FakePlayer()
        plugin.trackVideo(player: player, options: VideoTrackingOptions())
        player.fire(.played)
        drain()

        plugin.stopTracking(player: player)
        plugin.trackVideo(player: player, options: VideoTrackingOptions())

        XCTAssertEqual(drain(), 1, "the new viewing survived the previous one's late .final")
        XCTAssertNotNil(player.onEvent, "the new viewing is still subscribed")
    }

    /// The residual gap, pinned so a change to it is visible: `trackVideo` issued before the self-end's
    /// eviction has been enqueued is served first, sees the dying entry, and is refused.
    func testTrackIssuedInsideTheSelfEndWindowIsRefused() {
        let player = FakePlayer()
        plugin.trackVideo(player: player, options: VideoTrackingOptions())
        player.fire(.played)
        drain()

        player.fire(.error(message: "boom"))
        plugin.trackVideo(player: player, options: VideoTrackingOptions())

        XCTAssertEqual(drain(), 0, "the re-track was refused and the errored viewing then evicted itself")
        XCTAssertEqual(player.startObservingCount, 1)
    }
}
