import Foundation

// DEBUG-only performance instrumentation for the "make every action instant" pass.
//
// Provides three things, all compiled out entirely in Release:
//   1. `Perf.begin(_:)` / `Perf.end(_:)` — time a synchronous span; emits an
//      Instruments-visible os_signpost interval AND prints to the console when the
//      span exceeds a threshold (default one dropped frame, ~16ms).
//   2. `Perf.event(_:_:)` — a point-in-time signpost/console marker (e.g. to record
//      that a live-dot tick took the cheap vs expensive path).
//   3. `MainThreadStallMonitor` — a main-runloop watchdog that reports beachballs
//      (multi-hundred-ms main-thread blocks) with their measured duration.
//
// Rationale: the session-list beachball has repeatedly defeated "by feel" fixes, so
// every W1 lever needs before/after numbers. See docs/perf-master-plan.md (lever #0).

#if DEBUG
import os

enum Perf {
    static let log = OSLog(subsystem: "com.agentsessions.perf", category: "spans")

    struct Span {
        let name: StaticString
        let id: OSSignpostID
        let start: DispatchTime
        let thresholdMs: Double
        let detail: () -> String
    }

    /// Begin a timed span. Pair with `Perf.end(_:)`, ideally via `defer`. `detail` is kept
    /// as a closure and only evaluated in `end()` if the span exceeds its threshold, so
    /// under-threshold spans (the common case) never build the interpolated string.
    static func begin(_ name: StaticString,
                      thresholdMs: Double = 16,
                      _ detail: @escaping @autoclosure () -> String = "") -> Span {
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: id)
        return Span(name: name, id: id, start: DispatchTime.now(), thresholdMs: thresholdMs, detail: detail)
    }

    /// End a span. Prints `[perf] <name> <detail> <extra> N.Nms` when over threshold.
    static func end(_ span: Span, _ extra: @autoclosure () -> String = "") {
        os_signpost(.end, log: log, name: span.name, signpostID: span.id)
        let ms = Double(DispatchTime.now().uptimeNanoseconds &- span.start.uptimeNanoseconds) / 1_000_000
        guard ms >= span.thresholdMs else { return }
        let detailStr = span.detail()
        let d = detailStr.isEmpty ? "" : " " + detailStr
        let extraStr = extra()
        let e = extraStr.isEmpty ? "" : " " + extraStr
        print(String(format: "[perf] %@%@%@ %.1fms", String(describing: span.name), d, e, ms))
    }

    /// Point-in-time marker (both signpost and console).
    static func event(_ name: StaticString, _ message: @autoclosure () -> String = "") {
        let msg = message()
        os_signpost(.event, log: log, name: name, "%{public}s", msg)
        if !msg.isEmpty {
            print("[perf] \(String(describing: name)) \(msg)")
        }
    }
}

/// Watchdog that detects main-thread stalls (beachballs). It schedules a fast
/// repeating timer on the main queue; if the main run loop is blocked, the timer
/// fires late and the overshoot is the stall duration.
@MainActor
final class MainThreadStallMonitor {
    static let shared = MainThreadStallMonitor()

    private var timer: DispatchSourceTimer?
    private var lastFire: DispatchTime = DispatchTime.now()
    private let intervalMs: Double = 50
    private let stallThresholdMs: Double = 200

    func start() {
        // Only run during an explicit perf investigation, not on every DEBUG launch:
        // enabled when AS_PERF_MONITOR is set, or implicitly during an AS_PERF_BENCH run.
        let env = ProcessInfo.processInfo.environment
        guard env["AS_PERF_MONITOR"] != nil || (env["AS_PERF_BENCH"].map { !$0.isEmpty } ?? false) else { return }
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + .milliseconds(Int(intervalMs)),
                   repeating: .milliseconds(Int(intervalMs)),
                   leeway: .milliseconds(5))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let now = DispatchTime.now()
            let gapMs = Double(now.uptimeNanoseconds &- self.lastFire.uptimeNanoseconds) / 1_000_000
            self.lastFire = now
            let overshoot = gapMs - self.intervalMs
            if overshoot >= self.stallThresholdMs {
                print(String(format: "[perf][STALL] main thread blocked ~%.0fms", overshoot))
                os_signpost(.event, log: Perf.log, name: "main-stall", "%{public}.0fms", overshoot)
            }
        }
        lastFire = DispatchTime.now()
        timer = t
        t.resume()
    }
}

/// Self-driving perf harness. Enabled only when the `AS_PERF_BENCH` env var is set,
/// so it has zero effect on normal launches. Drives a repeatable UI action (e.g. sort)
/// on a timer so the app benchmarks itself — no UI automation needed. Combine with the
/// Perf spans (CPU cost per phase) and MainThreadStallMonitor (total main-thread block)
/// to attribute a beachball to CPU work vs SwiftUI rendering.
///
/// Env knobs:
///   AS_PERF_BENCH=sort         which action to drive (currently: "sort")
///   AS_PERF_BENCH_DELAY=30     seconds to wait after launch (let indexing settle)
///   AS_PERF_BENCH_CYCLES=8     number of action cycles to run
///   AS_PERF_BENCH_INTERVAL=2   seconds between cycles
@MainActor
enum PerfBench {
    static let toggleSortNotification = Notification.Name("ASPerfToggleSort")

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
        default:
            print("[perf][bench] unknown mode \(mode)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) {
            runCycle(mode: mode, index: index + 1, total: total, interval: interval)
        }
    }
}
#endif
