import AmplitudeSwift
import Foundation

/// The only place the wire taxonomy is spelled out. Pure functions.
enum StreamingEvents {
    static let startedType = "[Amplitude] Video Content Started"
    static let stoppedType = "[Amplitude] Video Content Stopped"

    static func started(options: VideoTrackingOptions, state: StreamingState) -> DelayedEvent {
        makeEvent(type: startedType,
                  state: state,
                  kind: .instant,
                  properties: baseProperties(options: options, state: state))
    }

    /// `timeout` is the reason the server holds a row open, so it is the only one that stays in the
    /// delayed lane; every other reason is what finalizes that row.
    static func stopped(options: VideoTrackingOptions, state: StreamingState) -> DelayedEvent {
        var properties = baseProperties(options: options, state: state)
        properties["watch_duration"] = state.watchDuration
        if let duration = state.duration {
            properties["percent_completed"] = percentCompleted(position: state.position, duration: duration)
        }
        if let stopReason = state.stopReason {
            properties["stop_reason"] = stopReason.rawValue
        }
        if let errorMessage = state.errorMessage {
            properties["error_message"] = errorMessage
        }
        return makeEvent(type: stoppedType,
                         state: state,
                         kind: state.stopReason == .timeout ? .delayed : .instant,
                         properties: properties)
    }

    private static func baseProperties(options: VideoTrackingOptions, state: StreamingState) -> [String: Any] {
        var properties = options.extraEventProperties
        if let contentId = options.contentId {
            properties["content_id"] = contentId
        }
        if let title = options.title {
            properties["title"] = title
        }
        properties["content_type"] = (options.contentType ?? (state.duration == nil ? .live : .vod)).rawValue
        properties["view_session_id"] = state.viewSessionId
        properties["play_id"] = state.playId
        if let duration = state.duration {
            properties["duration"] = duration
        }
        properties["start_time"] = state.startTime
        properties["position"] = state.position
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
