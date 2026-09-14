import AVFoundation
import AmplitudeSwift
import Foundation

struct StreamingAnalyticsConfig {
    var delayedEventTtl: TimeInterval = 3600
    var sampleInterval: TimeInterval = 1
}

/// Reports what your users watch as Amplitude streaming events.
/// Add it to your `Amplitude` instance, then call ``trackVideo(player:options:)-(AVPlayer,_)`` per viewing.
public final class StreamingAnalyticsPlugin: UtilityPlugin {
    /// Builds the timer that samples one playing viewing. `PulseTimer.init` is the real one.
    typealias PulseTimerFactory = (TimeInterval, DispatchQueue, @escaping () -> Void) -> PulseTimer
    /// Builds the transport, once `setup(amplitude:)` supplies the host. `DelayedEvents.init` is the real one.
    typealias DelayedEventsFactory = (Amplitude, DelayedEventsConfiguration) -> DelayedEvents

    private let config: StreamingAnalyticsConfig
    private let delayedEventsFactory: DelayedEventsFactory
    private let pulseTimerFactory: PulseTimerFactory
    private let queue = DispatchQueue(label: "com.amplitude.streamingAnalytics")

    private var transport: DelayedEvents?
    private var observersByPlayer: [ObjectIdentifier: PlayerObserver] = [:]

    public override convenience init() {
        self.init(config: StreamingAnalyticsConfig(),
                  delayedEventsFactory: DelayedEvents.init(amplitude:configuration:),
                  pulseTimerFactory: PulseTimer.init)
    }

    init(config: StreamingAnalyticsConfig,
         delayedEventsFactory: @escaping DelayedEventsFactory,
         pulseTimerFactory: @escaping PulseTimerFactory) {
        self.config = config
        self.delayedEventsFactory = delayedEventsFactory
        self.pulseTimerFactory = pulseTimerFactory
        super.init()
    }

    /// Each observer's `onChange` already forwards to `transport` without needing `self`, so
    /// finishing every viewing here still delivers its closing event.
    deinit {
        let observers = self.observersByPlayer.values
        queue.async {
            for observer in observers { observer.finish() }
        }
    }

    public override func setup(amplitude: Amplitude) {
        super.setup(amplitude: amplitude)
        queue.sync {
            guard transport == nil else { return }

            let configuration = DelayedEventsConfiguration(ttlMs: config.delayedEventTtl.milliseconds)
            transport = delayedEventsFactory(amplitude, configuration)
        }
    }

    /// Starts tracking one viewing on any ``Player``. A player already being tracked is left alone.
    func trackVideo(player: Player, options: VideoTrackingOptions) {
        track(player, keyedOn: ObjectIdentifier(player), options: options)
    }

    /// Starts tracking one viewing on an `AVPlayer`. It ends on its own when the player is deallocated, or
    /// call ``stopTracking(player:)`` to end it sooner.
    ///
    /// One viewing per player: if this player is already being tracked, the call is refused and logged, and
    /// the viewing already running is left untouched. To track it again — a new video in the same player —
    /// call ``stopTracking(player:)`` first.
    public func trackVideo(player avPlayer: AVPlayer, options: VideoTrackingOptions) {
        track(AVPlayerAdapter(avPlayer), keyedOn: ObjectIdentifier(avPlayer), options: options)
    }

    /// Ends the viewing being tracked for `avPlayer` and sends its closing event. Does nothing if that
    /// player is not being tracked, and leaves playback untouched.
    public func stopTracking(player avPlayer: AVPlayer) {
        stopTracking(keyedOn: ObjectIdentifier(avPlayer))
    }

    /// Ends the viewing being tracked for `player`. Does nothing if that player is not being tracked.
    func stopTracking(player: Player) {
        stopTracking(keyedOn: ObjectIdentifier(player))
    }

    /// `keyedOn` comes from the caller, not from a `Player`: the `AVPlayer` overload wraps its player in a
    /// fresh adapter every call, so a key derived there would never match the viewing already being tracked.
    private func track(_ player: Player, keyedOn identity: ObjectIdentifier, options: VideoTrackingOptions) {
        queue.sync {
            guard let transport else {
                logger.error(message: "StreamingAnalyticsPlugin: trackVideo called before amplitude.add(plugin:); this video is not tracked.")
                return
            }
            // One viewing per player, as `Player.startObserving(onEvent:)` promises one layer down. A viewing
            // that ended on its own has already evicted itself, because its `.final` reaches this same serial
            // queue; one that has not is still live, and replacing it silently would drop what it was sending.
            guard observersByPlayer[identity] == nil else {
                logger.error(message: "StreamingAnalyticsPlugin: this player is already being tracked; call stopTracking(player:) before tracking it again.")
                return
            }

            let transformer = PlayerStateTransformer(options: options)
            let observer = PlayerObserver(
                player: player,
                queue: queue,
                logger: logger,
                onChange: { [weak self] state in
                    for event in transformer.events(for: state, at: Date()) {
                        transport.track(event)
                    }
                    // No replacement can be sitting at this key: tracking refuses while one is registered.
                    guard state.phase == .final else { return }
                    self?.observersByPlayer.removeValue(forKey: identity)
                },
                makePulse: { [pulseTimerFactory, config, queue] tick in
                    pulseTimerFactory(config.sampleInterval, queue, tick)
                })
            observersByPlayer[identity] = observer
            observer.start()
        }
    }

    private func stopTracking(keyedOn identity: ObjectIdentifier) {
        queue.sync { observersByPlayer.removeValue(forKey: identity)?.finish() }
    }

    /// A test seam: how many viewings are live. Nothing in the SDK reads it.
    var activeSessionCount: Int {
        queue.sync { observersByPlayer.count }
    }

    private var logger: any Logger {
        amplitude?.configuration.loggerProvider ?? ConsoleLogger(logLevel: LogLevelEnum.error.rawValue)
    }
}

private extension TimeInterval {
    /// `TimeInterval` is seconds; the delayed-events wire protocol counts in milliseconds.
    var milliseconds: Int64 {
        Int64(self * 1000)
    }
}
