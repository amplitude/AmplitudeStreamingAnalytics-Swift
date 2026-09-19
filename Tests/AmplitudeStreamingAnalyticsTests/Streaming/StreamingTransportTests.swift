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
        uploader.autoSettle = .success(DelayedResponseBody(id: "d", expiration: 1, flushed: nil))
        let tracker = makeTracker(uploading: uploader)
        let harness = PlayerObserverHarness(label: "forwarded")
        let transformer = PlayerStateTransformer(content: PlayerContent(contentId: "ep-1"))
        let at = Date(timeIntervalSince1970: 1_752_000_000)
        harness.onEveryState { state in
            transformer.events(for: state, at: at).forEach { tracker.track($0) }
        }

        harness.handle(.played)
        let opening = waitForUpload(on: uploader) { !$0.events.isEmpty }
        let snapshotId = try XCTUnwrap(opening.events.first?.insertId)
        XCTAssertEqual(opening.ttlMs, 3_600_000, "the pending stop's appearance opens the row")

        let started = try XCTUnwrap(waitForUpload(on: uploader, matching: carriesStart)
            .instantEvents?.first { $0.eventType == StreamingEvents.startedType })
        let streamSessionId = started.eventProperties?["stream_session_id"] as? String

        harness.onQueue { harness.player.position = 30 }
        harness.handle(.paused)
        waitForUpload(on: uploader) { $0.finalizes(snapshotId) }

        try withExtendedLifetime(tracker) {
            let bodies = uploader.bodies
            let index = try XCTUnwrap(bodies.firstIndex { $0.finalizes(snapshotId) })
            let closing = bodies[index]
            XCTAssertEqual(closing.ttlMs, 0, "nothing is left open, so the server ingests and deletes")
            XCTAssertTrue(closing.events.isEmpty, "the snapshot was replaced by its own finalizing stop")

            let stopped = closing.instantEvents?.first { $0.eventType == StreamingEvents.stoppedType }
            XCTAssertEqual(stopped?.eventProperties?["stop_reason"] as? String, "paused")
            XCTAssertEqual(stopped?.eventProperties?["stream_duration"] as? TimeInterval, 30)
            XCTAssertEqual(stopped?.eventProperties?["position"] as? TimeInterval, 30)
            XCTAssertEqual(stopped?.eventProperties?["stream_session_id"] as? String, streamSessionId)

            let reopened = bodies[index...].contains { $0.events.contains { $0.insertId == snapshotId } }
            XCTAssertFalse(reopened, "no request from the stop onwards leaves that row open again")
        }
    }

    /// The pending stop is the row's first live entry, so its own appearance opens the row: the start
    /// no longer has to be tracked last to keep a `ttl_ms: 0` request from ingesting an empty one. The
    /// start is written either way and rides the first request that goes out.
    func testTheOpeningPendingStopOpensTheRowOnItsOwn() {
        let uploader = FakeDelayedEventsUploader()
        uploader.autoSettle = .success(DelayedResponseBody(id: "d", expiration: 1, flushed: nil))
        let tracker = makeTracker(uploading: uploader)
        let transformer = PlayerStateTransformer(content: PlayerContent(contentId: "ep-1"))
        let state = PlayerState(phase: .playing, position: 0, duration: 100, watchTime: 0)
        let opening = transformer.events(for: state, at: Date(timeIntervalSince1970: 1_752_000_000))

        XCTAssertEqual(opening.map(\.kind), [.delayed, .instant])

        tracker.track(opening[0])
        tracker.track(opening[1])

        let opened = waitForUpload(on: uploader) { !$0.events.isEmpty }
        XCTAssertEqual(opened.events.map(\.insertId), [opening[0].insertId])
        XCTAssertEqual(opened.ttlMs, 3_600_000, "a body carrying a delayed entry keeps the row alive")

        withExtendedLifetime(tracker) {
            _ = waitForUpload(on: uploader) { body in
                body.instantEvents?.contains { $0.insertId == opening[1].insertId } == true
            }
        }
    }

    private let carriesStart: (DelayedRequestBody) -> Bool = { body in
        body.instantEvents?.contains { $0.eventType == StreamingEvents.startedType } == true
    }

    /// A brisk pulse: past the row's appearance, nothing but the pulse sends.
    private func makeTracker(uploading uploader: FakeDelayedEventsUploader) -> DelayedEventTracker {
        DelayedEventTracker(amplitudeConfiguration: Configuration(apiKey: "test-key"),
                            configuration: DelayedEventsConfiguration(pulseInterval: 0.05,
                                                                      ttlMs: 3_600_000),
                            httpClient: uploader,
                            snapshots: makeSnapshotStore())
    }

    @discardableResult
    private func waitForUpload(on uploader: FakeDelayedEventsUploader,
                               matching predicate: @escaping (DelayedRequestBody) -> Bool) -> DelayedRequestBody {
        let arrived = expectation(description: "matching upload")
        uploader.whenUploadArrives(matching: predicate) { arrived.fulfill() }
        wait(for: [arrived], timeout: 5)
        return uploader.bodies.first(where: predicate) ?? uploader.bodies[0]
    }
}

private extension DelayedRequestBody {
    func finalizes(_ insertId: String) -> Bool {
        instantEvents?.contains { $0.insertId == insertId } ?? false
    }
}
