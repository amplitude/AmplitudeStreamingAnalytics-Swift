import AmplitudeSwift
import Foundation

/// Entry point onto the delayed transport. Tracked events take a round trip through the host
/// timeline, so they carry the same identity and context enrichment as any other event.
final class DelayedEvents {
    private weak var amplitude: Amplitude?
    private let tracker: DelayedEventTracker
    private let logger: (any Logger)?

    init(amplitude: Amplitude, httpClient: DelayedEventsUploading? = nil) {
        let configuration = amplitude.configuration
        self.amplitude = amplitude
        self.logger = configuration.loggerProvider
        self.tracker = DelayedEventTracker(
            configuration: configuration,
            httpClient: httpClient ?? DelayedEventsHttpClient(configuration: configuration))
        amplitude.add(plugin: DelayedEventsInterceptorPlugin { [weak self] event, kind in
            self?.route(event, kind: kind)
        })
    }

    /// Ingested on arrival, in the same request as whatever is currently live.
    func track(_ event: BaseEvent) {
        amplitude?.track(event: DelayedMarkerEvent(wrapping: event, kind: .instant))
    }

    /// Held on the server and kept alive by the pulse until flushed or expired.
    func trackDelayed(_ event: BaseEvent) {
        amplitude?.track(event: DelayedMarkerEvent(wrapping: event, kind: .delayed))
    }

    func flush() {
        tracker.flush()
    }

    func discard() {
        tracker.discard()
    }

    private func route(_ event: BaseEvent, kind: DelayedMarkerEvent.Kind) {
        guard let handover = plainCopy(of: event) else {
            logger?.warn(message: "DelayedEvents: cannot encode event, dropping id=\(event.insertId ?? "nil")")
            return
        }
        switch kind {
        case .instant: tracker.track(handover)
        case .delayed: tracker.trackDelayed(handover)
        }
    }

    /// The timeline goes on mutating the instance it enriched, and the tracker may encode what it
    /// is handed on its own queue. A decoded copy severs that aliasing, and sheds the marker.
    private func plainCopy(of event: BaseEvent) -> BaseEvent? {
        guard let data = try? JSONEncoder().encode(event) else { return nil }
        return try? JSONDecoder().decode(BaseEvent.self, from: data)
    }
}
