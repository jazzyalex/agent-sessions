import Foundation

/// Current git status from live CLI queries
/// This represents the real-time state of the repository when the inspector is opened.
public struct CurrentGitStatus: Equatable, Sendable {
    /// Current branch name
    public let branch: String?

    /// Full commit hash at HEAD
    public let commitHash: String?

    /// Whether the working tree has uncommitted changes
    public let isDirty: Bool

    /// List of files with uncommitted changes
    public let dirtyFiles: [GitFileStatus]

    /// Last commit message
    public let lastCommitMessage: String?

    /// Number of commits ahead of origin (if tracking remote)
    public let aheadCount: Int?

    /// Number of commits behind origin (if tracking remote)
    public let behindCount: Int?

    /// When this status was queried
    public let queriedAt: Date

    public init(
        branch: String?,
        commitHash: String?,
        isDirty: Bool,
        dirtyFiles: [GitFileStatus],
        lastCommitMessage: String? = nil,
        aheadCount: Int? = nil,
        behindCount: Int? = nil,
        queriedAt: Date = Date()
    ) {
        self.branch = branch
        self.commitHash = commitHash
        self.isDirty = isDirty
        self.dirtyFiles = dirtyFiles
        self.lastCommitMessage = lastCommitMessage
        self.aheadCount = aheadCount
        self.behindCount = behindCount
        self.queriedAt = queriedAt
    }

    /// Short commit hash (first 7 characters) for display
    public var shortCommitHash: String? {
        guard let hash = commitHash else { return nil }
        return String(hash.prefix(7))
    }

    /// Human-readable status description
    public var statusDescription: String {
        if isDirty {
            let count = dirtyFiles.count
            return count == 1 ? "Dirty (1 file)" : "Dirty (\(count) files)"
        }
        return "Clean"
    }

    /// Tracking status description (e.g., "↓ 2 commits behind")
    public var trackingDescription: String? {
        let ahead = aheadCount ?? 0
        let behind = behindCount ?? 0

        if ahead > 0 && behind > 0 {
            return "↑ \(ahead), ↓ \(behind)"
        } else if ahead > 0 {
            return "↑ \(ahead) ahead"
        } else if behind > 0 {
            return "↓ \(behind) behind"
        }
        return nil
    }

    /// Whether this status is stale (older than 5 minutes)
    public var isStale: Bool {
        Date().timeIntervalSince(queriedAt) > 300
    }

    /// Relative time description (e.g., "2 minutes ago")
    public var relativeTimeDescription: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: queriedAt, relativeTo: Date())
    }
}
