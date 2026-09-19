import AmplitudeStreamingAnalytics
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
/// `AVPlayer` is owned by this controller and torn down once the viewing ends —
/// which, with Picture in Picture, is later than the player being dismissed.
final class UIKitPlayerViewController: UIViewController {
    var plugin: StreamingAnalyticsPlugin?
    private var player: AVPlayer?
    /// Held across a Picture in Picture handover: the controller is dismissed while PiP runs
    /// and re-presented if the viewer restores it, so nothing else keeps it alive.
    private var playerViewController: DismissObservingPlayerViewController?
    private var isPictureInPictureActive = false

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
        let player = DemoVideo.makePlayer()
        self.player = player

        let playerViewController = DismissObservingPlayerViewController()
        playerViewController.player = player
        playerViewController.delegate = self
        playerViewController.allowsPictureInPicturePlayback = true
        playerViewController.canStartPictureInPictureAutomaticallyFromInline = true
        playerViewController.modalPresentationStyle = .fullScreen
        playerViewController.onDismiss = { [weak self] in
            guard let self, !isPictureInPictureActive else { return }
            teardownPlayer()
        }
        self.playerViewController = playerViewController

        plugin?.trackPlayer(
            player: player,
            content: PlayerContent(
                contentId: "bipbop-4x3",
                title: "BipBop (UIKit)",
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
        playerViewController = nil
    }
}

extension UIKitPlayerViewController: AVPlayerViewControllerDelegate {
    func playerViewControllerWillStartPictureInPicture(_ controller: AVPlayerViewController) {
        isPictureInPictureActive = true
        // Give the screen back — the PiP window is the presentation now. The flag is set first
        // so the dismissal this causes is not read as the end of the viewing.
        controller.dismiss(animated: true)
    }

    func playerViewController(
        _ controller: AVPlayerViewController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        present(controller, animated: true) { completionHandler(true) }
    }

    func playerViewControllerDidStopPictureInPicture(_ controller: AVPlayerViewController) {
        isPictureInPictureActive = false
        // A restore re-presents before this fires, so no presenter means the viewer closed the
        // PiP window outright and there is nothing left playing.
        if controller.presentingViewController == nil {
            teardownPlayer()
        }
    }
}
