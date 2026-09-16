import AmplitudeSwift
import Foundation

#if (os(iOS) || os(tvOS) || os(visionOS) || targetEnvironment(macCatalyst)) && !AMPLITUDE_DISABLE_UIKIT
import UIKit
#endif

/// Entry point onto the delayed transport, and the `.before` plugin that takes its events back off
/// the host timeline. Tracked events take a round trip through that timeline to pick up the same
/// enrichment as any other event. Do not mutate one after tracking it — track a fresh one carrying
/// the same `insert_id` instead. Sends its live set when the app enters the background.
final class DelayedEvents: BeforePlugin {
    let configuration: DelayedEventsConfiguration
    private let tracker: DelayedEventTracker
    private let notifications: NotificationCenter
    private var backgroundObserver: NSObjectProtocol?

    convenience init(amplitude: Amplitude, configuration: DelayedEventsConfiguration) {
        let httpClient = DelayedEventsHttpClient(configuration: amplitude.configuration)
        self.init(amplitude: amplitude,
                  configuration: configuration,
                  tracker: DelayedEventTracker(amplitudeConfiguration: amplitude.configuration,
                                               configuration: configuration,
                                               httpClient: httpClient),
                  notifications: .default)
    }

    init(amplitude: Amplitude,
         configuration: DelayedEventsConfiguration,
         tracker: DelayedEventTracker,
         notifications: NotificationCenter) {
        self.configuration = configuration
        self.tracker = tracker
        self.notifications = notifications
        super.init()
        amplitude.add(plugin: self)
#if (os(iOS) || os(tvOS) || os(visionOS) || targetEnvironment(macCatalyst)) && !AMPLITUDE_DISABLE_UIKIT
        backgroundObserver = notifications.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.tracker.pulseNow() }
#endif
    }

    deinit {
        if let backgroundObserver {
            notifications.removeObserver(backgroundObserver)
        }
    }

    func track(_ event: DelayedEvent, forcePulse: Bool = false) {
        if forcePulse {
            event.markForcePulse()
        }
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
