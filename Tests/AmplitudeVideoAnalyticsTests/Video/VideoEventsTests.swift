import XCTest
import AmplitudeSwift

@testable import AmplitudeVideoAnalytics

final class FakeVideoPlayer: VideoPlayer {
    var currentTime: TimeInterval = 0
    var duration: TimeInterval?
    var onEvent: ((VideoPlayerEvent) -> Void)?
    func startObserving() {}
    func stopObserving() {}
    func fire(_ event: VideoPlayerEvent) { onEvent?(event) }
}

final class VideoEventsTests: XCTestCase {
    func testStoppedSnapshotVoD() {
        let player = FakeVideoPlayer()
        player.duration = 100
        player.currentTime = 25
        let event = VideoEvents.stoppedSnapshot(
            options: VideoTrackingOptions(contentId: "ep-1", title: "Ep 1", contentType: .vod),
            player: player, viewSessionId: "vs-1", watchDuration: 20,
            stopReason: "paused", errorMessage: nil)
        XCTAssertEqual(event.eventType, "Video Content Stopped")
        let props = event.eventProperties!
        XCTAssertEqual(props["content_id"] as? String, "ep-1")
        XCTAssertEqual(props["current_time"] as? TimeInterval, 25)
        XCTAssertEqual(props["percent_completed"] as? Double, 0.25)
        XCTAssertEqual(props["stop_reason"] as? String, "paused")
        XCTAssertNotNil(event.timestamp)
    }

    func testLiveOmitsDurationAndPercent() {
        let player = FakeVideoPlayer()   // duration nil
        let event = VideoEvents.stoppedSnapshot(
            options: VideoTrackingOptions(contentId: "live-1"),
            player: player, viewSessionId: "vs-1", watchDuration: 5,
            stopReason: nil, errorMessage: nil)
        let props = event.eventProperties!
        XCTAssertNil(props["duration"])
        XCTAssertNil(props["percent_completed"])
        XCTAssertEqual(props["content_type"] as? String, "Live")
    }

    func testStartedCarriesStartPosition() {
        let player = FakeVideoPlayer()
        player.duration = 100
        let event = VideoEvents.started(
            options: VideoTrackingOptions(contentId: "ep-1", contentType: .vod),
            player: player, viewSessionId: "vs-1", startPosition: 10)
        XCTAssertEqual(event.eventType, "Video Content Started")
        XCTAssertEqual(event.eventProperties?["start_position"] as? TimeInterval, 10)
        XCTAssertEqual(event.eventProperties?["view_session_id"] as? String, "vs-1")
    }
}
