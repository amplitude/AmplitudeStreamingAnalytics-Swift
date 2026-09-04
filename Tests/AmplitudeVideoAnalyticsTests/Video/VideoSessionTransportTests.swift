import XCTest
import AmplitudeSwift

@testable import AmplitudeVideoAnalytics

/// What reaches the transport when a session is wired to a real ``DelayedEventTracker``.
///
/// `forcePulse` is expressed twice — as the second parameter of `VideoSession.onEmit`, and as
/// `DelayedEvent.forcePulse`, which is what the tracker actually reads. Only the owner joins them.
///
/// Tests marked CHARACTERIZATION record behaviour that is currently wrong. They are written to
/// pass today so the suite stays green, and each one says what its assertion becomes once fixed.
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
            harness.player.position = 30
            harness.session.handle(.paused)
        }
    }

    // MARK: - CHARACTERIZATION: the two forcePulse representations never agree

    /// The session asks for a force on STARTED and on the finalizing STOPPED, but never stamps it
    /// on the `DelayedEvent` it hands over.
    ///
    /// FIX: have `emit` call `event.markForcePulse()` and drop the closure parameter, so the
    /// request travels with the event and cannot be dropped. This test then asserts that
    /// `forcePulseRequests` and the events' own flags are equal.
    func testCharacterization_emittedEventsNeverCarryTheForcePulseTheyAskFor() {
        let harness = VideoSessionHarness(label: "force-flag")
        playThenPause(harness)

        XCTAssertEqual(harness.forcePulseRequests, [false, true, true],
                       "the snapshot rides the next pulse; the start and the final stop do not")
        XCTAssertEqual(harness.emitted.map(\.forcePulse), [false, false, false],
                       "CHARACTERIZATION: DelayedEvent.forcePulse is false even when a force was asked for")
    }

    /// End to end with the real tracker: forwarding the event as handed over — the obvious
    /// wiring — sends nothing, so "a stop finalizes the row, so it never waits for a pulse"
    /// holds only if the owner remembers to copy the flag across.
    ///
    /// FIX: as above. This test then merges into `testBridgingForcePulseSendsImmediately`.
    func testCharacterization_forwardingWithoutBridgingForcePulseDefersEverything() {
        let tracker = makeTracker()
        let harness = VideoSessionHarness(label: "unbridged")
        harness.session.onEmit = { event, _ in tracker.track(event) }

        playThenPause(harness)
        Thread.sleep(forTimeInterval: 0.3)

        withExtendedLifetime(tracker) {
            XCTAssertEqual(uploader.bodies.count, 0,
                           "CHARACTERIZATION: STARTED and the finalizing STOPPED sit until the 600s pulse")
        }
    }

    /// Bridging the flag is what makes the documented behaviour true — and a play/pause fast
    /// enough to land in one tick never puts an open row on the wire at all: the finalizing
    /// STOPPED reuses the snapshot's `insert_id`, so it replaces the snapshot in the live set
    /// before the request is built. One request, both events instant, `ttl_ms: 0`.
    func testBridgingForcePulseSendsOneRequestWithTheRowAlreadyFinalized() {
        let tracker = makeTracker()
        let harness = VideoSessionHarness(label: "bridged")
        harness.session.onEmit = { event, forcePulse in
            if forcePulse { event.markForcePulse() }
            tracker.track(event)
        }

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
