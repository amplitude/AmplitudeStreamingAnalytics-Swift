import XCTest
@testable import AmplitudeVideoAnalytics
import AmplitudeSwift

final class DelayedSnapshotStoreTests: XCTestCase {
    private let apiKey = "store-test-\(UUID().uuidString)"

    override func tearDown() {
        DelayedSnapshotStore(apiKey: apiKey, instanceName: "i").clear()
        super.tearDown()
    }

    func testSaveLoadRoundTrip() {
        let store = DelayedSnapshotStore(apiKey: apiKey, instanceName: "i")
        let event = BaseEvent(eventType: "Video Content Stopped")
        event.insertId = "ins-1"
        var state = DelayedState(delayId: "d-1", entries: [:], pendingInstantEvents: [])
        state.entries["ins-1"] = DelayedEntry(event: event, timeoutMs: 3_600_000, isFinal: false)
        store.save(state)

        XCTAssertTrue(DelayedSnapshotStore.hasPersistedState(apiKey: apiKey, instanceName: "i"))
        let loaded = store.load()
        XCTAssertEqual(loaded?.delayId, "d-1")
        XCTAssertEqual(loaded?.entries["ins-1"]?.event.eventType, "Video Content Stopped")
        XCTAssertEqual(loaded?.entries["ins-1"]?.timeoutMs, 3_600_000)
        XCTAssertEqual(loaded?.entries["ins-1"]?.isFinal, false)
        XCTAssertEqual(loaded?.version, DelayedState.currentVersion)
    }

    func testStateDefaultsToCurrentVersion() {
        let state = DelayedState(delayId: "d", entries: [:], pendingInstantEvents: [])
        XCTAssertEqual(state.version, DelayedState.currentVersion)
    }

    func testClearRemovesState() {
        let store = DelayedSnapshotStore(apiKey: apiKey, instanceName: "i")
        store.save(DelayedState(delayId: "d", entries: [:], pendingInstantEvents: []))
        store.clear()

        XCTAssertFalse(DelayedSnapshotStore.hasPersistedState(apiKey: apiKey, instanceName: "i"))
        XCTAssertNil(store.load())
    }

    func testHasPersistedStateIsFalseBeforeAnySave() {
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
        first.save(DelayedState(delayId: "d-one", entries: [:], pendingInstantEvents: []))

        XCTAssertEqual(first.load()?.delayId, "d-one")
        XCTAssertNil(second.load())
    }
}
