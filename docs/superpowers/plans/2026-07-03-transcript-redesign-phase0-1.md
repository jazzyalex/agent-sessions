# Transcript Render Redesign — Phase 0 + Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract a `TranscriptDerivedState` owner (Phase 0 / perf-program W6) and build the new block-based "Rich" transcript view (Phase 1): role-accented cards, collapsed tool blocks with one-line summaries, cross-block selection, ⌘F, follow-tail — all over the existing `LogicalBlock` / `TranscriptWindow` layer.

**Architecture:** A `@MainActor @Observable TranscriptDerivedState` consolidates block-space derived data (coalesced blocks, anchor maps, role block indices, whole-session find matches) computed off-main and published as one snapshot; both `SessionTerminalView` and the new view consume it. The new view is a view-based `NSTableView` in an `NSViewRepresentable`; each row = SwiftUI chrome (`NSHostingView`) + selectable `NSTextView` body; cross-block selection via a pure-math `TranscriptSelectionCoordinator`; off-window ⌘F/jumps reuse the shipped `eventIDToAnchorBlockIndex` + `widenWindowForJump` pattern. Decision memo + macOS-15 addendum: see "Architecture decisions" appendix at the bottom of this file.

**Tech Stack:** Swift / SwiftUI + AppKit (NSTableView, NSTextView, NSHostingView), XCTest. No new dependencies.

## Global Constraints

- **NEVER commit or push without explicit owner request** (CLAUDE.md). "Commit checkpoint" steps below mean: stage nothing, report the checkpoint, and ask the owner; commit only on their word. Conventional Commits + Tool/Model trailers, no Claude co-author.
- **No branches/worktrees without explicit approval** — work on the current branch.
- **Subagents edit in parallel but NEVER run xcodebuild.** ONE central verification in the main session: `./scripts/xcode_test_stable.sh` (full suite; currently 1209 green). Single suite: append `-only-testing:AgentSessionsTests/<ClassName>`.
- **Locked design decisions (do not re-litigate):** one unified style (no Focused mode); no token/cost badges; AS identity (TranscriptColorSystem palette, monospace-leaning, no web-chat avatars); no syntax highlighting of fences; Terminal ("Session") and JSON modes untouched; old "Text" mode stays selectable until parity.
- **Acceptance gates:** ⌘F with highlight + next/prev; cross-block selection + copy; follow-tail on live sessions; markdown export unchanged; the seven perf suites stay green (TranscriptWindowedBuildTests, TranscriptBuilderTests, TranscriptGoldenFixtureTests, TranscriptCacheTests, TranscriptRenderGenerationGateTests, Stage0PerfHarnessTests, PerfQuickWinsTests).
- **New Swift files** must be registered via `./scripts/xcode_add_file.rb AgentSessions.xcodeproj <TARGET> <FILE_PATH> <GROUP_PATH>`. ⚠️ pbxproj landmine: there are THREE targets named `AgentSessionsLogicTests` (live one = ID `9E29F9AF3D49DDA01A884CB7`; two 3-file orphans). `xcode_add_file.rb` matches the FIRST by name. All new files in this plan go to the **app target only** (`AgentSessions`) — transcript types aren't in LogicTests (it uses shims: `AgentSessionsLogicTests/SessionFilterShims.swift`), and all new tests go in the hosted `AgentSessionsTests` target where the seven suites live.
- **macOS deployment floor: 14.0 — Task 1 CANCELLED and reverted (owner call, 2026-07-03).** The bump bought the chosen AppKit stack nothing: `@Observable`/Observation ships with macOS 14, and the only genuinely 15-only APIs (`onScrollGeometryChange`, `TextSelection` bindings) are ones the architecture explicitly doesn't use. Do not use 15-only APIs anywhere in this plan.
- **Visual QA:** the main session builds; the owner runs the app (no CLI kill/open thrash, no computer-use).
- All file paths below are repo-relative from `/Users/alexm/Repository/Codex-History`.
- **⚠️ Line-number drift (2026-07-03):** commits `70de055e`/`7781ed5e`/`8a145cd6` (another session) added ~262 lines of whole-session find-scan machinery to `SessionTerminalView.swift` AFTER this plan's line references were captured. References into that file may be off by ~+20–250 lines below their cited positions — search for the named symbol, don't trust the number. New machinery to know: `ScanValidityKey` (sessionID/eventCount/fileSizeBytes), `nonisolated static scanSessionBlocks(session:query:)` (whole-session block scan via `SearchTextMatcher.matchRanges`), `kickOffGlobalUnifiedScan`/`kickOffGlobalFindScan` + `*GlobalMatchBlocks`/`*GlobalTotalMatches` state, `pendingUnifiedMatchScroll`/`pendingFindMatchScroll`, and widen-to-off-window-match behavior in both `recomputeUnifiedMatches`/`recomputeFindMatches` empty-window branches. `MatchOccurrence` gained `lineLocalRange`.
- **Execution amendments (owner, 2026-07-03):** NO commits at all — every "Commit checkpoint" step is replaced by a controller tree-snapshot (`git add -A && git write-tree`); single commit conversation at the end. Work happens on `feature/transcript-redesign-v5`.

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `AgentSessions/Services/TranscriptDerivedState.swift` | create (T2) | Block-space derived-state owner: snapshot compute (off-main), invalidation key, anchors, role block indices, find matches |
| `AgentSessions/Services/TranscriptToolSummary.swift` | create (T6) | Pure one-line tool summaries from `toolName`/`toolInput` + tool-run coalescing for "N tool calls" cards |
| `AgentSessions/Views/TranscriptSelectionCoordinator.swift` | create (T9) | Pure selection math: (anchor, focus) positions → per-block NSRange + ordered copy assembly |
| `AgentSessions/Views/TranscriptBlockListView.swift` | create (T5) | NSViewRepresentable + NSTableView + row/card infrastructure for the Rich mode |
| `AgentSessions/Services/SessionViewMode.swift` | modify (T4) | Add `.blocks` case |
| `AgentSessions/Views/TranscriptPlainView.swift` | modify (T4, T10, T11) | Menu entry, routing branch, find/copy plumbing to the new view |
| `AgentSessions/Views/SessionTerminalView.swift` | modify (T3) | Consume TranscriptDerivedState for block-space data; `RebuildResult` sheds relocated fields |
| `AgentSessions.xcodeproj/project.pbxproj` | modify (T1) | `MACOSX_DEPLOYMENT_TARGET = 15.0` |
| `AgentSessionsTests/TranscriptDerivedStateTests.swift` | create (T2) | Parity + invalidation + find-match tests |
| `AgentSessionsTests/TranscriptToolSummaryTests.swift` | create (T6) | Summary derivation + run-merging tests |
| `AgentSessionsTests/TranscriptSelectionCoordinatorTests.swift` | create (T9) | Selection-range math tests |

---

### Task 1: ~~Bump deployment target to macOS 15.0~~ — CANCELLED (2026-07-03)

