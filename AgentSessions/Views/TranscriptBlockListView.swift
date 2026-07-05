import SwiftUI
import AppKit

// MARK: - Row model

/// One row per displayed card. `TranscriptToolSummary.mergeToolRuns` (Task 6)
/// folds consecutive `.toolCall`/`.toolOut` message rows (run length >= 2)
/// into a single `.toolGroup` row; a lone tool block stays `.message` but is
/// still rendered as a collapsed tool card (see `isToolCard`).
struct BlockRowModel: Identifiable, Equatable {
    enum Content: Equatable {
        /// user / assistant / error / meta / tool (as ordinary card until T6)
        case message(SessionTranscriptBuilder.LogicalBlock)
        /// merged consecutive tool blocks — produced by Task 6, never by T5.
        case toolGroup([SessionTranscriptBuilder.LogicalBlock])
    }

    /// `globalBlockIndex` of the first block — stable across window widening.
    var id: Int
    var content: Content

    /// The block used to drive chrome/height for the row. For a message that is
    /// the block itself; for a (future) tool group it is the first block.
    var primaryBlock: SessionTranscriptBuilder.LogicalBlock {
        switch content {
        case .message(let b): return b
        case .toolGroup(let blocks): return blocks.first ?? Self.emptyBlock
        }
    }

    /// Text rendered in the body. T6 will concatenate grouped tool text.
    var bodyText: String {
        switch content {
        case .message(let b): return b.text
        case .toolGroup(let blocks): return blocks.map(\.text).joined(separator: "\n\n")
        }
    }

    /// True for any row rendered as a tool card: a merged `.toolGroup`, or a
    /// lone `.message` row whose block kind is `.toolCall`/`.toolOut`.
    var isToolCard: Bool {
        switch content {
        case .toolGroup: return true
        case .message(let b): return b.kind.isTool
        }
    }

    /// True for a `.meta` message row — rendered as a thin separator, no card
    /// chrome.
    var isMeta: Bool {
        if case .message(let b) = content { return b.kind == .meta }
        return false
    }

    /// True for a user/assistant prose message — the ONLY rows that get markdown
    /// rendering (Task 12). Tool cards, tool groups, errors, and meta rows keep
    /// their existing plain-string bodies untouched.
    var isMarkdownMessage: Bool {
        if case .message(let b) = content { return b.kind == .user || b.kind == .assistant }
        return false
    }

    /// The individual blocks backing this row (1 for `.message`, N for
    /// `.toolGroup`) — used to render per-call summary lines when a group is
    /// expanded.
    var toolBlocks: [SessionTranscriptBuilder.LogicalBlock] {
        switch content {
        case .message(let b): return [b]
        case .toolGroup(let blocks): return blocks
        }
    }

    private static let emptyBlock = SessionTranscriptBuilder.LogicalBlock(
        kind: .meta, text: "", timestamp: nil, messageID: nil, toolName: nil,
        isDelta: false, toolInput: nil, isErrorOutput: false, eventID: "", rawJSON: "")
}

// MARK: - Layout constants (single source of truth, shared by cell + measurement)

private enum CardMetrics {
    static let accentBarWidth: CGFloat = 3
    static let cornerRadius: CGFloat = 6
    /// Leading gap between the accent bar and text content.
    static let contentLeadingInset: CGFloat = 10
    static let contentTrailingInset: CGFloat = 12
    static let headerHeight: CGFloat = 22
    /// Vertical gap between header baseline block and the body text.
    static let headerToBodyGap: CGFloat = 2
    static let bodyBottomInset: CGFloat = 8
    static let bodyTopInsetWhenNoHeader: CGFloat = 4
    /// Minimum card height for empty-text blocks.
    static let minCardHeight: CGFloat = headerHeight + 12
    /// Background tint alpha for the role-tinted card fill (HIG-quiet).
    static let cardTintAlpha: CGFloat = 0.06
    /// Collapsed tool-card height: header row only (~28pt design target).
    /// Exactly headerHeight + bodyBottomInset so the measured height equals
    /// the Auto Layout solution for the collapsed shape (header 22 + zero-gap
    /// zero-height body + zero-height showAll + 8pt bottom inset) — anything
    /// smaller forces a negative body height out of the constraint chain.
    static let toolCardCollapsedHeight: CGFloat = headerHeight + bodyBottomInset
    /// Thin separator row height for `.meta` blocks (no card chrome).
    static let metaSeparatorHeight: CGFloat = 14
    /// Expanded tool body is truncated to this many lines before a
    /// "Show all N lines" affordance takes over.
    static let toolBodyTruncationLineLimit = 20
    /// Height of the "Show all N lines" SwiftUI affordance row.
    static let showAllRowHeight: CGFloat = 20

    /// Horizontal space consumed by chrome; body text width = tableWidth - this.
    static var horizontalChrome: CGFloat { accentBarWidth + contentLeadingInset + contentTrailingInset }
}

// MARK: - Representable

/// Rich-mode block list. Renders the windowed `LogicalBlock` stream as cards in
/// an `NSTableView` (accent bar + SwiftUI role header + selectable NSTextView).
///
/// `@Observable` discipline: `updateNSView` reads `derivedState.snapshot`
/// (blocks + totalBlockCount) so SwiftUI tracks those reads and re-invokes us on
/// change. Only plain value types are handed to the AppKit controller — the
/// controller never retains `derivedState`.
struct TranscriptBlockListView: NSViewRepresentable {
    let derivedState: TranscriptDerivedState
    let session: Session
    let fontSize: CGFloat
    /// Task 8: external jump intents, token-based so a re-render (e.g. a mode
    /// switch back to Rich) never replays a stale intent — the controller only
    /// acts when the incoming token differs from the last one it consumed.
    /// Bumped by the toolbar's "jump to first prompt" button.
    var firstPromptJumpToken: Int = 0
    /// Bumped alongside `eventJumpID` for an event-deeplink / image-jump
    /// request (unified-search hit navigation, image strip, cross-window
    /// deeplinks — see SessionTerminalView's `.navigateToSessionEventFromImages`
    /// receiver, mirrored for Rich mode in TranscriptPlainView).
    var eventJumpToken: Int = 0
    var eventJumpID: String? = nil
    /// Bumped alongside `userPromptIndexJump` for the images window's
    /// index-based variant of the same notification (no eventID available at
    /// the call site). Resolved here against `userBlockIndices` rather than at
    /// the SwiftUI layer so it works even if `derivedState.snapshot` hasn't
    /// landed yet when the notification arrives.
    var userPromptIndexJumpToken: Int = 0
    var userPromptIndexJump: Int? = nil

    // MARK: Find (Task 10)
    /// Local ⌘F query (trimmed at the SwiftUI layer). Whole-session matches are
    /// computed here from `derivedState.findMatches(query:)` so SwiftUI tracks
    /// the read and re-invokes `updateNSView` on snapshot change.
    var findQuery: String = ""
    /// Monotonic token: a new find request (query change / next / prev / clear)
    /// bumps it. The controller only re-navigates when the token increments,
    /// with the same mode-switch-remount replay guard the jump intents use.
    var findToken: Int = 0
    var findDirection: Int = 1
    var findReset: Bool = true
    var findAllowAutoScroll: Bool = true
    /// Whole-session match total (off-window included) and current 1-based
    /// ordinal, published back to the find bar. In Rich mode visible == total.
    @Binding var findMatchCount: Int
    @Binding var findCurrentIndex: Int

    /// Unified-search (list-search) query + token machinery — same shape as the
    /// local find above, fed by `unifiedFreeText`. Drives unified-hit navigation
    /// and auto-jump-on-open for Rich mode (Task 8 deferred to Task 10).
    var unifiedQuery: String = ""
    var unifiedFindToken: Int = 0
    var unifiedFindDirection: Int = 1
    var unifiedFindReset: Bool = true
    var unifiedFindAllowAutoScroll: Bool = true
    @Binding var unifiedMatchCount: Int
    @Binding var unifiedCurrentIndex: Int

    func makeCoordinator() -> BlockTableController { BlockTableController() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = BlockTableView()
        table.selectionOwner = context.coordinator
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.allowsColumnResizing = false
        table.allowsColumnReordering = false
        table.allowsColumnSelection = false
        table.gridStyleMask = []
        table.intercellSpacing = NSSize(width: 0, height: 8)
        table.usesAutomaticRowHeights = false
        table.rowSizeStyle = .custom
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("card"))
        col.resizingMask = .autoresizingMask
        col.isEditable = false
        table.addTableColumn(col)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true

        // Remount replay guard (Task 8): the token @State
        // (richFirstPromptJumpToken &co) lives on UnifiedTranscriptView and
        // PERSISTS across Terminal<->Rich mode switches, but this coordinator
        // is recreated fresh (lastConsumed* == 0) every time the Rich branch
        // remounts in the ZStack conditional. Without seeding, the sequence
        // "jump in Rich (token→1, consumed) → switch to Terminal → switch back
        // to Rich" would make the new coordinator see token 1 as new and
        // spuriously re-jump/flash. Seed the consumed watermarks from the
        // CURRENT prop values so a freshly-mounted view treats every
        // pre-existing token as already consumed; only tokens that increment
        // AFTER mount fire. This cannot break the mounted-but-computing
        // pending-stash path: seeding happens exactly once here, before any
        // updateNSView, so an intent arriving while Rich is already mounted
        // still carries a token above the seed and is handled (or stashed)
        // normally.
        context.coordinator.seedConsumedJumpTokens(
            firstPromptJumpToken: firstPromptJumpToken,
            eventJumpToken: eventJumpToken,
            userPromptIndexJumpToken: userPromptIndexJumpToken)
        context.coordinator.seedConsumedFindTokens(
            findToken: findToken,
            unifiedFindToken: unifiedFindToken)

        context.coordinator.attach(table: table, scroll: scroll)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        // Read observed state HERE so SwiftUI records the dependency and reruns
        // updateNSView on snapshot change. Hand plain values to the controller.
        let snapshot = derivedState.snapshot
        context.coordinator.apply(
            allBlocks: snapshot.blocks,
            totalBlockCount: snapshot.totalBlockCount,
            fontSize: fontSize,
            source: session.source,
            sessionID: session.id)

        // Task 8: external jump intents. Resolved here (not stashed as raw
        // tokens on the coordinator ctor) because resolution needs the CURRENT
        // snapshot (anchor map / user indices / preamble set), which can still
        // be mid-compute on first arrival — the controller stashes the intent
        // and re-checks it on every subsequent updateNSView pass, guarded by
        // resolvability (mirrors SessionTerminalView's pendingEventJumpID
        // retry discipline).
        context.coordinator.handleFirstPromptJumpIntent(
            token: firstPromptJumpToken,
            userBlockIndices: snapshot.userBlockIndices,
            preambleUserBlockIndexes: snapshot.preambleUserBlockIndexes,
            isSnapshotComputing: derivedState.isComputing)

        context.coordinator.handleEventJumpIntent(
            token: eventJumpToken,
            eventID: eventJumpID,
            eventIDToAnchorBlockIndex: snapshot.eventIDToAnchorBlockIndex,
            isSnapshotComputing: derivedState.isComputing)

        context.coordinator.handleUserPromptIndexJumpIntent(
            token: userPromptIndexJumpToken,
            userPromptIndex: userPromptIndexJump,
            userBlockIndices: snapshot.userBlockIndices,
            isSnapshotComputing: derivedState.isComputing)

        // Find (Task 10). Whole-session matches come from the derived state's
        // per-query cache (keyed by query + snapshot key, so a live-append that
        // changed the snapshot recomputes them). A find/unified token bump is a
        // navigation request; otherwise, if a query is active and the snapshot
        // just changed under it, reconcile the current match + counts in place.
        // Bindings are written on the next runloop tick to avoid mutating
        // SwiftUI state during `updateNSView` (re-entrancy).
        let coordinator = context.coordinator

        if coordinator.consumeLocalFindToken(findToken) {
            let matches = findQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? [] : derivedState.findMatches(query: findQuery)
            let counts = coordinator.applyFind(
                source: .local, query: findQuery, matches: matches,
                token: findToken, direction: findDirection,
                reset: findReset, shouldJump: findAllowAutoScroll)
            publishFindCounts(counts, current: $findCurrentIndex, total: $findMatchCount)
        } else if coordinator.consumeUnifiedFindToken(unifiedFindToken) {
            let matches = unifiedQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? [] : derivedState.findMatches(query: unifiedQuery)
            let counts = coordinator.applyFind(
                source: .unified, query: unifiedQuery, matches: matches,
                token: unifiedFindToken, direction: unifiedFindDirection,
                reset: unifiedFindReset, shouldJump: unifiedFindAllowAutoScroll)
            publishFindCounts(counts, current: $unifiedCurrentIndex, total: $unifiedMatchCount)
        } else if coordinator.isFindActive {
            // No new navigation request, but the snapshot may have changed under
            // an active query (live append / widen). Reconcile in place.
            let activeQuery = coordinator.activeFindSource == .unified ? unifiedQuery : findQuery
            let trimmed = activeQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let matches = derivedState.findMatches(query: trimmed)
            let counts = coordinator.refreshFindAfterRowsChanged(matches: matches)
            if coordinator.activeFindSource == .unified {
                publishFindCounts(counts, current: $unifiedCurrentIndex, total: $unifiedMatchCount)
            } else {
                publishFindCounts(counts, current: $findCurrentIndex, total: $findMatchCount)
            }
        }
    }

    /// Write find counts to the SwiftUI bindings on the next runloop tick, so we
    /// never mutate observed state during `updateNSView` (which SwiftUI flags as
    /// re-entrant). Gated BEFORE enqueue: reading a binding here is safe (only
    /// writes re-enter), and while a find is active this runs on every
    /// updateNSView pass — skipping the dispatch entirely on the common
    /// unchanged case avoids scheduling a main-queue closure per pass. The
    /// inner re-check stays as a guard against two enqueued publishes racing.
    private func publishFindCounts(_ counts: (current: Int, total: Int),
                                   current: Binding<Int>, total: Binding<Int>) {
        guard total.wrappedValue != counts.total || current.wrappedValue != counts.current else { return }
        DispatchQueue.main.async {
            if total.wrappedValue != counts.total { total.wrappedValue = counts.total }
            if current.wrappedValue != counts.current { current.wrappedValue = counts.current }
        }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: BlockTableController) {
        coordinator.tearDown()
    }
}

// MARK: - Controller (Coordinator)

