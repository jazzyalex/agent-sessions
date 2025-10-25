import Foundation

/// Historical git context extracted from session files at the time the session was created.
/// This represents a snapshot of the git state when the agent started working.
///
/// For Codex sessions, this data comes from `session_meta` event's `payload.git` field.
/// For other agents, this may be unavailable or partial.
public struct HistoricalGitContext: Equatable {
    /// Git branch name at session start
    public let branch: String?

    /// Full commit hash at session start
    public let commitHash: String?

    /// Whether the working tree was clean (no uncommitted changes)
    public let wasClean: Bool?

    /// List of uncommitted files at session start (if any)
    public let uncommittedFiles: [String]

    /// Working directory at session start
    public let cwd: String

    /// Repository URL (e.g., "https://github.com/user/repo.git")
    public let repositoryURL: String?

    /// When this session was created
    public let sessionCreated: Date

    public init(
        branch: String?,
        commitHash: String?,
        wasClean: Bool?,
        uncommittedFiles: [String] = [],
        cwd: String,
        repositoryURL: String? = nil,
        sessionCreated: Date
    ) {
        self.branch = branch
        self.commitHash = commitHash
        self.wasClean = wasClean
        self.uncommittedFiles = uncommittedFiles
        self.cwd = cwd
        self.repositoryURL = repositoryURL
        self.sessionCreated = sessionCreated
    }

    /// Short commit hash (first 7 characters) for display
    public var shortCommitHash: String? {
        guard let hash = commitHash else { return nil }
        return String(hash.prefix(7))
    }

    /// Human-readable status at session start
    public var statusDescription: String {
        if let clean = wasClean {
            return clean ? "Clean" : "Had uncommitted changes"
        }
        return "Not captured"
    }

    /// Relative time description (e.g., "2 hours ago")
    public var relativeTimeDescription: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: sessionCreated, relativeTo: Date())
    }
}
