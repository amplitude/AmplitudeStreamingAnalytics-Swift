import XCTest
@testable import AmplitudeStreamingAnalytics
import AmplitudeSwift

final class DelayedEventTrackerTests: XCTestCase {
    private var uploader: FakeDelayedEventsUploader!
    private var snapshots: DelayedSnapshotStore!
    private let apiKey = "tracker-\(UUID().uuidString)"

    override func setUp() {
        super.setUp()
        uploader = FakeDelayedEventsUploader()
        uploader.autoSettle = ok
        snapshots = DelayedSnapshotStore(apiKey: apiKey, instanceName: "i")
    }

    override func tearDown() {
        snapshots.clear()
        snapshots = nil
        uploader = nil
        super.tearDown()
    }

    /// A successful response, for tests that do not care which one.
    private var ok: Result<DelayedResponseBody, Error> {
        .success(DelayedResponseBody(id: "d", expiration: 1, flushed: nil))
    }

    // MARK: - insert_id

    func testEventWithoutInsertIdIsRejected() {
        let tracker = makeTracker()
        tracker.track(DelayedEvent(copying: BaseEvent(eventType: "Content Playing"), kind: .delayed))
        expectNoUpload(beyond: 0)

        tracker.track(makeDelayed("a"))
        waitForUploads(1)
        XCTAssertEqual(body(0)?.events.compactMap(\.insertId), ["a"])
    }

    // MARK: - the write path

    func testATrackedEventReachesTheFileAndARefreshDoesNot() {
        uploader.autoSettle = nil
        let tracker = makeTracker(pulseInterval: 0.05)
        tracker.track(makeDelayed("a", type: "First"))
        waitForUploads(1)
        XCTAssertEqual(persistedEntry("a")?.event.eventType, "First")
        // Settled before the refresh, so the write this completion makes cannot carry it.
        uploader.settle(at: 0, with: ok)

        tracker.track(makeDelayed("a", type: "Second"))
        withExtendedLifetime(tracker) {
            waitForUpload { $0.events.map(\.eventType) == ["Second"] }
        }
        XCTAssertEqual(persistedEntry("a")?.event.eventType, "First",
                       "a refresh of a persisted entry stays in memory until the next write")
    }

    func testAFinalizeMovesTheEntryIntoPendingInstantsAndADrainedStoreLeavesNoFile() {
        uploader.autoSettle = nil
        let tracker = makeTracker(pulseInterval: 0.05)
        tracker.track(makeDelayed("a"))
        waitForUploads(1)
        uploader.settle(at: 0, with: ok)

        tracker.track(makeInstant("a"))
        waitForUpload { $0.ttlMs == 0 }
        XCTAssertNil(persistedEntry("a"))
        XCTAssertEqual(persistedState()?.pendingInstantEvents.compactMap(\.insertId), ["a"])

        uploader.settle(at: 1, with: ok)
        withExtendedLifetime(tracker) {
            XCTAssertTrue(waitUntil { !self.persistedFileExists() }, "a drained store leaves no file")
        }
    }

    func testTheFirstLiveEntrySendsAndTheSecondDoesNot() {
        let tracker = makeTracker()
        tracker.track(makeDelayed("a"))
        waitForUploads(1)

        tracker.track(makeDelayed("b"))
        withExtendedLifetime(tracker) { expectNoUpload(beyond: 1) }
    }

    /// Both tracks land before the hop the first one scheduled, so they share one request.
    func testAnInstantDoesNotSendAndRidesTheEntrysAppearance() {
        let tracker = makeTracker()
        tracker.track(makeInstant("i"))
        expectNoUpload(beyond: 0)

        tracker.track(makeDelayed("a"))
        waitForUploads(1)
        XCTAssertEqual(body(0)?.events.compactMap(\.insertId), ["a"])
        XCTAssertEqual(body(0)?.instantEvents?.compactMap(\.insertId), ["i"])
        XCTAssertEqual(body(0)?.ttlMs, 3_600_000)
    }

