import Foundation
import Combine

// Actor for thread-safe promotion state
private actor PromotionState {
    private var promotedID: String?

    func setPromoted(id: String) {
        promotedID = id
    }

    func consumePromoted() -> String? {
        let id = promotedID
        promotedID = nil
        return id
    }
}

final class SearchCoordinator: ObservableObject {
    struct Progress: Equatable {
        enum Phase { case idle, small, large }
        var phase: Phase = .idle
        var scannedSmall: Int = 0
        var totalSmall: Int = 0
        var scannedLarge: Int = 0
        var totalLarge: Int = 0
    }

    @Published private(set) var isRunning: Bool = false
    @Published private(set) var wasCanceled: Bool = false
    @Published private(set) var results: [Session] = []
    @Published private(set) var progress: Progress = .init()

    private var currentTask: Task<Void, Never>? = nil
    private let codexIndexer: SessionIndexer
    private let claudeIndexer: ClaudeSessionIndexer
    private let geminiIndexer: GeminiSessionIndexer
    // Promotion support for large-queue preemption
    private let promotionState = PromotionState()
    // Generation token to ignore stale appends after cancel/restart
    private var runID = UUID()

    init(codexIndexer: SessionIndexer, claudeIndexer: ClaudeSessionIndexer, geminiIndexer: GeminiSessionIndexer) {
        self.codexIndexer = codexIndexer
        self.claudeIndexer = claudeIndexer
        self.geminiIndexer = geminiIndexer
    }

