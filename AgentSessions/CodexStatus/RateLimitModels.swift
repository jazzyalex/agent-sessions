import Foundation
import Combine

enum TightWindow: Equatable { case primary, secondary }

struct RateLimitTightState {
    var isTight: Bool
    var window: TightWindow?
    var resetAt: Date?
    var remainingSeconds: Int?
    var recent429Count: Int
}

final class RateLimitStore: ObservableObject {
    static let shared = RateLimitStore()

    @Published private(set) var state = RateLimitTightState(isTight: false, window: nil, resetAt: nil, remainingSeconds: nil, recent429Count: 0)

    private var timerCancellable: AnyCancellable?
    private var lastPrimaryReset: Date?
    private var lastSecondaryReset: Date?
    private var recent429: [Date] = []

    private init() {
        timerCancellable = Timer.publish(every: 1, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            self?.tick()
        }
    }

    func record429(at date: Date = Date()) {
        recent429.append(date)
        trim429(now: date)
        recompute(now: date)
    }

    func update(primaryReset: Date?, secondaryReset: Date?, now: Date = Date()) {
        lastPrimaryReset = primaryReset
        lastSecondaryReset = secondaryReset
        trim429(now: now)
        recompute(now: now)
    }

    private func tick() {
        recompute(now: Date())
    }

    private func recompute(now: Date) {
        let thresholdSeconds = UserDefaults.standard.object(forKey: "RateLimitTightThresholdSeconds") as? Int ?? 600
        let pRem = remaining(from: lastPrimaryReset, now: now)
        let sRem = remaining(from: lastSecondaryReset, now: now)

        var window: TightWindow? = nil
        var resetAt: Date? = nil
        var remainingSeconds: Int? = nil

        if let pr = pRem, pr <= thresholdSeconds, pr >= 0 { window = .primary; resetAt = lastPrimaryReset; remainingSeconds = pr }
        if let sr = sRem, sr <= thresholdSeconds, sr >= 0 {
            if remainingSeconds == nil || sr < (remainingSeconds ?? Int.max) { window = .secondary; resetAt = lastSecondaryReset; remainingSeconds = sr }
        }

        // 429-only path: if 2+ in 10m and none of the above
        trim429(now: now)
        let tightFrom429 = recent429.count >= 2
        let isTight = (remainingSeconds != nil) || tightFrom429
        let rs = RateLimitTightState(isTight: isTight,
                                     window: window,
                                     resetAt: resetAt,
                                     remainingSeconds: remainingSeconds,
                                     recent429Count: recent429.count)
        if rs.isTight != state.isTight || rs.window != state.window || rs.remainingSeconds != state.remainingSeconds || rs.recent429Count != state.recent429Count {
            state = rs
        }
    }

    private func remaining(from date: Date?, now: Date) -> Int? {
        guard let date else { return nil }
        return Int(ceil(date.timeIntervalSince(now)))
    }

    private func trim429(now: Date) {
        let cutoff = now.addingTimeInterval(-600) // last 10 minutes
        recent429.removeAll { $0 < cutoff }
    }
}
