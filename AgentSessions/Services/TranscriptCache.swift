import Foundation

/// Thread-safe cache for generated transcripts used in search filtering.
/// Generates transcripts in background on app launch to ensure accurate search results.
final class TranscriptCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [String: String] = [:]
    private var indexingInProgress = false

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Retrieve cached transcript for a session (thread-safe)
    func getCached(_ sessionID: String) -> String? {
        withLock { cache[sessionID] }
    }

    /// Store a generated transcript (thread-safe)
    func set(_ sessionID: String, transcript: String) {
        withLock { cache[sessionID] = transcript }
    }

    /// Generate and cache transcripts for multiple sessions in background
    /// Skips sessions that are already cached or have no events (lightweight sessions)
    func generateAndCache(sessions: [Session]) async {
        // Check if already indexing (avoid concurrent runs)
        let shouldStart = withLock { () -> Bool in
            if indexingInProgress { return false }
            indexingInProgress = true
            return true
        }
        guard shouldStart else { return }
        defer { withLock { indexingInProgress = false } }

        let filters: TranscriptFilters = .current(showTimestamps: false, showMeta: false)
        var indexed = 0

        for session in sessions {
            if FeatureFlags.gatePrewarmWhileTyping && TypingActivity.shared.isUserLikelyTyping {
                // Back off while the user is actively typing to avoid contention
                try? await Task.sleep(nanoseconds: 350_000_000)
                continue
            }
            let alreadyCached = withLock { cache[session.id] != nil }

            // Skip if already cached or lightweight (no events)
            guard !alreadyCached, !session.events.isEmpty else { continue }

            let transcript = SessionTranscriptBuilder.buildPlainTerminalTranscript(
                session: session,
                filters: filters,
                mode: .normal
            )

            withLock { cache[session.id] = transcript }

            indexed += 1

            // Cooperative yield after each item to avoid long bursts
            try? await Task.sleep(nanoseconds: 10_000_000)
            if indexed % 50 == 0 { await Task.yield() }
        }

        let totalCount = withLock { cache.count }

        #if DEBUG
        print("TRANSCRIPT CACHE: Indexed \(indexed) sessions (total cached: \(totalCount))")
        #endif
    }

    /// Clear all cached transcripts (thread-safe)
    func clear() {
        withLock { cache.removeAll() }
    }

    /// Get current cache size (thread-safe)
    func count() -> Int {
        withLock { cache.count }
    }

    /// Check if indexing is currently in progress (thread-safe)
    func isIndexing() -> Bool {
        withLock { indexingInProgress }
    }

    /// Synchronous transcript getter for use in FilterEngine
    /// Returns cached transcript if available, otherwise generates on-demand
    func getOrGenerate(session: Session) -> String {
        // Check cache first
        if let cached = getCached(session.id) {
            return cached
        }

        // Not cached - generate on demand (this is the fallback during initial indexing)
        let filters: TranscriptFilters = .current(showTimestamps: false, showMeta: false)
        let transcript = SessionTranscriptBuilder.buildPlainTerminalTranscript(
            session: session,
            filters: filters,
            mode: .normal
        )

        // Cache for next time
        set(session.id, transcript: transcript)

        return transcript
    }
}
