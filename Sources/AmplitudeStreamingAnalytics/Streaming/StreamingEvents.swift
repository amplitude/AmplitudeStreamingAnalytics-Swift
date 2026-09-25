import AmplitudeSwift
import Foundation

/// The only place the wire taxonomy is spelled out. Pure functions.
enum StreamingEvents {
    static let startedType = "[Streaming] Stream Started"
    static let stoppedType = "[Streaming] Stream Stopped"

    private static let mediaType = StreamingMediaType.video

    static func started(content: PlayerContent, state: StreamingState) -> DelayedEvent {
        makeEvent(type: startedType,
                  state: state,
                  kind: .instant,
                  properties: baseProperties(content: content, state: state))
    }

    /// `timeout` is the reason the server holds a row open, so it is the only one that stays in the
    /// delayed lane; every other reason is what finalizes that row.
    static func stopped(content: PlayerContent, state: StreamingState) -> DelayedEvent {
        var properties = baseProperties(content: content, state: state)
        properties["[Streaming] Play Time Sec"] = state.playTime
        properties["[Streaming] Play Time Total Sec"] = state.playTimeTotal
        if let duration = state.duration {
            properties["[Streaming] Percent Completed"] = percentCompleted(position: state.position, duration: duration)
        }
        if let stopReason = state.stopReason {
            properties["[Streaming] Stop Reason"] = stopReason.rawValue
        }
        if let errorMessage = state.errorMessage {
            properties["[Streaming] Error Message"] = errorMessage
        }
        return makeEvent(type: stoppedType,
                         state: state,
                         kind: state.stopReason == .timeout ? .delayed : .instant,
                         properties: properties)
    }

    private static func baseProperties(content: PlayerContent, state: StreamingState) -> [String: Any] {
        var properties = content.extraEventProperties
        if let contentId = content.contentId {
            properties["[Streaming] Content ID"] = contentId
        }
        if let title = content.title {
            properties["[Streaming] Title"] = title
        }
        properties["[Streaming] Media Type"] = mediaType.rawValue
        properties["[Streaming] Delivery Mode"] = (content.deliveryMode ?? (state.duration == nil ? .live : .onDemand)).rawValue
        properties["[Streaming] Stream Session ID"] = state.streamSessionId
        properties["[Streaming] Play ID"] = state.playId
        if let duration = state.duration {
            properties["[Streaming] Duration Sec"] = duration
        }
        properties["[Streaming] Start Position Sec"] = state.startPosition
        properties["[Streaming] Position Sec"] = state.position
        return properties
    }

    private static func percentCompleted(position: TimeInterval, duration: TimeInterval) -> Double {
        guard duration > 0, position.isFinite else { return 0 }
        return min(100, max(0, position / duration * 100))
    }

    private static func makeEvent(type: String,
                                  state: StreamingState,
                                  kind: DelayedEvent.Kind,
                                  properties: [String: Any]) -> DelayedEvent {
        let event = BaseEvent(timestamp: Int64(state.at.timeIntervalSince1970 * 1000),
                              eventType: type,
                              eventProperties: properties)
        event.insertId = state.insertId
        return DelayedEvent(copying: event, kind: kind)
    }
}
