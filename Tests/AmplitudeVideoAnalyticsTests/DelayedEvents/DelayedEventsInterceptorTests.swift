import XCTest
@testable import AmplitudeVideoAnalytics
import AmplitudeSwift

final class DelayedEventsInterceptorTests: XCTestCase {
    private var uploader: FakeDelayedEventsUploader!
    // Held for the test's lifetime: the interceptor retains the facade only weakly.
    private var amplitude: Amplitude!
    private var delayedEvents: DelayedEvents!
    private let notifications = NotificationCenter()

    override func setUp() {
        super.setUp()
        uploader = FakeDelayedEventsUploader()
        uploader.autoSettle = .success(DelayedResponseBody(id: "d", expiration: 1, flushed: nil))
    }

    override func tearDown() {
        delayedEvents = nil
        amplitude = nil
        uploader = nil
        super.tearDown()
    }

    // MARK: - interceptor plugin

    func testDelayedEventIsSwallowedAndHandedToTheTransport() {
        makeFacade()

        delayedEvents.track([makeDelayed("ins-1")])

        waitForUploads(1)
        XCTAssertEqual(uploader.bodies[0].events.compactMap(\.insertId), ["ins-1"])
    }

    /// A delayed event this transport never tracked belongs to another transport, or to nobody. It
    /// keeps flowing rather than being swallowed, or a stale transport left first in the `.before`
    /// chain would eat every delayed event on the timeline.
    func testDelayedEventThisTransportDidNotTrackPassesThroughUntouched() {
        makeFacade()

        XCTAssertNotNil(delayedEvents.execute(event: makeDelayed("foreign")))
    }

    func testOrdinaryEventPassesThroughUntouched() {
        makeFacade()
        let event = makeEvent("a", type: "Regular Event")

        XCTAssertIdentical(delayedEvents.execute(event: event), event)
    }

    // MARK: - delayed event

    func testDelayedEventCopiesTheWrappedEventsFields() {
        let wrapped = makeEvent("ins-1")
        wrapped.timestamp = 1_752_000_000_000
        wrapped.sessionId = 42
        wrapped.eventProperties = ["position": 12.5]

        let delayed = DelayedEvent(copying: wrapped, kind: .delayed)

        XCTAssertEqual(delayed.eventType, wrapped.eventType)
        XCTAssertEqual(delayed.insertId, "ins-1")
        XCTAssertEqual(delayed.timestamp, 1_752_000_000_000)
        XCTAssertEqual(delayed.sessionId, 42)
        XCTAssertEqual(delayed.eventProperties?["position"] as? Double, 12.5)
    }

    func testRefreshingAnEntryReplacesItInPlace() {
        makeFacade()
        delayedEvents.track([makeDelayed("ins-1", type: "First")])
        waitForUploads(1)

        // A refresh rides the next request rather than sending one of its own.
        delayedEvents.track([makeDelayed("ins-1", type: "Second", forcePulse: false)])
        delayedEvents.track([makeDelayed("ins-2")])
        waitForUploads(2)

        let events = uploader.bodies[1].events
        XCTAssertEqual(events.compactMap(\.insertId), ["ins-1", "ins-2"], "replaced in place, not appended")
        XCTAssertEqual(events[0].eventType, "Second")
        XCTAssertNotNil(events[0].platform, "refresh keeps its enrichment")
    }

