import Foundation
import Observation

/// Phase 0 / W6. Single owner of block-space state derived from a Session,
/// consumed by both SessionTerminalView and TranscriptBlockListView.
/// Consolidates: coalescedBlocks access, user anchors (eventID -> anchor block),
/// role block indices, whole-session find matches. Line-space state
/// (TerminalLine arrays, visible-line nav caches) intentionally stays in the
/// Terminal view. Pure function of Key; compute off-main, publish in one batch.
@MainActor
@Observable
final class TranscriptDerivedState {

    struct DerivedSettings: Equatable, Sendable {
        var skipAgentsPreamble: Bool
        var reviewCardsEnabled: Bool
    }

    struct Key: Hashable, Sendable {
        var sessionID: String
        var eventCount: Int
        var fileSizeBytes: Int
        var skipAgentsPreamble: Bool
        var reviewCardsEnabled: Bool

        init(session: Session, settings: DerivedSettings) {
            sessionID = session.id
            eventCount = session.events.count
            fileSizeBytes = session.fileSizeBytes ?? -1
            skipAgentsPreamble = settings.skipAgentsPreamble
            reviewCardsEnabled = settings.reviewCardsEnabled
        }
    }

    struct Snapshot: Sendable {
        var blocks: [SessionTranscriptBuilder.LogicalBlock] = []
        var totalBlockCount: Int = 0
        var eventIDToAnchorBlockIndex: [String: Int] = [:]
        var userBlockIndices: [Int] = []
        var toolBlockIndices: [Int] = []
        var errorBlockIndices: [Int] = []
        var preambleUserBlockIndexes: Set<Int> = []
        /// Whole-session tool pairing and status (Task 6), built from `blocks`.
        var invocationIndex: ToolInvocationIndex = .empty
        /// Ids of invocations whose status is `.failed` (the Errors filter's tool half, spec §6.8).
        var failedInvocationIDs: Set<Int> = []
        /// The session's agent (tool decoding depends on it).
        var source: SessionSource = .codex
        var key: Key?
    }

    /// What a match range indexes (Task 15, spec §6.8).
    enum MatchSpace: Equatable, Sendable {
        /// `blocks[i].text`: message blocks, and tool blocks whose invocation is not decoded yet.
        case raw
        /// The decoded search text of the invocation whose id block is `globalBlockIndex`
        /// (`ToolSearchText.text(of:)`): its actions' plain text and footer facts.
        case decoded
    }

    struct BlockMatch: Equatable, Sendable {
        var globalBlockIndex: Int
        /// UTF-16 range into `blocks[i].text` (`.raw`) or into the invocation's search text (`.decoded`).
        var rangeInBlockText: NSRange
        var ordinal: Int
        var space: MatchSpace = .raw
    }

    private(set) var snapshot = Snapshot()
    private(set) var isComputing = false
    private var computeTask: Task<Void, Never>?

    /// Decoded tool text for Find (spec §6.8 cost rule): one pass per snapshot, after the snapshot
    /// landed, off the main thread. Its invocation cache is shared with the Session view's L2 renderer.
    let toolSearchStore: ToolSearchTextStore
    /// A decode pass for the current snapshot is running (the find bar says "Searching tool output…").
    private(set) var isDecodingToolText = false
    /// Bumped once when a decode pass ends: Find re-runs once over the decoded text.
    private(set) var toolTextGeneration = 0
    /// `computeFindMatches` runs (cache misses), for tests.
    @ObservationIgnored private(set) var findComputeCount = 0
    /// Identifies the latest decode request; a stale start or completion is dropped.
    @ObservationIgnored private var toolDecodeRequest = 0

    init(toolSearchStore: ToolSearchTextStore = ToolSearchTextStore()) {
        self.toolSearchStore = toolSearchStore
    }

    /// Find-match memo, keyed by (snapshot key, decode generation, query). Bounded to a few entries
    /// so alternating between two queries (⌘F nav vs. unified search) doesn't
    /// thrash a single-slot cache into a miss on every call.
    private struct FindCacheKey: Hashable {
        var snapshotKey: Key?
        var toolTextGeneration: Int
        var query: String
    }
    private let findMatchesCache = LRUCache<FindCacheKey, [BlockMatch]>(maxEntries: 4)

