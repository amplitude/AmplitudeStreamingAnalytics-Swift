import AmplitudeSwift
import Foundation

/// Diverts delayed events off the host timeline and onto the delayed transport.
/// Registered after the SDK's own `.before` plugins, so what it forwards is already enriched.
final class DelayedEventsInterceptorPlugin: BeforePlugin {
    private let onIntercept: (DelayedEvent) -> Void

    init(onIntercept: @escaping (DelayedEvent) -> Void) {
        self.onIntercept = onIntercept
        super.init()
    }

    override func execute(event: BaseEvent) -> BaseEvent? {
        guard let delayed = event as? DelayedEvent else { return event }
        onIntercept(delayed)
        return nil
    }
}
