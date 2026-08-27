import XCTest
@testable import AmplitudeVideoAnalytics
import AmplitudeSwift

final class DelayedEventsInterceptorTests: XCTestCase {
    private var uploader: FakeDelayedEventsUploader!
    // Held for the test's lifetime: the facade is retained only weakly by the interceptor it
    // installs, so a local would be free to deallocate before the upload lands.
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

    func testMarkerIsSwallowedAndForwardedWithItsKind() {
        var intercepted: [(event: BaseEvent, kind: DelayedMarkerEvent.Kind)] = []
        let plugin = DelayedEventsInterceptorPlugin { intercepted.append(($0, $1)) }
        let marker = DelayedMarkerEvent(wrapping: makeEvent("a"), kind: .delayed)

        XCTAssertNil(plugin.execute(event: marker))
        XCTAssertEqual(intercepted.count, 1)
        XCTAssertEqual(intercepted.first?.kind, .delayed)
        // The enriched instance itself is forwarded, not a copy taken at wrap time.
        XCTAssertIdentical(intercepted.first?.event, marker)
    }

    func testInstantMarkerForwardsTheInstantKind() {
        var kinds: [DelayedMarkerEvent.Kind] = []
        let plugin = DelayedEventsInterceptorPlugin { kinds.append($1) }

        XCTAssertNil(plugin.execute(event: DelayedMarkerEvent(wrapping: makeEvent("a"), kind: .instant)))
        XCTAssertEqual(kinds, [.instant])
    }

    func testNonMarkerEventPassesThroughUntouched() {
        let plugin = DelayedEventsInterceptorPlugin { _, _ in XCTFail("must not intercept") }
        let event = makeEvent("a", type: "Regular Event")

        XCTAssertIdentical(plugin.execute(event: event), event)
    }

    // MARK: - marker event

    func testMarkerCopiesTheWrappedEventsFields() {
        let wrapped = makeEvent("ins-1")
        wrapped.timestamp = 1_752_000_000_000
        wrapped.sessionId = 42
        wrapped.eventProperties = ["position": 12.5]

        let marker = DelayedMarkerEvent(wrapping: wrapped, kind: .delayed)

        XCTAssertEqual(marker.eventType, wrapped.eventType)
        XCTAssertEqual(marker.insertId, "ins-1")
        XCTAssertEqual(marker.timestamp, 1_752_000_000_000)
        XCTAssertEqual(marker.sessionId, 42)
        XCTAssertEqual(marker.eventProperties?["position"] as? Double, 12.5)
    }

    /// The routing tag is transport-local: it must never reach the wire.
    func testMarkerKindIsNotEncoded() throws {
        let marker = DelayedMarkerEvent(wrapping: makeEvent("a"), kind: .delayed)

        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(marker))
        let fields = try XCTUnwrap(encoded as? [String: Any])
        XCTAssertNil(fields["kind"])
        XCTAssertEqual(fields["insert_id"] as? String, "a")
    }

    // MARK: - facade, through a real Amplitude timeline

    /// Also the ordering probe: `ContextPlugin` is registered inside `Amplitude.init` and the
    /// mediator runs `.before` plugins in insertion order, so it must precede this interceptor.
    /// A nil `platform` here means that assumption broke, not that an assertion needs relaxing.
    func testFacadeRoutesThroughRealTimelineWithEnrichment() {
        makeFacade()
        let event = makeEvent("ins-1")
        event.timestamp = 1_752_000_000_000

        delayedEvents.trackDelayed(event)
        waitForUploads(1)

        let sent = uploader.bodies[0].events[0]
        XCTAssertEqual(sent.insertId, "ins-1")
        XCTAssertEqual(sent.timestamp, 1_752_000_000_000, "client stamp must survive the timeline")
        XCTAssertNotNil(sent.deviceId, "identity stamped by the timeline")
        XCTAssertNotNil(sent.platform, "ContextPlugin enrichment must reach the interceptor")
    }

    /// The caller's own instance never reaches the transport — the marker wraps a copy of it —
    /// so a caller that keeps holding its event cannot mutate what is in flight.
    func testFacadeDoesNotHandOverTheCallersInstance() {
        makeFacade()
        let event = makeEvent("ins-1")

        delayedEvents.trackDelayed(event)
        waitForUploads(1)

        XCTAssertNotIdentical(uploader.bodies[0].events[0], event)
    }

    /// Swallowing at `.before` short-circuits the rest of the timeline, so `.enrichment` plugins
    /// never see a delayed event. Web re-tracks heartbeats through its full pipeline and does not
    /// have this gap — pinned here so a change in plugin type surfaces as a failure.
    func testDelayedEventsBypassEnrichmentPlugins() {
        let spy = SpyEnrichmentPlugin()
        makeFacade(enrichment: spy)

        amplitude.track(event: makeEvent("ins-0", type: "Regular Event"))
        delayedEvents.trackDelayed(makeEvent("ins-1"))
        waitForUploads(1)

        XCTAssertTrue(spy.seen.contains("Regular Event"), "the spy must be reached by ordinary events")
        XCTAssertFalse(spy.seen.contains("Content Stopped"))
    }

    func testFacadeTrackRidesTheInstantLane() {
        makeFacade()

        delayedEvents.track(makeEvent("ins-1"))
        waitForUploads(1)

        XCTAssertEqual(uploader.bodies[0].instantEvents?.compactMap(\.insertId), ["ins-1"])
        XCTAssertTrue(uploader.bodies[0].events.isEmpty)
    }

    func testFacadeFlushFinalizesTheRow() {
        makeFacade()
        delayedEvents.trackDelayed(makeEvent("ins-1"))
        waitForUploads(1)

        delayedEvents.flush()
        waitForUploads(2)

        XCTAssertEqual(uploader.bodies[1].timeout, 0)
    }

    func testFacadeDiscardRotatesTheDelayId() {
        makeFacade()
        delayedEvents.trackDelayed(makeEvent("ins-1"))
        waitForUploads(1)

        delayedEvents.discard()
        delayedEvents.trackDelayed(makeEvent("ins-2"))
        waitForUploads(2)

        XCTAssertNotEqual(uploader.bodies[0].id, uploader.bodies[1].id)
    }

    // MARK: - helpers

    /// Offline and without autocapture, so the host SDK's own uploader and its session events
    /// stay out of the way; only the delayed transport should see traffic.
    private func makeFacade(enrichment: SpyEnrichmentPlugin? = nil) {
        amplitude = Amplitude(configuration: Configuration(apiKey: "facade-\(UUID().uuidString)",
                                                           instanceName: "facade-\(UUID().uuidString)",
                                                           autocapture: [],
                                                           offline: true))
        if let enrichment {
            amplitude.add(plugin: enrichment)
        }
        delayedEvents = DelayedEvents(amplitude: amplitude, httpClient: uploader)
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
