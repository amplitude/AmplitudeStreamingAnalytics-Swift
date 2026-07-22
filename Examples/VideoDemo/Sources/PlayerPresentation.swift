import AVKit

/// Shared demo content: Apple's public HLS test stream, used by both the
/// SwiftUI and UIKit playback screens.
enum DemoVideo {
    static let url = URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8")

    /// The demo URL is a fixed, known-good literal, so force-unwrapping here
    /// is intentional rather than user/network input.
    static var validURL: URL {
        guard let url else {
            fatalError("DemoVideo.url failed to parse a static, hardcoded URL literal")
        }
        return url
    }
}

/// An `AVPlayerViewController` subclass that reports back when it has been
/// dismissed, so the presenting UIKit view controller can tear down its
/// `AVPlayer`. Used by the UIKit demo screen, which presents this modally
/// rather than through SwiftUI's `fullScreenCover`.
final class DismissObservingPlayerViewController: AVPlayerViewController {
    var onDismiss: (() -> Void)?

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed {
            onDismiss?()
        }
    }
}
