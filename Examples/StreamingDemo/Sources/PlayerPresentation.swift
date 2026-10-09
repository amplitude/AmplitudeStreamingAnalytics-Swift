import AVKit

/// Shared demo content: Apple's classic BipBop HLS test stream (H.264/AAC in
/// MPEG-TS), used by both the SwiftUI and UIKit playback screens. Chosen for
/// broad simulator compatibility; the advanced fMP4 variant fails to decode on
/// many simulators.
enum DemoVideo {
    static let url = URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_4x3/bipbop_4x3_variant.m3u8")

    /// The demo URL is a fixed, known-good literal, so force-unwrapping here
    /// is intentional rather than user/network input.
    static var validURL: URL {
        guard let url else {
            fatalError("DemoVideo.url failed to parse a static, hardcoded URL literal")
        }
        return url
    }

    /// Both playback screens build their player here, so the background policy holds
    /// wherever the demo plays.
    static func makePlayer() -> AVPlayer {
        let player = AVPlayer(url: validURL)
        // The system pauses items with video on background unless asked otherwise, whatever
        // the audio background mode says. This is the iOS 15+ replacement for detaching the
        // player from its view on `willResignActive`, and unlike that trick it does not
        // break Picture in Picture.
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        return player
    }
}

/// `.playback` is what keeps audio alive once the screen locks or the app backgrounds, and
/// Picture in Picture will not start without it. The default `.soloAmbient` is silenced on
/// background, so the background mode alone buys nothing.
enum DemoAudioSession {
    static func configureForBackgroundPlayback() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            // stdout, so a device run started with `devicectl ... --console` shows the failure;
            // silently losing background audio is much harder to diagnose.
            print("StreamingDemo audio session setup failed: \(error)")
        }
    }
}

/// An `AVPlayerViewController` subclass that reports back when it has been
/// dismissed, so the presenting UIKit view controller can tear down its
/// `AVPlayer`. Used by the UIKit demo screen, which presents this modally
/// rather than through SwiftUI's `fullScreenCover`.
///
/// A dismissal is not always the end of a viewing: starting Picture in Picture
/// dismisses this controller while playback carries on. The owner decides, which
/// is why this reports rather than tears down.
final class DismissObservingPlayerViewController: AVPlayerViewController {
    var onDismiss: (() -> Void)?

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed {
            onDismiss?()
        }
    }
}
