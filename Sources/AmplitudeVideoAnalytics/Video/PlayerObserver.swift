import AmplitudeSwift
import Foundation

/// The only consumer of a `Player`. Every call into the player happens on the owner's `queue`, events hop
/// onto it, readings are vetted on every pulse and event, and the result is one `PlayerState`.
final class PlayerObserver {
    private(set) var state = PlayerState()

    private let player: Player
    private let queue: DispatchQueue
    private let pulseInterval: TimeInterval
    private let logger: (any Logger)?
    /// Runs on `queue` after the transition that produced the state has returned; `.final` is last. Consumers read
    /// the payload, never `state`, which may already be ahead.
    private let onChange: (PlayerState) -> Void
    private lazy var pulse = PulseTimer(interval: pulseInterval, queue: queue) { [weak self] in self?.refresh() }
    private var isStarted = false

    init(player: Player,
         queue: DispatchQueue,
         pulseInterval: TimeInterval,
         logger: (any Logger)? = nil,
         onChange: @escaping (PlayerState) -> Void) {
        self.player = player
        self.queue = queue
        self.pulseInterval = pulseInterval
        self.logger = logger
        self.onChange = onChange
    }

    // MARK: - called on `queue` by the owner

    func start() {
        guard state.phase != .final, !isStarted else { return }
        isStarted = true
        player.startObserving { [weak self] event in
            guard let self else { return }
            self.queue.async { self.handle(event) }
        }
    }

    /// One reading now, booked while playing. Called by the pulse, and by the owner before it sends.
    func refresh() {
        guard state.phase == .playing else { return }
        commit(read())
    }

    /// Idempotent.
    func finish() {
        guard state.phase != .final else { return }
        endViewing(closingAt: read())
    }

    private func handle(_ event: PlayerEvent) {
        guard state.phase != .final else { return }
        // Every reading-based transition leaves seeking; a seek in progress only survives a redundant event.
        let next = read().with { $0.isSeeking = false }
        switch event {
        case .played where state.phase != .playing:
            commit(next.with { $0.phase = .playing })
        // Pausing or reaching the end closes the play, not the viewing; the next `.played` is a replay.
        case .paused where state.phase == .playing:
            commit(next.with { $0.phase = .stopped(.paused) })
        case .ended where state.phase == .playing:
            commit(next.with { $0.phase = .stopped(.ended) })
        // Seeking books nothing until the playhead settles; the settled reading re-bases position.
        case .seekStarted where !state.isSeeking:
            commit(state.with { $0.isSeeking = true })
        case .seekEnded where state.isSeeking:
            commit(next)
        // An error is always logged; it closes and ends the viewing only when a play is open.
        case .error(let message):
            logger?.error(message: "PlayerObserver: player reported an error: \(message ?? "no message")")
            guard state.phase == .playing else { return }
            commit(next.with { $0.phase = .stopped(.error(message: message)) })
            endViewing(closingAt: state)
        // The player went away: an open play closes as untracked at its last reading, and the viewing ends.
        case .released:
            endViewing(closingAt: next)
        case .played, .paused, .ended, .seekStarted, .seekEnded:
            ignore(event)
        }
    }

    /// Closes an open play as untracked at `last`, stops the player, and commits `.final`.
    private func endViewing(closingAt last: PlayerState) {
        guard state.phase != .final else { return }
        if state.phase == .playing { commit(last.with { $0.phase = .stopped(.untracked); $0.isSeeking = false }) }
        player.stopObserving()
        commit(state.with { $0.phase = .final; $0.isSeeking = false })
    }

    /// The one writer of `state`; the pulse runs only while playing; publishing lands on `queue` after the caller returns.
    private func commit(_ next: PlayerState) {
        state = next
        if next.phase == .playing { pulse.resume() } else { pulse.suspend() }
        queue.async { [onChange] in onChange(next) }
    }

    /// The vetted playhead applied to `state`; while playing and not seeking, its advance is booked as watch time.
    private func read() -> PlayerState {
        let playhead = player.playhead()
        let isValidPosition = playhead.position.isFinite && playhead.position >= 0
        if !isValidPosition { report(bad: "position \(playhead.position)") }
        let position = isValidPosition ? playhead.position : state.position
        let isValidDuration = playhead.duration.map { $0.isFinite && $0 > 0 } ?? true
        if !isValidDuration { report(bad: "duration \(playhead.duration ?? .nan)") }
        let duration = isValidDuration ? playhead.duration : state.duration
        let books = state.phase == .playing && !state.isSeeking
        let watchTime = state.watchTime + (books ? max(0, position - state.position) : 0)
        return state.with { $0.position = position; $0.duration = duration; $0.watchTime = watchTime }
    }

    private func ignore(_ event: PlayerEvent) {
        logger?.debug(message: "PlayerObserver: ignoring \(event) while \(state.phase)")
    }

    private func report(bad reading: String) {
        logger?.error(message: "PlayerObserver: player reported an invalid \(reading); keeping the last good reading")
    }
}
