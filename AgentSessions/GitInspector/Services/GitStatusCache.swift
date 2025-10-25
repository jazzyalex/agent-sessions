import Foundation

/// Caches live git status queries to avoid redundant shell commands
/// Cache lifetime: 10 seconds (soft TTL)
actor GitStatusCache {
    static let shared = GitStatusCache()

    /// Keyed by canonical repo root path
    private var cache: [String: CachedStatus] = [:]
    private let cacheLifetime: TimeInterval = 10.0
    private let commandRunner = GitCommandRunner()

    private struct CachedStatus {
        let status: CurrentGitStatus
        let timestamp: Date

        var isStale: Bool {
            Date().timeIntervalSince(timestamp) > 60.0
        }
    }

    /// Get current git status for a working directory
    /// - Parameter cwd: Any path within the repository (we normalize to repo root)
    /// - Returns: Current git status, or nil if not a git repository
    func getStatus(for cwd: String) async -> CurrentGitStatus? {
        // Normalize key to repository root if possible
        let key = await canonicalRepoRoot(for: cwd) ?? cwd

        // Check cache first
        if let cached = cache[key], !cached.isStale {
            return cached.status
        }

        // Query git and cache result
        guard let status = await queryGit(cwd: key) else {
            return nil
        }

        cache[key] = CachedStatus(status: status, timestamp: Date())
        return status
    }

    /// Invalidate cache for a specific directory
    /// Forces next getStatus() call to re-query git
    func invalidate(for cwd: String) async {
        let key = await canonicalRepoRoot(for: cwd) ?? cwd
        cache.removeValue(forKey: key)
    }

    /// Clear all cached statuses
    func clearAll() {
        cache.removeAll()
    }

    /// Query git directly (used internally and for refresh operations)
    private func queryGit(cwd: String) async -> CurrentGitStatus? {
        // Check if it's a git repository first
        guard await commandRunner.isGitRepository(cwd) else {
            return nil
        }

        // Run all git commands in parallel
        async let branch = commandRunner.runGit(["rev-parse", "--abbrev-ref", "HEAD"], in: cwd)
        async let commit = commandRunner.runGit(["rev-parse", "HEAD"], in: cwd)
        async let statusOutput = commandRunner.runGit(["status", "--porcelain"], in: cwd)
        async let lastMessage = commandRunner.runGit(["log", "-1", "--pretty=%s"], in: cwd)
        // Tracking may fail if no upstream; we treat that as (nil,nil)
        async let tracking = commandRunner.runGit(["rev-list", "--left-right", "--count", "@{u}...HEAD"], in: cwd)

        let (branchResult, commitResult, statusResult, messageResult, trackingResult) =
            await (branch, commit, statusOutput, lastMessage, tracking)

        // Parse status output to get dirty files
        let dirtyFiles = parseGitStatus(statusResult)

        // Parse tracking information
        let (behindCount, aheadCount) = parseTracking(trackingResult)

        return CurrentGitStatus(
            branch: branchResult,
            commitHash: commitResult,
            isDirty: !dirtyFiles.isEmpty,
            dirtyFiles: dirtyFiles,
            lastCommitMessage: messageResult,
            aheadCount: aheadCount,
            behindCount: behindCount,
            queriedAt: Date()
        )
    }

    /// Parse git status --porcelain output
    private func parseGitStatus(_ output: String?) -> [GitFileStatus] {
        guard let output = output, !output.isEmpty else {
            return []
        }

        return output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { return nil }

            let statusCode = String(parts[0]).trimmingCharacters(in: .whitespaces)
            let path = String(parts[1]).trimmingCharacters(in: .whitespaces)

            // Map git status codes to our FileChangeType
            let changeType: FileChangeType
            if statusCode.hasPrefix("M") {
                changeType = .modified
            } else if statusCode.hasPrefix("A") {
                changeType = .added
            } else if statusCode.hasPrefix("D") {
                changeType = .deleted
            } else if statusCode.hasPrefix("R") {
                changeType = .renamed
            } else if statusCode.hasPrefix("C") {
                changeType = .copied
            } else if statusCode.hasPrefix("?") {
                changeType = .untracked
            } else if statusCode.hasPrefix("U") {
                changeType = .unmerged
            } else {
                changeType = .modified  // Default fallback
            }

            return GitFileStatus(path: path, changeType: changeType)
        }
    }

    /// Parse git rev-list tracking output (e.g., "2\t3" means 2 behind, 3 ahead)
    private func parseTracking(_ output: String?) -> (behind: Int?, ahead: Int?) {
        guard let output = output else {
            return (nil, nil)
        }

        let parts = output.split(separator: "\t")
        guard parts.count == 2 else {
            return (nil, nil)
        }

        let behind = Int(parts[0])
        let ahead = Int(parts[1])

        return (behind, ahead)
    }

    /// Resolve canonical repository root path for a given directory using git
    private func canonicalRepoRoot(for path: String) async -> String? {
        await commandRunner.runGit(["rev-parse", "--show-toplevel"], in: path)
    }
}
