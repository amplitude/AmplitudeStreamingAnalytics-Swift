import XCTest
import AmplitudeSwift

@testable import AmplitudeVideoAnalytics

final class VideoSessionTests: XCTestCase {
    private var player: FakePlayer!
    private var session: VideoSession!
    private var emitted: [DelayedEvent] = []
    private var finalized = 0
    private var clock = Date(timeIntervalSince1970: 1_752_000_000)

    override func setUp() {
        super.setUp()
        player = FakePlayer()
        player.duration = 100
        session = VideoSession(player: player,
                               playerIdentity: ObjectIdentifier(player),
                               options: VideoTrackingOptions(contentId: "ep-1"),
                               queue: DispatchQueue(label: "test"),
                               now: { [unowned self] in self.clock })
        session.onEmit = { [unowned self] event, _ in self.emitted.append(event) }
        session.onFinal = { [unowned self] in self.finalized += 1 }
    }

    // MARK: - play / pause / ended

    func testFirstPlayEmitsTimeoutSnapshotDelayedThenStartedInstant() {
        player.position = 10
        session.handle(.played)

        XCTAssertEqual(emitted.count, 2)
        let snapshot = delayed(0)
        let started = instant(1)
        XCTAssertEqual(started.eventType, StreamingEvents.startedType)
        XCTAssertEqual(snapshot.eventType, StreamingEvents.stoppedType)
        XCTAssertEqual(snapshot.eventProperties?["stop_reason"] as? String, "timeout")
        XCTAssertEqual(started.eventProperties?["stream_session_id"] as? String, session.id)
        XCTAssertEqual(started.eventProperties?["play_id"] as? String, snapshot.eventProperties?["play_id"] as? String)
        XCTAssertEqual(started.eventProperties?["start_time"] as? TimeInterval, 10)
        XCTAssertNotEqual(started.insertId, snapshot.insertId)
    }

    func testDuplicatePlayedIsIgnored() {
        session.handle(.played)
        session.handle(.played)
        XCTAssertEqual(emitted.count, 2)
    }

    func testPausedEmitsFinalSnapshotAsInstantWithSameInsertId() {
        session.handle(.played)
        let liveId = delayed(0).insertId
        player.position = 30
        session.handle(.paused)

        XCTAssertEqual(emitted.count, 3)
        let final = instant(2)
        XCTAssertEqual(final.insertId, liveId)
        XCTAssertEqual(final.eventProperties?["stop_reason"] as? String, "paused")
        XCTAssertEqual(final.eventProperties?["position"] as? TimeInterval, 30)
        XCTAssertEqual(final.eventProperties?["stream_duration"] as? TimeInterval, 30)
        XCTAssertFalse(session.isFinal, "paused keeps the session open for a resume")
    }

    func testPausedWithoutPlayIsIgnored() {
        session.handle(.paused)
        XCTAssertTrue(emitted.isEmpty)
    }

    func testEndedThenPlayedIsAReplayWithNewPlayIdAndCumulativeWatchDuration() {
        session.handle(.played)
        player.position = 100
        session.handle(.ended)
        XCTAssertEqual(instant(2).eventProperties?["stop_reason"] as? String, "ended")
        let firstPlayId = instant(2).eventProperties?["play_id"] as? String

        player.position = 0
        session.handle(.played)
        player.position = 20
        session.handle(.paused)

        XCTAssertEqual(emitted.count, 6)
        XCTAssertNotEqual(instant(4).eventProperties?["play_id"] as? String, firstPlayId)
        XCTAssertEqual(instant(4).eventProperties?["stream_session_id"] as? String, session.id)
        XCTAssertEqual(instant(5).eventProperties?["stream_duration"] as? TimeInterval, 120)
    }

    // MARK: - error / seeking / ticks

    func testErrorWhilePlayingFinalizesWithMessageAndEndsTheSession() {
        session.handle(.played)
        session.handle(.error(message: "boom"))

        XCTAssertEqual(emitted.count, 3)
        XCTAssertEqual(instant(2).eventProperties?["stop_reason"] as? String, "error")
        XCTAssertEqual(instant(2).eventProperties?["error_message"] as? String, "boom")
        XCTAssertTrue(session.isFinal)
        XCTAssertEqual(finalized, 1)
        XCTAssertEqual(player.stopObservingCount, 1)
        XCTAssertNil(player.onEvent)
    }