/// Owns the AppKit table: row models, height cache, recycling, scroll-anchor
/// discipline, and the loaded window range. Deliberately holds only plain
/// values from the snapshot — never `TranscriptDerivedState`.
final class BlockTableController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private weak var table: NSTableView?
    private weak var scroll: NSScrollView?

    // Current display state.
    private(set) var rows: [BlockRowModel] = []
    private var fontSize: CGFloat = 13
    private var source: SessionSource = .codex

    /// Session identity last seen — the reset seam for all per-row expansion
    /// state below. Nil until the first `apply`.
    private var sessionID: String?

    /// Row ids (== first block's `globalBlockIndex`) whose tool card is
    /// expanded. Collapsed is the default for every `.toolCall`/`.toolOut`/
    /// `.toolGroup` row. Reset whenever `sessionID` changes.
    private(set) var expandedToolRowIDs: Set<Int> = []
    /// Row ids that opted into "Show all N lines" past the >20-line
    /// truncation. Reset whenever `sessionID` changes.
    private(set) var showAllRowIDs: Set<Int> = []

    /// Full coalesced stream length last seen (drives window re-pinning).
    private var totalBlockCount: Int = 0

    /// Window of GLOBAL block indices currently loaded. Task 7 widens this on
    /// scroll; T5 pins it to the tail (that IS the follow-tail seed). Nil until
    /// the first apply establishes it.
    private(set) var loadedBlockRange: ClosedRange<Int>?

    // Height cache keyed by (rowID, widthBucket, fontSizeBucket). Width changes
    // invalidate the whole cache only when the BUCKET differs; font changes
    // likewise invalidate via the bucket embedded in HeightKey.
    private var heightCache: [HeightKey: CGFloat] = [:]
    private var lastMeasuredWidthBucket: Int?

    // MARK: Markdown render cache (Task 12)

    /// Cache of rendered markdown bodies for user/assistant rows, keyed by
    /// `RenderKey` (eventID + textHash + fontBucket + isDark). eventID keeps the
    /// key stable across window prepend/widen (globalBlockIndex shifts); textHash
    /// catches a streaming delta; fontBucket + isDark match the two axes that
    /// change the baked attributed string. Bounded so a long session doesn't grow
    /// it without limit; cleared on session switch, font change, and appearance
    /// flip (colors are baked at render time). 400 ≈ several screens of messages.
    private let renderedBodyCache = LRUCache<RenderKey, RenderedBody>(maxEntries: 400)

    /// The effective-appearance dark flag used to key + bake markdown renders.
    /// Read from the controller's own table view (its `effectiveAppearance` is
    /// the one the cells resolve dynamic colors against); falls back to the app's
    /// effective appearance before the table is attached.
    private var effectiveAppearanceIsDark: Bool {
        let appearance = table?.effectiveAppearance ?? NSApp.effectiveAppearance
        return appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// KVO on the table view's own `effectiveAppearance` — the view-local signal
    /// that fires for BOTH a system dark/light flip AND the app's explicit
    /// appearance override (both propagate down to the table's effective
    /// appearance). Cheaper and more correct than a distributed notification: no
    /// cross-process hop, and it reflects exactly the appearance the cells
    /// resolve colors against. Torn down in `tearDown`.
    private var appearanceObservation: NSKeyValueObservation?
    /// Last dark flag we rendered against, so an appearance callback that doesn't
    /// actually flip our effective appearance is a cheap no-op (KVO can fire for
    /// unrelated appearance-graph churn).
    private var lastRenderedIsDark: Bool?

    private var frameObserver: NSObjectProtocol?
    private var observedClipView: NSClipView?

    // MARK: Scroll-driven windowing (Task 7)

    /// contentView bounds observer — drives load-older (near top) and follow-tail
    /// stickiness (near bottom). Separate object from `frameObserver` (width).
    private var scrollObserver: NSObjectProtocol?
    /// Sticky-bottom flag: true means "follow the tail on live appends". Seeded
    /// true (fresh sessions open at tail) and flipped by the bounds observer as
    /// the user scrolls away from / back to the bottom.
    private var isNearBottom: Bool = true
    /// Re-entry guard for load-older: a prepend is being applied. Blocks the
    /// bounds observer from stacking a second extension mid-flight.
    private var isPrependInFlight: Bool = false
    /// Debounce token for load-older — only the newest scheduled check fires.
    private var loadOlderDebounceToken: Int = 0
    /// Full block stream last handed to `apply`, retained so scroll-driven
    /// widening can re-slice without waiting for the next SwiftUI update pass.
    private var allBlocksCache: [SessionTranscriptBuilder.LogicalBlock] = []
    /// Row id currently flashing (widen/jump highlight), so a recycled cell for
    /// that row re-raises the pulse and every other cell resets to base alpha.
    private var flashingRowID: Int?

    // MARK: Cross-block selection (Task 9)

    /// The shared cross-block selection state. Ordinals index into `rows`
    /// (loaded/visible order). Cleared on ANY rows-array change (see
    /// `clearCrossBlockSelection`), so it never carries a stale ordinal.
    private var selection = TranscriptSelectionCoordinator()
    /// True while a mouse drag has escalated past a card boundary and the
    /// coordinator (not a native text view) owns the selection.
    private var crossBlockDragActive = false
    /// Auto-scroll timer while dragging near a viewport edge. Each tick derives
    /// the cursor from live `NSEvent.mouseLocation` (see `autoScrollTick`), so
    /// no drag event is retained.
    private var autoScrollTimer: Timer?

    // MARK: External jump intents (Task 8)

    /// Last `firstPromptJumpToken` this controller has already acted on. A
    /// token equal to this is a REPLAY (e.g. the representable was recreated
    /// when the user switched Terminal → Rich with a stale token still set on
    /// the SwiftUI side) and must be ignored, not re-fired.
    private var lastConsumedFirstPromptJumpToken: Int = 0
    /// Set when a first-prompt jump arrived while the snapshot was still
    /// computing (or its indices were momentarily empty) — re-checked on every
    /// subsequent `updateNSView` intent pass, firing once the snapshot is
    /// resolvable (not computing, indices non-empty).
    private var pendingFirstPromptJump: Bool = false

    /// Last `eventJumpToken` this controller has already acted on. Same
    /// replay-guard discipline as the first-prompt token.
    private var lastConsumedEventJumpToken: Int = 0
    /// Event id stashed when the anchor map didn't (yet) resolve it — either
    /// the snapshot is still computing, or the event lives outside the
    /// currently-computed anchor map for some other transient reason.
    /// Re-checked on every subsequent `updateNSView` intent pass, firing once
    /// the map resolves it.
    private var pendingEventJumpID: String?

    /// Last `userPromptIndexJumpToken` this controller has already acted on.
    private var lastConsumedUserPromptIndexJumpToken: Int = 0
    /// Stashed ordinal into `userBlockIndices` when the snapshot wasn't ready.
    /// Re-checked on every subsequent `updateNSView` intent pass.
    private var pendingUserPromptIndex: Int?

    // MARK: Find state (Task 10)

    /// Whole-session matches for the active query (from
    /// `derivedState.findMatches`, off-window hits included). Ordinal-ordered,
    /// block-ascending. Empty when no query is active.
    private var findMatches: [TranscriptDerivedState.BlockMatch] = []
    /// Ordinal of the current match into `findMatches`. Meaningful only when
    /// `findMatches` is non-empty; clamped/reconciled on every recompute.
    private var findCurrentOrdinal: Int = 0
    /// The active find query (trimmed). Empty ⇒ find inactive; drives whether
    /// `configure` paints highlights / pills for a (recycled) row.
    private var findQuery: String = ""
    /// Last find-request token consumed, PER source (local ⌘F / unified). The
    /// two token counters are independent (they can hold the same value), so a
    /// shared watermark would misfire; keep one per source. Same replay-guard
    /// discipline the jump intents use, so a Terminal↔Rich remount can't replay
    /// a stale find.
    private var lastConsumedLocalFindToken: Int = 0
    private var lastConsumedUnifiedFindToken: Int = 0
    /// Matches grouped by the row id that renders them, recomputed whenever the
    /// match list or the row set changes. For a message row the key is the
    /// block's own index; for a tool group it's the group's first-block id. Used
    /// to paint per-row highlights and the collapsed-row count pill without
    /// re-scanning the flat list per cell.
    private var findMatchesByRowID: [Int: [TranscriptDerivedState.BlockMatch]] = [:]
    /// Which query source currently owns the shared highlight/count state. Both
    /// the local find bar and the unified-search pill route through one find
    /// state; the last one to change its token wins and becomes active, so a
    /// rows-change refresh reports counts back to the right binding.
    enum FindSource { case none, local, unified }
    private(set) var activeFindSource: FindSource = .none

    /// Last find-request tokens SEEN at `updateNSView` (distinct from the
    /// replay-guard watermarks inside `applyFind`). Seeded in `makeNSView` from
    /// the current prop values so a Terminal↔Rich remount doesn't replay the
    /// pre-existing token as a fresh request; only a post-mount increment fires.
    private var lastSeenLocalFindToken: Int = 0
    private var lastSeenUnifiedFindToken: Int = 0
    /// Cheap fingerprint of the current rows array (count + first/last id),
    /// captured whenever find state is (re)computed. A refresh pass skips work
    /// when both the match list and this fingerprint are unchanged.
    private var lastFindRowsFingerprint: Int = 0

    /// Rows fingerprint: count + first + last row id. Enough to detect any
    /// widen/prepend/append/wholesale change (which all shift the window edges
    /// or count) without hashing every row.
    private func rowsFingerprint() -> Int {
        var h = Hasher()
        h.combine(rows.count)
        h.combine(rows.first?.id ?? -1)
        h.combine(rows.last?.id ?? -1)
        return h.finalize()
    }
    /// True (once) when `token` differs from the last-seen local find token,
    /// recording it. Drives whether `updateNSView` treats this as a new request.
    func consumeLocalFindToken(_ token: Int) -> Bool {
        guard token != lastSeenLocalFindToken else { return false }
        lastSeenLocalFindToken = token
        return true
    }
    func consumeUnifiedFindToken(_ token: Int) -> Bool {
        guard token != lastSeenUnifiedFindToken else { return false }
        lastSeenUnifiedFindToken = token
        return true
    }
    /// Seed both find watermarks + last-seen trackers at mount so a remount with
    /// stale tokens doesn't replay. Called from `makeNSView`.
    func seedConsumedFindTokens(findToken: Int, unifiedFindToken: Int) {
        lastConsumedLocalFindToken = findToken
        lastConsumedUnifiedFindToken = unifiedFindToken
        lastSeenLocalFindToken = findToken
        lastSeenUnifiedFindToken = unifiedFindToken
    }

    // `toolState` folds collapsed/expanded/showAll into the cache key so a
    // toggle can never read back a stale height computed under the other
    // state (the classic recycling-height defect this row type invites).
    private struct HeightKey: Hashable {
        var rowID: Int
        var widthBucket: Int
        var fontBucket: Int
        var toolState: ToolRowHeightState
    }

    private enum ToolRowHeightState: Hashable {
        /// Not a tool card — state doesn't affect height.
        case notApplicable
        case collapsed
        case expandedTruncated
        case expandedShowAll
    }

    // MARK: Attach / teardown

    func attach(table: NSTableView, scroll: NSScrollView) {
        self.table = table
        self.scroll = scroll
        table.dataSource = self
        table.delegate = self
        installWidthObserver(on: scroll)
        installScrollObserver(on: scroll)
        installAppearanceObserver(on: table)
    }

    func tearDown() {
        if let frameObserver {
            NotificationCenter.default.removeObserver(frameObserver)
            self.frameObserver = nil
        }
        if let scrollObserver {
            NotificationCenter.default.removeObserver(scrollObserver)
            self.scrollObserver = nil
        }
        appearanceObservation?.invalidate()
        appearanceObservation = nil
        observedClipView = nil
        stopAutoScroll()
        table?.dataSource = nil
        table?.delegate = nil
    }

    private func installWidthObserver(on scroll: NSScrollView) {
        let clip = scroll.contentView
        clip.postsFrameChangedNotifications = true
        observedClipView = clip
        frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: clip,
            queue: .main
        ) { [weak self] _ in
            self?.handleWidthChangeIfNeeded()
        }
    }

    /// Observe the clip view's bounds (scroll position). Same house idiom as
    /// `PlainTextScrollView.installScrollObserverIfNeeded` /
    /// `SessionTerminalView` — `postsBoundsChangedNotifications` on the same
    /// contentView the width observer watches for `frameDidChange`. Distinct
    /// notification (`boundsDidChange`), so the two never collide.
    private func installScrollObserver(on scroll: NSScrollView) {
        let clip = scroll.contentView
        clip.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clip,
            queue: .main
        ) { [weak self] _ in
            self?.handleScrollPositionChanged()
        }
    }

    /// Bounds observer body: refresh sticky-bottom and, when the flag allows,
    /// consider a load-older extension.
    private func handleScrollPositionChanged() {
        updateNearBottomFlag()
        maybeScheduleLoadOlder()
    }

    // MARK: Appearance change (Task 12)

    /// KVO the table view's `effectiveAppearance`. Markdown bodies bake resolved
    /// colors (the inline-code chip) at render time and are cached keyed by
    /// `isDark`, so a dark/light flip must drop the render cache and re-render
    /// visible cells. Seeds `lastRenderedIsDark` so the first real flip is
    /// detected; unrelated appearance-graph churn that doesn't change our dark
    /// flag is a no-op.
    private func installAppearanceObserver(on table: NSTableView) {
        lastRenderedIsDark = effectiveAppearanceIsDark
        appearanceObservation = table.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            // KVO may deliver off the main actor in theory; hop to main for UI.
            DispatchQueue.main.async { self?.handleEffectiveAppearanceChanged() }
        }
    }

    private func handleEffectiveAppearanceChanged() {
        let isDark = effectiveAppearanceIsDark
        guard isDark != lastRenderedIsDark else { return }
        lastRenderedIsDark = isDark
        // Baked colors are stale for the new appearance → drop the render cache
        // (and heights, since a re-render produces new RenderedBody identities the
        // height cache keys don't distinguish). Re-render visible cells and
        // re-note heights so every row picks up the new-appearance render.
        renderedBodyCache.removeAll()
        heightCache.removeAll(keepingCapacity: true)
        reconfigureVisibleRows()
        noteAllHeightsChanged()
    }

    /// Sticky-bottom: within ~1 row height of the content bottom ⇒ follow tail.
    private func updateNearBottomFlag() {
        guard let scroll = scroll, let doc = scroll.documentView else { return }
        let visible = scroll.contentView.bounds
        let maxOffset = max(0, doc.bounds.height - visible.height)
        let currentOffset = max(0, min(visible.origin.y, maxOffset))
        let distanceToBottom = max(0, maxOffset - currentOffset)
        isNearBottom = distanceToBottom <= (fontSize + 4)
    }

    // MARK: Load-older on near-top scroll (Task 7)

    /// When the viewport top is within 2 viewport-heights of content top AND the
    /// window doesn't already cover block 0, schedule a debounced extension.
    private func maybeScheduleLoadOlder() {
        guard FeatureFlags.transcriptWindowNearTopLoadOlder else { return }
        guard !isPrependInFlight else { return }
        guard let range = loadedBlockRange, range.lowerBound > 0 else { return }
        guard let scroll = scroll else { return }

        let visible = scroll.contentView.bounds
        // Distance from the current viewport top to the very top of content.
        let distanceToTop = max(0, visible.origin.y)
        let threshold = visible.height * 2
        guard distanceToTop <= threshold else { return }

        loadOlderDebounceToken &+= 1
        let token = loadOlderDebounceToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, self.loadOlderDebounceToken == token else { return }
            self.performLoadOlder()
        }
    }

    /// Extend the lower bound by `transcriptWindowBlockTarget` (clamp 0), rebuild
    /// rows, and splice the older rows in at the top WITHOUT animation, holding
    /// the viewport still via first-visible-row+offset anchor capture/restore.
    private func performLoadOlder() {
        guard !isPrependInFlight else { return }
        guard let range = loadedBlockRange, range.lowerBound > 0 else { return }
        guard !allBlocksCache.isEmpty else { return }

        isPrependInFlight = true
        defer { isPrependInFlight = false }

        let newLower = max(0, range.lowerBound - FeatureFlags.transcriptWindowBlockTarget)
        let newRange = newLower...range.upperBound
        loadedBlockRange = newRange

        let windowed = Self.slice(allBlocksCache, to: newRange)
        let newRows = TranscriptToolSummary.mergeToolRuns(Self.rowModels(from: windowed))
        applyPrepend(newRows: newRows)
    }

    /// Splice a downward-extended row set into the table with the viewport
    /// pinned. Handles the Task 6 boundary subtlety: the old top row (a lone
    /// tool card) may merge into a `.toolGroup` after the prepend, changing its
    /// id — so we diff by id and, when the boundary changed, reload that row too
    /// and drop its now-defunct expansion state.
    private func applyPrepend(newRows: [BlockRowModel]) {
        guard let table else { rows = newRows; return }

        // A prepend shifts every existing ordinal by the inserted count, so any
        // live cross-block selection is invalidated. Per the locked clear-on-any-
        // rows-change rule we drop it (this is the auto-scroll-into-load-older
        // case: the drag simply ends, no crash, no misindex).
        clearCrossBlockSelection()

        let diff = Self.prependDiff(old: rows, new: newRows)
        // Migrate/drop expansion state for a boundary row whose id changed: the
        // old lone-tool row id no longer exists as a row, so its expansion is
        // meaningless. Dropping is acceptable (documented) — a merged group
        // defaults to collapsed.
        for droppedID in diff.droppedRowIDs {
            expandedToolRowIDs.remove(droppedID)
            showAllRowIDs.remove(droppedID)
        }

        var anchor = captureScrollAnchor()
        // If the anchor row's id was dropped by a boundary merge (the first
        // visible row WAS the old lone-tool top edge that folded into a group),
        // re-point the anchor to the row in `newRows` that now contains that
        // block index — otherwise restore no-ops and the viewport jumps.
        if let a = anchor, diff.droppedRowIDs.contains(a.rowID),
           let absorbing = newRows.first(where: { row in
               row.toolBlocks.contains { $0.globalBlockIndex == a.rowID }
           }) {
            anchor = ScrollAnchor(rowID: absorbing.id, offsetIntoRow: a.offsetIntoRow)
        }
        rows = newRows
        // Find map invariant (Task 10 review): same rebuild-at-every-rows-swap
        // rule as widen. Load-older runs from the scroll-driven debounce, NOT
        // from updateNSView, so no refreshFindAfterRowsChanged pass follows —
        // without this, prepended rows (incl. a re-keyed boundary group) would
        // configure against a stale map (no highlights/pills) when
        // restoreScrollAnchor's layoutSubtreeIfNeeded materializes them.
        rebuildFindMatchesByRowIDIfActive()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            if diff.canSplice {
                if diff.insertedCount > 0 {
                    table.insertRows(at: IndexSet(integersIn: 0..<diff.insertedCount),
                                     withAnimation: [])
                }
                if diff.reloadBoundaryRow, rows.indices.contains(diff.insertedCount) {
                    table.reloadData(forRowIndexes: IndexSet(integer: diff.insertedCount),
                                     columnIndexes: IndexSet(integer: 0))
                }
            } else {
                table.reloadData()
            }
        }
        restoreScrollAnchor(anchor)
    }

    // MARK: Apply

    /// Diff the incoming windowed stream against the current rows and update the
    /// table with the cheapest correct operation.
    func apply(allBlocks: [SessionTranscriptBuilder.LogicalBlock],
               totalBlockCount: Int,
               fontSize: CGFloat,
               source: SessionSource,
               sessionID: String) {
        guard let table else { return }

        let fontChanged = fontSize != self.fontSize
        let sourceChanged = source != self.source
        self.fontSize = fontSize
        self.source = source

        // Session switch: all per-row expansion state is keyed by
        // globalBlockIndex, which is meaningless across sessions (a different
        // session can reuse the same indices) — reset unconditionally.
        if sessionID != self.sessionID {
            self.sessionID = sessionID
            expandedToolRowIDs.removeAll()
            showAllRowIDs.removeAll()
            heightCache.removeAll(keepingCapacity: true)
            renderedBodyCache.removeAll()
            loadedBlockRange = nil
            // Fresh session opens at the tail (see tailWindowRange seed) → the
            // sticky-follow flag must start true so the first append(s) track the
            // bottom. This also wins the in-flight-prepend vs session-switch race:
            // a session switch resets the flag AND establishes a new window below,
            // and the reset clears any pending prepend's assumptions.
            isNearBottom = true
            isPrependInFlight = false
            loadOlderDebounceToken &+= 1
            // A new session invalidates any pending intent stashed for the
            // PREVIOUS session's snapshot (an eventID/block index from session A
            // is meaningless against session B's anchor map / block indices).
            // Tokens themselves are monotonic app-wide so a stale token value
            // can't accidentally look "already consumed" here, but the pending
            // stash must still be dropped rather than replayed against the
            // wrong session.
            pendingFirstPromptJump = false
            pendingEventJumpID = nil
            pendingUserPromptIndex = nil
            // A session switch invalidates the whole find state (matches index a
            // different block stream). Reset it fully — the SwiftUI layer will
            // re-drive find on the new session if a query is still active.
            findQuery = ""
            findMatches = []
            findMatchesByRowID = [:]
            findCurrentOrdinal = 0
            activeFindSource = .none
            // A session switch invalidates every selection ordinal (they index a
            // different rows array now). Clear before rows are rebuilt below.
            clearCrossBlockSelection()
        }

        // Retain the full stream so scroll-driven widening can re-slice it
        // without waiting for the next SwiftUI update pass.
        allBlocksCache = allBlocks

        // Window maintenance on total-count change (live appends) / first apply.
        // T5 always re-pinned to the tail; T7 must PRESERVE a scroll-widened
        // window (lowerBound < the tail seed's lower) so a live append doesn't
        // collapse the older content the user loaded. We therefore keep the
        // existing lowerBound and only extend the upperBound to the new last
        // block — that keeps prepended history loaded while still following the
        // tail. Only a nil window (first apply / post-session-switch) seeds fresh
        // from the tail.
        if loadedBlockRange == nil {
            loadedBlockRange = Self.tailWindowRange(totalBlocks: totalBlockCount)
        } else if totalBlockCount != self.totalBlockCount {
            loadedBlockRange = Self.extendedTailRange(existing: loadedBlockRange,
                                                      totalBlocks: totalBlockCount)
        }
        self.totalBlockCount = totalBlockCount

        let windowed = Self.slice(allBlocks, to: loadedBlockRange)
        let newRows = TranscriptToolSummary.mergeToolRuns(Self.rowModels(from: windowed))

        // Font change forces a full re-measure + re-render of bodies. The
        // RenderKey embeds fontBucket so stale entries would already miss, but
        // clear to bound memory (old-size renders are now dead).
        if fontChanged {
            heightCache.removeAll(keepingCapacity: true)
            renderedBodyCache.removeAll()
        }

        // Follow-tail stickiness. Refresh the sticky flag from a live measurement
        // (the debounced bounds-observer value can lag a programmatic scroll), so
        // an at-bottom reader keeps following and a scrolled-up reader is never
        // yanked. `isScrolledToBottom` is the same near-bottom test the observer
        // uses; keep them in sync.
        if isScrolledToBottom() { isNearBottom = true }
        let sticky = isNearBottom
        let diff = Self.classifyChange(old: rows, new: newRows)

        switch diff {
        case .identical where !fontChanged && !sourceChanged:
            return
        case .identical:
            // Same rows, but font/source changed → re-render visible cells and
            // re-measure all heights.
            rows = newRows
            reconfigureVisibleRows()
            noteAllHeightsChanged()
        case .appendOnly(let appendedCount):
            let firstNew = rows.count
            rows = newRows
            let idx = IndexSet(integersIn: firstNew..<(firstNew + appendedCount))
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0
                table.insertRows(at: idx, withAnimation: [])
            }
            // Sticky ⇒ ride the tail. Scrolled up ⇒ do NOT move (and, per brief,
            // no unseen-updates affordance here — that's a later task's concern).
            if sticky { scrollToBottom() }
        case .wholesale:
            // Wholesale reorder/replacement invalidates every selection ordinal.
            clearCrossBlockSelection()
            let anchor = captureScrollAnchor()
            rows = newRows
            table.reloadData()
            if sticky {
                scrollToBottom()
            } else {
                restoreScrollAnchor(anchor)
            }
        }
    }

    // MARK: Window helpers

    private static func tailWindowRange(totalBlocks: Int) -> ClosedRange<Int>? {
        guard totalBlocks > 0 else { return nil }
        guard FeatureFlags.transcriptWindowedBuild,
              totalBlocks > FeatureFlags.transcriptWindowBlockTarget else {
            return 0...(totalBlocks - 1)
        }
        // lastWindow is never empty for totalBlocks > 0 (TranscriptWindow contract),
        // so no isEmpty guard is needed here.
        let window = TranscriptWindow.lastWindow(totalBlocks: totalBlocks,
                                                 blockTarget: FeatureFlags.transcriptWindowBlockTarget)
        return window.lowerBlock...window.upperBlock
    }

    /// On a live append, keep whatever lower bound the user has scroll-widened to
    /// and just extend the upper bound to the new last block. This preserves
    /// prepended history instead of collapsing back to the last-400 tail window
    /// (which would force a wholesale reload and lose the reader's context).
    /// Pure so it can be reasoned about / tested.
    static func extendedTailRange(existing: ClosedRange<Int>?,
                                  totalBlocks: Int) -> ClosedRange<Int>? {
        guard totalBlocks > 0 else { return nil }
        guard let existing else { return tailWindowRange(totalBlocks: totalBlocks) }
        let lastBlock = totalBlocks - 1
        let lower = min(existing.lowerBound, lastBlock)
        let upper = max(existing.upperBound, lastBlock)
        return lower...min(upper, lastBlock)
    }

    /// Slice the full stream by GLOBAL block index. Blocks carry
    /// `globalBlockIndex`, which equals array position in the derived snapshot,
    /// so a range filter is boundary-safe (blocks are already coalesced).
    private static func slice(_ blocks: [SessionTranscriptBuilder.LogicalBlock],
                              to range: ClosedRange<Int>?) -> ArraySlice<SessionTranscriptBuilder.LogicalBlock> {
        guard let range, !blocks.isEmpty else { return blocks[...] }
        let lower = max(0, range.lowerBound)
        let upper = min(blocks.count - 1, range.upperBound)
        guard lower <= upper else { return blocks[blocks.endIndex..<blocks.endIndex] }
        return blocks[lower...upper]
    }

    /// 1 block = 1 message row. Callers (namely `apply`) pipe this through
    /// `TranscriptToolSummary.mergeToolRuns` to fold consecutive tool blocks
    /// into `.toolGroup` rows before diffing/rendering.
    static func rowModels(from blocks: ArraySlice<SessionTranscriptBuilder.LogicalBlock>) -> [BlockRowModel] {
        blocks.map { BlockRowModel(id: $0.globalBlockIndex, content: .message($0)) }
    }

    // MARK: Change classification

    enum ChangeKind: Equatable {
        case identical
        case appendOnly(count: Int)
        case wholesale
    }

    /// Pure diff used to pick the cheapest table op. Append-only means `new`
    /// starts with exactly `old` (by id) and has extra rows at the tail.
    static func classifyChange(old: [BlockRowModel], new: [BlockRowModel]) -> ChangeKind {
        if old == new { return .identical }
        if new.count > old.count {
            var prefixMatches = true
            for i in old.indices where old[i] != new[i] {
                prefixMatches = false
                break
            }
            if prefixMatches { return .appendOnly(count: new.count - old.count) }
        }
        return .wholesale
    }

    // MARK: Prepend (load-older) boundary diff

    /// Result of diffing a downward-window-extension against the current rows.
    /// The new rows are the old rows with a block of OLDER rows prepended — but
    /// the OLD first row's id can CHANGE if it was a lone tool card that now
    /// merges into a `.toolGroup` with the newly-prepended tool blocks
    /// (Task 6). So the new rows are NOT guaranteed to contain the old rows as a
    /// strict suffix by id; the boundary row must be treated as part of the
    /// prepend delta and reloaded.
    struct PrependDiff: Equatable {
        /// Number of brand-new rows spliced in at index 0 (ids absent from old).
        /// Only meaningful when `canSplice` is true.
        var insertedCount: Int
        /// The surviving old-first row's content changed and must be reloaded in
        /// place at `insertedCount` after the splice.
        var reloadBoundaryRow: Bool
        /// Old row ids that no longer exist as rows after the merge (their
        /// expansion state should be dropped). Non-empty implies `canSplice`
        /// is false (a removed row can't be expressed as a pure top-insert), so
        /// the caller reloads — but still uses this list to prune stale state.
        var droppedRowIDs: [Int]
        /// True ⇒ the change is a pure top-insert (+ optional boundary reload) and
        /// the caller may `insertRows`. False ⇒ shape isn't a clean prepend (or a
        /// boundary row was removed by a merge); caller should `reloadData`.
        var canSplice: Bool
    }

    /// Pure diff for load-older. `new` should equal `old` with older rows
    /// prepended, possibly with the boundary row re-keyed by a tool-run merge
    /// across the old window edge.
    ///
    /// Algorithm: the OLD rows (minus a possibly-merged first row) must appear
    /// as a contiguous SUFFIX of `new`, matched by id. We locate the old
    /// SECOND row's id in `new`; everything before it is the prepend delta
    /// (inserted + a possibly-changed boundary row). If the old set had only one
    /// row, we anchor on nothing and treat all-but-last as inserted.
    static func prependDiff(old: [BlockRowModel], new: [BlockRowModel]) -> PrependDiff {
        // Degenerate: no prior rows ⇒ everything is inserted, nothing to anchor.
        guard !old.isEmpty else {
            return PrependDiff(insertedCount: new.count, reloadBoundaryRow: false,
                               droppedRowIDs: [], canSplice: true)
        }
        // New must be at least as long and end with the old tail.
        guard new.count >= old.count else {
            return PrependDiff(insertedCount: 0, reloadBoundaryRow: false,
                               droppedRowIDs: [], canSplice: false)
        }

        // Anchor: the old row that is guaranteed NOT to change identity under a
        // downward extension is any row strictly after the first (the merge can
        // only reach the OLD first row, never deeper — a run is contiguous and
        // the second old row already sat at a run boundary or a non-tool row).
        // With a single old row there's no safe interior anchor, so we anchor on
        // the LAST row (which cannot merge downward — nothing newer is added).
        let anchorOldIndex = old.count >= 2 ? 1 : old.count - 1
        let anchorID = old[anchorOldIndex].id

        guard let anchorNewIndex = new.firstIndex(where: { $0.id == anchorID }) else {
            return PrependDiff(insertedCount: 0, reloadBoundaryRow: false,
                               droppedRowIDs: [], canSplice: false)
        }

        // The old suffix from anchorOldIndex onward must match new from
        // anchorNewIndex onward, 1:1 by id, to the end.
        guard new.count - anchorNewIndex == old.count - anchorOldIndex else {
            return PrependDiff(insertedCount: 0, reloadBoundaryRow: false,
                               droppedRowIDs: [], canSplice: false)
        }
        var k = 0
        while anchorOldIndex + k < old.count {
            if old[anchorOldIndex + k].id != new[anchorNewIndex + k].id {
                return PrependDiff(insertedCount: 0, reloadBoundaryRow: false,
                                   droppedRowIDs: [], canSplice: false)
            }
            k += 1
        }

        // Everything in `new` before `anchorNewIndex` is the prepend delta. The
        // LAST row of that delta is the boundary — if its id differs from the
        // old first row's id, the old first row merged away (dropped) and this
        // boundary row is new content that needs a configure pass. If ids match
        // but content changed (rare), also reload it.
        let boundaryNewIndex = anchorNewIndex - 1
        var droppedRowIDs: [Int] = []
        var reloadBoundaryRow = false
        var insertedCount = anchorNewIndex

        if old.count >= 2 {
            let oldFirst = old[0]
            if boundaryNewIndex >= 0 {
                let boundaryRow = new[boundaryNewIndex]
                if boundaryRow.id != oldFirst.id {
                    // Old first row's id vanished (merged into a group). This is a
                    // REMOVE+insert, not a pure top-insert, so `insertRows` alone
                    // can't express it (the table's row count would diverge). Fall
                    // back to reloadData; still report the dropped id so the caller
                    // prunes its now-defunct expansion state, and so the viewport
                    // anchor can be re-pointed to the absorbing group.
                    droppedRowIDs.append(oldFirst.id)
                    return PrependDiff(insertedCount: 0, reloadBoundaryRow: false,
                                       droppedRowIDs: droppedRowIDs, canSplice: false)
                } else {
                    // old[0] SURVIVES at boundaryNewIndex (id matches). Only the
                    // rows strictly before it are new, so insertedCount excludes
                    // it. Reload it in place iff its content changed.
                    insertedCount = boundaryNewIndex
                    reloadBoundaryRow = (boundaryRow != oldFirst)
                }
            } else {
                // boundaryNewIndex < 0 ⇒ anchorNewIndex == 0, i.e. old[1] (the
                // anchor) landed at the very start of `new`, leaving no slot for
                // old[0]'s boundary row at all. Not reachable via the current sole
                // caller (whose window-widen math always leaves room above the
                // anchor), but this shape can't be expressed as a pure top-insert
                // either way — degrade to the same safe "reload everything" result
                // the other non-spliceable branches return, rather than falling
                // through with a bogus canSplice: true.
                return PrependDiff(insertedCount: 0, reloadBoundaryRow: false,
                                   droppedRowIDs: [], canSplice: false)
            }
        } else {
            // Single old row anchored on itself as the last row; nothing above it
            // in old, so no boundary reconfigure beyond plain inserts.
            insertedCount = anchorNewIndex
        }

        return PrependDiff(insertedCount: insertedCount,
                           reloadBoundaryRow: reloadBoundaryRow,
                           droppedRowIDs: droppedRowIDs,
                           canSplice: true)
    }

    // MARK: NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    // MARK: NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        let cell: BlockCardCellView
        if let reused = tableView.makeView(withIdentifier: BlockCardCellView.reuseID, owner: self) as? BlockCardCellView {
            cell = reused
        } else {
            cell = BlockCardCellView()
            cell.identifier = BlockCardCellView.reuseID
        }
        configure(cell: cell, forRowModel: rows[row], ordinal: row)
        return cell
    }

    /// Single call site for `BlockCardCellView.configure`, so every path
    /// (initial render, visible-row reconfigure, single-row toggle) passes
    /// the exact same expansion/show-all/callback wiring. `ordinal` is the row's
    /// index into `rows` — the coordinate space the selection coordinator uses.
    private func configure(cell: BlockCardCellView, forRowModel rowModel: BlockRowModel, ordinal: Int) {
        cell.configure(row: rowModel,
                       fontSize: fontSize,
                       source: source,
                       isExpanded: expandedToolRowIDs.contains(rowModel.id),
                       showAll: showAllRowIDs.contains(rowModel.id),
                       lineLimit: CardMetrics.toolBodyTruncationLineLimit,
                       findMatchCount: findMatchCount(forRowID: rowModel.id),
                       renderedBody: renderedBody(for: rowModel),
                       onToggleExpansion: { [weak self] in self?.toggleToolExpansion(rowID: rowModel.id) },
                       onToggleShowAll: { [weak self] in self?.toggleShowAll(rowID: rowModel.id) })
        // Flash reset/paint. A recycle mid-flash re-raises alpha on the flashing
        // row and forces every other row back to base — so the pulse can never
        // get stuck on a recycled cell.
        cell.setFlashAlpha(isFlashing(rowID: rowModel.id) ? Self.flashRaisedAlpha : CardMetrics.cardTintAlpha)

        // Cross-block selection wiring: stamp the ordinal + controller ref, reset
        // any stale highlight, then (if a live cross-block selection covers this
        // row) paint its portion so a scrolled-into-view cell shows selection.
        cell.wireSelection(controller: self, ordinal: ordinal, coordinatorActive: crossBlockDragActive)
        if crossBlockDragActive {
            let len = (renderedSelectableText(for: rowModel) as NSString).length
            let range = selection.selectionRange(blockOrdinal: ordinal, textLength: len)
                ?? NSRange(location: 0, length: 0)
            cell.applySelectionRange(range)
        }

        // Find highlights (Task 10). Paint directly here for RENDERABLE rows only
        // — the collapsed-card pill was already fed via `findMatchCount` above, so
        // this path must NOT reconfigure (that would recurse). A recycled cell
        // scrolling into view under an active query thus shows its highlights.
        // `cell.configure` already stripped any stale highlight, so a row with no
        // matches needs no work here.
        if !findQuery.isEmpty {
            applyRenderableFindHighlights(on: cell, rowModel: rowModel)
        }
    }

    /// Paint in-body find highlights for a renderable row (message / single
    /// expanded tool card). Non-renderable rows are skipped — their count shows
    /// on the pill. Safe to call from `configure` (never reconfigures).
    private func applyRenderableFindHighlights(on cell: BlockCardCellView, rowModel: BlockRowModel) {
        let shape = findRowShape(for: rowModel)
        if case .nonRenderable = shape { cell.clearFindHighlights(); return }
        let rowMatches = findMatchesByRowID[rowModel.id] ?? []
        let current: TranscriptDerivedState.BlockMatch? =
            findMatches.indices.contains(findCurrentOrdinal) ? findMatches[findCurrentOrdinal] : nil
        var ranges: [NSRange] = []
        var currentRange: NSRange?
        for m in rowMatches {
            guard let r = TranscriptFindNavigator.renderableRange(m.rangeInBlockText, shape: shape) else { continue }
            ranges.append(r)
            if let current, m.globalBlockIndex == current.globalBlockIndex,
               NSEqualRanges(m.rangeInBlockText, current.rangeInBlockText) {
                currentRange = r
            }
        }
        // Always apply (strips first) — empty ranges cleanly clear a row whose
        // highlights moved away under a re-navigation.
        cell.applyFindHighlights(all: ranges, current: currentRange)
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard rows.indices.contains(row) else { return CardMetrics.minCardHeight }
        return measuredHeight(for: rows[row], width: currentBodyWidth())
    }

    // Prevent selection chrome entirely (belt-and-suspenders with .none style).
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    // MARK: Height measurement

    private func currentBodyWidth() -> CGFloat {
        let tableWidth = table?.bounds.width ?? scroll?.contentView.bounds.width ?? 0
        return max(1, tableWidth - CardMetrics.horizontalChrome)
    }

    private func widthBucket(_ width: CGFloat) -> Int {
        // 1pt granularity is fine; boundingRect is stable and cheap enough, and
        // width changes are the only invalidation trigger.
        Int(width.rounded())
    }

    private func fontBucket(_ size: CGFloat) -> Int { Int((size * 2).rounded()) }

    /// Pure predicate: whether a width change should invalidate `heightCache`.
    /// `heightCache` is keyed by `widthBucket`, so sub-pixel width churn that
    /// rounds to the SAME bucket leaves every cached height still valid — only
    /// an actual bucket change can stale an entry. `oldBucket == nil` (no prior
    /// measurement yet) always invalidates so the first layout pass seeds it.
    static func shouldInvalidateForWidth(oldBucket: Int?, newBucket: Int) -> Bool {
        oldBucket != newBucket
    }

    /// The exact text `BlockCardCellView` renders in the body for this row —
    /// height measurement MUST match this, not the plain `row.bodyText`,
    /// because a `.toolGroup`'s expanded body is the bullet+summary-annotated
    /// text from `BlockCardCellView.expandedToolBodyText`, not the raw
    /// `\n\n`-joined block text.
    private func renderedBodyText(for row: BlockRowModel) -> String {
        row.isToolCard ? BlockCardCellView.expandedToolBodyText(blocks: row.toolBlocks) : row.bodyText
    }

    private func toolRowHeightState(for row: BlockRowModel) -> ToolRowHeightState {
        guard row.isToolCard else { return .notApplicable }
        guard expandedToolRowIDs.contains(row.id) else { return .collapsed }
        let text = renderedBodyText(for: row)
        let lineCount = text.isEmpty ? 0 : text.components(separatedBy: "\n").count
        if lineCount > CardMetrics.toolBodyTruncationLineLimit && !showAllRowIDs.contains(row.id) {
            return .expandedTruncated
        }
        return .expandedShowAll
    }

    private func measuredHeight(for row: BlockRowModel, width: CGFloat) -> CGFloat {
        if row.isMeta { return CardMetrics.metaSeparatorHeight }

        let toolState = toolRowHeightState(for: row)
        let key = HeightKey(rowID: row.id,
                            widthBucket: widthBucket(width),
                            fontBucket: fontBucket(fontSize),
                            toolState: toolState)
        if let cached = heightCache[key] { return cached }

        // Markdown message rows measure the RENDERED attributed string (same one
        // the cell displays), not the raw block text — the syntax-stripped,
        // proportional-font layout is a different height than the monospaced
        // source. `renderedBody(for:)` returns nil for every non-markdown row, so
        // this branch is user/assistant-only and tool/meta paths are unchanged.
        if row.isMarkdownMessage, let body = renderedBody(for: row) {
            let h = markdownCardHeight(body: body, width: width)
            heightCache[key] = h
            return h
        }

        let h: CGFloat
        switch toolState {
        case .notApplicable:
            h = Self.computeHeight(text: row.bodyText, width: width, fontSize: fontSize)
        case .collapsed:
            h = CardMetrics.toolCardCollapsedHeight
        case .expandedTruncated:
            let text = renderedBodyText(for: row)
            let truncated = Self.truncatedBody(text, lineLimit: CardMetrics.toolBodyTruncationLineLimit)
            h = Self.computeHeight(text: truncated, width: width, fontSize: fontSize)
                + CardMetrics.showAllRowHeight
        case .expandedShowAll:
            let text = renderedBodyText(for: row)
            h = Self.computeHeight(text: text, width: width, fontSize: fontSize)
        }
        heightCache[key] = h
        return h
    }

    /// First `lineLimit` lines of `text`, joined back with newlines. Pure,
    /// used both for height measurement and for what the cell actually shows.
    static func truncatedBody(_ text: String, lineLimit: Int) -> String {
        let lines = text.components(separatedBy: "\n")
        guard lines.count > lineLimit else { return text }
        return lines.prefix(lineLimit).joined(separator: "\n")
    }

    /// Pure height computation: header band + measured monospaced body + insets.
    static func computeHeight(text: String, width: CGFloat, fontSize: CGFloat) -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let trimmedEmpty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        let bodyHeight: CGFloat
        if trimmedEmpty {
            bodyHeight = 0
        } else {
            let attr = NSAttributedString(string: text, attributes: [.font: font])
            let bounding = attr.boundingRect(
                with: NSSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading])
            bodyHeight = ceil(bounding.height)
        }

        let content = CardMetrics.headerHeight
            + (bodyHeight > 0 ? CardMetrics.headerToBodyGap + bodyHeight : 0)
            + CardMetrics.bodyBottomInset
        return max(CardMetrics.minCardHeight, content)
    }

    // MARK: Markdown rendering + measurement (Task 12)

    /// Cache-backed rendered markdown body for a user/assistant row, or `nil` for
    /// any row that is NOT a markdown message (tool card, tool group, error,
    /// meta) — those keep their existing plain-string path. The key is stable
    /// across window shifts (eventID) and invalidates on streaming edits
    /// (textHash), font change (fontBucket), and appearance flip (isDark).
    func renderedBody(for row: BlockRowModel) -> RenderedBody? {
        guard row.isMarkdownMessage else { return nil }
        let block = row.primaryBlock
        let isDark = effectiveAppearanceIsDark
        let key = RenderKey(eventID: block.eventID,
                            textHash: block.text.hashValue,
                            fontBucket: fontBucket(fontSize),
                            isDark: isDark)
        if let cached = renderedBodyCache.get(key) { return cached }
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let body = MarkdownBodyRenderer.render(block.text, baseFont: font, isDark: isDark)
        renderedBodyCache.set(key, body)
        return body
    }

    /// Height of `attributed` laid out at `width` via a throwaway TextKit stack
    /// with `lineFragmentPadding = 0` (matching the body text view's container),
    /// so the measured height equals what the cell lays out. The attributed
    /// string measured here MUST be the SAME one the cell displays — the
    /// controller measures `renderedBody.attributed` and the cell sets that exact
    /// object into `bodyText.textStorage` (attribute parity; the Phase-1 ShowAll
    /// bug class where a differently-attributed measure string clipped the body).
    static func measuredHeight(of attributed: NSAttributedString, width: CGFloat) -> CGFloat {
        guard attributed.length > 0 else { return 0 }
        let storage = NSTextStorage(attributedString: attributed)
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        let manager = NSLayoutManager()
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        return ceil(manager.usedRect(for: container).height)
    }

    /// Card height for a markdown row: header band + measured markdown body +
    /// insets, mirroring `computeHeight`'s chrome math but measuring the rendered
    /// attributed string instead of a monospaced plain string.
    private func markdownCardHeight(body: RenderedBody, width: CGFloat) -> CGFloat {
        let bodyHeight = Self.measuredHeight(of: body.attributed, width: width)
        let content = CardMetrics.headerHeight
            + (bodyHeight > 0 ? CardMetrics.headerToBodyGap + bodyHeight : 0)
            + CardMetrics.bodyBottomInset
        return max(CardMetrics.minCardHeight, content)
    }

    // MARK: Width change handling

    private func handleWidthChangeIfNeeded() {
        let bucket = widthBucket(currentBodyWidth())
        guard Self.shouldInvalidateForWidth(oldBucket: lastMeasuredWidthBucket, newBucket: bucket) else { return }
        lastMeasuredWidthBucket = bucket
        // Width invalidation: the cache key includes the width bucket, so stale
        // entries simply miss; clear to bound memory, then re-note heights.
        heightCache.removeAll(keepingCapacity: true)
        noteAllHeightsChanged()
    }

    private func noteAllHeightsChanged() {
        guard let table, !rows.isEmpty else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<rows.count))
        }
    }

    private func reconfigureVisibleRows() {
        guard let table else { return }
        let visible = table.rows(in: table.visibleRect)
        guard visible.length > 0 else { return }
        for row in visible.lowerBound..<visible.upperBound where rows.indices.contains(row) {
            if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? BlockCardCellView {
                configure(cell: cell, forRowModel: rows[row], ordinal: row)
            }
        }
    }

    // MARK: Tool-card expansion toggles

    /// Toggle a tool card's collapsed/expanded state. Called from the header
    /// click target (the whole collapsed header row, not just the chevron
    /// glyph). Notes the single row's height change inside a 0.15s animation
    /// group, capturing/restoring the scroll anchor when the toggled row sits
    /// above the current viewport (so content below doesn't visually jump).
    func toggleToolExpansion(rowID: Int) {
        guard let rowIndex = rows.firstIndex(where: { $0.id == rowID }) else { return }
        // Collapse/expand changes this row's rendered text and its
        // included/excluded status — clear any live cross-block selection so an
        // ordinal can't reference now-different text (locked clear-on-change rule).
        clearCrossBlockSelection()
        if expandedToolRowIDs.contains(rowID) {
            expandedToolRowIDs.remove(rowID)
        } else {
            expandedToolRowIDs.insert(rowID)
        }
        noteHeightChanged(forRowAt: rowIndex)
    }

    /// Toggle "Show all N lines" for a tool card whose expanded body exceeds
    /// the 20-line truncation limit. Same animation/anchor discipline as
    /// `toggleToolExpansion`.
    func toggleShowAll(rowID: Int) {
        guard let rowIndex = rows.firstIndex(where: { $0.id == rowID }) else { return }
        // Show-all changes the rendered (truncated↔full) body text — clear any
        // live cross-block selection to keep ordinals honest.
        clearCrossBlockSelection()
        if showAllRowIDs.contains(rowID) {
            showAllRowIDs.remove(rowID)
        } else {
            showAllRowIDs.insert(rowID)
        }
        noteHeightChanged(forRowAt: rowIndex)
    }

    /// Shared height-change + scroll-anchor discipline for a single-row toggle.
    private func noteHeightChanged(forRowAt rowIndex: Int) {
        guard let table else { return }

        // Only capture/restore the anchor when the toggled row is ABOVE the
        // current viewport — the row expanding/collapsing there would
        // otherwise shove the visible content down/up by the height delta.
        // A toggle at or below the viewport doesn't need this: nothing above
        // the fold moves.
        let visible = table.rows(in: table.visibleRect)
        let toggledRowAboveViewport = visible.length > 0 && rowIndex < visible.lowerBound
        let anchor = toggledRowAboveViewport ? captureScrollAnchor() : nil

        if let cell = table.view(atColumn: 0, row: rowIndex, makeIfNecessary: false) as? BlockCardCellView {
            configure(cell: cell, forRowModel: rows[rowIndex], ordinal: rowIndex)
        }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            table.noteHeightOfRows(withIndexesChanged: IndexSet(integer: rowIndex))
        }

        if let anchor {
            restoreScrollAnchor(anchor)
        }
    }

    // MARK: Scroll anchoring

    private struct ScrollAnchor {
        var rowID: Int
        var offsetIntoRow: CGFloat
    }

    private func isScrolledToBottom() -> Bool {
        guard let scroll = scroll, let doc = scroll.documentView else { return true }
        let visibleMaxY = scroll.contentView.bounds.maxY
        let docHeight = doc.bounds.height
        // Treat "within one line" of the bottom as at-bottom.
        return visibleMaxY >= docHeight - (fontSize + 4)
    }

    private func scrollToBottom() {
        guard let table, rows.count > 0 else { return }
        DispatchQueue.main.async { [weak table] in
            guard let table, table.numberOfRows > 0 else { return }
            table.scrollRowToVisible(table.numberOfRows - 1)
        }
    }

    private func captureScrollAnchor() -> ScrollAnchor? {
        guard let table, let scroll = scroll, !rows.isEmpty else { return nil }
        let visible = table.rows(in: scroll.contentView.bounds)
        guard visible.length > 0, rows.indices.contains(visible.lowerBound) else { return nil }
        let firstVisibleRow = visible.lowerBound
        let rowRect = table.rect(ofRow: firstVisibleRow)
        let offset = scroll.contentView.bounds.minY - rowRect.minY
        return ScrollAnchor(rowID: rows[firstVisibleRow].id, offsetIntoRow: offset)
    }

    private func restoreScrollAnchor(_ anchor: ScrollAnchor?) {
        guard let anchor, let table, let scroll = scroll else { return }
        guard let newIndex = rows.firstIndex(where: { $0.id == anchor.rowID }) else { return }
        table.layoutSubtreeIfNeeded()
        let rowRect = table.rect(ofRow: newIndex)
        let targetY = rowRect.minY + anchor.offsetIntoRow
        let clamped = max(0, min(targetY, (table.bounds.height) - scroll.contentView.bounds.height))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: clamped))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    // MARK: Widen-for-jump + scroll-to-block (Task 7 primitives)

    /// Extend the loaded window DOWN so it covers `targetBlock`, mirroring
    /// `SessionTerminalView.widenWindowForJump` — both call the shared
    /// `TranscriptWindow.widenedLowerBound` for the new lower bound. Rows are
    /// rebuilt and spliced with the viewport pinned (no jump). Task 8 wires the
    /// external intent; this only exposes the controller primitive.
    ///
    /// See `TranscriptWindow.widenedLowerBound` for why a single call always
    /// suffices (no loop needed) for any distance below the current window.
    func widen(toIncludeBlock targetBlock: Int) {
        guard let range = loadedBlockRange else { return }
        guard targetBlock >= 0, targetBlock < allBlocksCache.count else { return }
        // Already loaded ⇒ nothing to widen.
        guard targetBlock < range.lowerBound || targetBlock > range.upperBound else { return }

        let upper = max(range.upperBound, targetBlock)
        let lower = TranscriptWindow.widenedLowerBound(target: targetBlock, upperBound: upper,
                                                       blockTarget: FeatureFlags.transcriptWindowBlockTarget)
        let newRange = lower...min(upper, max(0, allBlocksCache.count - 1))
        loadedBlockRange = newRange

        let windowed = Self.slice(allBlocksCache, to: newRange)
        let newRows = TranscriptToolSummary.mergeToolRuns(Self.rowModels(from: windowed))

        // A widen re-slices the window and shifts ordinals — invalidate any live
        // cross-block selection before the rows swap.
        clearCrossBlockSelection()

        // A widen can extend the window in either direction and re-key the old
        // boundary, so a plain reload is the safe, simplest correct op here (the
        // subsequent scrollToBlock re-anchors the viewport deliberately anyway).
        rows = newRows
        // Find map invariant (Task 10 review): findMatchesByRowID is keyed by
        // row ids and must be rebuilt at EVERY rows swap while a find is active.
        // This swap is the critical one: scrollToBlock calls
        // layoutSubtreeIfNeeded() right after widen, which synchronously
        // configures the newly-materialized cells — with a stale (pre-widen)
        // map they'd paint no current-match highlight and no collapsed-row
        // pills for widened-in rows (the off-window next/prev headline case).
        rebuildFindMatchesByRowIDIfActive()
        table?.reloadData()
    }

    /// Scroll the row backing `globalBlockIndex` to a top-ish position and flash
    /// its card. If the block isn't loaded, widen first. No-op if still absent.
    func scrollToBlock(_ globalBlockIndex: Int) {
        if rowIndex(forBlock: globalBlockIndex) == nil {
            widen(toIncludeBlock: globalBlockIndex)
        }
        guard let table, let rowIndex = rowIndex(forBlock: globalBlockIndex) else { return }
        table.layoutSubtreeIfNeeded()
        // Top-ish alignment: scroll the row to visible, then nudge it near the
        // top of the viewport so a jumped-to card isn't stuck at the very bottom.
        table.scrollRowToVisible(rowIndex)
        if let scroll = scroll {
            let rowRect = table.rect(ofRow: rowIndex)
            let maxY = max(0, table.bounds.height - scroll.contentView.bounds.height)
            let targetY = min(rowRect.minY, maxY)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: targetY))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        flashRow(id: rows[rowIndex].id)
    }

    // MARK: External jump intents (Task 8)

    /// Called once from `makeNSView`, BEFORE the first `updateNSView`, to
    /// baseline the consumed-token watermarks at the current prop values. A
    /// freshly-created coordinator starts at 0, but the SwiftUI-side token
    /// @State survives a Terminal<->Rich remount — without this seed, a
    /// remounted Rich view would treat every previously-consumed token as new
    /// and replay the stale jump. Seeding the tokens alone is sufficient: the
    /// target-id/index props are only ever read when their token clears the
    /// watermark, and the pending stashes are already empty on a fresh
    /// coordinator.
    func seedConsumedJumpTokens(firstPromptJumpToken: Int,
                                eventJumpToken: Int,
                                userPromptIndexJumpToken: Int) {
        lastConsumedFirstPromptJumpToken = firstPromptJumpToken
        lastConsumedEventJumpToken = eventJumpToken
        lastConsumedUserPromptIndexJumpToken = userPromptIndexJumpToken
    }

    /// Route the toolbar "jump to first user prompt" intent into Rich mode.
    /// First-prompt = first entry of `userBlockIndices` NOT in
    /// `preambleUserBlockIndexes`; when every user block is preamble (no
    /// post-preamble entry exists) this mirrors Terminal's
    /// `userPromptLineID(for: .firstUserPrompt, ...)` fallback and lands on
    /// `userBlockIndices.first` instead — i.e. still the first user block
    /// overall, not "block 0 of everything".
    ///
    /// `token` is compared against `lastConsumedFirstPromptJumpToken`, not
    /// fired unconditionally on every `updateNSView` — otherwise re-creating
    /// the representable (e.g. switching Terminal → Rich with the token left
    /// at its old value) would replay a stale intent.
    func handleFirstPromptJumpIntent(token: Int,
                                     userBlockIndices: [Int],
                                     preambleUserBlockIndexes: Set<Int>,
                                     isSnapshotComputing: Bool) {
        guard token != lastConsumedFirstPromptJumpToken else {
            // Not a new intent, but a previously-stashed one may now be
            // resolvable now that the snapshot has landed.
            if pendingFirstPromptJump {
                retryPendingFirstPromptJump(userBlockIndices: userBlockIndices,
                                            preambleUserBlockIndexes: preambleUserBlockIndexes,
                                            isSnapshotComputing: isSnapshotComputing)
            }
            return
        }
        lastConsumedFirstPromptJumpToken = token
        // Newest intent wins: drop any older unresolved stash so a stale
        // first-prompt retry can't fire after this newer intent settles.
        pendingFirstPromptJump = false

        if isSnapshotComputing || userBlockIndices.isEmpty {
            pendingFirstPromptJump = true
            return
        }
        let target = Self.firstPromptBlockIndex(userBlockIndices: userBlockIndices,
                                                preambleUserBlockIndexes: preambleUserBlockIndexes)
        guard let target else { return }
        scrollToBlock(target)
    }

    private func retryPendingFirstPromptJump(userBlockIndices: [Int],
                                             preambleUserBlockIndexes: Set<Int>,
                                             isSnapshotComputing: Bool) {
        guard !isSnapshotComputing, !userBlockIndices.isEmpty else { return }
        pendingFirstPromptJump = false
        guard let target = Self.firstPromptBlockIndex(userBlockIndices: userBlockIndices,
                                                       preambleUserBlockIndexes: preambleUserBlockIndexes) else { return }
        scrollToBlock(target)
    }

    /// Pure resolution, exposed for testing. First non-preamble user block, or
    /// (all-preamble session) the first user block overall.
    static func firstPromptBlockIndex(userBlockIndices: [Int],
                                      preambleUserBlockIndexes: Set<Int>) -> Int? {
        userBlockIndices.first(where: { !preambleUserBlockIndexes.contains($0) })
            ?? userBlockIndices.first
    }

    /// Route an event-deeplink / image-jump intent (unified-search hit
    /// navigation, image strip, cross-window deeplinks) into Rich mode.
    /// Resolves `eventID -> derivedState.snapshot.eventIDToAnchorBlockIndex`
    /// then widens/scrolls to that anchor block, mirroring
    /// `SessionTerminalView.jumpToEventID`.
    func handleEventJumpIntent(token: Int,
                               eventID: String?,
                               eventIDToAnchorBlockIndex: [String: Int],
                               isSnapshotComputing: Bool) {
        guard token != lastConsumedEventJumpToken else {
            if let pending = pendingEventJumpID {
                retryPendingEventJump(eventID: pending,
                                     eventIDToAnchorBlockIndex: eventIDToAnchorBlockIndex,
                                     isSnapshotComputing: isSnapshotComputing)
            }
            return
        }
        lastConsumedEventJumpToken = token
        // Newest intent wins: drop any older unresolved stash so a stale
        // event jump can't replay after this newer intent settles.
        pendingEventJumpID = nil
        guard let eventID, !eventID.isEmpty else { return }

        if isSnapshotComputing {
            pendingEventJumpID = eventID
            return
        }
        guard let anchorBlock = eventIDToAnchorBlockIndex[eventID] else {
            // Snapshot has landed but doesn't know this event yet (e.g. a race
            // with a very recent live-tail append) — stash and retry on the
            // next apply, same discipline as the computing case.
            pendingEventJumpID = eventID
            return
        }
        scrollToBlock(anchorBlock)
    }

    private func retryPendingEventJump(eventID: String,
                                       eventIDToAnchorBlockIndex: [String: Int],
                                       isSnapshotComputing: Bool) {
        guard !isSnapshotComputing else { return }
        guard let anchorBlock = eventIDToAnchorBlockIndex[eventID] else { return }
        pendingEventJumpID = nil
        scrollToBlock(anchorBlock)
    }

    /// Route the images window's index-based navigation variant (no eventID at
    /// the call site — see `.navigateToSessionEventFromImages`'s
    /// `userPromptIndex` payload) into Rich mode. `userPromptIndex` is an
    /// ordinal into `userBlockIndices`, mirroring Terminal's
    /// `jumpToUserPromptIndex`.
    func handleUserPromptIndexJumpIntent(token: Int,
                                         userPromptIndex: Int?,
                                         userBlockIndices: [Int],
                                         isSnapshotComputing: Bool) {
        guard token != lastConsumedUserPromptIndexJumpToken else {
            if let pending = pendingUserPromptIndex {
                retryPendingUserPromptIndexJump(userPromptIndex: pending,
                                               userBlockIndices: userBlockIndices,
                                               isSnapshotComputing: isSnapshotComputing)
            }
            return
        }
        lastConsumedUserPromptIndexJumpToken = token
        // Newest intent wins: drop any older unresolved stash so a stale
        // index jump can't replay after this newer intent settles.
        pendingUserPromptIndex = nil
        guard let userPromptIndex else { return }

        if isSnapshotComputing || !userBlockIndices.indices.contains(userPromptIndex) {
            pendingUserPromptIndex = userPromptIndex
            return
        }
        scrollToBlock(userBlockIndices[userPromptIndex])
    }

    private func retryPendingUserPromptIndexJump(userPromptIndex: Int,
                                                 userBlockIndices: [Int],
                                                 isSnapshotComputing: Bool) {
        guard !isSnapshotComputing, userBlockIndices.indices.contains(userPromptIndex) else { return }
        pendingUserPromptIndex = nil
        scrollToBlock(userBlockIndices[userPromptIndex])
    }

    // MARK: - Find (Task 10)

    /// Apply a find request. Called from `updateNSView` with the whole-session
    /// matches (`derivedState.findMatches`, so SwiftUI tracks the read), a
    /// monotonic token, a direction (+1 next / -1 prev), and a reset flag
    /// (new/changed query ⇒ jump to first match at-or-after the viewport top;
    /// otherwise step). Returns (current 1-based ordinal, total) for the find
    /// bar; total is the whole-session count (off-window included), matching
    /// Terminal's global-scan total. `source` distinguishes the local ⌘F bar
    /// from the unified-search pill, which share one highlight/count layer.
    ///
    /// Empty query ⇒ strip highlights, reset counts, return (only if THIS source
    /// owns the active find). Idempotent on a replayed token (mode-switch
    /// remount) via the per-source consumed-token watermark; a live snapshot
    /// recompute for the SAME token is handled separately by
    /// `refreshFindAfterRowsChanged`.
    @discardableResult
    func applyFind(source: FindSource,
                   query: String,
                   matches: [TranscriptDerivedState.BlockMatch],
                   token: Int,
                   direction: Int,
                   reset: Bool,
                   shouldJump: Bool) -> (current: Int, total: Int) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let consumed = (source == .unified) ? lastConsumedUnifiedFindToken : lastConsumedLocalFindToken
        func setConsumed() {
            if source == .unified { lastConsumedUnifiedFindToken = token }
            else { lastConsumedLocalFindToken = token }
        }

        // Empty query: clear everything — but only if THIS source owns the
        // active find (or none does). An empty-token bump from the inactive
        // source must not wipe the other source's live highlights.
        guard !q.isEmpty else {
            if activeFindSource == source || activeFindSource == .none {
                let hadFind = !findQuery.isEmpty
                findQuery = ""
                findMatches = []
                findMatchesByRowID = [:]
                findCurrentOrdinal = 0
                activeFindSource = .none
                if hadFind { repaintAllVisibleFind() }
            }
            setConsumed()
            return (0, 0)
        }

        // Replayed token AND unchanged query AND same active source ⇒ nothing
        // new (mode-switch remount). A genuinely new request bumps the token.
        if token == consumed && q == findQuery && activeFindSource == source {
            return (findMatches.isEmpty ? 0 : findCurrentOrdinal + 1, findMatches.count)
        }

        let queryChanged = (q != findQuery || activeFindSource != source)
        activeFindSource = source
        findQuery = q
        findMatches = matches
        rebuildFindMatchesByRowID()
        lastFindRowsFingerprint = rowsFingerprint()
        setConsumed()

        guard !matches.isEmpty else {
            findCurrentOrdinal = 0
            repaintAllVisibleFind()
            return (0, 0)
        }

        if reset || queryChanged {
            // New/changed query: jump to first match at-or-after the viewport top.
            let topBlock = firstVisibleBlockIndex()
            findCurrentOrdinal = TranscriptFindNavigator.firstOrdinalAtOrAfter(
                matches: matches, viewportTopBlock: topBlock) ?? 0
        } else {
            findCurrentOrdinal = TranscriptFindNavigator.steppedOrdinal(
                current: min(max(0, findCurrentOrdinal), matches.count - 1),
                count: matches.count,
                direction: direction)
        }

        if shouldJump { scrollToCurrentFindMatch() }
        repaintAllVisibleFind()
        return (findCurrentOrdinal + 1, matches.count)
    }

    /// Recompute find after the rows array changed under an active query (live
    /// append, widen, prepend, collapse toggle). Reconciles the current ordinal
    /// against the fresh whole-session match list (keeping the same match stable
    /// when it survives, clamping otherwise) and re-paints. No scroll — the
    /// reader stays put. Returns the refreshed (current, total) counts.
    @discardableResult
    func refreshFindAfterRowsChanged(matches: [TranscriptDerivedState.BlockMatch]) -> (current: Int, total: Int) {
        guard !findQuery.isEmpty else { return (0, 0) }
        // Fast no-op guard: unchanged whole-session matches AND unchanged rows
        // fingerprint ⇒ nothing to reconcile or repaint (keeps the common
        // `updateNSView` pass cheap). A widen/prepend/append/toggle changes the
        // fingerprint; a live snapshot recompute changes the matches.
        let fingerprint = rowsFingerprint()
        if matches == findMatches && fingerprint == lastFindRowsFingerprint {
            return (findMatches.isEmpty ? 0 : findCurrentOrdinal + 1, findMatches.count)
        }
        lastFindRowsFingerprint = fingerprint
        let previous: TranscriptDerivedState.BlockMatch? =
            findMatches.indices.contains(findCurrentOrdinal) ? findMatches[findCurrentOrdinal] : nil
        findMatches = matches
        rebuildFindMatchesByRowID()
        guard let newOrdinal = TranscriptFindNavigator.reconciledOrdinal(
            previous: previous, previousOrdinal: findCurrentOrdinal, newMatches: matches) else {
            findCurrentOrdinal = 0
            repaintAllVisibleFind()
            return (0, 0)
        }
        findCurrentOrdinal = newOrdinal
        repaintAllVisibleFind()
        return (findCurrentOrdinal + 1, matches.count)
    }

    /// Whether a find query is currently active (drives whether the SwiftUI
    /// layer routes a rows-change through `refreshFindAfterRowsChanged`).
    var isFindActive: Bool { !findQuery.isEmpty }

    /// Rows-swap hook: rebuild the row-id→matches map (and refresh the rows
    /// fingerprint) whenever `rows` is replaced while a find is active. Called
    /// from `widen` and `applyPrepend`, whose swaps are followed by SYNCHRONOUS
    /// cell configuration (`layoutSubtreeIfNeeded`) before any updateNSView
    /// refresh pass could run. `apply`'s swaps don't need this: they happen
    /// inside `updateNSView`, whose find branch runs `refreshFindAfterRowsChanged`
    /// (full map rebuild + ordinal reconcile) before AppKit's lazy cell
    /// configuration happens at layout. The matches themselves are unchanged by
    /// a pure window change (same block stream), so no ordinal reconciliation is
    /// needed here — only the row-id keying.
    private func rebuildFindMatchesByRowIDIfActive() {
        guard !findQuery.isEmpty else { return }
        rebuildFindMatchesByRowID()
        lastFindRowsFingerprint = rowsFingerprint()
    }

    /// Map each match to the row id that renders it, so per-cell paint/pill is an
    /// O(1) dictionary lookup rather than a rescan of the flat list. A match's
    /// block may sit inside a merged group whose id is the group's first block.
    private func rebuildFindMatchesByRowID() {
        var byRow: [Int: [TranscriptDerivedState.BlockMatch]] = [:]
        guard !findMatches.isEmpty else { findMatchesByRowID = [:]; return }
        // block index -> row id (only for currently-loaded rows; off-window
        // matches simply don't map to a row, which is correct — they're counted
        // in the total but have no cell to paint).
        var blockToRowID: [Int: Int] = [:]
        for row in rows {
            for b in row.toolBlocks { blockToRowID[b.globalBlockIndex] = row.id }
        }
        for m in findMatches {
            guard let rowID = blockToRowID[m.globalBlockIndex] else { continue }
            byRow[rowID, default: []].append(m)
        }
        findMatchesByRowID = byRow
    }

    /// The global block index at the top of the viewport (first visible row's
    /// primary block), used to anchor the query-change reset.
    private func firstVisibleBlockIndex() -> Int? {
        guard let table, let scroll = scroll, !rows.isEmpty else { return nil }
        let visible = table.rows(in: scroll.contentView.bounds)
        guard visible.length > 0, rows.indices.contains(visible.lowerBound) else { return nil }
        return rows[visible.lowerBound].primaryBlock.globalBlockIndex
    }

    /// Scroll to the row backing the current match's block, widening the window
    /// first if the block is off-window (parity with Text mode). Flashes the row.
    private func scrollToCurrentFindMatch() {
        guard findMatches.indices.contains(findCurrentOrdinal) else { return }
        let target = findMatches[findCurrentOrdinal].globalBlockIndex
        scrollToBlock(target) // widens if off-window, then scrolls + flashes
    }

    /// Re-paint find highlights (and pills, via reconfigure) on every visible
    /// row from the current match list + current ordinal. Cheap: one pass over
    /// visible cells. Called after any find state change.
    private func repaintAllVisibleFind() {
        guard let table else { return }
        let visible = table.rows(in: table.visibleRect)
        guard visible.length > 0 else { return }
        // The current match is derived inside applyRenderableFindHighlights
        // (via findCurrentOrdinal), so no per-call current argument is needed.
        for rowIdx in visible.lowerBound..<visible.upperBound where rows.indices.contains(rowIdx) {
            guard let cell = table.view(atColumn: 0, row: rowIdx, makeIfNecessary: false) as? BlockCardCellView else { continue }
            paintFind(on: cell, rowModel: rows[rowIdx])
        }
    }

    /// Paint a single visible cell's find state: in-body highlights for
    /// renderable rows, or (collapsed tool card) a header pill via a full
    /// reconfigure carrying the fresh count. Non-renderable-but-loaded matches
    /// (collapsed / truncated-hidden / merged-group body) contribute to the pill
    /// count, never a highlight. Called only from `repaintAllVisibleFind` (never
    /// from `configure`, so the reconfigure branch can't recurse).
    private func paintFind(on cell: BlockCardCellView, rowModel: BlockRowModel) {
        guard !findQuery.isEmpty else { cell.clearFindHighlights(); return }
        let shape = findRowShape(for: rowModel)
        if case .nonRenderable = shape {
            // Collapsed tool card / group ⇒ reconfigure so the header pill count
            // is current. Meta / other non-renderable ⇒ just ensure no stale
            // highlight. `configure` strips highlights and re-feeds the pill.
            if rowModel.isToolCard, !expandedToolRowIDs.contains(rowModel.id),
               let idx = rows.firstIndex(where: { $0.id == rowModel.id }) {
                configure(cell: cell, forRowModel: rowModel, ordinal: idx)
            } else {
                cell.clearFindHighlights()
            }
            return
        }
        applyRenderableFindHighlights(on: cell, rowModel: rowModel)
    }

    /// Classify the row's rendered shape for find-highlight mapping. Message
    /// rows and a single expanded (untruncated) tool card map block.text
    /// directly; a truncated single tool card maps only within the visible
    /// prefix; collapsed cards, merged groups, and meta rows are non-renderable.
    private func findRowShape(for row: BlockRowModel) -> TranscriptFindNavigator.RowShape {
        if row.isMeta { return .nonRenderable }
        // A user/assistant prose row renders as markdown: its body string is the
        // syntax-stripped rendered text, so a match range in block.text must map
        // through the render's source map (a range over consumed syntax → pill).
        // `renderedBody(for:)` is nil only if the row isn't markdown, which the
        // `isMarkdownMessage` guard already excludes — the `?? .message` is a
        // defensive fallback, not an expected path.
        if row.isMarkdownMessage {
            return renderedBody(for: row).map { .markdownMessage($0) } ?? .message
        }
        if !row.isToolCard { return .message }
        // Tool card / group.
        guard expandedToolRowIDs.contains(row.id) else { return .nonRenderable }
        // A merged group's expanded body is bullet-annotated (≠ block.text), so
        // per-block ranges don't map — non-renderable (pill via group count).
        guard row.toolBlocks.count == 1 else { return .nonRenderable }
        // Single expanded tool card: body string == block.text (untruncated) or
        // its first-N-lines prefix (truncated, showAll off).
        let full = row.bodyText // == block.text for a lone block
        let lines = full.components(separatedBy: "\n")
        if lines.count > CardMetrics.toolBodyTruncationLineLimit && !showAllRowIDs.contains(row.id) {
            let visible = lines.prefix(CardMetrics.toolBodyTruncationLineLimit).joined(separator: "\n")
            return .expandedSingleToolTruncated(visibleUTF16Len: (visible as NSString).length)
        }
        return .expandedSingleToolFull
    }

    /// The find-match count for a row (matches inside its backing block(s)) —
    /// consumed by `configure` to feed the collapsed-card header pill.
    func findMatchCount(forRowID rowID: Int) -> Int {
        findMatchesByRowID[rowID]?.count ?? 0
    }

    /// Row index whose row model backs (contains) `globalBlockIndex`. A
    /// `.toolGroup` row's id is its FIRST block's index, so a target that falls
    /// inside a merged group won't match by id — scan the row's backing blocks.
    private func rowIndex(forBlock globalBlockIndex: Int) -> Int? {
        if let exact = rows.firstIndex(where: { $0.id == globalBlockIndex }) { return exact }
        return rows.firstIndex { row in
            row.toolBlocks.contains { $0.globalBlockIndex == globalBlockIndex }
        }
    }

    /// Brief accent-alpha pulse on the target card. Marks `flashingRowID` so a
    /// recycle during the pulse re-raises alpha on the right cell, then resets it
    /// after the animation. `configure` clears any stale raised alpha, so the
    /// pulse can never get stuck on a recycled row.
    private func flashRow(id rowID: Int) {
        flashingRowID = rowID
        guard let table, let rowIndex = rows.firstIndex(where: { $0.id == rowID }),
              let cell = table.view(atColumn: 0, row: rowIndex, makeIfNecessary: true) as? BlockCardCellView else {
            // Cell not realized yet; the marked id will pulse on next configure.
            return
        }
        cell.setFlashAlpha(Self.flashRaisedAlpha)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.45
            cell.animateFlashAlpha(to: CardMetrics.cardTintAlpha)
        } completionHandler: { [weak self] in
            guard let self, self.flashingRowID == rowID else { return }
            self.flashingRowID = nil
            cell.setFlashAlpha(CardMetrics.cardTintAlpha)
        }
    }

    /// Raised card-fill alpha at the start of a jump flash.
    static let flashRaisedAlpha: CGFloat = 0.28

    /// Whether a given row should render with a raised flash alpha (queried by
    /// `configure` so a recycle mid-flash paints the pulse instead of dropping
    /// it, and every other row resets to base alpha).
    func isFlashing(rowID: Int) -> Bool { flashingRowID == rowID }

    // MARK: - Cross-block selection (Task 9)

    /// Rendered body text for a row — the SAME string the cell shows and the
    /// height math measures. Expanded tool groups use the bullet/summary body;
    /// a TRUNCATED expanded body copies only the visible (truncated) text
    /// ("copy what you see"); collapsed tool cards / meta rows are excluded
    /// upstream so their text never enters the copy.
    private func renderedSelectableText(for row: BlockRowModel) -> String {
        if row.isMeta { return "" }
        if row.isToolCard {
            guard expandedToolRowIDs.contains(row.id) else { return "" } // collapsed ⇒ excluded
            let full = renderedBodyText(for: row)
            let lines = full.components(separatedBy: "\n")
            if lines.count > CardMetrics.toolBodyTruncationLineLimit && !showAllRowIDs.contains(row.id) {
                return lines.prefix(CardMetrics.toolBodyTruncationLineLimit).joined(separator: "\n")
            }
            return full
        }
        // Markdown message: copy the RENDERED (syntax-stripped) text the cell
        // actually shows, so a copy of a bold word yields the word, not `**word**`
        // — and it matches the text length the cell's textStorage holds, keeping
        // cross-block selection ranges honest.
        if row.isMarkdownMessage, let body = renderedBody(for: row) {
            return body.attributed.string
        }
        return row.bodyText
    }

    /// True for a row that contributes nothing to selection: a meta separator,
    /// or a tool card that's currently collapsed. Shared by `excludedOrdinals()`
    /// (builds the full set) and `hasCopyableSelection()` (inlines this same
    /// test over just the selection span, without building the set — see that
    /// function's perf note).
    private func isExcludedFromSelection(_ row: BlockRowModel) -> Bool {
        if row.isMeta { return true }
        return row.isToolCard && !expandedToolRowIDs.contains(row.id)
    }

    /// Ordinals that contribute nothing: collapsed tool cards and meta rows.
    private func excludedOrdinals() -> Set<Int> {
        var set = Set<Int>()
        for (i, row) in rows.enumerated() {
            if isExcludedFromSelection(row) { set.insert(i) }
        }
        return set
    }

    /// Recompute the excluded set on the current rows and stash it into the
    /// coordinator before any span math or paint.
    private func refreshExcludedOrdinals() {
        selection.excludedBlockOrdinals = excludedOrdinals()
    }

    /// True while a cross-block (multi-card) selection owns the highlight —
    /// the seam `SelectableBlockTextView.copy/selectAll` use to decide between
    /// delegating here vs native NSTextView behavior. Cheap: two nil checks.
    var isCrossBlockSelectionActive: Bool { selection.isActive }

    /// Clear the cross-block selection and repaint every visible row to native.
    /// Called on ANY rows-array change (session switch, prepend, wholesale
    /// reload, collapse toggle changing text) — the locked simplest-correct rule.
    func clearCrossBlockSelection() {
        guard selection.isActive || crossBlockDragActive else { return }
        selection.clear()
        crossBlockDragActive = false
        stopAutoScroll()
        repaintAllVisibleSelectionRanges(reset: true)
    }

    /// A native click landed — drop any cross-block selection so the text view's
    /// own (native) caret/word behavior resumes cleanly.
    func clearCrossBlockSelectionForNativeClick() {
        clearCrossBlockSelection()
    }

    // MARK: Drag routing

    /// True iff the drag point (window coords in `event`) is still over the row
    /// whose ordinal is `ordinal`. Used by the body view to decide when to keep
    /// native selection vs escalate.
    func isDragPointInside(ordinal: Int, event: NSEvent) -> Bool {
        guard let table else { return true }
        let p = table.convert(event.locationInWindow, from: nil)
        let hit = table.row(at: p)
        // Outside all rows (above/below content) always escalates.
        guard hit >= 0 else { return false }
        return hit == ordinal
    }

    /// Begin (or extend) a cross-block drag. On first escalation we adopt the
    /// origin block's anchor (the offset the native drag started at) and the
    /// current point as focus; subsequent calls just extend the focus.
    func beginOrExtendCrossBlockDrag(originOrdinal: Int, anchorOffset: Int, event: NSEvent) {
        guard let table else { return }
        refreshExcludedOrdinals()

        if !crossBlockDragActive {
            crossBlockDragActive = true
            selection.begin(at: .init(blockOrdinal: originOrdinal, utf16Offset: anchorOffset))
            // Force the active-blue appearance on every visible body for the
            // duration of the multi-row selection.
            forEachVisibleCell { cell, _ in cell.bodyText.forceActiveSelectionAppearance(true) }
        }

        extendCrossBlockFocus(toWindowPoint: event.locationInWindow)
        maybeAutoScroll(for: event)
    }

    /// Resolve a drag point (WINDOW coords) to a (ordinal, offset) focus and
    /// repaint. Window coords so both live drag events and the auto-scroll
    /// tick's screen-derived location share one path.
    private func extendCrossBlockFocus(toWindowPoint windowPoint: NSPoint) {
        guard let table else { return }
        let p = table.convert(windowPoint, from: nil)
        var hit = table.row(at: p)
        if hit < 0 {
            // Above content ⇒ clamp to first row; below ⇒ clamp to last row.
            hit = p.y <= 0 ? 0 : max(0, rows.count - 1)
        }
        guard rows.indices.contains(hit) else { return }
        let offset = characterOffset(inRow: hit, tablePoint: p)
        selection.extend(to: .init(blockOrdinal: hit, utf16Offset: offset))
        repaintAllVisibleSelectionRanges(reset: false)
    }

    /// Character offset within a row's body text view for a point in TABLE
    /// coords. Rows without a realized/visible cell (offscreen) resolve to 0 or
    /// the full length by vertical position — good enough for a focus endpoint
    /// that will be re-resolved as the row scrolls into view.
    private func characterOffset(inRow row: Int, tablePoint p: NSPoint) -> Int {
        guard let table,
              let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? BlockCardCellView else {
            return 0
        }
        let body = cell.bodyText
        guard !body.isHidden else { return 0 }
        let local = body.convert(p, from: table)
        return body.characterOffset(atLocalPoint: local)
    }

    /// End of a cross-block drag: keep the selection (so ⌘C works) but stop the
    /// drag machinery. A subsequent native click clears it.
    func endCrossBlockDragIfActive(event: NSEvent) {
        guard crossBlockDragActive else { return }
        stopAutoScroll()
        // Selection endpoints stay; the coordinator remains "active" for copy.
        // crossBlockDragActive stays true so configure() keeps painting the
        // highlight on rows that scroll into view until the next native click.
    }

    // MARK: Painting

    private func forEachVisibleCell(_ body: (BlockCardCellView, Int) -> Void) {
        guard let table else { return }
        let visible = table.rows(in: table.visibleRect)
        guard visible.length > 0 else { return }
        for row in visible.lowerBound..<visible.upperBound where rows.indices.contains(row) {
            if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? BlockCardCellView {
                body(cell, row)
            }
        }
    }

    /// Paint each visible row's selection portion (or clear it when `reset`).
    private func repaintAllVisibleSelectionRanges(reset: Bool) {
        forEachVisibleCell { cell, ordinal in
            if reset {
                cell.bodyText.forceActiveSelectionAppearance(false)
                cell.applySelectionRange(NSRange(location: 0, length: 0))
                return
            }
            cell.bodyText.forceActiveSelectionAppearance(true)
            let len = (self.renderedSelectableText(for: self.rows[ordinal]) as NSString).length
            let range = self.selection.selectionRange(blockOrdinal: ordinal, textLength: len)
                ?? NSRange(location: 0, length: 0)
            cell.applySelectionRange(range)
        }
    }

    // MARK: Auto-scroll near viewport edges

    private func maybeAutoScroll(for event: NSEvent) {
        guard let scroll = scroll else { return }
        let p = scroll.contentView.convert(event.locationInWindow, from: nil)
        let bounds = scroll.contentView.bounds
        let margin: CGFloat = 24
        let outside = p.y < bounds.minY + margin || p.y > bounds.maxY - margin
        if outside {
            startAutoScrollIfNeeded()
        } else {
            stopAutoScroll()
        }
    }

    private func startAutoScrollIfNeeded() {
        guard autoScrollTimer == nil else { return }
        autoScrollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.autoScrollTick()
        }
    }

    private func stopAutoScroll() {
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
    }

    /// One auto-scroll frame: nudge the viewport toward the edge the cursor is
    /// past, then re-extend the selection focus for the (moved) content. If the
    /// nudge triggers a Task-7 load-older prepend, the rows array changes and
    /// `apply`/`applyPrepend` calls `clearCrossBlockSelection` — the drag simply
    /// ends cleanly (documented v1 behavior); we guard every access so nothing
    /// misindexes mid-tick.
    ///
    /// The cursor point is derived LIVE from `NSEvent.mouseLocation` (screen
    /// coords → window → clip view) each tick, NOT from a frozen drag event —
    /// after the content scrolls, a stale `locationInWindow` could drift out of
    /// the margin band and self-stop the scroll while the user is still holding
    /// the drag at the edge. Mouse-moved events don't fire during a stationary
    /// press, so polling the live location is the only accurate source here.
    private func autoScrollTick() {
        guard crossBlockDragActive, let scroll = scroll, let window = scroll.window else {
            stopAutoScroll(); return
        }
        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let p = scroll.contentView.convert(windowPoint, from: nil)
        let bounds = scroll.contentView.bounds
        let margin: CGFloat = 24
        let step: CGFloat = 18
        var dy: CGFloat = 0
        if p.y < bounds.minY + margin { dy = -step }
        else if p.y > bounds.maxY - margin { dy = step }
        guard dy != 0 else { stopAutoScroll(); return }

        let doc = scroll.documentView?.bounds.height ?? bounds.height
        let maxY = max(0, doc - bounds.height)
        let targetY = max(0, min(bounds.origin.y + dy, maxY))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: targetY))
        scroll.reflectScrolledClipView(scroll.contentView)

        // Re-extend for the new content under the (possibly stationary) cursor.
        // If a prepend fired during the scroll, crossBlockDragActive is now
        // false and this is a no-op.
        if crossBlockDragActive { extendCrossBlockFocus(toWindowPoint: windowPoint) }
    }

    // MARK: Copy / Select-all (responder chain)

    /// Assemble the currently-selected text across loaded rows, honoring the
    /// exclusion set (collapsed tool cards / meta). Only LOADED rows are walked —
    /// never the full derived stream — so ⌘A+⌘C on a windowed monster stays cheap.
    private func assembleSelectedText() -> String {
        refreshExcludedOrdinals()
        let texts = rows.map { renderedSelectableText(for: $0) }
        return selection.selectedText(blockTexts: texts)
    }

    @objc func copy(_ sender: Any?) {
        let text = assembleSelectedText()
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// ⌘A selects every loaded block: anchor (0,0) → focus (last, fullLength).
    @objc func selectAll(_ sender: Any?) {
        guard !rows.isEmpty else { return }
        refreshExcludedOrdinals()
        let lastOrdinal = rows.count - 1
        let lastLen = (renderedSelectableText(for: rows[lastOrdinal]) as NSString).length
        selection.begin(at: .init(blockOrdinal: 0, utf16Offset: 0))
        selection.extend(to: .init(blockOrdinal: lastOrdinal, utf16Offset: lastLen))
        crossBlockDragActive = true
        repaintAllVisibleSelectionRanges(reset: false)
    }

    /// Cheap validation predicate: is there ANY ordinal inside the selection
    /// span that isn't excluded? Menu validation runs on every menu open /
    /// key-equivalent pass, so it must NOT assemble the full selected text
    /// (that walks and substrings every loaded row). A non-excluded ordinal in
    /// span is the right O(span) gate; the rare false-positive (span covers
    /// only empty-bodied rows) merely enables a Copy that then no-ops.
    private func hasCopyableSelection() -> Bool {
        guard selection.isActive, let (lo, hi) = selection.normalizedEndpoints else { return false }
        let lower = max(0, lo.blockOrdinal)
        let upper = min(hi.blockOrdinal, rows.count - 1)
        guard lower <= upper else { return false }
        // Walk just the span and test the shared predicate — O(span) with early
        // exit, no allocation (vs. building the full excluded-ordinals set).
        for ordinal in lower...upper {
            if !isExcludedFromSelection(rows[ordinal]) { return true }
        }
        return false
    }

    /// Enable the Copy menu item only when a cross-block selection actually
    /// covers copyable content; Select All whenever there are rows. Other
    /// actions fall through so native per-view behavior (context menu, etc.)
    /// is untouched.
    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)):
            return hasCopyableSelection()
        case #selector(selectAll(_:)):
            return !rows.isEmpty
        default:
            return true
        }
    }
}

