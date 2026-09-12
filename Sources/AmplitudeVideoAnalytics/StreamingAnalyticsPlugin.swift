import AVFoundation
import AmplitudeSwift
import Foundation

struct StreamingAnalyticsConfig {
    var delayedEventTtl: TimeInterval = 3600
    var sampleInterval: TimeInterval = 1
}

/// Reports what your users watch as `[Amplitude] Stream Started` and `[Amplitude] Stream Stopped`.
/// Add it to your `Amplitude` instance, then call ``trackVideo(player:options:)-(AVPlayer,_)`` per viewing.
public final class StreamingAnalyticsPlugin: UtilityPlugin {
    /// Builds the timer that samples one playing viewing. `PulseTimer.init` is the real one.
    typealias MakePulse = (TimeInterval, DispatchQueue, @escaping () -> Void) -> PulseTimer

    private let config: StreamingAnalyticsConfig
    private let makePulse: MakePulse
    private let queue = DispatchQueue(label: "com.amplitude.streamingAnalytics")

    private(set) var transport: DelayedEvents?
    private var observersByPlayer: [ObjectIdentifier: PlayerObserver] = [:]

    public override convenience init() {
        self.init(config: StreamingAnalyticsConfig(), transport: nil, makePulse: PulseTimer.init)
    }

    init(config: StreamingAnalyticsConfig, transport: DelayedEvents?, makePulse: @escaping MakePulse) {
        self.config = config
        self.makePulse = makePulse
        self.transport = transport
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
            if transport == nil {
                let ttl = DelayedEventsConfiguration(ttlMs: config.delayedEventTtl.milliseconds)
                transport = DelayedEvents(amplitude: amplitude, configuration: ttl)
            }
        }
    }

    /// Starts tracking one viewing on any ``Player``. Tracking the same player again ends the previous viewing.
    func trackVideo(player: Player, options: VideoTrackingOptions) {
        track(player, keyedOn: ObjectIdentifier(player), options: options)
    }

    /// Starts tracking one viewing on an `AVPlayer`. It ends on its own when the player is deallocated, or
    /// call ``stopTracking(player:)`` to end it sooner.
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
            // Ends before the replacement starts: both share one `Player`, and the later subscription wins.
            observersByPlayer.removeValue(forKey: identity)?.finish()

            let transformer = PlayerStateTransformer(options: options)
            weak var tracked: PlayerObserver?
            let observer = PlayerObserver(
                player: player,
                queue: queue,
                logger: logger,
                onChange: { [weak self] state in
                    for event in transformer.events(for: state, at: Date()) {
                        transport.track(event)
                    }
                    // Retracking replaces the entry before this observer's late `.final` lands.
                    guard state.phase == .final, self?.observersByPlayer[identity] === tracked else { return }
                    self?.observersByPlayer.removeValue(forKey: identity)
                },
                makePulse: { [makePulse, config, queue] tick in
                    makePulse(config.sampleInterval, queue, tick)
                })
            tracked = observer
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
