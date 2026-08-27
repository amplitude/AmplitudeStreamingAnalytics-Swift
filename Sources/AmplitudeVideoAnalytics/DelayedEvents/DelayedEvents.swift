import AmplitudeSwift
import Foundation

/// Entry point onto the delayed transport. Tracked events take a round trip through the host
/// timeline, so they carry the same identity and context enrichment as any other event.
///
/// A tracked event must not be mutated after being handed over, matching the tracker's own
/// contract: the event is not copied again on the way out.
final class DelayedEvents {
    private weak var amplitude: Amplitude?
    private let tracker: DelayedEventTracker

    init(amplitude: Amplitude, httpClient: DelayedEventsUploading? = nil) {
        let configuration = amplitude.configuration
        self.amplitude = amplitude
        self.tracker = DelayedEventTracker(
            configuration: configuration,
            httpClient: httpClient ?? DelayedEventsHttpClient(configuration: configuration))
        amplitude.add(plugin: DelayedEventsInterceptorPlugin { [weak self] event in
            self?.tracker.track(event)
        })
    }

    /// The event's own `kind` decides its lane; the tracker routes on it once enriched.
    func track(_ event: DelayedEvent) {
        amplitude?.track(event: event)
    }

    func flush() {
        tracker.flush()
    }

    func discard() {
        tracker.discard()
    }
}