    func testRoutingFieldsAreNotEncoded() throws {
        let delayed = DelayedEvent(copying: makeEvent("a"), kind: .delayed)
        delayed.markForcePulse()

        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(delayed))
        let fields = try XCTUnwrap(encoded as? [String: Any])
        XCTAssertNil(fields["kind"])
        XCTAssertNil(fields["forcePulse"])
        XCTAssertEqual(fields["insert_id"] as? String, "a")
    }

    // MARK: - facade, through a real Amplitude timeline

    /// Ordering probe: a nil `platform` means ContextPlugin no longer precedes us, which is a
    /// design problem rather than an assertion to relax.
    func testFacadeRoutesThroughRealTimelineWithEnrichment() {
        makeFacade()
        let event = makeEvent("ins-1")
        event.timestamp = 1_752_000_000_000

        delayedEvents.track([{ let e = DelayedEvent(copying: event, kind: .delayed); e.markForcePulse(); return e }()])
        waitForUploads(1)

        let sent = uploader.bodies[0].events[0]
        XCTAssertEqual(sent.insertId, "ins-1")
        XCTAssertEqual(sent.timestamp, 1_752_000_000_000, "client stamp must survive the timeline")
        XCTAssertNotNil(sent.deviceId, "identity stamped by the timeline")
        XCTAssertNotNil(sent.platform, "ContextPlugin enrichment must reach the interceptor")
    }

    /// Swallowing at `.before` skips `.enrichment` entirely, which web does not do. Pinned so a
    /// change in plugin type surfaces as a failure.
    func testDelayedEventsBypassEnrichmentPlugins() {
        let spy = SpyEnrichmentPlugin()
        makeFacade(enrichment: spy)

        amplitude.track(event: makeEvent("ins-0", type: "Regular Event"))
        delayedEvents.track([makeDelayed("ins-1")])
        waitForUploads(1)

        XCTAssertTrue(spy.seen.contains("Regular Event"), "the spy must be reached by ordinary events")
        XCTAssertFalse(spy.seen.contains("Content Stopped"))
    }

    func testFacadeCarriesTheConfiguredTtlOntoTheWire() {
        makeFacade(configuration: DelayedEventsConfiguration(ttlMs: 1_234))
        delayedEvents.track([makeDelayed("ins-1")])
        waitForUploads(1)

        XCTAssertEqual(uploader.bodies[0].ttlMs, 1_234)
    }

    /// Deterministic where a separate "send now" call would not be: the request is asked for by the
    /// refresh itself, so it cannot overtake it across the timeline hop.
    func testFacadeRefreshWithForcePulseGoesOutWithTheRefreshedValue() {
        makeFacade()
        delayedEvents.track([makeDelayed("ins-1", type: "First")])
        waitForUploads(1)

        delayedEvents.track([makeDelayed("ins-1", type: "Second")])
        waitForUploads(2)
        XCTAssertEqual(uploader.bodies[1].events.map(\.eventType), ["Second"])
        XCTAssertNotEqual(uploader.bodies[1].ttlMs, 0, "nothing is finalized")
    }

    // MARK: - helpers

    /// Offline and without autocapture, so only the delayed transport sees traffic.
#if (os(iOS) || os(tvOS) || os(visionOS) || targetEnvironment(macCatalyst)) && !AMPLITUDE_DISABLE_UIKIT
    // MARK: - backgrounding, ordered

    /// What #35 does not promise and this does: nothing drains between the track and the post, so the
    /// event is still crossing the timeline when the pulse is asked for, and the barrier is what makes
    /// it land in that request rather than after it.
    func testBackgroundingWaitsForAnEventStillCrossingTheTimeline() {
        makeFacade(configuration: DelayedEventsConfiguration(pulseInterval: 3_600))
        delayedEvents.track([makeDelayed("ins-1", forcePulse: false)])

        notifications.post(name: UIApplication.didEnterBackgroundNotification, object: nil)

        waitForUploads(1)
        XCTAssertEqual(uploader.bodies[0].events.compactMap(\.insertId), ["ins-1"])
        XCTAssertNotEqual(uploader.bodies[0].ttlMs, 0, "nothing is finalized")
    }

