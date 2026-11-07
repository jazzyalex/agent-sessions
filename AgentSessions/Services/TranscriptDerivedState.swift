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
        /// Legacy block-level lists: the ▲▼ jumps and their enabled state use `toolJumpIDs` /
        /// `errorJumpIDs`. `toolBlockIndices` still gates the tool decode pass; `errorBlockIndices`
        /// is only read by tests.
        var toolBlockIndices: [Int] = []
        var errorBlockIndices: [Int] = []
        var preambleUserBlockIndexes: Set<Int> = []
        /// Whole-session tool pairing and status (Task 6), built from `blocks`.
        var invocationIndex: ToolInvocationIndex = .empty
        /// Ids of invocations whose status is `.failed` (the Errors filter's tool half, spec §6.8).
        var failedInvocationIDs: Set<Int> = []
        /// ▲▼ stops of the Tools filter (Task 16, spec §6.8): invocation ids, ascending.
        var toolJumpIDs: [Int] = []
        /// ▲▼ stops of the Errors filter: `.error` blocks that belong to no invocation, plus failed
        /// invocation ids (a paired `.error` block is its invocation's stop, not a second one), ascending.
        var errorJumpIDs: [Int] = []
        /// L1 summaries of the invocations in the tail window (the window the Session view opens
        /// at), by invocation id, built off the main thread (`tailRowSummaries`). The Session
        /// view seeds its summary cache from them, so its first rows need no input parse on main.
        var rowSummaries: [Int: RowSummaryEntry] = [:]
        /// The session's agent (tool decoding depends on it).
        var source: SessionSource = .codex
        var key: Key?
    }

    /// One L1 summary and what it was built from: valid while the invocation's content stamp
    /// (`ToolSearchTextStore.contentStamp`) and status are the same.
    struct RowSummaryEntry: Equatable, Sendable {
        var stamp: Int
        var status: ToolStatus
        var summary: ToolRowSummary
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
    /// A decode pass for the current snapshot has been running for more than
    /// `toolTextLabelDelayNanoseconds` (the find bar says "Searching tool output…"). A short pass, such as
    /// the few invocations of a live append, never sets it.
    private(set) var isDecodingToolText = false
    /// Bumped once when a decode pass that decoded something ends: Find re-runs once over the
    /// decoded text.
    private(set) var toolTextGeneration = 0
    /// `computeFindMatches` runs (cache misses), for tests.
    @ObservationIgnored private(set) var findComputeCount = 0
    /// Identifies the latest decode request; a stale start or completion is dropped.
    @ObservationIgnored private var toolDecodeRequest = 0
    /// Only the Session view's Find uses decoded tool text, so the pass runs only while that view
    /// asks for it (`setDecodesToolText`).
    @ObservationIgnored private var decodesToolText: Bool
    @ObservationIgnored private var toolDecodePassRunning = false
    /// The Session view's first visible block, read when a pass starts: the pass decodes from
    /// there outward. Nil (or no provider): the tail, where a session opens.
    @ObservationIgnored var toolDecodeViewportProvider: (@MainActor () -> Int?)?

    /// A live append decodes at most this many changed invocations (and this much raw member
    /// text, UTF-16) in the snapshot task, so the Find scan at landing is final; the rest goes to
    /// the background pass.
    nonisolated static let landingDecodeLimit = 8
    nonisolated static let landingDecodeBudget = 512 * 1024
    /// A pass shorter than this never shows "Searching tool output…".
    static let toolTextLabelDelayNanoseconds: UInt64 = 300_000_000

    init(toolSearchStore: ToolSearchTextStore = ToolSearchTextStore(), decodesToolText: Bool = false) {
        self.toolSearchStore = toolSearchStore
        self.decodesToolText = decodesToolText
    }

    deinit {
        toolSearchStore.cancel()
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
        let sameSession = key.sessionID == snapshot.key?.sessionID
        if !sameSession { stopToolTextDecode(dropText: true) }
        // A pass start the previous landing deferred must not install older maps after this
        // snapshot's refresh; the new landing schedules what is still missing.
        toolDecodeRequest &+= 1
        computeTask?.cancel()
        isComputing = true
        let sessionCopy = session
        let store = toolSearchStore
        let decodeLimit = decodesToolText ? Self.landingDecodeLimit : 0
        let viewport = toolDecodeViewportProvider?()
        // A live append keeps the summaries of the invocations that did not change.
        let previousRowSummaries = sameSession ? snapshot.rowSummaries : [:]
        computeTask = Task.detached(priority: .userInitiated) { [weak self] in
            let snap = Self.computeSnapshot(session: sessionCopy, settings: settings,
                                            previousRowSummaries: previousRowSummaries)
            if Task.isCancelled { return }
            // A live append (same session): before the snapshot is published, the store learns the
            // new invocation keys (an invocation whose output grew stops returning its old text)
            // and decodes the few that changed, so the one Find scan at landing is final.
            let decodedAll: Bool
            if sameSession, let snapKey = snap.key {
                decodedAll = store.refresh(blocks: snap.blocks, index: snap.invocationIndex, source: snap.source,
                                           sessionID: snapKey.sessionID,
                                           viewportBlock: viewport ?? max(0, snap.blocks.count - 1),
                                           decodeLimit: decodeLimit, decodeBudget: Self.landingDecodeBudget)
            } else {
                decodedAll = false
            }
            if Task.isCancelled { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.snapshot = snap
                self.isComputing = false
                self.findMatchesCache.removeAll()   // block content changed
                self.scheduleToolTextDecode(decodedAll: decodedAll)
            }
        }
    }

    // MARK: Decoded tool text (Task 15)

    /// The Session view shows (true) or went away (false). Off stops a running pass and keeps
    /// the decoded text; on decodes what is missing for the current snapshot.
    func setDecodesToolText(_ on: Bool) {
        guard on != decodesToolText else { return }
        decodesToolText = on
        if on {
            guard snapshot.key != nil, !isComputing else { return }   // the landing schedules it
            scheduleToolTextDecode(decodedAll: toolSearchStore.isComplete)
        } else {
            stopToolTextDecode(dropText: false)
        }
    }

    /// Starts the decode pass for the snapshot that just landed, unless the snapshot task already
    /// decoded everything (`decodedAll`, a live append) or the Session view is not showing.
    /// Opening the session never waits for it (spec A3): the snapshot is published first, and the
    /// pass starts in a later main-actor turn (after the views took the snapshot) and runs at
    /// utility priority, from the Session view's first visible block outward. "Searching tool
    /// output…" shows only when the pass still runs after `toolTextLabelDelayNanoseconds`.
    private func scheduleToolTextDecode(decodedAll: Bool) {
        toolDecodeRequest &+= 1
        let request = toolDecodeRequest
        let snap = snapshot
        guard decodesToolText, !decodedAll, let key = snap.key,
              !snap.invocationIndex.invocations.isEmpty || !snap.toolBlockIndices.isEmpty else {
            endToolDecodePass()
            return
        }
        toolDecodePassRunning = true
        Task { @MainActor [weak self] in
            guard let self, self.toolDecodeRequest == request else { return }
            let viewport = self.toolDecodeViewportProvider?() ?? max(0, snap.blocks.count - 1)
            self.toolSearchStore.start(blocks: snap.blocks, index: snap.invocationIndex, source: snap.source,
                                       sessionID: key.sessionID, viewportBlock: viewport) { [weak self] decodedAny in
                guard let self, self.toolDecodeRequest == request else { return }
                self.endToolDecodePass()
                // Nothing new decoded: the last Find scan already saw every text.
                if decodedAny { self.toolTextGeneration &+= 1 }
            }
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.toolTextLabelDelayNanoseconds)
            guard let self, self.toolDecodeRequest == request, self.toolDecodePassRunning,
                  !self.isDecodingToolText else { return }
            self.isDecodingToolText = true
        }
    }

    /// Ends the pass state; observers hear about it only when the label was showing.
    private func endToolDecodePass() {
        toolDecodePassRunning = false
        if isDecodingToolText { isDecodingToolText = false }
    }

    private func stopToolTextDecode(dropText: Bool) {
        toolDecodeRequest &+= 1
        if dropText { toolSearchStore.cancel() } else { toolSearchStore.stop() }
        endToolDecodePass()
    }

    /// The ▲▼ stops of the Tools and Errors filters (Task 16, spec §6.8), both ascending.
    /// Tools: every invocation id. Errors: failed invocation ids plus `.error` blocks that no
    /// invocation owns. Pure and off-main-callable.
    nonisolated static func jumpIDs(blocks: [SessionTranscriptBuilder.LogicalBlock],
                                    index: ToolInvocationIndex,
                                    failedInvocationIDs: Set<Int>) -> (tools: [Int], errors: [Int]) {
        let tools = index.invocations.map(\.id).sorted()
        var errors = failedInvocationIDs
        for block in blocks where block.kind == .error && index.invocationIDByBlock[block.globalBlockIndex] == nil {
            errors.insert(block.globalBlockIndex)
        }
        return (tools, errors.sorted())
    }

    /// L1 summaries (`ToolInvocationBuilder.rowSummary`) of every invocation with a block in the
    /// tail window (`TranscriptWindow.lastWindow`, the window the Session view opens at), as the
    /// Session view builds them: index invocations, and a lone invocation for a tool block the
    /// index does not know. An entry of `previous` with the same stamp and status is kept. A Codex
    /// `exec` summary parses the whole script (~0.3–0.7 ms each in Debug), which on the main thread
    /// made the first rows of a large session cost ~130 ms. Serial on purpose: a parallel build
    /// was slower (every worker retains the same index and block storage). Pure and
    /// off-main-callable.
    nonisolated static func tailRowSummaries(blocks: [SessionTranscriptBuilder.LogicalBlock],
                                             index: ToolInvocationIndex, source: SessionSource,
                                             previous: [Int: RowSummaryEntry] = [:]) -> [Int: RowSummaryEntry] {
        let window = TranscriptWindow.lastWindow(totalBlocks: blocks.count,
                                                 blockTarget: FeatureFlags.transcriptWindowBlockTarget)
        guard !window.isEmpty else { return [:] }
        var seen = Set<Int>()
        var result: [Int: RowSummaryEntry] = [:]
        var pending: [(ref: ToolInvocationRef, stamp: Int)] = []
        for position in window.lowerBlock...window.upperBlock where blocks.indices.contains(position) {
            let block = blocks[position]
            guard let id = index.invocationIDByBlock[position] ?? (block.kind.isTool ? position : nil),
                  seen.insert(id).inserted else { continue }
            let ref = TranscriptToolRows.invocationRef(id: id, in: index)
                ?? ToolInvocationRef(id: id, callBlockIndex: block.kind == .toolCall ? id : nil,
                                     outputBlockIndices: block.kind == .toolCall ? [] : [id], status: .unknown)
            let stamp = ToolSearchTextStore.contentStamp(of: ref, blocks: blocks)
            if let kept = previous[id], kept.stamp == stamp, kept.status == ref.status {
                result[id] = kept
            } else {
                pending.append((ref, stamp))
            }
        }
        for item in pending {
            let summary = ToolInvocationBuilder.rowSummary(item.ref, blocks: blocks, index: index, source: source)
            result[item.ref.id] = RowSummaryEntry(stamp: item.stamp, status: item.ref.status, summary: summary)
        }
        return result
    }

    /// Holds the tail summaries built beside the rest of `computeSnapshot` (written once before
    /// the group finishes, read after `wait`).
    private final class RowSummaryBox: @unchecked Sendable {
        var value: [Int: RowSummaryEntry] = [:]
    }

    /// Pure, off-main-callable. Relocates the block-space parts of
    /// SessionTerminalView.buildRebuildResult (see SessionTerminalView.swift,
    /// the eventIDToAnchorBlockIndex construction inside the whole-session
    /// buildRebuildResult(session:blocks:blockRange:skipAgentsPreamble:enableReviewCards:)).
    nonisolated static func computeSnapshot(session: Session,
                                            settings: DerivedSettings,
                                            previousRowSummaries: [Int: RowSummaryEntry] = [:]) -> Snapshot {
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
        let jumps = jumpIDs(blocks: blocks, index: invocationIndex, failedInvocationIDs: failedInvocationIDs)
        snap.toolJumpIDs = jumps.tools
        snap.errorJumpIDs = jumps.errors
        // The tail's L1 summaries are built on a second thread while this one derives the
        // preamble and the anchors, so the snapshot takes about as long as without them.
        let summaries = RowSummaryBox()
        let summariesDone = DispatchGroup()
        let source = session.source
        DispatchQueue.global(qos: .userInitiated).async(group: summariesDone) {
            summaries.value = tailRowSummaries(blocks: blocks, index: invocationIndex, source: source,
                                               previous: previousRowSummaries)
        }

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
        summariesDone.wait()
        snap.rowSummaries = summaries.value
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
