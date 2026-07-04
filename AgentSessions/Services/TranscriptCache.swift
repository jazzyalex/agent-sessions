import Foundation

/// Thread-safe cache for generated transcripts used in search filtering.
/// The cache is bounded so long-running indexing sessions do not grow memory
/// without limit.
///
/// Storage/eviction is delegated to the generic `LRUCache` (O(1) LRU with a
/// count cap of 512 and a 64 MB total-cost cap keyed on transcript UTF-8 byte
/// length). The `indexingInProgress` bookkeeping stays local here.
final class TranscriptCache: @unchecked Sendable {
    private let store = LRUCache<String, String>(
        maxEntries: 512,
        maxTotalCost: 64 * 1024 * 1024,
        cost: { $0.utf8.count }
    )

    private let indexingLock = NSLock()
    private var indexingInProgress = false

    private func withIndexingLock<T>(_ body: () -> T) -> T {
        indexingLock.lock()
        defer { indexingLock.unlock() }
        return body()
    }

    /// Retrieve cached transcript for a session (thread-safe)
    func getCached(_ sessionID: String) -> String? {
        store.get(sessionID)
    }

    /// Store a generated transcript (thread-safe)
    func set(_ sessionID: String, transcript: String) {
        store.set(sessionID, transcript)
    }

    /// Remove a single cached transcript (thread-safe)
    func remove(_ sessionID: String) {
        store.remove(sessionID)
    }

    /// Generate and cache transcripts for multiple sessions in background
    /// Skips sessions that are already cached or have no events (lightweight sessions)
    func generateAndCache(sessions: [Session]) async {
        // Check if already indexing (avoid concurrent runs)
        let shouldStart = withIndexingLock { () -> Bool in
            if indexingInProgress { return false }
            indexingInProgress = true
            return true
        }
        guard shouldStart else { return }
        defer { withIndexingLock { indexingInProgress = false } }

        let filters: TranscriptFilters = .current(showTimestamps: false, showMeta: false)
        var indexed = 0

        for session in sessions {
            if Task.isCancelled { break }
            // Back off while the user is actively typing to avoid contention, but
            // WAIT for idle rather than `continue` (which would drop this session
            // from the batch entirely — it would never be indexed until the next run).
            while FeatureFlags.gatePrewarmWhileTyping && TypingActivity.shared.isUserLikelyTyping {
                try? await Task.sleep(nanoseconds: 350_000_000)
                if Task.isCancelled { break }
            }
            if Task.isCancelled { break }
            let alreadyCached = store.contains(session.id)

            // Skip if already cached or lightweight (no events)
            guard !alreadyCached, !session.events.isEmpty else { continue }
            if Task.isCancelled { break }

            let transcript = SessionTranscriptBuilder.buildPlainTerminalTranscript(
                session: session,
                filters: filters,
                mode: .normal
            )
            if Task.isCancelled { break }

            set(session.id, transcript: transcript)

            indexed += 1

            // Cooperative yield after each item to avoid long bursts
            try? await Task.sleep(nanoseconds: 10_000_000)
            if Task.isCancelled { break }
            if indexed % 50 == 0 {
                await Task.yield()
                if Task.isCancelled { break }
            }
        }

        let totalCount = store.count

        #if DEBUG
        print("TRANSCRIPT CACHE: Indexed \(indexed) sessions (total cached: \(totalCount))")
        #endif
    }

    /// Clear all cached transcripts (thread-safe)
    func clear() {
        store.removeAll()
    }

    /// Get current cache size (thread-safe)
    func count() -> Int {
        store.count
    }

    /// Check if indexing is currently in progress (thread-safe)
    func isIndexing() -> Bool {
        withIndexingLock { indexingInProgress }
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
