import AmplitudeSwift
import Foundation

@testable import AmplitudeVideoAnalytics

/// A `PlayerObserver` with its player, its queue, and a thread-safe record of every state it published.
final class PlayerObserverHarness {
    let player = FakePlayer()
    let logger = FakeLogger()
    let queue: DispatchQueue
    let observer: PlayerObserver

    private let recorder = Recorder()
    private let reaction = Reaction()

    init(label: String, duration: TimeInterval? = 100, started: Bool = true, pulseInterval: TimeInterval = 3600) {
        player.duration = duration
        queue = DispatchQueue(label: label)
        let recorder = self.recorder
        let reaction = self.reaction
        observer = PlayerObserver(player: player, queue: queue, pulseInterval: pulseInterval, logger: logger) { state in
            recorder.record(state)
            reaction.hook?(state)
        }
        if started { onQueue { observer.start() } }
    }

    func onQueue(_ body: () -> Void) { queue.sync(execute: body) }

    /// Two syncs in a row: the first waits for the work itself, the second waits for the publish that
    /// `commit`'s `queue.async` enqueues while that work runs.
    func drain() { queue.sync {}; queue.sync {} }

    func handle(_ event: PlayerEvent) { player.fire(event); drain() }
    func refresh() { onQueue { observer.refresh() }; drain() }
    func finish() { onQueue { observer.finish() }; drain() }
    func play(_ seconds: TimeInterval) { player.position += seconds }

    /// Runs after every state this harness records, from inside the observer's own `onChange`. Set after
    /// construction so the hook can capture `observer` without the harness capturing itself during `init`.
    func onEveryState(_ hook: @escaping (PlayerState) -> Void) { reaction.hook = hook }

    var states: [PlayerState] { recorder.states }
    var phases: [PlayerState.Phase] { states.map(\.phase) }
    var last: PlayerState? { states.last }
    var finalizedCount: Int { phases.filter { $0 == .final }.count }

    private final class Recorder {
        private let lock = NSLock()
        private var recorded: [PlayerState] = []
        func record(_ state: PlayerState) { lock.withLock { recorded.append(state) } }
        var states: [PlayerState] { lock.withLock { recorded } }
    }

    private final class Reaction {
        var hook: ((PlayerState) -> Void)?
    }
}

/// Records every message by level; the observer logs from its queue while tests read from XCTest's thread.
final class FakeLogger: Logger, @unchecked Sendable {
    typealias LogLevel = LogLevelEnum

    var logLevel = LogLevelEnum.debug.rawValue

    private let lock = NSLock()
    private var recorded: [(level: LogLevelEnum, message: String)] = []

    func error(message: String) { record(.error, message) }
    func warn(message: String) { record(.warn, message) }
    func log(message: String) { record(.log, message) }
    func debug(message: String) { record(.debug, message) }

    func messages(at level: LogLevelEnum) -> [String] {
        lock.withLock { recorded.filter { $0.level == level }.map(\.message) }
    }

    private func record(_ level: LogLevelEnum, _ message: String) {
        lock.withLock { recorded.append((level, message)) }
    }
}