    func testARefreshSendsNothing() {
        let tracker = makeTracker()
        tracker.track(makeDelayed("a", type: "First"))
        waitForUploads(1)

        tracker.track(makeDelayed("a", type: "Second"))
        withExtendedLifetime(tracker) { expectNoUpload(beyond: 1) }
    }

    // MARK: - the pulse

    func testThePulseSendsWhatTheFileHolds() {
        uploader.autoSettle = nil
        let tracker = makeTracker(pulseInterval: 0.05)
        tracker.track(makeDelayed("a"))
        waitForUploads(1)
        uploader.settle(at: 0, with: ok)

        withExtendedLifetime(tracker) { waitForUploads(2) }
        XCTAssertEqual(body(1)?.events.compactMap(\.insertId),
                       persistedState()?.entries.keys.sorted())
        XCTAssertEqual(body(1)?.ttlMs, 3_600_000)
    }

    func testAFailedRequestChangesNothingAndTheNextPulseResendsIt() {
        uploader.autoSettle = .failure(DelayedEventsError.invalidResponse)
        let tracker = makeTracker(pulseInterval: 0.05)
        tracker.track(makeDelayed("a"))
        tracker.track(makeInstant("i"))
        waitForUpload { $0.instantEvents?.compactMap(\.insertId) == ["i"] }

        withExtendedLifetime(tracker) {
            waitForUploads(uploader.bodies.count + 1)
        }
        let resent = uploader.bodies.last
        XCTAssertEqual(resent?.events.compactMap(\.insertId), ["a"])
        XCTAssertEqual(resent?.instantEvents?.compactMap(\.insertId), ["i"],
                       "a failed request loses nothing, so the instant it carried is resent")
        XCTAssertEqual(persistedState()?.pendingInstantEvents.compactMap(\.insertId), ["i"])
    }

    func testASuccessfulPulseDropsTheInstantsItCarriedAndKeepsItsEntries() {
        uploader.autoSettle = nil
        let tracker = makeTracker(pulseInterval: 0.05)
        tracker.track(makeDelayed("a"))
        tracker.track(makeInstant("i"))
        waitForUpload { $0.instantEvents?.compactMap(\.insertId) == ["i"] }
        uploader.settle(at: 0, with: ok)

        withExtendedLifetime(tracker) {
            waitForUpload { $0.events.compactMap(\.insertId) == ["a"] && $0.instantEvents == nil }
        }
    }

    /// Instants appended while a request is in flight sit behind the ones it carried, so the
    /// completion cuts by count from the front rather than clearing the array.
    func testAnInstantAppendedMidFlightSurvivesTheCompletion() {
        uploader.autoSettle = nil
        let tracker = makeTracker(pulseInterval: 0.05)
        tracker.track(makeDelayed("a"))
        tracker.track(makeInstant("first"))
        waitForUpload { $0.instantEvents?.compactMap(\.insertId) == ["first"] }

        tracker.track(makeInstant("second"))
        uploader.settle(at: 0, with: ok)

        withExtendedLifetime(tracker) {
            waitForUpload { $0.instantEvents?.compactMap(\.insertId) == ["second"] }
        }
    }

    // MARK: - carried-over work

    func testCarriedOverWorkIsFlushedUnderItsOwnDelayIdAtLaunch() {
        snapshots.persist(DelayedStore(states: ["earlier-launch": DelayedState(
            entries: ["old": DelayedEntry(event: makeEvent("old"), revision: 7)],
            pendingInstantEvents: [makeEvent("old-instant")])]))
        uploader.autoSettle = nil

        let tracker = makeTracker()
        waitForUploads(1)
        XCTAssertEqual(body(0)?.id, "earlier-launch")
        XCTAssertEqual(body(0)?.ttlMs, 0, "a carried-over row is always flushed, never aged out")
        XCTAssertEqual(body(0)?.events.count, 0, "its entries go out as instants")
        XCTAssertEqual(Set(body(0)?.instantEvents?.compactMap(\.insertId) ?? []),
                       ["old", "old-instant"])

        tracker.track(makeDelayed("new"))
        waitForUploads(2)
        XCTAssertNotEqual(body(1)?.id, "earlier-launch", "this launch tracks under its own id")
        XCTAssertEqual(body(1)?.events.compactMap(\.insertId), ["new"])
    }

