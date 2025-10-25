import Foundation
import Combine

// MARK: - Models

enum RateLimitWindow: String, Equatable { case primary, secondary }
enum PressureReason: Equatable { case capacity, percentSlope, fallback429 }
enum PressureSeverity: Equatable { case none, warn, critical }

struct CapETA: Equatable {
    let window: RateLimitWindow
    let minutesToCap: Double?
    let minutesToReset: Double?
    let reason: PressureReason
    let recent429Count: Int
}

struct CapPressureState: Equatable {
    let eta: CapETA?
    let severity: PressureSeverity
}

// Internal snapshot for each window
private struct WindowSnapshot {
    let capturedAt: Date
    let usedPercent: Double?
    let resetsAt: Date?
    let windowMinutes: Int?
    let remainingTokens: Double?
    let capacityTokens: Double?
}

// MARK: - Store

@MainActor
final class CapPressureStore: ObservableObject {
    static let shared = CapPressureStore()

    @Published private(set) var state = CapPressureState(eta: nil, severity: .none)

    // Usage EMA
    private var rateEMA: Double? // tokens/min
    private var lastSampleAt: Date?

    // Snapshots (keep small history for slope)
    private var snapshots: [RateLimitWindow: [WindowSnapshot]] = [.primary: [], .secondary: []]

    // 429 ring buffer
    private var recent429: [Date] = []

    private init() {}

    // MARK: Inputs
    func recordUsageSample(input: Int, cached: Int, output: Int, at ts: Date) {
        let billable = max(0, (input - cached)) + max(0, output)
        guard billable >= 0 else { return }
        // Compute instantaneous rate from last sample interval
        if let last = lastSampleAt {
            let dtMin = max(1.0/60.0, ts.timeIntervalSince(last) / 60.0)
            let inst = Double(billable) / dtMin
            let alpha = 0.2
            if let old = rateEMA { rateEMA = alpha * inst + (1 - alpha) * old } else { rateEMA = inst }
        }
        lastSampleAt = ts
        recompute(now: ts)
    }

    func updateWindow(window: RateLimitWindow, capturedAt: Date, usedPercent: Double?, resetsAt: Date?, windowMinutes: Int?, remainingTokens: Double?, capacityTokens: Double?) {
        let snap = WindowSnapshot(capturedAt: capturedAt, usedPercent: usedPercent, resetsAt: resetsAt, windowMinutes: windowMinutes, remainingTokens: remainingTokens, capacityTokens: capacityTokens)
        var arr = snapshots[window] ?? []
        arr.append(snap)
        // keep last 6
        if arr.count > 6 { arr.removeFirst(arr.count - 6) }
        snapshots[window] = arr
        recompute(now: Date())
    }

    func record429(at ts: Date = Date()) {
        recent429.append(ts)
        trim429(now: ts)
        recompute(now: ts)
    }

