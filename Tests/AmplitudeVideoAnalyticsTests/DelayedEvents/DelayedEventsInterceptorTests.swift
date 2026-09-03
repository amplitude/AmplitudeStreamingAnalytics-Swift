import XCTest
@testable import AmplitudeVideoAnalytics
import AmplitudeSwift

final class DelayedEventsInterceptorTests: XCTestCase {
    private var uploader: FakeDelayedEventsUploader!
    // Held for the test's lifetime: the interceptor retains the facade only weakly.
    private var amplitude: Amplitude!
    private var delayedEvents: DelayedEvents!

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

        let event = DelayedEvent(copying: makeEvent("ins-1"), kind: .delayed)
        event.markForcePulse()

        XCTAssertNil(delayedEvents.execute(event: event))

        waitForUploads(1)
        XCTAssertEqual(uploader.bodies[0].events.compactMap(\.insertId), ["ins-1"])
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
        delayedEvents.track(DelayedEvent(copying: makeEvent("ins-1", type: "First"), kind: .delayed), forcePulse: true)
        waitForUploads(1)

        // A refresh rides the next request rather than sending one of its own.
        delayedEvents.track(DelayedEvent(copying: makeEvent("ins-1", type: "Second"), kind: .delayed))
        delayedEvents.track(DelayedEvent(copying: makeEvent("ins-2"), kind: .delayed), forcePulse: true)
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

        delayedEvents.track(DelayedEvent(copying: event, kind: .delayed), forcePulse: true)
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
        delayedEvents.track(DelayedEvent(copying: makeEvent("ins-1"), kind: .delayed), forcePulse: true)
        waitForUploads(1)

        XCTAssertTrue(spy.seen.contains("Regular Event"), "the spy must be reached by ordinary events")
        XCTAssertFalse(spy.seen.contains("Content Stopped"))
    }

    func testFacadeCarriesTheConfiguredTtlOntoTheWire() {
        makeFacade(configuration: DelayedEventsConfiguration(ttlMs: 1_234))
        delayedEvents.track(DelayedEvent(copying: makeEvent("ins-1"), kind: .delayed), forcePulse: true)
        waitForUploads(1)

        XCTAssertEqual(uploader.bodies[0].ttlMs, 1_234)
        XCTAssertEqual(delayedEvents.configuration.ttlMs, 1_234)
    }

    /// Deterministic where a separate "send now" call would not be: the request is asked for by the
    /// refresh itself, so it cannot overtake it across the timeline hop.
    func testFacadeRefreshWithForcePulseGoesOutWithTheRefreshedValue() {
        makeFacade()
        delayedEvents.track(DelayedEvent(copying: makeEvent("ins-1", type: "First"), kind: .delayed), forcePulse: true)
        waitForUploads(1)

        delayedEvents.track(DelayedEvent(copying: makeEvent("ins-1", type: "Second"), kind: .delayed),
                            forcePulse: true)
        waitForUploads(2)
        XCTAssertEqual(uploader.bodies[1].events.map(\.eventType), ["Second"])
        XCTAssertNotEqual(uploader.bodies[1].ttlMs, 0, "nothing is finalized")
    }

    func testFacadeFlushFinalizesTheRow() {
        makeFacade()
        delayedEvents.track(DelayedEvent(copying: makeEvent("ins-1"), kind: .delayed), forcePulse: true)
        waitForUploads(1)

        delayedEvents.flush()
        waitForUploads(2)

        XCTAssertEqual(uploader.bodies[1].ttlMs, 0)
    }

    func testFacadeDiscardRotatesTheDelayId() {
        makeFacade()
        delayedEvents.track(DelayedEvent(copying: makeEvent("ins-1"), kind: .delayed), forcePulse: true)
        waitForUploads(1)

        delayedEvents.discard()
        delayedEvents.track(DelayedEvent(copying: makeEvent("ins-2"), kind: .delayed), forcePulse: true)
        waitForUploads(2)

        XCTAssertNotEqual(uploader.bodies[0].id, uploader.bodies[1].id)
    }

    // MARK: - helpers

    /// Offline and without autocapture, so only the delayed transport sees traffic.
    private func makeFacade(enrichment: SpyEnrichmentPlugin? = nil,
                            configuration: DelayedEventsConfiguration = DelayedEventsConfiguration()) {
        amplitude = Amplitude(configuration: Configuration(apiKey: "facade-\(UUID().uuidString)",
                                                           instanceName: "facade-\(UUID().uuidString)",
                                                           autocapture: [],
                                                           offline: true))
        if let enrichment {
            amplitude.add(plugin: enrichment)
        }
        let tracker = DelayedEventTracker(amplitudeConfiguration: amplitude.configuration,
                                          configuration: configuration,
                                          httpClient: uploader)
        delayedEvents = DelayedEvents(amplitude: amplitude, configuration: configuration, tracker: tracker)
    }

    private func makeEvent(_ insertId: String, type: String = "Content Stopped") -> BaseEvent {
        let event = BaseEvent(eventType: type)
        event.insertId = insertId
        return event
    }

    private func waitForUploads(_ count: Int, timeout: TimeInterval = 5) {
        let reached = expectation(description: "\(count) upload(s)")
        uploader.whenUploadCountReaches(count) { reached.fulfill() }
        wait(for: [reached], timeout: timeout)
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
