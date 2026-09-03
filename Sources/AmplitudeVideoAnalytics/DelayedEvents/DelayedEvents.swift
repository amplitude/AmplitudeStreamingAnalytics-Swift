import AmplitudeSwift
import Foundation

/// Entry point onto the delayed transport, and the `.before` plugin that takes its events back off
/// the host timeline. Tracked events take a round trip through that timeline to pick up the same
/// enrichment as any other event. Do not mutate one after tracking it — track a fresh one carrying
/// the same `insert_id` instead.
final class DelayedEvents: BeforePlugin {
    let configuration: DelayedEventsConfiguration
    private let tracker: DelayedEventTracker

    /// Uploads over the real endpoint; the full init is for a test double.
    convenience init(amplitude: Amplitude, configuration: DelayedEventsConfiguration) {
        self.init(amplitude: amplitude,
                  httpClient: DelayedEventsHttpClient(configuration: amplitude.configuration),
                  configuration: configuration)
    }

    init(amplitude: Amplitude,
         httpClient: DelayedEventsUploading,
         configuration: DelayedEventsConfiguration) {
        self.configuration = configuration
        tracker = DelayedEventTracker(amplitudeConfiguration: amplitude.configuration,
                                      configuration: configuration,
                                      httpClient: httpClient)
        super.init()
        amplitude.add(plugin: self)
    }

    /// `forcePulse` asks the transport to send as soon as this event reaches it, rather than leaving
    /// a refreshed entry to the next pulse. It rides the event through the host timeline, so it
    /// cannot arrive ahead of the refresh it belongs to — a separate "send now" call can, and does.
    func track(_ event: DelayedEvent, forcePulse: Bool = false) {
        event.forcePulse = forcePulse
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
