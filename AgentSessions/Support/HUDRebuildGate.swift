import Foundation

/// Skip-gate for the Cockpit HUD derived-state rebuild. The presence poll
/// publishes every ~2 s even when nothing changed; recomputing the rows
/// snapshot costs ~35 ms on the main thread per tick. Rebuild only when a
/// versioned input changed, or when `staleReclassifyInterval` has elapsed
/// (so age-based active/idle classification still refreshes).
struct HUDRebuildGate {
    struct Inputs: Equatable {
        var membershipVersion: UInt64
        var badgeVersion: UInt64
        var sessionsGeneration: UInt64
        var isCompact: Bool
        var showProbes: Bool
        /// `UserDefaults` "SkipAgentsPreamble" (see `Session.title`,
        /// `PreferencesKey.Unified.skipAgentsPreamble`). Rendered row titles
        /// read this preference directly, so a flip must trigger an immediate
        /// rebuild (C3) rather than waiting for `staleReclassifyInterval` --
        /// without it in `Inputs`, `shouldRebuild` sees no versioned-input
        /// change and the HUD would show stale titles for up to 5s.
        var skipAgentsPreamble: Bool
    }

    let staleReclassifyInterval: TimeInterval
    private var lastInputs: Inputs?
    private var lastRebuildAt: Date?

    init(staleReclassifyInterval: TimeInterval) {
        self.staleReclassifyInterval = staleReclassifyInterval
    }

    mutating func shouldRebuild(inputs: Inputs, now: Date) -> Bool {
        if inputs != lastInputs {
            mark(inputs: inputs, now: now)
            return true
        }
        if let last = lastRebuildAt, now.timeIntervalSince(last) < staleReclassifyInterval {
            return false
        }
        mark(inputs: inputs, now: now)
        return true
    }

    mutating func forceNextRebuild() {
        lastInputs = nil
        lastRebuildAt = nil
    }

    private mutating func mark(inputs: Inputs, now: Date) {
        lastInputs = inputs
        lastRebuildAt = now
    }
}
