import XCTest

@testable import AmplitudeStreamingAnalytics

/// Pure mapping from successive `PlayerState`s to wire events. No player, no queue.
final class PlayerStateTransformerTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_752_000_000)
    private var transformer: PlayerStateTransformer!

    override func setUp() {
        super.setUp()
        transformer = PlayerStateTransformer(content: PlayerContent(contentId: "ep-1"))
    }

    private func state(_ phase: PlayerState.Phase,
                       position: TimeInterval = 0,
                       duration: TimeInterval? = 100,
                       playTime: TimeInterval = 0) -> PlayerState {
        PlayerState(phase: phase, position: position, duration: duration, playTime: playTime)
    }

    private func emit(_ phase: PlayerState.Phase,
                      position: TimeInterval = 0,
                      playTime: TimeInterval = 0) -> [DelayedEvent] {
        transformer.events(for: state(phase, position: position, playTime: playTime), at: at)
    }

    private func string(_ name: String, _ event: DelayedEvent) -> String? { event.eventProperties?[name] as? String }
    private func number(_ name: String, _ event: DelayedEvent) -> TimeInterval? { event.eventProperties?[name] as? TimeInterval }

    func testEnteringPlayingEmitsThePendingStopThenStarted() {
        let events = emit(.playing, position: 10)

        XCTAssertEqual(events.map(\.eventType), [StreamingEvents.stoppedType, StreamingEvents.startedType],
                       "order matters: the start forces the request, so the pending stop must be tracked first")
        XCTAssertEqual(events.map(\.kind), [.delayed, .instant])
        XCTAssertEqual(events.map(\.forcePulse), [false, true], "the pending stop rides the start's request")
        XCTAssertEqual(string("[Streaming] Stop Reason", events[0]), "timeout")
        XCTAssertEqual(string("[Streaming] Stream Session ID", events[0]), string("[Streaming] Stream Session ID", events[1]))
        XCTAssertEqual(string("[Streaming] Play ID", events[0]), string("[Streaming] Play ID", events[1]))
        XCTAssertEqual(number("[Streaming] Start Position Sec", events[1]), 10)
        XCTAssertEqual(number("[Streaming] Position Sec", events[1]), 10)
        XCTAssertEqual(events[1].timestamp, Int64(at.timeIntervalSince1970 * 1000))
        XCTAssertNotEqual(events[0].insertId, events[1].insertId)
    }

    func testATickWhilePlayingRefreshesTheSnapshotInPlace() {
        let snapshot = emit(.playing, position: 10)[0]
        let events = emit(.playing, position: 15, playTime: 5)

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].kind, .delayed)
        XCTAssertFalse(events[0].forcePulse)
        XCTAssertEqual(events[0].insertId, snapshot.insertId)
        XCTAssertEqual(string("[Streaming] Stop Reason", events[0]), "timeout")
        XCTAssertEqual(number("[Streaming] Position Sec", events[0]), 15)
        XCTAssertEqual(number("[Streaming] Play Time Sec", events[0]), 5)
    }

    func testLeavingPlayingFinalizesTheRowWithTheReason() {
        let snapshot = emit(.playing)[0]
        let events = emit(.stopped(.paused), position: 30, playTime: 30)

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].kind, .instant)
        XCTAssertTrue(events[0].forcePulse)
        XCTAssertEqual(events[0].insertId, snapshot.insertId, "the same row, finalized")
        XCTAssertEqual(string("[Streaming] Stop Reason", events[0]), "paused")
        XCTAssertEqual(number("[Streaming] Position Sec", events[0]), 30)
        XCTAssertEqual(number("[Streaming] Play Time Sec", events[0]), 30)
        XCTAssertNil(string("[Streaming] Error Message", events[0]))
    }

    func testAnErrorCarriesItsMessage() {
        _ = emit(.playing)
        let events = emit(.stopped(.error(message: "boom")), position: 20, playTime: 20)

        XCTAssertEqual(string("[Streaming] Stop Reason", events[0]), "error")
        XCTAssertEqual(string("[Streaming] Error Message", events[0]), "boom")
    }

    func testAReplayGetsANewPlayIdUnderTheSameStreamSession() {
        let first = emit(.playing)
        _ = emit(.stopped(.ended), position: 100, playTime: 100)
        let replay = emit(.playing, position: 0, playTime: 100)

        XCTAssertEqual(replay.count, 2)
        XCTAssertNotEqual(string("[Streaming] Play ID", replay[1]), string("[Streaming] Play ID", first[1]))
        XCTAssertNotEqual(replay[0].insertId, first[0].insertId, "a fresh pending stop")
        XCTAssertEqual(string("[Streaming] Stream Session ID", replay[1]), string("[Streaming] Stream Session ID", first[1]))
        XCTAssertEqual(number("[Streaming] Play Time Sec", replay[0]), 0, "a new play starts from zero")
        XCTAssertEqual(number("[Streaming] Play Time Total Sec", replay[0]), 100, "the session total carries on")
    }

    func testPlayTimeResetsPerPlayWhileTheTotalRunsOn() {
        _ = emit(.playing)
        let firstStop = emit(.stopped(.paused), position: 30, playTime: 30)
        _ = emit(.playing, position: 30, playTime: 30)
        let secondStop = emit(.stopped(.paused), position: 50, playTime: 50)

        XCTAssertEqual(number("[Streaming] Play Time Sec", firstStop[0]), 30)
        XCTAssertEqual(number("[Streaming] Play Time Total Sec", firstStop[0]), 30)
        XCTAssertEqual(number("[Streaming] Play Time Sec", secondStop[0]), 20, "only what this play accrued")
        XCTAssertEqual(number("[Streaming] Play Time Total Sec", secondStop[0]), 50)
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
        let events = emit(.final, position: 12, playTime: 12)

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].kind, .instant)
        XCTAssertTrue(events[0].forcePulse)
        XCTAssertEqual(string("[Streaming] Stop Reason", events[0]), "untracked")
    }
}
