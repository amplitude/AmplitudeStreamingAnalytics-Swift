import AmplitudeSwift
import Foundation

/// Rides the host timeline so it lands ordered after every event tracked before it; `sessionId: -1` keeps it from fabricating a session.
private final class DelayedPulse: BaseEvent {
    convenience init() {
        self.init(sessionId: -1, eventType: "$delayed_pulse")
    }
}

/// Entry point onto the delayed transport, and the `.before` plugin that takes its events back off
/// the host timeline. Tracked events take a round trip through that timeline to pick up the same
/// enrichment as any other event. Do not mutate one after tracking it — track a fresh one carrying
/// the same `insert_id` instead.
final class DelayedEvents: BeforePlugin {
    let configuration: DelayedEventsConfiguration
    private let tracker: DelayedEventTracker

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

    func track(_ event: DelayedEvent, forcePulse: Bool = false) {
        if forcePulse {
            event.markForcePulse()
        }
        amplitude?.track(event: event)
    }

    /// Sends the live set now instead of at the next pulse. Used at backgrounding.
    func pulseNow() {
        amplitude?.track(event: DelayedPulse())
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
        if event is DelayedPulse {
            tracker.pulseNow()
            return nil
        }
        guard let delayed = event as? DelayedEvent else { return event }
        tracker.track(delayed)
        return nil
    }
}
