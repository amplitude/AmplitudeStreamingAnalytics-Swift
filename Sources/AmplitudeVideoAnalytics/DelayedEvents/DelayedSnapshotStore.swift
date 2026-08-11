import AmplitudeSwift
import Foundation

struct DelayedEntry: Codable {
    var event: BaseEvent
    var timeoutMs: Int64
    var isFinal: Bool
}

struct DelayedState: Codable {
    static let currentVersion = 1

    // Bumped on any breaking change to this shape; lets a future `load()` branch on it
    // instead of discarding old-format state outright.
    var version: Int = DelayedState.currentVersion
    var delayId: String
    var entries: [String: DelayedEntry]
    var pendingInstantEvents: [BaseEvent]
}

// Uses only `fileExists` / `Data(contentsOf:)` / atomic `write` — no file-timestamp or
// disk-space reads — so the privacy manifest needs no `NSPrivacyAccessedAPITypes` entry.
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
