import XCTest
@testable import AmplitudeVideoAnalytics
import AmplitudeSwift

final class DelayedSnapshotStoreTests: XCTestCase {
    private let apiKey = "store-test-\(UUID().uuidString)"

    override func tearDown() {
        DelayedSnapshotStore(apiKey: apiKey, instanceName: "i").clear()
        super.tearDown()
    }

    private func entry(insertId: String, timeoutMs: Int64, revision: Int = 0) -> DelayedEntry {
        let event = BaseEvent(eventType: "Video Content Stopped")
        event.insertId = insertId
        return DelayedEntry(event: event, timeoutMs: timeoutMs, revision: revision)
    }

    func testSaveLoadRoundTripAcrossMultipleDelayIds() {
        let store = DelayedSnapshotStore(apiKey: apiKey, instanceName: "i")
        let instant = BaseEvent(eventType: "Video Content Started")
        instant.insertId = "ins-3"
        let saved = DelayedStore(states: [
            "delay-a": DelayedState(
                entries: ["ins-1": entry(insertId: "ins-1", timeoutMs: 3_600_000, revision: 2)],
                pendingInstantEvents: []
            ),
            "delay-b": DelayedState(
                entries: ["ins-2": entry(insertId: "ins-2", timeoutMs: 60_000)],
                pendingInstantEvents: [instant]
            )
        ])
        store.persist(saved)

        XCTAssertTrue(DelayedSnapshotStore.hasPersistedState(apiKey: apiKey, instanceName: "i"))
        let loaded = store.load()
        XCTAssertEqual(loaded?.version, DelayedStore.currentVersion)
        XCTAssertEqual(Set(loaded?.states.keys.map { $0 } ?? []), ["delay-a", "delay-b"])
        XCTAssertEqual(loaded?.states["delay-a"]?.entries["ins-1"]?.event.eventType, "Video Content Stopped")
        XCTAssertEqual(loaded?.states["delay-a"]?.entries["ins-1"]?.timeoutMs, 3_600_000)
        XCTAssertEqual(loaded?.states["delay-a"]?.entries["ins-1"]?.revision, 2)
        XCTAssertEqual(loaded?.states["delay-a"]?.pendingInstantEvents.count, 0)
        XCTAssertEqual(loaded?.states["delay-b"]?.entries["ins-2"]?.timeoutMs, 60_000)
        XCTAssertEqual(loaded?.states["delay-b"]?.pendingInstantEvents.first?.insertId, "ins-3")
    }

    func testStoreDefaultsToCurrentVersion() {
        XCTAssertEqual(DelayedStore(states: [:]).version, 1)
        XCTAssertEqual(DelayedStore.currentVersion, 1)
    }

    private func fileUrl() -> URL {
        DelayedSnapshotStore.fileUrl(apiKey: apiKey, instanceName: "i")
    }

    private func nonEmptyStore(delayId: String = "d") -> DelayedStore {
        DelayedStore(states: [delayId: DelayedState(
            entries: ["ins-1": entry(insertId: "ins-1", timeoutMs: 3_600_000)],
            pendingInstantEvents: []
        )])
    }

    /// Keys are present but hold nothing — no outstanding work, despite `states` being non-empty.
    private func hollowStore() -> DelayedStore {
        DelayedStore(states: ["d": DelayedState(entries: [:], pendingInstantEvents: [])])
    }

    func testUndecodableFileIsDiscarded() {
        let store = DelayedSnapshotStore(apiKey: apiKey, instanceName: "i")
        store.persist(nonEmptyStore())
        try? Data("not json".utf8).write(to: fileUrl(), options: .atomic)

        XCTAssertNil(store.load())
        XCTAssertFalse(DelayedSnapshotStore.hasPersistedState(apiKey: apiKey, instanceName: "i"))
    }

    func testFileFromNewerVersionIsDiscarded() throws {
        let store = DelayedSnapshotStore(apiKey: apiKey, instanceName: "i")
        store.persist(nonEmptyStore())
        var future = nonEmptyStore()
        future.version = DelayedStore.currentVersion + 1
        try JSONEncoder().encode(future).write(to: fileUrl(), options: .atomic)

        XCTAssertNil(store.load())
        XCTAssertFalse(DelayedSnapshotStore.hasPersistedState(apiKey: apiKey, instanceName: "i"))
    }