    /// No-op if key unchanged (same dedupe discipline as shouldSkipRebuild).
    func update(session: Session, settings: DerivedSettings) {
        let key = Key(session: session, settings: settings)
        if key == snapshot.key { return }
        // A session change cancels the decode pass and drops the decoded text (block indices
        // mean another session's blocks now).
        if key.sessionID != snapshot.key?.sessionID { stopToolTextDecode() }
        computeTask?.cancel()
        isComputing = true
        let sessionCopy = session
        computeTask = Task.detached(priority: .userInitiated) { [weak self] in
            let snap = Self.computeSnapshot(session: sessionCopy, settings: settings)
            if Task.isCancelled { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.snapshot = snap
                self.isComputing = false
                self.findMatchesCache.removeAll()   // block content changed
                self.scheduleToolTextDecode()
            }
        }
    }

    // MARK: Decoded tool text (Task 15)

    /// Starts the decode pass for the snapshot that just landed. Opening the session never waits
    /// for it (spec A3): the snapshot is published first, and the pass starts in a later main-actor
    /// turn (after the views took the snapshot) and runs at utility priority, from the tail (where
    /// a session opens) outward. A restart for a live append reuses every unchanged invocation.
    private func scheduleToolTextDecode() {
        toolDecodeRequest &+= 1
        let request = toolDecodeRequest
        let snap = snapshot
        guard let key = snap.key, !snap.invocationIndex.invocations.isEmpty || !snap.toolBlockIndices.isEmpty else {
            isDecodingToolText = false
            return
        }
        isDecodingToolText = true
        Task { @MainActor [weak self] in
            guard let self, self.toolDecodeRequest == request else { return }
            self.toolSearchStore.start(blocks: snap.blocks, index: snap.invocationIndex, source: snap.source,
                                       sessionID: key.sessionID, viewportBlock: max(0, snap.blocks.count - 1)) { [weak self] in
                guard let self, self.toolDecodeRequest == request else { return }
                self.isDecodingToolText = false
                self.toolTextGeneration &+= 1
            }
        }
    }

    private func stopToolTextDecode() {
        toolDecodeRequest &+= 1
        toolSearchStore.cancel()
        isDecodingToolText = false
    }

