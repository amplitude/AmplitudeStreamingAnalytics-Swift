import XCTest
@testable import AmplitudeVideoAnalytics
import AmplitudeSwift

final class DelayedEventTrackerTests: XCTestCase {
    private var uploader: FakeDelayedEventsUploader!

    override func setUp() {
        super.setUp()
        uploader = FakeDelayedEventsUploader()
        uploader.autoSettle = ok
    }

    /// A successful response, for tests that do not care which one.
    private var ok: Result<DelayedResponseBody, Error> {
        .success(DelayedResponseBody(id: "d", expiration: 1, flushed: nil))
    }

    // MARK: - insert_id

    func testEventWithoutInsertIdIsRejected() {
        let tracker = makeTracker()
        tracker.track(DelayedEvent(wrapping: BaseEvent(eventType: "Content Playing"), kind: .delayed))
        expectNoUpload(beyond: 0)

        tracker.track(makeDelayed("a"))
        waitForUploads(1)
        XCTAssertEqual(uploader.bodies[0].events.compactMap(\.insertId), ["a"])
    }

    // MARK: - track

    func testTrackDelayedSendsEntireCollection() {
        let tracker = makeTracker()
        tracker.track(makeDelayed("a"))
        waitForUploads(1)
        tracker.track(makeDelayed("b"))
        waitForUploads(2)

        XCTAssertEqual(uploader.bodies[0].events.compactMap(\.insertId), ["a"])
        XCTAssertEqual(uploader.bodies[1].events.compactMap(\.insertId), ["a", "b"])
        XCTAssertEqual(uploader.bodies[0].id, uploader.bodies[1].id)
    }

    func testTrackAndTrackDelayedCoalesceIntoOneUpload() {
        let tracker = makeTracker(delayTimeoutMs: 1_234)
        // An in-flight request holds both tracks below until they can share one.
        uploader.autoSettle = nil
        tracker.track(makeDelayed("warmup"))
        waitForUploads(1)

        tracker.track(makeInstant("start"))
        tracker.track(makeDelayed("stop"))
        uploader.settle(at: 0, with: ok)

        waitForUploads(2)
        withExtendedLifetime(tracker) { expectNoUpload(beyond: 2) }
        XCTAssertEqual(uploader.bodies[1].instantEvents?.compactMap(\.insertId), ["start"])
        XCTAssertEqual(uploader.bodies[1].events.compactMap(\.insertId), ["warmup", "stop"])
        XCTAssertEqual(uploader.bodies[1].timeout, 1_234)
    }

    /// A refresh replaces the entry without sending, so it surfaces on the next request out.
    func testReTrackingSameInsertIdReplacesInPlace() {
        let tracker = makeTracker()
        tracker.track(makeDelayed("a", type: "First"))
        waitForUploads(1)
        tracker.track(makeDelayed("a", type: "Second"))
        expectNoUpload(beyond: 1)

        tracker.track(makeDelayed("b"))
        waitForUploads(2)

        let events = uploader.bodies[1].events
        XCTAssertEqual(events.compactMap(\.insertId), ["a", "b"], "replaced in place, not appended")
        XCTAssertEqual(events.first?.eventType, "Second")
    }

    func testTimeoutIsDelayTimeoutWhenDelayedEntriesPresentAndZeroForInstantsOnly() {
        let tracker = makeTracker(delayTimeoutMs: 1_234)
        tracker.track(makeInstant("i"))
        waitForUploads(1)
        XCTAssertEqual(uploader.bodies[0].timeout, 0)
        XCTAssertTrue(uploader.bodies[0].events.isEmpty)
        XCTAssertEqual(uploader.bodies[0].instantEvents?.compactMap(\.insertId), ["i"])

        tracker.track(makeDelayed("d"))
        waitForUploads(2)
        XCTAssertEqual(uploader.bodies[1].timeout, 1_234)
        XCTAssertEqual(uploader.bodies[1].events.compactMap(\.insertId), ["d"])
        // "i" settled with the first request, so it is not carried a second time.
        XCTAssertNil(uploader.bodies[1].instantEvents)
    }

    // MARK: - instant events

    func testInstantEventIsDroppedAfterSuccess() {
        assertInstantDropped(settlingWith: .success(DelayedResponseBody(id: "d", expiration: nil, flushed: true)))
    }

    func testInstantEventIsDroppedAfterFailure() {
        assertInstantDropped(settlingWith: .failure(DelayedEventsError.invalidResponse))
    }

