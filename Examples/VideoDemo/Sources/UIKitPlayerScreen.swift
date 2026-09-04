import AmplitudeVideoAnalytics
import AVKit
import SwiftUI
import UIKit

/// UIKit tab: wraps `UIKitPlayerViewController` for hosting inside the
/// SwiftUI `TabView`.
struct UIKitPlayerScreen: UIViewControllerRepresentable {
    @EnvironmentObject private var analytics: DemoAnalytics

    func makeUIViewController(context: Context) -> UIKitPlayerViewController {
        let controller = UIKitPlayerViewController()
        controller.plugin = analytics.plugin
        return controller
    }

    func updateUIViewController(_ uiViewController: UIKitPlayerViewController, context: Context) {
        uiViewController.plugin = analytics.plugin
    }
}

/// A plain UIKit screen with a play button. Tapping it presents an
/// `AVPlayerViewController` modally, full-screen, and starts playback. The
/// `AVPlayer` is owned by this controller and torn down once the player is
/// dismissed.
final class UIKitPlayerViewController: UIViewController {
    var plugin: StreamingAnalyticsPlugin?
    private var player: AVPlayer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configureLayout()
    }

    private func configureLayout() {
        let titleLabel = UILabel()
        titleLabel.text = "UIKit Player"
        titleLabel.font = .preferredFont(forTextStyle: .title2)

        let subtitleLabel = UILabel()
        subtitleLabel.text = "Plays Apple's public HLS demo stream full-screen."
        subtitleLabel.font = .preferredFont(forTextStyle: .subheadline)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.numberOfLines = 0
        subtitleLabel.textAlignment = .center

        var buttonConfig = UIButton.Configuration.filled()
        buttonConfig.title = "Play"
        buttonConfig.image = UIImage(systemName: "play.fill")
        let playButton = UIButton(configuration: buttonConfig)
        playButton.addTarget(self, action: #selector(playTapped), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel, playButton])
        stack.axis = .vertical
        stack.spacing = 16
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24)
        ])
    }

    @objc
    private func playTapped() {
        let player = AVPlayer(url: DemoVideo.validURL)
        self.player = player

        let playerViewController = DismissObservingPlayerViewController()
        playerViewController.player = player
        playerViewController.modalPresentationStyle = .fullScreen
        playerViewController.onDismiss = { [weak self] in
            self?.teardownPlayer()
        }

        plugin?.trackVideo(
            player: player,
            options: VideoTrackingOptions(
                contentId: "bipbop-adv-fmp4",
                title: "BipBop Advanced (UIKit)",
                deliveryMode: .onDemand
            )
        )

        present(playerViewController, animated: true) {
            player.play()
        }
    }

    private func teardownPlayer() {
        guard let player else { return }
        player.pause()
        plugin?.stopTracking(player: player)
        self.player = nil
    }
}
