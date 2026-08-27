import AmplitudeSwift
import Foundation

/// Entry point onto the delayed transport. Tracked events take a round trip through the host
/// timeline, so they carry the same identity and context enrichment as any other event.
///
/// A tracked event must not be mutated after being handed over, matching the tracker's own
/// contract: the marker is not copied again on the way out.
final class DelayedEvents {
    private weak var amplitude: Amplitude?
    private let tracker: DelayedEventTracker

    init(amplitude: Amplitude, httpClient: DelayedEventsUploading? = nil) {
        let configuration = amplitude.configuration
        self.amplitude = amplitude
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

    /// Swallowing the marker ends the timeline's interest in it, so the enriched instance is
    /// handed straight over; `kind` is outside `CodingKeys` and never reaches the wire.
    private func route(_ event: BaseEvent, kind: DelayedMarkerEvent.Kind) {
        switch kind {
        case .instant: tracker.track(event)
        case .delayed: tracker.trackDelayed(event)
        }
    }
}