    private func assertInstantDropped(settlingWith result: Result<DelayedResponseBody, Error>) {
        uploader.autoSettle = result
        let tracker = makeTracker()
        tracker.track(makeInstant("i"))
        waitForUploads(1)

        tracker.track(makeDelayed("d"))
        waitForUploads(2)
        XCTAssertNil(uploader.bodies[1].instantEvents)
        XCTAssertEqual(uploader.bodies[1].events.compactMap(\.insertId), ["d"])
    }

    func testDelayedEventSurvivesSuccessAndIsResentOnNextPulse() {
        let tracker = makeTracker(pulseInterval: 0.05)
        tracker.track(makeDelayed("d"))
        waitForUploads(1)

        withExtendedLifetime(tracker) { waitForUploads(2) }
        XCTAssertEqual(uploader.bodies[1].events.compactMap(\.insertId), ["d"])
    }

    // MARK: - size limit

    func testSizeLimitRejectsOffendingEventAndKeepsPriorState() {
        let tracker = makeTracker()
        tracker.track(makeDelayed("a"))
        waitForUploads(1)

        tracker.track(makeDelayed("big", type: oversizedEventType))
        expectNoUpload(beyond: 1)

        tracker.track(makeDelayed("c"))
        waitForUploads(2)
        XCTAssertEqual(uploader.bodies[1].events.compactMap(\.insertId), ["a", "c"])
    }

    /// Deliberate divergence from the browser, which drops the entry here. A refresh that cannot
    /// be admitted must not cost us the live snapshot the server is already holding.
    func testOversizedRefreshKeepsTheLiveEntry() {
        let tracker = makeTracker()
        tracker.track(makeDelayed("a", type: "First"))
        waitForUploads(1)
        tracker.track(makeDelayed("b"))
        waitForUploads(2)

        tracker.track(makeDelayed("a", type: oversizedEventType))
        expectNoUpload(beyond: 2)

        tracker.track(makeDelayed("c"))
        waitForUploads(3)
        XCTAssertEqual(uploader.bodies[2].events.compactMap(\.insertId), ["a", "b", "c"])
        XCTAssertEqual(uploader.bodies[2].events[0].eventType, "First", "the admitted version survives")
    }

    func testSizeLimitRejectsEventThatOverflowsAccumulatedSet() {
        let tracker = makeTracker()
        let filler = String(repeating: "x", count: 8_000)
        for (index, id) in ["a", "b", "c", "d"].enumerated() {
            tracker.track(makeDelayed(id, type: filler))
            waitForUploads(index + 1)
        }

        tracker.track(makeDelayed("e", type: filler))
        expectNoUpload(beyond: 4)

        tracker.track(makeDelayed("f"))
        waitForUploads(5)
        XCTAssertEqual(uploader.bodies[4].events.compactMap(\.insertId), ["a", "b", "c", "d", "f"])
    }

    func testConfiguredSizeLimitReplacesTheDefaultOne() {
        let tracker = makeTracker(eventsSizeLimit: 2_000)
        tracker.track(makeDelayed("a"))
        waitForUploads(1)

        // Well under the 40 kB default, over the limit this tracker was given.
        tracker.track(makeDelayed("b", type: String(repeating: "x", count: 3_000)))
        expectNoUpload(beyond: 1)
    }

    func testUnencodableEventIsRejectedAndKeepsPriorState() {
        let tracker = makeTracker()
        tracker.track(makeDelayed("a"))
        waitForUploads(1)

        let bad = makeEvent("bad")
        bad.eventProperties = ["duration": Double.nan]
        tracker.track(DelayedEvent(wrapping: bad, kind: .delayed))
        expectNoUpload(beyond: 1)

        tracker.track(makeDelayed("c"))
        waitForUploads(2)
        XCTAssertEqual(uploader.bodies[1].events.compactMap(\.insertId), ["a", "c"])
    }

    // MARK: - refreshing an entry

    /// A known insert_id is a refresh, not a new event: it replaces the entry and waits for the
    /// pulse, because refreshes arrive far faster than the pulse does.
    func testRefreshDoesNotTriggerUpload() {
        let tracker = makeTracker()
        tracker.track(makeDelayed("a", type: "First"))
        waitForUploads(1)

        tracker.track(makeDelayed("a", type: "Second"))
        expectNoUpload(beyond: 1)
    }

    func testUnknownInsertIdIsANewEntryAndSends() {
        let tracker = makeTracker()
        tracker.track(makeDelayed("a"))
        waitForUploads(1)

        tracker.track(makeDelayed("b"))
        waitForUploads(2)
        XCTAssertEqual(uploader.bodies[1].events.compactMap(\.insertId), ["a", "b"])
    }

