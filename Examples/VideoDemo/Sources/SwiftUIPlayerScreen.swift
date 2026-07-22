import AmplitudeVideoAnalytics
import AVKit
import SwiftUI

/// Identifiable wrapper so the player can drive item-based full-screen
/// presentation. `fullScreenCover(isPresented:)` + optional `@State` is prone
/// to the classic stale-capture race (the cover renders once with the old nil
/// value → blank screen); `fullScreenCover(item:)` hands the unwrapped value
/// straight to the content closure instead.
private struct PresentedPlayer: Identifiable {
    let id = UUID()
    let player: AVPlayer
}

/// SwiftUI tab: a content card with a play button that presents the demo
/// video full-screen via AVKit's native SwiftUI `VideoPlayer` view.
struct SwiftUIPlayerScreen: View {
    @State private var presented: PresentedPlayer?

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 8) {
                Text("SwiftUI Player")
                    .font(.title2)
                    .bold()
                Text("Plays Apple's public HLS demo stream full-screen.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .background(Color(.secondarySystemBackground))
            .cornerRadius(12)
            .padding(.horizontal)

            Button {
                play()
            } label: {
                Label("Play", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)

            Spacer()

            Text("AmplitudeVideoAnalytics v\(AmplitudeVideoAnalyticsInfo.version)")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .padding(.top, 40)
        .fullScreenCover(item: $presented) { presented in
            ZStack {
                Color.black
                    .ignoresSafeArea()
                VideoPlayer(player: presented.player)
                    .ignoresSafeArea()
            }
            // `VideoPlayer` has no dismiss affordance of its own, and
            // `fullScreenCover` has no swipe-to-dismiss. Provide an
            // explicit close button.
            .overlay(alignment: .topTrailing) {
                Button {
                    dismissPlayer()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title)
                        .foregroundStyle(.white, .black.opacity(0.6))
                        .padding()
                }
            }
            .onAppear {
                presented.player.play()
            }
        }
    }

    private func play() {
        let player = AVPlayer(url: DemoVideo.validURL)

        // TODO(video-analytics): plugin.trackVideo(player: AVPlayerVideoPlayer(player), options: ...)

        presented = PresentedPlayer(player: player)
    }

    private func dismissPlayer() {
        presented?.player.pause()
        presented = nil
    }
}
