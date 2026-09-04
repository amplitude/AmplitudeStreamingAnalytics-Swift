import Foundation

@testable import AmplitudeVideoAnalytics

/// A `VideoSession` plus its player, its queue and a thread-safe record of what it emitted.
///
/// `VideoSessionTests` drives the session straight from the XCTest thread, which reads well for
/// state-machine assertions but exercises none of the queue confinement the type is built on.
/// Everything here goes through ``onQueue`` instead, so the tests match how the session is
/// actually driven in production.
final class VideoSessionHarness {
    let player = FakePlayer()
    let queue: DispatchQueue
    let session: VideoSession

    /// Held separately from the harness so the emit closure does not retain it back.
    private let recorder = Recorder()

    init(label: String,
         duration: TimeInterval? = 100,
         options: VideoTrackingOptions = VideoTrackingOptions(contentId: "ep-1"),
         now: @escaping () -> Date = Date.init) {
        player.duration = duration
        queue = DispatchQueue(label: label)
        session = VideoSession(player: player,
                               playerIdentity: ObjectIdentifier(player),
                               options: options,
                               queue: queue,
                               now: now)
        let recorder = self.recorder
        session.onEmit = { event, forcePulse in recorder.record(event, forcePulse: forcePulse) }
        session.onFinal = { recorder.recordFinal() }
    }

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

        func record(_ event: DelayedEvent, forcePulse: Bool) {
            lock.withLock { recorded.append((event, forcePulse)) }
        }
        func recordFinal() { lock.withLock { finals += 1 } }

        var events: [DelayedEvent] { lock.withLock { recorded.map(\.event) } }
        var forcePulseRequests: [Bool] { lock.withLock { recorded.map(\.forcePulse) } }
        var finalCount: Int { lock.withLock { finals } }
    }
}
