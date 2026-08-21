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
            return try JSONDecoder().decode(DelayedStore.self, from: data)
        } catch {
            logger?.error(message: "Delayed events state unreadable, discarding: \(error)")
            clear()
            return nil
        }
    }

    func save(_ store: DelayedStore) {
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

    private static func fileUrl(apiKey: String, instanceName: String) -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return directory
            .appendingPathComponent("com.amplitude.delayed", isDirectory: true)
            .appendingPathComponent("delayed-\(apiKey)-\(instanceName).json")
    }
}
