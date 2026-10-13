import AmplitudeSwift
import Foundation

/// The only place the wire taxonomy is spelled out. Pure functions.
enum StreamingEvents {
    static let startedType = "[Streaming] Stream Started"
    static let stoppedType = "[Streaming] Stream Stopped"

    enum Property: String {
        case contentId = "[Streaming] Content ID"
        case title = "[Streaming] Title"
        case mediaType = "[Streaming] Media Type"
        case deliveryMode = "[Streaming] Delivery Mode"
        case streamSessionId = "[Streaming] Stream Session ID"
        case playId = "[Streaming] Play ID"
        case startPosition = "[Streaming] Start Position Sec"
        case position = "[Streaming] Position Sec"
        case duration = "[Streaming] Duration Sec"
        case playTime = "[Streaming] Play Time Sec"
        case playTimeTotal = "[Streaming] Play Time Total Sec"
        case percentCompleted = "[Streaming] Percent Completed"
        case stopReason = "[Streaming] Stop Reason"
        case errorMessage = "[Streaming] Error Message"
    }

    private static let mediaType = StreamingMediaType.video

    static func started(content: PlayerContent, state: StreamingState) -> DelayedEvent {
        makeEvent(type: startedType,
                  content: content,
                  state: state,
                  kind: .instant,
                  properties: baseProperties(content: content, state: state))
    }

    /// `timeout` is the reason the server holds a row open, so it is the only one that stays in the
    /// delayed lane; every other reason is what finalizes that row.
    static func stopped(content: PlayerContent, state: StreamingState) -> DelayedEvent {
        var properties = baseProperties(content: content, state: state)
        properties[.playTime] = state.playTime
        properties[.playTimeTotal] = state.playTimeTotal
        if let duration = state.duration {
            properties[.percentCompleted] = percentCompleted(position: state.position, duration: duration)
        }
        if let stopReason = state.stopReason {
            properties[.stopReason] = stopReason.rawValue
        }
        if let errorMessage = state.errorMessage {
            properties[.errorMessage] = errorMessage
        }
        return makeEvent(type: stoppedType,
                         content: content,
                         state: state,
                         kind: state.stopReason == .timeout ? .delayed : .instant,
                         properties: properties)
    }

    private static func baseProperties(content: PlayerContent, state: StreamingState) -> [Property: Any] {
        var properties: [Property: Any] = [:]
        if let contentId = content.contentId {
            properties[.contentId] = contentId
        }
        if let title = content.title {
            properties[.title] = title
        }
        properties[.mediaType] = mediaType.rawValue
        properties[.deliveryMode] = (content.deliveryMode ?? (state.duration == nil ? .live : .onDemand)).rawValue
        properties[.streamSessionId] = state.streamSessionId
        properties[.playId] = state.playId
        if let duration = state.duration {
            properties[.duration] = duration
        }
        properties[.startPosition] = state.startPosition
        properties[.position] = state.position
        return properties
    }

    private static func percentCompleted(position: TimeInterval, duration: TimeInterval) -> Double {
        guard duration > 0, position.isFinite else { return 0 }
        return min(100, max(0, position / duration * 100))
    }

    private static func makeEvent(type: String,
                                  content: PlayerContent,
                                  state: StreamingState,
                                  kind: DelayedEvent.Kind,
                                  properties: [Property: Any]) -> DelayedEvent {
        let sdkProperties = Dictionary(uniqueKeysWithValues: properties.map { ($0.key.rawValue, $0.value) })
        let event = BaseEvent(timestamp: Int64(state.at.timeIntervalSince1970 * 1000),
                              eventType: type,
                              eventProperties: content.extraEventProperties.merging(sdkProperties) { _, sdk in sdk })
        event.insertId = state.insertId
        return DelayedEvent(copying: event, kind: kind)
    }
}
