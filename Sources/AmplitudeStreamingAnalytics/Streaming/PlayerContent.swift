import Foundation

/// How the content reaches the viewer. Raw values are wire taxonomy.
public enum DeliveryMode: String {
    case onDemand = "on_demand"
    case live
}

/// Caller-supplied metadata describing the content being tracked.
public struct PlayerContent {
    public let contentId: String?
    public let title: String?
    public let deliveryMode: DeliveryMode?
    public let extraEventProperties: [String: Any]

    public init(
        contentId: String? = nil,
        title: String? = nil,
        deliveryMode: DeliveryMode? = nil,
        extraEventProperties: [String: Any] = [:]
    ) {
        self.contentId = contentId
        self.title = title
        self.deliveryMode = deliveryMode
        self.extraEventProperties = extraEventProperties
    }
}
