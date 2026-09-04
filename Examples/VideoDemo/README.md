# VideoDemo

An example app exercising `AmplitudeVideoAnalytics` end to end. It has three tabs:
a SwiftUI player, a UIKit player (both playing Apple's public HLS demo stream), and an
Activity panel showing the `[Amplitude] Stream *` events the plugin emits.

The `StreamingAnalyticsPlugin` is registered once at launch (see `DemoAnalytics.swift`)
against a placeholder `DEMO-API-KEY`; each screen calls `trackVideo(player:options:)` when
its `AVPlayer` starts. The UIKit screen also calls `stopTracking(player:)` when its player is
dismissed; the SwiftUI screen leaves its viewing to end with the player. Swap in a real project
key to see events land in a project.

## Run

Open `Examples/VideoDemo/VideoDemo.xcodeproj` in Xcode, select the `VideoDemo`
scheme, and run on any iOS 16+ simulator or device.
