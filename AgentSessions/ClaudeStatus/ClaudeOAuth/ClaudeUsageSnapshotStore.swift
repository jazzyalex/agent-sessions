import Foundation
import os.log

private let log = OSLog(subsystem: "com.triada.AgentSessions", category: "ClaudeOAuth")

// MARK: - Snapshot Store
//
// Persists the latest ClaudeLimitSnapshot to disk for cold-start restore.
// Writes are atomic. Never blocks the UI — all I/O on the actor's executor.

actor ClaudeUsageSnapshotStore {
    private let fileURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let dir = appSupport?.appendingPathComponent("com.triada.AgentSessions", isDirectory: true)
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/com.triada.AgentSessions")
        self.fileURL = dir.appendingPathComponent("claude_usage_latest.json")
    }

    /// Test-only: use a custom file path to avoid touching real app data.
    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func save(_ snapshot: ClaudeLimitSnapshot) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(snapshot) else {
            os_log("ClaudeOAuth: snapshot encode failed", log: log, type: .error)
            return
        }
        let url = fileURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            os_log("ClaudeOAuth: snapshot saved to disk", log: log, type: .debug)
        } catch {
            os_log("ClaudeOAuth: snapshot write failed: %{public}@", log: log, type: .error, error.localizedDescription)
        }
    }

    func load() -> ClaudeLimitSnapshot? {
        let url = fileURL
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let snapshot = try? decoder.decode(ClaudeLimitSnapshot.self, from: data) else {
            os_log("ClaudeOAuth: snapshot decode failed", log: log, type: .error)
            return nil
        }
        os_log("ClaudeOAuth: snapshot loaded from disk (age %.0fs)", log: log, type: .debug,
               Date().timeIntervalSince(snapshot.fetchedAt))
        return snapshot
    }
}
