import AmplitudeSwift
import Foundation

/// One viewing of one piece of content. Ends on `stop()`, playback error, a new `trackVideo` for the same player,
/// or when the player goes away. You do not need to keep this handle.
public final class VideoSession {
    /// `stream_session_id` on every event this session produces.
    public let id = UUID().uuidString

    /// `forcePulse` marks an emission the transport should put on the wire at once rather than
    /// leaving to its next pulse.
    var onEmit: ((_ event: DelayedEvent, _ forcePulse: Bool) -> Void)?
    var onFinal: (() -> Void)?
    let playerIdentity: ObjectIdentifier
    private(set) var isFinal = false

    private let player: Player
    private let options: VideoTrackingOptions
    private let queue: DispatchQueue
    private let now: () -> Date

    private var playId = ""
    private var snapshotInsertId: String?
    private var startTime: TimeInterval = 0
    private var lastPosition: TimeInterval?
    private var streamDuration: TimeInterval = 0
    private var lastSample = PlayerSample(position: 0, duration: nil)

    init(player: Player,
         playerIdentity: ObjectIdentifier,
         options: VideoTrackingOptions,
         queue: DispatchQueue,
         now: @escaping () -> Date) {
        self.player = player
        self.playerIdentity = playerIdentity
        self.options = options
        self.queue = queue
        self.now = now
    }

    /// Ends the session now. Idempotent. Do not call from inside a ``Player`` callback — it waits on the SDK queue those callbacks run on.
    public func stop() {
        queue.sync { finish() }
    }

    // MARK: - queue-confined

    func start() {
        player.onEvent = { [weak self] event in
            guard let self else { return }
            self.queue.async { self.handle(event) }
        }
        player.startObserving()
    }

    func handle(_ event: PlayerEvent) {
        guard !isFinal else { return }
        switch event {
        case .played:
            handlePlay()
        case .paused:
            handleStop(reason: .paused)
        case .ended:
            handleStop(reason: .ended)
        case .error(let message):
            guard isPlaying else { return }
            handleStop(reason: .error, errorMessage: message)
            finish()
        case .seeking:
            lastPosition = nil
        }
    }

    /// Re-reads the playhead and refreshes the open snapshot. `forcePulse` asks the transport to put
    /// it on the wire rather than hold it until the next pulse.
    func refresh(forcePulse: Bool = false) {
        guard !isFinal else { return }
        guard let sample = takeSample() else { return finish() }
        guard isPlaying else { return }
        accrueStreamTime(to: sample.position)
        emit(StreamingEvents.stopped(options: options, state: currentState(reason: .timeout)), forcePulse: forcePulse)
    }

    /// `untracked` if a play is open, then detach. Idempotent.
    func finish() {
        guard !isFinal else { return }
        handleStop(reason: .untracked)
        isFinal = true
        player.onEvent = nil
        player.stopObserving()
        onFinal?()
        onEmit = nil
        onFinal = nil
    }

    // MARK: - state machine

    private var isPlaying: Bool { snapshotInsertId != nil }

    private func handlePlay() {
        guard !isPlaying else { return }
        guard let sample = takeSample() else { return finish() }
        playId = UUID().uuidString
        snapshotInsertId = UUID().uuidString
        startTime = sample.position
        lastPosition = sample.position
        // The snapshot opens the row and rides the start's request rather than asking for its own.
        emit(StreamingEvents.stopped(options: options, state: currentState(reason: .timeout)))
        emit(StreamingEvents.started(options: options, state: currentState(reason: nil, insertId: UUID().uuidString)),
             forcePulse: true)
    }

    private func handleStop(reason: StreamingStopReason, errorMessage: String? = nil) {
        guard isPlaying else { return }
        if let sample = takeSample() {
            accrueStreamTime(to: sample.position)
        }
        // A stop finalizes the row, so it never waits for a pulse.
        emit(StreamingEvents.stopped(options: options,
                                     state: currentState(reason: reason, errorMessage: errorMessage)),
             forcePulse: true)
        snapshotInsertId = nil
        lastPosition = nil
    }

    private func accrueStreamTime(to position: TimeInterval) {
        if let lastPosition {
            streamDuration += max(0, position - lastPosition)
        }
        lastPosition = position
    }

    /// Nil once the player is gone. Remembers the reading so a state can be built without
    /// re-reading a player that may have disappeared in between.
    private func takeSample() -> PlayerSample? {
        guard let sample = player.sample() else { return nil }
        lastSample = sample
        return sample
    }

    private func currentState(reason: StreamingStopReason?,
                              errorMessage: String? = nil,
                              insertId: String? = nil) -> StreamingState {
        StreamingState(streamSessionId: id,
                       playId: playId,
                       insertId: insertId ?? snapshotInsertId ?? "",
                       at: now(),
                       startTime: startTime,
                       position: lastSample.position,
                       duration: lastSample.duration,
                       streamDuration: streamDuration,
                       stopReason: reason,
                       errorMessage: errorMessage)
    }

    private func emit(_ event: DelayedEvent, forcePulse: Bool = false) {
        onEmit?(event, forcePulse)
    }
}