    /// An instant always sends, even for an id already live — that is how an entry is finalized.
    func testInstantForALiveEntrySendsImmediately() {
        let tracker = makeTracker()
        tracker.track(makeDelayed("a"))
        waitForUploads(1)

        tracker.track(makeInstant("a"))
        waitForUploads(2)
        XCTAssertEqual(uploader.bodies[1].instantEvents?.compactMap(\.insertId), ["a"])
    }

    func testUpdatedPropertiesAppearOnNextPulse() {
        let tracker = makeTracker(pulseInterval: 0.05)
        tracker.track(makeDelayed("a", type: "First"))
        waitForUploads(1)
        tracker.track(makeDelayed("a", type: "Second"))

        withExtendedLifetime(tracker) {
            waitForUpload { body in
                body.events.compactMap(\.insertId) == ["a"] && body.events.map(\.eventType) == ["Second"]
            }
        }
    }

    func testRefreshKeepsPreviousEventOnOverflow() {
        let tracker = makeTracker()
        tracker.track(makeDelayed("a", type: "First"))
        waitForUploads(1)

        tracker.track(makeDelayed("a", type: oversizedEventType))
        expectNoUpload(beyond: 1)

        tracker.track(makeDelayed("b"))
        waitForUploads(2)
        XCTAssertEqual(uploader.bodies[1].events.map(\.eventType), ["First", "Content Playing"])
    }

    // MARK: - flush

    func testFlushSendsWholeSetWithZeroTimeoutAndDropsItOnSuccess() {
        assertFlushDropsEntries(settlingWith: .success(DelayedResponseBody(id: "d", expiration: nil, flushed: true)))
    }

    func testFlushDropsEntriesOnFailureToo() {
        assertFlushDropsEntries(settlingWith: .failure(DelayedEventsError.invalidResponse))
    }

    private func assertFlushDropsEntries(settlingWith result: Result<DelayedResponseBody, Error>) {
        uploader.autoSettle = result
        let tracker = makeTracker(delayTimeoutMs: 1_234)
        tracker.track(makeDelayed("a"))
        waitForUploads(1)
        tracker.track(makeDelayed("b"))
        waitForUploads(2)

        tracker.flush()
        waitForUploads(3)
        XCTAssertEqual(uploader.bodies[2].timeout, 0)
        XCTAssertEqual(uploader.bodies[2].events.compactMap(\.insertId), ["a", "b"])

        tracker.track(makeDelayed("c"))
        waitForUploads(4)
        XCTAssertEqual(uploader.bodies[3].events.compactMap(\.insertId), ["c"])
        XCTAssertEqual(uploader.bodies[3].id, uploader.bodies[2].id)
    }

    func testFlushKeepsEntriesUntilTheRequestSettles() {
        uploader.autoSettle = nil
        let tracker = makeTracker()
        tracker.track(makeDelayed("a"))
        waitForUploads(1)
        uploader.settle(at: 0, with: ok)

        tracker.flush()
        waitForUploads(2)
        // Held rather than sent beside the flush; it rides the request issued once that settles.
        tracker.track(makeDelayed("b"))
        withExtendedLifetime(tracker) { expectNoUpload(beyond: 2) }

        uploader.settle(at: 1, with: ok)
        waitForUploads(3)
        // "a" left with the flush; only "b" is still live.
        XCTAssertEqual(uploader.bodies[2].events.compactMap(\.insertId), ["b"])
    }

    func testFlushSuspendsPulseWhileTheRequestIsInFlight() {
        uploader.autoSettle = nil
        let tracker = makeTracker(pulseInterval: 0.05)
        tracker.track(makeDelayed("a"))
        waitForUploads(1)
        uploader.settle(at: 0, with: ok)

        tracker.flush()
        waitForUploads(2)
        // The flush is never settled, so "a" is still local; a live pulse
        // would re-upsert the row the server already ingested and deleted.
        withExtendedLifetime(tracker) { expectNoUpload(beyond: 2, timeout: 0.3) }
    }

    func testUpdateDuringInFlightFlushDoesNotResumeThePulse() {
        uploader.autoSettle = nil
        let tracker = makeTracker(pulseInterval: 0.05)
        tracker.track(makeDelayed("a", type: "First"))
        waitForUploads(1)
        uploader.settle(at: 0, with: ok)

        tracker.flush()
        waitForUploads(2)
        // The flush is never settled, so "a" is still local; an update on it must not
        // restart the pulse the flush suspended, or it would re-upsert the deleted row.
        tracker.track(makeDelayed("a", type: "Second"))
        withExtendedLifetime(tracker) { expectNoUpload(beyond: 2, timeout: 0.3) }
    }

