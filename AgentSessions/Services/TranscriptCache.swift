import Foundation

/// Thread-safe cache for generated transcripts used in search filtering.
/// The cache is bounded so long-running indexing sessions do not grow memory
/// without limit.
final class TranscriptCache: @unchecked Sendable {
    private struct Entry {
        let transcript: String
        let cost: Int
        var lastAccess: UInt64
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var totalCost: Int = 0
    private var accessSerial: UInt64 = 0
    private var indexingInProgress = false

    private let maxEntries = 512
    private let maxTotalCost = 64 * 1024 * 1024

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func nextAccessSerial() -> UInt64 {
        accessSerial &+= 1
        return accessSerial
    }

    private func evictIfNeeded() {
        while entries.count > maxEntries || totalCost > maxTotalCost {
            guard let oldestKey = entries.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key else {
                break
            }
            if let removed = entries.removeValue(forKey: oldestKey) {
                totalCost = max(0, totalCost - removed.cost)
            }
        }
    }

    /// Retrieve cached transcript for a session (thread-safe)
    func getCached(_ sessionID: String) -> String? {
        withLock {
            guard var entry = entries[sessionID] else { return nil }
            entry.lastAccess = nextAccessSerial()
            entries[sessionID] = entry
            return entry.transcript
        }
    }

    /// Store a generated transcript (thread-safe)
    func set(_ sessionID: String, transcript: String) {
        withLock {
            let cost = max(1, transcript.utf8.count)
            if let existing = entries[sessionID] {
                totalCost = max(0, totalCost - existing.cost)
            }
            entries[sessionID] = Entry(
                transcript: transcript,
                cost: cost,
                lastAccess: nextAccessSerial()
            )
            totalCost += cost
            evictIfNeeded()
        }
    }

    /// Remove a single cached transcript (thread-safe)
    func remove(_ sessionID: String) {
        withLock {
            guard let removed = entries.removeValue(forKey: sessionID) else { return }
            totalCost = max(0, totalCost - removed.cost)
        }
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
            if Task.isCancelled { break }
            if FeatureFlags.gatePrewarmWhileTyping && TypingActivity.shared.isUserLikelyTyping {
                // Back off while the user is actively typing to avoid contention
                try? await Task.sleep(nanoseconds: 350_000_000)
                if Task.isCancelled { break }
                continue
            }
            let alreadyCached = withLock { entries[session.id] != nil }

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

        let totalCount = withLock { entries.count }

        #if DEBUG
        print("TRANSCRIPT CACHE: Indexed \(indexed) sessions (total cached: \(totalCount))")
        #endif
    }

    /// Clear all cached transcripts (thread-safe)
    func clear() {
        withLock {
            entries.removeAll()
            totalCost = 0
        }
    }

    /// Get current cache size (thread-safe)
    func count() -> Int {
        withLock { entries.count }
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
