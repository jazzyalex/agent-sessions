import Foundation

/// Thread-safe cache for generated transcripts used in search filtering.
/// The cache is bounded so long-running indexing sessions do not grow memory
/// without limit.
///
/// Eviction is least-recently-used and O(1): entries live in an intrusive
/// doubly-linked list (most-recently-used at `head`, least at `tail`), so a
/// `set` that overflows a cap drops the tail without scanning the whole map.
/// `prev` is weak so the list holds no retain cycles.
final class TranscriptCache: @unchecked Sendable {
    private final class Node {
        let key: String
        var transcript: String
        var cost: Int
        var next: Node?
        weak var prev: Node?

        init(key: String, transcript: String, cost: Int) {
            self.key = key
            self.transcript = transcript
            self.cost = cost
        }
    }

    private let lock = NSLock()
    private var nodes: [String: Node] = [:]
    private var head: Node?              // most recently used
    private var tail: Node?              // least recently used
    private var totalCost: Int = 0
    private var indexingInProgress = false

    private let maxEntries = 512
    private let maxTotalCost = 64 * 1024 * 1024

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: - Intrusive LRU list (all callers must hold `lock`)

    private func addToFront(_ node: Node) {
        node.prev = nil
        node.next = head
        head?.prev = node
        head = node
        if tail == nil { tail = node }
    }

    private func detach(_ node: Node) {
        let p = node.prev
        let n = node.next
        p?.next = n
        n?.prev = p
        if head === node { head = n }
        if tail === node { tail = p }
        node.prev = nil
        node.next = nil
    }

    private func moveToFront(_ node: Node) {
        guard head !== node else { return }
        detach(node)
        addToFront(node)
    }

    private func removeNode(_ node: Node) {
        detach(node)
        nodes.removeValue(forKey: node.key)
        totalCost = max(0, totalCost - node.cost)
    }

    private func evictIfNeeded() {
        while nodes.count > maxEntries || totalCost > maxTotalCost {
            guard let lru = tail else { break }
            removeNode(lru)
        }
    }

    /// Retrieve cached transcript for a session (thread-safe)
    func getCached(_ sessionID: String) -> String? {
        withLock {
            guard let node = nodes[sessionID] else { return nil }
            moveToFront(node)
            return node.transcript
        }
    }

    /// Store a generated transcript (thread-safe)
    func set(_ sessionID: String, transcript: String) {
        withLock {
            let cost = max(1, transcript.utf8.count)
            if let existing = nodes[sessionID] {
                totalCost = max(0, totalCost - existing.cost)
                existing.transcript = transcript
                existing.cost = cost
                totalCost += cost
                moveToFront(existing)
            } else {
                let node = Node(key: sessionID, transcript: transcript, cost: cost)
                nodes[sessionID] = node
                addToFront(node)
                totalCost += cost
            }
            evictIfNeeded()
        }
    }

    /// Remove a single cached transcript (thread-safe)
    func remove(_ sessionID: String) {
        withLock {
            guard let node = nodes[sessionID] else { return }
            removeNode(node)
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
            let alreadyCached = withLock { nodes[session.id] != nil }

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

        let totalCount = withLock { nodes.count }

        #if DEBUG
        print("TRANSCRIPT CACHE: Indexed \(indexed) sessions (total cached: \(totalCount))")
        #endif
    }

    /// Clear all cached transcripts (thread-safe)
    func clear() {
        withLock {
            nodes.removeAll()
            head = nil
            tail = nil
            totalCost = 0
        }
    }

    /// Get current cache size (thread-safe)
    func count() -> Int {
        withLock { nodes.count }
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