// MARK: - Appearance-aware fill view

/// Layer-backed fill that resolves its dynamic `NSColor` at appearance time.
/// `NSColor.cgColor` is a static snapshot of a dynamic color (`systemBlue`,
/// `tertiaryLabelColor`, …), so writing it once in `configure` would leave
/// already-rendered cells with stale colors across a LIVE dark/light flip.
/// With `wantsUpdateLayer == true`, AppKit calls `updateLayer()` with the
/// current appearance set to this view's `effectiveAppearance` — both on
/// `needsDisplay` and on effective-appearance changes — so the dynamic color
/// re-resolves per mode, view-locally, with no notification observers.
final class DynamicFillView: NSView {
    /// Dynamic base color. Alpha is applied at resolve time so the tint always
    /// derives from the CURRENT appearance's resolution of the base color.
    var fillColor: NSColor = .clear { didSet { needsDisplay = true } }
    var fillAlpha: CGFloat = 1 { didSet { needsDisplay = true } }
    /// Stored (not layer-only) so a recreated backing layer — e.g. after a
    /// `wantsLayer` round-trip — still gets the radius/mask on the next
    /// `updateLayer()`, instead of relying on a one-time caller-side set on
    /// the (possibly stale) `layer` reference.
    var cornerRadius: CGFloat = 0 { didSet { needsDisplay = true } }
    var masksToBounds: Bool = false { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = fillColor.withAlphaComponent(fillAlpha).cgColor
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = masksToBounds
    }

