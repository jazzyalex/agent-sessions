import Foundation

/// Builds a runway snapshot for Claude. Mirrors `CodexRunwaySnapshotLoader` but
/// uses only the token-activity path (Claude logs carry no per-session rate
/// limits), then hands the burns to the shared, provider-agnostic
/// `CodexRunwayCalculator` and `RunwaySnapshotAssembly`.
enum ClaudeRunwaySnapshotLoader {
    static func snapshot(for request: CodexRunwaySnapshotRequest) async -> CodexRunwaySnapshot? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let scannerIdentities = ClaudeRunwayRecentSessionScanner.identities(
                    root: request.recentSessionsRoot,
                    now: request.now
                )
                let merged = RunwaySnapshotAssembly.uniqueIdentities(request.identities + scannerIdentities)
                // Prefer the title the user sees in Claude Desktop (keyed by the
                // transcript session id) over any transcript-derived name. This
                // wins regardless of whether the name came from a HUD row or the
                // recent-session scanner.
                let desktopTitles = ClaudeDesktopSessionTitles.map()
                let identities = merged.map { identity -> RunwaySessionIdentity in
                    guard let title = desktopTitles[identity.id] else { return identity }
                    return RunwaySessionIdentity(
                        id: identity.id,
                        displayName: ClaudeRunwayLog.compact(title),
                        isGoal: identity.isGoal,
                        logPaths: identity.logPaths
                    )
                }
                let burns = request.baseline.hasProjectedRunout
                    ? ClaudeRunwayTokenActivityParser.burns(
                        identities: identities,
                        baseline: request.baseline,
                        now: request.now
                    )
                    : []
                let snapshot = RunwaySnapshotAssembly.withPendingRows(
                    baseline: request.baseline,
                    snapshot: CodexRunwayCalculator.snapshot(
                        baseline: request.baseline,
                        burns: burns,
                        maxRows: request.maxRows
                    ),
                    activeIdentities: identities,
                    maxRows: request.maxRows
                )
                continuation.resume(returning: snapshot)
            }
        }
    }
}
