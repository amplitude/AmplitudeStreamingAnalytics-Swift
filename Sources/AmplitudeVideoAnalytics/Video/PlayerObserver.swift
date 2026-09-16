import AmplitudeSwift
import Foundation

/// The only consumer of a `Player`. Every call into the player happens on the owner's `queue`, events hop
/// onto it, readings are vetted on every pulse and event, and the result is one `PlayerState`.
final class PlayerObserver {
    /// Builds the timer that ticks `refresh()`, given the handler to tick. Tests hand back one they can fire.
    typealias MakePulse = (@escaping () -> Void) -> PulseTimer

    private var state = PlayerState()

    private let player: Player
    private let queue: DispatchQueue
    private let logger: (any Logger)?
    /// Runs on `queue` after the transition that produced the state has returned; `.final` is last. Consumers read
    /// the payload, never `state`, which may already be ahead.
    private let onChange: (PlayerState) -> Void
    private let makePulse: MakePulse
    /// Built on the first commit, because the handler it needs cannot reference `self` until init returns.
    private lazy var pulse = makePulse { [weak self] in self?.refresh() }
    private var isStarted = false
    /// Set by `.seeking`, cleared by the next event: until then the playhead is mid-jump and its advance is not play.
    private var isSeeking = false

    convenience init(player: Player,
                     queue: DispatchQueue,
                     pulseInterval: TimeInterval,
                     logger: (any Logger)? = nil,
                     onChange: @escaping (PlayerState) -> Void) {
        self.init(player: player, queue: queue, logger: logger, onChange: onChange) { tick in
            PulseTimer(interval: pulseInterval, queue: queue, handler: tick)
        }
    }

    init(player: Player,
         queue: DispatchQueue,
         logger: (any Logger)?,
         onChange: @escaping (PlayerState) -> Void,
         makePulse: @escaping MakePulse) {
        self.player = player
        self.queue = queue
        self.logger = logger
        self.onChange = onChange
        self.makePulse = makePulse
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

    /// The pulse's tick: one reading, booked while playing.
    private func refresh() {
        guard state.phase == .playing else { return }
        commit(read())
    }

    /// Idempotent.
    func finish() {
        guard state.phase != .final else { return }
        endViewing(closing: .untracked, at: read())
    }

    private func handle(_ event: PlayerEvent) {
        guard state.phase != .final else { return }
        // Hoisted so no transition below can return before an error is logged.
        if case .error(let message) = event { report("an error: \(message ?? "no message")") }
        // A released player is never read: it answers from a cache at best and with garbage at worst.
        let next = event == .released ? state : read(accruing: event != .seeked)
        // Only `.seeking` is promised to predate its jump, so only it books; readings after it land past one.
        isSeeking = event == .seeking
        switch event {
        case .played where state.phase != .playing:
            commit(next.with { $0.phase = .playing })
        case .paused where state.phase == .playing:
            commit(next.with { $0.phase = .stopped(.paused) })
        case .ended where state.phase == .playing:
            commit(next.with { $0.phase = .stopped(.ended) })
        case .seeking, .seeked:
            // Before the first play there is no position worth publishing, and none can accrue from `.idle`.
            guard state.phase != .idle else { return }
            commit(next)
        case .error(let message):
            endViewing(closing: .error(message: message), at: next)
        case .released:
            endViewing(closing: .untracked, at: next)
        case .played, .paused, .ended:
            ignore(event)
        }
    }

    /// Closes an open play at `last` with `reason`, stops the player, and commits `.final`.
    private func endViewing(closing reason: PlayerState.StopReason, at last: PlayerState) {
        guard state.phase != .final else { return }
        if state.phase == .playing { commit(last.with { $0.phase = .stopped(reason) }) }
        player.stopObserving()
        commit(state.with { $0.phase = .final })
    }

    /// The one writer of `state`; the pulse runs only while playing; publishing lands on `queue` after the caller returns.
    private func commit(_ next: PlayerState) {
        state = next
        if next.phase == .playing { pulse.resume() } else { pulse.suspend() }
        queue.async { [onChange] in onChange(next) }
    }

    /// The vetted playhead applied to `state`; while playing, its advance is booked as watch time.
    private func read(accruing: Bool = true) -> PlayerState {
        let playhead = player.playhead()

        let isValidPosition = playhead.position.isFinite && playhead.position >= 0
        let isValidDuration = playhead.duration.map { $0.isFinite && $0 >= 0 } ?? true

        if !isValidPosition { report("an invalid position \(playhead.position)") }
        if !isValidDuration, let invalid = playhead.duration { report("an invalid duration \(invalid)") }

        let position = isValidPosition ? playhead.position : state.position
        let duration = isValidDuration ? playhead.duration : state.duration

        let isPlayback = accruing && !isSeeking && state.phase == .playing
        let advance = isPlayback ? max(0, position - state.position) : 0

        return state.with { $0.position = position; $0.duration = duration; $0.watchTime += advance }
    }

    private func ignore(_ event: PlayerEvent) {
        logger?.debug(message: "PlayerObserver: ignoring \(event) while \(state.phase)")
    }

    /// The one place anything the player got wrong is logged.
    private func report(_ problem: String) {
        logger?.error(message: "PlayerObserver: the player reported \(problem)")
    }
}