/// The wait covers what was crossing when backgrounding asked, and nothing tracked after it. The
    /// later batch is stranded and held alive, so a wait that included it would never end.
    func testBackgroundingDoesNotWaitForBatchesTrackedAfterIt() {
        makeFacade(swallowing: ["after"],
                   configuration: DelayedEventsConfiguration(pulseInterval: 3_600))
        delayedEvents.track([makeDelayed("before", forcePulse: false)])

        notifications.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        let after = makeDelayed("after", forcePulse: false)
        delayedEvents.track([after])

        waitForUploads(1)
        XCTAssertEqual(uploader.bodies[0].events.compactMap(\.insertId), ["before"])
        withExtendedLifetime(after) {}
    }

        /// The wait ends when the last batch it covered lands, so one request carries all of them. Sending
    /// as each batch drained would produce one request per batch instead.
    func testBackgroundingSendsOneRequestForEveryBatchItWaitedOn() {
        makeFacade(configuration: DelayedEventsConfiguration(pulseInterval: 3_600))
        delayedEvents.track([makeDelayed("first", forcePulse: false)])
        delayedEvents.track([makeDelayed("second", forcePulse: false)])

        notifications.post(name: UIApplication.didEnterBackgroundNotification, object: nil)

        waitForUploads(1)
        XCTAssertEqual(Set(uploader.bodies[0].events.compactMap(\.insertId)), ["first", "second"],
                       "one request carrying both batches, not one per batch")
        expectNoUpload(beyond: 1)
    }