    // MARK: - delay id rotation

    func testAFinalizeThatLeavesASurvivorRotatesTheDelayId() {
        uploader.autoSettle = nil
        let tracker = makeTracker()
        tracker.track(makeDelayed("a"))
        waitForUploads(1)
        uploader.settle(at: 0, with: ok)

        tracker.flush()
        waitForUploads(2)
        XCTAssertEqual(body(1)?.ttlMs, 0)

        // Tracked while the finalize is in flight, so the server never saw it.
        tracker.track(makeDelayed("b"))
        uploader.settle(at: 1, with: ok)

        tracker.flush()
        waitForUploads(3)
        XCTAssertEqual(body(2)?.events.compactMap(\.insertId), ["b"])
        XCTAssertNotEqual(body(2)?.id, body(1)?.id,
                          "survivors move to a row the server has never finalized")
    }

    func testAFinalizeThatDrainsTheRowKeepsTheDelayId() {
        uploader.autoSettle = nil
        let tracker = makeTracker()
        tracker.track(makeDelayed("a"))
        waitForUploads(1)
        uploader.settle(at: 0, with: ok)

        tracker.flush()
        waitForUploads(2)
        uploader.settle(at: 1, with: ok)

        tracker.track(makeDelayed("b"))
        waitForUploads(3)
        XCTAssertEqual(body(2)?.events.compactMap(\.insertId), ["b"])
        XCTAssertEqual(body(2)?.id, body(1)?.id)
    }

    func testAnEntryRefreshedDuringAnInFlightFinalizeSurvivesIt() {
        uploader.autoSettle = nil
        let tracker = makeTracker()
        tracker.track(makeDelayed("a", type: "First"))
        waitForUploads(1)
        uploader.settle(at: 0, with: ok)

        tracker.flush()
        waitForUploads(2)
        XCTAssertEqual(body(1)?.events.map(\.eventType), ["First"])

        tracker.track(makeDelayed("a", type: "Second"))
        uploader.settle(at: 1, with: ok)

        tracker.flush()
        waitForUploads(3)
        XCTAssertEqual(body(2)?.events.map(\.eventType), ["Second"],
                       "the refresh outranks the revision the finalize carried")
    }

    // MARK: - admission

    /// Four 8 kB fillers encode to roughly 33 kB of store; the fifth passes 40,000 bytes.
    func testAdmissionRejectsWhatWouldPushTheStorePastTheSizeLimit() {
        let tracker = makeTracker()
        let filler = String(repeating: "x", count: 8_000)
        for id in ["a", "b", "c", "d", "e"] {
            tracker.track(makeDelayed(id, type: filler))
        }

        tracker.flush()
        waitForUpload { $0.ttlMs == 0 }
        withExtendedLifetime(tracker) {
            XCTAssertEqual(uploader.bodies.last?.events.compactMap(\.insertId), ["a", "b", "c", "d"])
        }
    }

    func testConfiguredSizeLimitReplacesTheDefaultOne() {
        let tracker = makeTracker(eventsSizeLimit: 2_000)
        tracker.track(makeDelayed("a"))
        waitForUploads(1)

        // Well under the 40 kB default, over the limit this tracker was given.
        tracker.track(makeDelayed("b", type: String(repeating: "x", count: 3_000)))
        tracker.flush()
        waitForUpload { $0.ttlMs == 0 }
        withExtendedLifetime(tracker) {
            XCTAssertEqual(uploader.bodies.last?.events.compactMap(\.insertId), ["a"])
        }
    }

    func testUnencodableEventIsRejectedAndKeepsPriorState() {
        let tracker = makeTracker()
        tracker.track(makeDelayed("a"))
        waitForUploads(1)

        let bad = makeEvent("bad")
        bad.eventProperties = ["duration": Double.nan]
        tracker.track(DelayedEvent(copying: bad, kind: .delayed))

        tracker.track(makeDelayed("c"))
        tracker.flush()
        waitForUpload { $0.ttlMs == 0 }
        withExtendedLifetime(tracker) {
            XCTAssertEqual(uploader.bodies.last?.events.compactMap(\.insertId), ["a", "c"])
        }
    }

