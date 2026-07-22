import Foundation

/// Whether tracked content is video-on-demand or a live stream.
public enum VideoContentType: String {
    case vod = "VoD"
    case live = "Live"
}

/// Caller-supplied metadata describing the content being tracked.
public struct VideoTrackingOptions {
    public let contentId: String?
    public let title: String?
    public let contentType: VideoContentType?
    public let extraEventProperties: [String: Any]

    public init(
        contentId: String? = nil,
        title: String? = nil,
        contentType: VideoContentType? = nil,
        extraEventProperties: [String: Any] = [:]
    ) {
        self.contentId = contentId
        self.title = title
        self.contentType = contentType
        self.extraEventProperties = extraEventProperties
    }
}
