import Foundation

/// Extracts historical git context from Codex session files
struct GitContextExtractor {
    /// Extract historical git context from a Codex session
    /// - Parameter session: The session to extract from
    /// - Returns: Historical git context if available, nil otherwise
    static func extractHistorical(from session: Session) -> HistoricalGitContext? {
        // Historical snapshot is currently supported for Codex sessions only.
        guard session.source == .codex else { return nil }
        guard let cwd = session.cwd else { return nil }

        let sessionCreated = session.startTime ?? session.modifiedAt

        // Fast path: if events are loaded and first event contains payload.git, use it.
        if let firstEvent = session.events.first,
           let data = firstEvent.rawJSON.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let payload = json["payload"] as? [String: Any],
           let git = payload["git"] as? [String: Any] {
            return makeHistorical(from: git, cwd: cwd, created: sessionCreated)
        }

        // Lightweight session (no events loaded): read the first few JSONL lines directly from file.
        // We only need payload.git; avoid full parse.
        let path = session.filePath
        if let handle = FileHandle(forReadingAtPath: path) {
            defer { try? handle.close() }
            // Read the first ~64KB which easily covers a few lines
            let chunk = try? handle.read(upToCount: 64 * 1024) ?? Data()
            if let chunk, let text = String(data: chunk, encoding: .utf8) {
                // Inspect up to first 5 lines
                for line in text.split(separator: "\n").prefix(5) {
                    if let data = String(line).data(using: .utf8),
                       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let payload = obj["payload"] as? [String: Any],
                       let git = payload["git"] as? [String: Any] {
                        return makeHistorical(from: git, cwd: cwd, created: sessionCreated)
                    }
                }
            }
        }

        // As a final fallback, try to heuristically infer branch from early content when events are present.
        if let b = session.gitBranch {
            return HistoricalGitContext(
                branch: b,
                commitHash: nil,
                wasClean: nil,
                uncommittedFiles: [],
                cwd: cwd,
                repositoryURL: nil,
                sessionCreated: sessionCreated
            )
        }
        return nil
    }

    private static func makeHistorical(from git: [String: Any], cwd: String, created: Date) -> HistoricalGitContext {
        let branch = git["branch"] as? String
        let commitHash = git["commit_hash"] as? String
        let wasClean = git["is_clean"] as? Bool
        let repositoryURL = git["repository_url"] as? String
        var uncommittedFiles: [String] = []
        if let changes = git["uncommitted_changes"] as? [[String: Any]] {
            uncommittedFiles = changes.compactMap { $0["path"] as? String }
        }
        return HistoricalGitContext(
            branch: branch,
            commitHash: commitHash,
            wasClean: wasClean,
            uncommittedFiles: uncommittedFiles,
            cwd: cwd,
            repositoryURL: repositoryURL,
            sessionCreated: created
        )
    }
}

/// Extension to Session model for easy access to historical git context
extension Session {
    /// Historical git context for this session (Codex only)
    var historicalGitContext: HistoricalGitContext? {
        GitContextExtractor.extractHistorical(from: self)
    }
}
