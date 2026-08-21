import XCTest
@testable import AmplitudeVideoAnalytics
import AmplitudeSwift

/// Records every upload and answers with a scripted result. Shared with the Task 4
/// interceptor tests, so `captured` is lock-guarded: the pipeline uploads from its own
/// serial queue while assertions read from the test thread.
final class FakeDelayedUploader: DelayedEventsUploading {
    private let lock = NSLock()
    private var requests: [DelayedRequestBody] = []
    private var result: Result<DelayedResponseBody, Error> = .success(DelayedResponseBody(id: "d",
                                                                                          expiration: nil,
                                                                                          flushed: nil))
    /// Holds completions instead of firing them, so a mutation can land mid-flight.
    private var deferred = false
    private var pending: [(Result<DelayedResponseBody, Error>) -> Void] = []
    private var uploadObserver: (() -> Void)?

    /// Called after the completion handler returns, so pipeline state is already settled.
    var onUpload: (() -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return uploadObserver
        }
        set {
            lock.lock()
            uploadObserver = newValue
            lock.unlock()
        }
    }

    var captured: [DelayedRequestBody] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    var nextResult: Result<DelayedResponseBody, Error> {
        get {
            lock.lock()
            defer { lock.unlock() }
            return result
        }
        set {
            lock.lock()
            result = newValue
            lock.unlock()
        }
    }

    var deferCompletion: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return deferred
        }
        set {
            lock.lock()
            deferred = newValue
            lock.unlock()
        }
    }

    @discardableResult
    func upload(_ body: DelayedRequestBody,
                completion: @escaping (Result<DelayedResponseBody, Error>) -> Void) -> URLSessionDataTask? {
        lock.lock()
        requests.append(body)
        let scripted = result
        let holdIt = deferred
        let observer = uploadObserver
        if holdIt {
            pending.append(completion)
        }
        lock.unlock()
        if !holdIt {
            completion(scripted)
        }
        observer?()
        return nil
    }

    func completePending(_ result: Result<DelayedResponseBody, Error>) {
        lock.lock()
        let waiting = pending
        pending = []
        lock.unlock()
        waiting.forEach { $0(result) }
    }

    /// Completes only the oldest held request, leaving any later one in flight.
    func completeOldestPending(_ result: Result<DelayedResponseBody, Error>) {
        lock.lock()
        let oldest = pending.isEmpty ? nil : pending.removeFirst()
        lock.unlock()
        oldest?(result)
    }
}

final class DelayedEventPipelineTests: XCTestCase {
    private var uploader: FakeDelayedUploader!
    private var store: DelayedSnapshotStore!
    private var pipeline: DelayedEventPipeline!
    private let apiKey = "pipeline-test-\(UUID().uuidString)"

    override func setUp() {
        super.setUp()
        uploader = FakeDelayedUploader()
        store = DelayedSnapshotStore(apiKey: apiKey, instanceName: "i")
        pipeline = makePipeline()
    }

    override func tearDown() {
        pipeline = nil
        store.clear()
        super.tearDown()
    }

    /// `pulseInterval: 3600` keeps the timer from firing during the test — every upload
    /// observed here was triggered explicitly by `track`/`flushPersistedEntries`.
    private func makePipeline() -> DelayedEventPipeline {
        DelayedEventPipeline(configuration: Configuration(apiKey: apiKey),
                             store: store,
                             httpClient: uploader,
                             pulseInterval: 3600)
    }

    private func stopped(_ insertId: String, timestamp: Int64 = 1_752_000_000_000) -> BaseEvent {
        let event = BaseEvent(eventType: "Video Content Stopped")
        event.insertId = insertId
        event.timestamp = timestamp
        return event
    }

    private func started(_ insertId: String) -> BaseEvent {
        let event = BaseEvent(eventType: "Video Content Started")
        event.insertId = insertId
        event.timestamp = 1_752_000_000_000
        return event
    }

    private func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    private func waitForUpload(count: Int) {
        let expectation = expectation(description: "upload \(count)")
        expectation.assertForOverFulfill = false
        uploader.onUpload = { [uploader] in
            if uploader?.captured.count ?? 0 >= count { expectation.fulfill() }
        }
        if uploader.captured.count >= count { expectation.fulfill() }
        wait(for: [expectation], timeout: 10)
    }

