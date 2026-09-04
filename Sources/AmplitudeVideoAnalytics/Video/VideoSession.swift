import AmplitudeSwift
import Foundation

/// One viewing of one piece of content. Ends on `stop()`, playback error, a new `trackVideo` for the same player,
/// or when the player goes away. You do not need to keep this handle.
public final class VideoSession {
    /// `stream_session_id` on every event this session produces.
    public let id = UUID().uuidString

    /// An emission the transport should put on the wire at once carries `forcePulse` on the event
    /// itself, so the request cannot be separated from the event that asked for it.
    var onEmit: ((DelayedEvent) -> Void)?
    var onFinal: (() -> Void)?
    let playerIdentity: ObjectIdentifier
    private(set) var isFinal = false

    private let player: Player
    private let options: VideoTrackingOptions
    private let queue: DispatchQueue
    private let now: () -> Date

    /// Slack on the advance clamp, absorbing clock and rate jitter between two readings. Being
    /// proportional, it stays negligible next to a jump, which covers ground no rate explains.
    private static let advanceSlack = 1.1

    private var playId = ""
    private var snapshotInsertId: String?
    private var startTime: TimeInterval = 0
    private var lastPosition: TimeInterval?
    private var lastReadingAt: Date?
    private var lastRate: Double = 0
    private var streamDuration: TimeInterval = 0
    private var lastSample = PlayerSample(position: 0, duration: nil, rate: 0)

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

    /// Ends the session. Idempotent, and safe from any thread — including the session's own queue,
    /// which is where `onEmit` and `onFinal` run.
    public func stop() {
        queue.async { self.finish() }
    }

    // MARK: - queue-confined

    func start() {
        guard !isFinal else { return }
        player.startObserving { [weak self] event, sample in
            guard let self else { return }
            self.queue.async { self.handle(event, sample: sample) }
        }
    }

    /// `sample` is the reading taken when the event fired. It beats one taken here, because the
    /// playhead may have moved again while the event was in flight; nil means no reading came
    /// with the event, not that the player is gone.
    func handle(_ event: PlayerEvent, sample: PlayerSample? = nil) {
        guard !isFinal else { return }
        guard let sample = sample ?? player.sample() else { return finish() }
        record(sample)
        switch event {
        case .played:
            handlePlay(sample)
        case .paused:
            handleStop(reason: .paused, sample: sample)
        case .ended:
            handleStop(reason: .ended, sample: sample)
        case .error(let message):
            // Nothing has played yet: the browser ignores these, and there is no row to finalize.
            guard !playId.isEmpty else { return }
            handleStop(reason: .error, sample: sample, errorMessage: message)
            finish()
        case .seeking:
            // Accrual no longer depends on a seek signal arriving in time — `accrue(to:)` bounds
            // every advance by what playback could have covered — so there is nothing to do here.
            break
        }
    }

    /// Re-reads the playhead and refreshes the open snapshot. `forcePulse` asks the transport to put
    /// it on the wire rather than hold it until the next pulse.
    func refresh(forcePulse: Bool = false) {
        guard !isFinal else { return }
        guard let sample = player.sample() else { return finish() }
        record(sample)
        guard isPlaying else { return }
        accrue(to: sample)
        emit(StreamingEvents.stopped(options: options, state: currentState(reason: .timeout)), forcePulse: forcePulse)
    }

    /// `untracked` if a play is open, then detach. Idempotent.
    func finish() {
        guard !isFinal else { return }
        let sample = player.sample()
        if let sample { record(sample) }
        handleStop(reason: .untracked, sample: sample)
        isFinal = true
        player.stopObserving()
        onFinal?()
        onEmit = nil
        onFinal = nil
    }

    // MARK: - state machine

    private var isPlaying: Bool { snapshotInsertId != nil }

    private func handlePlay(_ sample: PlayerSample) {
        guard !isPlaying else { return }
        playId = UUID().uuidString
        snapshotInsertId = UUID().uuidString
        startTime = sample.position
        anchor(at: sample)
        // The snapshot opens the row and rides the start's request rather than asking for its own.
        emit(StreamingEvents.stopped(options: options, state: currentState(reason: .timeout)))
        emit(StreamingEvents.started(options: options, state: currentState(reason: nil, insertId: UUID().uuidString)),
             forcePulse: true)
    }

    /// `sample` is nil only when the player vanished, in which case the last reading stands.
    private func handleStop(reason: StreamingStopReason,
                            sample: PlayerSample?,
                            errorMessage: String? = nil) {
        guard isPlaying else { return }
        if let sample {
            accrue(to: sample)
        }
        // A stop finalizes the row, so it never waits for a pulse.
        emit(StreamingEvents.stopped(options: options,
                                     state: currentState(reason: reason, errorMessage: errorMessage)),
             forcePulse: true)
        snapshotInsertId = nil
        lastPosition = nil
        lastReadingAt = nil
    }

    /// Books the playhead's advance as watch time, bounded by how far playback could actually have
    /// carried it since the previous reading. A scrub moves the playhead much faster than that, so
    /// the jump is excluded without needing a seek signal to arrive first — which it may not, since
    /// events fired on different threads reach this queue in no particular order.
    private func accrue(to sample: PlayerSample) {
        defer { anchor(at: sample) }
        guard let lastPosition, let lastReadingAt else { return }
        let advanced = sample.position - lastPosition
        guard advanced > 0 else { return }
        let elapsed = max(0, now().timeIntervalSince(lastReadingAt))
        // The faster of the two readings: a rate change mid-interval should not clip real watch time.
        let coverable = elapsed * max(lastRate, sample.rate) * Self.advanceSlack
        streamDuration += min(advanced, coverable)
    }

    private func anchor(at sample: PlayerSample) {
        lastPosition = sample.position
        lastReadingAt = now()
        lastRate = sample.rate
    }

    /// Remembers the reading so a state can be built without re-reading a player that may have
    /// disappeared in between.
    private func record(_ sample: PlayerSample) {
        lastSample = sample
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
        if forcePulse {
            event.markForcePulse()
        }
        onEmit?(event)
    }
}
