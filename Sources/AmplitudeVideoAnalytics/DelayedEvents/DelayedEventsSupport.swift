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

/// Wraps `UIApplication.beginBackgroundTask` so uploads have a chance to finish
/// when the app is backgrounded. No-op on platforms without UIKit (e.g. macOS).
///
/// The end-closure is invoked from two threads — the OS expiration handler (main)
/// and the upload completion handler (URLSession's background queue) — so the
/// identifier is guarded by a lock to avoid a double `endBackgroundTask`, which
/// iOS treats as a client bug ("called with already-invalid identifier").
enum BackgroundTaskRunner {
    static func begin() -> (() -> Void)? {
        #if (os(iOS) || os(tvOS) || os(visionOS) || targetEnvironment(macCatalyst)) && !AMPLITUDE_DISABLE_UIKIT
        let application = UIApplication.shared
        let lock = NSLock()
        var identifier: UIBackgroundTaskIdentifier = .invalid
        let end = { () in
            lock.lock()
            defer { lock.unlock() }
            guard identifier != .invalid else { return }
            application.endBackgroundTask(identifier)
            identifier = .invalid
        }
        let started = application.beginBackgroundTask(expirationHandler: end)
        lock.lock()
        identifier = started
        lock.unlock()
        return end
        #else
        return nil
        #endif
    }
}
