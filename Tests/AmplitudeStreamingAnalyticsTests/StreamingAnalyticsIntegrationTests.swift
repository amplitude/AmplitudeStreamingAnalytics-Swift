import XCTest
import AmplitudeSwift

@testable import AmplitudeStreamingAnalytics

/// Real Amplitude timeline, real plugin + facade + tracker; only HTTP and the player are fake.
final class StreamingAnalyticsIntegrationTests: XCTestCase {
    func testViewSessionEndToEnd() {
        let uploader = FakeDelayedEventsUploader()
        uploader.autoSettle = .success(DelayedResponseBody(id: "d", expiration: 1, flushed: nil))
        let amplitude = Amplitude(configuration: Configuration(apiKey: "e2e-\(UUID().uuidString)",
                                                               instanceName: "e2e-\(UUID().uuidString)",
                                                               autocapture: [],
                                                               offline: true))
        let destination = RecordingDestination()
        amplitude.add(plugin: destination)
        let transport = makeTransport(on: amplitude, uploading: uploader)
        let plugin = StreamingAnalyticsPlugin(config: StreamingAnalyticsConfig(),
                                              delayedEventsFactory: { _, _ in transport },
                                              pulseTimerFactory: PulseTimer.init)
        amplitude.add(plugin: plugin)

        let player = FakePlayer()
        player.duration = 100
        plugin.trackPlayer(player: player, content: PlayerContent(contentId: "ep-1", deliveryMode: .onDemand))
        player.fire(.played)
        // Wait for the play's own request to land before pausing, so the timeout snapshot
        // is not overwritten in place by the paused final before either is ever sent.
        waitForUpload(on: uploader) { !$0.events.isEmpty }

        player.position = 50
        player.fire(.paused)

        let final = expectation(description: "final")
        let carriesPausedFinal: (DelayedRequestBody) -> Bool = {
            $0.instantEvents?.contains { $0.eventProperties?["stop_reason"] as? String == "paused" } == true
        }
        uploader.whenUploadArrives(matching: carriesPausedFinal) { final.fulfill() }
        wait(for: [final], timeout: 5)

        let all = uploader.bodies
        let started = all.compactMap(\.instantEvents).flatMap { $0 }.first { $0.eventType == StreamingEvents.startedType }!
        let snapshot = all.flatMap(\.events).first { $0.eventType == StreamingEvents.stoppedType }!
        let stopped = all.compactMap(\.instantEvents).flatMap { $0 }.first { $0.eventType == StreamingEvents.stoppedType }!

        XCTAssertNotNil(started.deviceId, "identity stamped by the timeline")
        XCTAssertNotNil(started.platform, "ContextPlugin enrichment reached the transport")
        XCTAssertEqual(snapshot.eventProperties?["stop_reason"] as? String, "timeout")
        XCTAssertEqual(snapshot.insertId, stopped.insertId)
        XCTAssertEqual(stopped.eventProperties?["percent_completed"] as? Double, 50)
        XCTAssertEqual(stopped.eventProperties?["stream_session_id"] as? String,
                       snapshot.eventProperties?["stream_session_id"] as? String)
        XCTAssertEqual(all.first?.ttlMs, DelayedEventsConfiguration().ttlMs)
        XCTAssertEqual(all.last?.ttlMs, 0)
        XCTAssertTrue(destination.seen.isEmpty, "video events never reach the normal destination")
    }

    private func makeTransport(on amplitude: Amplitude,
                               uploading uploader: FakeDelayedEventsUploader) -> DelayedEvents {
        let configuration = DelayedEventsConfiguration()
        let tracker = DelayedEventTracker(amplitudeConfiguration: amplitude.configuration,
                                          configuration: configuration,
                                          httpClient: uploader)
        return DelayedEvents(amplitude: amplitude, configuration: configuration, tracker: tracker)
    }

    private func waitForUpload(on uploader: FakeDelayedEventsUploader,
                               matching predicate: @escaping (DelayedRequestBody) -> Bool,
                               timeout: TimeInterval = 5) {
        let arrived = expectation(description: "matching upload")
        uploader.whenUploadArrives(matching: predicate) { arrived.fulfill() }
        wait(for: [arrived], timeout: timeout)
    }
}

final class RecordingDestination: DestinationPlugin {
    private let lock = NSLock()
    private var recorded: [String] = []
    var seen: [String] { lock.withLock { recorded } }

    override func execute(event: BaseEvent) -> BaseEvent? {
        lock.withLock { recorded.append(event.eventType) }
        return event
    }
}
