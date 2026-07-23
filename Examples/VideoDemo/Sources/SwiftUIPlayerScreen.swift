import AmplitudeVideoAnalytics
import AVKit
import SwiftUI

/// Embeds an `AVPlayerViewController` inline and lets AVKit own the
/// full-screen experience: `entersFullScreenWhenPlaybackBegins` takes the
/// player full screen (with native controls and a Done button) as soon as
/// playback starts, and exits again when playback ends.
private struct InlinePlayerView: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.entersFullScreenWhenPlaybackBegins = true
        controller.exitsFullScreenWhenPlaybackEnds = true
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        // No dynamic updates needed for this demo screen.
    }
}

/// SwiftUI tab: an inline video card whose native play control hands the
/// player to AVKit for full-screen playback.
struct SwiftUIPlayerScreen: View {
    @State private var player: AVPlayer?

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 8) {
                Text("SwiftUI Player")
                    .font(.title2)
                    .bold()
                Text("Native AVKit player — its own controls handle play and full screen.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
            .padding(.horizontal)

            if let player {
                InlinePlayerView(player: player)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .cornerRadius(12)
                    .padding(.horizontal)
            }

            Spacer()

            Text("AmplitudeVideoAnalytics v\(AmplitudeVideoAnalyticsInfo.version)")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .padding(.top, 40)
        .onAppear {
            guard player == nil else { return }
            let player = AVPlayer(url: DemoVideo.validURL)

            // TODO(video-analytics): plugin.trackVideo(player: AVPlayerVideoPlayer(player), options: ...)

            self.player = player
        }
        .onDisappear {
            player?.pause()
        }
    }
}
