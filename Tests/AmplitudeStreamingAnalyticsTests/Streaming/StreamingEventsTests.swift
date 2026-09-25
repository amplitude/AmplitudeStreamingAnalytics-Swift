import XCTest
import AmplitudeSwift

@testable import AmplitudeStreamingAnalytics

final class StreamingEventsTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_752_000_000)

    func testStartedCarriesIdentityAndPosition() {
        let event = StreamingEvents.started(content: PlayerContent(contentId: "ep-1", title: "Ep 1", deliveryMode: .onDemand),
                                            state: state(position: 10, duration: 100, insertId: "start-1"))

        XCTAssertEqual(event.eventType, "[Amplitude] Stream Started")
        XCTAssertEqual(event.insertId, "start-1")
        XCTAssertEqual(event.timestamp, 1_752_000_000_000)
        XCTAssertEqual(event.kind, .instant, "a start finalizes nothing but is never held back")
        let props = event.eventProperties!
        XCTAssertEqual(props["content_id"] as? String, "ep-1")
        XCTAssertEqual(props["title"] as? String, "Ep 1")
        XCTAssertEqual(props["delivery_mode"] as? String, "on_demand")
        XCTAssertEqual(props["media_type"] as? String, "video")
        XCTAssertEqual(props["stream_session_id"] as? String, "vs-1")
        XCTAssertEqual(props["play_id"] as? String, "play-1")
        XCTAssertEqual(props["duration"] as? TimeInterval, 100)
        XCTAssertEqual(props["start_time"] as? TimeInterval, 10)
        XCTAssertEqual(props["position"] as? TimeInterval, 10)
        XCTAssertNil(props["play_time"])
        XCTAssertNil(props["stop_reason"])
    }

    func testStoppedCarriesProgressAndReason() {
        let event = StreamingEvents.stopped(content: PlayerContent(contentId: "ep-1", deliveryMode: .onDemand),
                                            state: state(position: 25, duration: 100, playTime: 20, reason: .paused))

        XCTAssertEqual(event.eventType, "[Amplitude] Stream Stopped")
        let props = event.eventProperties!
        XCTAssertEqual(props["position"] as? TimeInterval, 25)
        XCTAssertEqual(props["start_time"] as? TimeInterval, 10)
        XCTAssertEqual(props["play_time"] as? TimeInterval, 20)
        XCTAssertEqual(props["percent_completed"] as? Double, 25)
        XCTAssertEqual(props["stop_reason"] as? String, "paused")
        XCTAssertNil(props["error_message"])
    }

    func testStoppedWithErrorCarriesMessage() {
        let event = StreamingEvents.stopped(content: PlayerContent(),
                                            state: state(position: 5, duration: 100, reason: .error, errorMessage: "boom"))

        XCTAssertEqual(event.eventProperties?["stop_reason"] as? String, "error")
        XCTAssertEqual(event.eventProperties?["error_message"] as? String, "boom")
    }

    /// The lane follows the reason: only a `timeout` leaves the row open for a later refresh.
    func testTimeoutIsTheOnlyDelayedStop() {
        XCTAssertEqual(StreamingEvents.stopped(content: PlayerContent(),
                                               state: state(position: 5, duration: 100, reason: .timeout)).kind,
                       .delayed)
        for reason: StreamingStopReason in [.paused, .ended, .error, .untracked] {
            XCTAssertEqual(StreamingEvents.stopped(content: PlayerContent(),
                                                   state: state(position: 5, duration: 100, reason: reason)).kind,
                           .instant,
                           "\(reason.rawValue) finalizes the row")
        }
    }

    func testLiveOmitsDurationAndPercentAndInfersDeliveryMode() {
        let event = StreamingEvents.stopped(content: PlayerContent(contentId: "live-1"),
                                            state: state(position: 5, duration: nil, reason: .timeout))

        let props = event.eventProperties!
        XCTAssertNil(props["duration"])
        XCTAssertNil(props["percent_completed"])
        XCTAssertEqual(props["delivery_mode"] as? String, "live")
    }

    func testPercentIsClampedAndZeroDurationIsSafe() {
        let over = StreamingEvents.stopped(content: PlayerContent(),
                                           state: state(position: 150, duration: 100, reason: .ended))
        XCTAssertEqual(over.eventProperties?["percent_completed"] as? Double, 100)

        let zero = StreamingEvents.stopped(content: PlayerContent(),
                                           state: state(position: 5, duration: 0, reason: .ended))
        XCTAssertEqual(zero.eventProperties?["percent_completed"] as? Double, 0)
    }

    func testExtraPropertiesHaveLowestPrecedence() {
        let options = PlayerContent(contentId: "real", extraEventProperties: ["content_id": "extra", "custom": 1])
        let event = StreamingEvents.started(content: options, state: state(position: 0, duration: 10))

        XCTAssertEqual(event.eventProperties?["content_id"] as? String, "real")
        XCTAssertEqual(event.eventProperties?["custom"] as? Int, 1)
    }

    private func state(position: TimeInterval,
                       duration: TimeInterval?,
                       playTime: TimeInterval = 0,
                       reason: StreamingStopReason? = nil,
                       errorMessage: String? = nil,
                       insertId: String = "stop-1") -> StreamingState {
        StreamingState(streamSessionId: "vs-1", playId: "play-1", insertId: insertId, at: at,
                       startTime: 10, position: position, duration: duration,
                       playTime: playTime, stopReason: reason, errorMessage: errorMessage)
    }
}
