import Foundation

enum AppRuntime {
    /// True when running under Xcode/`xcodebuild test`.
    /// Cached on first access — the test-host environment doesn't change mid-process.
    static let isRunningTests: Bool = {
        let env = ProcessInfo.processInfo.environment
        let forced = (env["AGENT_SESSIONS_TEST_MODE"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if forced == "1" || forced == "true" || forced == "yes" {
            return true
        }
        let testKeys = [
            "XCTestConfigurationFilePath",
            "XCTestBundlePath",
            "XCInjectBundle",
            "XCInjectBundleInto",
            "XCTestSessionIdentifier"
        ]
        if testKeys.contains(where: { !(env[$0] ?? "").isEmpty }) {
            return true
        }
        if Bundle.main.bundlePath.contains("/.deriveddata-tests/") {
            return true
        }
        if NSClassFromString("XCTestCase") != nil {
            return true
        }
        return false
    }()

    /// True when app code is being loaded by tooling rather than the real app process.
    /// Build-time metadata extraction can load app types in-process, so avoid any
    /// filesystem probing in that environment.
    /// Coupled to bundle ID `com.triada.AgentSessions` — update if the app is rebranded.
    static let isHostedByTooling: Bool = {
        if isRunningTests { return true }
        return Bundle.main.bundleIdentifier != "com.triada.AgentSessions"
    }()
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

/// One-shot gate that opens one run-loop tick after the first window appears.
/// Startup work that touches the filesystem should `await waitUntilReady()`
/// so macOS TCC sees the access only after the UI is visible.
enum AppReadyGate {
    private static let state = Locked<GateState>(.waiting([]))

    private enum GateState {
        case waiting([CheckedContinuation<Void, Never>])
        case ready
    }

    static func markReady() {
        let continuations: [CheckedContinuation<Void, Never>]
        continuations = state.withLock { s in
            guard case .waiting(let pending) = s else { return [] }
            s = .ready
            return pending
        }
        for c in continuations { c.resume() }
    }

    static func waitUntilReady() async {
        let needsWait: Bool = state.withLock { s in
            if case .ready = s { return false }
            return true
        }
        guard needsWait else { return }
        await withCheckedContinuation { cont in
            state.withLock { s in
                switch s {
                case .ready:
                    cont.resume()
                case .waiting(var pending):
                    pending.append(cont)
                    s = .waiting(pending)
                }
            }
        }
    }
}
