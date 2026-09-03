import AmplitudeSwift
import Foundation

/// Entry point onto the delayed transport, and the `.before` plugin that takes its events back off
/// the host timeline. Tracked events take a round trip through that timeline to pick up the same
/// enrichment as any other event. Do not mutate one after tracking it — track a fresh one carrying
/// the same `insert_id` instead.
final class DelayedEvents: BeforePlugin {
    let configuration: DelayedEventsConfiguration
    private let tracker: DelayedEventTracker

    convenience init(amplitude: Amplitude) {
        self.init(amplitude: amplitude, httpClient: nil, configuration: DelayedEventsConfiguration())
    }

    init(amplitude: Amplitude,
         httpClient: DelayedEventsUploading?,
         configuration: DelayedEventsConfiguration) {
        let amplitudeConfiguration = amplitude.configuration
        self.configuration = configuration
        tracker = DelayedEventTracker(
            amplitudeConfiguration: amplitudeConfiguration,
            configuration: configuration,
            httpClient: httpClient ?? DelayedEventsHttpClient(configuration: amplitudeConfiguration))
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
