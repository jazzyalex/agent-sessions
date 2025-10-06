import Foundation

/// Thread-safe cache for generated transcripts used in search filtering.
/// Generates transcripts in background on app launch to ensure accurate search results.
final class TranscriptCache {
    private let lock = NSLock()
    private var cache: [String: String] = [:]
    private var indexingInProgress = false

    /// Retrieve cached transcript for a session (thread-safe)
    func getCached(_ sessionID: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return cache[sessionID]
    }

    /// Store a generated transcript (thread-safe)
    func set(_ sessionID: String, transcript: String) {
        lock.lock()
        defer { lock.unlock() }
        cache[sessionID] = transcript
    }

    /// Generate and cache transcripts for multiple sessions in background
    /// Skips sessions that are already cached or have no events (lightweight sessions)
    func generateAndCache(sessions: [Session]) async {
        // Check if already indexing (avoid concurrent runs)
        await MainActor.run {
            lock.lock()
            let wasIndexing = indexingInProgress
            if !wasIndexing {
                indexingInProgress = true
            }
            lock.unlock()

            guard !wasIndexing else { return }
        }

        let filters: TranscriptFilters = .current(showTimestamps: false, showMeta: false)
        var indexed = 0

        for session in sessions {
            // Check if already cached (thread-safe)
            let alreadyCached = await MainActor.run {
                lock.lock()
                defer { lock.unlock() }
                return cache[session.id] != nil
            }

            // Skip if already cached or lightweight (no events)
            guard !alreadyCached, !session.events.isEmpty else { continue }

            let transcript = SessionTranscriptBuilder.buildPlainTerminalTranscript(
                session: session,
                filters: filters,
                mode: .normal
            )

            await MainActor.run {
                lock.lock()
                cache[session.id] = transcript
                lock.unlock()
            }

            indexed += 1

            // Yield periodically to avoid blocking
            if indexed % 50 == 0 {
                await Task.yield()
            }
        }

        let totalCount = await MainActor.run {
            lock.lock()
            indexingInProgress = false
            let count = cache.count
            lock.unlock()
            return count
        }

        print("📝 TRANSCRIPT CACHE: Indexed \(indexed) sessions (total cached: \(totalCount))")
    }

    /// Clear all cached transcripts (thread-safe)
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        cache.removeAll()
    }

    /// Get current cache size (thread-safe)
    func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return cache.count
    }

    /// Check if indexing is currently in progress (thread-safe)
    func isIndexing() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return indexingInProgress
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
