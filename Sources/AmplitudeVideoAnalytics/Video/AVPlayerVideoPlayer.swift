import AVFoundation
import Foundation

/// Concrete `VideoPlayer` adapter that wraps an `AVFoundation.AVPlayer` and translates its
/// KVO-observable state and notifications into `VideoPlayerEvent`s.
///
/// Deliberately **internal**: how the SDK subscribes to AVFoundation is an implementation detail,
/// and callers must not drive `startObserving()`/`stopObserving()` themselves — doing so detaches
/// observation without finalizing the in-flight snapshot. Consumers reach this adapter through the
/// plugin's `trackVideo(player:options:)` entry point, which owns the observation lifecycle; the
/// public extension point for custom/vendor players is the `VideoPlayer` protocol.
///
/// v1 assumption: `currentItem` is expected to be set (or left nil for the lifetime of this
/// instance) before `startObserving()` is called. Item-level observers are attached once, against
/// whatever `player.currentItem` is at `startObserving()` time; if the caller swaps
/// `player.replaceCurrentItem(with:)` afterwards, item-scoped observation (`.ended`, `.seeking`,
/// `.error`, `.bufferingEnded`) will keep referring to the original item, not the new one.
///
/// In v1 the consumer must therefore end and restart *tracking* around an item swap, so the old
/// snapshot is finalized (`timeout: 0`) rather than left to expire on its TTL:
///
/// ```swift
/// let stopTracking = plugin.trackVideo(player: avPlayer, options: oldOptions)
/// // ...
/// stopTracking()                    // finalizes the old snapshot (timeout: 0) + stopObserving()
/// avPlayer.replaceCurrentItem(with: newItem)
/// let stopTracking2 = plugin.trackVideo(player: avPlayer, options: newOptions)  // new viewSessionId
/// ```
///
/// `AVQueuePlayer` advances `currentItem` internally with no hook for this recipe and is not
/// supported in v1. Automatic re-attachment (KVO on `player.currentItem`) is deferred to v2,
/// where an item swap must also surface to the tracking layer as a content change (new view
/// session with fresh caller-supplied metadata).
final class AVPlayerVideoPlayer: VideoPlayer {
    private let player: AVPlayer
    private var isObserving = false

    private var timeControlStatusToken: NSKeyValueObservation?
    private var itemStatusToken: NSKeyValueObservation?
    private var itemLikelyToKeepUpToken: NSKeyValueObservation?

    private var didPlayToEndObserver: NSObjectProtocol?
    /// Backs the `AVPlayerItemTimeJumpedNotification` (imported into Swift as
    /// `.AVPlayerItemTimeJumped`) subscription — the brief's `AVPlayer.timeJumpedNotification`
    /// does not exist; the notification is posted by `AVPlayerItem`, not `AVPlayer`.
    private var timeJumpedObserver: NSObjectProtocol?

    var onEvent: ((VideoPlayerEvent) -> Void)?

    var currentTime: TimeInterval {
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? seconds : 0
    }

    var duration: TimeInterval? {
        guard let item = player.currentItem else { return nil }
        let duration = item.duration
        guard !duration.isIndefinite else { return nil }
        let seconds = duration.seconds
        return seconds.isFinite ? seconds : nil
    }

    init(_ player: AVPlayer) {
        self.player = player
    }

    deinit {
        stopObserving()
    }

    func startObserving() {
        guard !isObserving else { return }
        isObserving = true

        timeControlStatusToken = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            self?.handleTimeControlStatusChange(player.timeControlStatus)
        }

        // Item-level KVO and notifications are only registered when there's a current item at
        // startObserving() time, and always scoped to that specific item (never `object: nil`,
        // which would observe every AVPlayerItem in the process and cause cross-talk with
        // unrelated players elsewhere in the host app). This mirrors the documented v1
        // currentItem-swap assumption above: all item-level observation attaches to the item
        // present at startObserving() time, or not at all.
        if let item = player.currentItem {
            itemStatusToken = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                self?.handleItemStatusChange(item)
            }
            itemLikelyToKeepUpToken = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] item, _ in
                self?.handleLikelyToKeepUpChange(item.isPlaybackLikelyToKeepUp)
            }

            didPlayToEndObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: nil
            ) { [weak self] _ in
                self?.onEvent?(.ended)
            }

            timeJumpedObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemTimeJumped,
                object: item,
                queue: nil
            ) { [weak self] _ in
                self?.onEvent?(.seeking)
            }
        }
    }

    func stopObserving() {
        isObserving = false

        timeControlStatusToken = nil
        itemStatusToken = nil
        itemLikelyToKeepUpToken = nil

        if let didPlayToEndObserver {
            NotificationCenter.default.removeObserver(didPlayToEndObserver)
            self.didPlayToEndObserver = nil
        }
        if let timeJumpedObserver {
            NotificationCenter.default.removeObserver(timeJumpedObserver)
            self.timeJumpedObserver = nil
        }
    }

    private func handleTimeControlStatusChange(_ status: AVPlayer.TimeControlStatus) {
        switch status {
        case .playing:
            onEvent?(.played)
        case .paused:
            onEvent?(.paused)
        case .waitingToPlayAtSpecifiedRate:
            onEvent?(.buffering)
        @unknown default:
            break
        }
    }

    private func handleItemStatusChange(_ item: AVPlayerItem) {
        guard item.status == .failed else { return }
        onEvent?(.error(message: item.error?.localizedDescription))
    }

    private func handleLikelyToKeepUpChange(_ isLikelyToKeepUp: Bool) {
        onEvent?(isLikelyToKeepUp ? .bufferingEnded : .buffering)
    }
}