    /// Animate the fill alpha from its current value down to `target` (used for
    /// the jump-flash pulse). Settles `fillAlpha` to `target` so `updateLayer`
    /// keeps it stable after the animation and a later recycle can't snap it
    /// back to a raised value.
    func animateFillAlpha(to target: CGFloat, duration: CFTimeInterval) {
        let from = fillColor.withAlphaComponent(fillAlpha).cgColor
        fillAlpha = target
        needsDisplay = true
        layer?.displayIfNeeded()
        let anim = CABasicAnimation(keyPath: "backgroundColor")
        anim.fromValue = from
        anim.toValue = fillColor.withAlphaComponent(target).cgColor
        anim.duration = duration
        anim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer?.add(anim, forKey: "flash")
    }
}

// MARK: - Card cell

/// A card row: a 3pt accent bar, a SwiftUI header hosted in an NSHostingView,
/// and a selectable NSTextView body. Reused across rows — `configure` fully
/// resets all mutable state.
///
/// Tool cards (`.toolCall`/`.toolOut`/`.toolGroup`) render the SAME chrome but
/// swap the header for a clickable chevron+summary row and default to
/// collapsed (body hidden). `.meta` rows collapse to a thin separator with no
/// card chrome at all.
final class BlockCardCellView: NSTableCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("BlockCardCellView")

    private let cardBackground = DynamicFillView()
    private let accentBar = DynamicFillView()
    let bodyText = SelectableBlockTextView()
    private var headerHost: NSHostingView<BlockCardHeader>?
    private var showAllHost: NSHostingView<ShowAllRow>?
    private let metaSeparator = DynamicFillView()

    private var bodyTopConstraint: NSLayoutConstraint?
    private var headerHeightConstraint: NSLayoutConstraint?
    private var showAllHeightConstraint: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildViewTree()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        buildViewTree()
    }

    private func buildViewTree() {
        wantsLayer = true

        // DynamicFillView sets wantsLayer in its own init. cornerRadius/
        // masksToBounds are stored properties re-applied on every
        // updateLayer() pass, so a recreated backing layer keeps the radius.
        cardBackground.cornerRadius = CardMetrics.cornerRadius
        cardBackground.masksToBounds = true
        cardBackground.fillAlpha = CardMetrics.cardTintAlpha
        cardBackground.translatesAutoresizingMaskIntoConstraints = false
        addSubview(cardBackground)

        accentBar.translatesAutoresizingMaskIntoConstraints = false
        cardBackground.addSubview(accentBar)

        bodyText.translatesAutoresizingMaskIntoConstraints = false
        bodyText.isEditable = false
        bodyText.isSelectable = true
        bodyText.drawsBackground = false
        bodyText.isRichText = false
        bodyText.textContainerInset = .zero
        bodyText.textContainer?.lineFragmentPadding = 0
        bodyText.textContainer?.widthTracksTextView = true
        bodyText.isVerticallyResizable = true
        bodyText.isHorizontallyResizable = false
        cardBackground.addSubview(bodyText)

        let host = NSHostingView(rootView: BlockCardHeader(kind: .meta, timestamp: nil, accent: .secondary,
                                                            toolMode: nil))
        host.translatesAutoresizingMaskIntoConstraints = false
        cardBackground.addSubview(host)
        headerHost = host

        let showAll = NSHostingView(rootView: ShowAllRow(lineCount: 0, action: {}))
        showAll.translatesAutoresizingMaskIntoConstraints = false
        showAll.isHidden = true
        cardBackground.addSubview(showAll)
        showAllHost = showAll

        // Thin separator for `.meta` rows — hidden unless configure() selects
        // meta mode.
        metaSeparator.translatesAutoresizingMaskIntoConstraints = false
        metaSeparator.fillColor = .tertiaryLabelColor
        metaSeparator.fillAlpha = 0.35
        metaSeparator.isHidden = true
        addSubview(metaSeparator)

        // Card fills the cell; accent bar pinned leading full-height; header at
        // top; body below header with trailing/bottom insets; show-all row
        // below body.
        let headerHeight = host.heightAnchor.constraint(equalToConstant: CardMetrics.headerHeight)
        headerHeightConstraint = headerHeight

        let bodyTop = bodyText.topAnchor.constraint(equalTo: host.bottomAnchor,
                                                    constant: CardMetrics.headerToBodyGap)
        bodyTopConstraint = bodyTop

        let showAllHeight = showAll.heightAnchor.constraint(equalToConstant: CardMetrics.showAllRowHeight)
        showAllHeightConstraint = showAllHeight

        NSLayoutConstraint.activate([
            cardBackground.leadingAnchor.constraint(equalTo: leadingAnchor),
            cardBackground.trailingAnchor.constraint(equalTo: trailingAnchor),
            cardBackground.topAnchor.constraint(equalTo: topAnchor),
            cardBackground.bottomAnchor.constraint(equalTo: bottomAnchor),

            accentBar.leadingAnchor.constraint(equalTo: cardBackground.leadingAnchor),
            accentBar.topAnchor.constraint(equalTo: cardBackground.topAnchor),
            accentBar.bottomAnchor.constraint(equalTo: cardBackground.bottomAnchor),
            accentBar.widthAnchor.constraint(equalToConstant: CardMetrics.accentBarWidth),

            host.leadingAnchor.constraint(equalTo: accentBar.trailingAnchor,
                                          constant: CardMetrics.contentLeadingInset),
            host.trailingAnchor.constraint(equalTo: cardBackground.trailingAnchor,
                                           constant: -CardMetrics.contentTrailingInset),
            host.topAnchor.constraint(equalTo: cardBackground.topAnchor),
            headerHeight,

            bodyText.leadingAnchor.constraint(equalTo: accentBar.trailingAnchor,
                                              constant: CardMetrics.contentLeadingInset),
            bodyText.trailingAnchor.constraint(equalTo: cardBackground.trailingAnchor,
                                               constant: -CardMetrics.contentTrailingInset),
            bodyTop,

            showAll.leadingAnchor.constraint(equalTo: accentBar.trailingAnchor,
                                             constant: CardMetrics.contentLeadingInset),
            showAll.trailingAnchor.constraint(equalTo: cardBackground.trailingAnchor,
                                              constant: -CardMetrics.contentTrailingInset),
            showAll.topAnchor.constraint(equalTo: bodyText.bottomAnchor),
            showAllHeight,
            showAll.bottomAnchor.constraint(lessThanOrEqualTo: cardBackground.bottomAnchor,
                                            constant: -CardMetrics.bodyBottomInset),

            metaSeparator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CardMetrics.contentLeadingInset),
            metaSeparator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -CardMetrics.contentTrailingInset),
            metaSeparator.centerYAnchor.constraint(equalTo: centerYAnchor),
            metaSeparator.heightAnchor.constraint(equalToConstant: 1)
        ])
    }

    /// Fully reset all reused state. Guards against the classic recycling bug
    /// (stale text/color/hosting-view). Updates the hosting view's `rootView`
    /// in place — never recreates the NSHostingView.
    func configure(row: BlockRowModel,
                   fontSize: CGFloat,
                   source: SessionSource,
                   isExpanded: Bool,
                   showAll: Bool,
                   lineLimit: Int,
                   findMatchCount: Int = 0,
                   renderedBody: RenderedBody? = nil,
                   onToggleExpansion: @escaping () -> Void,
                   onToggleShowAll: @escaping () -> Void) {
        // Recycle hygiene (Task 10): drop any find highlight the previous
        // occupant left before this row's body string is (re)assigned below. The
        // controller re-applies the correct highlights right after configure for
        // rows that participate in the active query.
        bodyText.clearFindHighlights()
        if row.isMeta {
            configureMetaSeparator()
            return
        }

        let block = row.primaryBlock
        let accent = Self.accentColor(kind: block.kind, source: source)

        cardBackground.isHidden = false
        metaSeparator.isHidden = true

        // Accent bar + tinted card background. Store the DYNAMIC NSColor only;
        // DynamicFillView resolves cgColor in updateLayer() at appearance time
        // (didSet marks needsDisplay), so live dark/light flips stay correct.
        accentBar.fillColor = accent
        cardBackground.fillColor = accent

        if row.isToolCard {
            configureToolCard(row: row, block: block, accent: accent, fontSize: fontSize,
                              isExpanded: isExpanded, showAll: showAll, lineLimit: lineLimit,
                              findMatchCount: findMatchCount,
                              onToggleExpansion: onToggleExpansion, onToggleShowAll: onToggleShowAll)
            return
        }

        // Ordinary message card (user/assistant/error) — Task 5 chrome, plus
        // Task 12 markdown for user/assistant bodies.
        headerHeightConstraint?.constant = CardMetrics.headerHeight
        // isHidden does NOT relax constraints in AppKit: the showAll chain
        // (showAll.top == bodyText.bottom, height, bottom <= card.bottom-inset)
        // stays active, so the height constant MUST be zeroed whenever the row
        // is hidden or every non-truncated card demands bodyText.bottom + 20pt
        // that measuredHeight doesn't provide (clipping/log spam).
        showAllHeightConstraint?.constant = 0
        showAllHost?.isHidden = true

        bodyText.textContainer?.widthTracksTextView = true
        bodyText.isHidden = false

        let isEmpty: Bool
        if let renderedBody {
            // Markdown message: set the RENDERED attributed string (the exact
            // object the controller measured, so height parity holds — the
            // Phase-1 ShowAll bug class). No plain `bodyText.string` assignment,
            // no monospaced-font override: the attributed runs carry their own
            // fonts (proportional prose, monospaced inline code).
            bodyText.textColor = .labelColor // insertion/caret default for selection
            if let storage = bodyText.textStorage {
                storage.setAttributedString(renderedBody.attributed)
            }
            isEmpty = renderedBody.attributed.length == 0
        } else {
            // Non-markdown message (error card): plain monospaced string, exactly
            // as Task 5 did.
            bodyText.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
            bodyText.textColor = .labelColor
            bodyText.string = row.bodyText
            isEmpty = row.bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        bodyTopConstraint?.constant = isEmpty ? 0 : CardMetrics.headerToBodyGap
        bodyText.isHidden = isEmpty

        let header = BlockCardHeader(kind: block.kind, timestamp: block.timestamp,
                                     accent: Color(nsColor: accent), toolMode: nil)
        headerHost?.rootView = header
    }

    private func configureToolCard(row: BlockRowModel,
                                    block: SessionTranscriptBuilder.LogicalBlock,
                                    accent: NSColor,
                                    fontSize: CGFloat,
                                    isExpanded: Bool,
                                    showAll: Bool,
                                    lineLimit: Int,
                                    findMatchCount: Int,
                                    onToggleExpansion: @escaping () -> Void,
                                    onToggleShowAll: @escaping () -> Void) {
        headerHeightConstraint?.constant = CardMetrics.headerHeight

        let toolBlocks = row.toolBlocks
        let groupCount = toolBlocks.count
        let isGroup = groupCount >= 2
        // A merged group's blocks may mix tool names — "N tool calls" stands
        // alone without a (potentially misleading) single toolName badge.
        let headerSummary = isGroup
            ? "\(groupCount) tool calls"
            : TranscriptToolSummary.summary(toolName: block.toolName, toolInput: block.toolInput)

        let toolMode = BlockCardHeader.ToolMode(
            isExpanded: isExpanded,
            summary: headerSummary,
            toolName: isGroup ? nil : block.toolName,
            findMatchCount: findMatchCount,
            onToggle: onToggleExpansion)
        let header = BlockCardHeader(kind: block.kind, timestamp: block.timestamp,
                                     accent: Color(nsColor: accent), toolMode: toolMode)
        headerHost?.rootView = header

        bodyText.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        bodyText.textColor = .labelColor
        bodyText.textContainer?.widthTracksTextView = true

        guard isExpanded else {
            // Collapsed: header row only, body + show-all hidden. Clear the
            // body string too — a live expanded→collapsed toggle reconfigures
            // this same cell without a prepareForReuse pass.
            bodyText.string = ""
            bodyText.isHidden = true
            bodyTopConstraint?.constant = 0
            showAllHeightConstraint?.constant = 0
            showAllHost?.isHidden = true
            return
        }

        let fullText = Self.expandedToolBodyText(blocks: toolBlocks)
        let lines = fullText.components(separatedBy: "\n")
        let isTruncated = lines.count > lineLimit && !showAll

        bodyText.string = isTruncated ? lines.prefix(lineLimit).joined(separator: "\n") : fullText
        let isEmpty = fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        bodyText.isHidden = isEmpty
        bodyTopConstraint?.constant = isEmpty ? 0 : CardMetrics.headerToBodyGap

        if isTruncated {
            showAllHeightConstraint?.constant = CardMetrics.showAllRowHeight
            showAllHost?.rootView = ShowAllRow(lineCount: lines.count, action: onToggleShowAll)
            showAllHost?.isHidden = false
        } else {
            showAllHeightConstraint?.constant = 0
            showAllHost?.isHidden = true
        }
    }

    /// Per-call summary sub-header + body, stacked, for an expanded group (one
    /// expansion level — no per-call collapse).
    static func expandedToolBodyText(blocks: [SessionTranscriptBuilder.LogicalBlock]) -> String {
        guard blocks.count >= 2 else { return blocks.first?.text ?? "" }
        return blocks.map { block -> String in
            let summary = TranscriptToolSummary.summary(toolName: block.toolName, toolInput: block.toolInput)
            return "\u{2022} \(summary)\n\(block.text)"
        }.joined(separator: "\n\n")
    }

    private func configureMetaSeparator() {
        cardBackground.isHidden = true
        metaSeparator.isHidden = false
        bodyText.string = ""
        bodyText.isHidden = true
        // Collapse the whole (hidden) card chain to zero so it fits the 14pt
        // separator row without forcing a degenerate negative-height solution:
        // 22pt header + 8pt bottom inset would not fit in 14pt otherwise.
        headerHeightConstraint?.constant = 0
        bodyTopConstraint?.constant = 0
        showAllHeightConstraint?.constant = 0
        showAllHost?.isHidden = true
    }

    // MARK: Cross-block selection wiring (Task 9)

    /// Stamp the body text view with its current ordinal + controller back-ref
    /// so mouse escalation can route to the shared coordinator. Called by the
    /// controller's single `configure` site AFTER the body string is set, so the
    /// ordinal always matches the text now displayed. Also resets any stale
    /// selection highlight left over from the recycled cell's previous row.
    func wireSelection(controller: BlockTableController?, ordinal: Int, coordinatorActive: Bool) {
        bodyText.selectionController = controller
        bodyText.blockOrdinal = ordinal
        bodyText.forceActiveSelectionAppearance(coordinatorActive)
        // Recycled-cell hygiene: clear any highlight the previous occupant left.
        // The controller re-applies the correct range immediately after if this
        // row participates in a live cross-block selection.
        if !coordinatorActive { bodyText.setSelectedRange(NSRange(location: 0, length: 0)) }
    }

    /// Paint this row's portion of a live cross-block selection.
    func applySelectionRange(_ range: NSRange) { bodyText.applyCoordinatorRange(range) }

    // MARK: Find highlights (Task 10)

    /// Paint find highlights over the body (renderable rows) — a no-op when the
    /// body is hidden (collapsed tool card / meta), where the collapsed-row pill
    /// carries the count instead. Ranges are UTF-16 into the body string.
    func applyFindHighlights(all ranges: [NSRange], current: NSRange?) {
        bodyText.applyFindHighlights(all: ranges, current: current)
    }

    /// Strip any find highlights from the body. Called on query clear and from
    /// `configure` so a recycled cell never shows a stale highlight.
    func clearFindHighlights() {
        bodyText.clearFindHighlights()
    }

    // MARK: Jump-flash (Task 7)

    /// Set the card fill alpha immediately (no animation). Called from
    /// `configure` to reset any raised flash alpha on recycle, and to seed the
    /// pulse's start value.
    func setFlashAlpha(_ alpha: CGFloat) {
        cardBackground.fillAlpha = alpha
    }

    /// Animate the card fill alpha down to `target` for the jump-flash pulse.
    func animateFlashAlpha(to target: CGFloat) {
        cardBackground.animateFillAlpha(to: target, duration: 0.45)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        bodyText.string = ""
        // Drop any cross-block selection highlight and detach the ordinal so a
        // recycled cell can never paint a stale selection or misroute a mouse
        // escalation before `configure`/`wireSelection` re-stamps it.
        bodyText.setSelectedRange(NSRange(location: 0, length: 0))
        bodyText.blockOrdinal = -1
        bodyText.forceActiveSelectionAppearance(false)
        cardBackground.isHidden = false
        metaSeparator.isHidden = true
        // Reset any in-flight flash alpha so a recycled cell never inherits a
        // raised pulse; configure() re-applies the correct alpha (base or raised)
        // for the row it's about to display.
        cardBackground.fillAlpha = CardMetrics.cardTintAlpha
        cardBackground.layer?.removeAnimation(forKey: "flash")
        // Intentionally NOT resetting bodyText.isHidden / bodyTopConstraint /
        // fill colors here: `configure` reassigns all of them unconditionally
        // on every path before the cell is displayed again.
    }

    static func accentColor(kind: SessionTranscriptBuilder.LogicalBlock.Kind,
                            source: SessionSource) -> NSColor {
        switch kind {
        case .user: return TranscriptColorSystem.semanticAccent(.user)
        case .assistant: return TranscriptColorSystem.agentBrandAccent(source: source)
        case .toolCall: return TranscriptColorSystem.semanticAccent(.toolCall)
        case .toolOut: return TranscriptColorSystem.semanticAccent(.toolOutputSuccess)
        case .error: return TranscriptColorSystem.semanticAccent(.error)
        case .meta: return NSColor.tertiaryLabelColor
        }
    }
}

