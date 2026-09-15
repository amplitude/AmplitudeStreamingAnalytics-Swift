import AmplitudeSwift
import AmplitudeVideoAnalytics
import Foundation

/// `AMPLITUDE_API_KEY` in the environment overrides this, so a real key reaches a real project
/// without being committed. Xcode: set it on the VideoDemo scheme's Run action.
private let demoAPIKey = ProcessInfo.processInfo.environment["AMPLITUDE_API_KEY"] ?? "DEMO-API-KEY"

/// `AMPLITUDE_SERVER_URL` points the delayed transport at a non-default host, which the SDK reads off
/// the shared `Configuration`. It redirects ordinary event ingestion too, so it is for demos only.
private let demoServerURL = ProcessInfo.processInfo.environment["AMPLITUDE_SERVER_URL"]

final class DemoAnalytics: ObservableObject {
    let plugin = StreamingAnalyticsPlugin()
    let activity = StreamActivityLog()

    private let amplitude: Amplitude

    init() {
        amplitude = Amplitude(configuration: Configuration(apiKey: demoAPIKey,
                                                           logLevel: .debug,
                                                           serverUrl: demoServerURL))
        // Registered before the streaming plugin so it observes emitted stream events on the
        // `.before` timeline ahead of the delayed transport consuming them.
        amplitude.add(plugin: StreamActivityRecorder(log: activity))
        amplitude.add(plugin: plugin)
    }
}

struct StreamActivityEntry: Identifiable {
    let id = UUID()
    let at = Date()
    let eventType: String
    let detail: String
}

final class StreamActivityLog: ObservableObject {
    @Published private(set) var entries: [StreamActivityEntry] = []
    @Published var isCapturing = true

    func record(_ entry: StreamActivityEntry) {
        DispatchQueue.main.async {
            guard self.isCapturing else { return }
            self.entries.insert(entry, at: 0)
        }
    }

    func clear() {
        entries.removeAll()
    }
}

// Demo-only hook: copies each `[Amplitude] Stream *` event into the activity log and passes it
// through untouched. Request-level inspection is deferred to the Kong cross-SDK harness.
private final class StreamActivityRecorder: BeforePlugin {
    private let log: StreamActivityLog

    init(log: StreamActivityLog) {
        self.log = log
        super.init()
    }

    override func execute(event: BaseEvent) -> BaseEvent? {
        guard event.eventType.hasPrefix("[Amplitude] Stream") else { return event }
        // A `timeout` stop is the once-a-second row the server holds open, not a viewing that ended.
        // Listing those buries every real event, so the panel shows only what a viewer did.
        guard event.eventProperties?["stop_reason"] as? String != "timeout" else { return event }

        log.record(StreamActivityEntry(eventType: event.eventType, detail: summarize(event)))
        return event
    }

    private func summarize(_ event: BaseEvent) -> String {
        let props = event.eventProperties ?? [:]
        var parts: [String] = []
        if let title = props["title"] as? String { parts.append(title) }
        if let deliveryMode = props["delivery_mode"] as? String { parts.append(deliveryMode) }
        if let duration = props["stream_duration"] as? Double { parts.append(String(format: "%.0fs", duration)) }
        if let percent = props["percent_completed"] as? Double { parts.append(String(format: "%.0f%%", percent)) }
        if let reason = props["stop_reason"] as? String { parts.append(reason) }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }
}
