import XCTest

@testable import AmplitudeStreamingAnalytics

/// Thread-safe fire counter shared between the timer's dispatch queue and the test thread.
final class PulseTimerFireCounter {
    private let lock = NSLock()
    private var count = 0

    func increment() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }

    func read() -> Int {
        lock.withLock { count }
    }
}

/// Lets a timer's own event handler reach the `PulseTimer` that owns it, which is
/// otherwise impossible because the handler is supplied to `init`. Weak so the
/// handler does not retain the timer.
final class WeakPulseTimerBox {
    weak var timer: PulseTimer?
}

final class PulseTimerTests: XCTestCase {
    func testResumeFiresHandler() {
        let counter = PulseTimerFireCounter()
        let queue = DispatchQueue(label: "com.amplitude.pulseTimerTests.resume")
        let firedExpectation = expectation(description: "handler fires after resume")

        let timer = PulseTimer(interval: 0.05, queue: queue) {
            if counter.increment() == 1 {
                firedExpectation.fulfill()
            }
        }
        timer.resume()

        wait(for: [firedExpectation], timeout: 2)
        XCTAssertGreaterThanOrEqual(counter.read(), 1)
    }

    func testSuspendAfterResumeStopsFurtherFiring() {
        let counter = PulseTimerFireCounter()
        let queue = DispatchQueue(label: "com.amplitude.pulseTimerTests.suspend")
        let firstFireExpectation = expectation(description: "first fire")
        let noSecondFireExpectation = expectation(description: "no fire after suspend")
        noSecondFireExpectation.isInverted = true

        // Suspending from the timer's own queue, inside the handler, is what makes
        // this test deterministic: the serial queue cannot deliver another tick
        // while the handler is still running, so suspend() lands before any second
        // fire. Suspending from the test thread after wait() would race — a loaded
        // runner can let the timer tick again before the test thread wakes up.
        let box = WeakPulseTimerBox()
        let timer = PulseTimer(interval: 0.05, queue: queue) {
            let value = counter.increment()
            if value == 1 {
                box.timer?.suspend()
                firstFireExpectation.fulfill()
            } else if value == 2 {
                // Only the second fire fulfills, so a hypothetical third one cannot
                // trip XCTest's "multiple calls made to fulfill" API violation.
                noSecondFireExpectation.fulfill()
            }
        }
        box.timer = timer
        timer.resume()

        wait(for: [firstFireExpectation], timeout: 2)
        wait(for: [noSecondFireExpectation], timeout: 0.3)
        XCTAssertEqual(counter.read(), 1)
    }

    func testDoubleResumeIsIdempotent() {
        let queue = DispatchQueue(label: "com.amplitude.pulseTimerTests.doubleResume")
        let timer = PulseTimer(interval: 60, queue: queue) {}

        timer.resume()
        timer.resume()

        // The second resume() call must hit the early-return guard rather than
        // resuming an already-resumed DispatchSourceTimer (which would crash).
        XCTAssertTrue(true, "no crash on double resume")
    }

    func testSecondSuspendIsIdempotent() {
        let queue = DispatchQueue(label: "com.amplitude.pulseTimerTests.doubleSuspend")
        let timer = PulseTimer(interval: 60, queue: queue) {}

        timer.resume()
        timer.suspend()
        timer.suspend()

        // The second suspend() call must hit the early-return guard rather than
        // suspending an already-suspended DispatchSourceTimer (which would crash).
        XCTAssertTrue(true, "no crash on double suspend")
    }

    func testSuspendOnNeverResumedTimerIsNoOp() {
        let queue = DispatchQueue(label: "com.amplitude.pulseTimerTests.neverResumedSuspend")
        let timer = PulseTimer(interval: 60, queue: queue) {}

        timer.suspend()

        // suspend() on a timer that started suspended (and was never resumed) must
        // hit the early-return guard rather than suspending an already-suspended timer.
        XCTAssertTrue(true, "no crash suspending a never-resumed timer")
    }

    func testDeinitWhileSuspendedDoesNotCrash() {
        let queue = DispatchQueue(label: "com.amplitude.pulseTimerTests.deinitSuspended")
        var timer: PulseTimer? = PulseTimer(interval: 60, queue: queue) {}

        // Never resumed: still suspended when deallocated. deinit must resume
        // the timer before cancelling it to avoid a crash.
        timer = nil

        XCTAssertNil(timer)
    }

    func testDeinitWhileResumedDoesNotCrash() {
        let queue = DispatchQueue(label: "com.amplitude.pulseTimerTests.deinitResumed")
        var timer: PulseTimer? = PulseTimer(interval: 60, queue: queue) {}

        timer?.resume()

        // Already resumed: deinit must cancel directly without resuming again.
        timer = nil

        XCTAssertNil(timer)
    }
}