// MARK: - Table view (routes copy/select-all to the controller)

/// NSTableView subclass whose only job is to place the `BlockTableController`
/// into the copy / select-all / menu-validation path. The controller is a plain
/// `NSObject` (can't be a `nextResponder`), so the table — which IS in the
/// responder chain — forwards these actions to it. Everything else (scroll,
/// per-view context menus, double-click word select inside a body) keeps native
/// behavior.
final class BlockTableView: NSTableView {
    weak var selectionOwner: BlockTableController?

    /// Clicks on rows without a `SelectableBlockTextView` (meta separators,
    /// collapsed tool-card chrome, card background, inter-card gaps) must clear
    /// any live cross-block selection; such clicks bubble up to the table via
    /// the default NSView mouseDown chain, which is why this override lives
    /// here rather than on the text view. Clicks inside a body text view never
    /// reach here (the text view handles them and clears via its own
    /// mouseDown), so there is no double-clear.
    override func mouseDown(with event: NSEvent) {
        if selectionOwner?.isCrossBlockSelectionActive == true {
            selectionOwner?.clearCrossBlockSelectionForNativeClick()
        }
        super.mouseDown(with: event)
    }

    @objc func copy(_ sender: Any?) {
        selectionOwner?.copy(sender)
    }

    override func selectAll(_ sender: Any?) {
        // Route ⌘A to the cross-block coordinator (select all loaded blocks)
        // rather than NSTableView's own row-selection (which is disabled anyway
        // via selectionHighlightStyle = .none / shouldSelectRow = false).
        selectionOwner?.selectAll(sender)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if let owner = selectionOwner,
           let action = item.action,
           action == #selector(BlockTableController.copy(_:)) || action == #selector(NSResponder.selectAll(_:)) {
            return owner.validateUserInterfaceItem(item)
        }
        return super.validateUserInterfaceItem(item)
    }
}

