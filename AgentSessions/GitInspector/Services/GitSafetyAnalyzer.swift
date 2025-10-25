import Foundation

/// Analyzes safety of resuming a session by comparing historical and current git state
struct GitSafetyAnalyzer {
    /// Analyze safety of resuming a session
    /// - Parameters:
    ///   - historical: Git context when session was created
    ///   - current: Current git status
    /// - Returns: Safety check result with recommendations
    static func analyze(
        historical: HistoricalGitContext?,
        current: CurrentGitStatus?
    ) -> GitSafetyCheck {
        // Case 1: No data available
        guard let historical = historical, let current = current else {
            return GitSafetyCheck(
                status: .unknown,
                checks: [],
                recommendation: "Unable to verify safety - git information unavailable"
            )
        }

        var checks: [GitSafetyCheck.CheckResult] = []
        var status: GitSafetyCheck.SafetyStatus = .safe

        // Check 1: Branch unchanged
        let branchSame = historical.branch == current.branch
        checks.append(GitSafetyCheck.CheckResult(
            icon: branchSame ? "✓" : "⚠️",
            message: branchSame
                ? "Branch unchanged (still on \(current.branch ?? "unknown"))"
                : "Branch changed: \(historical.branch ?? "?") → \(current.branch ?? "?")",
            passed: branchSame
        ))
        if !branchSame {
            status = .warning
        }

        // Check 2: No new commits
        let commitSame = historical.commitHash?.prefix(7) == current.commitHash?.prefix(7)
        checks.append(GitSafetyCheck.CheckResult(
            icon: commitSame ? "✓" : "⚠️",
            message: commitSame
                ? "No new commits since session start"
                : "New commits detected",
            passed: commitSame
        ))
        if !commitSame && status != .warning {
            status = .warning
        }

        // Check 3: Working tree clean/dirty comparison
        if current.isDirty {
            let fileCount = current.dirtyFiles.count
            checks.append(GitSafetyCheck.CheckResult(
                icon: "⚠️",
                message: "\(fileCount) uncommitted change\(fileCount == 1 ? "" : "s") detected in working tree",
                passed: false
            ))
            if status == .safe {
                status = .caution
            }
        } else {
            checks.append(GitSafetyCheck.CheckResult(
                icon: "✓",
                message: "Working tree clean",
                passed: true
            ))
        }

        // Generate recommendation based on overall status
        let recommendation: String
        switch status {
        case .safe:
            recommendation = "Safe to resume - no changes detected"
        case .caution:
            recommendation = "Review uncommitted changes before resuming. The agent may conflict with your work. Consider committing or stashing changes first."
        case .warning:
            recommendation = "Caution: Git state has changed significantly. Review changes carefully before resuming."
        case .unknown:
            recommendation = "Unable to verify safety - proceed with caution"
        }

        return GitSafetyCheck(
            status: status,
            checks: checks,
            recommendation: recommendation
        )
    }
}
