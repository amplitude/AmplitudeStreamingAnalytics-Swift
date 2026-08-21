import AmplitudeSwift
import Foundation

struct DelayedEntry: Codable {
    var event: BaseEvent
    var timeoutMs: Int64
    // Stamped on every mutation, so a completing request only removes what it actually sent.
    var revision: Int = 0
}

/// Everything outstanding under one delay id — what a single server row holds.
struct DelayedState: Codable {
    var entries: [String: DelayedEntry]  // insert_id -> its latest snapshot
    var pendingInstantEvents: [BaseEvent]
}

/// The persisted file: every delay id this install still has undelivered work for.
struct DelayedStore: Codable {
    static let currentVersion = 1

    var version: Int = DelayedStore.currentVersion
    var states: [String: DelayedState]  // delayId -> its outstanding work
}

// Keep to `fileExists` / `Data(contentsOf:)` / atomic `write`: timestamp or disk-space reads
// would force an `NSPrivacyAccessedAPITypes` entry in the privacy manifest.
final class DelayedSnapshotStore {
    private let fileUrl: URL
    private let logger: (any Logger)?

    init(apiKey: String, instanceName: String, logger: (any Logger)? = nil) {
        self.fileUrl = Self.fileUrl(apiKey: apiKey, instanceName: instanceName)
        self.logger = logger
    }

    static func hasPersistedState(apiKey: String, instanceName: String) -> Bool {
        let url = fileUrl(apiKey: apiKey, instanceName: instanceName)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        guard let data = try? Data(contentsOf: url) else { return false }
        return !data.isEmpty
    }

    func load() -> DelayedStore? {
        guard let data = try? Data(contentsOf: fileUrl), !data.isEmpty else { return nil }
        do {
            let decoded = try JSONDecoder().decode(DelayedStore.self, from: data)
            // A newer SDK's file decodes cleanly here — unknown keys are ignored — so a
            // version we don't know could carry semantics we'd misread.
            guard decoded.version <= DelayedStore.currentVersion else {
                logger?.error(message: "Delayed events state is version \(decoded.version), "
                    + "newer than \(DelayedStore.currentVersion); discarding")
                clear()
                return nil
            }
            return decoded
        } catch {
            logger?.error(message: "Delayed events state unreadable, discarding: \(error)")
            clear()
            return nil
        }
    }

    /// A drained store leaves no file. An empty one still encodes to non-empty JSON, which
    /// would keep `hasPersistedState` true forever.
    func save(_ store: DelayedStore) {
        guard !store.states.isEmpty else {
            clear()
            return
        }
        do {
            let data = try JSONEncoder().encode(store)
            try FileManager.default.createDirectory(at: fileUrl.deletingLastPathComponent(),
                                                   withIntermediateDirectories: true)
            try data.write(to: fileUrl, options: .atomic)
        } catch {
            logger?.error(message: "Delayed events state save failed: \(error)")
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileUrl)
    }

    static func fileUrl(apiKey: String, instanceName: String) -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let root = directory.appendingPathComponent("com.amplitude.delayed", isDirectory: true)
        let scoped = appScope().map { root.appendingPathComponent($0, isDirectory: true) } ?? root
        // Hashed the way DiagnosticsStorage sanitizes its instance name. Fixed-length hex keeps
        // the two values unambiguous and keeps path separators out of a customer-supplied string.
        return scoped.appendingPathComponent(
            "delayed-\(apiKey.fnv1a64String())-\(instanceName.fnv1a64String()).json")
    }

    /// Non-sandboxed macOS apps share Application Support, so scope by app the way
    /// `PersistentStorage` does — otherwise two apps sharing an api key share one file.
    /// Mirrors `SandboxHelper`, which is public but not constructible from here.
    private static func appScope() -> String? {
        #if os(macOS)
        guard ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] == nil else { return nil }
        return Bundle.main.bundleIdentifier
            ?? (Bundle.main.executablePath ?? ProcessInfo.processInfo.processName).fnv1a64String()
        #else
        return nil
        #endif
    }
}
