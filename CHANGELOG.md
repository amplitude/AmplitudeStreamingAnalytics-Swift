# Changelog

## 0.1.0-alpha.1 (2026-09-23)

First Alpha release. See [`docs/`](docs/) for the full reference.

### Features

* `StreamingAnalyticsPlugin`, an Amplitude-Swift plugin that reports `AVPlayer` playback as Amplitude events. Add it to your `Amplitude` instance once, call `trackPlayer(player:content:)` for each player and `stopTracking(player:)` when the viewer is done.
* `PlayerContent` describes what is playing: `contentId`, `title`, `deliveryMode` and `extraEventProperties`. When `deliveryMode` is `nil`, the SDK sends `live` for an item with no duration and `on_demand` for one with a duration.
* Each play sends `[Amplitude] Stream Started` and `[Amplitude] Stream Stopped`. `stream_session_id` identifies the viewing and `play_id` the play within it. See [Events](docs/events.md).
* A play that never closes, because the app crashed, was force-quit or lost the network, still reaches your data as `[Amplitude] Stream Stopped` with `stop_reason` `timeout`.
* Tracked players are held weakly. A player that deallocates closes its viewing without a `stopTracking(player:)` call.
* iOS 13.0+, tvOS 13.0+ and macOS 10.15+, with Amplitude-Swift 1.18.6 or later.

### Known limitations

* `media_type` is always `video`; audio-only playback is not reported separately.
* The SDK does not follow `replaceCurrentItem`. Stop and re-track the player when its item changes.
* Track a player after it has an item. A player tracked before `currentItem` is set never reports `ended` or `error` for that item.
