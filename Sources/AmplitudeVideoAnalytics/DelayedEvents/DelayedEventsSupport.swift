import Foundation

#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

enum DelayedEventsInfo {
    static let version = "0.1.0"
}

enum DelayedEventsError: Error {
    case invalidUrl(String)
    case httpError(code: Int, data: Data?)
}

enum DelayedHosts {
    static let us = "https://api2.amplitude.com/2/httpapi/delayed"
    static let eu = "https://api.eu.amplitude.com/2/httpapi/delayed"
}

/// Thin wrapper around `DispatchSourceTimer` that tracks suspend/resume state.
///
/// `DispatchSourceTimer` crashes if it is deallocated while suspended, so this
/// type resumes any suspended timer before cancelling it in `deinit`.
final class PulseTimer {
    private let timer: DispatchSourceTimer
    private var isSuspended = true

    init(interval: TimeInterval, queue: DispatchQueue, handler: @escaping () -> Void) {
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler(handler: handler)
    }

    func resume() {
        guard isSuspended else { return }
        isSuspended = false
        timer.resume()
    }

    func suspend() {
        guard !isSuspended else { return }
        isSuspended = true
        timer.suspend()
    }

    deinit {
        if isSuspended {
            timer.resume()
        }
        timer.cancel()
    }
}

/// Wraps `UIApplication.beginBackgroundTask` so uploads have a chance to finish
/// when the app is backgrounded. No-op on platforms without UIKit (e.g. macOS).
enum BackgroundTaskRunner {
    static func begin() -> (() -> Void)? {
        #if canImport(UIKit) && !os(watchOS)
        let application = UIApplication.shared
        var identifier: UIBackgroundTaskIdentifier = .invalid
        let end = { () in
            guard identifier != .invalid else { return }
            application.endBackgroundTask(identifier)
            identifier = .invalid
        }
        identifier = application.beginBackgroundTask(expirationHandler: end)
        return end
        #else
        return nil
        #endif
    }
}
