import XCTest
import AmplitudeSwift

@testable import AmplitudeStreamingAnalytics

/// Observer and transformer wired to a real `DelayedEventTracker`: what a play/pause puts on the wire.
final class StreamingTransportTests: XCTestCase {

    /// A play opens a snapshot row and a pause finalizes it: the STOPPED reuses the snapshot's
    /// `insert_id`, so the last request naming that row carries the finalized instant with `ttl_ms: 0`,
    /// with no open snapshot left behind it.
    func testAPlayAndPauseFinalizeTheSnapshotRowOnTheWire() throws {
        let uploader = FakeDelayedEventsUploader()
        let tracker = DelayedEventTracker(amplitudeConfiguration: Configuration(apiKey: "test-key"),
                                          configuration: DelayedEventsConfiguration(pulseInterval: 600,
                                                                                    ttlMs: 3_600_000),
                                          httpClient: uploader)
        let harness = PlayerObserverHarness(label: "forwarded")
        let transformer = PlayerStateTransformer(content: PlayerContent(contentId: "ep-1"))
        let at = Date(timeIntervalSince1970: 1_752_000_000)
        harness.onEveryState { state in
            transformer.events(for: state, at: at).forEach { tracker.track($0) }
        }

        // The opening request is left in flight: the tracker sends one at a time, so the pause lands in
        // the live set before the next body is built, however the observer and tracker queues interleave.
        let opened = expectation(description: "opening request")
        uploader.whenUploadCountReaches(1) { opened.fulfill() }
        harness.handle(.played)
        wait(for: [opened], timeout: 5)

        let opening = uploader.bodies[0]
        let snapshotId = try XCTUnwrap(opening.events.first?.insertId)
        let streamSessionId = opening.instantEvents?.first?.eventProperties?["stream_session_id"] as? String
        XCTAssertEqual(opening.instantEvents?.map(\.eventType), [StreamingEvents.startedType])
        XCTAssertEqual((opening.instantEvents?.first as? DelayedEvent)?.forcePulse, true,
                       "the STARTED is forced, which is why it went out ahead of the pulse")

        harness.onQueue { harness.player.position = 30 }
        harness.handle(.paused)

        let finalized = expectation(description: "finalizing request")
        uploader.whenUploadArrives(matching: { body in body.finalizes(snapshotId) },
                                   notify: { finalized.fulfill() })
        uploader.settle(at: 0, with: .success(DelayedResponseBody(id: "d", expiration: 1, flushed: nil)))
        wait(for: [finalized], timeout: 5)

        try withExtendedLifetime(tracker) {
            let bodies = uploader.bodies
            let index = try XCTUnwrap(bodies.firstIndex { $0.finalizes(snapshotId) })
            let closing = bodies[index]
            XCTAssertEqual(closing.ttlMs, 0, "nothing is left open, so the server ingests and deletes")
            XCTAssertTrue(closing.events.isEmpty, "the snapshot was replaced by its own finalizing stop")

            let stopped = closing.instantEvents?.first
            XCTAssertEqual(stopped?.eventType, StreamingEvents.stoppedType)
            XCTAssertEqual(stopped?.eventProperties?["stop_reason"] as? String, "paused")
            XCTAssertEqual(stopped?.eventProperties?["stream_duration"] as? TimeInterval, 30)
            XCTAssertEqual(stopped?.eventProperties?["position"] as? TimeInterval, 30)
            XCTAssertEqual(stopped?.eventProperties?["stream_session_id"] as? String, streamSessionId)

            let reopened = bodies[index...].contains { $0.events.contains { $0.insertId == snapshotId } }
            XCTAssertFalse(reopened, "no request from the stop onwards leaves that row open again")
        }
    }

    /// The STARTED is what forces the opening request, so the pending stop has to be tracked first: were the
    /// caller preempted between the two, a start-first order would ship a request with no delayed entry, and
    /// `ttl_ms: 0` has the server ingest and delete it — the play would then hold no row until the next pulse.
    func testTheOpeningPendingStopNeverShipsWithoutTheStart() throws {
        let uploader = FakeDelayedEventsUploader()
        let tracker = DelayedEventTracker(amplitudeConfiguration: Configuration(apiKey: "test-key"),
                                          configuration: DelayedEventsConfiguration(pulseInterval: 600,
                                                                                    ttlMs: 3_600_000),
                                          httpClient: uploader)
        let transformer = PlayerStateTransformer(content: PlayerContent(contentId: "ep-1"))
        let state = PlayerState(phase: .playing, position: 0, duration: 100, watchTime: 0)
        let opening = transformer.events(for: state, at: Date(timeIntervalSince1970: 1_752_000_000))

        XCTAssertEqual(opening.map(\.kind), [.delayed, .instant], "the forced instant must be tracked last")

        tracker.track(opening[0])
        let premature = expectation(description: "the pending stop alone forces nothing")
        premature.isInverted = true
        uploader.whenUploadCountReaches(1) { premature.fulfill() }
        wait(for: [premature], timeout: 1)

        tracker.track(opening[1])
        let sent = expectation(description: "the request the start forces")
        uploader.whenUploadCountReaches(1) { sent.fulfill() }
        wait(for: [sent], timeout: 5)

        try withExtendedLifetime(tracker) {
            let body = uploader.bodies[0]
            XCTAssertEqual(body.events.map(\.insertId), [opening[0].insertId], "the row rides the start's request")
            XCTAssertEqual(body.instantEvents?.map(\.insertId), [opening[1].insertId])
            XCTAssertEqual(body.ttlMs, 3_600_000, "a body carrying a delayed entry keeps the row alive")
        }
    }
}

private extension DelayedRequestBody {
    func finalizes(_ insertId: String) -> Bool {
        instantEvents?.contains { $0.insertId == insertId } ?? false
    }
}
