import AVFoundation
import CoreVideo
import Foundation
import XCTest

@testable import AmplitudeVideoAnalytics

// Scope: unlike `AVPlayerAdapterTests` (bare AVPlayer), this drives a REAL `AVPlayer` against a
// REAL, locally-generated H.264 asset to prove the adapter emits `PlayerEvent`s end-to-end.
final class AVPlayerAdapterIntegrationTests: XCTestCase {
    /// 10 frames @ 10fps = 1.0s. Matches the asset generated in `makeSilentVideoAsset()`.
    private static let assetDurationSeconds = 1.0

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
        sut.startObserving()
        addTeardownBlock { sut.stopObserving() }

        waitForItemReady(player)

        guard let duration = sut.sample()?.duration else {
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

        XCTAssertGreaterThan(sut.sample()?.position ?? 0, 0)
    }

    func testPlayedEventFiresOnPlay() {
        let player = AVPlayer(url: assetURL)
        let sut = AVPlayerAdapter(player)
        let played = expectation(description: "played")
        sut.onEvent = { if $0 == .played { played.fulfill() } }
        sut.startObserving()
        addTeardownBlock { sut.stopObserving() }

        player.play()
        wait(for: [played], timeout: 10)
    }

    func testPausedEventFiresOnPause() {
        let player = AVPlayer(url: assetURL)
        let sut = AVPlayerAdapter(player)
        let played = expectation(description: "played")
        let paused = expectation(description: "paused")
        sut.onEvent = { event in
            if event == .played { played.fulfill() }
            if event == .paused { paused.fulfill() }
        }
        sut.startObserving()
        addTeardownBlock { sut.stopObserving() }

        player.play()
        wait(for: [played], timeout: 10)
        player.pause()
        wait(for: [paused], timeout: 10)
    }

    func testSeekingEventFiresOnSeek() {
        let player = AVPlayer(url: assetURL)
        let sut = AVPlayerAdapter(player)
        sut.startObserving()
        addTeardownBlock { sut.stopObserving() }

        waitForItemReady(player)

        let seeking = expectation(description: "seeking")
        sut.onEvent = { if $0 == .seeking { seeking.fulfill() } }

        let seekCompleted = expectation(description: "seek completed")
        player.seek(to: CMTime(value: 5, timescale: 10)) { _ in seekCompleted.fulfill() }

        wait(for: [seeking, seekCompleted], timeout: 10)
    }

    func testEndedEventFiresWhenPlaybackCompletes() {
        let player = AVPlayer(url: assetURL)
        let sut = AVPlayerAdapter(player)
        let ended = expectation(description: "ended")
        sut.onEvent = { if $0 == .ended { ended.fulfill() } }
        sut.startObserving()
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
        sut.onEvent = { if case .error = $0 { errored.fulfill() } }
        sut.startObserving()
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
        sut.onEvent = { if case .error = $0 { errored.fulfill() } }
        sut.startObserving()
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
        sut.onEvent = { if $0 == .played { played.fulfill() } }
        sut.startObserving()
        addTeardownBlock { sut.stopObserving() }

        wait(for: [played], timeout: 10)
    }

    // MARK: - Helpers

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

    /// Generates a tiny (~1s, 16x16, H.264) silent local video file for deterministic, no-network
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

        let frameCount = 10
        let frameRate: Int32 = 10 // 10 frames @ 10fps == assetDurationSeconds (1.0s)
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
