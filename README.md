<p align="center">
  <a href="https://amplitude.com" target="_blank" align="center">
    <img src="https://static.amplitude.com/lightning/46c85bfd91905de8047f1ee65c7c93d6fa9ee6ea/static/media/amplitude-logo-with-text.4fb9e463.svg" width="280">
  </a>
  <br />
</p>

# AmplitudeStreamingAnalytics-Swift

Amplitude's Streaming Analytics SDK for Apple platforms. It reports what your users watch as
Amplitude events.

> **Alpha.** Nothing in this SDK is final. The public API, the internal behaviour, and the events
> it sends can change in any release.

## Need Help?
If you have any issues using our SDK, feel free to [create a GitHub issue](https://github.com/amplitude/AmplitudeStreamingAnalytics-Swift/issues/new) or submit a request on [Amplitude Help](https://help.amplitude.com/hc/en-us/requests/new).

## Requirements

iOS 13.0+, tvOS 13.0+, and macOS 10.15+. Requires Amplitude-Swift 1.18.6 up to, but not
including, 2.0.0. Building needs Xcode 15+ (Swift 5.9), the package's `swift-tools-version`.

## Installation

Swift Package Manager. Alpha releases can break the API from one to the next, so pin an exact
version:

<!-- x-release-please-start-version -->
```swift
dependencies: [
    .package(url: "https://github.com/amplitude/AmplitudeStreamingAnalytics-Swift.git", exact: "0.1.0-alpha.1")
],
targets: [
    .target(
        name: "YourApp",
        dependencies: [.product(name: "AmplitudeStreamingAnalytics", package: "AmplitudeStreamingAnalytics-Swift")]
    )
]
```
<!-- x-release-please-end -->

## Quickstart

Add the plugin to your `Amplitude` instance once, then track each player you create.

```swift
import AVFoundation
import AmplitudeSwift
import AmplitudeStreamingAnalytics

// At startup.
let amplitude = Amplitude(configuration: Configuration(apiKey: API_KEY))
let streaming = StreamingAnalyticsPlugin()
amplitude.add(plugin: streaming)

// For each video. Create the player and give it an item before you track it.
let player = AVPlayer(url: videoURL)
streaming.trackPlayer(player: player, content: PlayerContent(contentId: "ep-42", title: "Pilot"))
player.play()

// When the viewer is done.
streaming.stopTracking(player: player)
```

You can skip `stopTracking(player:)` if the player is about to go away. The SDK holds the player
weakly and closes the viewing when it deallocates.

See [`docs/`](docs/) for the full reference.
