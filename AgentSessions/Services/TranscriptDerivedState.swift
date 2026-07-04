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

    struct Key: Equatable, Sendable {
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
        var key: Key?
    }

    struct BlockMatch: Equatable, Sendable {
        var globalBlockIndex: Int
        var rangeInBlockText: NSRange   // UTF-16 range into blocks[i].text
        var ordinal: Int
    }

    private(set) var snapshot = Snapshot()
    private(set) var isComputing = false
    private var computeTask: Task<Void, Never>?

    // Find-match memo (query -> matches for the current snapshot key)
    private var cachedFindQuery: String?
    private var cachedFindKey: Key?
    private var cachedFindMatches: [BlockMatch] = []

    /// No-op if key unchanged (same dedupe discipline as shouldSkipRebuild).
    func update(session: Session, settings: DerivedSettings) {
        let key = Key(session: session, settings: settings)
        if key == snapshot.key { return }
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
                self.cachedFindQuery = nil   // block content changed
            }
        }
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
        if q == cachedFindQuery, cachedFindKey == snapshot.key { return cachedFindMatches }
        let matches = Self.computeFindMatches(blocks: snapshot.blocks, query: q)
        cachedFindQuery = q
        cachedFindKey = snapshot.key
        cachedFindMatches = matches
        return matches
    }

    /// Per-block ranges via the SAME matcher the shipped whole-session scan
    /// uses (SessionTerminalView.scanSessionBlocks) so Rich-mode counts agree
    /// with Terminal-mode counts for the same query.
    nonisolated static func computeFindMatches(
        blocks: [SessionTranscriptBuilder.LogicalBlock],
        query: String) -> [BlockMatch] {
        var out: [BlockMatch] = []
        var ordinal = 0
        for block in blocks {
            for r in SearchTextMatcher.matchRanges(in: block.text, query: query) {
                out.append(BlockMatch(globalBlockIndex: block.globalBlockIndex,
                                      rangeInBlockText: r, ordinal: ordinal))
                ordinal += 1
            }
        }
        return out
    }
}
