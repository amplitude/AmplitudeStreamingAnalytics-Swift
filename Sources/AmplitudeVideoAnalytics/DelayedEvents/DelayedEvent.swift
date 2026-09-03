import AmplitudeSwift
import Foundation

/// An event bound for the delayed transport. `kind` is outside `BaseEvent.CodingKeys`, so
/// encoding drops it.
final class DelayedEvent: BaseEvent {
    enum Kind: Equatable {
        case instant
        case delayed
    }

    /// Defaulted so the class declares no designated initializer and inherits `init(from:)`.
    private(set) var kind: Kind = .delayed

    /// Asks for a request as soon as this lands, instead of leaving the refreshed entry to the next
    /// pulse. It travels with the event, so it cannot overtake the refresh it belongs to.
    private(set) var sendNow = false

    convenience init(wrapping event: BaseEvent, kind: Kind, sendNow: Bool = false) {
        self.init(eventType: event.eventType)
        self.kind = kind
        self.sendNow = sendNow
        // `mergeEventOptions` copies everything `EventOptions` owns; these four are the rest.
        mergeEventOptions(eventOptions: event)
        eventProperties = event.eventProperties
        userProperties = event.userProperties
        groups = event.groups
        groupProperties = event.groupProperties
    }
}
