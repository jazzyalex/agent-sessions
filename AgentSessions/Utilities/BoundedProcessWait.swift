import Foundation

extension Process {
    /// Waits for the process to exit within `timeout` seconds.
    /// If still running after the deadline, sends SIGTERM,
    /// waits a 0.5 s grace period, then SIGKILL.
    /// Returns `true` if the process exited on its own, `false` if it was killed.
    @discardableResult
    func waitForExit(timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard isRunning else { return true }
        terminate()
        let grace = Date().addingTimeInterval(0.5)
        while isRunning, Date() < grace {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if isRunning {
            kill(processIdentifier, SIGKILL)
        }
        // Wait for the child to be fully reaped so callers can safely
        // read terminationStatus and drain pipes without races.
        waitUntilExit()
        return false
    }
}
