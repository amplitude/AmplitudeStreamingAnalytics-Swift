import Foundation

/// Thin wrapper around `DispatchSourceTimer` that tracks suspend/resume state.
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

    func resume() {
        stateLock.lock()
        guard isSuspended else {
            stateLock.unlock()
            return
        }
        isSuspended = false
        stateLock.unlock()
        timer.resume()
    }

    func suspend() {
        stateLock.lock()
        guard !isSuspended else {
            stateLock.unlock()
            return
        }
        isSuspended = true
        stateLock.unlock()
        timer.suspend()
    }

    deinit {
        stateLock.lock()
        let wasSuspended = isSuspended
        stateLock.unlock()
        if wasSuspended {
            timer.resume()
        }
        timer.cancel()
    }
}
