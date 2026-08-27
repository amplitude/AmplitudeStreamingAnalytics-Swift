import AmplitudeSwift
import Foundation

/// Diverts marker events off the host timeline and onto the delayed transport.
/// Registered after the SDK's own `.before` plugins, so what it forwards is already enriched.
final class DelayedEventsInterceptorPlugin: BeforePlugin {
    private let onIntercept: (BaseEvent, DelayedMarkerEvent.Kind) -> Void

    init(onIntercept: @escaping (BaseEvent, DelayedMarkerEvent.Kind) -> Void) {
        self.onIntercept = onIntercept
        super.init()
    }

    override func execute(event: BaseEvent) -> BaseEvent? {
        guard let marker = event as? DelayedMarkerEvent else { return event }
        onIntercept(marker, marker.kind)
        return nil
    }
}
