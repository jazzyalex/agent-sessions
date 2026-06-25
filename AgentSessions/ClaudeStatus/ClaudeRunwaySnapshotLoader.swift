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
                let identities = RunwaySnapshotAssembly.uniqueIdentities(request.identities + scannerIdentities)
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
