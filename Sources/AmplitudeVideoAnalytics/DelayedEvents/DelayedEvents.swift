import AmplitudeSwift
import Foundation

/// Entry point onto the delayed transport, and the `.before` plugin that takes its events back off
/// the host timeline. Tracked events take a round trip through that timeline to pick up the same
/// enrichment as any other event. Do not mutate one after tracking it — track a fresh one carrying
/// the same `insert_id` instead.
final class DelayedEvents: BeforePlugin {
    private let tracker: DelayedEventTracker

    init(amplitude: Amplitude, httpClient: DelayedEventsUploading? = nil) {
        let configuration = amplitude.configuration
        tracker = DelayedEventTracker(
            configuration: configuration,
            httpClient: httpClient ?? DelayedEventsHttpClient(configuration: configuration))
        super.init()
        amplitude.add(plugin: self)
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

    /// Registered after the SDK's own `.before` plugins, so what reaches the transport is already
    /// enriched. Returning nil keeps delayed events out of the host's uploader.
    override func execute(event: BaseEvent) -> BaseEvent? {
        guard let delayed = event as? DelayedEvent else { return event }
        tracker.track(delayed)
        return nil
    }
}
