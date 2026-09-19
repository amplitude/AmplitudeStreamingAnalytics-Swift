import AmplitudeSwift
import Foundation

/// An event bound for the delayed transport. `kind` is outside `BaseEvent.CodingKeys`,
/// so encoding drops it.
final class DelayedEvent: BaseEvent {
    enum Kind: Equatable {
        case instant
        case delayed
    }

    /// Defaulted so the class declares no designated initializer and inherits `init(from:)`.
    private(set) var kind: Kind = .delayed

    convenience init(copying event: BaseEvent, kind: Kind) {
        self.init(eventType: event.eventType)
        self.kind = kind
        // `mergeEventOptions` copies everything `EventOptions` owns; these four are the rest.
        mergeEventOptions(eventOptions: event)
        eventProperties = event.eventProperties
        userProperties = event.userProperties
        groups = event.groups
        groupProperties = event.groupProperties
    }
}
