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
