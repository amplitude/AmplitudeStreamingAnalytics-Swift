# Getting started

> **Alpha.** This SDK is ready to use in production, but nothing in it is final. The public API, the internal behaviour, and the events it sends can all change before GA.

> **Note:** Scope
>
> These pages describe the Alpha. They will be removed at GA, when [the Amplitude docsite](https://amplitude.com/docs) takes over.

**Package:** AmplitudeStreamingAnalytics
**Latest version:** unreleased; install by commit SHA

Amplitude Streaming Analytics reports what your users watch as Amplitude events.

## Before you begin

You need:

- iOS 13.0+, tvOS 13.0+, or macOS 10.15+
- Amplitude-Swift 1.18.6 or later
- An Amplitude project and its API key

## Quickstart

### Install

There are no tagged releases during the Alpha, so pin a commit SHA:

```swift
dependencies: [
    .package(url: "https://github.com/amplitude/AmplitudeStreamingAnalytics-Swift.git", revision: "<commit-sha>")
]
```

In Xcode, use **File > Add Package Dependencies…**, enter
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

`StreamingAnalyticsPlugin` takes no configuration. You configure each viewing through
`PlayerContent` instead. See [Configuration](configuration.md).

### Starting a viewing

Call `trackPlayer(player:content:)` with the `AVPlayer` you are playing and a `PlayerContent`
describing it:

```swift
let player = AVPlayer(url: videoURL)
streaming.trackPlayer(player: player, content: PlayerContent(contentId: "ep-42", title: "Pilot", deliveryMode: .onDemand))
player.play()
```

> **Note:** One viewing per player
>
> You can track one viewing per `AVPlayer` at a time. If you call `trackPlayer(player:content:)` on a player that is already tracked, the SDK logs an error and leaves the running viewing alone. To track a new video in the same player, call `stopTracking(player:)` first.

> **Note:** `[Amplitude] Stream Started` fires when playback starts
>
> `trackPlayer(player:content:)` begins the viewing, but the first `[Amplitude] Stream Started` waits until the player actually starts playing. A viewing that pauses and resumes sends several Started events and several Stopped events. See [Events: Viewings and plays](events.md#viewings-and-plays).

### Stopping a viewing

Call `stopTracking(player:)` to end tracking for a player:

```swift
streaming.stopTracking(player: player)
```

If the player is playing, this sends a closing `[Amplitude] Stream Stopped`. If the player is
already paused, the SDK sent that event when the pause happened and sends nothing now.

Calling `stopTracking(player:)` on a player you never tracked does nothing. It never touches
playback.

> **Tip:** Tracking also ends on its own
>
> You do not have to call `stopTracking(player:)` when a screen goes away. The SDK holds the `AVPlayer` weakly and ends the viewing when the player deallocates, sending the same closing event an explicit `stopTracking(player:)` would.

## Known limitations

- Give the player an item before you track it. `trackPlayer(player:content:)` looks at
  `AVPlayer.currentItem` once, when you call it, and attaches the observers that report the item
  finishing, failing, or seeking. Track a player that has no item yet and you lose all three for
  that item: no `ended`, no `error`, and forward seeks counted as play time.
- The SDK does not follow `replaceCurrentItem`. The viewing keeps reporting under the
  `PlayerContent` you started it with, so the next video's events carry the previous video's
  `content_id`. Call `stopTracking(player:)`, then `trackPlayer(player:content:)` with the new
  content.