    // Get appropriate transcript cache based on session source
    private func transcriptCache(for source: SessionSource) -> TranscriptCache {
        switch source {
        case .codex: return codexIndexer.searchTranscriptCache
        case .claude: return claudeIndexer.searchTranscriptCache
        case .gemini: return geminiIndexer.searchTranscriptCache
        }
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.runID = UUID()
            self.isRunning = false
            self.wasCanceled = true
            self.progress = .init()
            self.results = []
        }
    }

    // Promote a large session to be processed next in the large queue if present.
    func promote(id: String) {
        Task {
            await promotionState.setPromoted(id: id)
        }
    }

    func start(query: String, filters: Filters, includeCodex: Bool, includeClaude: Bool, includeGemini: Bool, all: [Session]) {
        // Cancel any in-flight search
        currentTask?.cancel()
        wasCanceled = false
        let newRunID = UUID()
        runID = newRunID

        let allowed: Set<SessionSource> = {
            var set = Set<SessionSource>()
            if includeCodex { set.insert(.codex) }
            if includeClaude { set.insert(.claude) }
            if includeGemini { set.insert(.gemini) }
            return set
        }()
        let candidates = all.filter { allowed.contains($0.source) }

        // Partition
        let threshold = 10 * 1024 * 1024
        var nonLarge: [Session] = []
        var large: [Session] = []
        nonLarge.reserveCapacity(candidates.count)
        large.reserveCapacity(candidates.count / 2)
        for s in candidates {
            let size = Self.sizeBytes(for: s)
            if size >= threshold { large.append(s) } else { nonLarge.append(s) }
        }
        nonLarge.sort { $0.modifiedAt > $1.modifiedAt }
        large.sort { $0.modifiedAt > $1.modifiedAt }

        // Launch orchestration
        // Capture counts to avoid capturing mutable arrays
        let nonLargeCount = nonLarge.count
        let largeCount = large.count

        currentTask = Task.detached { [weak self, newRunID] in
            guard let self else { return }
            await MainActor.run {
                guard self.runID == newRunID else { return }
                self.isRunning = true
                self.results = []
                self.progress = .init(phase: .small, scannedSmall: 0, totalSmall: nonLargeCount, scannedLarge: 0, totalLarge: largeCount)
            }

            // Phase 1: nonLarge batched
            let batchSize = 64
            var seen = Set<String>()
            for start in stride(from: 0, to: nonLarge.count, by: batchSize) {
                if Task.isCancelled { await self.finishCanceled(); return }
                let end = min(start + batchSize, nonLarge.count)
                let batch = Array(nonLarge[start..<end])
                let hits = await self.searchBatch(batch: batch, query: query, filters: filters, threshold: threshold)
                if Task.isCancelled { await self.finishCanceled(); return }

                // Filter out duplicates before entering MainActor
                let newHits = hits.filter { !seen.contains($0.id) }
                for s in newHits { seen.insert(s.id) }

                await MainActor.run {
                    guard self.runID == newRunID else { return }
                    self.results.append(contentsOf: newHits)
                    self.progress.scannedSmall += batch.count
                }
            }

            if Task.isCancelled { await self.finishCanceled(); return }

            // Phase 2: large sequential
            await MainActor.run { if self.runID == newRunID { self.progress.phase = .large } }
            var idx = 0
            while idx < large.count {
                // Check for promotion request and reorder so promoted item is next.
                let want = await self.promotionState.consumePromoted()

                if let want, let pos = large[idx...].firstIndex(where: { $0.id == want }) {
                    if pos != idx { large.swapAt(idx, pos) }
                }

                let s = large[idx]
                if Task.isCancelled { await self.finishCanceled(); return }
                if let parsed = await self.parseFullIfNeeded(session: s, threshold: threshold) {
                    if Task.isCancelled { await self.finishCanceled(); return }

                    // Persist parsed session in canonical allSessions (fixes message count reversion bug)
                    // This ensures message counts remain visible even after search is cleared
                    await MainActor.run {
                        if parsed.source == .codex {
                            self.codexIndexer.updateSession(parsed)
                            print("📊 Search updated Codex session: \(parsed.id.prefix(8)) → \(parsed.messageCount) msgs")
                        } else if parsed.source == .claude {
                            self.claudeIndexer.updateSession(parsed)
                            print("📊 Search updated Claude session: \(parsed.id.prefix(8)) → \(parsed.messageCount) msgs")
                        } else {
                            self.geminiIndexer.updateSession(parsed)
                            print("📊 Search updated Gemini session: \(parsed.id.prefix(8)) → \(parsed.messageCount) msgs")
                        }
                    }

                    let cache = self.transcriptCache(for: parsed.source)
                    if FilterEngine.sessionMatches(parsed, filters: filters, transcriptCache: cache) {
                        // Check and update seen outside MainActor
                        let shouldAdd = !seen.contains(parsed.id)
                        if shouldAdd {
                            seen.insert(parsed.id)
                            await MainActor.run {
                                guard self.runID == newRunID else { return }
                                self.results.append(parsed)
                            }
                        }
                    }
                }
                await MainActor.run { if self.runID == newRunID { self.progress.scannedLarge += 1 } }
                idx += 1
            }

            if Task.isCancelled { await self.finishCanceled(); return }
            await MainActor.run {
                guard self.runID == newRunID else { return }
                self.isRunning = false
                self.progress.phase = .idle
            }
        }
    }

    private func finishCanceled() async {
        await MainActor.run {
            self.isRunning = false
            self.wasCanceled = true
            self.progress.phase = .idle
        }
    }

    private func searchBatch(batch: [Session], query: String, filters: Filters, threshold: Int) async -> [Session] {
        var out: [Session] = []
        out.reserveCapacity(batch.count / 4)
        for var s in batch {
            if Task.isCancelled { return out }
            if s.events.isEmpty {
                // For non-large sessions only, parse quickly if needed
                let size = Self.sizeBytes(for: s)
                if size < threshold, let parsed = await parseFullIfNeeded(session: s, threshold: threshold) {
                    s = parsed

                    // Persist parsed session in canonical allSessions (same as Phase 2)
                    await MainActor.run {
                        if parsed.source == .codex {
                            self.codexIndexer.updateSession(parsed)
                        } else if parsed.source == .claude {
                            self.claudeIndexer.updateSession(parsed)
                        } else {
                            self.geminiIndexer.updateSession(parsed)
                        }
                    }
                }
            }
            let cache = self.transcriptCache(for: s.source)
            if FilterEngine.sessionMatches(s, filters: filters, transcriptCache: cache) { out.append(s) }
        }
        return out
    }

    private func parseFullIfNeeded(session s: Session, threshold: Int) async -> Session? {
        if !s.events.isEmpty { return s }
        let url = URL(fileURLWithPath: s.filePath)
        let source = s.source

        // Capture indexer as nonisolated(unsafe) for use in detached task
        // This is safe because parseFileFull is a stateless operation
        nonisolated(unsafe) let codex = self.codexIndexer

        // Parse on background queue using Task instead of DispatchQueue to maintain isolation
        let prio: TaskPriority = FeatureFlags.lowerQoSForHeavyWork ? .utility : .userInitiated
        return await Task.detached(priority: prio) {
            switch source {
            case .codex:
                return codex.parseFileFull(at: url)
            case .claude:
                return ClaudeSessionParser.parseFileFull(at: url)
            case .gemini:
                return GeminiSessionParser.parseFileFull(at: url)
            }
        }.value
    }

    private static func sizeBytes(for s: Session) -> Int {
        if let b = s.fileSizeBytes { return b }
        let p = s.filePath
        if let num = (try? FileManager.default.attributesOfItem(atPath: p)[.size] as? NSNumber)?.intValue { return num }
        return 0
    }
}

extension Array {
    func chunks(of n: Int) -> [ArraySlice<Element>] {
        guard n > 0 else { return [self[...]] }
        return stride(from: 0, to: count, by: n).map { self[$0..<Swift.min($0 + n, count)] }
    }
}
