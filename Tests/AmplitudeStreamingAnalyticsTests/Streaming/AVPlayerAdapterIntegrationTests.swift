import AVFoundation
import CoreVideo
import Foundation
import XCTest

@testable import AmplitudeStreamingAnalytics

// Scope: unlike `AVPlayerAdapterTests` (bare AVPlayer), this drives a REAL `AVPlayer` against a
// REAL, locally-generated H.264 asset to prove the adapter emits `PlayerEvent`s end-to-end.
final class AVPlayerAdapterIntegrationTests: XCTestCase {
    /// 60 frames @ 10fps = 6.0s. Matches the asset generated in `makeSilentVideoAsset()`; long enough to seek
    /// far ahead and still have playback left to observe.
    private static let assetDurationSeconds = 6.0

    /// Generated once for the whole class, not per test: H.264 encoding is software-only and slow
    /// on the simulators CI runs, and every test only ever reads the file. Regenerating it in each
    /// `setUp` multiplied both the runtime and the exposure to encoder stalls by the test count.
    private static var sharedAssetURL: URL?

    private var assetURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        if Self.sharedAssetURL == nil {
            Self.sharedAssetURL = try Self.makeSilentVideoAsset()
        }
        assetURL = Self.sharedAssetURL
    }

    override static func tearDown() {
        if let sharedAssetURL {
            try? FileManager.default.removeItem(at: sharedAssetURL)
        }
        sharedAssetURL = nil
        super.tearDown()
    }

    // MARK: - Tests

    func testDurationReflectsAssetAndCurrentTimeAdvancesDuringPlayback() {
        let player = AVPlayer(url: assetURL)
        let sut = AVPlayerAdapter(player)
        sut.startObserving { _ in }
        addTeardownBlock { sut.stopObserving() }

        waitForItemReady(player)

        guard let duration = sut.playhead().duration else {
            return XCTFail("Expected a non-nil duration for a finite local asset")
        }
        XCTAssertEqual(duration, Self.assetDurationSeconds, accuracy: 0.3)

        let advanced = expectation(description: "currentTime advances during playback")
        var timeObserverToken: Any?
        timeObserverToken = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30),
            queue: .main
        ) { time in
            if time.seconds > 0 {
                advanced.fulfill()
            }
        }
        player.play()
        wait(for: [advanced], timeout: 10)
        if let timeObserverToken {
            player.removeTimeObserver(timeObserverToken)
        }
        player.pause()

        waitForPlayheadPastSUT(sut, threshold: 0, timeout: 2)
    }

    func testPlayedEventFiresOnPlay() {
        let player = AVPlayer(url: assetURL)
        let sut = AVPlayerAdapter(player)
        let played = expectation(description: "played")
        sut.startObserving { if $0 == .played { played.fulfill() } }
        addTeardownBlock { sut.stopObserving() }

        player.play()
        wait(for: [played], timeout: 10)
    }

    func testPausedEventFiresOnPause() {
        let player = AVPlayer(url: assetURL)
        let sut = AVPlayerAdapter(player)
        let played = expectation(description: "played")
        let paused = expectation(description: "paused")
        sut.startObserving { event in
            if event == .played { played.fulfill() }
            if event == .paused { paused.fulfill() }
        }
        addTeardownBlock { sut.stopObserving() }

        player.play()
        wait(for: [played], timeout: 10)
        player.pause()
        wait(for: [paused], timeout: 10)
    }

    func testSeekWhilePlayingYieldsExactlyOneSeeked() {
        let player = AVPlayer(url: assetURL)
        let sut = AVPlayerAdapter(player)
        waitForItemReady(player)

        let seekEvents = EventRecorder()
        let seeked = expectation(description: "seeked")
        sut.startObserving { event in
            if event == .seeking || event == .seeked { seekEvents.record(event) }
            if event == .seeked { seeked.fulfill() }
        }
        addTeardownBlock { sut.stopObserving() }

        player.play()
        seekPrecisely(player, to: 4)

        wait(for: [seeked], timeout: 10)
        // AVPlayer reports only the settle, so the adapter never produces `.seeking`.
        XCTAssertEqual(seekEvents.events, [.seeked])
    }

    /// The reason `AVPlayerItemTimeJumped` is used instead of polling the playhead: a seek this small is
    /// below any practical polling threshold, and polling books it as ordinary watch time.
    func testSeekTooSmallForPollingIsStillReported() {
        let player = AVPlayer(url: assetURL)
        let sut = AVPlayerAdapter(player)
        waitForItemReady(player)

        let seeked = expectation(description: "seeked for a 0.05s seek")
        sut.startObserving { if $0 == .seeked { seeked.fulfill() } }
        addTeardownBlock { sut.stopObserving() }

        player.play()
        waitForPlayhead(player, toReach: 0.5)
        seekPrecisely(player, to: player.currentTime().seconds + 0.05)

        wait(for: [seeked], timeout: 10)
    }

    /// Also unreachable by polling: while paused the playhead never moves, so there is nothing to sample.
    func testSeekWhilePausedIsReported() {
        let player = AVPlayer(url: assetURL)
        let sut = AVPlayerAdapter(player)
        waitForItemReady(player)

        let seeked = expectation(description: "seeked while paused")
        sut.startObserving { if $0 == .seeked { seeked.fulfill() } }
        addTeardownBlock { sut.stopObserving() }

        seekPrecisely(player, to: 3)
        wait(for: [seeked], timeout: 10)
    }

    /// Known and accepted: reaching the end is a time jump too. The SDK reconciles it — `.ended` closes the play
    /// and clears the seek. Asserted so the behaviour is not mistaken for a regression.
    func testReachingTheEndAlsoReportsSeeked() {
        let player = AVPlayer(url: assetURL)
        let sut = AVPlayerAdapter(player)
        waitForItemReady(player)

        // Positioned near the end BEFORE observing, so the only jump the adapter can see is the end itself.
        // Waits on the seek's own completion, not on a periodic observer: the player is paused here, so
        // nothing else guarantees a callback once the seek lands.
        let settled = expectation(description: "seek near the end settled")
        player.seek(to: CMTime(seconds: Self.assetDurationSeconds - 0.5, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { _ in settled.fulfill() }
        wait(for: [settled], timeout: 10)

        let seeked = expectation(description: "seeked at play-to-end")
        seeked.assertForOverFulfill = false
        let ended = expectation(description: "ended")
        ended.assertForOverFulfill = false
        sut.startObserving { event in
            if event == .seeked { seeked.fulfill() }
            if event == .ended { ended.fulfill() }
        }
        addTeardownBlock { sut.stopObserving() }

        player.play()
        wait(for: [seeked, ended], timeout: 15)
    }

    func testPlayAfterPauseYieldsNoSeekEvents() {
        let player = AVPlayer(url: assetURL)
        let sut = AVPlayerAdapter(player)
        waitForItemReady(player)

        let seekEvents = EventRecorder()
        let paused = expectation(description: "paused")
        paused.assertForOverFulfill = false
        sut.startObserving { event in
            if event == .seeking || event == .seeked { seekEvents.record(event) }
            if event == .paused { paused.fulfill() }
        }
        addTeardownBlock { sut.stopObserving() }

        player.play()
        waitForPlayhead(player, toReach: 0.5)
        player.pause()
        player.play()
        waitForPlayhead(player, toReach: 1.0)
        player.pause()
        wait(for: [paused], timeout: 10)

        XCTAssertTrue(seekEvents.events.isEmpty, "resuming after a pause must not look like a seek")
    }

    func testPlayheadPositionAfterSeekIsWithinToleranceOfDestination() {
        let player = AVPlayer(url: assetURL)
        let sut = AVPlayerAdapter(player)
        waitForItemReady(player)

        let seeked = expectation(description: "seeked")
        seeked.assertForOverFulfill = false
        sut.startObserving { if $0 == .seeked { seeked.fulfill() } }
        addTeardownBlock { sut.stopObserving() }

        player.play()
        let target: TimeInterval = 3
        seekPrecisely(player, to: target)

        wait(for: [seeked], timeout: 10)
        XCTAssertEqual(sut.playhead().position, target, accuracy: 0.3)
    }

    func testEndedEventFiresWhenPlaybackCompletes() {
        let player = AVPlayer(url: assetURL)
        let sut = AVPlayerAdapter(player)
        let ended = expectation(description: "ended")
        sut.startObserving { if $0 == .ended { ended.fulfill() } }
        addTeardownBlock { sut.stopObserving() }

        player.play()
        wait(for: [ended], timeout: 15)
    }

    func testErrorEventFiresForInvalidAsset() {
        let invalidURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).mp4")
        let player = AVPlayer(url: invalidURL)
        let sut = AVPlayerAdapter(player)
        let errored = expectation(description: "error")
        sut.startObserving { if case .error = $0 { errored.fulfill() } }
        addTeardownBlock { sut.stopObserving() }

        wait(for: [errored], timeout: 10)
    }

    /// Regression: `.new`-only KVO never fires for an item that reached its terminal `.failed`
    /// state before `startObserving()`, so the error — and the whole view session — was silently
    /// dropped. Observation begins only after the failure has already landed.
    func testErrorEventFiresWhenItemAlreadyFailedBeforeObserving() {
        let invalidURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).mp4")
        let player = AVPlayer(url: invalidURL)

        let failed = expectation(description: "item reached .failed")
        let statusToken = player.currentItem?.observe(\.status, options: [.initial, .new]) { item, _ in
            if item.status == .failed { failed.fulfill() }
        }
        wait(for: [failed], timeout: 10)
        statusToken?.invalidate()

        let sut = AVPlayerAdapter(player)
        let errored = expectation(description: "error")
        sut.startObserving { if case .error = $0 { errored.fulfill() } }
        addTeardownBlock { sut.stopObserving() }

        wait(for: [errored], timeout: 10)
    }

    /// Regression: a player already `.playing` when observation starts emitted no `.played`, so no
    /// view session was ever opened for it.
    func testPlayedEventFiresWhenPlayerAlreadyPlayingBeforeObserving() {
        let player = AVPlayer(url: assetURL)
        waitForItemReady(player)

        let playing = expectation(description: "player reached .playing")
        let statusToken = player.observe(\.timeControlStatus, options: [.initial, .new]) { player, _ in
            if player.timeControlStatus == .playing { playing.fulfill() }
        }
        player.play()
        wait(for: [playing], timeout: 10)
        statusToken.invalidate()

        let sut = AVPlayerAdapter(player)
        let played = expectation(description: "played")
        sut.startObserving { if $0 == .played { played.fulfill() } }
        addTeardownBlock { sut.stopObserving() }

        wait(for: [played], timeout: 10)
    }

    func testPlayheadAfterReleaseKeepsTheLastKnownReading() {
        let released = expectation(description: "released")
        var before: Playhead?
        // Scoped in one pool, like `testReleasingThePlayerEmitsReleased`: draining it at the end is
        // what actually drops the player's last reference and triggers `.released`.
        let sut = autoreleasepool { () -> AVPlayerAdapter in
            var player: AVPlayer? = AVPlayer(url: assetURL)
            let adapter = AVPlayerAdapter(player!)
            adapter.startObserving { if $0 == .released { released.fulfill() } }

            waitForItemReady(player!)
            player!.play()
            waitForPlayheadPastSUT(adapter, threshold: 0.3)
            before = adapter.playhead()

            player = nil
            return adapter
        }

        wait(for: [released], timeout: 10)

        guard let before else {
            return XCTFail("Expected a playhead reading before release")
        }
        XCTAssertGreaterThan(before.position, 0.3)
        XCTAssertNotNil(before.duration)

        let after = sut.playhead()
        XCTAssertEqual(after.position, before.position, accuracy: 0.3)
        XCTAssertEqual(after.duration, before.duration)
        sut.stopObserving()
    }

    // MARK: - Helpers

    /// Zero tolerance, so the destination is exact rather than the nearest sync sample — needed both to make a
    /// jump reliably cross the seek-detection threshold and to assert the settled position afterward.
    private func seekPrecisely(_ player: AVPlayer, to seconds: TimeInterval) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func waitForPlayhead(_ player: AVPlayer, toReach threshold: TimeInterval) {
        let reached = expectation(description: "playhead reached \(threshold)")
        reached.assertForOverFulfill = false
        var token: Any?
        token = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { time in
            if time.seconds >= threshold { reached.fulfill() }
        }
        wait(for: [reached], timeout: 10)
        if let token { player.removeTimeObserver(token) }
    }

    /// Polls from a repeating timer, like `waitForPlayhead`, rather than `Thread.sleep`-ing the test's
    /// main thread: on the simulator, AVPlayer needs its main run loop pumped to actually start playback,
    /// and a busy-wait that never yields to the run loop starves it, so the playhead never moves.
    private func waitForPlayheadPastSUT(_ adapter: AVPlayerAdapter, threshold: TimeInterval, timeout: TimeInterval = 10) {
        let reached = expectation(description: "adapter playhead advanced past \(threshold)")
        reached.assertForOverFulfill = false
        let timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in
            if adapter.playhead().position > threshold { reached.fulfill() }
        }
        wait(for: [reached], timeout: timeout)
        timer.invalidate()
    }

    private func waitForItemReady(_ player: AVPlayer) {
        guard let item = player.currentItem else {
            return XCTFail("Expected a current item")
        }
        let ready = expectation(description: "item ready")
        // `.initial` rather than a `status` read before registering: the item can become ready in
        // the window between the two, and `.readyToPlay` has no later transition to observe, so
        // the check-then-register form waits out the full timeout on an already-ready item.
        let token = item.observe(\.status, options: [.initial, .new]) { item, _ in
            if item.status == .readyToPlay {
                ready.fulfill()
            }
        }
        wait(for: [ready], timeout: 10)
        token.invalidate()
    }

    /// Generates a tiny (~6s, 16x16, H.264) silent local video file for deterministic, no-network
    /// playback in these tests. Runs synchronously in `setUp` via `AVAssetWriter`.
    private static func makeSilentVideoAsset() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        let width = 16
        let height = 16
        let outputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        input.expectsMediaDataInRealTime = false

        let sourcePixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: sourcePixelBufferAttributes
        )
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? IntegrationTestAssetError.writeFailed
        }
        writer.startSession(atSourceTime: .zero)

        let frameCount = 60
        let frameRate: Int32 = 10 // 60 frames @ 10fps == assetDurationSeconds (6.0s)
        for frameNumber in 0..<frameCount {
            // Bounded: an unbounded poll would spin forever if the writer fails, and this runs in
            // setUp rather than under an XCTest expectation, so nothing else would ever time it out.
            let readyDeadline = Date().addingTimeInterval(assetWriteTimeout)
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing else {
                    throw writer.error ?? IntegrationTestAssetError.writeFailed
                }
                guard Date() < readyDeadline else {
                    throw IntegrationTestAssetError.writerInputNeverReady
                }
                Thread.sleep(forTimeInterval: 0.005) // tight readiness poll, not assertion timing
            }
            guard let pool = adaptor.pixelBufferPool else {
                throw IntegrationTestAssetError.noPixelBufferPool
            }
            var pixelBufferOut: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBufferOut)
            guard let pixelBuffer = pixelBufferOut else {
                throw IntegrationTestAssetError.noPixelBuffer
            }
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
                memset(baseAddress, 0, CVPixelBufferGetDataSize(pixelBuffer))
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            let presentationTime = CMTime(value: Int64(frameNumber), timescale: frameRate)
            adaptor.append(pixelBuffer, withPresentationTime: presentationTime)
        }

        input.markAsFinished()
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        // Bounded for the same reason as the readiness poll above: this runs in setUp, outside any
        // XCTest expectation, so an encoder that never invokes the completion handler would hang
        // the whole suite rather than fail it.
        guard finished.wait(timeout: .now() + assetWriteTimeout) == .success else {
            writer.cancelWriting()
            throw IntegrationTestAssetError.writerDidNotFinish
        }

        guard writer.status == .completed else {
            throw writer.error ?? IntegrationTestAssetError.writeFailed
        }
        return url
    }
}

/// Upper bound on how long `makeSilentVideoAsset()` waits on the writer — both for the input to
/// accept data and for `finishWriting` to call back.
///
/// Generous on purpose. This exists to convert a hang into a failure, not to assert performance:
/// the software H.264 encoder on a loaded CI simulator has been seen to stall a single frame for
/// well over 30s. Tightening this trades a real hang guard for flaky failures.
private let assetWriteTimeout: TimeInterval = 180

private enum IntegrationTestAssetError: Error {
    case noPixelBufferPool
    case noPixelBuffer
    case writeFailed
    case writerInputNeverReady
    case writerDidNotFinish
}

/// Events are emitted from the adapter's queue but read back from the test thread.
private final class EventRecorder {
    private let lock = NSLock()
    private var recorded: [PlayerEvent] = []
    func record(_ event: PlayerEvent) { lock.withLock { recorded.append(event) } }
    var events: [PlayerEvent] { lock.withLock { recorded } }
}
