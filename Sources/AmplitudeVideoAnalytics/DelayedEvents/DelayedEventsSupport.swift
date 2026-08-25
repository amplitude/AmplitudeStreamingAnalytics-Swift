import Foundation

#if (os(iOS) || os(tvOS) || os(visionOS) || targetEnvironment(macCatalyst)) && !AMPLITUDE_DISABLE_UIKIT
import UIKit
#endif

enum DelayedEventsInfo {
    static let version = "0.1.0"
}

enum DelayedEventsError: Error {
    case invalidUrl(String)
    case httpError(code: Int, data: Data?)
    case invalidResponse
}

enum DelayedHosts {
    static let us = "https://api2.amplitude.com/2/httpapi/delayed"
    static let eu = "https://api.eu.amplitude.com/2/httpapi/delayed"
}

enum DelayedEventsDefaults {
    static let pulseInterval: TimeInterval = 60
    static let delayTimeoutMs: Int64 = 3_600_000
    static let eventsSizeLimit = 40_000
}

#if (os(iOS) || os(tvOS) || os(visionOS) || targetEnvironment(macCatalyst)) && !AMPLITUDE_DISABLE_UIKIT
/// Owns a single `UIApplication` background task and ends it exactly once —
/// whether the upload completes first or iOS's expiration handler fires first.
///
/// `end()` can be called concurrently from the expiration handler (main thread) and
/// the upload completion (URLSession's queue). It claims the identifier under a lock
/// (read-and-clear in one step) so only the caller that claims a valid id ends the
/// task; the other sees `.invalid` and no-ops. This avoids the double
/// `endBackgroundTask` that iOS treats as a client bug ("already-invalid identifier").
private final class BackgroundTask {
    private let lock = NSLock()
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init() {
        identifier = UIApplication.shared.beginBackgroundTask { [weak self] in
            self?.end()
        }
    }

    func end() {
        lock.lock()
        let id = identifier
        identifier = .invalid
        lock.unlock()
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
    }
}
#endif

/// Keeps the app alive so an in-flight upload can finish when backgrounded.
/// No-op on platforms without UIKit (e.g. macOS).
enum BackgroundTaskRunner {
    static func begin() -> (() -> Void)? {
        #if (os(iOS) || os(tvOS) || os(visionOS) || targetEnvironment(macCatalyst)) && !AMPLITUDE_DISABLE_UIKIT
        let task = BackgroundTask()
        return { task.end() }
        #else
        return nil
        #endif
    }
}