    /// Deliberate divergence from the browser, which drops the entry here. A refresh that cannot
    /// be admitted must not cost us the live snapshot the server is already holding.
    func testOversizedRefreshKeepsTheLiveEntry() {
        let tracker = makeTracker()
        tracker.track(makeDelayed("a", type: "First"))
        waitForUploads(1)

        tracker.track(makeDelayed("a", type: String(repeating: "x", count: 45_000)))
        tracker.flush()
        waitForUpload { $0.ttlMs == 0 }
        withExtendedLifetime(tracker) {
            XCTAssertEqual(uploader.bodies.last?.events.map(\.eventType), ["First"])
        }
    }

    // MARK: - one request per delay id

    func testASecondRequestWaitsForTheInFlightOne() {
        uploader.autoSettle = nil
        let tracker = makeTracker(pulseInterval: 0.05)
        tracker.track(makeDelayed("a"))
        waitForUploads(1)

        // A second request racing this one could land first and restore stale state.
        tracker.track(makeDelayed("b"))
        withExtendedLifetime(tracker) { expectNoUpload(beyond: 1, timeout: 0.3) }

        uploader.settle(at: 0, with: ok)
        waitForUploads(2)
        XCTAssertEqual(body(1)?.events.compactMap(\.insertId), ["a", "b"])
    }

    /// An appearance blocked by an in-flight request is owed, not lost: the completion issues it.
    func testAnAppearanceBlockedByAnInFlightRequestIsSentOnCompletion() {
        uploader.autoSettle = nil
        let tracker = makeTracker()
        tracker.track(makeInstant("i"))
        tracker.flush()
        waitForUploads(1)

        tracker.track(makeDelayed("a"))
        withExtendedLifetime(tracker) { expectNoUpload(beyond: 1) }

        uploader.settle(at: 0, with: ok)
        waitForUploads(2)
        XCTAssertEqual(body(1)?.events.compactMap(\.insertId), ["a"])
    }

    // MARK: - flush and discard

    func testFlushSendsTheWholeRowWithZeroTimeoutAndDropsItOnSuccess() {
        let tracker = makeTracker(ttlMs: 1_234)
        tracker.track(makeDelayed("a"))
        waitForUploads(1)
        XCTAssertEqual(body(0)?.ttlMs, 1_234)

        tracker.flush()
        waitForUploads(2)
        XCTAssertEqual(body(1)?.ttlMs, 0)
        XCTAssertEqual(body(1)?.events.compactMap(\.insertId), ["a"])
        withExtendedLifetime(tracker) {
            XCTAssertTrue(waitUntil { !self.persistedFileExists() })
        }
    }

    func testFlushKeepsEverythingWhenItFails() {
        uploader.autoSettle = .failure(DelayedEventsError.invalidResponse)
        let tracker = makeTracker()
        tracker.track(makeDelayed("a"))
        waitForUploads(1)

        tracker.flush()
        waitForUpload { $0.ttlMs == 0 }
        withExtendedLifetime(tracker) {
            XCTAssertEqual(persistedState()?.entries.keys.sorted(), ["a"])
        }
    }

    func testFlushOnAnEmptyStoreSendsNothing() {
        let tracker = makeTracker()
        tracker.flush()
        withExtendedLifetime(tracker) { expectNoUpload(beyond: 0) }
    }

    func testDiscardClearsTheFileAndSendsNothing() {
        let tracker = makeTracker()
        tracker.track(makeDelayed("a"))
        waitForUploads(1)
        XCTAssertTrue(persistedFileExists())

        tracker.discard()
        withExtendedLifetime(tracker) {
            XCTAssertTrue(waitUntil { !self.persistedFileExists() },
                          "discarded state must not resurrect at the next launch")
        }
        expectNoUpload(beyond: 1)
    }

