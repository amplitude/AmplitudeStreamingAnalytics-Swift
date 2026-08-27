import XCTest
@testable import AmplitudeVideoAnalytics
import AmplitudeSwift

/// `DelayedEventTracker` over a real `URLSession` against `tools/mock_delayed_server.py`.
///
/// The unit tests in `DelayedEventTrackerTests` assert what the tracker *believes* it sent, via
/// a fake uploader. These assert what a server emulating the real endpoint actually *did* with
/// it — stored a row, ingested an instant, deleted on flush — which is the half a fake cannot
/// cover: a wrong field name, a wrong timeout unit, or a body the endpoint refuses all look
/// identical from inside the SDK.
///
/// Run with:
///     tools/run_contract_tests.sh
///
/// Skipped unless `MOCK_SERVER=1`. When it *is* set, an unreachable server fails rather than
/// skips, so a broken CI wiring cannot quietly stop testing anything.
final class DelayedEventTrackerContractTests: XCTestCase {
    private var server: MockDelayedServer!
    private var tracker: DelayedEventTracker!

    private let apiKey = "contract-test-key"
    private let delayTimeoutMs: Int64 = 3_600_000

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(MockDelayedServer.isEnabled,
                          "Set MOCK_SERVER=1 with tools/mock_delayed_server.py running")
        server = MockDelayedServer()
        XCTAssertTrue(server.isHealthy(),
                      "MOCK_SERVER=1 but no server answered \(server.baseUrl)/healthcheck")
        try server.reset()
    }

    override func tearDownWithError() throws {
        if let server {
            // Every body this tracker produced must be one the endpoint accepts.
            try server.assertNoRejectedRequests()
        }
        tracker = nil
        server = nil
        try super.tearDownWithError()
    }

    // MARK: - Storage

    func testDelayedEventIsStoredAsOneRowUnderTheDelayId() throws {
        makeTracker()
        tracker.trackDelayed(makeEvent("snap-1"))

        let requests = try server.waitForRequests(1)
        let request = requests[0]
        XCTAssertEqual(request.path, "/2/httpapi/delayed")
        XCTAssertEqual(request.apiKey, apiKey)
        XCTAssertEqual(request.timeout, delayTimeoutMs)
        XCTAssertEqual(request.eventInsertIds, ["snap-1"])
        XCTAssertEqual(request.instantEvents.count, 0)
        XCTAssertEqual(request.actions, [.upsert])
        // A stored row is the only case that gets an expiration back.
        XCTAssertNotNil(request.response?["expiration"]?.intValue)

        let rows = try server.waitForRows(1)
        XCTAssertEqual(rows[0].delayId, request.id)
        XCTAssertEqual(rows[0].apiKey, apiKey)
        XCTAssertEqual(rows[0].timeoutMs, delayTimeoutMs)
        XCTAssertEqual(rows[0].storedInsertIds, ["snap-1"])
        XCTAssertEqual(rows[0].storedEvents.first?.eventType, "Content Playing")
        XCTAssertEqual(try server.ingested().count, 0, "a delayed event must not ingest yet")
    }

    func testEveryDelayedSendCarriesTheWholeLiveSet() throws {
        makeTracker()
        tracker.trackDelayed(makeEvent("a"))
        try server.waitForRequests(1)
        tracker.trackDelayed(makeEvent("b"))

        let requests = try server.waitForRequests(2)
        XCTAssertEqual(requests[0].eventInsertIds, ["a"])
        // The upsert is a full replace, so the second body must resend "a" or the server loses it.
        XCTAssertEqual(requests[1].eventInsertIds, ["a", "b"])
        XCTAssertEqual(requests[0].id, requests[1].id)

        let rows = try server.waitForRows(1)
        XCTAssertEqual(rows[0].storedInsertIds, ["a", "b"])
    }

    // MARK: - Instant events

    func testInstantEventIsIngestedAndTheStoredRowNeverCarriesIt() throws {
        makeTracker()
        tracker.trackDelayed(makeEvent("snap-1"))
        try server.waitForRequests(1)
        tracker.track(makeEvent("started", type: "Video Content Started"))

        let requests = try server.waitForRequests(2)
        let paired = requests[1]
        XCTAssertEqual(paired.timeout, delayTimeoutMs)
        XCTAssertEqual(paired.eventInsertIds, ["snap-1"])
        XCTAssertEqual(paired.instantInsertIds, ["started"])
        // Ordering guarantee: the row is written first, and only then is the instant ingested.
        XCTAssertEqual(paired.actions, [.upsert, .ingestInstant])

        let batches = try server.waitForIngested(1)
        XCTAssertEqual(batches[0].trigger, .instant)
        XCTAssertEqual(batches[0].insertIds, ["started"])
        XCTAssertEqual(batches[0].requestSeq, paired.seq)

        let rows = try server.waitForRows(1)
        XCTAssertEqual(rows[0].storedInsertIds, ["snap-1"],
                       "the instant must not be stored alongside the snapshot")
        XCTAssertNil(rows[0].storedInstantEvents,
                     "instant_events must be stripped from the stored body")
    }

    func testInstantWithNoLiveSnapshotIngestsAndRetiresTheRow() throws {
        makeTracker()
        tracker.trackDelayed(makeEvent("snap-1"))
        try server.waitForRequests(1)
        tracker.flush()
        try server.waitForRequests(2)
        try server.waitForRows(0)

        // Nothing delayed is live now, so a lone instant goes out as timeout 0.
        tracker.track(makeEvent("stopped", type: "Video Content Stopped"))
        let requests = try server.waitForRequests(3)
        XCTAssertEqual(requests[2].timeout, 0)
        XCTAssertEqual(requests[2].events.count, 0)
        XCTAssertEqual(requests[2].instantInsertIds, ["stopped"])
        XCTAssertEqual(requests[2].response?["flushed"]?.boolValue, true)
        XCTAssertEqual(try server.rows().count, 0)
    }

    // MARK: - Flush

    func testFlushIngestsTheWholeSetAndDeletesTheRow() throws {
        makeTracker()
        tracker.trackDelayed(makeEvent("a"))
        try server.waitForRequests(1)
        tracker.trackDelayed(makeEvent("b"))
        try server.waitForRequests(2)
        try server.waitForRows(1)

        tracker.flush()
        let requests = try server.waitForRequests(3)
        let flushRequest = requests[2]
        XCTAssertEqual(flushRequest.timeout, 0, "flush must ask the server to ingest and delete")
        XCTAssertEqual(flushRequest.eventInsertIds, ["a", "b"])
        XCTAssertEqual(flushRequest.response?["flushed"]?.boolValue, true)
        XCTAssertNil(flushRequest.response?["expiration"],
                     "a flushed request stored nothing, so it has no expiration")
        XCTAssertEqual(flushRequest.actions, [.flush, .delete])

        let batches = try server.waitForIngested(1)
        XCTAssertEqual(batches[0].trigger, .flush)
        XCTAssertEqual(batches[0].insertIds, ["a", "b"])
        try server.waitForRows(0)
    }

    // MARK: - Pulse

    func testPulseReUpsertsTheSameRowWithoutIngestingAnything() throws {
        makeTracker(pulseInterval: 0.3)
        tracker.trackDelayed(makeEvent("snap-1"))
        let first = try server.waitForRequests(1)[0]
        let firstRow = try server.waitForRows(1)[0]

        let requests = try server.waitForRequests(2, timeout: 5)
        XCTAssertEqual(requests[1].id, first.id, "the pulse must keep the same delay id")
        XCTAssertEqual(requests[1].timeout, delayTimeoutMs)
        XCTAssertEqual(requests[1].eventInsertIds, ["snap-1"])
        XCTAssertEqual(requests[1].actions, [.upsert])

        let rows = try server.waitForRows(1)
        XCTAssertEqual(rows[0].id, firstRow.id, "one row, replaced in place")
        XCTAssertGreaterThan(rows[0].updatedAt, firstRow.updatedAt, "the TTL must have been extended")
        XCTAssertEqual(rows[0].createdAt, firstRow.createdAt, "created_at survives a replace")
        XCTAssertEqual(try server.ingested().count, 0, "a pulse must not ingest")
    }

    // MARK: - Concurrent snapshots under one row (plan scenario 13)

    func testFinalizingOneOfTwoSnapshotsLeavesTheSurvivorsRowIntact() throws {
        makeTracker()
        tracker.trackDelayed(makeEvent("player-a"))
        try server.waitForRequests(1)
        tracker.trackDelayed(makeEvent("player-b"))
        try server.waitForRequests(2)

        // Re-tracking player-b as an instant is how a finalize reaches the wire: it rides
        // instant_events alongside the survivor's still-live snapshot.
        tracker.track(makeEvent("player-b", type: "Video Content Stopped"))

        let requests = try server.waitForRequests(3)
        let finalize = requests[2]
        XCTAssertEqual(finalize.eventInsertIds, ["player-a"])
        XCTAssertEqual(finalize.instantInsertIds, ["player-b"])
        XCTAssertEqual(finalize.timeout, delayTimeoutMs,
                       "the shared row must keep a live TTL while player-a is still playing")
        XCTAssertEqual(finalize.actions, [.upsert, .ingestInstant])

        let allActions = try server.requests().flatMap(\.actions)
        XCTAssertFalse(allActions.contains(.delete),
                       "the shared row must never be deleted out from under the survivor")
        XCTAssertFalse(try server.requests().contains { $0.timeout == 0 },
                       "no timeout: 0 while a snapshot is still live")

        let rows = try server.waitForRows(1)
        XCTAssertEqual(rows[0].storedInsertIds, ["player-a"])
        XCTAssertEqual(rows[0].timeoutMs, delayTimeoutMs)

        let batches = try server.waitForIngested(1)
        XCTAssertEqual(batches[0].trigger, .instant)
        XCTAssertEqual(batches[0].insertIds, ["player-b"])
    }

    // MARK: - TTL expiry

    func testDiscardLeavesARowTheServerIngestsAtTtlExpiry() throws {
        // 2s so the row's expiration is a second or two out; the mock sweeps promptly, where
        // real DynamoDB TTL lags. This asserts the trigger, never its latency.
        makeTracker(delayTimeoutMs: 2_000)
        tracker.trackDelayed(makeEvent("abandoned"))
        try server.waitForRequests(1)
        let row = try server.waitForRows(1)[0]
        XCTAssertEqual(row.timeoutMs, 2_000)

        // discard() sends nothing: the row is deliberately left for the server to ingest.
        tracker.discard()

        let batches = try server.waitForIngested(1, timeout: 10)
        XCTAssertEqual(batches[0].trigger, .ttl)
        XCTAssertEqual(batches[0].insertIds, ["abandoned"])
        XCTAssertEqual(batches[0].id, row.delayId)
        XCTAssertNil(batches[0].requestSeq, "a TTL ingest is caused by no request")
        XCTAssertEqual(try server.rows().count, 0, "the row is deleted before it is ingested")
        XCTAssertEqual(try server.requests().count, 1, "discard must not send")
    }

    func testDiscardRotatesTheDelayIdSoTheAbandonedRowIsUntouched() throws {
        makeTracker()
        tracker.trackDelayed(makeEvent("before"))
        try server.waitForRequests(1)

        tracker.discard()
        tracker.trackDelayed(makeEvent("after"))
        let requests = try server.waitForRequests(2)
        XCTAssertNotEqual(requests[0].id, requests[1].id)

        let rows = try server.waitForRows(2)
        XCTAssertEqual(Set(rows.map(\.storedInsertIds)), [["before"], ["after"]],
                       "two independent rows, neither overwriting the other")
    }

    // MARK: - helpers

    private func makeTracker(pulseInterval: TimeInterval = 60, delayTimeoutMs: Int64? = nil) {
        let configuration = Configuration(apiKey: apiKey,
                                          serverUrl: server.delayedEndpointServerUrl)
        tracker = DelayedEventTracker(configuration: configuration,
                                      httpClient: DelayedEventsHttpClient(configuration: configuration),
                                      pulseInterval: pulseInterval,
                                      delayTimeoutMs: delayTimeoutMs ?? self.delayTimeoutMs)
    }

    private func makeEvent(_ insertId: String, type: String = "Content Playing") -> BaseEvent {
        let event = BaseEvent(eventType: type)
        event.insertId = insertId
        return event
    }
}