    func testStorageDirectoryIsExcludedFromBackup() throws {
        // The directory outlives any single test, so clear the flag first — otherwise this
        // passes on an attribute a previous run set.
        var cleared = fileUrl().deletingLastPathComponent()
        try FileManager.default.createDirectory(at: cleared, withIntermediateDirectories: true)
        var off = URLResourceValues()
        off.isExcludedFromBackup = false
        try cleared.setResourceValues(off)

        DelayedSnapshotStore(apiKey: apiKey, instanceName: "i").persist(nonEmptyStore())

        // Read through a fresh URL: `setResourceValues` caches on the instance it was called
        // on, so re-reading that one can return what we wrote rather than what is on disk.
        let onDisk = fileUrl().deletingLastPathComponent()
        let values = try onDisk.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    func testAmbiguousApiKeyAndInstanceSplitsDoNotShareAFile() {
        XCTAssertNotEqual(DelayedSnapshotStore.fileUrl(apiKey: "a-b", instanceName: "c"),
                          DelayedSnapshotStore.fileUrl(apiKey: "a", instanceName: "b-c"))
    }

    func testPathSeparatorsInInstanceNameCannotEscapeTheDirectory() {
        let url = DelayedSnapshotStore.fileUrl(apiKey: "k", instanceName: "../../escape")
        XCTAssertEqual(url.deletingLastPathComponent(),
                       DelayedSnapshotStore.fileUrl(apiKey: "k", instanceName: "i")
                           .deletingLastPathComponent())
        XCTAssertFalse(url.path.contains(".."))
    }

    func testPersistingADrainedStoreLeavesNoFile() {
        let store = DelayedSnapshotStore(apiKey: apiKey, instanceName: "i")
        store.persist(nonEmptyStore())
        XCTAssertTrue(DelayedSnapshotStore.hasPersistedState(apiKey: apiKey, instanceName: "i"))

        store.persist(DelayedStore(states: [:]))

        XCTAssertFalse(DelayedSnapshotStore.hasPersistedState(apiKey: apiKey, instanceName: "i"))
        XCTAssertNil(store.load())
    }

    func testPersistingAStoreWhoseKeysAreAllEmptyLeavesNoFile() {
        let store = DelayedSnapshotStore(apiKey: apiKey, instanceName: "i")
        store.persist(nonEmptyStore())
        XCTAssertTrue(DelayedSnapshotStore.hasPersistedState(apiKey: apiKey, instanceName: "i"))

        store.persist(hollowStore())

        XCTAssertFalse(DelayedSnapshotStore.hasPersistedState(apiKey: apiKey, instanceName: "i"))
        XCTAssertNil(store.load())
    }

    func testClearRemovesState() {
        let store = DelayedSnapshotStore(apiKey: apiKey, instanceName: "i")
        store.persist(nonEmptyStore())
        store.clear()

        XCTAssertFalse(DelayedSnapshotStore.hasPersistedState(apiKey: apiKey, instanceName: "i"))
        XCTAssertNil(store.load())
    }

    func testHasPersistedStateIsFalseBeforeAnyPersist() {
        XCTAssertFalse(DelayedSnapshotStore.hasPersistedState(apiKey: apiKey, instanceName: "i"))
        XCTAssertNil(DelayedSnapshotStore(apiKey: apiKey, instanceName: "i").load())
    }

    func testStoresForDifferentInstancesAreIsolated() {
        let first = DelayedSnapshotStore(apiKey: apiKey, instanceName: "one")
        let second = DelayedSnapshotStore(apiKey: apiKey, instanceName: "two")
        defer {
            first.clear()
            second.clear()
        }
        first.persist(nonEmptyStore(delayId: "d-one"))

        XCTAssertEqual(first.load()?.states.keys.map { $0 }, ["d-one"])
        XCTAssertNil(second.load())
    }

    /// Measurement, not an assertion of behaviour: sizes the 40,000-byte pulse cap against a real
    /// `ContextPlugin`-enriched snapshot. The bound is asserted loosely so it fails only if the
    /// enriched shape grows far beyond what the cap was sized for.
    func testEnrichedSnapshotEncodedSize() throws {
        let event = BaseEvent(
            deviceId: "F1B7A2C4-9E3D-4A61-8B0F-2D5C7E1A4B93",
            timestamp: 1_755_648_000_000,
            sessionId: 1_755_647_900_000,
            insertId: "3C9D5E71-64A2-4F08-9B1D-8E0A6C2F5D74",
            appVersion: "4.12.3",
            versionName: "4.12.3",
            platform: "iOS",
            osName: "ios",
            osVersion: "18.5",
            deviceManufacturer: "Apple",
            deviceModel: "iPhone17,2",
            carrier: "Verizon",
            country: "US",
            language: "en-US",
            library: "amplitude-swift/1.18.6",
            eventType: "Video Content Stopped",
            eventProperties: [
                "content_id": "series/stranger-things/s04e09",
                "title": "Stranger Things — The Piggyback",
                "content_type": "vod",
                "duration": 8_340.0,
                "current_time": 4_213.417,
                "watch_duration": 3_988.204,
                "percent_completed": 0.5052058752997602,
                "stop_reason": "paused",
                "view_session_id": "8A2E4C60-1F7B-4D39-A5C8-90B3E6D7F214"
            ]
        )
        let entry = DelayedEntry(event: event, timeoutMs: 3_600_000, revision: 1)
        let eventBytes = try JSONEncoder().encode(event).count
        let entryBytes = try JSONEncoder().encode(entry).count
        let storeBytes = try JSONEncoder().encode(
            DelayedStore(states: ["d": DelayedState(entries: ["i": entry], pendingInstantEvents: [event])])
        ).count

        print("[measurement] enriched BaseEvent: \(eventBytes) bytes; "
            + "DelayedEntry: \(entryBytes) bytes; "
            + "one-entry-plus-one-instant DelayedStore: \(storeBytes) bytes")
        XCTAssertLessThan(eventBytes, 2_000)
    }
}