// MARK: - Selectable body text view

/// Non-editable, selectable body. Intra-block selection stays fully NATIVE
/// (double-click word select, drag within one card, right-click context menu).
/// The cross-block coordinator only engages when a drag that STARTED here
/// crosses the card boundary — at which point we escalate to the controller,
/// handing it the origin anchor (the character offset the drag began at). Once
/// the coordinator is active the controller drives every visible row's
/// `setSelectedRange`, and this view renders its portion as a non-first-responder
/// text view (see `forceActiveSelectionAppearance`).
final class SelectableBlockTextView: NSTextView {
    override var acceptsFirstResponder: Bool { true }

    /// Set by the cell so this body can report its ordinal + escalate. The
    /// controller owns the row→ordinal mapping and the shared coordinator.
    weak var selectionController: BlockTableController?
    /// The block ordinal (index into the controller's CURRENT rows array) this
    /// body currently backs. Re-stamped on every `configure`.
    var blockOrdinal: Int = -1

    /// True while a cross-block drag is in flight and the coordinator, not the
    /// native text view, owns the selection. Suppresses native selection churn.
    private var coordinatorDriving = false
    /// The character offset where the current native drag began — adopted as the
    /// coordinator's anchor the moment the drag crosses the card boundary.
    private var dragAnchorOffset: Int?