Implemented, reviewed, verified green — then reverted the same day on owner review: the redesign stack needs nothing from macOS 15 (`@Observable` is macOS 14+; the architect memo's "unlocks @Observable" claim was wrong), and dropping Sonoma users has real product cost. Floor stays 14.0. Kept for the record; skip during execution.

**Files:**
- Modify: `AgentSessions.xcodeproj/project.pbxproj` (all 10 build configs, e.g. line 2436)

**Steps:**

- [ ] **Step 1: Edit all occurrences**

```bash
grep -c 'MACOSX_DEPLOYMENT_TARGET = 14.0' AgentSessions.xcodeproj/project.pbxproj   # expect 10
```
Replace every `MACOSX_DEPLOYMENT_TARGET = 14.0;` with `MACOSX_DEPLOYMENT_TARGET = 15.0;` (Edit tool, replace_all). Also check `scripts/xcode_add_unit_test_target.rb` passes `'14.0'` to `new_target` — update the literal to `'15.0'` so future targets match.

- [ ] **Step 2: Sweep now-dead availability guards**

```bash
grep -rn "available(macOS 15" AgentSessions/ | grep -v deriveddata
```
For each hit: remove the guard, keep the 15-path code. If a `#available(macOS 26/16, *)` style guard appears, leave it.

- [ ] **Step 3: Central verification**

Run: `./scripts/xcode_test_stable.sh`
Expected: full suite green (1209 tests).

- [ ] **Step 4: Commit checkpoint** (ask owner)

Proposed message: `chore(build): raise deployment target to macOS 15.0` + Tool/Model trailers.

---

### Task 2: `TranscriptDerivedState` — the Phase 0 owner (create + parity tests)

Consolidation, not rewrite: the compute relocates the **block-space** parts of `SessionTerminalView.buildRebuildResult` (anchors, role block indices, block count) behind one owner. Line-space state (TerminalLine arrays, nav-index caches over visibleLines) stays in the Terminal view — it is renderer-specific.

**Files:**
- Create: `AgentSessions/Services/TranscriptDerivedState.swift`
- Test: `AgentSessionsTests/TranscriptDerivedStateTests.swift`

**Interfaces:**
- Consumes: `SessionTranscriptBuilder.coalescedBlocks(for:includeMeta:)` (memoized, `SessionTranscriptBuilder.swift:465`), `TranscriptUserAnchors.anchors(userBlockIndices:preambleUserBlockIndexes:blockCount:)` (see call at `SessionTerminalView.swift:1355–1371`), `SessionTerminalView.computePreambleUserBlockIndexes` (static, `SessionTerminalView.swift:1576` — copy its logic here or call it if access allows), `SearchTextMatcher.matchRanges` (`TranscriptPlainView.swift:1888` — match the exact signature found there).
- Produces (later tasks rely on these exact names):
  - `TranscriptDerivedState.update(session:settings:)`
  - `TranscriptDerivedState.snapshot: Snapshot` with `blocks`, `totalBlockCount`, `eventIDToAnchorBlockIndex`, `userBlockIndices`, `toolBlockIndices`, `errorBlockIndices`, `preambleUserBlockIndexes`, `key`
  - `TranscriptDerivedState.findMatches(query:) -> [BlockMatch]`, `struct BlockMatch { globalBlockIndex, rangeInBlockText: NSRange, ordinal }`
  - `nonisolated static func computeSnapshot(session:settings:) -> Snapshot` (pure; this is what tests hit)

- [ ] **Step 1: Write the failing parity test**

`AgentSessionsTests/TranscriptDerivedStateTests.swift`:

```swift
import XCTest
@testable import AgentSessions

final class TranscriptDerivedStateTests: XCTestCase {
    override func setUp() {
        super.setUp()
        SessionTranscriptBuilder._testResetCoalesceCache()
    }

    private func fixtureSession() -> Session {
        // Reuse the synthetic-session helper style from TranscriptWindowedBuildTests
        // (same file pattern: build a Session with interleaved user/assistant/tool events).
        TranscriptWindowedBuildTests.makeSyntheticSession(eventCount: 300)
    }

    func testSnapshotParityWithTerminalRebuildResult() {
        let session = fixtureSession()
        let settings = TranscriptDerivedState.DerivedSettings(skipAgentsPreamble: false,
                                                              reviewCardsEnabled: true)
        let snap = TranscriptDerivedState.computeSnapshot(session: session, settings: settings)

        let blocks = SessionTranscriptBuilder.coalescedBlocks(for: session, includeMeta: false)
        let legacy = SessionTerminalView.buildRebuildResult(
            session: session, skipAgentsPreamble: false, enableReviewCards: true)

        XCTAssertEqual(snap.totalBlockCount, blocks.count)
        XCTAssertEqual(snap.eventIDToAnchorBlockIndex, legacy.eventIDToAnchorBlockIndex)
        XCTAssertEqual(snap.preambleUserBlockIndexes, legacy.preambleUserBlockIndexes)
        XCTAssertEqual(snap.userBlockIndices,
                       blocks.indices.filter { blocks[$0].kind == .user }.map { blocks[$0].globalBlockIndex })
    }

    func testSnapshotKeyDedupe() {
        let session = fixtureSession()
        let settings = TranscriptDerivedState.DerivedSettings(skipAgentsPreamble: false,
                                                              reviewCardsEnabled: true)
        let k1 = TranscriptDerivedState.Key(session: session, settings: settings)
        let k2 = TranscriptDerivedState.Key(session: session, settings: settings)
        XCTAssertEqual(k1, k2)
        let other = TranscriptDerivedState.DerivedSettings(skipAgentsPreamble: true,
                                                           reviewCardsEnabled: true)
        XCTAssertNotEqual(k1, TranscriptDerivedState.Key(session: session, settings: other))
    }

    func testFindMatchesWholeSession() {
        let session = fixtureSession()
        let settings = TranscriptDerivedState.DerivedSettings(skipAgentsPreamble: false,
                                                              reviewCardsEnabled: true)
        let snap = TranscriptDerivedState.computeSnapshot(session: session, settings: settings)
        let needle = String(snap.blocks.first(where: { !$0.text.isEmpty })!.text.prefix(6))
        let matches = TranscriptDerivedState.computeFindMatches(blocks: snap.blocks, query: needle)
        XCTAssertFalse(matches.isEmpty)
        XCTAssertEqual(matches.map(\.ordinal), Array(0..<matches.count))
        // matches sorted by block, then location
        XCTAssertEqual(matches, matches.sorted {
            ($0.globalBlockIndex, $0.rangeInBlockText.location) < ($1.globalBlockIndex, $1.rangeInBlockText.location)
        })
    }
}
```

Notes for the implementer: `buildRebuildResult`'s whole-session convenience overload is at `SessionTerminalView.swift:1281–1288` and is `nonisolated static` — check its exact parameter list and adapt the call; if `TranscriptWindowedBuildTests` has no reusable synthetic-session helper, lift its private one into a shared `AgentSessionsTests/TranscriptTestFixtures.swift` (test target only, plain Xcode-added test file) rather than duplicating.

- [ ] **Step 2: Register the test file and run it to verify it fails**

```bash
./scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessionsTests \
  AgentSessionsTests/TranscriptDerivedStateTests.swift AgentSessionsTests
./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/TranscriptDerivedStateTests
```
Expected: FAIL — `TranscriptDerivedState` not defined.

- [ ] **Step 3: Implement `TranscriptDerivedState.swift`**

```swift
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
    /// SessionTerminalView.buildRebuildResult (see SessionTerminalView.swift:1341-1371).
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
            ? SessionTerminalView.computePreambleUserBlockIndexes(blocks: blocks, session: session)
            : []
        // Same anchor derivation buildRebuildResult uses (full-session scope).
        snap.eventIDToAnchorBlockIndex = TranscriptUserAnchors.anchors(
            userBlockIndices: userIdx,
            preambleUserBlockIndexes: snap.preambleUserBlockIndexes,
            blockCount: blocks.count
        ).eventIDToAnchorBlockIndex(blocks: blocks)
        // ^ IMPLEMENTER: mirror the exact anchor construction from
        //   SessionTerminalView.swift:1355-1371 — copy that code verbatim here
        //   and delete this comment. The parity test is the referee.
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
    /// uses (SessionTerminalView.scanSessionBlocks, added 8a145cd6) so Rich-mode
    /// counts agree with Terminal-mode counts for the same query.
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
```

Implementer notes: (a) the anchor construction MUST be copied verbatim from `SessionTerminalView.swift:1355–1371` — do not re-derive it; (b) if `computePreambleUserBlockIndexes` or `TranscriptUserAnchors` have different signatures than sketched, follow the real code — the parity test is the referee; (c) match-scan semantics should mirror the flat view's find (`transcript.range(of:options:[.caseInsensitive])`, `TranscriptPlainView.swift:1934`) — plain case-insensitive substring, matching current ⌘F behavior.

- [ ] **Step 4: Register the source file (app target only) and run the tests**

```bash
./scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessions \
  AgentSessions/Services/TranscriptDerivedState.swift AgentSessions/Services
./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/TranscriptDerivedStateTests
```
Expected: PASS (all three tests).

- [ ] **Step 5: Commit checkpoint** (ask owner)

Proposed: `feat(transcript): TranscriptDerivedState block-space owner (redesign Phase 0 / perf W6)`

---

### Task 3: SessionTerminalView consumes the owner

Terminal view sheds duplicated block-space state; behavior identical; 1209 tests stay green. **This task changes a hot, shipped view — smallest possible diff.**

**Files:**
- Modify: `AgentSessions/Views/SessionTerminalView.swift`
- Modify: `AgentSessions/Views/TranscriptPlainView.swift` (owner instantiation + injection)

**Interfaces:**
- Consumes: `TranscriptDerivedState.update(session:settings:)`, `.snapshot.eventIDToAnchorBlockIndex`, `.snapshot.totalBlockCount`
- Produces: `UnifiedTranscriptView` holds `@State private var derivedState = TranscriptDerivedState()` and passes it to `SessionTerminalView(derivedState:)` — Task 5's block view receives the same instance.

- [ ] **Step 1: Inject the owner**

In `UnifiedTranscriptView` (`TranscriptPlainView.swift:494`): add `@State private var derivedState = TranscriptDerivedState()`. In the existing `.task(id: renderKey)` (line ~749), add before the mode branch:

```swift
derivedState.update(
    session: session,
    settings: .init(skipAgentsPreamble: skipAgentsPreambleEnabled(),
                    reviewCardsEnabled: transcriptReviewCardsEnabled))
```
(Use the same two settings reads the Terminal view uses — `SessionTerminalView.swift:901–905`; if `UnifiedTranscriptView` lacks those helpers, read the same `PreferencesKey.Unified.skipAgentsPreamble` / `PreferencesKey.Transcript.enableReviewCards` storage.) Pass `derivedState` into `SessionTerminalView`'s init at the `terminalTranscriptView` call site.

- [ ] **Step 2: Swap reads in SessionTerminalView**

- Add `let derivedState: TranscriptDerivedState` to the view's stored properties.
- Delete `@State private var eventIDToAnchorBlockIndex: [String: Int]` (line 214) and `@State private var totalBlockCount: Int` (line 217); replace all reads (`jumpToEventID` at :2359–2378, `jumpToFirstPrompt` at :2320–2333, any status text) with `derivedState.snapshot.eventIDToAnchorBlockIndex` / `derivedState.snapshot.totalBlockCount`.
- In `applyRebuild` (:1115–1209): delete the assignments to the two removed properties.
- In `RebuildResult` (:873–894): remove `eventIDToAnchorBlockIndex` and `totalBlockCount` fields and their construction in `buildRebuildResult` (:1355–1371 anchor part moves entirely to the owner; keep `eventIDToUserLineID` — it is line-space and stays). ⚠️ `buildRebuildResult` is exercised by TranscriptWindowedBuildTests — update any test referencing the removed fields to read `TranscriptDerivedState.computeSnapshot` instead.
- The Terminal view no longer needs its own `derivedState.update(...)` call — the injection point in Step 1 covers both views. But `widenWindowForJump` (:1050–1102) re-coalesces internally; it keeps doing so (memoized, cheap) — leave it.
- **Scope guard (post-8a145cd6):** do NOT touch the new whole-session scan machinery (`scanSessionBlocks`, `kickOffGlobalUnifiedScan`/`kickOffGlobalFindScan`, `ScanValidityKey`, `*GlobalMatchBlocks` state, `pendingUnifiedMatchScroll`/`pendingFindMatchScroll`) beyond mechanical reads of the two relocated properties (`totalBlockCount` appears in its `windowCoversWholeSession` computations — swap those reads too). Consolidating the Terminal scans onto `TranscriptDerivedState.findMatches` is a flagged POST-PLAN cleanup, not part of this task.

- [ ] **Step 3: Central verification (full suite — this is the risky task)**

Run: `./scripts/xcode_test_stable.sh`
Expected: full suite green. Pay attention to TranscriptWindowedBuildTests (15 funcs — several touch `buildRebuildResult`'s shape) and PerfQuickWinsTests (user-anchor parity oracle).

- [ ] **Step 4: Manual QA hand-off (owner runs the app)**

Build only: `xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug build`
Ask the owner to verify in Session (Terminal) mode: open a monster session → first-prompt jump (widens window), deeplink/event jump, image-click jump. These are the three `eventIDToAnchorBlockIndex` consumers.

- [ ] **Step 5: Commit checkpoint** (ask owner)

Proposed: `refactor(transcript): SessionTerminalView consumes TranscriptDerivedState for block-space data`

---

### Task 4: `.blocks` view mode — menu entry + routing

**Files:**
- Modify: `AgentSessions/Services/SessionViewMode.swift`
- Modify: `AgentSessions/Views/TranscriptPlainView.swift`

**Interfaces:**
- Produces: `SessionViewMode.blocks` (rawValue `"blocks"`, menu title **"Rich"**), routed in `UnifiedTranscriptView.body` to `TranscriptBlockListView` (Task 5 supplies it; until then a placeholder `Text("Rich mode – under construction")`).

- [ ] **Step 1: Extend the enum**

`SessionViewMode.swift`:
```swift
public enum SessionViewMode: String, CaseIterable, Identifiable, Codable {
    case blocks        // "Rich" — block-based rendering (v5 redesign)
    case transcript
    case terminal
    case json
    public var id: String { rawValue }
}
```
In the `transcriptRenderMode` mapping extension: map `.blocks` → `.normal` (legacy persistence only; `TranscriptRenderMode` gains no case). `from(_:)` keeps returning `.transcript` for `.normal` — one-way legacy mapping is intentional: old builds fall back to Text.

- [ ] **Step 2: Menu + routing + shortcut cycle**

In `TranscriptPlainView.swift`:
- `viewModeMenu` (:1166–1186): add a fourth `viewModeMenuButton(.blocks, title: "Rich", help: "Structured cards with collapsible tool calls.")` — listed FIRST (above "Session").
- `viewModeMenuTitle` (:1203): add `case .blocks: return "Rich"`.
- `body` mode switch (:703–707): add `else if viewMode == .blocks { blocksTranscriptView(session: session) }` where `blocksTranscriptView` is a new `@ViewBuilder` func returning the placeholder for now.
- Cmd+Shift+T cycle (:1259–1273): include `.blocks` in the rotation.
- Default stays `terminal` (`viewModeRaw` initial value unchanged) — Rich becomes default only at v5 cut, per handover.

- [ ] **Step 3: Verify**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/TranscriptRenderGenerationGateTests` (contains `TranscriptSessionRenderKeyTests` etc. in the same file — the cheap suite most likely to notice mode plumbing), then a plain `xcodebuild ... build`.
Expected: PASS + clean build. Menu shows Rich/Session/Text/JSON.

- [ ] **Step 4: Commit checkpoint** (ask owner)

Proposed: `feat(transcript): add Rich view mode entry (placeholder) alongside Session/Text/JSON`

---

### Task 5: `TranscriptBlockListView` — NSTableView skeleton with plain cards

The load-bearing UI task. Deliverable: Rich mode renders windowed blocks as cards (accent bar + role label + timestamp + selectable NSTextView body), correct variable heights, recycling, dark/light, honors `TranscriptFontSize`.

**Files:**
- Create: `AgentSessions/Views/TranscriptBlockListView.swift`
- Modify: `AgentSessions/Views/TranscriptPlainView.swift` (replace Task 4 placeholder)

**Interfaces:**
- Consumes: `derivedState.snapshot.blocks`, `TranscriptWindow.lastWindow(totalBlocks:blockTarget:)`, `FeatureFlags.transcriptWindowBlockTarget` (=400), `TranscriptColorSystem.semanticAccent(_:)/agentBrandAccent(source:)`, `@AppStorage("TranscriptFontSize")`.
- Produces: `struct TranscriptBlockListView: NSViewRepresentable` with init `(derivedState: TranscriptDerivedState, session: Session, fontSize: CGFloat)`; internal `final class BlockTableController: NSObject, NSTableViewDataSource, NSTableViewDelegate` (Coordinator); `struct BlockRowModel: Identifiable` — Tasks 6–11 extend these.

- [ ] **Step 1: Row model + controller + representable**

```swift
import SwiftUI
import AppKit

/// Row model: one row per displayed card. Task 6 adds .toolGroup merging.
struct BlockRowModel: Identifiable, Equatable {
    enum Content: Equatable {
        case message(SessionTranscriptBuilder.LogicalBlock)          // user/assistant/error/meta
        case toolGroup([SessionTranscriptBuilder.LogicalBlock])      // merged consecutive tool blocks (T6)
    }
    var id: Int              // globalBlockIndex of first block — stable across window widening
    var content: Content
}

struct TranscriptBlockListView: NSViewRepresentable {
    let derivedState: TranscriptDerivedState
    let session: Session
    let fontSize: CGFloat

    func makeCoordinator() -> BlockTableController { BlockTableController() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.headerView = nil
        table.style = .plain
        table.selectionHighlightStyle = .none
        table.intercellSpacing = NSSize(width: 0, height: 8)
        table.usesAutomaticRowHeights = false            // we own heights (T5 Step 3)
        let col = NSTableColumn(identifier: .init("card"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        context.coordinator.attach(table: table, scroll: scroll)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.apply(
            rows: Self.rowModels(from: windowedBlocks()),
            fontSize: fontSize,
            source: session.source)
    }

    /// Window discipline identical to the Terminal view: last-window slice,
    /// widened on demand (T7). Whole stream only when it fits the same
    /// char gate the Terminal uses.
    private func windowedBlocks() -> ArraySlice<SessionTranscriptBuilder.LogicalBlock> {
        let blocks = derivedState.snapshot.blocks
        guard FeatureFlags.transcriptWindowedBuild, blocks.count > FeatureFlags.transcriptWindowBlockTarget else {
            return blocks[...]
        }
        let window = context(coordinatorWindow: blocks.count)   // coordinator-held range, defaults to lastWindow
        return blocks[window]
    }
    // IMPLEMENTER: context(coordinatorWindow:) = read coordinator.loadedBlockRange,
    // defaulting to TranscriptWindow.lastWindow(totalBlocks:blockTarget:).range.
    // Store on the coordinator so widening (T7) survives updateNSView passes.

    static func rowModels(from blocks: ArraySlice<SessionTranscriptBuilder.LogicalBlock>) -> [BlockRowModel] {
        // T5: 1 block = 1 row (message rows only). T6 replaces this with tool-run merging.
        blocks.map { BlockRowModel(id: $0.globalBlockIndex, content: .message($0)) }
    }
}
```

- [ ] **Step 2: The card row view (SwiftUI chrome + NSTextView body)**

Same file. One `NSTableCellView` subclass hosting: a 3pt accent bar (NSBox), an `NSHostingView` header (role label + timestamp, SwiftUI), and a body `NSTextView` (non-editable, selectable, `drawsBackground = false`, `textContainer.widthTracksTextView = true`, monospaced system font at `fontSize`).

```swift
final class BlockCardCellView: NSTableCellView {
    static let reuseID = NSUserInterfaceItemIdentifier("BlockCardCellView")
    let accentBar = NSBox()
    let bodyText = SelectableBlockTextView()   // NSTextView subclass; T9 adds coordinator hooks
    private var headerHost: NSHostingView<BlockCardHeader>?

    func configure(row: BlockRowModel, fontSize: CGFloat, source: SessionSource) {
        guard case .message(let block) = row.content else { return } // toolGroup: T6
        let accent = Self.accentColor(kind: block.kind, source: source)
        accentBar.boxType = .custom; accentBar.borderWidth = 0
        accentBar.fillColor = accent
        bodyText.string = block.text
        bodyText.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        bodyText.textColor = .labelColor
        bodyText.isEditable = false; bodyText.isSelectable = true
        let header = BlockCardHeader(kind: block.kind, timestamp: block.timestamp, accent: Color(nsColor: accent))
        if let host = headerHost { host.rootView = header }
        else { headerHost = NSHostingView(rootView: header) /* + addSubview/constraints */ }
        // IMPLEMENTER: Auto Layout — accentBar pinned leading (3pt wide, full height);
        // header top; bodyText below header, trailing inset 12, bottom 8.
        // Card background: NSVisualEffect-free — layer.backgroundColor = accent.withAlphaComponent(0.06),
        // cornerRadius 6, masksToBounds true (role-tinted, HIG-quiet; NOT web-chat).
    }

    static func accentColor(kind: SessionTranscriptBuilder.LogicalBlock.Kind, source: SessionSource) -> NSColor {
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

struct BlockCardHeader: View {
    let kind: SessionTranscriptBuilder.LogicalBlock.Kind
    let timestamp: Date?
    let accent: Color
    var body: some View {
        HStack(spacing: 6) {
            Text(roleLabel).font(.system(size: 11, weight: .semibold)).foregroundStyle(accent)
            if let timestamp {
                Text(timestamp, format: .dateTime.hour().minute().second())
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 6).padding(.leading, 10).padding(.trailing, 12)
    }
    private var roleLabel: String {
        switch kind {
        case .user: "You"; case .assistant: "Agent"; case .toolCall: "Tool"
        case .toolOut: "Output"; case .error: "Error"; case .meta: "Meta"
        }
    }
}
```

- [ ] **Step 3: Heights + recycling in `BlockTableController`**

- `tableView(_:heightOfRow:)`: measure body text with `NSAttributedString.boundingRect` against `tableWidth - insets` (cache per `(rowID, widthBucket, fontSize, collapsedState)`; invalidate bucket cache on `frameDidChange`).
- `tableView(_:viewFor:row:)`: `makeView(withIdentifier: BlockCardCellView.reuseID)` or create; call `configure`.
- `apply(rows:fontSize:source:)`: diff by `id` against current rows. Append-only tail → `insertRows(at:)`; wholesale change → `reloadData()` with scroll-anchor capture/restore (capture first visible row id + offset via `rows(in: visibleRect)`, restore after reload — the perf-review §1.4 discipline). Width change → `noteHeightOfRows(withIndexesChanged: all)` inside `NSAnimationContext` with `duration = 0`.

- [ ] **Step 4: Wire into Rich mode, build, hand off visual QA**

Replace the Task 4 placeholder: `TranscriptBlockListView(derivedState: derivedState, session: session, fontSize: CGFloat(transcriptFontSize))`.
Run: `./scripts/xcode_test_stable.sh` (full — first task with real view code), then Debug build.
Owner QA: Rich mode on a mid-size session — cards render, accents match role palette, A−/A+ resizes, dark/light OK, resize window reflows heights without jumps.

- [ ] **Step 5: Commit checkpoint** (ask owner)

Proposed: `feat(transcript): Rich mode block list — NSTableView cards over LogicalBlocks`

---

### Task 6: Tool cards — one-line summaries, "N tool calls" merge, collapse/expand, truncation

**Files:**
- Create: `AgentSessions/Services/TranscriptToolSummary.swift`
- Modify: `AgentSessions/Views/TranscriptBlockListView.swift`
- Test: `AgentSessionsTests/TranscriptToolSummaryTests.swift`

**Interfaces:**
- Produces: `enum TranscriptToolSummary { static func summary(toolName: String?, toolInput: String?) -> String; static func mergeToolRuns(_ rows: [BlockRowModel]) -> [BlockRowModel] }`; `BlockTableController.expandedToolRowIDs: Set<Int>`; per-row "Show all N lines" state for >20-line bodies.

- [ ] **Step 1: Failing tests first**

```swift
import XCTest
@testable import AgentSessions

final class TranscriptToolSummaryTests: XCTestCase {
    func testShellCommandSummary() {
        let s = TranscriptToolSummary.summary(
            toolName: "shell",
            toolInput: #"{"command":["bash","-lc","ls -la /tmp"]}"#)
        XCTAssertEqual(s, "ls -la /tmp")
    }
    func testFilePathSummary() {
        let s = TranscriptToolSummary.summary(
            toolName: "Read",
            toolInput: #"{"file_path":"/Users/x/project/Sources/App/main.swift"}"#)
        XCTAssertEqual(s, "main.swift")
    }
    func testDescriptionFallback() {
        let s = TranscriptToolSummary.summary(
            toolName: "Bash",
            toolInput: #"{"command":"git status","description":"Show working tree status"}"#)
        XCTAssertEqual(s, "git status")   // command beats description
    }
    func testUnparseableInputFallsBackToToolName() {
        XCTAssertEqual(TranscriptToolSummary.summary(toolName: "MyTool", toolInput: "not json"), "MyTool")
        XCTAssertEqual(TranscriptToolSummary.summary(toolName: nil, toolInput: nil), "Tool call")
    }
    func testMergeConsecutiveToolRuns() {
        func tool(_ i: Int) -> BlockRowModel {
            var b = SessionTranscriptBuilder.LogicalBlock(kind: .toolCall, text: "t\(i)", timestamp: nil,
                messageID: nil, toolName: "shell", isDelta: false, toolInput: nil,
                isErrorOutput: false, eventID: "e\(i)", rawJSON: "")
            b.globalBlockIndex = i
            return BlockRowModel(id: i, content: .message(b))
        }
        func user(_ i: Int) -> BlockRowModel {
            var b = SessionTranscriptBuilder.LogicalBlock(kind: .user, text: "u", timestamp: nil,
                messageID: nil, toolName: nil, isDelta: false, toolInput: nil,
                isErrorOutput: false, eventID: "e\(i)", rawJSON: "")
            b.globalBlockIndex = i
            return BlockRowModel(id: i, content: .message(b))
        }
        let merged = TranscriptToolSummary.mergeToolRuns([user(0), tool(1), tool(2), tool(3), user(4)])
        XCTAssertEqual(merged.count, 3)
        guard case .toolGroup(let group) = merged[1].content else { return XCTFail("expected toolGroup") }
        XCTAssertEqual(group.count, 3)
        XCTAssertEqual(merged[1].id, 1)   // keyed by first block's globalBlockIndex
    }
}
```
(Adapt the `LogicalBlock` memberwise init to the real one at `SessionTranscriptBuilder.swift:288` — if it has no public memberwise init usable from tests, add a test-fixture factory in the shared fixtures file from Task 2.)

Register + run: `./scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessionsTests AgentSessionsTests/TranscriptToolSummaryTests.swift AgentSessionsTests` then `-only-testing:.../TranscriptToolSummaryTests`. Expected: FAIL (type not defined).

- [ ] **Step 2: Implement `TranscriptToolSummary`**

Priority order for `summary` (amended 2026-07-03 — original prose contradicted this task's own `testUnparseableInputFallsBackToToolName`; test semantics govern): parsed JSON `command` (string, or array → drop `bash -lc` style wrappers and join) → `description` → `file_path`/`path` last component → `pattern`/`query`/`url` → `toolName` → first non-empty line of raw `toolInput` (trim, cap 80 chars; reachable only when `toolName` is nil/empty) → `"Tool call"`. `mergeToolRuns`: single pass; consecutive rows whose block kind is `.toolCall`/`.toolOut` fold into one `.toolGroup` (run length ≥ 2; a lone tool block stays a `.message` row rendered as a collapsed tool card). Register the file to the **app target**. Run tests → PASS.

- [ ] **Step 3: Collapsed/expanded tool cards in the table**

- `TranscriptBlockListView.rowModels` now pipes through `TranscriptToolSummary.mergeToolRuns`.
- Collapsed tool card (default): chevron + `toolName` + summary + (group: "N tool calls" title with per-call summary lines when expanded one level). Header-only height (~28pt).
- Click chevron/header → toggle id in `expandedToolRowIDs`, then `noteHeightOfRows(withIndexesChanged:)` inside `NSAnimationContext.runAnimationGroup { $0.duration = 0.15 }` **with scroll-anchor capture/restore when the toggled row is above the viewport**.
- Expanded body >20 lines: show first 20 + "Show all N lines" button (SwiftUI in the header host) → per-row `showAllRowIDs` set, another height note.
- meta blocks (`.meta`) render as thin separator rows, no card chrome.

- [ ] **Step 4: Central verification + visual QA**

`./scripts/xcode_test_stable.sh` full. Owner QA: session heavy on tool calls — collapse default, expand/collapse stable scroll, "Show all" works, group merge counts right.

- [ ] **Step 5: Commit checkpoint** (ask owner)

Proposed: `feat(transcript): collapsible tool cards with one-line summaries and N-tool-call grouping`

---

### Task 7: Windowing — load older, widen-for-jump, follow-tail

**Files:**
- Modify: `AgentSessions/Views/TranscriptBlockListView.swift`

**Interfaces:**
- Consumes: `TranscriptWindow` expand helpers, `derivedState.snapshot.eventIDToAnchorBlockIndex`, `FeatureFlags.transcriptWindowNearTopLoadOlder`.
- Produces: `BlockTableController.loadedBlockRange: ClosedRange<Int>`, `func widen(toIncludeBlock: Int)`, `func scrollToBlock(_ globalBlockIndex: Int)`; follow-tail parity with Terminal mode.

- [ ] **Step 1: Load-older on near-top scroll**

Observe `NSView.boundsDidChangeNotification` on the scroll's contentView (same pattern as `PlainTextScrollView.installScrollObserverIfNeeded`). When top-proximity < 2 viewport-heights and `loadedBlockRange.lowerBound > 0`: extend the range down by `transcriptWindowBlockTarget`, rebuild rows, `insertRows(at: 0..<newCount)` with anchor capture/restore (no animation). Debounce 100ms.

- [ ] **Step 2: `widen(toIncludeBlock:)` + `scrollToBlock`**

Mirror of `widenWindowForJump` (`SessionTerminalView.swift:1050`): new lower = `max(0, min(target, upper) - FeatureFlags.transcriptWindowBlockTarget)`; rebuild rows; after the table reloads, `scrollRowToVisible(rowIndex(for: globalBlockIndex))` and flash the row (brief accent-alpha pulse on the card layer). All block-space — no line IDs involved.

- [ ] **Step 3: Follow-tail**

Track `isNearBottom` from the same bounds observer (distance-to-bottom < 1 row height ⇒ sticky). On `updateNSView` with appended rows (row-id diff is append-only): if sticky, `scrollRowToVisible(last)` after insert; if not, keep position and (parity with Text mode's `TranscriptTailUpdateState`) surface the existing "unseen updates" affordance if `UnifiedTranscriptView` already renders one for Text mode — reuse, don't invent.

- [ ] **Step 4: Verification + QA**

Full suite. Owner QA: monster session opens Rich fast (window = last 400 blocks); scroll to top loads older smoothly; live session follows tail; scrolling up during live output stops following; returning to bottom re-sticks.

- [ ] **Step 5: Commit checkpoint** (ask owner)

Proposed: `feat(transcript): Rich mode windowing — load-older, widen-for-jump, follow-tail`

---

### Task 8: Jump plumbing — first-prompt, event deeplinks, images

Rich mode must honor the same external jump intents Terminal mode handles, or nav buttons silently no-op in Rich mode.

**Files:**
- Modify: `AgentSessions/Views/TranscriptBlockListView.swift`, `AgentSessions/Views/TranscriptPlainView.swift`

- [ ] **Step 1: Inventory the intent surface**

Read how `UnifiedTranscriptView` triggers Terminal jumps (`jumpToFirstPrompt`, `jumpToEventID` — props/tokens into `SessionTerminalView`, see `SessionTerminalView.swift:218–219` pending-jump state). List every intent reaching Terminal mode from outside (toolbar first-prompt button, unified-search hit navigation, deeplinks, image strip).

- [ ] **Step 2: Route the same intents to Rich mode**

For each: resolve `eventID → derivedState.snapshot.eventIDToAnchorBlockIndex[eventID]` → `controller.widen(toIncludeBlock:)` + `scrollToBlock(_:)`. First-prompt = first non-preamble entry of `snapshot.userBlockIndices`. Pending-jump discipline: if snapshot is still computing, stash the intent and fire on next `apply`.

- [ ] **Step 3: Verification + QA + checkpoint** (ask owner)

Full suite; owner QA: unified search → hit in Rich mode scrolls to the right card; first-prompt button; image jump if wired.
Proposed: `feat(transcript): Rich mode honors first-prompt/event/image jump intents`

---

### Task 9: Cross-block selection + copy (acceptance gate #1)

**Files:**
- Create: `AgentSessions/Views/TranscriptSelectionCoordinator.swift`
- Modify: `AgentSessions/Views/TranscriptBlockListView.swift`
- Test: `AgentSessionsTests/TranscriptSelectionCoordinatorTests.swift`

**Interfaces:**
- Produces: pure `struct TranscriptSelectionCoordinator` (below) + integration: mouse-drag across cards selects continuously; ⌘C copies concatenated selection; ⌘A selects all loaded blocks.

- [ ] **Step 1: Failing tests for the pure math**

```swift
import XCTest
@testable import AgentSessions

final class TranscriptSelectionCoordinatorTests: XCTestCase {
    // 3 blocks with UTF-16 lengths 10, 5, 8
    private let lengths = [10, 5, 8]
    private func coord(_ a: (Int, Int), _ f: (Int, Int)) -> TranscriptSelectionCoordinator {
        var c = TranscriptSelectionCoordinator()
        c.begin(at: .init(blockOrdinal: a.0, utf16Offset: a.1))
        c.extend(to: .init(blockOrdinal: f.0, utf16Offset: f.1))
        return c
    }

    func testForwardSpanThreeBlocks() {
        let c = coord((0, 4), (2, 3))
        XCTAssertEqual(c.selectionRange(blockOrdinal: 0, textLength: lengths[0]), NSRange(location: 4, length: 6))
        XCTAssertEqual(c.selectionRange(blockOrdinal: 1, textLength: lengths[1]), NSRange(location: 0, length: 5))
        XCTAssertEqual(c.selectionRange(blockOrdinal: 2, textLength: lengths[2]), NSRange(location: 0, length: 3))
        XCTAssertNil(c.selectionRange(blockOrdinal: 3, textLength: 4))
    }
    func testBackwardDragNormalizes() {
        let c = coord((2, 3), (0, 4))   // dragged upward
        XCTAssertEqual(c.selectionRange(blockOrdinal: 0, textLength: lengths[0]), NSRange(location: 4, length: 6))
        XCTAssertEqual(c.selectionRange(blockOrdinal: 2, textLength: lengths[2]), NSRange(location: 0, length: 3))
    }
    func testSingleBlockSelection() {
        let c = coord((1, 1), (1, 4))
        XCTAssertEqual(c.selectionRange(blockOrdinal: 1, textLength: lengths[1]), NSRange(location: 1, length: 3))
        XCTAssertNil(c.selectionRange(blockOrdinal: 0, textLength: lengths[0]))
    }
    func testCopyAssemblyJoinsWithDoubleNewline() {
        let c = coord((0, 4), (2, 3))
        let texts = ["0123456789", "abcde", "ABCDEFGH"]
        XCTAssertEqual(c.selectedText(blockTexts: texts), "456789\n\nabcde\n\nABC")
    }
    func testCollapsedBlockContributesNothing() {
        var c = coord((0, 0), (2, 3))
        c.excludedBlockOrdinals = [1]   // collapsed tool card
        let texts = ["0123456789", "abcde", "ABCDEFGH"]
        XCTAssertEqual(c.selectedText(blockTexts: texts), "0123456789\n\nABC")
    }
}
```
Register to AgentSessionsTests, run `-only-testing` → FAIL.

- [ ] **Step 2: Implement the pure struct**

```swift
import Foundation

/// Pure cross-block selection math. blockOrdinal = index into the CURRENT row
/// text array (visible/loaded order), NOT globalBlockIndex — the table layer
/// owns the mapping. Collapsed cards are excluded via excludedBlockOrdinals
/// (locked P1 decision: collapsed tool cards contribute nothing to selection).
struct TranscriptSelectionCoordinator: Equatable {
    struct Position: Comparable, Equatable {
        var blockOrdinal: Int
        var utf16Offset: Int
        static func < (l: Position, r: Position) -> Bool {
            (l.blockOrdinal, l.utf16Offset) < (r.blockOrdinal, r.utf16Offset)
        }
    }
    private(set) var anchor: Position?
    private(set) var focus: Position?
    var excludedBlockOrdinals: Set<Int> = []

    mutating func begin(at p: Position) { anchor = p; focus = p }
    mutating func extend(to p: Position) { focus = p }
    mutating func clear() { anchor = nil; focus = nil }
    var isActive: Bool { anchor != nil && focus != nil && anchor != focus }

    func selectionRange(blockOrdinal: Int, textLength: Int) -> NSRange? {
        guard let anchor, let focus else { return nil }
        guard !excludedBlockOrdinals.contains(blockOrdinal) else { return nil }
        let (lo, hi) = anchor <= focus ? (anchor, focus) : (focus, anchor)
        guard blockOrdinal >= lo.blockOrdinal, blockOrdinal <= hi.blockOrdinal else { return nil }
        let start = blockOrdinal == lo.blockOrdinal ? min(lo.utf16Offset, textLength) : 0
        let end = blockOrdinal == hi.blockOrdinal ? min(hi.utf16Offset, textLength) : textLength
        guard end >= start else { return nil }
        return NSRange(location: start, length: end - start)
    }

    func selectedText(blockTexts: [String]) -> String {
        blockTexts.indices.compactMap { i -> String? in
            guard let r = selectionRange(blockOrdinal: i, textLength: (blockTexts[i] as NSString).length),
                  r.length > 0 || isSingleCaretBlock(i) else { return nil }
            return (blockTexts[i] as NSString).substring(with: r)
        }.joined(separator: "\n\n")
    }
    private func isSingleCaretBlock(_ i: Int) -> Bool { false }
}
```
(Adjust `selectedText` so full-block middle selections with `length == textLength` are included — the tests define exact behavior.) Register to app target. Run tests → PASS.

- [ ] **Step 3: Wire into the table**

In `BlockTableController`:
- Mouse handling on the scroll/table (override `mouseDown/mouseDragged/mouseUp` on the table or an overlay view): convert point → `row(at:)` → cell's `bodyText.characterIndexForInsertion(at:)` → `Position(blockOrdinal:utf16Offset:)`; `begin`/`extend`.
- On coordinator change: for each visible row, `bodyText.setSelectedRange(coordinator.selectionRange(...) ?? NSRange(location:0,length:0))`. `SelectableBlockTextView` overrides `resignFirstResponder`/`becomeFirstResponder` so multiple text views can SHOW selection simultaneously (set `insertionPointColor` clear, keep `selectedTextAttributes` at system highlight; verify inactive-selection color reads as active — if not, set `selectedTextAttributes` explicitly while multi-select is active).
- Drag near top/bottom edge → auto-scroll (`scrollRowToVisible` on a timer) and keep extending.
- ⌘C: first responder chain — controller implements `copy(_:)`: `coordinator.selectedText(blockTexts:)` (message rows = block text; expanded tool rows = their text; collapsed = excluded) → pasteboard. ⌘A: `begin` at (0,0), `extend` to (last, length).
- Single-block click-drag inside one card must still behave natively (don't fight NSTextView for intra-block drags: engage the coordinator only when the drag crosses a card boundary; until then let the body view handle it, then adopt its range as anchor).

- [ ] **Step 4: Verification + QA + checkpoint** (ask owner)

Full suite. Owner QA (the gate): drag across 3+ cards incl. a collapsed tool card; ⌘C paste into TextEdit — order right, collapsed content absent, `\n\n` separators; intra-card selection still native; ⌘A + copy on a windowed monster grabs loaded blocks without beachball.
Proposed: `feat(transcript): cross-block selection and copy in Rich mode`

---

### Task 10: ⌘F in Rich mode (acceptance gate #2)

**Files:**
- Modify: `AgentSessions/Views/TranscriptPlainView.swift` (`performFind` branch), `AgentSessions/Views/TranscriptBlockListView.swift`

**Interfaces:**
- Consumes: `derivedState.findMatches(query:)` (Task 2), `widen(toIncludeBlock:)`/`scrollToBlock` (Task 7), existing find-bar state (`findQueryDraft`, `isFindBarVisible`, `terminalFindToken`-style prop pattern at `TranscriptPlainView.swift:1934`).
- Produces: find in Rich mode with all-match highlight + distinct current match + next/prev incl. off-window, match counter in the find bar.

- [ ] **Step 1: Route find to Rich mode**

In `performFind` (`TranscriptPlainView.swift:1934`): add a `.blocks` branch modeled on the `.terminal` branch — pass `findQuery`, `findToken`, `findDirection`, `findReset` + the three external count bindings into `TranscriptBlockListView`. The block view computes `derivedState.findMatches(query:)` (whole session — off-window hits included), maintains `currentMatchOrdinal`, publishes counts back through the bindings.

- [ ] **Step 2: Highlights + navigation**

- Visible rows: `bodyText.textStorage` gets temporary background attrs (`.systemYellow.withAlphaComponent(0.35)`; current match `.controlAccentColor.withAlphaComponent(0.45)`) over each `rangeInBlockText` for that block; strip attrs when query clears. Collapsed tool cards containing a match show a match-count pill on the collapsed row (auto-expand is Phase 2, per handover — pill only in P1).
- next/prev: step ordinal; if target block outside `loadedBlockRange` → `widen(toIncludeBlock:)` then `scrollToBlock`; else scroll directly. Wrap around at ends (parity with Text mode).
- New/changed query: recompute, jump to first match at-or-after current viewport top (parity with Text mode's reset behavior).

- [ ] **Step 3: Verification + QA + checkpoint** (ask owner)

Full suite. Owner QA: ⌘F in Rich — counter matches Text mode's count for the same query/session (spot-check), next/prev walks in order incl. a hit 1000+ blocks up (window widens), highlight visible, Esc clears.
Proposed: `feat(transcript): whole-session find with off-window navigation in Rich mode`

---

### Task 11: Toolbar parity — Copy button, Export, ID chip, fonts

**Files:**
- Modify: `AgentSessions/Views/TranscriptPlainView.swift`

- [ ] **Step 1: Copy-all button in Rich mode**

`copyAll()` (`TranscriptPlainView.swift:2060`) currently copies the flat `transcript` string — in `.blocks` mode there is none. Branch: Rich mode copies `TranscriptMarkdownExporter.markdownContent(...)`-style plain assembly? No — parity decision: Copy button copies the same plain-terminal text Text mode produces (`SessionTranscriptBuilder.buildPlainTerminalTranscript(session:filters:mode:)`) so the button's output is mode-independent. One line: in `copyAll()`, if `viewMode == .blocks`, build via `SessionTranscriptBuilder.buildPlainTerminalTranscript` (off-main if large, reuse the existing rebuild cache when warm).

- [ ] **Step 2: Confirm export + ID chip + A−/A+ untouched**

Export already consumes `LogicalBlock` (`TranscriptMarkdownExporter.markdownContent`, `TranscriptPlainView.swift:33` → `coalescedBlocks` at :82) — verify the Export button isn't gated on `transcript` being non-empty in `.blocks` mode; fix the gate if so. ID chip and font buttons are mode-independent (shared toolbar + shared `TranscriptFontSize`); Task 5 already consumes `fontSize`.

- [ ] **Step 3: Verification + QA + checkpoint** (ask owner)

Full suite. Owner QA: Copy button output identical Text vs Rich for same session; Export produces the same .md both modes.
Proposed: `feat(transcript): toolbar Copy/Export parity for Rich mode`

---

### Task 12: Final gate — full verification + parity QA script

- [ ] **Step 1: Central full suite** — `./scripts/xcode_test_stable.sh`. Expected: everything green (1209 + new suites). The seven perf suites individually confirmed in the output.
- [ ] **Step 2: Perf sanity on a monster session** — Debug build; owner opens the largest local session in Rich mode. Bar (from perf program): first content well under 1s (target ~200ms like Terminal windowed open), no beachball on open/scroll/expand. If it feels off, profile with the PerfBench/sample discipline (memory: `feedback_perf_profiling_harness`) BEFORE shipping — do not eyeball-tune.
- [ ] **Step 3: Acceptance checklist with the owner (Rich mode):**
  - ⌘F highlight + next/prev + off-window ✓ (T10)
  - Cross-block selection + copy, collapsed cards excluded ✓ (T9)
  - Follow-tail on a live session ✓ (T7)
  - Markdown export unchanged ✓ (T11)
  - Session/Text/JSON modes byte-identical to pre-plan behavior (spot-check Terminal jumps — T3 touched them)
- [ ] **Step 4: Update docs** — `docs/superpowers/plans/2026-07-03-transcript-redesign-HANDOVER.md`: mark Phase 0+1 done, note the `.blocks` mode name ("Rich"), the macOS 15 floor, and that Phase 2 (markdown + search-auto-expand) is next. Add the pbxproj triple-`AgentSessionsLogicTests` cleanup as a flagged follow-up (do NOT clean it up inside this plan).
- [ ] **Step 5: Ask the owner** about commit/push of anything still uncommitted, and whether to proceed to Phase 2 planning.

---

## Appendix — Architecture decisions (Opus memo, 2026-07-03, adopted)

1. **Block list = view-based NSTableView in NSViewRepresentable.** Decisive constraint: scroll-anchor stability when rows above the viewport change height (expand/collapse, load-older prepend). SwiftUI LazyVStack/List cannot pin the anchor (macOS 15's `onScrollGeometryChange` observes, doesn't control); `noteHeightOfRows` + `insertRows` + explicit anchor restore can. List also risks the documented SwiftUI-Table O(n²) wholesale-reorder pathology.
2. **Cross-block selection = per-block NSTextView bodies + pure selection coordinator.** SwiftUI `.textSelection` container behavior across sibling Texts does not exist on macOS 15 (the 15 additions are TextEditor selection bindings), and per-row NSHostingViews are separate SwiftUI roots anyway. Fallback if the coordinator slips: render cards as decorations inside a single windowed NSTextView (the proven Terminal engine). Text mode stays selectable until parity regardless.
3. **⌘F = whole-session matches on TranscriptDerivedState over `LogicalBlock.text`; off-window nav reuses `eventIDToAnchorBlockIndex` + the `widenWindowForJump` pattern verbatim.**
4. **TranscriptDerivedState = consolidation, not rewrite** — block-space only (blocks, anchors, role indices, find matches); line-space stays in the Terminal view. `@Observable` (Observation framework, macOS 14+) with one snapshot struct for batched publishes.
5. **Card bodies = NSTextView from day one** (selection gate requires it; Phase 2 markdown lands as NSAttributedString on the same views; find highlights are NSRange attrs).
6. **macOS 15 bump: CANCELLED** — initially approved, then reverted 2026-07-03 when the owner challenged its value: the memo's `@Observable` justification was factually wrong (Observation is macOS 14+), and no chosen component uses a 15-only API. Floor remains 14.0.

**Prior-art note (cite, don't re-argue):** `docs/perf-fable-review.md` §1.3 rejected per-block views *as a Terminal perf fix*; this plan's goal is formatting, its named risks (selection, Find) are Tasks 9–10's acceptance gates, and Terminal mode ships untouched as the fallback.
