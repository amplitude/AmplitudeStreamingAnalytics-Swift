import XCTest
@testable import AmplitudeStreamingAnalytics
import AmplitudeSwift

extension XCTestCase {
    /// A snapshot file of this test's own, removed when it ends: a file another test left behind
    /// would be loaded as carried-over work and sent before this one tracked anything.
    func makeSnapshotStore() -> DelayedSnapshotStore {
        let snapshots = DelayedSnapshotStore(apiKey: "test-\(UUID().uuidString)", instanceName: "i")
        addTeardownBlock { snapshots.clear() }
        return snapshots
    }
}

/// Records request bodies and hands the test control over when each upload settles.
final class FakeDelayedEventsUploader: DelayedEventsUploading {
    typealias Completion = (Result<DelayedResponseBody, Error>) -> Void

    private let lock = NSLock()
    private var recorded: [(body: DelayedRequestBody, completion: Completion)] = []
    private var pending: (count: Int, notify: () -> Void)?
    private var pendingPredicate: (matches: (DelayedRequestBody) -> Bool, notify: () -> Void)?

    /// Settles each upload as it is issued. The tracker sends one request at a time per delay id,
    /// so tests that want one left in flight clear this and drive `settle(at:)` themselves.
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

    /// A no-op when that upload never happened, so a test that has already failed a wait reports
    /// its own assertion rather than trapping and taking the rest of the run down with it.
    func settle(at index: Int, with result: Result<DelayedResponseBody, Error>) {
        let completion = lock.withLock { recorded.indices.contains(index) ? recorded[index].completion : nil }
        completion?(result)
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
        // The tracker marks the id in flight before calling us, so settling here (on its queue)
        // just enqueues the completion hop — it cannot re-enter `send` underneath itself.
        if let settleWith { completion(settleWith) }
        return nil
    }
}