    // MARK: Selection appearance for simultaneous multi-row selection

    /// AppKit greys out selection in a text view that is NOT first responder.
    /// During a cross-block selection every visible row must show the SAME
    /// active-blue highlight at once, so while the coordinator is driving we
    /// force the active `selectedTextAttributes` regardless of responder state.
    func forceActiveSelectionAppearance(_ active: Bool) {
        coordinatorDriving = active
        if active {
            selectedTextAttributes = [
                .backgroundColor: NSColor.selectedTextBackgroundColor,
                .foregroundColor: NSColor.selectedTextColor
            ]
            insertionPointColor = .clear
        } else {
            // Restore system defaults (empty ⇒ AppKit uses the standard
            // responder-dependent appearance again).
            selectedTextAttributes = [:]
            insertionPointColor = .textColor
        }
    }

    /// Paint (or clear) this row's portion of a cross-block selection without
    /// stealing first-responder status.
    func applyCoordinatorRange(_ range: NSRange) {
        setSelectedRange(range)
    }

    // MARK: Find highlights (Task 10)

    /// Temporary `.backgroundColor` attributes layered over each in-row match
    /// range. Applied via `textStorage` so they coexist with Task 9's selection
    /// (which uses `setSelectedRange`, an orthogonal layer) — a row can show
    /// both a find highlight and a cross-block selection at once. `current`
    /// gets the accent tint; all others the yellow tint. Every call first strips
    /// the previous find attributes so a reconfigure/recycle can't leave a stale
    /// highlight behind (extends the reuse-reset discipline). All ranges are
    /// UTF-16 into THIS view's string, which for renderable rows is identical to
    /// the block text the match ranges index.
    func applyFindHighlights(all ranges: [NSRange], current: NSRange?) {
        guard let storage = textStorage else { return }
        let fullLen = storage.length
        clearFindHighlights()
        guard fullLen > 0 else { return }
        storage.beginEditing()
        for r in ranges {
            guard NSMaxRange(r) <= fullLen else { continue }
            let isCurrent = current.map { NSEqualRanges($0, r) } ?? false
            let color: NSColor = isCurrent
                ? NSColor.controlAccentColor.withAlphaComponent(0.45)
                : NSColor.systemYellow.withAlphaComponent(0.35)
            storage.addAttribute(.backgroundColor, value: color, range: r)
        }
        storage.endEditing()
    }

