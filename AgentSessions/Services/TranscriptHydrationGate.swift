import Foundation
import Combine

/// Former central gate for the large-session guardrail. No longer called anywhere
/// (Task 9c removed all three call sites — UnifiedSessionsView's direct reload,
/// SearchCoordinator's prewarm, and UnifiedSessionIndexer's focused-session reload —
/// so sessions now auto-hydrate unconditionally on selection).
///
/// Selecting a session triggers a full parse (`parseFileFull`). This class used to
/// gate that parse above a size/message threshold behind a manual "Show full
/// transcript" affordance (profiled hang: 30 s / 1.3 GB on a 619k-line session).
/// Parse + model build now run off-main and the windowed build paints only the tail
/// window, so the guardrail is obsolete.
///
/// Kept as a dead, always-true stub rather than deleted outright: removing the file
/// requires editing the Xcode project's pbxproj references, which is out of scope
/// for this behavior change. Safe to delete (class + pbxproj entries) in a follow-up.
final class TranscriptHydrationGate: ObservableObject {
    static let shared = TranscriptHydrationGate()

    private init() {}

    /// Always true. No longer called by any hydration path; retained only so this
    /// stub compiles without hunting down zero call sites.
    func shouldAutoHydrate(_ session: Session) -> Bool {
        true
    }
}
