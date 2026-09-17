<p align="center">
  <a href="https://amplitude.com" target="_blank" align="center">
    <img src="https://static.amplitude.com/lightning/46c85bfd91905de8047f1ee65c7c93d6fa9ee6ea/static/media/amplitude-logo-with-text.4fb9e463.svg" width="280">
  </a>
  <br />
</p>

# AmplitudeStreamingAnalytics-Swift

Amplitude's Streaming Analytics SDK for Apple platforms.

> **Alpha.** This SDK is in Alpha. It is stable enough for production use, but its internal behaviour, its public API and the events it sends may all change before GA.

## Need Help?
If you have any issues using our SDK, feel free to [create a GitHub issue](https://github.com/amplitude/AmplitudeStreamingAnalytics-Swift/issues/new) or submit a request on [Amplitude Help](https://help.amplitude.com/hc/en-us/requests/new).

## SDK support

AmplitudeStreamingAnalytics currently supports iOS 13.0+, tvOS 13.0+, and macOS 10.15+.

## Instructions

`git tag -l` has no tags yet and there is no podspec, so a version constraint like `from: "1.0.0"`
would resolve to nothing. Pin Swift Package Manager to a commit SHA with `revision:` instead;
tagged releases arrive at GA.

#### SPM

```swift
dependencies: [
    .package(url: "https://github.com/amplitude/AmplitudeStreamingAnalytics-Swift.git", revision: "<commit-sha>")
]
```

## Quickstart

```swift
import AmplitudeSwift
import AmplitudeStreamingAnalytics

let amplitude = Amplitude(configuration: Configuration(apiKey: API_KEY))
let streaming = StreamingAnalyticsPlugin()
amplitude.add(plugin: streaming)

streaming.trackPlayer(player: avPlayer, content: PlayerContent(contentId: "ep-1", title: "Episode 1"))
```

See [`docs/`](https://amplitude.com/docs) for the full reference; the docsite is the source of
truth from GA.
