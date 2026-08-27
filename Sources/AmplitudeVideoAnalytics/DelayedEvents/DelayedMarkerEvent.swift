import AmplitudeSwift
import Foundation

/// Carries an event and its lane through the host timeline, for the interceptor to pick back off.
/// `kind` sits outside `BaseEvent.CodingKeys`, so encoding drops it.
final class DelayedMarkerEvent: BaseEvent {
    enum Kind: Equatable {
        case instant
        case delayed
    }

    /// Defaulted so the class declares no designated initializer and inherits `init(from:)`;
    /// markers are built by `init(wrapping:kind:)`, never decoded.
    private(set) var kind: Kind = .delayed

    convenience init(wrapping event: BaseEvent, kind: Kind) {
        self.init(eventType: event.eventType)
        self.kind = kind
        mergeEventOptions(eventOptions: event)
        eventProperties = event.eventProperties
        userProperties = event.userProperties
        groups = event.groups
        groupProperties = event.groupProperties
    }
}
