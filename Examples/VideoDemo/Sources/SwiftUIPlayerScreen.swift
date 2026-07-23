import AmplitudeVideoAnalytics
import AVKit
import SwiftUI

/// SwiftUI tab: the native `VideoPlayer` view. Its own controls handle
/// play/pause and full screen.
struct SwiftUIPlayerScreen: View {
    @State private var player = AVPlayer(url: DemoVideo.validURL)

    var body: some View {
        VideoPlayer(player: player)
            .ignoresSafeArea()
            .onAppear {
                // TODO(video-analytics): plugin.trackVideo(player: AVPlayerVideoPlayer(player), options: ...)
            }
    }
}
