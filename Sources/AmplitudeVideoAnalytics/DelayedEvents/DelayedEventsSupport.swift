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

/// Owns a single `UIApplication` background task and ends it exactly once — whether the upload
/// completes first or iOS's expiration handler fires first. A no-op where UIKit is unavailable.
///
/// Ending on `deinit` is what makes it safe to hand down the send path: no early return there can
/// strand the assertion, because dropping the last reference ends it.
///
/// `end()` can be called concurrently from the expiration handler (main thread) and the upload
/// completion (URLSession's queue). It claims the identifier under a lock (read-and-clear in one
/// step) so only the caller that claims a valid id ends the task; the other sees `.invalid` and
/// no-ops. This avoids the double `endBackgroundTask` that iOS treats as a client bug.
final class BackgroundTask {
#if (os(iOS) || os(tvOS) || os(visionOS) || targetEnvironment(macCatalyst)) && !AMPLITUDE_DISABLE_UIKIT
    private let lock = NSLock()
    private var identifier: UIBackgroundTaskIdentifier = .invalid
#endif

    /// `onExpiry` runs when iOS is about to revoke the assertion, before it is ended.
    init(onExpiry: @escaping () -> Void) {
#if (os(iOS) || os(tvOS) || os(visionOS) || targetEnvironment(macCatalyst)) && !AMPLITUDE_DISABLE_UIKIT
        identifier = UIApplication.shared.beginBackgroundTask { [weak self] in
            onExpiry()
            self?.end()
        }
#endif
    }

    deinit {
        end()
    }

    func end() {
#if (os(iOS) || os(tvOS) || os(visionOS) || targetEnvironment(macCatalyst)) && !AMPLITUDE_DISABLE_UIKIT
        lock.lock()
        let id = identifier
        identifier = .invalid
        lock.unlock()
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
#endif
    }
}
