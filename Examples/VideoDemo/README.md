# VideoDemo

An example app exercising `AmplitudeStreamingAnalytics` end to end. It has three tabs:
a SwiftUI player, a UIKit player (both playing Apple's public HLS demo stream), and an
Activity panel listing the `[Amplitude] Stream *` events a viewer causes. The once-a-second
`timeout` stop that keeps the server row open is left out, or it buries everything else.

The `StreamingAnalyticsPlugin` is registered once at launch (see `DemoAnalytics.swift`)
against a placeholder `DEMO-API-KEY`; each screen calls `trackPlayer(player:content:)` when
its `AVPlayer` starts, once per player. The UIKit screen also calls `stopTracking(player:)` when
its player is dismissed; the SwiftUI screen leaves its viewing to end with the player. Swap in a
real project key to see events land in a project.

## Run

Open `Examples/VideoDemo/VideoDemo.xcodeproj` in Xcode, select the `VideoDemo`
scheme, and run on any iOS 16+ simulator or device.
