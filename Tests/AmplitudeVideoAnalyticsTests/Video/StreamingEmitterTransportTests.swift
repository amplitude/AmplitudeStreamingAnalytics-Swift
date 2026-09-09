import XCTest
import AmplitudeSwift

@testable import AmplitudeVideoAnalytics

/// Observer and emitter wired to a real `DelayedEventTracker`: what a play/pause puts on the wire.
final class StreamingEmitterTransportTests: XCTestCase {

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
        let emitter = StreamingEventEmitter(options: VideoTrackingOptions(contentId: "ep-1"))
        let at = Date(timeIntervalSince1970: 1_752_000_000)
        harness.onEveryState { state in
            for event in emitter.events(for: state, at: at) { tracker.track(event) }
        }

        // The opening request is left in flight: the tracker sends one at a time, so the pause lands in
        // the live set before the next body is built, however the observer and tracker queues interleave.
        let opened = expectation(description: "opening request")
        uploader.whenUploadCountReaches(1) { opened.fulfill() }
        harness.handle(.played)
        wait(for: [opened], timeout: 5)

        let opening = uploader.bodies[0]
        let snapshotId = try XCTUnwrap(opening.events.first?.insertId)
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
            XCTAssertEqual(stopped?.eventProperties?["stream_session_id"] as? String, emitter.streamSessionId)

            let reopened = bodies[index...].contains { $0.events.contains { $0.insertId == snapshotId } }
            XCTAssertFalse(reopened, "no request from the stop onwards leaves that row open again")
        }
    }
}

private extension DelayedRequestBody {
    func finalizes(_ insertId: String) -> Bool {
        instantEvents?.contains { $0.insertId == insertId } ?? false
    }
}
