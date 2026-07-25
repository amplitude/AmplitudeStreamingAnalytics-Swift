import AmplitudeSwift
import Foundation

/// One delayed event awaiting server-side ingestion.
///
/// `timeoutMs` is the TTL last sent to the server; `isFinal` marks an entry that should be
/// flushed (`timeout: 0`) on the next pulse instead of upserted.
struct DelayedEntry: Codable {
    var event: BaseEvent
    var timeoutMs: Int64
    var isFinal: Bool
}

/// Everything the pipeline must survive a process kill with: the delay id the server
/// correlates requests by, the in-flight snapshots keyed by `insert_id`, and instant
/// events that have not been acknowledged yet.
struct DelayedState: Codable {
    var delayId: String
    var entries: [String: DelayedEntry]
    var pendingInstantEvents: [BaseEvent]
}

/// Persists `DelayedState` as a single JSON file so snapshots outlive the process.
///
/// Deliberately uses only `fileExists`, `Data(contentsOf:)` and an atomic `write` — no
/// file-timestamp or disk-space attribute reads — so the package's privacy manifest needs
/// no `NSPrivacyAccessedAPITypes` entry. Emptiness is judged by content length, not by
/// file attributes, for the same reason.
final class DelayedSnapshotStore {
    private let fileUrl: URL
    private let logger: (any Logger)?

    init(apiKey: String, instanceName: String, logger: (any Logger)? = nil) {
        self.fileUrl = Self.fileUrl(apiKey: apiKey, instanceName: instanceName)
        self.logger = logger
    }

    /// True when a previous run left snapshots behind. Used at plugin setup to decide
    /// whether stale entries need flushing, without instantiating a pipeline first.
    static func hasPersistedState(apiKey: String, instanceName: String) -> Bool {
        let url = fileUrl(apiKey: apiKey, instanceName: instanceName)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        guard let data = try? Data(contentsOf: url) else { return false }
        return !data.isEmpty
    }

    func load() -> DelayedState? {
        guard let data = try? Data(contentsOf: fileUrl), !data.isEmpty else { return nil }
        do {
            return try JSONDecoder().decode(DelayedState.self, from: data)
        } catch {
            logger?.error(message: "Delayed events state unreadable, discarding: \(error)")
            clear()
            return nil
        }
    }

    func save(_ state: DelayedState) {
        do {
            let data = try JSONEncoder().encode(state)
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
