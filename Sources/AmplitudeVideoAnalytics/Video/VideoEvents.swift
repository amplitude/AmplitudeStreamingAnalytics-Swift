import AmplitudeSwift
import Foundation

/// Pure-function builders for the two video lifecycle events. No state, no networking.
enum VideoEvents {
    static let startedType = "Video Content Started"
    static let stoppedType = "Video Content Stopped"

    static func started(
        options: VideoTrackingOptions,
        player: VideoPlayer,
        viewSessionId: String,
        startPosition: TimeInterval
    ) -> BaseEvent {
        var properties = baseProperties(options: options, player: player, viewSessionId: viewSessionId)
        properties["start_position"] = startPosition
        return makeEvent(type: startedType, properties: properties)
    }

    // swiftlint:disable:next function_parameter_count
    static func stoppedSnapshot(
        options: VideoTrackingOptions,
        player: VideoPlayer,
        viewSessionId: String,
        watchDuration: TimeInterval,
        stopReason: String?,
        errorMessage: String?
    ) -> BaseEvent {
        var properties = baseProperties(options: options, player: player, viewSessionId: viewSessionId)
        properties["current_time"] = player.currentTime
        properties["watch_duration"] = watchDuration
        if let duration = player.duration {
            properties["duration"] = duration
            properties["percent_completed"] = duration == 0 ? 0 : player.currentTime / duration
        }
        if let stopReason {
            properties["stop_reason"] = stopReason
        }
        if let errorMessage {
            properties["error_message"] = errorMessage
        }
        return makeEvent(type: stoppedType, properties: properties)
    }

    private static func baseProperties(
        options: VideoTrackingOptions,
        player: VideoPlayer,
        viewSessionId: String
    ) -> [String: Any] {
        var properties = options.extraEventProperties
        if let contentId = options.contentId {
            properties["content_id"] = contentId
        }
        if let title = options.title {
            properties["title"] = title
        }
        properties["content_type"] = resolvedContentType(options: options, player: player)
        properties["view_session_id"] = viewSessionId
        return properties
    }

    private static func resolvedContentType(options: VideoTrackingOptions, player: VideoPlayer) -> String {
        if let contentType = options.contentType {
            return contentType.rawValue
        }
        return player.duration == nil ? VideoContentType.live.rawValue : VideoContentType.vod.rawValue
    }

    private static func makeEvent(type: String, properties: [String: Any]) -> BaseEvent {
        BaseEvent(
            timestamp: Int64(Date().timeIntervalSince1970 * 1000),
            eventType: type,
            eventProperties: properties
        )
    }
}
