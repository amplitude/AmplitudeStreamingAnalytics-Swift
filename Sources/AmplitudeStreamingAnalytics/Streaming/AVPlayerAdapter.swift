import AVFoundation
import Foundation
import ObjectiveC

/// `Player` over an `AVPlayer`, held weakly so the session ends when the app's player goes away. Seeks come from
/// `AVPlayerItemTimeJumped`, which fires only after the playhead moves: `.seeked` is sent, `.seeking` is not, and
/// play time runs ~half a poll interval short per seek. `replaceCurrentItem` is not followed — stop and re-track.
final class AVPlayerAdapter: Player {
    private weak var player: AVPlayer?
    private var lastKnown = Playhead(position: 0, duration: nil)
    private var sentinelKey: UnsafeMutableRawPointer?
    // Guards `onEvent` alone: read on AVFoundation's threads, written as the SDK tears down on its own.
    private let lock = NSLock()

    private var timeControlStatusObserver: TimeControlStatusObserver?
    private var itemStatusToken: NSKeyValueObservation?
    private var didPlayToEndObserver: NSObjectProtocol?
    private var timeJumpedObserver: NSObjectProtocol?

    private var onEvent: ((PlayerEvent) -> Void)?

    init(_ player: AVPlayer) {
        self.player = player
    }

    deinit {
        stopObserving()
    }

    // Snapshot under the lock, call outside it: the lock is not recursive and the callback is the SDK's.
    private func emit(_ event: PlayerEvent) {
        let onEvent = lock.withLock { self.onEvent }
        onEvent?(event)
    }

    func playhead() -> Playhead {
        guard let player else { return lastKnown }
        let seconds = player.currentTime().seconds
        lastKnown = Playhead(position: seconds.isFinite ? seconds : lastKnown.position,
                             duration: duration(of: player.currentItem))
        return lastKnown
    }

    private func duration(of item: AVPlayerItem?) -> TimeInterval? {
        guard let item, !item.duration.isIndefinite else { return nil }
        let seconds = item.duration.seconds
        return seconds.isFinite ? seconds : nil
    }

    func startObserving(onEvent: @escaping (PlayerEvent) -> Void) {
        // Read and taken in one atomic step, so two concurrent calls cannot both get past the guard.
        let wasObserving = lock.withLock {
            guard self.onEvent == nil else { return true }
            self.onEvent = onEvent
            return false
        }
        guard !wasObserving else { return }
        guard let player else { return emit(.released) }
        sentinelKey = ReleaseSentinel.attach(to: player) { [weak self] in self?.emit(.released) }

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
            timeJumpedObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemTimeJumped, object: item, queue: nil
            ) { [weak self] _ in self?.emit(.seeked) }
        }

        // `.new`-only KVO never reports a player that was already playing.
        if player.timeControlStatus == .playing {
            emit(.played)
        }
    }

    func stopObserving() {
        lock.withLock { onEvent = nil }
        // Unlocked from here: `.initial` KVO and posted notifications reach `emit`, and the lock is not recursive.
        if let player, let sentinelKey { ReleaseSentinel.detach(from: player, key: sentinelKey) }
        sentinelKey = nil
        timeControlStatusObserver?.invalidate()
        timeControlStatusObserver = nil
        itemStatusToken = nil
        if let didPlayToEndObserver {
            NotificationCenter.default.removeObserver(didPlayToEndObserver)
            self.didPlayToEndObserver = nil
        }
        if let timeJumpedObserver {
            NotificationCenter.default.removeObserver(timeJumpedObserver)
            self.timeJumpedObserver = nil
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

// Classic KVO: block-based gives `change.newValue == nil` for `@objc` enums, leaving only the live property,
// which under concurrent transitions is newer than the status that fired.
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

/// Owns its own attachment: the player retains it, so its `deinit` is the player's deallocation.
private final class ReleaseSentinel {
    private var onRelease: (() -> Void)?
    private init(_ onRelease: @escaping () -> Void) { self.onRelease = onRelease }

    /// Keyed by the sentinel's own address, so two adapters on one player can never clear each other's.
    static func attach(to player: AVPlayer, onRelease: @escaping () -> Void) -> UnsafeMutableRawPointer {
        let sentinel = ReleaseSentinel(onRelease)
        let key = Unmanaged.passUnretained(sentinel).toOpaque()
        objc_setAssociatedObject(player, key, sentinel, .OBJC_ASSOCIATION_RETAIN)
        return key
    }

    /// Disarms first: clearing the association runs `deinit` at once, reporting a release for a live player.
    static func detach(from player: AVPlayer, key: UnsafeMutableRawPointer) {
        (objc_getAssociatedObject(player, key) as? ReleaseSentinel)?.onRelease = nil
        objc_setAssociatedObject(player, key, nil, .OBJC_ASSOCIATION_RETAIN)
    }

    deinit { onRelease?() }
}
