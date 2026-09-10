import AVFoundation
import Foundation
import ObjectiveC

/// `Player` over an `AVPlayer`, held weakly so the session ends when the app's player goes away.
/// AVPlayer has no seek-start signal, so seeks are read off the playhead: a jump two callbacks could not
/// have carried starts one, the next ordinary advance ends it.
/// The player's deallocation is reported as `.released` through an associated object whose `deinit` runs with it.
final class AVPlayerAdapter: Player {
    private weak var player: AVPlayer?
    // Guarded by `lock`: written from the SDK queue, read from AVFoundation's threads and the
    // releasing thread via `emit`.
    private var isObserving = false
    private let queue = DispatchQueue(label: "com.amplitude.avPlayerAdapter")
    private let lock = NSLock()
    private var position: TimeInterval = 0
    private var isSeeking = false
    private var lastDuration: TimeInterval?
    private var timeObserver: Any?
    private static let pollInterval: TimeInterval = 0.25

    private var timeControlStatusObserver: TimeControlStatusObserver?
    private var itemStatusToken: NSKeyValueObservation?
    private var didPlayToEndObserver: NSObjectProtocol?

    // Written once per `startObserving`, before any observer exists; read on AVFoundation's threads.
    private var onEvent: ((PlayerEvent) -> Void)?

    init(_ player: AVPlayer) {
        self.player = player
    }

    deinit {
        stopObserving()
    }

    // Guards against the sentinel deallocating synchronously inside `stopObserving()` (clearing the
    // associated object drops its last reference) and reporting `.released` for a player that is still alive.
    private func emit(_ event: PlayerEvent) {
        lock.lock()
        let observing = isObserving
        lock.unlock()
        guard observing else { return }
        onEvent?(event)
    }

    func playhead() -> Playhead {
        let liveDuration = player.map { duration(of: $0.currentItem) }
        lock.lock()
        defer { lock.unlock() }
        if let liveDuration { lastDuration = liveDuration }
        return Playhead(position: position, duration: lastDuration)
    }

    private func playheadMoved(to time: CMTime) {
        let seconds = time.seconds
        guard seconds.isFinite else { return }
        lock.lock()
        let isJump = abs(seconds - position) > Self.pollInterval * 2 + 0.05
        let edge: PlayerEvent?
        switch (isJump, isSeeking) {
        case (true, false): edge = .seekStarted
        case (false, true): edge = .seekEnded
        default: edge = nil
        }
        isSeeking = isJump
        position = seconds
        lock.unlock()
        if let edge { emit(edge) }
    }

    private func duration(of item: AVPlayerItem?) -> TimeInterval? {
        guard let item, !item.duration.isIndefinite else { return nil }
        let seconds = item.duration.seconds
        return seconds.isFinite ? seconds : nil
    }

    func startObserving(onEvent: @escaping (PlayerEvent) -> Void) {
        lock.lock()
        let wasObserving = isObserving
        isObserving = true
        lock.unlock()
        guard !wasObserving else { return }
        self.onEvent = onEvent
        guard let player else { return onEvent(.released) }
        let sentinel = ReleaseSentinel { [weak self] in self?.emit(.released) }
        objc_setAssociatedObject(player, Unmanaged.passUnretained(self).toOpaque(), sentinel, .OBJC_ASSOCIATION_RETAIN)

        let seconds = player.currentTime().seconds
        lock.lock()
        position = seconds.isFinite ? seconds : 0
        isSeeking = false
        lock.unlock()
        let observerInterval = CMTime(seconds: Self.pollInterval, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: observerInterval, queue: queue) { [weak self] time in
            self?.playheadMoved(to: time)
        }

        timeControlStatusObserver = TimeControlStatusObserver(player: player) { [weak self] status in
            self?.handle(status)
        }

        // Item observers are scoped to this item, never `object: nil`, so other players in the app cannot cross-talk.
        if let item = player.currentItem {
            // `.initial` so an item that failed before observation began still reports it, exactly once.
            itemStatusToken = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                guard item.status == .failed else { return }
                self?.emit(.error(message: item.error?.localizedDescription))
            }
            didPlayToEndObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: nil
            ) { [weak self] _ in self?.emit(.ended) }
        }

        // `.new`-only KVO never reports a player that was already playing.
        if player.timeControlStatus == .playing {
            onEvent(.played)
        }
    }

    func stopObserving() {
        lock.lock()
        isObserving = false
        lock.unlock()
        // Must run unlocked: clearing the associated object deallocates the sentinel synchronously,
        // and its `deinit` calls `emit`, which takes `lock` — `NSLock` is not recursive.
        if let player {
            objc_setAssociatedObject(player, Unmanaged.passUnretained(self).toOpaque(), nil, .OBJC_ASSOCIATION_RETAIN)
        }
        if let timeObserver {
            player?.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        timeControlStatusObserver?.invalidate()
        timeControlStatusObserver = nil
        itemStatusToken = nil
        if let didPlayToEndObserver {
            NotificationCenter.default.removeObserver(didPlayToEndObserver)
            self.didPlayToEndObserver = nil
        }
    }

    private func handle(_ status: AVPlayer.TimeControlStatus) {
        switch status {
        case .playing:
            emit(.played)
        case .paused:
            emit(.paused)
        case .waitingToPlayAtSpecifiedRate:
            break
        @unknown default:
            break
        }
    }
}

// Classic KVO: block-based gives `change.newValue == nil` for `@objc` enums, leaving only the live
// property, which under concurrent transitions is a newer status than the one that fired.
private final class TimeControlStatusObserver: NSObject {
    private static let keyPath = #keyPath(AVPlayer.timeControlStatus)

    private weak var player: AVPlayer?
    private let onChange: (AVPlayer.TimeControlStatus) -> Void

    init(player: AVPlayer, onChange: @escaping (AVPlayer.TimeControlStatus) -> Void) {
        self.player = player
        self.onChange = onChange
        super.init()
        player.addObserver(self, forKeyPath: Self.keyPath, options: [.new], context: nil)
    }

    deinit {
        invalidate()
    }

    // No-op once the player is gone: it took its registrations with it.
    func invalidate() {
        guard let player else { return }
        player.removeObserver(self, forKeyPath: Self.keyPath)
        self.player = nil
    }

    // swiftlint:disable:next block_based_kvo
    override func observeValue(forKeyPath keyPath: String?,
                               of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?,
                               context: UnsafeMutableRawPointer?) {
        guard keyPath == Self.keyPath,
              let raw = (change?[.newKey] as? NSNumber)?.intValue,
              let status = AVPlayer.TimeControlStatus(rawValue: raw)
        else { return }
        onChange(status)
    }
}

/// Retained by the player; its `deinit` is the player's deallocation.
private final class ReleaseSentinel {
    private let onRelease: () -> Void
    init(onRelease: @escaping () -> Void) { self.onRelease = onRelease }
    deinit { onRelease() }
}
