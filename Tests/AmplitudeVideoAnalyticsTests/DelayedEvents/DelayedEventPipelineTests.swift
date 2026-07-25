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
    /// Called after the completion handler returns, so pipeline state is already settled.
    var onUpload: (() -> Void)?

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

    @discardableResult
    func upload(_ body: DelayedRequestBody,
                completion: @escaping (Result<DelayedResponseBody, Error>) -> Void) -> URLSessionDataTask? {
        lock.lock()
        requests.append(body)
        let scripted = result
        lock.unlock()
        completion(scripted)
        onUpload?()
        return nil
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

    private func stopped(_ insertId: String) -> BaseEvent {
        let event = BaseEvent(eventType: "Video Content Stopped")
        event.insertId = insertId
        event.timestamp = 1_752_000_000_000
        return event
    }

    private func started(_ insertId: String) -> BaseEvent {
        let event = BaseEvent(eventType: "Video Content Started")
        event.insertId = insertId
        event.timestamp = 1_752_000_000_000
        return event
    }

    private func waitForUpload(count: Int) {
        let expectation = expectation(description: "upload \(count)")
        expectation.assertForOverFulfill = false
        uploader.onUpload = { [uploader] in
            if uploader?.captured.count ?? 0 >= count { expectation.fulfill() }
        }
        if uploader.captured.count >= count { expectation.fulfill() }
        wait(for: [expectation], timeout: 2)
    }

    /// Upload responses are handled on the pipeline's queue *after* the completion handler
    /// returns, so assertions about persisted state have to wait for that hop.
    private func waitUntil(_ message: String, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(2)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), message)
    }

    // MARK: - upsert + instant pairing

    // Asserts the shape of the delayed upsert itself; the instant tracked first rides
    // its own immediate flush (see testInstantEventsDroppedAfterSuccess).
    func testFirstDelayedTrackSendsUpsertWithInstantEvents() {
        pipeline.track(started("start-1"), delay: DelayConfig(timeout: nil))
        pipeline.track(stopped("stop-1"), delay: DelayConfig(timeout: 3600))
        waitForUpload(count: 2)

        let last = uploader.captured.last!
        XCTAssertEqual(last.timeout, 3_600_000)
        XCTAssertEqual(last.events.map(\.insertId), ["stop-1"])
        XCTAssertEqual(last.apiKey, apiKey)
    }

    func testInstantEventsDroppedAfterSuccess() {
        pipeline.track(started("start-1"), delay: DelayConfig(timeout: nil))
        waitForUpload(count: 1)
        XCTAssertEqual(uploader.captured[0].instantEvents?.map(\.insertId), ["start-1"])

        pipeline.track(stopped("stop-1"), delay: DelayConfig(timeout: 3600))
        waitForUpload(count: 2)
        XCTAssertNil(uploader.captured.last!.instantEvents)
    }

    func testInstantEventsRetainedAfterFailure() {
        uploader.nextResult = .failure(DelayedEventsError.httpError(code: 500, data: nil))
        pipeline.track(started("start-1"), delay: DelayConfig(timeout: nil))
        waitForUpload(count: 1)

        uploader.nextResult = .success(DelayedResponseBody(id: "d", expiration: nil, flushed: nil))
        pipeline.track(stopped("stop-1"), delay: DelayConfig(timeout: 3600))
        waitForUpload(count: 2)
        XCTAssertEqual(uploader.captured.last!.instantEvents?.map(\.insertId), ["start-1"])
    }

    // MARK: - finalization

    func testTimeoutZeroFlushesAndRemovesEntry() {
        pipeline.track(stopped("stop-1"), delay: DelayConfig(timeout: 3600))
        waitForUpload(count: 1)

        pipeline.track(stopped("stop-1"), delay: DelayConfig(timeout: 0))
        waitForUpload(count: 2)
        XCTAssertEqual(uploader.captured.last!.timeout, 0)
        waitUntil("finalized entry removed from disk") { store.load()?.entries.isEmpty ?? true }
    }

    func testFlushPersistedEntriesMarksAllFinal() {
        pipeline.track(stopped("stale-1"), delay: DelayConfig(timeout: 3600))
        waitForUpload(count: 1)

        let relaunched = makePipeline()
        relaunched.flushPersistedEntries()
        waitForUpload(count: 2)
        XCTAssertEqual(uploader.captured.last!.timeout, 0)
        XCTAssertEqual(uploader.captured.last!.events.map(\.insertId), ["stale-1"])
    }

    // MARK: - guards

    func testOversizedStateRevertsMutation() {
        let bloated = stopped("huge-1")
        bloated.eventProperties = ["padding": String(repeating: "x", count: 5000)]
        pipeline.track(bloated, delay: DelayConfig(timeout: 3600))

        // FIFO on the pipeline's serial queue: once this small event has uploaded, the
        // oversized track above has already been processed (and reverted).
        pipeline.track(stopped("small-1"), delay: DelayConfig(timeout: 3600))
        waitForUpload(count: 1)

        XCTAssertEqual(uploader.captured.count, 1)
        XCTAssertEqual(uploader.captured[0].events.map(\.insertId), ["small-1"])
        XCTAssertNil(store.load()?.entries["huge-1"])
    }

    func testEventWithoutInsertIdIsDropped() {
        let anonymous = BaseEvent(eventType: "Video Content Stopped")
        pipeline.track(anonymous, delay: DelayConfig(timeout: 3600))

        pipeline.track(stopped("small-1"), delay: DelayConfig(timeout: 3600))
        waitForUpload(count: 1)

        XCTAssertEqual(uploader.captured.count, 1)
        XCTAssertEqual(uploader.captured[0].events.map(\.insertId), ["small-1"])
    }

    func testBadRequestDropsEntry() {
        uploader.nextResult = .failure(DelayedEventsError.httpError(code: 400, data: nil))
        pipeline.track(stopped("rejected-1"), delay: DelayConfig(timeout: 3600))
        waitForUpload(count: 1)
        waitUntil("rejected entry dropped") { store.load()?.entries.isEmpty ?? true }

        // The next snapshot must not drag the rejected one along.
        uploader.nextResult = .success(DelayedResponseBody(id: "d", expiration: nil, flushed: nil))
        pipeline.track(stopped("kept-1"), delay: DelayConfig(timeout: 3600))
        waitForUpload(count: 2)
        XCTAssertEqual(uploader.captured.last!.events.map(\.insertId), ["kept-1"])
    }

    func testServerErrorKeepsEntryForRetry() {
        uploader.nextResult = .failure(DelayedEventsError.httpError(code: 500, data: nil))
        pipeline.track(stopped("retry-1"), delay: DelayConfig(timeout: 3600))
        waitForUpload(count: 1)

        // Serial queue ordering: the failure has been handled by the time this second
        // track runs, so the next upload proves the entry survived it.
        pipeline.track(stopped("retry-2"), delay: DelayConfig(timeout: 3600))
        waitForUpload(count: 2)
        XCTAssertEqual(uploader.captured.last!.events.map(\.insertId), ["retry-1", "retry-2"])
        XCTAssertNotNil(store.load()?.entries["retry-1"])
    }

    func testDelayConfigCarriesReservedIdAndTimeout() {
        let config = DelayConfig(id: "reserved-1", timeout: 3600)
        XCTAssertEqual(config.id, "reserved-1")
        XCTAssertEqual(config.timeout, 3600)
        XCTAssertNil(DelayConfig(timeout: nil).id)
    }
}
