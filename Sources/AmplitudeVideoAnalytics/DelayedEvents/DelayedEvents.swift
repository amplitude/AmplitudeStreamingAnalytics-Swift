import AmplitudeSwift
import Foundation

/// Entry point onto the delayed transport. Tracked events take a round trip through the host
/// timeline to pick up the same enrichment as any other event. Do not mutate one after
/// tracking it — derive a fresh one with `updated(_:)`.
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
