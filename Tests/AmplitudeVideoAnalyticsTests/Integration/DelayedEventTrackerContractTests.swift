import XCTest
@testable import AmplitudeVideoAnalytics
import AmplitudeSwift

/// `DelayedEventTracker` over a real `URLSession` against `tools/mock_delayed_server.py`.
///
/// The unit tests in `DelayedEventTrackerTests` assert what the tracker *believes* it sent, via
/// a fake uploader. These assert what a server reproducing the real endpoint's validation
/// actually received, and what it answered — the half a fake cannot cover: a wrong field name,
/// a wrong timeout unit, or a body the endpoint refuses all look identical from inside the SDK.
///
/// Every assertion here is on `GET /debug/requests` or on the HTTP response recorded in it.
/// Nothing asserts on `GET /debug/state`: the mock documents its stored payloads as a
/// convenience for a human watching the demo app rather than a model of backend storage, so an
/// assertion there would be testing the fixture. There is no ingestion and no TTL to assert on
/// either — the mock does not model what the backend does with a payload after it is stored.
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
            // Every unscripted body this tracker produced must be one the endpoint accepts.
            try server.assertNoRejectedRequests()
        }
        tracker = nil
        server = nil
        try super.tearDownWithError()
    }

    // MARK: - The wire format

    func testDelayedEventGoesOutAsAnAcceptedPayloadUnderTheDelayId() throws {
        makeTracker()
        tracker.trackDelayed(makeEvent("snap-1"))

        let request = try server.waitForRequests(1)[0]
        XCTAssertEqual(request.path, "/2/httpapi/delayed")
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.status, 200)
        XCTAssertEqual(request.apiKey, apiKey)
        XCTAssertNotNil(request.id)
        // Milliseconds. A seconds/ms mix-up would land far under the endpoint's ceiling and be
        // invisible from inside the SDK, so this is the only place it can be caught.
        XCTAssertEqual(request.timeout, delayTimeoutMs)
        XCTAssertEqual(request.eventInsertIds, ["snap-1"])
        XCTAssertEqual(request.events.first?.eventType, "Content Playing")
        XCTAssertEqual(request.instantEvents.count, 0)
        XCTAssertTrue(request.actions.contains(.store),
                      "timeout > 0 with a non-empty events array is what the endpoint stores")
        // Only a stored payload gets an expiration back.
        XCTAssertNotNil(request.response?["expiration"]?.intValue)
        XCTAssertNil(request.response?["flushed"])
    }

    /// The load-bearing test for `DelayedRequestBody`'s `CodingKeys`. Every other assertion here
    /// reads a *parsed* field, so a renamed key would show up as a `nil` somewhere confusing (or,
    /// for `instant_events`, not at all, since the endpoint treats it as optional). This pins the
    /// exact key set the endpoint is given.
    func testDelayedRequestBodyCarriesExactlyTheContractedTopLevelKeys() throws {
        makeTracker()
        tracker.trackDelayed(makeEvent("snap-1"))
        try server.waitForRequests(1)
        tracker.track(makeEvent("started", type: "Video Content Started"))

        let requests = try server.waitForRequests(2)
        XCTAssertEqual(requests[0].bodyKeys, ["api_key", "id", "timeout", "events"],
                       "a delayed-only body carries no instant_events key at all")
        XCTAssertEqual(requests[1].bodyKeys,
                       ["api_key", "id", "timeout", "events", "instant_events"])
    }

    func testEveryDelayedSendCarriesTheWholeLiveSet() throws {
        makeTracker()
        tracker.trackDelayed(makeEvent("a"))
        try server.waitForRequests(1)
        tracker.trackDelayed(makeEvent("b"))

        let requests = try server.waitForRequests(2)
        XCTAssertEqual(requests[0].eventInsertIds, ["a"])
        // Each request fully replaces the payload held under the delay id, so the second body
        // must resend "a" or the server loses it.
        XCTAssertEqual(requests[1].eventInsertIds, ["a", "b"])
        XCTAssertEqual(requests[0].id, requests[1].id)
        XCTAssertEqual(requests[1].timeout, delayTimeoutMs)
    }

    // MARK: - Instant events

    func testInstantEventRidesAlongsideTheStillLiveSnapshot() throws {
        makeTracker()
        tracker.trackDelayed(makeEvent("snap-1"))
        try server.waitForRequests(1)
        tracker.track(makeEvent("started", type: "Video Content Started"))

        let paired = try server.waitForRequests(2)[1]
        XCTAssertEqual(paired.eventInsertIds, ["snap-1"])
        XCTAssertEqual(paired.instantInsertIds, ["started"])
        XCTAssertEqual(paired.instantEvents.first?.eventType, "Video Content Started")
        // The snapshot is still playing, so the payload must stay alive: an instant must never
        // ride a timeout that finalizes the delayed set with it.
        XCTAssertEqual(paired.timeout, delayTimeoutMs)
        XCTAssertTrue(paired.actions.contains(.store))
        XCTAssertNotNil(paired.response?["expiration"]?.intValue)
    }

    func testInstantWithNoLiveSnapshotGoesOutWithTimeoutZero() throws {
        makeTracker()
        tracker.trackDelayed(makeEvent("snap-1"))
        try server.waitForRequests(1)
        tracker.flush()
        try server.waitForRequests(2)

        // Nothing delayed is live now, so a lone instant goes out as timeout 0 — there is no
        // delayed set left for it to keep alive.
        tracker.track(makeEvent("stopped", type: "Video Content Stopped"))
        let lone = try server.waitForRequests(3)[2]
        XCTAssertEqual(lone.timeout, 0)
        XCTAssertEqual(lone.events.count, 0)
        XCTAssertEqual(lone.instantInsertIds, ["stopped"])
        XCTAssertEqual(lone.response?["flushed"]?.boolValue, true)
        XCTAssertNil(lone.response?["expiration"])
    }

    // MARK: - Flush

    func testFlushSendsTheWholeSetWithTimeoutZero() throws {
        makeTracker()
        tracker.trackDelayed(makeEvent("a"))
        try server.waitForRequests(1)
        tracker.trackDelayed(makeEvent("b"))
        try server.waitForRequests(2)

        tracker.flush()
        let flushRequest = try server.waitForRequests(3)[2]
        XCTAssertEqual(flushRequest.timeout, 0, "flush must ask the endpoint to finalize")
        XCTAssertEqual(flushRequest.eventInsertIds, ["a", "b"],
                       "the finalizing request carries the whole set, not just what changed")
        XCTAssertEqual(flushRequest.instantEvents.count, 0)
        XCTAssertEqual(flushRequest.response?["flushed"]?.boolValue, true)
        XCTAssertNil(flushRequest.response?["expiration"],
                     "a finalized request stored nothing, so it has no expiration")
        XCTAssertEqual(flushRequest.actions.first, .flush)

        // The flush settles every entry and suspends the pulse, so nothing follows it.
        try server.expectNoMoreRequests(beyond: 3)
    }

    // MARK: - Pulse

    func testPulseResendsTheSameSetUnderTheSameDelayId() throws {
        makeTracker(pulseInterval: 0.3)
        tracker.trackDelayed(makeEvent("snap-1"))
        let first = try server.waitForRequests(1)[0]

        let pulsed = try server.waitForRequests(2)[1]
        XCTAssertEqual(pulsed.id, first.id, "the pulse must keep the same delay id")
        XCTAssertEqual(pulsed.timeout, delayTimeoutMs, "the pulse is what extends the TTL")
        XCTAssertEqual(pulsed.eventInsertIds, ["snap-1"])
        XCTAssertEqual(pulsed.instantEvents.count, 0)
        XCTAssertTrue(pulsed.actions.contains(.store))
        XCTAssertNotNil(pulsed.response?["expiration"]?.intValue)
    }

    // MARK: - Concurrent snapshots under one delay id (plan scenario 13)

    func testFinalizingOneOfTwoSnapshotsKeepsTheSharedPayloadAlive() throws {
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
                       "the shared payload must keep a live TTL while player-a is still playing")
        XCTAssertFalse(requests.contains { $0.timeout == 0 },
                       "no timeout: 0 while a snapshot is still live — it would finalize the survivor too")
        XCTAssertEqual(Set(requests.compactMap(\.id)).count, 1, "one delay id throughout")
    }

    // MARK: - Discard

    func testDiscardSendsNothing() throws {
        makeTracker()
        tracker.trackDelayed(makeEvent("abandoned"))
        try server.waitForRequests(1)

        // discard() deliberately sends nothing: the payload is left for the server to expire.
        tracker.discard()
        try server.expectNoMoreRequests(beyond: 1)
    }

    func testDiscardRotatesTheDelayIdAndDropsTheAbandonedEvents() throws {
        makeTracker()
        tracker.trackDelayed(makeEvent("before"))
        try server.waitForRequests(1)

        tracker.discard()
        tracker.trackDelayed(makeEvent("after"))

        let requests = try server.waitForRequests(2)
        XCTAssertNotEqual(requests[0].id, requests[1].id,
                          "a rotated delay id is what keeps the new set off the abandoned payload")
        XCTAssertEqual(requests[1].eventInsertIds, ["after"],
                       "the discarded event must not be resent under the new id")
    }

    // MARK: - Failure paths (POST /debug/script)
    //
    // The tracker has no retry: `send(flushing:)` consumes the `Result` only to log it, and
    // success and failure take a byte-identical state transition. A scripted 500 and a scripted
    // hang-up are therefore not observably different to the SDK — both are `.failure` — so the
    // two are used below for variety of transport, not because the tracker distinguishes them.
    // What *does* differ is which entries a failure destroys, and that is what these pin.

    /// A delayed event outlives a failed plain send because such a send settles nothing: the live
    /// set is resent in full on the next send, and the pulse resends it unprompted. That is the
    /// SDK's de-facto retry and it is intended behaviour.
    ///
    /// This also pins that the tracker itself never re-sends on failure. Deferred to Task 9.5;
    /// see the `TODO: retry failed uploads with backoff` in `DelayedEventTracker.send(flushing:)`.
    func testDelayedEventSurvivesAScriptedServerErrorAndRidesTheNextRequest() throws {
        try server.queueScript([.status(500, body: ["error": .string("boom")])])
        XCTAssertEqual(try server.pendingScript().count, 1)

        makeTracker()
        tracker.trackDelayed(makeEvent("a"))

        let failed = try server.waitForRequest("the scripted 500") { $0.scripted }
        XCTAssertEqual(failed.status, 500)
        // Validation runs before the queue is consumed, so the 500 is proof the body was
        // acceptable — the endpoint got as far as choosing a response for it.
        XCTAssertEqual(failed.eventInsertIds, ["a"])
        XCTAssertEqual(failed.timeout, delayTimeoutMs)
        XCTAssertEqual(try server.pendingScript().count, 0, "the request consumed the queue entry")

        // No self-driven retry: nothing goes out until something else is tracked.
        try server.expectNoMoreRequests(beyond: 1)

        tracker.trackDelayed(makeEvent("b"))
        let resent = try server.waitForRequest("the request carrying b") {
            $0.eventInsertIds.contains("b")
        }
        XCTAssertFalse(resent.scripted, "the queue drained, so this is normal behaviour")
        XCTAssertEqual(resent.status, 200)
        XCTAssertEqual(resent.eventInsertIds, ["a", "b"],
                       "the event the failed request carried is still live and goes out again")
        XCTAssertEqual(resent.id, failed.id, "same delay id, so the payload lands in the same place")
    }

    /// An instant event does **not** survive a failed request. `settledIds` is fixed when the body
    /// is built (every `.instant` entry goes in it) and the completion removes those entries
    /// "whether the request succeeded or not", so one failure drops them permanently.
    ///
    /// CURRENT BEHAVIOUR, NOT DESIRED BEHAVIOUR — do not read this test as a specification.
    /// Retry is deferred to Task 9.5; see the `TODO: retry failed uploads with backoff` in
    /// `DelayedEventTracker.send(flushing:)`, and the unit test `testInstantEventIsDroppedAfterFailure`.
    /// Instants are the events with no second chance: unlike the delayed set, no pulse resends
    /// them, so a single hang-up loses a "Video Content Started"/"Stopped" outright.
    func testInstantEventIsLostWhenTheServerHangsUp() throws {
        try server.queueScript([.hangUp])

        makeTracker()
        // A lone instant, so the failure lands on the first request this tracker makes.
        tracker.track(makeEvent("started", type: "Video Content Started"))

        let hungUp = try server.waitForRequest("the scripted hang-up") { $0.scripted }
        XCTAssertEqual(hungUp.status, 0, "the mock logs a hang-up as status 0")
        XCTAssertEqual(hungUp.actions, [.closed])
        XCTAssertNil(hungUp.response, "the client saw a transport error, not a response")
        // The body still reached the server and still passed validation before being dropped.
        XCTAssertEqual(hungUp.instantInsertIds, ["started"])
        XCTAssertEqual(hungUp.events.count, 0)
        XCTAssertEqual(hungUp.timeout, 0)

        // Now the gap: the tracker's next request does not carry the lost instant. Matched by
        // contents, because `URLSession` may transparently re-send the hung-up request itself.
        tracker.trackDelayed(makeEvent("snap-1"))
        let next = try server.waitForRequest("the request carrying snap-1") {
            $0.eventInsertIds.contains("snap-1")
        }
        XCTAssertEqual(next.status, 200)
        XCTAssertEqual(next.eventInsertIds, ["snap-1"])
        XCTAssertEqual(next.timeout, delayTimeoutMs)
        XCTAssertEqual(next.instantEvents.count, 0,
                       "the instant was settled by the failed request and is gone for good")
        XCTAssertEqual(next.bodyKeys, ["api_key", "id", "timeout", "events"],
                       "the instant_events key is absent entirely, not sent empty")
    }

    /// A failed *flush* destroys the whole live set, delayed entries included: `flushing == true`
    /// puts every id in `settledIds`, and settled entries are removed regardless of the result.
    ///
    /// CURRENT BEHAVIOUR, NOT DESIRED BEHAVIOUR. This is the worst of the three failure shapes —
    /// total, silent loss of a completed session rather than delayed delivery — and it is the one
    /// a retry (Task 9.5) most needs to fix. Pinned here so the fix has to change a test on
    /// purpose. See also the unit test `testFlushDropsEntriesOnFailureToo`.
    func testFailedFlushLosesTheWholeLiveSet() throws {
        makeTracker()
        tracker.trackDelayed(makeEvent("a"))
        try server.waitForRequests(1)

        try server.queueScript([.hangUp])
        tracker.flush()

        let failedFlush = try server.waitForRequest("the scripted flush") { $0.scripted }
        XCTAssertEqual(failedFlush.timeout, 0)
        XCTAssertEqual(failedFlush.eventInsertIds, ["a"])
        XCTAssertEqual(failedFlush.actions, [.closed])

        tracker.trackDelayed(makeEvent("b"))
        let next = try server.waitForRequest("the request carrying b") {
            $0.eventInsertIds.contains("b")
        }
        XCTAssertEqual(next.eventInsertIds, ["b"],
                       "\"a\" was settled by the failed flush and is never resent")
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
