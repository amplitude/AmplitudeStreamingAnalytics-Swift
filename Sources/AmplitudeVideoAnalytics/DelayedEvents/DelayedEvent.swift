import AmplitudeSwift
import Foundation

/// An event bound for the delayed transport. `kind` and `forcePulse` are outside
/// `BaseEvent.CodingKeys`, so encoding drops them.
final class DelayedEvent: BaseEvent {
    enum Kind: Equatable {
        case instant
        case delayed
    }

    /// Defaulted so the class declares no designated initializer and inherits `init(from:)`.
    private(set) var kind: Kind = .delayed
    private(set) var forcePulse = false

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

    func markForcePulse() {
        forcePulse = true
    }
}
