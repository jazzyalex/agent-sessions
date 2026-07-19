import SwiftUI

/// Single authoritative acceptance gate for manual hard probes (spec
/// 2026-07-18-qm-hard-probe-design). Every surface (QM toolbar, menu-bar
/// dropdown, Preferences probes, main-window strip) requests probes here so
/// two surfaces can never race the same provider, and "probing…"/"probe
/// failed" row feedback can never wedge: acceptance is synchronous, accepted
/// runs complete exactly once (Task 2 contract), synchronous reports are
/// buffered until acceptance is known (so `false` NEVER follows a delivered
/// completion), and failure expiry is data (a deadline) evaluated against
/// the caller's clock — not a sleeping UI task. Lives at app level (outlives
/// the QM window) so closing/reopening the QM mid-probe shows the truth.
@MainActor
final class ProbeCoordinator: ObservableObject {
    static let shared = ProbeCoordinator()

    enum ProbeRowState: Equatable {
        case none
        case probing(generation: UInt64)
        case failed(until: Date, generation: UInt64)
    }

    /// Guard short-circuits (auth unsafe: 126, tracking disabled: 125, or a
    /// successful run that reports usage unavailable) are `.suppressed`, never
    /// `.failed`: a guard declining to spawn an unsafe probe is not a failed
    /// probe and must not render "probe failed".
    enum Outcome: Equatable { case ok, failed, suppressed }

    /// Typed completion so alert/dialog surfaces (menu-bar dropdown,
    /// Preferences) keep their full-diagnostics presentation while still
    /// routing acceptance through the coordinator.
    enum ProbeReport {
        case claude(ClaudeProbeDiagnostics)
        case codex(CodexProbeDiagnostics)

        var outcome: Outcome {
            switch self {
            case .claude(let d): return ProbeCoordinator.outcome(claude: d)
            case .codex(let d): return ProbeCoordinator.outcome(codex: d)
            }
        }
    }

    static let failureDisplayDuration: TimeInterval = 8

    @Published private(set) var claudeState: ProbeRowState = .none
    @Published private(set) var codexState: ProbeRowState = .none

    private let claudeRunner: (@escaping (ClaudeProbeDiagnostics) -> Void) -> Bool
    private let codexRunner: (@escaping (CodexProbeDiagnostics) -> Void) -> Bool
    /// `isUpdating` covers ordinary refreshes too, so coordinator-idle does
    /// not imply the model will accept; `requestBoth` needs both checks
    /// up front to guarantee it never partially starts.
    private let claudeModelBusy: () -> Bool
    private let codexModelBusy: () -> Bool
    private var generation: UInt64 = 0

    init(claudeRunner: @escaping (@escaping (ClaudeProbeDiagnostics) -> Void) -> Bool = { completion in
             ClaudeUsageModel.shared.hardProbeNowDiagnostics(completion: completion)
         },
         codexRunner: @escaping (@escaping (CodexProbeDiagnostics) -> Void) -> Bool = { completion in
             CodexUsageModel.shared.hardProbeNowDiagnostics(completion: completion)
         },
         claudeModelBusy: @escaping () -> Bool = { ClaudeUsageModel.shared.isUpdating },
         codexModelBusy: @escaping () -> Bool = { CodexUsageModel.shared.isUpdating }) {
        self.claudeRunner = claudeRunner
        self.codexRunner = codexRunner
        self.claudeModelBusy = claudeModelBusy
        self.codexModelBusy = codexModelBusy
    }

    static func outcome(claude diag: ClaudeProbeDiagnostics) -> Outcome {
        if diag.success { return diag.unavailableMessage != nil ? .suppressed : .ok }
        return (diag.exitCode == 126 || diag.exitCode == 125) ? .suppressed : .failed
    }

    static func outcome(codex diag: CodexProbeDiagnostics) -> Outcome {
        if diag.success { return .ok }
        return (diag.exitCode == 126 || diag.exitCode == 125) ? .suppressed : .failed
    }

    func state(for source: UsageTrackingSource) -> ProbeRowState {
        source == .claude ? claudeState : codexState
    }

    func isBusy(_ source: UsageTrackingSource) -> Bool {
        if case .probing = state(for: source) { return true }
        return false
    }

    /// Expiry as data: a `.failed` whose deadline has passed displays as
    /// `.none`. Render against the QM's shared clock tick.
    func displayState(for source: UsageTrackingSource, now: Date) -> ProbeRowState {
        let s = state(for: source)
        if case .failed(let until, _) = s, now >= until { return .none }
        return s
    }

    /// Synchronous acceptance: `true` = probe started (state -> .probing,
    /// `completion` fires exactly once with the provider's diagnostics);
    /// `false` = rejected — state untouched/rolled back and `completion` is
    /// NEVER called, even if a malformed runner completed before declining
    /// (its report is buffered until acceptance is known, then discarded).
    ///
    /// Ordering: `.probing` is installed BEFORE the runner so the row state
    /// exists for the run; synchronous reports are buffered and applied after
    /// the runner accepts, async reports apply directly. Both paths go
    /// through one-shot `deliver`, so a stale double-fire can neither flip
    /// row state (generation guard) nor re-invoke the caller's completion.
    @discardableResult
    func request(_ source: UsageTrackingSource,
                 completion: ((ProbeReport) -> Void)? = nil) -> Bool {
        guard !isBusy(source) else { return false }
        generation += 1
        let gen = generation
        setState(.probing(generation: gen), for: source)

        var acceptanceKnown = false
        var buffered: ProbeReport?
        var delivered = false
        let deliver: (ProbeReport) -> Void = { [weak self] report in
            guard !delivered else { return }
            delivered = true
            if let self,
               case .probing(let current) = self.state(for: source), current == gen {
                switch report.outcome {
                case .ok, .suppressed:
                    self.setState(.none, for: source)
                case .failed:
                    self.setState(.failed(until: Date().addingTimeInterval(Self.failureDisplayDuration),
                                          generation: gen), for: source)
                }
            }
            completion?(report)
        }
        let handle: (ProbeReport) -> Void = { report in
            if acceptanceKnown {
                deliver(report)
            } else if buffered == nil {
                // First-report-wins: a malformed runner double-firing
                // synchronously must deliver its FIRST report, mirroring the
                // one-shot guarantee `deliver` enforces on the async path.
                buffered = report
            }
        }

        let accepted: Bool
        if source == .claude {
            accepted = claudeRunner { handle(.claude($0)) }
        } else {
            accepted = codexRunner { handle(.codex($0)) }
        }
        acceptanceKnown = true
        guard accepted else {
            // Rejected: discard any buffered synchronous report and roll back
            // this generation's `.probing` (only if it still stands).
            if case .probing(let current) = state(for: source), current == gen {
                setState(.none, for: source)
            }
            return false
        }
        if let report = buffered { deliver(report) }
        return true
    }

    /// Atomic eligibility for "Probe Both": rejected outright unless BOTH
    /// providers are coordinator-idle AND both models can accept right now —
    /// no runner is invoked on rejection, so Both can never silently degrade
    /// to probing one provider. All checks and both runner invocations happen
    /// synchronously on the main actor, so nothing can flip in between.
    @discardableResult
    func requestBoth() -> Bool {
        guard !isBusy(.claude), !isBusy(.codex),
              !claudeModelBusy(), !codexModelBusy() else { return false }
        let claudeStarted = request(.claude)
        let codexStarted = request(.codex)
        return claudeStarted && codexStarted
    }

    private func setState(_ s: ProbeRowState, for source: UsageTrackingSource) {
        if source == .claude { claudeState = s } else { codexState = s }
    }
}