    /// Pure, off-main-callable. Relocates the block-space parts of
    /// SessionTerminalView.buildRebuildResult (see SessionTerminalView.swift,
    /// the eventIDToAnchorBlockIndex construction inside the whole-session
    /// buildRebuildResult(session:blocks:blockRange:skipAgentsPreamble:enableReviewCards:)).
    nonisolated static func computeSnapshot(session: Session,
                                            settings: DerivedSettings) -> Snapshot {
        let blocks = SessionTranscriptBuilder.coalescedBlocks(for: session, includeMeta: false)
        var snap = Snapshot()
        snap.blocks = blocks
        snap.totalBlockCount = blocks.count
        snap.source = session.source
        snap.key = Key(session: session, settings: settings)

        var userIdx: [Int] = [], toolIdx: [Int] = [], errIdx: [Int] = []
        for b in blocks {
            switch b.kind {
            case .user: userIdx.append(b.globalBlockIndex)
            case .toolCall, .toolOut: toolIdx.append(b.globalBlockIndex)
            case .error: errIdx.append(b.globalBlockIndex)
            case .assistant, .meta: break
            }
        }
        snap.userBlockIndices = userIdx
        snap.toolBlockIndices = toolIdx
        snap.errorBlockIndices = errIdx

        // Tool pairing + cheap status (spec §6.2 pass 1), once per snapshot, off main.
        // Errors stay block-based in `errorBlockIndices`; failed invocations are separate.
        let invocationIndex = ToolInvocationIndex.build(blocks: blocks, source: session.source)
        snap.invocationIndex = invocationIndex
        var failedInvocationIDs: Set<Int> = []
        for invocation in invocationIndex.invocations {
            if case .failed = invocation.status { failedInvocationIDs.insert(invocation.id) }
        }
        snap.failedInvocationIDs = failedInvocationIDs

        snap.preambleUserBlockIndexes = settings.skipAgentsPreamble
            ? SessionTerminalView.computePreambleUserBlockIndexes(session: session, blocks: blocks)
            : []

        // Same anchor derivation buildRebuildResult uses (full-session scope),
        // copied verbatim from SessionTerminalView.buildRebuildResult's
        // eventIDToAnchorBlockIndex construction so the two stay byte-identical.
        var eventIDToAnchorBlockIndex: [String: Int] = [:]
        if !blocks.isEmpty {
            // Re-derived here as array OFFSETS (rather than reusing
            // snap.userBlockIndices, which stores globalBlockIndex values) —
            // the two are provably equal for this full coalesced stream, since
            // `blocks` is the whole session with no filtering, so a block's
            // array position always equals its globalBlockIndex.
            let userBlockIndices = blocks.enumerated().compactMap { $0.element.kind == .user ? $0.offset : nil }
            let anchors = TranscriptUserAnchors.anchors(userBlockIndices: userBlockIndices,
                                                        preambleUserBlockIndexes: snap.preambleUserBlockIndexes,
                                                        blockCount: blocks.count)

            for (idx, block) in blocks.enumerated() {
                let targetUserBlockOffset: Int? = block.kind == .user ? idx : anchors[idx]
                guard let targetUserBlockOffset,
                      blocks.indices.contains(targetUserBlockOffset) else { continue }
                // firstLineForBlock (Terminal-view line-space) is keyed by
                // globalBlockIndex too, so this lookup key stays valid even
                // though this derived-state layer never builds lines.
                let lookupKey = blocks[targetUserBlockOffset].globalBlockIndex
                eventIDToAnchorBlockIndex[block.eventID] = lookupKey
            }
        }
        snap.eventIDToAnchorBlockIndex = eventIDToAnchorBlockIndex
        return snap
    }

    func findMatches(query: String) -> [BlockMatch] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        // Reading `toolTextGeneration` here (an observed property) makes a view that asks for
        // matches update again when a decode pass ends, so Find re-runs exactly once.
        let cacheKey = FindCacheKey(snapshotKey: snapshot.key, toolTextGeneration: toolTextGeneration, query: q)
        if let cached = findMatchesCache.get(cacheKey) { return cached }
        findComputeCount += 1
        let store = toolSearchStore
        let matches = Self.computeFindMatches(blocks: snapshot.blocks, query: q, toolText: store.text(forBlock:))
        findMatchesCache.set(cacheKey, matches)
        return matches
    }

    /// Per-block ranges via the SAME matcher the shipped whole-session scan
    /// uses (SessionTerminalView.scanSessionBlocks) so Rich-mode counts agree
    /// with Terminal-mode counts for the same query.
    ///
    /// Task 15 (spec §6.8): `toolText` gives a tool block's decoded search text
    /// (`ToolSearchTextStore.text(forBlock:)`): the whole invocation's text at its id block ("" at
    /// its other blocks), matched in `.decoded` space. Where it returns nil (a message block, or
    /// an invocation not decoded yet) the raw block text is searched, in `.raw` space.
    nonisolated static func computeFindMatches(
        blocks: [SessionTranscriptBuilder.LogicalBlock],
        query: String,
        toolText: ((Int) -> String?)? = nil) -> [BlockMatch] {
        var out: [BlockMatch] = []
        var ordinal = 0
        for block in blocks {
            if let toolText, let decoded = toolText(block.globalBlockIndex) {
                guard !decoded.isEmpty else { continue }
                for r in SearchTextMatcher.matchRanges(in: decoded, query: query) {
                    out.append(BlockMatch(globalBlockIndex: block.globalBlockIndex,
                                          rangeInBlockText: r, ordinal: ordinal, space: .decoded))
                    ordinal += 1
                }
                continue
            }
            for r in SearchTextMatcher.matchRanges(in: block.text, query: query) {
                out.append(BlockMatch(globalBlockIndex: block.globalBlockIndex,
                                      rangeInBlockText: r, ordinal: ordinal))
                ordinal += 1
            }
        }
        return out
    }
}
