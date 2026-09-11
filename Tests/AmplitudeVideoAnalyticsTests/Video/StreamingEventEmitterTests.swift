import XCTest

@testable import AmplitudeVideoAnalytics

/// Pure mapping from successive `PlayerState`s to wire events. No player, no queue.
final class StreamingEventEmitterTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_752_000_000)
    private var emitter: StreamingEventEmitter!

    override func setUp() {
        super.setUp()
        emitter = StreamingEventEmitter(options: VideoTrackingOptions(contentId: "ep-1"))
    }

    private func state(_ phase: PlayerState.Phase,
                       position: TimeInterval = 0,
                       duration: TimeInterval? = 100,
                       watchTime: TimeInterval = 0) -> PlayerState {
        PlayerState(phase: phase, position: position, duration: duration, watchTime: watchTime)
    }

    private func emit(_ phase: PlayerState.Phase,
                      position: TimeInterval = 0,
                      watchTime: TimeInterval = 0) -> [DelayedEvent] {
        let (next, events) = emitter.events(for: state(phase, position: position, watchTime: watchTime), at: at)
        emitter = next
        return events
    }

    private func string(_ name: String, _ event: DelayedEvent) -> String? { event.eventProperties?[name] as? String }
    private func number(_ name: String, _ event: DelayedEvent) -> TimeInterval? { event.eventProperties?[name] as? TimeInterval }

    func testEnteringPlayingEmitsTheSnapshotThenStarted() {
        let events = emit(.playing, position: 10)

        XCTAssertEqual(events.map(\.eventType), [StreamingEvents.stoppedType, StreamingEvents.startedType])
        XCTAssertEqual(events.map(\.kind), [.delayed, .instant])
        XCTAssertEqual(events.map(\.forcePulse), [false, true], "the snapshot rides the start's request")
        XCTAssertEqual(string("stop_reason", events[0]), "timeout")
        XCTAssertEqual(string("stream_session_id", events[1]), emitter.streamSessionId)
        XCTAssertEqual(string("play_id", events[0]), string("play_id", events[1]))
        XCTAssertEqual(number("start_time", events[1]), 10)
        XCTAssertEqual(number("position", events[1]), 10)
        XCTAssertEqual(events[1].timestamp, Int64(at.timeIntervalSince1970 * 1000))
        XCTAssertNotEqual(events[0].insertId, events[1].insertId)
    }

    func testATickWhilePlayingRefreshesTheSnapshotInPlace() {
        let snapshot = emit(.playing, position: 10)[0]
        let events = emit(.playing, position: 15, watchTime: 5)

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].kind, .delayed)
        XCTAssertFalse(events[0].forcePulse)
        XCTAssertEqual(events[0].insertId, snapshot.insertId)
        XCTAssertEqual(string("stop_reason", events[0]), "timeout")
        XCTAssertEqual(number("position", events[0]), 15)
        XCTAssertEqual(number("stream_duration", events[0]), 5)
    }

    func testLeavingPlayingFinalizesTheRowWithTheReason() {
        let snapshot = emit(.playing)[0]
        let events = emit(.stopped(.paused), position: 30, watchTime: 30)

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].kind, .instant)
        XCTAssertTrue(events[0].forcePulse)
        XCTAssertEqual(events[0].insertId, snapshot.insertId, "the same row, finalized")
        XCTAssertEqual(string("stop_reason", events[0]), "paused")
        XCTAssertEqual(number("position", events[0]), 30)
        XCTAssertEqual(number("stream_duration", events[0]), 30)
        XCTAssertNil(string("error_message", events[0]))
    }

    func testAnErrorCarriesItsMessage() {
        _ = emit(.playing)
        let events = emit(.stopped(.error(message: "boom")), position: 20, watchTime: 20)

        XCTAssertEqual(string("stop_reason", events[0]), "error")
        XCTAssertEqual(string("error_message", events[0]), "boom")
    }

    func testAReplayGetsANewPlayIdUnderTheSameStreamSession() {
        let first = emit(.playing)
        _ = emit(.stopped(.ended), position: 100, watchTime: 100)
        let replay = emit(.playing, position: 0, watchTime: 100)

        XCTAssertEqual(replay.count, 2)
        XCTAssertNotEqual(string("play_id", replay[1]), string("play_id", first[1]))
        XCTAssertNotEqual(replay[0].insertId, first[0].insertId, "a fresh snapshot row")
        XCTAssertEqual(string("stream_session_id", replay[1]), emitter.streamSessionId)
        XCTAssertEqual(number("stream_duration", replay[0]), 100, "cumulative across plays")
    }

    func testNothingIsEmittedOutsideAPlay() {
        XCTAssertTrue(emit(.stopped(.paused)).isEmpty)
        XCTAssertTrue(emit(.idle).isEmpty)
        _ = emit(.playing)
        _ = emit(.stopped(.paused))
        XCTAssertTrue(emit(.final).isEmpty, "the row was already finalized by the stop")
    }

    func testFinalStraightFromPlayingClosesTheRowAsUntracked() {
        _ = emit(.playing)
        let events = emit(.final, position: 12, watchTime: 12)

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].kind, .instant)
        XCTAssertTrue(events[0].forcePulse)
        XCTAssertEqual(string("stop_reason", events[0]), "untracked")
    }
}
