import Foundation

/// Thin wrapper around `DispatchSourceTimer` that tracks suspend/resume state.
///
/// Starts suspended: `resume()` to start ticking, `suspend()` to pause, release
/// to stop for good. Both are idempotent and safe to call from any thread.
///
/// `DispatchSourceTimer` crashes if it is deallocated while suspended, so this
/// type resumes any suspended timer before cancelling it in `deinit`.
final class PulseTimer {
    private let timer: DispatchSourceTimer
    private let stateLock = NSLock()
    private var isSuspended = true

    init(interval: TimeInterval, queue: DispatchQueue, handler: @escaping () -> Void) {
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler(handler: handler)
    }

    // The lock is held across the `timer` call, not just the flag mutation, so
    // the flag and the underlying suspend/resume stay atomic as a unit.
    // Releasing early would let a concurrent resume/suspend reorder the actual
    // dispatch calls relative to the flag, breaking the suspend/resume balance
    // (`DispatchSourceTimer` crashes on over-resume and cannot be deallocated
    // while suspended). `resume`/`suspend` do not synchronously re-enter this
    // type, so holding the lock across them cannot deadlock.
    func resume() {
        stateLock.withLock {
            guard isSuspended else { return }
            isSuspended = false
            timer.resume()
        }
    }

    func suspend() {
        stateLock.withLock {
            guard !isSuspended else { return }
            isSuspended = true
            timer.suspend()
        }
    }

    deinit {
        let wasSuspended = stateLock.withLock { isSuspended }
        if wasSuspended {
            timer.resume()
        }
        timer.cancel()
    }
}