    func testDiscardRotatesTheDelayIdSoTheAbandonedRowIsLeftAlone() {
        let tracker = makeTracker()
        tracker.track(makeDelayed("a"))
        waitForUploads(1)

        tracker.discard()
        tracker.track(makeDelayed("b"))
        waitForUploads(2)
        XCTAssertNotEqual(body(0)?.id, body(1)?.id)
    }

    func testAnEmptyStoreNeverSends() {
        let tracker = makeTracker(pulseInterval: 0.02)
        withExtendedLifetime(tracker) { expectNoUpload(beyond: 0, timeout: 0.3) }
    }

    // MARK: - permanent rejections

    func testARejectedPayloadIsDroppedRatherThanResent() {
        uploader.autoSettle = .failure(DelayedEventsError.httpError(code: 413, data: nil))
        let tracker = makeTracker(pulseInterval: 0.05)
        tracker.track(makeDelayed("a"))
        waitForUploads(1)

        withExtendedLifetime(tracker) {
            XCTAssertTrue(waitUntil { !self.persistedFileExists() },
                          "a 413 payload will never be accepted, so it is dropped")
        }
    }

    // MARK: - helpers

    private func makeTracker(pulseInterval: TimeInterval = 60,
                             ttlMs: Int64 = 3_600_000,
                             eventsSizeLimit: Int = 40_000) -> DelayedEventTracker {
        DelayedEventTracker(amplitudeConfiguration: Configuration(apiKey: apiKey),
                            configuration: DelayedEventsConfiguration(pulseInterval: pulseInterval,
                                                                      ttlMs: ttlMs,
                                                                      eventsSizeLimit: eventsSizeLimit),
                            httpClient: uploader,
                            snapshots: snapshots)
    }

    private func makeDelayed(_ insertId: String, type: String = "Content Playing") -> DelayedEvent {
        DelayedEvent(copying: makeEvent(insertId, type: type), kind: .delayed)
    }

    private func makeInstant(_ insertId: String, type: String = "Content Playing") -> DelayedEvent {
        DelayedEvent(copying: makeEvent(insertId, type: type), kind: .instant)
    }

    private func makeEvent(_ insertId: String, type: String = "Content Playing") -> BaseEvent {
        let event = BaseEvent(eventType: type)
        event.insertId = insertId
        return event
    }

    /// The tests here track under one delay id, so the store holds at most that one row.
    private func persistedState() -> DelayedState? {
        snapshots.load()?.states.values.first
    }

    private func persistedEntry(_ insertId: String) -> DelayedEntry? {
        persistedState()?.entries[insertId]
    }

    private func persistedFileExists() -> Bool {
        FileManager.default.fileExists(
            atPath: DelayedSnapshotStore.fileUrl(apiKey: apiKey, instanceName: "i").path)
    }

    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 2) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        } while Date() < deadline
        return condition()
    }

    /// Optional rather than trapping: a wait that already failed should report its own
    /// assertion instead of taking the rest of the run down with it.
    private func body(_ index: Int) -> DelayedRequestBody? {
        let bodies = uploader.bodies
        return bodies.indices.contains(index) ? bodies[index] : nil
    }

    private func waitForUploads(_ count: Int, timeout: TimeInterval = 5) {
        let reached = expectation(description: "\(count) upload(s)")
        uploader.whenUploadCountReaches(count) { reached.fulfill() }
        wait(for: [reached], timeout: timeout)
    }

    private func waitForUpload(timeout: TimeInterval = 5,
                               where predicate: @escaping (DelayedRequestBody) -> Bool) {
        let matched = expectation(description: "upload matching predicate")
        uploader.whenUploadArrives(matching: predicate) { matched.fulfill() }
        wait(for: [matched], timeout: timeout)
    }

    private func expectNoUpload(beyond count: Int, timeout: TimeInterval = 0.2) {
        let extra = expectation(description: "no upload beyond \(count)")
        extra.isInverted = true
        uploader.whenUploadCountReaches(count + 1) { extra.fulfill() }
        wait(for: [extra], timeout: timeout)
    }
}
