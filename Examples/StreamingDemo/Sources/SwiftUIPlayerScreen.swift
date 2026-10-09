import AmplitudeStreamingAnalytics
import AVKit
import SwiftUI

/// SwiftUI tab: the native `VideoPlayer` view. Its own controls handle
/// play/pause and full screen.
///
/// Audio keeps playing on background here, but there is no Picture in Picture:
/// `VideoPlayer` exposes no equivalent of `AVPlayerViewController`'s
/// `allowsPictureInPicturePlayback`, and wrapping that controller instead would cost
/// this tab the thing it exists to demonstrate. The UIKit tab covers PiP.
struct SwiftUIPlayerScreen: View {
    @EnvironmentObject private var analytics: DemoAnalytics
    @State private var player = DemoVideo.makePlayer()
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
