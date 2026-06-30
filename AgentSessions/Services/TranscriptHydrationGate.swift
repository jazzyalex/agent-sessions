import Foundation
import Combine

/// Central gate for the large-session guardrail.
///
/// Selecting a session can trigger a full parse (`parseFileFull`) from three paths —
/// the direct provider reload, the search prewarm, and the focused-session reload.
/// For sessions over a size/message threshold that whole-document parse + build can
/// hang the app (profiled: 30 s / 1.3 GB on a 619k-line session), so we skip
/// auto-hydration until the user opts in via "Show full transcript". All three paths
/// must consult `shouldAutoHydrate`; gating only one leaves another able to parse.
final class TranscriptHydrationGate: ObservableObject {
    static let shared = TranscriptHydrationGate()

    private let lock = NSLock()
    private var overrides: Set<String> = []
    /// Bumps whenever an override is added so SwiftUI views observing the gate refresh.
    @Published private(set) var version: Int = 0

    private init() {}

    /// True if the session exceeds the auto-hydration thresholds.
    func isLarge(_ session: Session) -> Bool {
        let bytes = session.fileSizeBytes ?? 0
        return session.messageCount > FeatureFlags.largeSessionMessageThreshold
            || bytes > FeatureFlags.largeSessionByteThreshold
    }

    /// True if this session may be parsed/built automatically on selection.
    func shouldAutoHydrate(_ session: Session) -> Bool {
        guard isLarge(session) else { return true }
        lock.lock(); defer { lock.unlock() }
        return overrides.contains(session.id)
    }

    /// True if the guardrail interstitial should be offered for this session.
    func needsManualHydration(_ session: Session) -> Bool {
        guard isLarge(session) else { return false }
        lock.lock(); defer { lock.unlock() }
        return !overrides.contains(session.id)
    }

    /// User opted to load the full transcript for this session.
    @MainActor
    func allowFullHydration(_ sessionID: String) {
        lock.lock()
        let inserted = overrides.insert(sessionID).inserted
        lock.unlock()
        if inserted { version &+= 1 }
    }
}
