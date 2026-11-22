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
        var includeMessageContext: Bool = false
    }

    struct Key: Hashable, Sendable {
        var sessionID: String
        var contentRevision: UUID
        var isPartiallyHydrated: Bool
        var eventCount: Int
        var fileSizeBytes: Int
        var skipAgentsPreamble: Bool
        var reviewCardsEnabled: Bool

        var includeMessageContext: Bool
        var source: SessionSource
        var parentSessionID: String?
        var subagentType: String?

        init(session: Session, settings: DerivedSettings) {
            includeMessageContext = settings.includeMessageContext
            source = session.source
            parentSessionID = session.parentSessionID
            subagentType = session.subagentType
            sessionID = session.id
            contentRevision = session.contentRevision
            isPartiallyHydrated = session.isPartiallyHydrated
            eventCount = session.events.count
            fileSizeBytes = session.fileSizeBytes ?? -1
            skipAgentsPreamble = settings.skipAgentsPreamble
            reviewCardsEnabled = settings.reviewCardsEnabled
        }
    }

    struct Snapshot: Sendable {
        var blocks: [SessionTranscriptBuilder.LogicalBlock] = []
        /// `blockDigests[i]` digests every field of blocks 0...i (built off the main thread). Equal
        /// digests mean equal prefixes up to a 64-bit hash collision, so the message-group cache can
        /// check an unchanged prefix in constant time on the main actor. Process-local (Hasher is seeded).
        var blockDigests: [Int] = []
        var totalBlockCount: Int = 0
        var eventIDToAnchorBlockIndex: [String: Int] = [:]
        var userBlockIndices: [Int] = []
        /// Original raw-user block ordinals mapped by event identity into this projection.
        var imageUserBlockIndices: [Int] = []
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
        /// Turn segmentation of `blocks` (answer and note blocks per turn), built off the main thread.
        var turnIndex: TranscriptTurnIndex = .empty
        var turnTiming: [Int: TurnTiming] = [:]
        var toolTiming: [Int: ToolTiming] = [:]
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
        case presentation
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
    /// The key of the computation in flight (nil when none).
    @ObservationIgnored private var pendingKey: Key?
    /// Bumped per started or dropped computation; a landing publishes only when it is current.
    @ObservationIgnored private var computeGeneration = 0

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
        var showsContext: Bool
    }
    private let findMatchesCache = LRUCache<FindCacheKey, [BlockMatch]>(maxEntries: 4)

    /// No-op if key unchanged (same dedupe discipline as shouldSkipRebuild).
    func update(session: Session, settings: DerivedSettings) {
        let key = Key(session: session, settings: settings)
        if key == snapshot.key {
            // Back at the published snapshot while another one computes (a quick A → B → A
            // switch): drop that computation, so it never publishes over the session shown now.
            if isComputing { dropPendingSnapshot() }
            return
        }
        // Already computing this key.
        if key == pendingKey, isComputing { return }
        // Cancel first: an older same-session refresh must not install maps after the drop below.
        computeTask?.cancel()
        // A session change cancels the decode pass and drops the decoded text (block indices
        // mean another session's blocks now).
        let sameSession = key.sessionID == snapshot.key?.sessionID
        if !sameSession { stopToolTextDecode(dropText: true) }
        // A pass start the previous landing deferred must not install older maps after this
        // snapshot's refresh; the new landing schedules what is still missing.
        toolDecodeRequest &+= 1
        computeGeneration &+= 1
        let generation = computeGeneration
        pendingKey = key
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
            // and decodes the few that changed, so the one Find scan at landing is final. Only
            // while the Session view decodes: otherwise nothing reads the store, and the pass that
            // starts when it shows again installs the maps (the store is not complete then).
            let decodedAll: Bool
            if sameSession, decodeLimit > 0, let snapKey = snap.key {
                decodedAll = store.refresh(blocks: snap.blocks, index: snap.invocationIndex, source: snap.source,
                                           sessionID: snapKey.sessionID,
                                           viewportBlock: viewport ?? max(0, snap.blocks.count - 1),
                                           decodeLimit: decodeLimit, decodeBudget: Self.landingDecodeBudget)
            } else {
                decodedAll = false
            }
            if Task.isCancelled { return }
            await MainActor.run { [weak self] in
                // A newer update (or a return to the published snapshot) replaced this one.
                guard let self, self.computeGeneration == generation else { return }
                self.snapshot = snap
                self.schedulePresentation()
                self.isComputing = false
                self.pendingKey = nil
                self.findMatchesCache.removeAll()   // block content changed
                self.scheduleToolTextDecode(decodedAll: decodedAll)
            }
        }
    }

    /// Cancels the snapshot computation in flight; the published snapshot stays. When that
    /// computation was another session's, the decoded text was dropped for it: decode again.
    private func dropPendingSnapshot() {
        let leftSession = pendingKey.map { $0.sessionID != snapshot.key?.sessionID } ?? false
        computeTask?.cancel()
        computeTask = nil
        computeGeneration &+= 1
        pendingKey = nil
        isComputing = false
        if leftSession { scheduleToolTextDecode(decodedAll: toolSearchStore.isComplete) }
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

    /// Running digests of everything message grouping reads from each block (see `Snapshot.blockDigests`).
    nonisolated static func blockDigests(_ blocks: [SessionTranscriptBuilder.LogicalBlock]) -> [Int] {
        var digests: [Int] = []
        digests.reserveCapacity(blocks.count)
        var running = 0
        for block in blocks {
            var hasher = Hasher()
            hasher.combine(running)
            // Every field a cached group keeps (its whole representative block), not only the ones
            // grouping reads: a replaced file can change a timestamp and nothing else.
            hasher.combine(block.globalBlockIndex)
            hasher.combine(block.firstEventIndex)
            hasher.combine(block.kind)
            hasher.combine(block.eventID)
            hasher.combine(block.text)
            hasher.combine(block.rawJSON)
            hasher.combine(block.timestamp)
            hasher.combine(block.messageID)
            hasher.combine(block.isDelta)
            hasher.combine(block.isErrorOutput)
            hasher.combine(block.toolName)
            hasher.combine(block.toolInput)
            hasher.combine(block.toolNamespace)
            hasher.combine(block.toolCallID)
            hasher.combine(block.messageDisplayText)
            hasher.combine(block.messageHasEncryptedContent)
            hasher.combine(block.messageOrigin.map { String(describing: $0) })
            hasher.combine(block.presentation.map { String(describing: $0) })
            hasher.combine(block.toolOutputValue.map { String(describing: $0) })
            hasher.combine(block.toolSidecar.map { String(describing: $0) })
            hasher.combine(block.toolDisposition.map { String(describing: $0) })
            running = hasher.finalize()
            digests.append(running)
        }
        return digests
    }

    /// Pure, off-main-callable. Relocates the block-space parts of
    /// SessionTerminalView.buildRebuildResult (see SessionTerminalView.swift,
    /// the eventIDToAnchorBlockIndex construction inside the whole-session
    /// buildRebuildResult(session:blocks:blockRange:skipAgentsPreamble:enableReviewCards:)).
    nonisolated static func computeSnapshot(session: Session,
                                            settings: DerivedSettings,
                                            previousRowSummaries: [Int: RowSummaryEntry] = [:]) -> Snapshot {
        let metrics = SearchResponsivenessMetrics.shared
        let operation = metrics.operation(source: session.source.rawValue, sessionID: session.id)
        let context = SearchResponsivenessMetricContext.session(session)
        let span = metrics.beginSpan(.snapshot, operationID: operation, context: context)
        defer { if let span { Task.isCancelled ? metrics.cancel(span) : metrics.end(span) } }
        let blocks = metrics.measured(.snapshotCoalescing, operationID: operation, context: context) {
            SessionTranscriptBuilder.coalescedBlocks(for: session, includeMeta: false, includeMessageContext: settings.includeMessageContext)
        }
        var snap = Snapshot()
        snap.blocks = blocks
        snap.blockDigests = metrics.measured(.snapshotDigests, operationID: operation, context: context) { blockDigests(blocks) }
        snap.totalBlockCount = blocks.count
        snap.source = session.source
        snap.key = Key(session: session, settings: settings)

        var userIdx: [Int] = [], toolIdx: [Int] = [], errIdx: [Int] = []
        for b in blocks {
            switch b.kind {
            case .user: if !settings.includeMessageContext || b.isTypedUserMessage { userIdx.append(b.globalBlockIndex) }
            case .toolCall, .toolOut: toolIdx.append(b.globalBlockIndex)
            case .error: errIdx.append(b.globalBlockIndex)
            case .assistant, .meta: break
            }
        }
        snap.userBlockIndices = userIdx
        let rawUserEventIDs = Set(session.events.filter { $0.kind == .user }.map(\.id))
        snap.imageUserBlockIndices = blocks.filter { $0.kind == .user && rawUserEventIDs.contains($0.eventID) }.map(\.globalBlockIndex)
        snap.toolBlockIndices = toolIdx
        snap.errorBlockIndices = errIdx

        // Tool pairing + cheap status (spec §6.2 pass 1), once per snapshot, off main.
        // Errors stay block-based in `errorBlockIndices`; failed invocations are separate.
        let invocationIndex = metrics.measured(.invocationIndex, operationID: operation, context: context) { ToolInvocationIndex.build(blocks: blocks, source: session.source) }
        snap.invocationIndex = invocationIndex
        var failedInvocationIDs: Set<Int> = []
        for invocation in invocationIndex.invocations {
            if case .failed = invocation.status { failedInvocationIDs.insert(invocation.id) }
        }
        snap.failedInvocationIDs = failedInvocationIDs
        let jumps = jumpIDs(blocks: blocks, index: invocationIndex, failedInvocationIDs: failedInvocationIDs)
        snap.toolJumpIDs = jumps.tools
        snap.errorJumpIDs = jumps.errors
        snap.turnIndex = metrics.measured(.turnIndex, operationID: operation, context: context) { TranscriptTurns.index(blocks: blocks, source: session.source) }
        let timing = TranscriptTurnTiming.compute(blocks: blocks, index: invocationIndex,
                                                  source: session.source, turnIndex: snap.turnIndex)
        snap.turnTiming = timing.turns
        snap.toolTiming = timing.tools
        // The tail's L1 summaries are built on a second thread while this one derives the
        // preamble and the anchors, so the snapshot takes about as long as without them.
        let summaries = RowSummaryBox()
        let summariesDone = DispatchGroup()
        let source = session.source
        DispatchQueue.global(qos: .userInitiated).async(group: summariesDone) {
            summaries.value = tailRowSummaries(blocks: blocks, index: invocationIndex, source: source,
                                               previous: previousRowSummaries)
        }

        if settings.skipAgentsPreamble && settings.includeMessageContext {
            // Session already classified provenance during coalescing. Rescanning raw bodies
            // is costly and can mistake explicitly typed instructions for a preamble.
            snap.preambleUserBlockIndexes = Set(blocks.lazy.filter {
                $0.kind == .user && $0.presentation?.origin?.isHiddenContext == true
            }.map(\.globalBlockIndex))
        } else {
            // Terminal/default snapshots retain their historical full-text heuristic.
            snap.preambleUserBlockIndexes = settings.skipAgentsPreamble
                ? SessionTerminalView.computePreambleUserBlockIndexes(session: session, blocks: blocks)
                : []
        }

        // Same anchor derivation buildRebuildResult uses (full-session scope),
        // copied verbatim from SessionTerminalView.buildRebuildResult's
        // eventIDToAnchorBlockIndex construction so the two stay byte-identical.
        let anchorSpan = metrics.beginSpan(.anchorIndexes, operationID: operation, context: context)
        var eventIDToAnchorBlockIndex: [String: Int] = [:]
        if settings.includeMessageContext {
            let fallbackPrompts = blocks.filter {
                $0.presentation?.origin == .parentTask || $0.presentation?.origin == .approvalRequest
            }.map(\.globalBlockIndex)
            let promptIndices = Set(userIdx.isEmpty ? fallbackPrompts : userIdx)
            var precedingPrompt: Int?
            for block in blocks {
                let index = block.globalBlockIndex
                if promptIndices.contains(index) { precedingPrompt = index }
                if block.presentation?.origin == .placeholder { continue }
                if block.kind == .user || (block.kind == .meta && block.presentation != nil) {
                    // Message-origin deep links name their own row, even when You skips it.
                    eventIDToAnchorBlockIndex[block.eventID] = index
                } else if block.kind != .meta {
                    eventIDToAnchorBlockIndex[block.eventID] = precedingPrompt ?? invocationIndex.invocationIDByBlock[index] ?? index
                }
            }
        } else if !blocks.isEmpty {
            // Preserve Terminal's historical raw-user anchoring exactly.
            let anchors = TranscriptUserAnchors.anchors(userBlockIndices: userIdx,
                                                        preambleUserBlockIndexes: snap.preambleUserBlockIndexes,
                                                        blockCount: blocks.count)
            for (idx, block) in blocks.enumerated() {
                let target = block.kind == .user ? idx : anchors[idx]
                guard let target, blocks.indices.contains(target) else { continue }
                eventIDToAnchorBlockIndex[block.eventID] = blocks[target].globalBlockIndex
            }
        }
        snap.eventIDToAnchorBlockIndex = eventIDToAnchorBlockIndex
        if let anchorSpan { metrics.end(anchorSpan) }
        summariesDone.wait()
        snap.rowSummaries = summaries.value
        return snap
    }

    struct PresentationInputs: Equatable, Sendable {
        var snapshotKey: Key
        var showsContext: Bool
        var configurationChanges: [ConfigurationChange]
        var imageBlocks: Set<Int>
        var localeIdentifier: String = Locale.current.identifier
        var activeRoles: Set<TranscriptRoleFilter> = []
        var diagnosticContext: SearchResponsivenessMetricContext = .none
    }

    struct PresentationBundle: Sendable {
        var inputs: PresentationInputs
        var snapshot: Snapshot
        var markers: [Int: [String]]
        var groups: TranscriptMessageGroupIndex
        var userStops: Int
        var agentStopIDs: [Int]
        var errorStopIDs: [Int]
        var hiddenNotes: Set<Int>
        var chipAnchors: [Int: TurnTiming]
        var revision: Int
    }
    private(set) var presentationBundle: PresentationBundle?
    @ObservationIgnored private var presentationInputs: PresentationInputs?
    @ObservationIgnored private var presentationTask: Task<Void, Never>?
    @ObservationIgnored private var presentationGeneration = 0

    /// UI input only. Derivation starts when the exact snapshot is available.
    func preparePresentation(_ inputs: PresentationInputs) {
        guard inputs != presentationInputs else { return }
        presentationInputs = inputs
        schedulePresentation()
    }

    func presentation(matching inputs: PresentationInputs) -> PresentationBundle? {
        guard presentationInputs == inputs, presentationBundle?.inputs == inputs else { return nil }
        return presentationBundle
    }

    var selectedPresentationContext: SearchResponsivenessMetricContext? {
        presentationInputs?.diagnosticContext
    }

    private func schedulePresentation() {
        presentationTask?.cancel()
        presentationGeneration &+= 1
        guard let inputs = presentationInputs, inputs.snapshotKey == snapshot.key else { return }
        if presentationBundle?.inputs == inputs { return }
        let generation = presentationGeneration
        let snap = snapshot, previous = presentationBundle
        presentationTask = Task.detached(priority: .userInitiated) { [weak self] in
            let bundle = Self.computePresentation(snapshot: snap, inputs: inputs, previous: previous,
                                                  revision: generation)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.presentationGeneration == generation,
                      self.presentationInputs == inputs, self.snapshot.key == inputs.snapshotKey else { return }
                self.presentationBundle = bundle
                SearchResponsivenessMetrics.shared.record(.presentationPublished,
                    operationID: SearchResponsivenessMetrics.shared.operation(source: inputs.snapshotKey.source.rawValue,
                                                                            sessionID: inputs.snapshotKey.sessionID),
                    context: .init(session: .init(source: inputs.snapshotKey.source.rawValue, sessionID: inputs.snapshotKey.sessionID),
                        contentRevision: .init(inputs.snapshotKey.contentRevision.uuidString),
                        hydration: inputs.snapshotKey.isPartiallyHydrated ? .provisional : .full,
                        presentationGeneration: Int64(generation)), status: .published)
            }
        }
    }

    nonisolated static func computePresentation(snapshot: Snapshot, inputs: PresentationInputs,
                                               previous: PresentationBundle? = nil,
                                               revision: Int = 1) -> PresentationBundle {
        let metrics = SearchResponsivenessMetrics.shared
        let operation = metrics.operation(source: inputs.snapshotKey.source.rawValue, sessionID: inputs.snapshotKey.sessionID)
        let context = SearchResponsivenessMetricContext(session: .init(source: inputs.snapshotKey.source.rawValue,
            sessionID: inputs.snapshotKey.sessionID), contentRevision: .init(inputs.snapshotKey.contentRevision.uuidString),
            hydration: inputs.snapshotKey.isPartiallyHydrated ? .provisional : .full, presentationGeneration: Int64(revision))
        let markerSpan = metrics.beginSpan(.markerDerivation, operationID: operation, context: context)
        let markers: [Int: [String]]
        if let previous, previous.inputs.snapshotKey == inputs.snapshotKey,
           previous.inputs.configurationChanges == inputs.configurationChanges,
           previous.inputs.localeIdentifier == inputs.localeIdentifier {
            markers = previous.markers
        } else {
            markers = TranscriptTelemetryPresentation.markers(changes: inputs.configurationChanges,
                blocks: snapshot.blocks, locale: Locale(identifier: inputs.localeIdentifier))
        }
        if let markerSpan { metrics.end(markerSpan) }
        let groupSpan = metrics.beginSpan(.groupDerivation, operationID: operation, context: context)
        let blocks = snapshot.blocks
        var groups: TranscriptMessageGroupIndex
        let restart: Int? = {
            guard let previous, var oldKey = previous.snapshot.key,
                  let newKey = snapshot.key, previous.inputs.showsContext == inputs.showsContext,
                  previous.inputs.imageBlocks == inputs.imageBlocks,
                  previous.markers == markers, previous.inputs.localeIdentifier == inputs.localeIdentifier,
                  blocks.count >= previous.snapshot.blocks.count else { return nil }
            oldKey.eventCount = newKey.eventCount
            oldKey.fileSizeBytes = newKey.fileSizeBytes
            oldKey.contentRevision = newKey.contentRevision
            oldKey.isPartiallyHydrated = newKey.isPartiallyHydrated
            guard oldKey == newKey else { return nil }
            let old = previous.snapshot
            return previous.groups.restartPoints.reversed().map(\.id).first { point in
                guard point < old.blocks.count else { return false }
                if point == 0 { return true }
                return snapshot.blockDigests[point - 1] == old.blockDigests[point - 1]
                    && blocks[point - 1] == old.blocks[point - 1]
            }
        }()
        let sameGroupInputs = previous.map {
            $0.inputs.snapshotKey == inputs.snapshotKey && $0.inputs.showsContext == inputs.showsContext
                && $0.inputs.configurationChanges == inputs.configurationChanges
                && $0.inputs.imageBlocks == inputs.imageBlocks && $0.inputs.localeIdentifier == inputs.localeIdentifier
        } ?? false
        if sameGroupInputs, let previous {
            groups = previous.groups
        } else if let restart, let previous {
            groups = .extending(previous.groups, from: restart, previousBlockCount: previous.snapshot.blocks.count,
                blocks: blocks[...], source: snapshot.source, showsContext: inputs.showsContext,
                markers: markers, noncollapsibleBlockIndices: inputs.imageBlocks)
        } else {
            groups = .build(blocks: blocks[...], source: snapshot.source, showsContext: inputs.showsContext,
                markers: markers, noncollapsibleBlockIndices: inputs.imageBlocks)
        }
        if !sameGroupInputs { groups.revision = revision }
        if let groupSpan { metrics.end(groupSpan) }
        let countSpan = metrics.beginSpan(.countDerivation, operationID: operation, context: context)
        let roles = inputs.activeRoles
        let userShown = roles.isEmpty || roles.contains(.user)
        let agentShown = roles.isEmpty || roles.contains(.assistant)
        let toolsShown = roles.isEmpty || roles.contains(.tools)
        let hiddenNotes = toolsShown ? Set<Int>() : snapshot.turnIndex.noteBlockIndices
        let userStops = userShown ? groups.groupsByID.values.filter {
            TranscriptRoleFilter.governing($0.block, source: snapshot.source) == .user
        }.count : 0
        let agentStops = agentShown ? groups.groupsByID.compactMap { id, group in
            TranscriptRoleFilter.governing(group.block, source: snapshot.source) == .assistant
                && !group.isHidden(by: hiddenNotes) ? id : nil
        }.sorted() : []
        let errors = SessionRoleFilters.shownErrorStops(snapshot.errorJumpIDs,
            failedInvocationIDs: snapshot.failedInvocationIDs, activeRoles: roles)
        let anchors = TranscriptTurns.chipAnchors(timing: snapshot.turnTiming, turnIndex: snapshot.turnIndex,
            rowIDByBlock: groups.groupIDByBlock, visibleRowIDs: Set(agentStops))
        if let countSpan { metrics.end(countSpan) }
        return .init(inputs: inputs, snapshot: snapshot, markers: markers, groups: groups, userStops: userStops,
                     agentStopIDs: agentStops, errorStopIDs: errors, hiddenNotes: hiddenNotes,
                     chipAnchors: anchors, revision: revision)
    }

    func findMatches(query: String, showsContext: Bool = false) -> [BlockMatch] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        // Reading `toolTextGeneration` here (an observed property) makes a view that asks for
        // matches update again when a decode pass ends, so Find re-runs exactly once.
        let cacheKey = FindCacheKey(snapshotKey: snapshot.key, toolTextGeneration: toolTextGeneration, query: q, showsContext: showsContext)
        if let cached = findMatchesCache.get(cacheKey) { return cached }
        findComputeCount += 1
        let store = toolSearchStore
        let matches = Self.computeFindMatches(blocks: snapshot.blocks, query: q, toolText: store.text(forBlock:), includeMessageContext: snapshot.key?.includeMessageContext == true, showsContext: showsContext)
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
        toolText: ((Int) -> String?)? = nil,
        includeMessageContext: Bool = false, showsContext: Bool = false) -> [BlockMatch] {
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
            let presentation = includeMessageContext ? block.presentation : nil
            if presentation?.origin == .placeholder || (!showsContext && presentation?.origin?.isHiddenContext == true) { continue }
            for r in SearchTextMatcher.matchRanges(in: presentation?.body ?? block.text, query: query) {
                out.append(BlockMatch(globalBlockIndex: block.globalBlockIndex,
                                      rangeInBlockText: r, ordinal: ordinal, space: presentation == nil ? .raw : .presentation))
                ordinal += 1
            }
        }
        return out
    }
}
