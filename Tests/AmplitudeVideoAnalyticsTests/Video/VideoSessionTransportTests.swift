import XCTest
import AmplitudeSwift

@testable import AmplitudeVideoAnalytics

/// What reaches the transport when a session is wired to a real ``DelayedEventTracker``.
///
/// `forcePulse` rides on the event itself, so forwarding an emission to the tracker is all the
/// owner has to do — there is no second flag to remember to copy across.
final class VideoSessionTransportTests: XCTestCase {
    private var uploader: FakeDelayedEventsUploader!

    override func setUp() {
        super.setUp()
        uploader = FakeDelayedEventsUploader()
        uploader.autoSettle = .success(DelayedResponseBody(id: "d", expiration: 1, flushed: nil))
    }

    /// A pulse long enough that anything sent within a test was sent because it was forced.
    private func makeTracker() -> DelayedEventTracker {
        DelayedEventTracker(amplitudeConfiguration: Configuration(apiKey: "test-key"),
                            configuration: DelayedEventsConfiguration(pulseInterval: 600,
                                                                      ttlMs: 3_600_000),
                            httpClient: uploader)
    }

    /// Play then pause: an opening snapshot that should wait, a STARTED and a finalizing STOPPED
    /// that should not.
    private func playThenPause(_ harness: VideoSessionHarness) {
        harness.onQueue {
            harness.session.handle(.played)
            harness.play(forSeconds: 30)
            harness.session.handle(.paused)
        }
    }

    /// The opening snapshot waits for a pulse; the start and the finalizing stop do not.
    func testOnlyTheOpeningSnapshotIsLeftToThePulse() {
        let harness = VideoSessionHarness(label: "force-flag")
        playThenPause(harness)

        XCTAssertEqual(harness.emitted.map(\.forcePulse), [false, true, true])
        XCTAssertEqual(harness.emitted.map(\.kind), [.delayed, .instant, .instant])
    }

    /// Forwarding emissions straight to the tracker sends at once — and a play/pause fast enough
    /// to land in one tick never puts an open row on the wire at all: the finalizing STOPPED
    /// reuses the snapshot's `insert_id`, so it replaces the snapshot in the live set before the
    /// request is built. One request, both events instant, `ttl_ms: 0`.
    func testForwardingEmissionsSendsOneRequestWithTheRowAlreadyFinalized() {
        let tracker = makeTracker()
        let harness = VideoSessionHarness(label: "forwarded")
        harness.session.onEmit = { event in tracker.track(event) }

        let sent = expectation(description: "uploaded")
        uploader.whenUploadCountReaches(1) { sent.fulfill() }
        playThenPause(harness)
        wait(for: [sent], timeout: 5)

        withExtendedLifetime(tracker) {
            XCTAssertEqual(uploader.bodies.count, 1, "the three emissions coalesce into one request")
            let body = uploader.bodies[0]

            // The stop sorts ahead of the start because it inherited the snapshot's slot in the
            // live set. Both carry their own `time`, so ingest order does not depend on this.
            XCTAssertEqual(body.instantEvents?.map(\.eventType),
                           [StreamingEvents.stoppedType, StreamingEvents.startedType])
            XCTAssertTrue(body.events.isEmpty, "the open snapshot was replaced before it ever went out")
            XCTAssertEqual(body.ttlMs, 0, "nothing is left open, so the server ingests and deletes")

            let stopped = body.instantEvents?.first
            XCTAssertEqual(stopped?.eventProperties?["stop_reason"] as? String, "paused")
            XCTAssertEqual(stopped?.eventProperties?["stream_duration"] as? TimeInterval, 30)
            XCTAssertEqual(stopped?.eventProperties?["position"] as? TimeInterval, 30)
            XCTAssertEqual(stopped?.eventProperties?["stream_session_id"] as? String, harness.session.id)
        }
    }
}
