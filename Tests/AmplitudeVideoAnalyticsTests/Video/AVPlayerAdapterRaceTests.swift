import AVFoundation
import CoreVideo
import XCTest

@testable import AmplitudeVideoAnalytics

/// Regression guard for the `onEvent` data race: AVFoundation delivers events on its own threads while the SDK
/// tears observation down on its queue. Both touch `onEvent`, so the read has to be synchronised — without it
/// the reader can retain a closure the writer has already released, which corrupts the heap rather than
/// failing cleanly. Passing means "did not crash"; there is nothing else to assert.
final class AVPlayerAdapterRaceTests: XCTestCase {
    private static var sharedAssetURL: URL?
    private var assetURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        if Self.sharedAssetURL == nil { Self.sharedAssetURL = try Self.makeAsset() }
        assetURL = Self.sharedAssetURL
    }

    override static func tearDown() {
        if let sharedAssetURL { try? FileManager.default.removeItem(at: sharedAssetURL) }
        sharedAssetURL = nil
        super.tearDown()
    }

    func testEventsDeliveredWhileObservationIsTornDownDoNotCrash() throws {
        let player = AVPlayer(url: assetURL)
        let sut = AVPlayerAdapter(player)
        guard let item = player.currentItem else { return XCTFail("expected an item") }

        let deadline = Date().addingTimeInterval(1.5)
        let finished = expectation(description: "all threads done")
        finished.expectedFulfillmentCount = 5

        // One thread stands in for the SDK's queue, which is the only caller of start/stopObserving.
        // Each attach passes a FRESH closure over a FRESH object: the race needs the previous closure's
        // last reference to actually drop, and a reused closure would keep its box alive forever.
        DispatchQueue.global().async {
            while Date() < deadline {
                let box = NSObject()
                sut.startObserving { _ in _ = box }
                sut.stopObserving()
            }
            finished.fulfill()
        }

        // AVFoundation's threads: posting the real notification drives the adapter's real observer.
        for _ in 0..<4 {
            DispatchQueue.global().async {
                while Date() < deadline {
                    for _ in 0..<50 {
                        NotificationCenter.default.post(name: .AVPlayerItemTimeJumped, object: item)
                    }
                }
                finished.fulfill()
            }
        }

        wait(for: [finished], timeout: 30)
        sut.stopObserving()
        withExtendedLifetime(player) {}
    }

    private static func makeAsset() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 16, AVVideoHeightKey: 16
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 16, kCVPixelBufferHeightKey as String: 16
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? NSError(domain: "race", code: 1) }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<20 {
            let ready = Date().addingTimeInterval(60)
            while !input.isReadyForMoreMediaData {
                guard Date() < ready else { throw NSError(domain: "race", code: 2) }
                Thread.sleep(forTimeInterval: 0.005)
            }
            guard let pool = adaptor.pixelBufferPool else { throw NSError(domain: "race", code: 3) }
            var out: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
            guard let buffer = out else { throw NSError(domain: "race", code: 4) }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                memset(base, Int32(frame), CVPixelBufferGetDataSize(buffer))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 10))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        guard done.wait(timeout: .now() + 120) == .success, writer.status == .completed else {
            throw writer.error ?? NSError(domain: "race", code: 5)
        }
        return url
    }
}