    /// Strip every find-highlight background attribute over the whole string,
    /// then RESTORE any markdown inline-code chip background (Task 12) and any
    /// fenced-code-block card background (Task 13). Find highlights, the inline
    /// chip, AND the code-block card all paint `.backgroundColor`, so a blanket
    /// removal would wipe the chip/card too; the renderer stamps a
    /// `.markdownCodeChip` marker on inline-code runs and a
    /// `.markdownCodeBlockBg` marker on fenced-code-block runs (value: the
    /// respective color), and we re-apply `.backgroundColor` from whichever
    /// marker is present here. Cheap and idempotent; called before re-applying
    /// find and on clear/recycle. For a non-markdown row (no markers) this is
    /// exactly the Task 10 behavior.
    func clearFindHighlights() {
        guard let storage = textStorage, storage.length > 0 else { return }
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.removeAttribute(.backgroundColor, range: full)
        storage.enumerateAttribute(.markdownCodeChip, in: full) { value, range, _ in
            if let color = value as? NSColor {
                storage.addAttribute(.backgroundColor, value: color, range: range)
            }
        }
        storage.enumerateAttribute(.markdownCodeBlockBg, in: full) { value, range, _ in
            if let color = value as? NSColor {
                storage.addAttribute(.backgroundColor, value: color, range: range)
            }
        }
        storage.endEditing()
    }

    // MARK: Copy / Select-all interception

    /// During (and after) a cross-block drag, the ORIGIN text view remains
    /// first responder, and NSTextView implements `copy:` natively — so without
    /// this override the responder chain would stop HERE and copy only this
    /// row's `selectedRange` fragment; the table-level forwarder would never
    /// run. When the cross-block selection is active, delegate to the
    /// controller's assembled multi-block copy; otherwise the native intra-block
    /// path is untouched.
    override func copy(_ sender: Any?) {
        if let controller = selectionController, controller.isCrossBlockSelectionActive {
            controller.copy(sender)
        } else {
            super.copy(sender)
        }
    }

    /// ⌘A in Rich mode ALWAYS means "select all loaded blocks" (the plan's
    /// locked semantics: anchor (0,0) → focus (last, length)) — so we escalate
    /// to the controller even when NO cross-block selection is active yet.
    /// A per-block native selectAll is in nobody's mental model here: the user
    /// sees one continuous transcript, not N text boxes. `super.selectAll` only
    /// as a fallback when unwired (pre-configure; shouldn't occur in practice).
    override func selectAll(_ sender: Any?) {
        if let controller = selectionController {
            controller.selectAll(sender)
        } else {
            super.selectAll(sender)
        }
    }

    /// Keep menu validation consistent with the overrides above: while the
    /// cross-block selection is active, Copy validity comes from the
    /// controller (assembled selection), not this view's local selectedRange.
    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if let controller = selectionController, let action = item.action {
            if action == #selector(copy(_:)), controller.isCrossBlockSelectionActive {
                return controller.validateUserInterfaceItem(item)
            }
            if action == #selector(selectAll(_:)) {
                return controller.validateUserInterfaceItem(item)
            }
        }
        return super.validateUserInterfaceItem(item)
    }

    // MARK: Mouse routing

    override func mouseDown(with event: NSEvent) {
        // A plain click (or the START of a native drag) clears any live
        // cross-block selection back to native behavior. If a drag develops and
        // crosses a boundary, mouseDragged re-engages the coordinator.
        selectionController?.clearCrossBlockSelectionForNativeClick()
        dragAnchorOffset = characterOffset(for: event)
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        // Ask the controller whether this drag point is still inside our own
        // row. While inside, stay native. Once it leaves, escalate.
        if selectionController?.isDragPointInside(ordinal: blockOrdinal, event: event) == false {
            let anchor = dragAnchorOffset ?? selectedRange().location
            selectionController?.beginOrExtendCrossBlockDrag(
                originOrdinal: blockOrdinal, anchorOffset: anchor, event: event)
            return
        }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        selectionController?.endCrossBlockDragIfActive(event: event)
        dragAnchorOffset = nil
        super.mouseUp(with: event)
    }

    /// UTF-16 character offset in THIS text view for a mouse event.
    func characterOffset(for event: NSEvent) -> Int {
        let point = convert(event.locationInWindow, from: nil)
        return characterOffset(atLocalPoint: point)
    }

    /// UTF-16 character offset for a point already in THIS view's coordinates.
    func characterOffset(atLocalPoint point: NSPoint) -> Int {
        guard let lm = layoutManager, let container = textContainer else { return 0 }
        let inContainer = NSPoint(x: point.x - textContainerOrigin.x,
                                  y: point.y - textContainerOrigin.y)
        var frac: CGFloat = 0
        let g = lm.glyphIndex(for: inContainer, in: container, fractionOfDistanceThroughGlyph: &frac)
        var idx = lm.characterIndexForGlyph(at: g)
        if frac > 0.5 { idx += 1 }
        return min(idx, (string as NSString).length)
    }
}

// MARK: - SwiftUI header

struct BlockCardHeader: View {
    /// Tool-card header mode: chevron + toolName + one-line summary (or
    /// "N tool calls" for a merged group). The whole row is the click target,
    /// not just the chevron glyph.
    struct ToolMode {
        var isExpanded: Bool
        var summary: String
        var toolName: String?
        /// Task 10: count of find matches inside this collapsed tool row's
        /// block(s). >0 renders a match-count pill on the header (the match text
        /// itself is unreachable while collapsed — auto-expand is Phase 2). 0
        /// hides the pill. Ignored while expanded (matches highlight in-body).
        var findMatchCount: Int = 0
        var onToggle: () -> Void
    }

    let kind: SessionTranscriptBuilder.LogicalBlock.Kind
    let timestamp: Date?
    let accent: Color
    let toolMode: ToolMode?

    var body: some View {
        if let toolMode {
            toolHeader(toolMode)
        } else {
            plainHeader
        }
    }

    private var plainHeader: some View {
        HStack(spacing: 6) {
            Text(roleLabel)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(accent)
            if let timestamp {
                Text(timestamp, format: .dateTime.hour().minute().second())
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 6)
    }

    private func toolHeader(_ mode: ToolMode) -> some View {
        Button(action: mode.onToggle) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(mode.isExpanded ? 90 : 0))
                    .animation(.easeInOut(duration: 0.15), value: mode.isExpanded)
                if let toolName = mode.toolName, !toolName.isEmpty {
                    Text(toolName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(accent)
                }
                Text(mode.summary)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let timestamp {
                    Text(timestamp, format: .dateTime.hour().minute().second())
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                if !mode.isExpanded, mode.findMatchCount > 0 {
                    Text("\(mode.findMatchCount)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color(nsColor: .systemYellow).opacity(0.9))
                        )
                        .help("\(mode.findMatchCount) find match\(mode.findMatchCount == 1 ? "" : "es") in this collapsed card")
                        .accessibilityLabel("\(mode.findMatchCount) find matches, collapsed")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 6)
    }

    private var roleLabel: String {
        switch kind {
        case .user: return "You"
        case .assistant: return "Agent"
        case .toolCall: return "Tool"
        case .toolOut: return "Output"
        case .error: return "Error"
        case .meta: return "Meta"
        }
    }
}

// MARK: - Show-all affordance

/// "Show all N lines" SwiftUI row shown below a truncated (>20-line)
/// expanded tool-card body.
struct ShowAllRow: View {
    let lineCount: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Show all \(lineCount) lines")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tint)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
