import AmplitudeSwift
import Foundation

/// An event bound for the delayed transport. `kind` and `forcePulse` are outside
/// `BaseEvent.CodingKeys`, so encoding drops them.
///
/// The designated initializer is declared rather than inherited on purpose: `BaseEvent` is `open`
/// with public initializers, and inheriting them would let a caller build an event that never chose
/// a lane. Declaring one stops that inheritance and lets both flags be `let`.
final class DelayedEvent: BaseEvent {
    enum Kind: Equatable {
        case instant
        case delayed
    }

    let kind: Kind
    /// Only a track call sets this, through the initializer below — which is not for callers
    /// outside the transport, and stays `internal` when this type is made public.
    let forcePulse: Bool

    convenience init(wrapping event: BaseEvent, kind: Kind) {
        self.init(wrapping: event, kind: kind, forcePulse: false)
    }

    init(wrapping event: BaseEvent, kind: Kind, forcePulse: Bool) {
        self.kind = kind
        self.forcePulse = forcePulse
        super.init(eventType: event.eventType)
        // `mergeEventOptions` copies everything `EventOptions` owns; these four are the rest.
        mergeEventOptions(eventOptions: event)
        eventProperties = event.eventProperties
        userProperties = event.userProperties
        groups = event.groups
        groupProperties = event.groupProperties
    }

    required init(from decoder: Decoder) throws {
        kind = .delayed
        forcePulse = false
        try super.init(from: decoder)
    }
}
