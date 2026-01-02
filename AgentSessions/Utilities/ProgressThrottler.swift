import Dispatch

/// Coalesces high-frequency progress updates into a lower-frequency "flush" signal.
final class ProgressThrottler {
    private var lastFlush = DispatchTime.now()
    private var pendingTicks = 0
    private let intervalNanoseconds: UInt64
    private let flushEveryTicks: Int

    init(intervalMs: Int = 100, flushEveryTicks: Int = 50) {
        intervalNanoseconds = UInt64(intervalMs) * 1_000_000
        self.flushEveryTicks = flushEveryTicks
    }

    func incrementAndShouldFlush() -> Bool {
        pendingTicks += 1
        let now = DispatchTime.now()
        if now.uptimeNanoseconds - lastFlush.uptimeNanoseconds > intervalNanoseconds {
            lastFlush = now
            pendingTicks = 0
            return true
        }
        if pendingTicks >= flushEveryTicks {
            pendingTicks = 0
            return true
        }
        return false
    }
}

