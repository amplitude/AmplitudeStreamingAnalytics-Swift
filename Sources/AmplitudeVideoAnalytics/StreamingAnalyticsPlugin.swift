import AVFoundation
import AmplitudeSwift
import Foundation

#if (os(iOS) || os(tvOS) || os(visionOS) || targetEnvironment(macCatalyst)) && !AMPLITUDE_DISABLE_UIKIT
import UIKit
#endif

/// Tuning for ``StreamingAnalyticsPlugin``. Deliberately not public: these values are a contract
/// with the ingestion server, not a customer knob. ``StreamingAnalyticsPlugin/init()`` uses them.
struct StreamingAnalyticsConfig {
    /// How long the server keeps an unfinished view session before ingesting it on its own.
    var delayedEventTtl: TimeInterval = 3600
    /// How often playing sessions are sampled and refreshed.
    var sampleInterval: TimeInterval = 1
}

/// Reports what your users watch as `[Amplitude] Video Content Started` and `[Amplitude] Video Content Stopped`.
/// Add it to your `Amplitude` instance, then call ``trackVideo(player:options:)-(AVPlayer,_)`` per viewing.
public final class StreamingAnalyticsPlugin: UtilityPlugin {
    private let config: StreamingAnalyticsConfig
    private let now: () -> Date
    private let queue = DispatchQueue(label: "com.amplitude.streamingAnalytics")

    private(set) var transport: DelayedEvents?
    private var sessions: [VideoSession] = []
    private var timer: PulseTimer!
    private var backgroundObserver: NSObjectProtocol?

    public override convenience init() {
        self.init(config: StreamingAnalyticsConfig(), transport: nil)
    }

    init(config: StreamingAnalyticsConfig, transport: DelayedEvents?, now: @escaping () -> Date = Date.init) {
        self.config = config
        self.now = now
        self.transport = transport
        super.init()
        timer = PulseTimer(interval: config.sampleInterval, queue: queue) { [weak self] in self?.refreshSessions() }
    }

    deinit {
        if let backgroundObserver {
            NotificationCenter.default.removeObserver(backgroundObserver)
        }
        // No other reference to the plugin exists at this point, so reading these off-queue
        // cannot race a concurrent mutation; `queue.sync` here could deadlock if the last
        // release happens on the queue itself (e.g. from inside `refreshSessions()` or an `onFinal`).
        let sessions = self.sessions
        let transport = self.transport
        queue.async {
            for session in sessions {
                session.onEmit = { event, forcePulse in transport?.track(event, forcePulse: forcePulse) }
                session.finish()
            }
        }
    }

    public override func setup(amplitude: Amplitude) {
        super.setup(amplitude: amplitude)
        queue.sync {
            if transport == nil {
                let ttl = DelayedEventsConfiguration(ttlMs: Int64(config.delayedEventTtl * 1000))
                transport = DelayedEvents(amplitude: amplitude, configuration: ttl)
            }
        }
        observeBackgrounding()
    }

    /// Starts tracking one viewing on any ``Player``. Tracking the same player again ends the previous session.
    @discardableResult
    func trackVideo(player: Player, options: VideoTrackingOptions) -> VideoSession {
        track(player, identity: ObjectIdentifier(player), options: options)
    }

    /// Starts tracking one viewing on an `AVPlayer`. The session ends on its own when the player is deallocated.
    @discardableResult
    public func trackVideo(player: AVPlayer, options: VideoTrackingOptions) -> VideoSession {
        track(AVPlayerAdapter(player), identity: ObjectIdentifier(player), options: options)
    }

    private func track(_ player: Player, identity: ObjectIdentifier, options: VideoTrackingOptions) -> VideoSession {
        let session = VideoSession(player: player, playerIdentity: identity, options: options, queue: queue, now: now)
        queue.sync {
            sessions.first { $0.playerIdentity == identity }?.finish()
            guard transport != nil else {
                logger.error(message: "StreamingAnalyticsPlugin: trackVideo called before amplitude.add(plugin:); this video is not tracked.")
                session.finish()
                return
            }
            session.onEmit = { [weak self] event, forcePulse in self?.transport?.track(event, forcePulse: forcePulse) }
            session.onFinal = { [weak self, weak session] in
                self?.sessions.removeAll { $0 === session }
                if self?.sessions.isEmpty == true { self?.timer.suspend() }
            }
            sessions.append(session)
            timer.resume()
            session.start()
        }
        return session
    }

    private func refreshSessions(forcePulse: Bool = false) {
        for session in sessions {
            session.refresh(forcePulse: forcePulse)
        }
    }

    var activeSessionCount: Int {
        queue.sync { sessions.count }
    }

    /// Samples every live session and has the refreshes go out at once. Used at backgrounding.
    func refreshAndSend() {
        queue.sync { refreshSessions(forcePulse: true) }
    }

    private var logger: any Logger {
        amplitude?.configuration.loggerProvider ?? ConsoleLogger(logLevel: LogLevelEnum.error.rawValue)
    }

    private func observeBackgrounding() {
        #if (os(iOS) || os(tvOS) || os(visionOS) || targetEnvironment(macCatalyst)) && !AMPLITUDE_DISABLE_UIKIT
        guard backgroundObserver == nil else { return }
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.refreshAndSend() }
        #endif
    }
}