#endif

    /// A batch that asked for an immediate send must not be held up by an unrelated batch the host
    /// never hands back. The stranded event is held alive here, so compaction cannot quietly rescue
    /// the pulse instead.
    func testABatchPulsesWithoutWaitingForAnUnrelatedStrandedBatch() {
        makeFacade(swallowing: ["stranded"],
                   configuration: DelayedEventsConfiguration(pulseInterval: 3_600))
        let stranded = makeDelayed("stranded", forcePulse: false)
        delayedEvents.track([stranded])
        delayedEvents.track([makeDelayed("wants-pulse")])

        waitForUploads(1)
        XCTAssertEqual(uploader.bodies[0].events.compactMap(\.insertId), ["wants-pulse"])
        withExtendedLifetime(stranded) {}
    }

    /// Two transports on one Amplitude: an event tracked through the second must not be consumed by
    /// the first, which is what a stale transport left on the timeline would otherwise do.
    func testEventsGoToTheTransportThatTrackedThem() {
        amplitude = makeAmplitude()
        let firstUploader = FakeDelayedEventsUploader()
        firstUploader.autoSettle = uploader.autoSettle
        let first = makeTransport(uploading: firstUploader, ttlMs: 1_111)
        let second = makeTransport(uploading: uploader, ttlMs: 2_222)

        second.track([makeDelayed("ins-1")])

        waitForUploads(1)
        XCTAssertEqual(uploader.bodies[0].ttlMs, 2_222, "the transport that tracked it sent it")
        XCTAssertTrue(firstUploader.bodies.isEmpty, "the other transport saw nothing")
        withExtendedLifetime((first, second)) {}
    }

    /// Public surface: callers may track from any thread. Every worker's events must reach the live
    /// set exactly once, with no lost update and no crash, and one forced send must carry them all.
    func testTrackIsSafeFromAnyThread() {
        makeFacade(configuration: DelayedEventsConfiguration(pulseInterval: 3_600))
        let workers = 4
        let perWorker = 10

        let group = DispatchGroup()
        for worker in 0..<workers {
            DispatchQueue.global().async(group: group) { [delayedEvents] in
                for step in 0..<perWorker {
                    delayedEvents?.track([self.makeDelayed("w\(worker)-\(step)", forcePulse: false)])
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 30), .success, "workers hung")

        delayedEvents.track([makeDelayed("last")])

        waitForUploads(1)
        let delivered = Set(uploader.bodies[0].events.compactMap(\.insertId))
        let expected = Set((0..<workers).flatMap { worker in
            (0..<perWorker).map { "w\(worker)-\($0)" }
        } + ["last"])
        XCTAssertEqual(delivered, expected, "every thread's events landed exactly once")
    }

    private func makeFacade(enrichment: SpyEnrichmentPlugin? = nil,
                            swallowing swallowedIds: Set<String> = [],
                            configuration: DelayedEventsConfiguration = DelayedEventsConfiguration()) {
        amplitude = makeAmplitude()
        // Added before the transport, so it sits ahead of it in the `.before` chain and drops first.
        if !swallowedIds.isEmpty {
            amplitude.add(plugin: SwallowingBeforePlugin(swallowing: swallowedIds))
        }
        if let enrichment {
            amplitude.add(plugin: enrichment)
        }
        delayedEvents = makeTransport(uploading: uploader, configuration: configuration)
    }

    private func makeAmplitude() -> Amplitude {
        Amplitude(configuration: Configuration(apiKey: "facade-\(UUID().uuidString)",
                                               instanceName: "facade-\(UUID().uuidString)",
                                               autocapture: [],
                                               offline: true))
    }

    private func makeTransport(uploading uploader: FakeDelayedEventsUploader,
                               ttlMs: Int64) -> DelayedEvents {
        makeTransport(uploading: uploader,
                      configuration: DelayedEventsConfiguration(ttlMs: ttlMs))
    }

    private func makeTransport(uploading uploader: FakeDelayedEventsUploader,
                               configuration: DelayedEventsConfiguration) -> DelayedEvents {
        let tracker = DelayedEventTracker(amplitudeConfiguration: amplitude.configuration,
                                          configuration: configuration,
                                          httpClient: uploader)
        return DelayedEvents(amplitude: amplitude,
                             tracker: tracker,
                             notifications: notifications)
    }

#if (os(iOS) || os(tvOS) || os(visionOS) || targetEnvironment(macCatalyst)) && !AMPLITUDE_DISABLE_UIKIT
    /// The pulse interval is an hour, so only backgrounding can produce the second request. The event
    /// is already settled in the live set, which is all this send promises: an event still crossing
    /// the timeline is not waited for, by design.
    func testBackgroundingSendsTheLiveSetWithoutWaitingForThePulse() {
        makeFacade(configuration: DelayedEventsConfiguration(pulseInterval: 3_600))
        delayedEvents.track([makeDelayed("ins-1")])
        waitForUploads(1)

        notifications.post(name: UIApplication.didEnterBackgroundNotification, object: nil)

        waitForUploads(2)
        XCTAssertEqual(uploader.bodies[1].events.compactMap(\.insertId), ["ins-1"])
        XCTAssertNotEqual(uploader.bodies[1].ttlMs, 0, "nothing is finalized")
    }
#endif

    /// Forces by default: most tests here are about routing rather than scheduling.
    private func makeDelayed(_ insertId: String,
                             type: String = "Content Stopped",
                             forcePulse: Bool = true) -> DelayedEvent {
        let event = DelayedEvent(copying: makeEvent(insertId, type: type), kind: .delayed)
        if forcePulse {
            event.markForcePulse()
        }
        return event
    }

    private func makeEvent(_ insertId: String, type: String = "Content Stopped") -> BaseEvent {
        let event = BaseEvent(eventType: type)
        event.insertId = insertId
        return event
    }

    private func expectNoUpload(beyond count: Int, timeout: TimeInterval = 0.2) {
        let extra = expectation(description: "no upload beyond \(count)")
        extra.isInverted = true
        uploader.whenUploadCountReaches(count + 1) { extra.fulfill() }
        wait(for: [extra], timeout: timeout)
    }

    private func waitForUploads(_ count: Int, timeout: TimeInterval = 5) {
        let reached = expectation(description: "\(count) upload(s)")
        uploader.whenUploadCountReaches(count) { reached.fulfill() }
        wait(for: [reached], timeout: timeout)
    }
}

/// Drops events by insert id before the transport sees them, the way an app's own `.before` plugin
/// could — or an opt-out could, which short-circuits before the timeline entirely.
final class SwallowingBeforePlugin: BeforePlugin {
    private let swallowedIds: Set<String>

    init(swallowing swallowedIds: Set<String>) {
        self.swallowedIds = swallowedIds
        super.init()
    }

    override func execute(event: BaseEvent) -> BaseEvent? {
        guard let insertId = event.insertId, swallowedIds.contains(insertId) else { return event }
        return nil
    }
}

/// Records the event types that reach the `.enrichment` stage.
final class SpyEnrichmentPlugin: EnrichmentPlugin {
    private let lock = NSLock()
    private var recorded: [String] = []

    var seen: [String] { lock.withLock { recorded } }

    override func execute(event: BaseEvent) -> BaseEvent? {
        lock.withLock { recorded.append(event.eventType) }
        return event
    }
}