    func testErrorBeforeFirstPlayIsIgnored() {
        session.handle(.error(message: "boom"))
        XCTAssertTrue(emitted.isEmpty)
        XCTAssertFalse(session.isFinal)
    }

    func testTicksAccruePlayheadDeltasAndPushTheSnapshot() {
        session.handle(.played)
        player.position = 5
        session.refresh()
        player.position = 12
        session.refresh()

        XCTAssertEqual(emitted.count, 4)
        XCTAssertEqual(delayed(3).eventProperties?["stream_duration"] as? TimeInterval, 12)
        XCTAssertEqual(delayed(3).eventProperties?["position"] as? TimeInterval, 12)
        XCTAssertEqual(delayed(3).insertId, delayed(0).insertId, "same live snapshot, replaced in place")
    }

    func testSeekingSkipsExactlyOneDelta() {
        session.handle(.played)
        player.position = 5
        session.refresh()
        session.handle(.seeking)
        player.position = 60
        session.refresh()
        player.position = 62
        session.refresh()

        XCTAssertEqual(delayed(4).eventProperties?["stream_duration"] as? TimeInterval, 7)
    }

    func testBackwardsMovementWithoutSeekingClampsToZero() {
        session.handle(.played)
        player.position = 5
        session.refresh()
        player.position = 2
        session.refresh()

        XCTAssertEqual(delayed(3).eventProperties?["stream_duration"] as? TimeInterval, 5)
    }

    func testTickWhilePausedEmitsNothing() {
        session.handle(.played)
        session.handle(.paused)
        session.refresh()
        XCTAssertEqual(emitted.count, 3)
    }

    // MARK: - lifetime

    func testPlayerGoneWhilePlayingFinalizesUntrackedFromLastSample() {
        session.handle(.played)
        player.position = 40
        session.refresh()
        player.isGone = true
        session.refresh()

        XCTAssertEqual(emitted.count, 4)
        XCTAssertEqual(instant(3).eventProperties?["stop_reason"] as? String, "untracked")
        XCTAssertEqual(instant(3).eventProperties?["position"] as? TimeInterval, 40)
        XCTAssertTrue(session.isFinal)
        XCTAssertEqual(finalized, 1)
    }

    func testPlayerGoneWhilePausedEndsTheSessionSilently() {
        session.handle(.played)
        session.handle(.paused)
        player.isGone = true
        session.refresh()

        XCTAssertEqual(emitted.count, 3)
        XCTAssertTrue(session.isFinal)
    }

    func testStopWhilePlayingSendsUntrackedAndIsIdempotent() {
        session.handle(.played)
        session.stop()
        session.stop()

        XCTAssertEqual(emitted.count, 3)
        XCTAssertEqual(instant(2).eventProperties?["stop_reason"] as? String, "untracked")
        XCTAssertEqual(finalized, 1)
        XCTAssertEqual(player.stopObservingCount, 1)
    }

    func testStopWithNoOpenPlaySendsNothing() {
        session.stop()
        XCTAssertTrue(emitted.isEmpty)
        XCTAssertTrue(session.isFinal)
        XCTAssertEqual(player.stopObservingCount, 1)
    }

    func testEventsAfterFinalAreIgnored() {
        session.handle(.played)
        session.stop()
        session.handle(.played)
        session.refresh()
        XCTAssertEqual(emitted.count, 3)
    }

    func testStartWiresOnEventThroughTheQueueAndSurvivesSynchronousReplay() {
        let queue = DispatchQueue(label: "wiring")
        let wired = VideoSession(player: player, playerIdentity: ObjectIdentifier(player),
                                 options: VideoTrackingOptions(), queue: queue, now: Date.init)
        var seen = 0
        wired.onEmit = { _, _ in seen += 1 }
        player.onStartObserving = { [unowned self] in self.player.fire(.played) }

        wired.start()
        queue.sync {}

        XCTAssertEqual(player.startObservingCount, 1)
        XCTAssertEqual(seen, 2, "the replayed .played opened the session")
    }

    // MARK: - helpers

    func instant(_ index: Int) -> DelayedEvent {
        let event = emitted[index]
        XCTAssertEqual(event.kind, .instant, "expected an instant at \(index)")
        return event
    }

    func delayed(_ index: Int) -> DelayedEvent {
        let event = emitted[index]
        XCTAssertEqual(event.kind, .delayed, "expected a delayed refresh at \(index)")
        return event
    }
}
