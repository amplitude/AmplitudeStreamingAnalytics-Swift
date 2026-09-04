import AVFoundation
import Foundation

/// `Player` over an `AVPlayer`, held weakly so the session ends when the app's player goes away.
final class AVPlayerAdapter: Player {
    private weak var player: AVPlayer?
    private var isObserving = false

    private var timeControlStatusObserver: TimeControlStatusObserver?
    private var itemStatusToken: NSKeyValueObservation?
    private var didPlayToEndObserver: NSObjectProtocol?
    private var timeJumpedObserver: NSObjectProtocol?

    // Written once per `startObserving`, before any observer exists; read on AVFoundation's threads.
    private var onEvent: ((PlayerEvent) -> Void)?

    init(_ player: AVPlayer) {
        self.player = player
    }

    deinit {
        stopObserving()
    }

    private func emit(_ event: PlayerEvent) {
        onEvent?(event)
    }

    func sample() -> PlayerSample? {
        guard let player else { return nil }
        let seconds = player.currentTime().seconds
        return PlayerSample(position: seconds.isFinite ? seconds : 0, duration: duration(of: player.currentItem))
    }

    private func duration(of item: AVPlayerItem?) -> TimeInterval? {
        guard let item, !item.duration.isIndefinite else { return nil }
        let seconds = item.duration.seconds
        return seconds.isFinite ? seconds : nil
    }

    func startObserving(onEvent: @escaping (PlayerEvent) -> Void) {
        guard !isObserving, let player else { return }
        isObserving = true
        self.onEvent = onEvent

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
            ) { [weak self] _ in self?.emit(.seeking) }
        }

        // `.new`-only KVO never reports a player that was already playing.
        if player.timeControlStatus == .playing {
            onEvent(.played)
        }
    }

    func stopObserving() {
        isObserving = false
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
