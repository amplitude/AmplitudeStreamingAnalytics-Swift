import AmplitudeVideoAnalytics
import AVKit
import SwiftUI

/// SwiftUI tab: the native `VideoPlayer` view. Its own controls handle
/// play/pause and full screen.
struct SwiftUIPlayerScreen: View {
    @EnvironmentObject private var analytics: DemoAnalytics
    @State private var player = AVPlayer(url: DemoVideo.validURL)

    var body: some View {
        VideoPlayer(player: player)
            .ignoresSafeArea()
            .onAppear {
                analytics.plugin.trackVideo(
                    player: player,
                    options: VideoTrackingOptions(
                        contentId: "bipbop-adv-fmp4",
                        title: "BipBop Advanced (SwiftUI)",
                        deliveryMode: .onDemand
                    )
                )
            }
    }
}
