import XCTest
import AmplitudeSwift

@testable import AmplitudeStreamingAnalytics

final class StreamingEventsTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_752_000_000)

    func testStartedCarriesIdentityAndPosition() {
        let event = StreamingEvents.started(content: PlayerContent(contentId: "ep-1", title: "Ep 1", deliveryMode: .onDemand),
                                            state: state(position: 10, duration: 100, insertId: "start-1"))

        XCTAssertEqual(event.eventType, "[Streaming] Stream Started")
        XCTAssertEqual(event.insertId, "start-1")
        XCTAssertEqual(event.timestamp, 1_752_000_000_000)
        XCTAssertEqual(event.kind, .instant, "a start finalizes nothing but is never held back")
        let props = event.eventProperties!
        XCTAssertEqual(props["[Streaming] Content ID"] as? String, "ep-1")
        XCTAssertEqual(props["[Streaming] Title"] as? String, "Ep 1")
        XCTAssertEqual(props["[Streaming] Delivery Mode"] as? String, "on_demand")
        XCTAssertEqual(props["[Streaming] Media Type"] as? String, "video")
        XCTAssertEqual(props["[Streaming] Stream Session ID"] as? String, "vs-1")
        XCTAssertEqual(props["[Streaming] Play ID"] as? String, "play-1")
        XCTAssertEqual(props["[Streaming] Duration Sec"] as? TimeInterval, 100)
        XCTAssertEqual(props["[Streaming] Start Position Sec"] as? TimeInterval, 10)
        XCTAssertEqual(props["[Streaming] Position Sec"] as? TimeInterval, 10)
        XCTAssertNil(props["[Streaming] Play Time Sec"])
        XCTAssertNil(props["[Streaming] Play Time Total Sec"])
        XCTAssertNil(props["[Streaming] Stop Reason"])
    }

    func testStoppedCarriesProgressAndReason() {
        let event = StreamingEvents.stopped(content: PlayerContent(contentId: "ep-1", deliveryMode: .onDemand),
                                            state: state(position: 25, duration: 100, playTime: 20, playTimeTotal: 45, reason: .paused))

        XCTAssertEqual(event.eventType, "[Streaming] Stream Stopped")
        let props = event.eventProperties!
        XCTAssertEqual(props["[Streaming] Position Sec"] as? TimeInterval, 25)
        XCTAssertEqual(props["[Streaming] Start Position Sec"] as? TimeInterval, 10)
        XCTAssertEqual(props["[Streaming] Play Time Sec"] as? TimeInterval, 20)
        XCTAssertEqual(props["[Streaming] Play Time Total Sec"] as? TimeInterval, 45)
        XCTAssertEqual(props["[Streaming] Percent Completed"] as? Double, 25)
        XCTAssertEqual(props["[Streaming] Stop Reason"] as? String, "paused")
        XCTAssertNil(props["[Streaming] Error Message"])
    }

    func testStoppedWithErrorCarriesMessage() {
        let event = StreamingEvents.stopped(content: PlayerContent(),
                                            state: state(position: 5, duration: 100, reason: .error, errorMessage: "boom"))

        XCTAssertEqual(event.eventProperties?["[Streaming] Stop Reason"] as? String, "error")
        XCTAssertEqual(event.eventProperties?["[Streaming] Error Message"] as? String, "boom")
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
        XCTAssertNil(props["[Streaming] Duration Sec"])
        XCTAssertNil(props["[Streaming] Percent Completed"])
        XCTAssertEqual(props["[Streaming] Delivery Mode"] as? String, "live")
    }

    func testPercentIsClampedAndZeroDurationIsSafe() {
        let over = StreamingEvents.stopped(content: PlayerContent(),
                                           state: state(position: 150, duration: 100, reason: .ended))
        XCTAssertEqual(over.eventProperties?["[Streaming] Percent Completed"] as? Double, 100)

        let zero = StreamingEvents.stopped(content: PlayerContent(),
                                           state: state(position: 5, duration: 0, reason: .ended))
        XCTAssertEqual(zero.eventProperties?["[Streaming] Percent Completed"] as? Double, 0)
    }

    func testExtraPropertiesHaveLowestPrecedence() {
        let options = PlayerContent(contentId: "real", extraEventProperties: ["[Streaming] Content ID": "extra", "custom": 1])
        let event = StreamingEvents.started(content: options, state: state(position: 0, duration: 10))

        XCTAssertEqual(event.eventProperties?["[Streaming] Content ID"] as? String, "real")
        XCTAssertEqual(event.eventProperties?["custom"] as? Int, 1)
    }

    private func state(position: TimeInterval,
                       duration: TimeInterval?,
                       playTime: TimeInterval = 0,
                       playTimeTotal: TimeInterval = 0,
                       reason: StreamingStopReason? = nil,
                       errorMessage: String? = nil,
                       insertId: String = "stop-1") -> StreamingState {
        StreamingState(streamSessionId: "vs-1", playId: "play-1", insertId: insertId, at: at,
                       startPosition: 10, position: position, duration: duration,
                       playTime: playTime, playTimeTotal: playTimeTotal, stopReason: reason, errorMessage: errorMessage)
    }
}
