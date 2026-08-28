import AmplitudeSwift
import Foundation

/// Carries an event and its lane through the host timeline, for the interceptor to pick back off.
/// `kind` sits outside `BaseEvent.CodingKeys`, so encoding drops it.
final class DelayedEvent: BaseEvent {
    enum Kind: Equatable {
        case instant
        case delayed
    }

    /// Defaulted so the class declares no designated initializer and inherits `init(from:)`;
    /// these are built by `init(wrapping:kind:)`, never decoded.
    private(set) var kind: Kind = .delayed

    /// `mergeEventOptions` overlays with `source ?? self`, so it copies wholesale only because a
    /// fresh event starts out nil; the four assignments after it are the fields `BaseEvent` adds
    /// over `EventOptions`, which it does not touch.
    convenience init(wrapping event: BaseEvent, kind: Kind) {
        self.init(eventType: event.eventType)
        self.kind = kind
        mergeEventOptions(eventOptions: event)
        eventProperties = event.eventProperties
        userProperties = event.userProperties
        groups = event.groups
        groupProperties = event.groupProperties
    }

    /// A fresh event for the same entry: same `insert_id` and lane, new content. Tracking it
    /// replaces the stored entry rather than adding one, and re-enriches on the way through.
    ///
    /// Deriving rather than mutating is how an already-tracked event stays untouched — the
    /// inherited setters cannot be sealed, so this is the convention that stands in for it.
    func updated(_ changes: (BaseEvent) -> Void) -> DelayedEvent {
        let next = DelayedEvent(wrapping: self, kind: kind)
        changes(next)
        next.insertId = insertId
        return next
    }
}
