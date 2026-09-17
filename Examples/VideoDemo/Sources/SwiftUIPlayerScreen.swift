import AmplitudeStreamingAnalytics
import AVKit
import SwiftUI

/// SwiftUI tab: the native `VideoPlayer` view. Its own controls handle
/// play/pause and full screen.
struct SwiftUIPlayerScreen: View {
    @EnvironmentObject private var analytics: DemoAnalytics
    @State private var player = AVPlayer(url: DemoVideo.validURL)
    @State private var isTracked = false

    var body: some View {
        VideoPlayer(player: player)
            .ignoresSafeArea()
            .onAppear {
                // `onAppear` fires again on every tab switch, and this player outlives one.
                guard !isTracked else { return }
                isTracked = true

                analytics.plugin.trackPlayer(
                    player: player,
                    content: PlayerContent(
                        contentId: "bipbop-4x3",
                        title: "BipBop (SwiftUI)",
                        deliveryMode: .onDemand
                    )
                )
            }
    }
}