    func testFlushOnEmptySetDoesNotFinalizeALaterEvent() {
        let tracker = makeTracker(delayTimeoutMs: 1_234)
        tracker.flush()
        expectNoUpload(beyond: 0)

        tracker.track(makeDelayed("a"))
        waitForUploads(1)
        XCTAssertEqual(uploader.bodies[0].timeout, 1_234)
        XCTAssertEqual(uploader.bodies[0].events.compactMap(\.insertId), ["a"])
    }

    func testDeferredFlushIsDroppedWhenTheEarlierOneDrainsEverything() {
        uploader.autoSettle = nil
        let tracker = makeTracker(delayTimeoutMs: 1_234)
        tracker.track(makeDelayed("a"))
        waitForUploads(1)
        uploader.settle(at: 0, with: ok)

        tracker.flush()
        waitForUploads(2)
        tracker.flush()
        uploader.settle(at: 1, with: ok)

        tracker.track(makeDelayed("b"))
        waitForUploads(3)
        XCTAssertEqual(uploader.bodies[2].timeout, 1_234)
        XCTAssertEqual(uploader.bodies[2].events.compactMap(\.insertId), ["b"])
    }

    func testFlushOnEmptySetSendsNothing() {
        let tracker = makeTracker()
        tracker.flush()
        expectNoUpload(beyond: 0)
    }

    // MARK: - request serialization

    func testSendWaitsForTheInFlightRequestAndCoalesces() {
        uploader.autoSettle = nil
        let tracker = makeTracker()
        tracker.track(makeDelayed("a"))
        waitForUploads(1)

        // A second request racing this one could land first and restore stale state.
        tracker.track(makeDelayed("b"))
        tracker.track(makeDelayed("c"))
        withExtendedLifetime(tracker) { expectNoUpload(beyond: 1) }

        uploader.settle(at: 0, with: ok)
        waitForUploads(2)
        withExtendedLifetime(tracker) { expectNoUpload(beyond: 2) }
        XCTAssertEqual(uploader.bodies[1].events.compactMap(\.insertId), ["a", "b", "c"])
    }

    func testFlushIsSentOnlyAfterTheInFlightRequestSettles() {
        uploader.autoSettle = nil
        let tracker = makeTracker(delayTimeoutMs: 1_234)
        tracker.track(makeDelayed("a"))
        waitForUploads(1)

        // A slower request landing after the flush would recreate the row it had deleted.
        tracker.flush()
        withExtendedLifetime(tracker) { expectNoUpload(beyond: 1) }

        uploader.settle(at: 0, with: ok)
        waitForUploads(2)
        XCTAssertEqual(uploader.bodies[1].timeout, 0)
        XCTAssertEqual(uploader.bodies[1].events.compactMap(\.insertId), ["a"])
    }

    func testUpdateDuringAnInFlightRequestRidesTheOwedSend() {
        uploader.autoSettle = nil
        let tracker = makeTracker()
        tracker.track(makeDelayed("a", type: "First"))
        waitForUploads(1)

        tracker.track(makeDelayed("b"))       // owes a send, held by the gate
        tracker.track(makeDelayed("a", type: "Second"))

        uploader.settle(at: 0, with: ok)
        waitForUploads(2)
        XCTAssertEqual(uploader.bodies[1].events.map(\.eventType), ["Second", "Content Playing"])
    }

    // MARK: - discard / empty state

    func testDiscardClearsStateAndSendsNothing() {
        let tracker = makeTracker()
        tracker.track(makeDelayed("a"))
        waitForUploads(1)

        tracker.discard()
        expectNoUpload(beyond: 1)

        tracker.track(makeDelayed("b"))
        waitForUploads(2)
        XCTAssertEqual(uploader.bodies[1].events.compactMap(\.insertId), ["b"])
    }

    func testDiscardRotatesDelayIdSoTheAbandonedRowIsLeftAlone() {
        let tracker = makeTracker()
        tracker.track(makeDelayed("a"))
        waitForUploads(1)

        tracker.discard()
        tracker.track(makeDelayed("b"))
        waitForUploads(2)
        XCTAssertNotEqual(uploader.bodies[0].id, uploader.bodies[1].id)
    }

    func testEmptyCollectionNeverSends() {
        let tracker = makeTracker(pulseInterval: 0.02)
        withExtendedLifetime(tracker) {
            expectNoUpload(beyond: 0, timeout: 0.3)
        }
    }

    // MARK: - routing by the event's own kind

