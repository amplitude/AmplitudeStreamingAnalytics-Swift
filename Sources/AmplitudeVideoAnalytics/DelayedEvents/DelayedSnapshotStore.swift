import AmplitudeSwift
import Foundation

struct DelayedEntry: Codable {
    var event: BaseEvent
    var timeoutMs: Int64
    // Stamped on mutation so a completing request only removes what it actually sent.
    var revision: Int = 0
}

/// Everything outstanding under one delay id — what a single server row holds.
struct DelayedState: Codable {
    var entries: [String: DelayedEntry]  // insert_id -> its latest snapshot
    var pendingInstantEvents: [BaseEvent]

    var isEmpty: Bool { entries.isEmpty && pendingInstantEvents.isEmpty }
}

struct DelayedStore: Codable {
    static let currentVersion = 1

    var version: Int = DelayedStore.currentVersion
    var states: [String: DelayedState]  // delayId -> its outstanding work

    // A key holding an empty state is still no outstanding work, so check depth, not count.
    var isEmpty: Bool { states.values.allSatisfy(\.isEmpty) }
}

// Timestamp or disk-space reads here would force an `NSPrivacyAccessedAPITypes` entry.
final class DelayedSnapshotStore {
    private let fileUrl: URL
    private let logger: (any Logger)?
    private var didExcludeFromBackup = false

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
            // Unknown keys decode silently, so a newer file could carry semantics we'd misread.
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

    func persist(_ store: DelayedStore) {
        // `isEmpty` is deep: keys holding nothing count as empty. Every store encodes to
        // non-empty JSON, so writing one regardless would pin `hasPersistedState` true.
        guard !store.isEmpty else {
            clear()
            return
        }
        do {
            let data = try JSONEncoder().encode(store)
            let directory = fileUrl.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory,
                                                   withIntermediateDirectories: true)
            excludeFromBackupIfNeeded(directory)
            try data.write(to: fileUrl, options: .atomic)
        } catch {
            logger?.error(message: "Delayed events state save failed: \(error)")
        }
    }

    /// `setResourceValues` is costly, so run it once per instance rather than on every save.
    private func excludeFromBackupIfNeeded(_ directory: URL) {
        guard !didExcludeFromBackup else { return }
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do {
            try url.setResourceValues(values)
            didExcludeFromBackup = true
        } catch {
            logger?.error(message: "Delayed events backup exclusion failed: \(error)")
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
        // Hashed like DiagnosticsStorage: keeps the two values unambiguous across the separator
        // and keeps path components out of a customer-supplied instance name.
        return scoped.appendingPathComponent(
            "delayed-\(apiKey.fnv1a64String())-\(instanceName.fnv1a64String()).json")
    }

    /// Non-sandboxed macOS apps share Application Support, so two apps sharing an api key would
    /// otherwise share a file. Mirrors `PersistentStorage.getAppPath`.
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