    // MARK: Compute
    private func recompute(now: Date) {
        let warnMins = Double(UserDefaults.standard.object(forKey: "CapWarningThresholdMinutes") as? Int ?? 10)
        let critMins = Double(UserDefaults.standard.object(forKey: "CapCriticalThresholdMinutes") as? Int ?? 5)
        let fallbackWindow = Double(UserDefaults.standard.object(forKey: "Fallback429WindowMinutes") as? Int ?? 10)
        let fallbackCount = UserDefaults.standard.object(forKey: "Fallback429Count") as? Int ?? 2

        trim429(now: now, windowMins: fallbackWindow)

        // Prepare per-window ETAs
        var candidates: [CapETA] = []
        for win in [RateLimitWindow.primary, .secondary] {
            let etaA = etaByCapacity(window: win)
            let etaB = etaByPercentSlope(window: win)
            let chosen: (Double, PressureReason)? = [etaA, etaB].compactMap { $0 }.min { $0.0 < $1.0 }
            let minutesToReset = snapshots[win]?.compactMap { $0.resetsAt }.map { $0.timeIntervalSince(now) / 60.0 }.min()
            if let (mins, reason) = chosen {
                let bounded = min(max(mins, 0.5), 120.0)
                let eta = CapETA(window: win, minutesToCap: bounded, minutesToReset: minutesToReset, reason: reason, recent429Count: recent429.count)
                candidates.append(eta)
            }
        }

        // 429 fallback if nothing else
        if candidates.isEmpty, recent429.count >= fallbackCount {
            let mins = fallbackWindow
            let minReset = [RateLimitWindow.primary, .secondary].compactMap { snapshots[$0]?.compactMap { $0.resetsAt }.min() }.min()
            let minsToReset = minReset.map { max(0, $0.timeIntervalSince(now) / 60.0) }
            candidates.append(CapETA(window: .primary, minutesToCap: mins, minutesToReset: minsToReset, reason: .fallback429, recent429Count: recent429.count))
        }

        // Drop if above warn threshold or rate ~ 0
        let chosen = candidates.min { (a, b) in
            let am = a.minutesToCap ?? .infinity
            let bm = b.minutesToCap ?? .infinity
            return am < bm
        }

        let severity: PressureSeverity
        if let m = chosen?.minutesToCap, m <= critMins { severity = .critical }
        else if let m = chosen?.minutesToCap, m <= warnMins { severity = .warn }
        else { severity = .none }

        let newState = CapPressureState(eta: chosen, severity: severity)
        if newState != state { state = newState }
    }

    private func etaByCapacity(window: RateLimitWindow) -> (Double, PressureReason)? {
        guard let snaps = snapshots[window], let latest = snaps.last else { return nil }
        let rate = max(rateEMA ?? 0, 1e-3) // tokens/min
        var remaining: Double?
        if let r = latest.remainingTokens { remaining = r }
        else if let cap = latest.capacityTokens, let p = latest.usedPercent { remaining = cap * (1.0 - p / 100.0) }
        guard let rem = remaining, rem.isFinite, rem >= 0 else { return nil }
        return (rem / rate, .capacity)
    }

    private func etaByPercentSlope(window: RateLimitWindow) -> (Double, PressureReason)? {
        guard let snaps = snapshots[window] else { return nil }
        if snaps.count >= 2 {
            // Average over last deltas with valid usedPercent
            var pairs: [(Double, Double)] = [] // minutes, deltaPercent
            for i in 1..<snaps.count {
                let a = snaps[i-1], b = snaps[i]
                guard let pa = a.usedPercent, let pb = b.usedPercent else { continue }
                let dt = max(1.0/60.0, b.capturedAt.timeIntervalSince(a.capturedAt) / 60.0)
                pairs.append((dt, pb - pa))
            }
            guard !pairs.isEmpty, let last = snaps.last, let pNow = last.usedPercent else { return nil }
            let slope = pairs.map { $0.1 / $0.0 }.reduce(0, +) / Double(pairs.count) // percent points per min
            let eps = 1e-3
            let rate = max(slope, eps)
            let remPct = max(0, 100.0 - pNow)
            return (remPct / rate, .percentSlope)
        }
        // Single snapshot fallback using window semantics when available
        if let last = snaps.last, let pNow = last.usedPercent, let wmin = last.windowMinutes, let rz = last.resetsAt {
            let elapsed = Double(wmin) - max(0, rz.timeIntervalSince(last.capturedAt) / 60.0)
            if elapsed > 1.0/60.0 {
                let slope = pNow / elapsed
                let eps = 1e-3
                let rate = max(slope, eps)
                let remPct = max(0, 100.0 - pNow)
                return (remPct / rate, .percentSlope)
            }
        }
        return nil
    }

    private func trim429(now: Date, windowMins: Double = 10) {
        let cutoff = now.addingTimeInterval(-windowMins * 60)
        recent429.removeAll { $0 < cutoff }
    }
}
