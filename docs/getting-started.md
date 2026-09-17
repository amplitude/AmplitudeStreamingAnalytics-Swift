# Getting started

> **Alpha.** This SDK is in Alpha. It is stable enough for production use, but its internal behaviour, its public API and the events it sends may all change before GA.

> **Note:** Scope of this document
>
> This describes the Alpha. It will be obsolete — and probably deleted — when the SDK reaches GA, at which point [the Amplitude docsite](https://amplitude.com/docs) becomes the source of truth.

**Package:** AmplitudeStreamingAnalytics
**Latest version:** unreleased — install by commit SHA

Amplitude Streaming Analytics reports what your users watch as Amplitude events. This page covers
installing the package, adding the plugin, and starting and stopping a viewing.

## Before you begin

You need:

- iOS 13.0+, tvOS 13.0+, or macOS 10.15+
- Amplitude-Swift 1.18.6 or later
- An Amplitude project and its API key

## Quickstart

### SPM

`git tag -l` has no tags yet and there is no podspec, so a version constraint such as `from:
"1.0.0"` resolves to nothing. Pin Swift Package Manager to a commit SHA instead; tagged releases
arrive at GA.

```swift
dependencies: [
    .package(url: "https://github.com/amplitude/AmplitudeStreamingAnalytics-Swift.git", revision: "<commit-sha>")
]
```

You can also add it through Xcode: **File > Add Package Dependencies…**, enter
`https://github.com/amplitude/AmplitudeStreamingAnalytics-Swift.git`, choose **Branch/Commit**,
and paste the SHA.

### Configure your application code

Add `StreamingAnalyticsPlugin` to your `Amplitude` instance once, at startup:

```swift
import AmplitudeSwift
import AmplitudeStreamingAnalytics

let amplitude = Amplitude(configuration: Configuration(apiKey: API_KEY))
let streaming = StreamingAnalyticsPlugin()
amplitude.add(plugin: streaming)
```

## Configuration

`StreamingAnalyticsPlugin` itself takes no configuration. What you can configure per viewing is
`PlayerContent` — see [Configuration](configuration.md).

### Starting a viewing

Call `trackPlayer(player:content:)` with the `AVPlayer` you are playing and a `PlayerContent`
describing it:

```swift
streaming.trackPlayer(player: avPlayer, content: PlayerContent(contentId: "ep-42", title: "Pilot", deliveryMode: .onDemand))
```

> **Note:** One viewing per player
>
> Only one viewing can be tracked per `AVPlayer` at a time. Calling `trackPlayer(player:content:)` again on a player that is already tracked is refused: the SDK logs an error and leaves the viewing already running untouched. To track a new video in the same player, call `stopTracking(player:)` first.

> **Note:** `[Amplitude] Stream Started` fires per play, not per call
>
> `trackPlayer(player:content:)` begins tracking a viewing, but `[Amplitude] Stream Started` fires when the player starts playing, and a viewing that pauses and resumes sends it — and a matching `[Amplitude] Stream Stopped` — more than once. See [Events: Viewings and plays](events.md#viewings-and-plays).

### Stopping a viewing

Call `stopTracking(player:)` to end tracking for a player:

```swift
streaming.stopTracking(player: avPlayer)
```

If the player is currently playing, this sends the closing `[Amplitude] Stream Stopped` for the
play in progress. If no play is open — the player is already paused, for example — it sends
nothing further; that play was already closed when the player paused. See
[Events: Viewings and plays](events.md#viewings-and-plays).

Calling `stopTracking(player:)` on a player that is not being tracked at all does nothing, and
does not touch playback.

> **Tip:** Tracking also ends on its own
>
> You do not have to call `stopTracking(player:)` when a screen is dismissed. The SDK holds the `AVPlayer` weakly and ends tracking on its own as soon as the player deallocates. If a play was open at that point, this sends its closing event, same as an explicit `stopTracking(player:)` would.

## Known limitations

- CocoaPods distribution is not available yet; use Swift Package Manager.
- There is no tagged release yet; pin a commit SHA, and expect it to move as the Alpha changes.
- `StreamingAnalyticsConfig` (sample interval, delayed-event TTL) is internal in Alpha and not
  caller-configurable.
- Track a player only once its item is set. `trackPlayer(player:content:)` attaches the item-level
  observers to whatever `AVPlayer.currentItem` holds at that moment, and does not pick one up later.
  Track a player that has none and the viewing never reports that item reaching its end or failing,
  and a forward seek in it is counted as watched time.
- `replaceCurrentItem` is not followed. The viewing goes on reporting under the `PlayerContent` it
  was started with, so the next item's playback lands on the previous `content_id`. Call
  `stopTracking(player:)` and then `trackPlayer(player:content:)` with the new content instead.
