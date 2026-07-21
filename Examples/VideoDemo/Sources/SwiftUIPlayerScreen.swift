import AmplitudeVideoAnalytics
import AVFoundation
import SwiftUI

/// SwiftUI tab: a content card with a play button that presents the demo
/// video full-screen via `AVPlayerViewController`.
struct SwiftUIPlayerScreen: View {
    @State private var player: AVPlayer?
    @State private var isPresentingPlayer = false

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
        .fullScreenCover(isPresented: $isPresentingPlayer, onDismiss: teardownPlayer) {
            if let player {
                // AVPlayerViewController is embedded here (not presented directly),
                // so it doesn't get AVKit's automatic "Done" button. Provide an
                // explicit close affordance instead.
                FullScreenPlayerView(player: player)
                    .ignoresSafeArea()
                    .overlay(alignment: .topTrailing) {
                        Button {
                            isPresentingPlayer = false
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title)
                                .foregroundStyle(.white, .black.opacity(0.6))
                                .padding()
                        }
                    }
            }
        }
    }

    private func play() {
        player = AVPlayer(url: DemoVideo.validURL)
        isPresentingPlayer = true
    }

    private func teardownPlayer() {
        player?.pause()
        player = nil
    }
}
