# StreamingDemo

An example app exercising `AmplitudeStreamingAnalytics` end to end. It has three tabs:
a SwiftUI player, a UIKit player (both playing Apple's public HLS demo stream), and an
Activity panel listing the `[Amplitude] Stream *` events a viewer causes. The once-a-second
`timeout` stop that keeps the server row open is left out, or it buries everything else.

The `StreamingAnalyticsPlugin` is registered once at launch (see `DemoAnalytics.swift`)
against a placeholder `DEMO-API-KEY`; each screen calls `trackPlayer(player:content:)` when
its `AVPlayer` starts, once per player. The UIKit screen also calls `stopTracking(player:)` when
its player is dismissed; the SwiftUI screen leaves its viewing to end with the player. Swap in a
real project key to see events land in a project.

## Background playback and Picture in Picture

The app declares the `audio` background mode and puts its audio session in `.playback`,
and every player is built through `DemoVideo.makePlayer()`, which sets
`audiovisualBackgroundPlaybackPolicy = .continuesIfPossible` — the iOS 15+ way to keep a
video item running on background without detaching the player from its view.

Picture in Picture is on the UIKit tab only. Its `AVPlayerViewController` allows PiP and
starts it automatically when the app goes to the background; the screen hands PiP the
player, dismisses itself, and re-presents on restore, so the viewing — and the
`[Amplitude] Stream *` events — continue across the handover. SwiftUI's `VideoPlayer`
exposes no PiP switch, so the SwiftUI tab gets background audio but not PiP.

Both need a physical device: the Simulator does not offer PiP, and it cannot render video
on some hosts at all.

## Run

Open `Examples/StreamingDemo/StreamingDemo.xcodeproj` in Xcode, select the `StreamingDemo`
scheme, and run on any iOS 16+ simulator or device.
