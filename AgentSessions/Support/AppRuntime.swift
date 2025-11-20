import Foundation

enum AppRuntime {
    /// True when running under Xcode/`xcodebuild test`.
    static var isRunningTests: Bool {
        return ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}

/// Lightweight helper for measuring launch-time phases end-to-end.
/// Only active in DEBUG builds; no-ops in Release.
enum LaunchProfiler {
    #if DEBUG
    private static var start: Date?

    static func reset(_ label: String = "launch") {
        start = Date()
        print("[Launch] reset \(label)")
    }

    static func log(_ label: String) {
        guard let t0 = start else {
            print("[Launch] \(label) (no t0)")
            return
        }
        let dt = Date().timeIntervalSince(t0)
        let formatted = String(format: "%.3f", dt)
        print("[Launch] \(label) +\(formatted)s")
    }
    #else
    static func reset(_ label: String = "launch") {}
    static func log(_ label: String) {}
    #endif
}
