import Foundation

// DEBUG-only scripted UI benchmark driver, split from PerfSignpost.swift because it
// drives app windows (`AppWindowRouter`) and so cannot live in the shared session core.
#if DEBUG
/// Self-driving perf harness. Enabled only when the `AS_PERF_BENCH` env var is set,
/// so it has zero effect on normal launches. Drives a repeatable UI action (e.g. sort)
/// on a timer so the app benchmarks itself — no UI automation needed. Combine with the
/// Perf spans (CPU cost per phase) and MainThreadStallMonitor (total main-thread block)
/// to attribute a beachball to CPU work vs SwiftUI rendering.
///
/// Env knobs:
///   AS_PERF_BENCH=sort         which action to drive ("sort" or "select")
///   AS_PERF_BENCH_DELAY=30     seconds to wait after launch (let indexing settle)
///   AS_PERF_BENCH_CYCLES=8     number of action cycles to run (for "select": rows to walk)
///   AS_PERF_BENCH_INTERVAL=2   seconds between cycles (Double — fractional values like
///                              0.06 are supported, used by "select" to hit key-repeat rate)
///   AS_PERF_BENCH_STRIDE=1     rows advanced per "select" cycle. 1 = key-repeat scrub;
///                              large strides (e.g. 25) jump across row ranges, forcing
///                              scroll-to-row + fresh row materialization — a fast-scroll
///                              simulation (W7 Task 0)
@MainActor
enum PerfBench {
    static let toggleSortNotification = Notification.Name("ASPerfToggleSort")
    /// "select" mode: each cycle posts this to advance selection to the next row,
    /// exercising the real setActiveSelection(...) path at a driven cadence — used to
    /// reproduce key-repeat scrubbing (AS_PERF_BENCH_INTERVAL=0.06) without UI automation.
    static let selectWalkNotification = Notification.Name("ASPerfSelectWalk")
    /// Read by the select-walk receiver in UnifiedSessionsView.
    static let selectWalkStride: Int = max(1, Int(ProcessInfo.processInfo.environment["AS_PERF_BENCH_STRIDE"] ?? "") ?? 1)

    static func startIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let mode = env["AS_PERF_BENCH"], !mode.isEmpty else { return }
        let delay = Double(env["AS_PERF_BENCH_DELAY"] ?? "") ?? 30
        let cycles = Int(env["AS_PERF_BENCH_CYCLES"] ?? "") ?? 8
        let interval = Double(env["AS_PERF_BENCH_INTERVAL"] ?? "") ?? 2.0
        print("[perf][bench] mode=\(mode) delay=\(delay)s cycles=\(cycles) interval=\(interval)s")
        // Ensure the main window is open + rendered so UnifiedSessionsView exists to
        // receive the sort toggles (this user launches into cockpit-only mode).
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            AppWindowRouter.showAgentSessionsWindow()
            print("[perf][bench] open main window; visible=\(AppWindowRouter.isAgentSessionsWindowVisible)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            AppWindowRouter.showAgentSessionsWindow()
            print("[perf][bench] begin cycles; mainVisible=\(AppWindowRouter.isAgentSessionsWindowVisible)")
            runCycle(mode: mode, index: 1, total: cycles, interval: interval)
        }
    }

    private static func runCycle(mode: String, index: Int, total: Int, interval: Double) {
        guard index <= total else {
            print("[perf][bench] done")
            return
        }
        print("[perf][bench] \(mode) cycle \(index)/\(total)")
        switch mode {
        case "sort":
            NotificationCenter.default.post(name: toggleSortNotification, object: nil)
        case "select":
            NotificationCenter.default.post(name: selectWalkNotification, object: nil)
        default:
            print("[perf][bench] unknown mode \(mode)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) {
            runCycle(mode: mode, index: index + 1, total: total, interval: interval)
        }
    }
}
#endif
