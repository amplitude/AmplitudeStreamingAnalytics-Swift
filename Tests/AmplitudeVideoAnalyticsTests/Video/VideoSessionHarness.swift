import Foundation

@testable import AmplitudeVideoAnalytics

/// A clock the test drives. Watch time is now bounded by elapsed wall time, so a test that moves
/// the playhead has to move the clock with it or it is describing something physically impossible.
final class TestClock {
    private let lock = NSLock()
    private var value: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_752_000_000)) { value = start }

    var now: Date { lock.withLock { value } }
    func advance(_ interval: TimeInterval) { lock.withLock { value += interval } }
}

/// A `VideoSession` plus its player, its clock, its queue and a thread-safe record of what it emitted.
///
/// `VideoSessionTests` drives the session straight from the XCTest thread, which reads well for
/// state-machine assertions but exercises none of the queue confinement the type is built on.
/// Everything here goes through ``onQueue`` instead, so the tests match how the session is
/// actually driven in production.
final class VideoSessionHarness {
    let player = FakePlayer()
    let clock = TestClock()
    let queue: DispatchQueue
    let session: VideoSession

    /// Held separately from the harness so the emit closure does not retain it back.
    private let recorder = Recorder()

    init(label: String,
         duration: TimeInterval? = 100,
         options: VideoTrackingOptions = VideoTrackingOptions(contentId: "ep-1")) {
        player.duration = duration
        queue = DispatchQueue(label: label)
        let clock = self.clock
        session = VideoSession(player: player,
                               playerIdentity: ObjectIdentifier(player),
                               options: options,
                               queue: queue,
                               now: { clock.now })
        let recorder = self.recorder
        session.onEmit = { event in recorder.record(event) }
        session.onFinal = { recorder.recordFinal() }
    }

    /// Plays for `seconds` at 1x: the playhead and the clock advance together.
    func play(forSeconds seconds: TimeInterval) {
        clock.advance(seconds)
        player.position += seconds
    }

    /// Moves the playhead without time passing, which is what a scrub looks like.
    func scrub(to position: TimeInterval) { player.position = position }

    /// Lets `seconds` pass without the playhead moving, as a pause does.
    func wait(seconds: TimeInterval) { clock.advance(seconds) }

    /// Runs `body` on the session's queue, which is where every internal entry point belongs.
    func onQueue(_ body: () -> Void) { queue.sync(execute: body) }

    /// Blocks until everything already queued has run.
    func drain() { queue.sync {} }

    var emitted: [DelayedEvent] { recorder.events }
    var forcePulseRequests: [Bool] { recorder.forcePulseRequests }
    var finalizedCount: Int { recorder.finalCount }

    var lastStreamDuration: TimeInterval? {
        emitted.last?.eventProperties?["stream_duration"] as? TimeInterval
    }

    func stopReason(at index: Int) -> String? {
        emitted[index].eventProperties?["stop_reason"] as? String
    }

    private final class Recorder {
        private let lock = NSLock()
        private var recorded: [(event: DelayedEvent, forcePulse: Bool)] = []
        private var finals = 0

        func record(_ event: DelayedEvent) {
            lock.withLock { recorded.append((event, event.forcePulse)) }
        }
        func recordFinal() { lock.withLock { finals += 1 } }

        var events: [DelayedEvent] { lock.withLock { recorded.map(\.event) } }
        var forcePulseRequests: [Bool] { lock.withLock { recorded.map(\.forcePulse) } }
        var finalCount: Int { lock.withLock { finals } }
    }
}
