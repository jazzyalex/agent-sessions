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
    private static let start = Locked<Date?>(nil)

    static func reset(_ label: String = "launch") {
        start.withLock { $0 = Date() }
        print("[Launch] reset \(label)")
    }

    static func log(_ label: String) {
        guard let t0 = start.withLock({ $0 }) else {
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

final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
