import AmplitudeSwift
import Foundation

#if (os(iOS) || os(tvOS) || os(visionOS) || targetEnvironment(macCatalyst)) && !AMPLITUDE_DISABLE_UIKIT
import UIKit
#endif

/// Entry point onto the delayed transport, and the `.before` plugin that takes its own events back
/// off the host timeline. Tracked events take a round trip through that timeline to pick up the same
/// enrichment as any other event. Do not mutate one after tracking it — track a fresh one carrying
/// the same `insert_id` instead. Sends its live set when the app enters the background.
final class DelayedEvents: BeforePlugin {
    private let tracker: DelayedEventTracker
    private let notifications: NotificationCenter
    private var backgroundObserver: NSObjectProtocol?
    private let lock = NSLock()
    private var state = State()

    convenience init(amplitude: Amplitude, configuration: DelayedEventsConfiguration) {
        let httpClient = DelayedEventsHttpClient(configuration: amplitude.configuration)
        self.init(amplitude: amplitude,
                  tracker: DelayedEventTracker(amplitudeConfiguration: amplitude.configuration,
                                               configuration: configuration,
                                               httpClient: httpClient),
                  notifications: .default)
    }

    init(amplitude: Amplitude, tracker: DelayedEventTracker, notifications: NotificationCenter) {
        self.tracker = tracker
        self.notifications = notifications
        super.init()
        amplitude.add(plugin: self)
#if (os(iOS) || os(tvOS) || os(visionOS) || targetEnvironment(macCatalyst)) && !AMPLITUDE_DISABLE_UIKIT
        backgroundObserver = notifications.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.pulseBeforeSuspending() }
#endif
    }

    deinit {
        if let backgroundObserver {
            notifications.removeObserver(backgroundObserver)
        }
    }

    /// The array is the unit: its members register together and produce one request. They enter the
    /// in-flight set before any of them reaches the host, so a pulse asked for between two members
    /// still lands after the last.
    func track(_ events: [DelayedEvent]) {
        lock.withLock { state.track(events) }
        events.forEach { amplitude?.track(event: $0) }
    }

    /// Registered after the SDK's own `.before` plugins, so what reaches the transport is already
    /// enriched. Returning nil keeps our delayed events out of the host's uploader; a delayed event
    /// this transport never tracked belongs to another one, or to nobody, and keeps flowing.
    override func execute(event: BaseEvent) -> BaseEvent? {
        guard let delayed = event as? DelayedEvent else { return event }
        guard let shouldSend = lock.withLock({ state.arrive(delayed) }) else { return event }
        tracker.track(delayed, sending: shouldSend)
        return nil
    }

#if (os(iOS) || os(tvOS) || os(visionOS) || targetEnvironment(macCatalyst)) && !AMPLITUDE_DISABLE_UIKIT
    /// Claims the assertion on the main thread where the notification lands, rather than letting the
    /// HTTP client claim its own once the request is finally built: the send waits for whatever is
    /// still crossing the timeline, and that wait would otherwise run with the app free to suspend.
    ///
    /// Exactly one of the two sends below runs in the normal case. `forcePulse` answers true only when
    /// nothing is crossing, and the expiry closure runs only if iOS revokes the assertion before the
    /// wait settles — the backstop that stops a wait ending in silence. Both firing means the expiry
    /// beat a send already asked for, and the tracker coalesces those into one request.
    private func pulseBeforeSuspending() {
        let keepAlive = BackgroundTask { [weak self] in self?.tracker.pulseNow() }
        tracker.keepAwake(keepAlive)

        if lock.withLock({ state.forcePulse() }) {
            tracker.pulseNow()
        }
    }
#endif
}

extension DelayedEvents {
    /// The barrier as a value: the batches still crossing the host timeline. A send asked for here
    /// waits for the batches already crossing when it asked, so it lands behind everything tracked
    /// before it, without the transport ever having to stop accepting events.
    struct State {
        /// One `track` call while its events cross the timeline — a set of events that empties as they
        /// arrive. Batches drain independently and in any order: `track` releases the lock before
        /// handing events to the host, so two callers can interleave and a later batch can finish first.
        private struct Batch {
            typealias Identifier = UInt64

            /// Weak: an event the host drops — opted out, or swallowed by a `.before` plugin ahead of
            /// ours — deallocates, and would otherwise hold its batch open forever.
            private struct Member {
                weak var event: DelayedEvent?
            }

            let id: Identifier
            /// Whether this `track` call's own events asked for a send.
            let wantsPulse: Bool
            private var members: [ObjectIdentifier: Member]

            init(id: Identifier, events: [DelayedEvent]) {
                self.id = id
                wantsPulse = events.contains(where: \.forcePulse)
                members = Dictionary(uniqueKeysWithValues:
                    events.map { (ObjectIdentifier($0), Member(event: $0)) })
            }

            var isEmpty: Bool { members.isEmpty }

            /// `ObjectIdentifier` is an address and addresses are reused, so the key only indexes the
            /// candidate — identity is what decides.
            func contains(_ event: DelayedEvent) -> Bool {
                members[ObjectIdentifier(event)]?.event === event
            }

            mutating func remove(_ event: DelayedEvent) {
                members[ObjectIdentifier(event)] = nil
            }

            mutating func compact() {
                members = members.filter { $0.value.event != nil }
            }
        }

        private var batches: [Batch] = []
        private var nextIdentifier: Batch.Identifier = 0
        /// The batches a background pulse is waiting on, captured when it asked. nil when none waits.
        private var pulseAwaits: Set<Batch.Identifier>?

        mutating func track(_ events: [DelayedEvent]) {
            compact()
            batches.append(Batch(id: nextIdentifier, events: events))
            nextIdentifier += 1
        }

        /// Whether the tracker should send on this event, or nil when the event belongs to no batch of
        /// ours. Only the arrival that empties a batch can answer true, so one request carries a batch.
        mutating func arrive(_ event: DelayedEvent) -> Bool? {
            compact()
            guard let index = batches.firstIndex(where: { $0.contains(event) }) else { return nil }
            batches[index].remove(event)
            guard batches[index].isEmpty else { return false }

            let drained = batches.remove(at: index)
            pulseAwaits?.remove(drained.id)
            let pulseIsDue = pulseAwaits?.isEmpty == true
            if pulseIsDue {
                pulseAwaits = nil
            }
            return drained.wantsPulse || pulseIsDue
        }

        /// Captures the batches crossing right now: the send goes once the last of them lands, whichever
        /// order they land in. Batches tracked afterwards are not waited for — they are legitimately
        /// later. Returns true when nothing is crossing and the caller should send straight away.
        mutating func forcePulse() -> Bool {
            compact()
            guard !batches.isEmpty else { return true }
            pulseAwaits = Set(batches.map(\.id))
            return false
        }

        /// Only runs when a transition runs, so a dropped event releases the barrier on the next
        /// activity rather than the instant it deallocates. A batch the host dropped can never arrive,
        /// so a pulse waiting on it stops waiting; if that empties the wait, the next arrival sends it,
        /// and if nothing else ever arrives the assertion's expiry is the backstop.
        private mutating func compact() {
            for index in batches.indices {
                batches[index].compact()
            }
            let dropped = Set(batches.filter(\.isEmpty).map(\.id))
            guard !dropped.isEmpty else { return }
            batches.removeAll { $0.isEmpty }
            pulseAwaits?.subtract(dropped)
        }
    }
}