    /// Upload responses are handled on the pipeline's queue *after* the completion handler
    /// returns, so assertions about persisted state have to wait for that hop.
    private func waitUntil(_ message: String, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(10)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), message)
    }

    private func request(underId id: String) -> DelayedRequestBody? {
        uploader.captured.last { $0.id == id }
    }

    // MARK: - upsert + instant pairing

    // Asserts the shape of the delayed upsert itself; the instant tracked first rides
    // its own immediate flush (see testInstantEventsDroppedAfterSuccess).
    func testFirstDelayedTrackSendsUpsertUnderTheCurrentDelayId() {
        pipeline.track(started("start-1"), delay: .instant)
        pipeline.track(stopped("stop-1"), delay: .delayed(timeout: 3600))
        waitForUpload(count: 2)

        let last = uploader.captured.last!
        XCTAssertEqual(last.timeout, 3_600_000)
        XCTAssertEqual(last.events.map(\.insertId), ["stop-1"])
        XCTAssertEqual(last.apiKey, apiKey)
        XCTAssertEqual(last.id, pipeline.currentDelayId)
    }

    func testInstantEventsDroppedAfterSuccess() {
        pipeline.track(started("start-1"), delay: .instant)
        waitForUpload(count: 1)
        XCTAssertEqual(uploader.captured[0].instantEvents?.map(\.insertId), ["start-1"])

        pipeline.track(stopped("stop-1"), delay: .delayed(timeout: 3600))
        waitForUpload(count: 2)
        XCTAssertNil(uploader.captured.last!.instantEvents)
    }

    func testInstantEventsRetainedAfterFailure() {
        uploader.nextResult = .failure(DelayedEventsError.httpError(code: 500, data: nil))
        pipeline.track(started("start-1"), delay: .instant)
        waitForUpload(count: 1)

        uploader.nextResult = .success(DelayedResponseBody(id: "d", expiration: nil, flushed: nil))
        pipeline.track(stopped("stop-1"), delay: .delayed(timeout: 3600))
        waitForUpload(count: 2)
        XCTAssertEqual(uploader.captured.last!.instantEvents?.map(\.insertId), ["start-1"])
    }

    /// A lone instant has no live snapshot to ride: the servlet merges `instant_events` into
    /// `events` when `timeout == 0`, so an empty `events` is legal and needs no Dynamo row.
    func testLoneInstantSendsTimeoutZeroWithEmptyEvents() {
        pipeline.track(started("start-1"), delay: .instant)
        waitForUpload(count: 1)

        let only = uploader.captured[0]
        XCTAssertEqual(only.timeout, 0)
        XCTAssertTrue(only.events.isEmpty)
        XCTAssertEqual(only.instantEvents?.map(\.insertId), ["start-1"])
    }

    // MARK: - finalization

    /// The finalized snapshot rides `instant_events` while the survivor keeps the row alive at
    /// its own TTL. No per-final `timeout: 0` request — that would delete a shared row.
    func testFinalRidesInstantEventsAlongsideLiveSnapshots() {
        pipeline.track(stopped("stop-a"), delay: .delayed(timeout: 3600))
        pipeline.track(stopped("stop-b"), delay: .delayed(timeout: 3600))
        waitForUpload(count: 2)

        pipeline.track(stopped("stop-a"), delay: .instant)
        waitForUpload(count: 3)
        let last = uploader.captured.last!
        XCTAssertEqual(last.timeout, 3_600_000)
        XCTAssertEqual(last.events.map(\.insertId), ["stop-b"])
        XCTAssertEqual(last.instantEvents?.map(\.insertId), ["stop-a"])
    }

    func testRequestTimeoutIsZeroOnlyWhenTheLastSnapshotDrains() {
        pipeline.track(stopped("stop-1"), delay: .delayed(timeout: 3600))
        waitForUpload(count: 1)
        XCTAssertEqual(uploader.captured[0].timeout, 3_600_000)

        pipeline.track(stopped("stop-1"), delay: .instant)
        waitForUpload(count: 2)
        let last = uploader.captured.last!
        XCTAssertEqual(last.timeout, 0)
        XCTAssertTrue(last.events.isEmpty)
        XCTAssertEqual(last.instantEvents?.map(\.insertId), ["stop-1"])
        waitUntil("drained key leaves the file") { store.load()?.states.isEmpty ?? true }
    }

    // MARK: - delay id rotation

    func testFreshDelayIdMintedPerInstanceEvenWithStateOnDisk() {
        pipeline.track(stopped("stop-1"), delay: .delayed(timeout: 3600))
        waitForUpload(count: 1)
        let firstId = uploader.captured[0].id
        XCTAssertNotNil(store.load()?.states[firstId])

        let relaunched = makePipeline()
        XCTAssertNotEqual(relaunched.currentDelayId, firstId)

        relaunched.track(stopped("stop-2"), delay: .delayed(timeout: 3600))
        waitForUpload(count: 2)
        let upsert = request(underId: relaunched.currentDelayId)
        XCTAssertEqual(upsert?.events.map(\.insertId), ["stop-2"])
        XCTAssertEqual(upsert?.timeout, 3_600_000)
    }

    func testCarriedOverKeysFlushUnderTheirOriginalId() {
        pipeline.track(stopped("stale-1", timestamp: nowMs()), delay: .delayed(timeout: 3600))
        waitForUpload(count: 1)
        let originalId = uploader.captured[0].id

        let relaunched = makePipeline()
        relaunched.flushPersistedEntries()
        waitForUpload(count: 2)

        let flush = uploader.captured.last!
        XCTAssertEqual(flush.id, originalId)
        XCTAssertNotEqual(flush.id, relaunched.currentDelayId)
        XCTAssertEqual(flush.timeout, 0)
        XCTAssertTrue(flush.events.isEmpty)
        XCTAssertEqual(flush.instantEvents?.map(\.insertId), ["stale-1"])
        waitUntil("flushed key leaves the file") { store.load()?.states.isEmpty ?? true }
    }

    /// No age-out. An entry carries no acknowledgement state, so age cannot distinguish "the
    /// server already TTL-ingested this" from "this never reached the server at all".
    func testCarriedOverKeyPastItsOwnTimeoutIsStillFlushed() {
        let expired = DelayedState(entries: ["stale-1": DelayedEntry(event: stopped("stale-1"),
                                                                     timeoutMs: 1_000)],
                                   pendingInstantEvents: [started("undelivered-1")])
        store.save(DelayedStore(states: ["d-old": expired]))

        let relaunched = makePipeline()
        relaunched.flushPersistedEntries()
        waitForUpload(count: 1)

        let flushed = uploader.captured[0]
        XCTAssertEqual(flushed.id, "d-old")
        XCTAssertNotEqual(flushed.id, relaunched.currentDelayId)
        XCTAssertEqual(flushed.timeout, 0)
        XCTAssertTrue(flushed.events.isEmpty)
        XCTAssertEqual(flushed.instantEvents?.map(\.insertId), ["undelivered-1", "stale-1"])
        waitUntil("flushed key leaves the file") { store.load()?.states.isEmpty ?? true }
    }

    // MARK: - one in-flight request per delay id

    func testPulseWhileARequestIsInFlightDoesNotSend() {
        uploader.deferCompletion = true
        pipeline.track(stopped("stop-1"), delay: .delayed(timeout: 3600))
        waitForUpload(count: 1)

        pipeline.track(stopped("stop-2"), delay: .delayed(timeout: 3600))
        waitUntil("second snapshot recorded") {
            store.load()?.states[pipeline.currentDelayId]?.entries["stop-2"] != nil
        }
        XCTAssertEqual(uploader.captured.count, 1)
    }

    func testSkippedPulseIsCoalescedOnceTheInFlightRequestCompletes() {
        uploader.deferCompletion = true
        pipeline.track(stopped("stop-1"), delay: .delayed(timeout: 3600))
        waitForUpload(count: 1)

        pipeline.track(stopped("stop-2"), delay: .delayed(timeout: 3600))
        waitUntil("second snapshot recorded") {
            store.load()?.states[pipeline.currentDelayId]?.entries["stop-2"] != nil
        }

        uploader.deferCompletion = false
        uploader.completePending(.success(DelayedResponseBody(id: "d", expiration: nil, flushed: nil)))
        waitForUpload(count: 2)
        XCTAssertEqual(uploader.captured.last!.events.map(\.insertId), ["stop-1", "stop-2"])
    }

    // MARK: - instant durability

    /// A claim is in memory only: the events stay on disk for the whole request, so a process
    /// killed mid-flight leaves them for the next launch.
    func testClaimedInstantsStayPersistedWhileInFlightAndClearOnSuccess() {
        uploader.deferCompletion = true
        pipeline.track(started("start-1"), delay: .instant)
        waitForUpload(count: 1)
        XCTAssertEqual(uploader.captured[0].instantEvents?.map(\.insertId), ["start-1"])

        let inFlight = store.load()?.states[pipeline.currentDelayId]?.pendingInstantEvents
        XCTAssertEqual(inFlight?.map(\.insertId), ["start-1"])

        uploader.deferCompletion = false
        uploader.completePending(.success(DelayedResponseBody(id: "d", expiration: nil, flushed: nil)))
        waitUntil("claimed instants cleared on success") { store.load()?.states.isEmpty ?? true }
    }

    /// The claim covers exactly the prefix that went out, so an instant queued mid-flight is not
    /// swept up by the completing request.
    func testInstantQueuedMidFlightSurvivesTheCompletingRequest() {
        uploader.deferCompletion = true
        pipeline.track(started("start-1"), delay: .instant)
        waitForUpload(count: 1)

        pipeline.track(started("start-2"), delay: .instant)
        waitUntil("second instant queued") {
            store.load()?.states[pipeline.currentDelayId]?.pendingInstantEvents.count == 2
        }

        uploader.deferCompletion = false
        uploader.completePending(.success(DelayedResponseBody(id: "d", expiration: nil, flushed: nil)))
        waitForUpload(count: 2)
        XCTAssertEqual(uploader.captured.last!.instantEvents?.map(\.insertId), ["start-2"])
    }

    // MARK: - in-flight staleness

    /// A `timeout: 0` request deletes the row, but only the row it carried: a snapshot tracked
    /// while it was in flight was never in that body and must survive its completion.
    func testSnapshotTrackedMidFlightSurvivesACompletingFinalRequest() {
        uploader.deferCompletion = true
        pipeline.track(started("start-1"), delay: .instant)
        waitForUpload(count: 1)
        XCTAssertEqual(uploader.captured[0].timeout, 0)

        pipeline.track(stopped("stop-1"), delay: .delayed(timeout: 3600))
        waitUntil("mid-flight snapshot recorded") {
            store.load()?.states[pipeline.currentDelayId]?.entries["stop-1"] != nil
        }

        uploader.deferCompletion = false
        uploader.completePending(.success(DelayedResponseBody(id: "d", expiration: nil, flushed: nil)))
        waitForUpload(count: 2)
        XCTAssertEqual(uploader.captured.last!.events.map(\.insertId), ["stop-1"])
        XCTAssertEqual(uploader.captured.last!.timeout, 3_600_000)
    }

    /// Revision guard proper: the rejected request carries revision N, but the entry has already
    /// moved to N+1, so the 400 drop must leave the fresher snapshot alone.
    func testSnapshotRefreshedMidFlightIsNotDroppedByARejectedRequest() {
        uploader.deferCompletion = true
        pipeline.track(stopped("stop-1"), delay: .delayed(timeout: 3600))
        waitForUpload(count: 1)

        pipeline.track(stopped("stop-1"), delay: .delayed(timeout: 3600))  // bumps the revision
        waitUntil("refresh recorded") {
            (store.load()?.states[pipeline.currentDelayId]?.entries["stop-1"]?.revision ?? 0) > 1
        }

        uploader.deferCompletion = false
        uploader.completeOldestPending(.failure(DelayedEventsError.httpError(code: 400, data: nil)))
        // FIFO barrier: this pulse is queued behind the completion handler, so what it
        // carries is exactly the state that handler left behind.
        pipeline.track(stopped("stop-2"), delay: .delayed(timeout: 3600))
        waitForUpload(count: 2)
        XCTAssertEqual(uploader.captured.last!.events.map(\.insertId), ["stop-1", "stop-2"])
    }

    // MARK: - TTL clamping

    /// Truncating a sub-millisecond TTL to `0` would turn an upsert into the row-delete signal.
    func testSubMillisecondTimeoutClampsToOneMillisecond() {
        pipeline.track(stopped("stop-1"), delay: .delayed(timeout: 0.0004))
        waitForUpload(count: 1)
        XCTAssertEqual(uploader.captured[0].timeout, 1)
    }

    func testTimeoutAboveTwentyFourHoursClampsToTheServerMaximum() {
        pipeline.track(stopped("stop-1"), delay: .delayed(timeout: 172_800))
        waitForUpload(count: 1)
        XCTAssertEqual(uploader.captured[0].timeout, 86_400_000)
    }

    /// `Int64(Double)` traps on a non-finite value, taking the host app with it.
    func testNonFiniteTimeoutFallsBackToTheDefault() {
        pipeline.track(stopped("stop-1"), delay: .delayed(timeout: .infinity))
        pipeline.track(stopped("stop-2"), delay: .delayed(timeout: .nan))
        waitForUpload(count: 2)
        XCTAssertEqual(uploader.captured.last!.timeout, 3_600_000)
    }

    // MARK: - guards

    /// `flush` finalizes everything it touches. On the current key that would delete a row other
    /// players are still holding open, so it refuses instead.
    func testFlushRefusesTheCurrentKeyWhileSnapshotsAreLive() {
        pipeline.track(stopped("stop-1"), delay: .delayed(timeout: 3600))
        waitForUpload(count: 1)

        pipeline.flushForTesting(pipeline.currentDelayId)
        // FIFO barrier: this instant's own pulse is queued behind the refused flush.
        pipeline.track(started("start-1"), delay: .instant)
        waitForUpload(count: 2)

        let last = uploader.captured.last!
        XCTAssertEqual(last.timeout, 3_600_000)
        XCTAssertEqual(last.events.map(\.insertId), ["stop-1"])
        XCTAssertEqual(last.instantEvents?.map(\.insertId), ["start-1"])
        XCTAssertEqual(uploader.captured.count, 2)
    }

    func testOversizedStateRevertsMutation() {
        let bloated = stopped("huge-1")
        bloated.eventProperties = ["padding": String(repeating: "x", count: 50_000)]
        pipeline.track(bloated, delay: .delayed(timeout: 3600))

        // FIFO on the pipeline's serial queue: once this small event has uploaded, the
        // oversized track above has already been processed (and reverted).
        pipeline.track(stopped("small-1"), delay: .delayed(timeout: 3600))
        waitForUpload(count: 1)

        XCTAssertEqual(uploader.captured.count, 1)
        XCTAssertEqual(uploader.captured[0].events.map(\.insertId), ["small-1"])
        XCTAssertNil(store.load()?.states[pipeline.currentDelayId]?.entries["huge-1"])
    }

    func testEventWithoutInsertIdIsDropped() {
        let anonymous = BaseEvent(eventType: "Video Content Stopped")
        pipeline.track(anonymous, delay: .delayed(timeout: 3600))

        pipeline.track(stopped("small-1"), delay: .delayed(timeout: 3600))
        waitForUpload(count: 1)

        XCTAssertEqual(uploader.captured.count, 1)
        XCTAssertEqual(uploader.captured[0].events.map(\.insertId), ["small-1"])
    }

    func testBadRequestDropsEntry() {
        uploader.nextResult = .failure(DelayedEventsError.httpError(code: 400, data: nil))
        pipeline.track(stopped("rejected-1"), delay: .delayed(timeout: 3600))
        waitForUpload(count: 1)
        waitUntil("rejected entry dropped") { store.load()?.states.isEmpty ?? true }

        // The next snapshot must not drag the rejected one along.
        uploader.nextResult = .success(DelayedResponseBody(id: "d", expiration: nil, flushed: nil))
        pipeline.track(stopped("kept-1"), delay: .delayed(timeout: 3600))
        waitForUpload(count: 2)
        XCTAssertEqual(uploader.captured.last!.events.map(\.insertId), ["kept-1"])
    }

    func testServerErrorKeepsEntryForRetry() {
        uploader.nextResult = .failure(DelayedEventsError.httpError(code: 500, data: nil))
        pipeline.track(stopped("retry-1"), delay: .delayed(timeout: 3600))
        waitForUpload(count: 1)

        // Serial queue ordering: the failure has been handled by the time this second
        // track runs, so the next upload proves the entry survived it.
        pipeline.track(stopped("retry-2"), delay: .delayed(timeout: 3600))
        waitForUpload(count: 2)
        XCTAssertEqual(uploader.captured.last!.events.map(\.insertId), ["retry-1", "retry-2"])
        XCTAssertNotNil(store.load()?.states[pipeline.currentDelayId]?.entries["retry-1"])
    }
}
