import AmplitudeSwift
import Foundation

/// Entry point onto the delayed transport, and the `.before` plugin that takes its events back off
/// the host timeline. Tracked events take a round trip through that timeline to pick up the same
/// enrichment as any other event. Do not mutate one after tracking it — track a fresh one carrying
/// the same `insert_id` instead.
final class DelayedEvents: BeforePlugin {
    let configuration: DelayedEventsConfiguration
    private let tracker: DelayedEventTracker

    /// Tracks over the real endpoint; the full init takes a tracker a test can build on a double.
    convenience init(amplitude: Amplitude, configuration: DelayedEventsConfiguration) {
        let httpClient = DelayedEventsHttpClient(configuration: amplitude.configuration)
        self.init(amplitude: amplitude,
                  configuration: configuration,
                  tracker: DelayedEventTracker(amplitudeConfiguration: amplitude.configuration,
                                               configuration: configuration,
                                               httpClient: httpClient))
    }

    init(amplitude: Amplitude,
         configuration: DelayedEventsConfiguration,
         tracker: DelayedEventTracker) {
        self.configuration = configuration
        self.tracker = tracker
        super.init()
        amplitude.add(plugin: self)
    }

    /// Nothing goes out on its own: `forcePulse` is what sends the live set off schedule, and it
    /// rides the event through the host timeline so it cannot arrive ahead of what it belongs to.
    func track(_ event: DelayedEvent, forcePulse: Bool = false) {
        let tracked = forcePulse
            ? DelayedEvent(wrapping: event, kind: event.kind, forcePulse: true)
            : event
        amplitude?.track(event: tracked)
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