    func testDelayedEventRoutesToTheLaneItsKindNames() {
        let tracker = makeTracker()
        tracker.track(DelayedEvent(wrapping: makeEvent("a"), kind: .delayed))
        waitForUploads(1)
        XCTAssertEqual(uploader.bodies[0].events.compactMap(\.insertId), ["a"])
        XCTAssertNil(uploader.bodies[0].instantEvents)

        tracker.track(DelayedEvent(wrapping: makeEvent("b"), kind: .instant))
        waitForUploads(2)
        XCTAssertEqual(uploader.bodies[1].instantEvents?.compactMap(\.insertId), ["b"])
    }

    // MARK: - helpers

    private var oversizedEventType: String {
        String(repeating: "x", count: 45_000)
    }

    private func makeTracker(pulseInterval: TimeInterval = 60,
                             delayTimeoutMs: Int64 = 3_600_000,
                             eventsSizeLimit: Int = 40_000) -> DelayedEventTracker {
        DelayedEventTracker(amplitudeConfiguration: Configuration(apiKey: "test-key"),
                            configuration: DelayedEventsConfiguration(pulseInterval: pulseInterval,
                                                                      delayTimeoutMs: delayTimeoutMs,
                                                                      eventsSizeLimit: eventsSizeLimit),
                            httpClient: uploader)
    }

    private func makeDelayed(_ insertId: String, type: String = "Content Playing") -> DelayedEvent {
        DelayedEvent(wrapping: makeEvent(insertId, type: type), kind: .delayed)
    }

    private func makeInstant(_ insertId: String, type: String = "Content Playing") -> DelayedEvent {
        DelayedEvent(wrapping: makeEvent(insertId, type: type), kind: .instant)
    }

    private func makeEvent(_ insertId: String, type: String = "Content Playing") -> BaseEvent {
        let event = BaseEvent(eventType: type)
        event.insertId = insertId
        return event
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

// MARK: - Fake uploader

/// Records request bodies and hands the test control over when each upload settles.
final class FakeDelayedEventsUploader: DelayedEventsUploading {
    typealias Completion = (Result<DelayedResponseBody, Error>) -> Void

    private let lock = NSLock()
    private var recorded: [(body: DelayedRequestBody, completion: Completion)] = []
    private var pending: (count: Int, notify: () -> Void)?
    private var pendingPredicate: (matches: (DelayedRequestBody) -> Bool, notify: () -> Void)?

    /// Settles each upload as it is issued. The tracker sends one request at a time, so tests
    /// that want one left in flight clear this and drive `settle(at:)` themselves.
    var autoSettle: Result<DelayedResponseBody, Error>?

    var bodies: [DelayedRequestBody] { lock.withLock { recorded.map(\.body) } }

    /// Fires `notify` once `count` uploads have been recorded, counting uploads that
    /// already landed — so installing it cannot race with the tracker's queue.
    func whenUploadCountReaches(_ count: Int, notify: @escaping () -> Void) {
        let reached: Bool = lock.withLock {
            guard recorded.count < count else { return true }
            pending = (count, notify)
            return false
        }
        if reached { notify() }
    }

    /// Fires `notify` on the first upload whose body matches `predicate`, evaluating bodies
    /// already recorded under the same lock — so installing it cannot race.
    func whenUploadArrives(matching predicate: @escaping (DelayedRequestBody) -> Bool,
                           notify: @escaping () -> Void) {
        let matched: Bool = lock.withLock {
            guard !recorded.contains(where: { predicate($0.body) }) else { return true }
            pendingPredicate = (predicate, notify)
            return false
        }
        if matched { notify() }
    }

    func settle(at index: Int, with result: Result<DelayedResponseBody, Error>) {
        let completion = lock.withLock { recorded[index].completion }
        completion(result)
    }

    @discardableResult
    func upload(_ body: DelayedRequestBody, completion: @escaping Completion) -> URLSessionDataTask? {
        let (notifications, settleWith): ([() -> Void], Result<DelayedResponseBody, Error>?) = lock.withLock {
            recorded.append((body, completion))
            var fired: [() -> Void] = []
            if let pending, recorded.count >= pending.count {
                self.pending = nil
                fired.append(pending.notify)
            }
            if let pendingPredicate, pendingPredicate.matches(body) {
                self.pendingPredicate = nil
                fired.append(pendingPredicate.notify)
            }
            return (fired, autoSettle)
        }
        notifications.forEach { $0() }
        // The tracker sets its in-flight flag before calling us, so settling here (on its queue)
        // just enqueues the completion hop — it cannot re-enter `send` underneath itself.
        if let settleWith { completion(settleWith) }
        return nil
    }
}
