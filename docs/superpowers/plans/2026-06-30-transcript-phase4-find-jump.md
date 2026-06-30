# Transcript Phase 4 — Bidirectional Find + Counts + Jump-to-Range (Windowed) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make in-session Find (both ⌘F local Find and ⌥⌘F Unified Search) work across the WHOLE session under windowed transcript build — accurate total match counts up front from a cheap model-level scan over `Session.events`, with Find next/prev navigating that global match list by loading older OR newer windows to bring the target match into the loaded window, explicit wrap semantics, and jump-to-range/deep-link loading the containing window then scrolling.

**Architecture:** A new `TranscriptFindIndex` does a text-only scan over coalesced blocks (no line build) to produce, up front, the accurate total match count and a stable ordered list of global match locations keyed by `(globalBlockIndex, occurrenceOrdinalInBlock)`. `SessionTerminalView` consumes this index: counts come from `index.total`; next/prev advances a global cursor over the index, asks the Phase 3 windower to ensure the target match's block is loaded (load-older or load-newer), then maps the in-block occurrence to a built `TerminalLine` range and drives the existing highlight + scroll machinery. Wrap is explicit (next past last → first match, load its window; prev past first → last match, load its window). Jump-to-range / deep-link / first-prompt load the containing window then scroll.

**Tech Stack:** Swift 5 / SwiftUI / AppKit (NSTextView + custom `TerminalLayoutManager`), XCTest. macOS app target `AgentSessions`, test target `AgentSessionsTests`.

## Global Constraints

- **Feature flag gate:** All Phase 4 behavior is gated behind `FeatureFlags.transcriptWindowedBuild` (a `Bool` added in Phase 2). When the flag is OFF, Find/jump behave exactly as today (whole-session `fullSnapshot` build). When ON, the model-scan path is used. Every task that touches `SessionTerminalView` find/jump code must branch on this flag and keep the legacy path intact.
- **Assumed in place (Phase 2 + Phase 3 deliverables — do NOT implement here):**
  - Phase 2: `TerminalLine.id`, `TerminalLine.eventIndex`, and `TerminalLine.blockIndex` derive from **global** block/event identity (not local `enumerated()`/`nextID` from 0). `MatchOccurrence.lineID` is therefore a stable global line id. The coalescer yields a single canonical ordered `[LogicalBlock]` for the whole session; each block has a stable **global block index** equal to its position in that array.
  - Phase 3: `SessionTerminalView` holds a windowed `lines` array (a contiguous slice of whole coalesced blocks), plus a windower exposing: `loadedBlockRange: Range<Int>` (global block indices currently built), `func ensureBlockLoaded(_ globalBlockIndex: Int)` (synchronously extends the window older or newer to include that block, preserving scroll anchor, and updates `lines`/`visibleLines`/`lineRanges`), and the existing `lineRanges: [Int: NSRange]` map keyed by global line id for the loaded window.
- **New Swift files** are added to the Xcode project via:
  `LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 ./scripts/xcode_add_file.rb AgentSessions.xcodeproj <TARGET> <path> <group>`
  (TARGET is `AgentSessions` for app code, `AgentSessionsTests` for tests.)
- **Tests run via:** `./scripts/xcode_test_stable.sh` (optionally narrowed with `-only-testing:AgentSessionsTests/<Class>/<method>` appended — confirm the script forwards extra args; if not, run the whole suite).
- **Commits:** Conventional Commits with trailers `Tool: Claude Code`, `Model: claude-opus-4-8`, `Why: <reason>`. NO co-author trailer, NO "Generated with" footer. Author is the repo owner only. Do not commit or push unless the user explicitly asks; the plan's commit steps stage + commit locally only.
- **Text matching semantics** must match the rest of the app: use `SearchTextMatcher.matchRanges(in:query:)` (FilterEngine.swift:115) for occurrence extraction so phrase/boolean/prefix behavior is identical to the existing terminal Find. The model scan and the in-window mapping both use it.

---

## Background: how Find works today (for the implementer)

Read these before starting. All paths are in `/Users/alexm/Repository/Codex-History`.

- `AgentSessions/Views/TranscriptPlainView.swift`
  - `performUnifiedFind(resetIndex:direction:shouldJump:)` (~1826) and `performFind(...)` (~1901): in terminal mode these only set tokens/flags (`terminalUnifiedFindToken`, `terminalUnifiedFindDirection`, `terminalUnifiedFindResetFlag`, `terminalUnifiedAllowMatchAutoScroll`, and the `terminalFind*` equivalents) and return. The real work happens inside `SessionTerminalView`.
  - State bindings (`@State`, ~506–521): `terminalUnifiedMatchesCount`, `terminalUnifiedTotalMatchesCount`, `terminalUnifiedCurrentIndex`, plus `terminalFind*` equivalents.
  - `terminalStatus(currentIndex:visible:total:)` (~1998) renders `"<cur>/<visible>"` or `"<cur>/<visible> (<total>)"` when `visible != total`. Phase 4 makes navigation traverse ALL matches, so `visible` becomes `total` and the status reads `"<cur>/<total>"`.
- `AgentSessions/Views/SessionTerminalView.swift`
  - `MatchOccurrence { range: NSRange; lineID: Int }` (~6); `TextSnapshot` (~11) holds `text` + line-range maps.
  - `@State lines` (~102, whole-session today / window under Phase 3), `visibleLines` (~103, role/semantic-filtered subset), `fullSnapshot`/`visibleSnapshot` (~105–106).
  - `recomputeUnifiedMatches(resetIndex:direction:preserveCurrentLine:)` (~1646) and `recomputeFindMatches(...)` (~1697): today they scan `visibleSnapshot.text` for navigable occurrences and `fullSnapshot.text` only for a total count, advance an index within the **visible** occurrences (wrap within visible), and set `unifiedCurrentMatchLineID` / `findCurrentMatchLineID`.
  - `buildTextSnapshot(lines:)` (~1747), `occurrences(from:in:)` (~1784), `lineID(for:in:)` (~1795 binary search).
  - `handleUnifiedFindRequest()` / `handleFindRequest()` (~1637/1642) invoked from `.onChange(of: unifiedFindToken)` / `.onChange(of: findToken)` (~556/557).
  - Auto-scroll on token change in `updateNSView` (~4219–4233): scrolls `lineRanges[currentMatchLineID]` into view.
  - `jumpToUserPrompt(lineID:alignTop:)` (~1864), `jumpToEventID(_:)` (~1888), `jumpToUserPromptIndex(_:)` (~1879), `jumpToFirstPrompt()` (~1859), `scrollTargetLineID`/`scrollTargetToken` (~173/174) drive deep-link/jump scrolling.

**The core change:** today `fullSnapshot` is the whole-session line build (so total counts are correct). Under windowing `lines` is only a window, so `fullSnapshot` is no longer the whole session. Phase 4 replaces the whole-session *line* build with a whole-session *text* scan (`TranscriptFindIndex`) for counts AND for the canonical navigation list, then loads windows to reach each match.

## File Structure

- **Create** `AgentSessions/Services/TranscriptFindIndex.swift` — model-level scan; pure value type; no UI. Owns: query → ordered global match locations + total count; cursor advance with wrap; lookup of the global block index for a cursor position.
- **Create** `AgentSessionsTests/TranscriptFindIndexTests.swift` — unit tests for the scan (counts, ordering, block mapping, wrap, empty/no-match).
- **Create** `AgentSessionsTests/SessionTerminalFindWindowedTests.swift` — integration-ish tests for the in-block occurrence → line range mapping and the load-to-match decision (pure helpers, no NSTextView).
- **Modify** `AgentSessions/Views/SessionTerminalView.swift` — consume `TranscriptFindIndex` behind the flag in `recomputeUnifiedMatches`/`recomputeFindMatches`; add `findIndex`/`unifiedFindIndex` state, the load-to-match navigation, and jump-to-range window loading.
- **Modify** `AgentSessions/Support/FeatureFlags.swift` — only if Phase 2 has not already added `transcriptWindowedBuild` (the plan adds it defensively in Task 0; skip if present).

---

## Task 0: Ensure the feature flag exists

**Files:**
- Modify: `AgentSessions/Support/FeatureFlags.swift`

**Interfaces:**
- Produces: `FeatureFlags.transcriptWindowedBuild: Bool` (used by every later task).

- [ ] **Step 1: Check whether the flag already exists**

Run: `grep -n "transcriptWindowedBuild" AgentSessions/Support/FeatureFlags.swift`
Expected: either a line `static let transcriptWindowedBuild` (Phase 2 already added it — **skip the rest of Task 0**), or no output (add it below).

- [ ] **Step 2: Add the flag if missing**

If Step 1 produced no output, add this line inside `enum FeatureFlags` in `AgentSessions/Support/FeatureFlags.swift`, immediately after the `static let largeSessionByteThreshold` line (around line 17):

```swift
    // Phase 2–4 windowed transcript build. When true, the terminal renderer builds
    // only a window of blocks and Find/jump scan the whole session at the model level.
    static let transcriptWindowedBuild = false
```

- [ ] **Step 3: Verify it compiles**

Run: `./scripts/xcode_test_stable.sh`
Expected: build succeeds (existing tests pass; no behavior change because the flag defaults to `false`).

- [ ] **Step 4: Commit (only if you added the flag)**

```bash
git add AgentSessions/Support/FeatureFlags.swift
git commit -m "feat(transcript): add transcriptWindowedBuild feature flag

Tool: Claude Code
Model: claude-opus-4-8
Why: Phase 4 Find/jump must be gated behind the windowed-build flag"
```

---

## Task 1: `TranscriptFindIndex` — model scan, total count, ordered global locations

**Files:**
- Create: `AgentSessions/Services/TranscriptFindIndex.swift`
- Test: `AgentSessionsTests/TranscriptFindIndexTests.swift`

**Interfaces:**
- Consumes: `SessionTranscriptBuilder.coalescedBlocks(for:includeMeta:)` → `[SessionTranscriptBuilder.LogicalBlock]` (each block has `.text` and a stable global index = position in the array); `SearchTextMatcher.matchRanges(in:query:)` for occurrence extraction.
- Produces (used by Task 3+):
  - `struct TranscriptFindIndex` with:
    - `struct Location: Equatable { let globalBlockIndex: Int; let occurrenceOrdinalInBlock: Int }`
    - `let locations: [Location]` (document order: ascending `globalBlockIndex`, then ascending `occurrenceOrdinalInBlock`)
    - `var total: Int { locations.count }`
    - `static func build(blocks: [SessionTranscriptBuilder.LogicalBlock], query: String) -> TranscriptFindIndex`
    - `func location(at index: Int) -> Location?` (bounds-checked)
    - `func advance(from index: Int?, direction: Int) -> Int?` — wrap-aware cursor advance over `locations`; returns the next cursor index. Wrap: from `nil` with `direction >= 0` → `0`; from `nil` with `direction < 0` → `total - 1`; past last (forward) → `0`; before first (backward) → `total - 1`. Returns `nil` when `total == 0`.

- [ ] **Step 1: Write the failing test file**

Create `AgentSessionsTests/TranscriptFindIndexTests.swift`:

```swift
import XCTest
@testable import AgentSessions

final class TranscriptFindIndexTests: XCTestCase {

    // Build a minimal LogicalBlock with just text + a placeholder eventID/index.
    private func block(_ text: String, kind: SessionTranscriptBuilder.LogicalBlock.Kind = .assistant) -> SessionTranscriptBuilder.LogicalBlock {
        SessionTranscriptBuilder.LogicalBlock(
            kind: kind,
            text: text,
            timestamp: nil,
            messageID: nil,
            toolName: nil,
            isDelta: false,
            toolInput: nil,
            isErrorOutput: false,
            eventID: "evt",
            rawJSON: ""
        )
    }

    func test_totalCountsAllOccurrencesAcrossBlocks() {
        let blocks = [
            block("alpha beta alpha"),   // 2 occurrences of "alpha"
            block("gamma"),              // 0
            block("alpha")               // 1
        ]
        let index = TranscriptFindIndex.build(blocks: blocks, query: "alpha")
        XCTAssertEqual(index.total, 3)
    }

    func test_locationsAreInDocumentOrderWithBlockAndOrdinal() {
        let blocks = [
            block("alpha beta alpha"),
            block("gamma"),
            block("alpha")
        ]
        let index = TranscriptFindIndex.build(blocks: blocks, query: "alpha")
        XCTAssertEqual(index.locations, [
            .init(globalBlockIndex: 0, occurrenceOrdinalInBlock: 0),
            .init(globalBlockIndex: 0, occurrenceOrdinalInBlock: 1),
            .init(globalBlockIndex: 2, occurrenceOrdinalInBlock: 0)
        ])
    }

    func test_emptyQueryYieldsNoMatches() {
        let index = TranscriptFindIndex.build(blocks: [block("alpha")], query: "   ")
        XCTAssertEqual(index.total, 0)
        XCTAssertTrue(index.locations.isEmpty)
    }

    func test_noMatchYieldsZeroTotal() {
        let index = TranscriptFindIndex.build(blocks: [block("alpha")], query: "zzz")
        XCTAssertEqual(index.total, 0)
    }

    func test_advanceForwardWrapsPastLastToFirst() {
        let blocks = [block("alpha alpha")] // 2 matches at indices 0,1
        let index = TranscriptFindIndex.build(blocks: blocks, query: "alpha")
        XCTAssertEqual(index.advance(from: nil, direction: 1), 0)
        XCTAssertEqual(index.advance(from: 0, direction: 1), 1)
        XCTAssertEqual(index.advance(from: 1, direction: 1), 0) // wrap
    }

    func test_advanceBackwardWrapsPastFirstToLast() {
        let blocks = [block("alpha alpha alpha")] // 3 matches
        let index = TranscriptFindIndex.build(blocks: blocks, query: "alpha")
        XCTAssertEqual(index.advance(from: nil, direction: -1), 2)
        XCTAssertEqual(index.advance(from: 0, direction: -1), 2) // wrap
        XCTAssertEqual(index.advance(from: 2, direction: -1), 1)
    }

    func test_advanceReturnsNilWhenNoMatches() {
        let index = TranscriptFindIndex.build(blocks: [block("alpha")], query: "zzz")
        XCTAssertNil(index.advance(from: nil, direction: 1))
        XCTAssertNil(index.advance(from: 0, direction: -1))
    }

    func test_locationAtIsBoundsChecked() {
        let index = TranscriptFindIndex.build(blocks: [block("alpha")], query: "alpha")
        XCTAssertEqual(index.location(at: 0), .init(globalBlockIndex: 0, occurrenceOrdinalInBlock: 0))
        XCTAssertNil(index.location(at: 1))
        XCTAssertNil(index.location(at: -1))
    }
}
```

- [ ] **Step 2: Add the test file to the test target**

Run:
```bash
LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 ./scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessionsTests AgentSessionsTests/TranscriptFindIndexTests.swift AgentSessionsTests
```
Expected: prints that the file was added (or already referenced — if so, continue).

- [ ] **Step 3: Run the test to verify it fails**

Run: `./scripts/xcode_test_stable.sh`
Expected: FAIL with "cannot find 'TranscriptFindIndex' in scope" (type not defined yet).

- [ ] **Step 4: Create the implementation**

Create `AgentSessions/Services/TranscriptFindIndex.swift`:

```swift
import Foundation

/// Model-level Find index over a session's coalesced blocks.
///
/// Built by scanning **block text only** (no `TerminalLine` build), so it is cheap
/// even for very large sessions. Produces the accurate total match count and an
/// ordered list of global match locations, each identified by the block's global
/// index plus the occurrence ordinal within that block. Navigation (Find next/prev)
/// walks `locations`; the view loads the window containing the target block and maps
/// the in-block occurrence to a built line range.
struct TranscriptFindIndex: Equatable {

    /// A single match location in the whole session, independent of what window is loaded.
    struct Location: Equatable {
        /// Position of the block in the canonical whole-session `coalescedBlocks` array.
        let globalBlockIndex: Int
        /// 0-based index of this match among matches within that block, in text order.
        let occurrenceOrdinalInBlock: Int
    }

    /// Matches in document order: ascending `globalBlockIndex`, then ascending
    /// `occurrenceOrdinalInBlock`.
    let locations: [Location]

    /// The query this index was built for (trimmed). Empty when the index is empty.
    let query: String

    var total: Int { locations.count }

    static let empty = TranscriptFindIndex(locations: [], query: "")

    /// Scan block text for `query` and produce ordered global locations.
    ///
    /// Uses `SearchTextMatcher.matchRanges(in:query:)` per block so phrase/boolean/prefix
    /// semantics are identical to the rest of the app's text search.
    static func build(blocks: [SessionTranscriptBuilder.LogicalBlock], query: String) -> TranscriptFindIndex {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return empty }

        var locations: [Location] = []
        for (blockIndex, block) in blocks.enumerated() {
            let ranges = SearchTextMatcher.matchRanges(in: block.text, query: trimmed)
            guard !ranges.isEmpty else { continue }
            for ordinal in 0..<ranges.count {
                locations.append(Location(globalBlockIndex: blockIndex,
                                          occurrenceOrdinalInBlock: ordinal))
            }
        }
        return TranscriptFindIndex(locations: locations, query: trimmed)
    }

    /// The location at cursor `index`, or nil if out of bounds.
    func location(at index: Int) -> Location? {
        guard index >= 0, index < locations.count else { return nil }
        return locations[index]
    }

    /// Wrap-aware cursor advance over `locations`.
    ///
    /// - From `nil`: forward → first (0), backward → last (total - 1).
    /// - Forward past the last → 0 (wrap). Backward before the first → total - 1 (wrap).
    /// - Returns `nil` when there are no matches.
    func advance(from index: Int?, direction: Int) -> Int? {
        guard !locations.isEmpty else { return nil }
        let last = locations.count - 1
        guard let current = index else {
            return direction >= 0 ? 0 : last
        }
        if direction >= 0 {
            return current >= last ? 0 : current + 1
        } else {
            return current <= 0 ? last : current - 1
        }
    }
}
```

- [ ] **Step 5: Add the implementation file to the app target**

Run:
```bash
LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 ./scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessions AgentSessions/Services/TranscriptFindIndex.swift Services
```
Expected: prints that the file was added.

- [ ] **Step 6: Run the test to verify it passes**

Run: `./scripts/xcode_test_stable.sh`
Expected: PASS for all `TranscriptFindIndexTests`.

- [ ] **Step 7: Commit**

```bash
git add AgentSessions/Services/TranscriptFindIndex.swift AgentSessionsTests/TranscriptFindIndexTests.swift AgentSessions.xcodeproj/project.pbxproj
git commit -m "feat(transcript): add TranscriptFindIndex model scan for windowed Find

Tool: Claude Code
Model: claude-opus-4-8
Why: accurate whole-session Find counts + ordered global match locations without a line build"
```

---

## Task 2: In-block occurrence → loaded-window line range mapping

This task adds a pure helper that, given a `TranscriptFindIndex.Location` and the loaded window's lines, finds the `TerminalLine` and the **NSRange of that specific occurrence** within the line, so the existing highlight + scroll machinery can target it. The helper is pure (operates on arrays/maps) so it is unit-testable without an NSTextView.

**Files:**
- Modify: `AgentSessions/Views/SessionTerminalView.swift` (add a `static` helper + a small struct)
- Test: `AgentSessionsTests/SessionTerminalFindWindowedTests.swift`

**Interfaces:**
- Consumes: `TranscriptFindIndex.Location`; the loaded window's `lines: [TerminalLine]` (each line has global `id` and global `blockIndex`); `SearchTextMatcher.matchRanges(in:query:)`.
- Produces (used by Task 3):
  - `struct WindowedMatchTarget: Equatable { let lineID: Int; let occurrenceRangeInLine: NSRange }`
  - `static func windowedMatchTarget(for location: TranscriptFindIndex.Location, query: String, lines: [TerminalLine]) -> WindowedMatchTarget?` — returns the line id + the NSRange (within that line's text, UTF-16) of the `occurrenceOrdinalInBlock`-th match of `query` across the block's lines in order; `nil` if the block is not in `lines` (caller must load the window first) or the ordinal can't be located.

- [ ] **Step 1: Write the failing test file**

Create `AgentSessionsTests/SessionTerminalFindWindowedTests.swift`:

```swift
import XCTest
@testable import AgentSessions

final class SessionTerminalFindWindowedTests: XCTestCase {

    private func line(id: Int, blockIndex: Int, _ text: String) -> TerminalLine {
        TerminalLine(id: id,
                     text: text,
                     role: .assistant,
                     eventIndex: blockIndex,
                     blockIndex: blockIndex,
                     decorationGroupID: blockIndex * 1000,
                     semanticKind: nil)
    }

    func test_mapsFirstOccurrenceInBlockToCorrectLineAndRange() {
        // Block 7 spans two loaded lines; "alpha" appears once on each line.
        let lines = [
            line(id: 100, blockIndex: 7, "alpha here"),
            line(id: 101, blockIndex: 7, "and alpha again")
        ]
        let loc = TranscriptFindIndex.Location(globalBlockIndex: 7, occurrenceOrdinalInBlock: 0)
        let target = SessionTerminalView.windowedMatchTarget(for: loc, query: "alpha", lines: lines)
        XCTAssertEqual(target?.lineID, 100)
        XCTAssertEqual(target?.occurrenceRangeInLine, NSRange(location: 0, length: 5))
    }

    func test_mapsSecondOccurrenceInBlockToSecondLine() {
        let lines = [
            line(id: 100, blockIndex: 7, "alpha here"),
            line(id: 101, blockIndex: 7, "and alpha again")
        ]
        let loc = TranscriptFindIndex.Location(globalBlockIndex: 7, occurrenceOrdinalInBlock: 1)
        let target = SessionTerminalView.windowedMatchTarget(for: loc, query: "alpha", lines: lines)
        XCTAssertEqual(target?.lineID, 101)
        XCTAssertEqual(target?.occurrenceRangeInLine, NSRange(location: 4, length: 5))
    }

    func test_returnsNilWhenBlockNotLoaded() {
        let lines = [line(id: 100, blockIndex: 7, "alpha here")]
        let loc = TranscriptFindIndex.Location(globalBlockIndex: 99, occurrenceOrdinalInBlock: 0)
        XCTAssertNil(SessionTerminalView.windowedMatchTarget(for: loc, query: "alpha", lines: lines))
    }

    func test_returnsNilWhenOrdinalOutOfRangeInLoadedBlock() {
        let lines = [line(id: 100, blockIndex: 7, "alpha here")] // only 1 occurrence
        let loc = TranscriptFindIndex.Location(globalBlockIndex: 7, occurrenceOrdinalInBlock: 5)
        XCTAssertNil(SessionTerminalView.windowedMatchTarget(for: loc, query: "alpha", lines: lines))
    }
}
```

- [ ] **Step 2: Add the test file to the test target**

Run:
```bash
LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 ./scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessionsTests AgentSessionsTests/SessionTerminalFindWindowedTests.swift AgentSessionsTests
```
Expected: prints that the file was added.

- [ ] **Step 3: Run the test to verify it fails**

Run: `./scripts/xcode_test_stable.sh`
Expected: FAIL with "type 'SessionTerminalView' has no member 'windowedMatchTarget'".

- [ ] **Step 4: Add the helper to `SessionTerminalView`**

In `AgentSessions/Views/SessionTerminalView.swift`, immediately AFTER the private `lineID(for:in:)` method (it ends at ~line 1816, just before `skipAgentsPreambleEnabled()`), insert:

```swift
    /// Target of a windowed Find match: the loaded line plus the NSRange of the
    /// specific occurrence within that line's text (UTF-16).
    struct WindowedMatchTarget: Equatable {
        let lineID: Int
        let occurrenceRangeInLine: NSRange
    }

    /// Map a global match `location` to a loaded line + in-line occurrence range.
    ///
    /// The block's lines must already be present in `lines` (the caller loads the
    /// window first via the Phase 3 windower). Walks the block's lines in order,
    /// counting `query` occurrences per line, and returns the line + range for the
    /// `occurrenceOrdinalInBlock`-th occurrence. Returns nil if the block is not
    /// loaded or the ordinal exceeds the occurrences currently built for that block.
    static func windowedMatchTarget(for location: TranscriptFindIndex.Location,
                                    query: String,
                                    lines: [TerminalLine]) -> WindowedMatchTarget? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var remaining = location.occurrenceOrdinalInBlock
        var sawBlock = false
        for line in lines where line.blockIndex == location.globalBlockIndex {
            sawBlock = true
            let ranges = SearchTextMatcher.matchRanges(in: line.text, query: trimmed)
            if remaining < ranges.count {
                return WindowedMatchTarget(lineID: line.id,
                                           occurrenceRangeInLine: ranges[remaining])
            }
            remaining -= ranges.count
        }
        _ = sawBlock
        return nil
    }
```

> Note on correctness: `TranscriptFindIndex` counts occurrences over the **block's full text**, while this helper counts over the **per-line rendered text**. For ordinal alignment, the block's lines concatenated must contain the same occurrences in the same order. Plain blocks satisfy this. Blocks whose rendering injects synthetic prefixes (semantic code/diff line numbers, "Code"/"Diff" headers) can shift or add text; Task 5 narrows the index to use the **same per-line rendered text** the window builds, eliminating the discrepancy. For Task 2/3 this helper is correct for the common case and degrades to "load window, then re-scan loaded lines" (Task 3 Step 6 fallback) when it returns nil.

- [ ] **Step 5: Run the test to verify it passes**

Run: `./scripts/xcode_test_stable.sh`
Expected: PASS for all `SessionTerminalFindWindowedTests`.

- [ ] **Step 6: Commit**

```bash
git add AgentSessions/Views/SessionTerminalView.swift AgentSessionsTests/SessionTerminalFindWindowedTests.swift AgentSessions.xcodeproj/project.pbxproj
git commit -m "feat(transcript): map global Find locations to loaded-window line ranges

Tool: Claude Code
Model: claude-opus-4-8
Why: windowed Find must resolve a global match to a built line + in-line range to highlight"
```

---

## Task 3: Wire windowed Find navigation (counts + bidirectional load-to-match + wrap) into `SessionTerminalView`

This is the core integration. Behind `transcriptWindowedBuild`, `recomputeUnifiedMatches` / `recomputeFindMatches` build/refresh a `TranscriptFindIndex`, set the **total** count from it, advance a global cursor with wrap, load the window containing the target block, map to a line range, and drive the existing highlight + scroll. When the flag is OFF, the existing visible/full snapshot path runs unchanged.

**Files:**
- Modify: `AgentSessions/Views/SessionTerminalView.swift`

**Interfaces:**
- Consumes: `TranscriptFindIndex` (Task 1); `windowedMatchTarget(for:query:lines:)` (Task 2); Phase 3 windower `func ensureBlockLoaded(_ globalBlockIndex: Int)` and `loadedBlockRange`; existing `unifiedMatchOccurrences`, `unifiedCurrentMatchLineID`, `findMatchOccurrences`, `findCurrentMatchLineID`, and the external count bindings.
- Produces: navigation that updates `unifiedExternalTotalMatchCount` / `externalTotalMatchCount` to the **whole-session** total, `unifiedExternalMatchCount` / `externalMatchCount` to the same total (so status reads `cur/total`), and `unifiedExternalCurrentMatchIndex` / `externalCurrentMatchIndex` to the **global** cursor (1-based for display is handled in `terminalStatus`).

- [ ] **Step 1: Add state for the global Find indexes and cursors**

In `AgentSessions/Views/SessionTerminalView.swift`, after the "Local Find state" block (the `findCurrentMatchLineID` declaration at ~line 171), add:

```swift
    // Phase 4 windowed Find: whole-session model scan + global cursor.
    @State private var unifiedFindIndex: TranscriptFindIndex = .empty
    @State private var unifiedFindCursor: Int? = nil
    @State private var findFindIndex: TranscriptFindIndex = .empty
    @State private var findFindCursor: Int? = nil
```

- [ ] **Step 2: Add a cached coalesced-blocks accessor for the scan**

The scan needs the whole-session `[LogicalBlock]`. Re-coalescing on every keystroke is wasteful; cache it by session identity + event count. After the state added in Step 1, add:

```swift
    @State private var findScanBlocks: [SessionTranscriptBuilder.LogicalBlock] = []
    @State private var findScanBlocksSignature: Int = 0

    /// Whole-session coalesced blocks for the model-level Find scan, cached by
    /// session id + event count so we coalesce once per content version.
    private func coalescedBlocksForFindScan() -> [SessionTranscriptBuilder.LogicalBlock] {
        var hasher = Hasher()
        hasher.combine(session.id)
        hasher.combine(session.events.count)
        let signature = hasher.finalize()
        if signature == findScanBlocksSignature, !findScanBlocks.isEmpty {
            return findScanBlocks
        }
        let blocks = SessionTranscriptBuilder.coalescedBlocks(for: session, includeMeta: false)
        findScanBlocks = blocks
        findScanBlocksSignature = signature
        return blocks
    }
```

- [ ] **Step 3: Add the windowed navigation core**

After `coalescedBlocksForFindScan()`, add a shared navigation routine used by both Unified and local Find. It builds/keeps the index, advances the cursor with wrap, loads the target window, maps to a line, and writes the external count/index state. The `kind` parameter selects which set of bindings/state to write.

```swift
    private enum WindowedFindKind { case unified, local }

    /// Drive a windowed Find request: build/refresh the whole-session index, advance the
    /// global cursor (with wrap), load the window containing the target match, map it to a
    /// loaded line, and update highlight + count state. `resetIndex` true means "(re)build
    /// and select the first match"; otherwise advance by `direction` from the current cursor.
    private func recomputeWindowedFind(kind: WindowedFindKind,
                                       query rawQuery: String,
                                       resetIndex: Bool,
                                       direction: Int) {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)

        func clearState() {
            switch kind {
            case .unified:
                unifiedFindIndex = .empty
                unifiedFindCursor = nil
                unifiedMatchOccurrences = []
                unifiedCurrentMatchLineID = nil
                unifiedExternalMatchCount = 0
                unifiedExternalTotalMatchCount = 0
                unifiedExternalCurrentMatchIndex = 0
            case .local:
                findFindIndex = .empty
                findFindCursor = nil
                findMatchOccurrences = []
                findCurrentMatchLineID = nil
                externalMatchCount = 0
                externalTotalMatchCount = 0
                externalCurrentMatchIndex = 0
            }
        }

        guard !query.isEmpty else { clearState(); return }

        // (Re)build the index when the query changed (resetIndex) or it is empty/stale.
        let existingIndex = (kind == .unified) ? unifiedFindIndex : findFindIndex
        let index: TranscriptFindIndex
        if resetIndex || existingIndex.query != query {
            index = TranscriptFindIndex.build(blocks: coalescedBlocksForFindScan(), query: query)
            switch kind {
            case .unified: unifiedFindIndex = index
            case .local: findFindIndex = index
            }
        } else {
            index = existingIndex
        }

        // Whole-session total: navigation traverses ALL matches, so visible == total.
        let total = index.total
        switch kind {
        case .unified:
            unifiedExternalTotalMatchCount = total
            unifiedExternalMatchCount = total
        case .local:
            externalTotalMatchCount = total
            externalMatchCount = total
        }

        guard total > 0 else {
            // No matches anywhere: clear highlight + cursor but keep counts at 0.
            switch kind {
            case .unified:
                unifiedFindCursor = nil
                unifiedMatchOccurrences = []
                unifiedCurrentMatchLineID = nil
                unifiedExternalCurrentMatchIndex = 0
            case .local:
                findFindCursor = nil
                findMatchOccurrences = []
                findCurrentMatchLineID = nil
                externalCurrentMatchIndex = 0
            }
            return
        }

        // Advance the global cursor (wrap-aware).
        let currentCursor = (kind == .unified) ? unifiedFindCursor : findFindCursor
        let newCursor: Int?
        if resetIndex {
            newCursor = index.advance(from: nil, direction: direction)
        } else {
            newCursor = index.advance(from: currentCursor, direction: direction)
        }
        guard let cursor = newCursor, let location = index.location(at: cursor) else {
            clearState()
            return
        }

        // Load the window containing the target block (older OR newer as needed).
        ensureBlockLoaded(location.globalBlockIndex)

        // Map the global location to a loaded line + range.
        let target = Self.windowedMatchTarget(for: location, query: query, lines: lines)

        switch kind {
        case .unified:
            unifiedFindCursor = cursor
            unifiedExternalCurrentMatchIndex = cursor
            if let target {
                unifiedCurrentMatchLineID = target.lineID
                unifiedMatchOccurrences = currentWindowOccurrences(kind: .unified, query: query)
            } else {
                unifiedCurrentMatchLineID = nil
                unifiedMatchOccurrences = []
            }
        case .local:
            findFindCursor = cursor
            externalCurrentMatchIndex = cursor
            if let target {
                findCurrentMatchLineID = target.lineID
                findMatchOccurrences = currentWindowOccurrences(kind: .local, query: query)
            } else {
                findCurrentMatchLineID = nil
                findMatchOccurrences = []
            }
        }
    }

    /// Highlight occurrences for the CURRENTLY LOADED window only (the layout manager
    /// can only draw what is built). Counts/navigation come from the global index; this
    /// just paints every match inside the loaded window so the current match and its
    /// neighbors are highlighted.
    private func currentWindowOccurrences(kind: WindowedFindKind, query: String) -> [MatchOccurrence] {
        ensureSearchSnapshots()
        let snapshot = visibleSnapshot
        let ranges = SearchTextMatcher.matchRanges(in: snapshot.text, query: query)
        return occurrences(from: ranges, in: snapshot)
    }
```

- [ ] **Step 4: Branch `recomputeUnifiedMatches` to the windowed path**

In `recomputeUnifiedMatches(resetIndex:direction:preserveCurrentLine:)` (~1646), add an early branch at the very top of the method body (immediately after the function's opening brace, before `let query = ...`):

```swift
        if FeatureFlags.transcriptWindowedBuild {
            recomputeWindowedFind(kind: .unified,
                                  query: unifiedQuery,
                                  resetIndex: resetIndex,
                                  direction: direction)
            return
        }
```

- [ ] **Step 5: Branch `recomputeFindMatches` to the windowed path**

In `recomputeFindMatches(resetIndex:direction:preserveCurrentLine:)` (~1697), add the same early branch at the top of the method body:

```swift
        if FeatureFlags.transcriptWindowedBuild {
            recomputeWindowedFind(kind: .local,
                                  query: findQuery,
                                  resetIndex: resetIndex,
                                  direction: direction)
            return
        }
```

- [ ] **Step 6: Add the load-then-rescan fallback for synthetic-prefix blocks**

`windowedMatchTarget` can return nil when per-line rendered text diverges from block text (semantic prefixes). In that case, after `ensureBlockLoaded`, fall back to selecting the first loaded occurrence in that block by line. Replace the `let target = Self.windowedMatchTarget(...)` line in `recomputeWindowedFind` (Step 3) with:

```swift
        var target = Self.windowedMatchTarget(for: location, query: query, lines: lines)
        if target == nil {
            // Fallback: pick the first occurrence physically inside the target block in
            // the loaded window (handles rendered-prefix divergence).
            if let firstLine = lines.first(where: { $0.blockIndex == location.globalBlockIndex }),
               let ranges = Optional(SearchTextMatcher.matchRanges(in: firstLine.text, query: query)),
               let firstRange = ranges.first {
                target = WindowedMatchTarget(lineID: firstLine.id, occurrenceRangeInLine: firstRange)
            }
        }
```

- [ ] **Step 7: Verify it builds with the flag OFF (no regression)**

Run: `./scripts/xcode_test_stable.sh`
Expected: build succeeds; all existing tests pass (flag defaults false → legacy path unchanged).

- [ ] **Step 8: Commit**

```bash
git add AgentSessions/Views/SessionTerminalView.swift
git commit -m "feat(transcript): windowed Find navigation with whole-session counts + load-to-match

Tool: Claude Code
Model: claude-opus-4-8
Why: bidirectional Find/prev across the whole session under windowing, wrap-aware, off-window targets load their window"
```

---

## Task 4: Test the windowed navigation decision logic (off-window next/prev, wrap, counts)

The navigation in Task 3 mixes UI state with the Phase 3 windower, so test the **decision logic** as a pure function rather than driving the live view. Extract the "given index + current cursor + direction, which global block must be loaded and which cursor results" decision into a `static` helper and test it directly.

**Files:**
- Modify: `AgentSessions/Views/SessionTerminalView.swift` (extract `static func windowedFindStep(...)`)
- Test: `AgentSessionsTests/SessionTerminalFindWindowedTests.swift` (extend)

**Interfaces:**
- Produces:
  - `struct WindowedFindStep: Equatable { let cursor: Int; let blockToLoad: Int; let total: Int }`
  - `static func windowedFindStep(index: TranscriptFindIndex, currentCursor: Int?, resetIndex: Bool, direction: Int) -> WindowedFindStep?` — returns nil when `index.total == 0`; otherwise the resolved cursor (wrap applied), the global block to load, and the total. Task 3's `recomputeWindowedFind` is refactored to call this.

- [ ] **Step 1: Write the failing tests (extend the windowed test file)**

Append to `AgentSessionsTests/SessionTerminalFindWindowedTests.swift` (inside the class):

```swift
    private func indexFromOccurrences(_ occ: [(Int, Int)]) -> TranscriptFindIndex {
        let locs = occ.map { TranscriptFindIndex.Location(globalBlockIndex: $0.0, occurrenceOrdinalInBlock: $0.1) }
        return TranscriptFindIndex(locations: locs, query: "q")
    }

    func test_stepResetSelectsFirstMatchForward() {
        let index = indexFromOccurrences([(2, 0), (5, 0), (5, 1)])
        let step = SessionTerminalView.windowedFindStep(index: index, currentCursor: nil, resetIndex: true, direction: 1)
        XCTAssertEqual(step, .init(cursor: 0, blockToLoad: 2, total: 3))
    }

    func test_stepNextAdvancesToNextGlobalMatchPossiblyOffWindow() {
        let index = indexFromOccurrences([(2, 0), (50, 0)]) // 50 is off-window
        let step = SessionTerminalView.windowedFindStep(index: index, currentCursor: 0, resetIndex: false, direction: 1)
        XCTAssertEqual(step, .init(cursor: 1, blockToLoad: 50, total: 2))
    }

    func test_stepPrevLoadsOlderWindow() {
        let index = indexFromOccurrences([(2, 0), (50, 0)])
        let step = SessionTerminalView.windowedFindStep(index: index, currentCursor: 1, resetIndex: false, direction: -1)
        XCTAssertEqual(step, .init(cursor: 0, blockToLoad: 2, total: 2))
    }

    func test_stepWrapsForwardPastLastToFirst() {
        let index = indexFromOccurrences([(2, 0), (50, 0)])
        let step = SessionTerminalView.windowedFindStep(index: index, currentCursor: 1, resetIndex: false, direction: 1)
        XCTAssertEqual(step, .init(cursor: 0, blockToLoad: 2, total: 2)) // wrap to first
    }

    func test_stepWrapsBackwardPastFirstToLast() {
        let index = indexFromOccurrences([(2, 0), (50, 0)])
        let step = SessionTerminalView.windowedFindStep(index: index, currentCursor: 0, resetIndex: false, direction: -1)
        XCTAssertEqual(step, .init(cursor: 1, blockToLoad: 50, total: 2)) // wrap to last
    }

    func test_stepReturnsNilWhenNoMatches() {
        let index = TranscriptFindIndex.empty
        XCTAssertNil(SessionTerminalView.windowedFindStep(index: index, currentCursor: nil, resetIndex: true, direction: 1))
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `./scripts/xcode_test_stable.sh`
Expected: FAIL with "type 'SessionTerminalView' has no member 'windowedFindStep'".

- [ ] **Step 3: Add the `windowedFindStep` helper**

In `AgentSessions/Views/SessionTerminalView.swift`, immediately AFTER the `windowedMatchTarget(...)` helper added in Task 2, insert:

```swift
    /// Resolved decision for one windowed Find step: the new global cursor, the global
    /// block that must be loaded to show it, and the whole-session total. Nil when there
    /// are no matches. Pure: no UI/window side effects.
    struct WindowedFindStep: Equatable {
        let cursor: Int
        let blockToLoad: Int
        let total: Int
    }

    static func windowedFindStep(index: TranscriptFindIndex,
                                 currentCursor: Int?,
                                 resetIndex: Bool,
                                 direction: Int) -> WindowedFindStep? {
        guard index.total > 0 else { return nil }
        let cursor: Int?
        if resetIndex {
            cursor = index.advance(from: nil, direction: direction)
        } else {
            cursor = index.advance(from: currentCursor, direction: direction)
        }
        guard let c = cursor, let loc = index.location(at: c) else { return nil }
        return WindowedFindStep(cursor: c, blockToLoad: loc.globalBlockIndex, total: index.total)
    }
```

- [ ] **Step 4: Refactor `recomputeWindowedFind` to use `windowedFindStep`**

In `recomputeWindowedFind` (Task 3, Step 3), replace the block from `// Advance the global cursor (wrap-aware).` through the `guard let cursor = newCursor, let location = index.location(at: cursor) else { clearState(); return }` with:

```swift
        // Resolve the next step (cursor + block to load) via the pure decision helper.
        let currentCursor = (kind == .unified) ? unifiedFindCursor : findFindCursor
        guard let step = Self.windowedFindStep(index: index,
                                               currentCursor: currentCursor,
                                               resetIndex: resetIndex,
                                               direction: direction),
              let location = index.location(at: step.cursor) else {
            clearState()
            return
        }
        let cursor = step.cursor
```

(The `ensureBlockLoaded(location.globalBlockIndex)` call and everything after it remain unchanged.)

- [ ] **Step 5: Run to verify pass**

Run: `./scripts/xcode_test_stable.sh`
Expected: PASS for all `SessionTerminalFindWindowedTests`, including the new `windowedFindStep` cases.

- [ ] **Step 6: Commit**

```bash
git add AgentSessions/Views/SessionTerminalView.swift AgentSessionsTests/SessionTerminalFindWindowedTests.swift
git commit -m "test(transcript): cover windowed Find step decisions (off-window next/prev, wrap, counts)

Tool: Claude Code
Model: claude-opus-4-8
Why: lock bidirectional load-to-match + wrap semantics as a pure, testable decision"
```

---

## Task 5: Align the model scan with rendered per-line text (ordinal parity)

`TranscriptFindIndex` scans raw block text; the window builds **rendered** per-line text (semantic prefixes, "Code"/"Diff" headers, code/diff line-number gutters). For blocks with these transforms, occurrence ordinals can diverge, which is why Task 2/3 carry a fallback. This task makes the index scan the **same rendered text** the window produces, so ordinals align exactly and the fallback is rarely needed. We reuse `TerminalBuilder.buildLines(from:source:)` per block (cheap text build, no attributed string / TextKit) to derive the rendered line text for the scan.

**Files:**
- Modify: `AgentSessions/Services/TranscriptFindIndex.swift`
- Test: `AgentSessionsTests/TranscriptFindIndexTests.swift` (extend)

**Interfaces:**
- Consumes: `TerminalBuilder.buildLines(from:source:enableReviewCards:)` → `[TerminalLine]`; `SessionSource`.
- Produces: a new `build` overload that scans rendered text:
  - `static func build(blocks: [SessionTranscriptBuilder.LogicalBlock], source: SessionSource, query: String) -> TranscriptFindIndex` — for each block, build its `TerminalLine`s, concatenate their rendered text with `\n`, scan that, and emit ordinals over the rendered concatenation. `blockIndex` on the produced lines is local-to-the-single-block build, so map by position: the i-th block in `blocks` is `globalBlockIndex = i`.

- [ ] **Step 1: Write the failing test (extend)**

Append to `AgentSessionsTests/TranscriptFindIndexTests.swift` (inside the class):

```swift
    func test_renderedBuildCountsMatchesInRenderedText() {
        // A fenced code block renders a synthetic "Code" header line; ensure scanning
        // rendered text counts occurrences in the rendered output, in document order.
        let blocks = [
            block("```\nlet alpha = alpha\n```", kind: .assistant),
            block("alpha", kind: .user)
        ]
        let index = TranscriptFindIndex.build(blocks: blocks, source: .codex, query: "alpha")
        // Two occurrences in the code body block + one in the user block.
        XCTAssertEqual(index.total, 3)
        XCTAssertEqual(index.locations.map { $0.globalBlockIndex }, [0, 0, 1])
    }

    func test_renderedBuildEmptyQuery() {
        let index = TranscriptFindIndex.build(blocks: [block("alpha")], source: .codex, query: "  ")
        XCTAssertEqual(index.total, 0)
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `./scripts/xcode_test_stable.sh`
Expected: FAIL with "extra argument 'source' in call" / no matching `build` overload.

- [ ] **Step 3: Add the rendered-text build overload**

In `AgentSessions/Services/TranscriptFindIndex.swift`, add this method inside `struct TranscriptFindIndex`, after the existing `build(blocks:query:)`:

```swift
    /// Build the index by scanning the SAME rendered per-line text the windowed view
    /// produces, so occurrence ordinals align exactly with `windowedMatchTarget`.
    ///
    /// For each block we run `TerminalBuilder.buildLines` on a single-block array (a cheap
    /// text-only build — no attributed string / TextKit), concatenate the rendered line
    /// text with newlines, and scan that. The block's global index is its position in
    /// `blocks`.
    static func build(blocks: [SessionTranscriptBuilder.LogicalBlock],
                      source: SessionSource,
                      query: String) -> TranscriptFindIndex {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return empty }

        var locations: [Location] = []
        for (blockIndex, block) in blocks.enumerated() {
            let renderedLines = TerminalBuilder.buildLines(from: [block], source: source)
            guard !renderedLines.isEmpty else { continue }
            let renderedText = renderedLines.map(\.text).joined(separator: "\n")
            let ranges = SearchTextMatcher.matchRanges(in: renderedText, query: trimmed)
            guard !ranges.isEmpty else { continue }
            for ordinal in 0..<ranges.count {
                locations.append(Location(globalBlockIndex: blockIndex,
                                          occurrenceOrdinalInBlock: ordinal))
            }
        }
        return TranscriptFindIndex(locations: locations, query: trimmed)
    }
```

- [ ] **Step 4: Switch `recomputeWindowedFind` to the rendered-text overload**

In `AgentSessions/Views/SessionTerminalView.swift`, in `recomputeWindowedFind` (Task 3 Step 3), change the index build call from:

```swift
            index = TranscriptFindIndex.build(blocks: coalescedBlocksForFindScan(), query: query)
```

to:

```swift
            index = TranscriptFindIndex.build(blocks: coalescedBlocksForFindScan(),
                                              source: session.source,
                                              query: query)
```

- [ ] **Step 5: Run to verify pass**

Run: `./scripts/xcode_test_stable.sh`
Expected: PASS for all `TranscriptFindIndexTests` (including the rendered-build cases) and no regressions elsewhere.

- [ ] **Step 6: Commit**

```bash
git add AgentSessions/Services/TranscriptFindIndex.swift AgentSessions/Views/SessionTerminalView.swift AgentSessionsTests/TranscriptFindIndexTests.swift
git commit -m "feat(transcript): scan rendered per-line text in TranscriptFindIndex for ordinal parity

Tool: Claude Code
Model: claude-opus-4-8
Why: align Find index occurrences with the windowed view's rendered lines so navigation lands exactly"
```

---

## Task 6: Jump-to-range / deep-link / first-prompt load the containing window then scroll

Deep-link and jump paths (`jumpToEventID`, `jumpToUserPromptIndex`, `jumpToFirstPrompt`, image navigation) target a global line/event id. Under windowing the target may be off-window, so `lineRanges[target]` is nil and the scroll no-ops. Behind the flag, these must first load the window containing the target block, then scroll.

**Files:**
- Modify: `AgentSessions/Views/SessionTerminalView.swift`
- Test: `AgentSessionsTests/SessionTerminalFindWindowedTests.swift` (extend — pure block-resolution helper)

**Interfaces:**
- Consumes: Phase 3 `ensureBlockLoaded(_:)`; the canonical blocks via `coalescedBlocksForFindScan()`; existing `eventIDToUserLineID`, `userLineIndices`.
- Produces:
  - `static func globalBlockIndex(forEventID eventID: String, in blocks: [SessionTranscriptBuilder.LogicalBlock]) -> Int?` — first block whose `eventID == eventID`.
  - Flag-gated window-load before scroll in `jumpToEventID`, `jumpToUserPromptIndex`, `jumpToFirstPrompt`.

- [ ] **Step 1: Write the failing test (extend)**

Append to `AgentSessionsTests/SessionTerminalFindWindowedTests.swift` (inside the class):

```swift
    private func blockWithEventID(_ eventID: String, _ text: String) -> SessionTranscriptBuilder.LogicalBlock {
        SessionTranscriptBuilder.LogicalBlock(kind: .user, text: text, timestamp: nil, messageID: nil,
                                              toolName: nil, isDelta: false, toolInput: nil,
                                              isErrorOutput: false, eventID: eventID, rawJSON: "")
    }

    func test_globalBlockIndexForEventIDFindsBlock() {
        let blocks = [blockWithEventID("a", "one"), blockWithEventID("b", "two"), blockWithEventID("c", "three")]
        XCTAssertEqual(SessionTerminalView.globalBlockIndex(forEventID: "b", in: blocks), 1)
    }

    func test_globalBlockIndexForEventIDReturnsNilWhenMissing() {
        let blocks = [blockWithEventID("a", "one")]
        XCTAssertNil(SessionTerminalView.globalBlockIndex(forEventID: "zzz", in: blocks))
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `./scripts/xcode_test_stable.sh`
Expected: FAIL with "type 'SessionTerminalView' has no member 'globalBlockIndex'".

- [ ] **Step 3: Add the block-resolution helper**

In `AgentSessions/Views/SessionTerminalView.swift`, after `windowedFindStep(...)` (Task 4), insert:

```swift
    /// First coalesced block whose `eventID` equals `eventID`, by global index. Used to
    /// load the containing window before a deep-link/jump scroll under windowing.
    static func globalBlockIndex(forEventID eventID: String,
                                 in blocks: [SessionTranscriptBuilder.LogicalBlock]) -> Int? {
        blocks.firstIndex { $0.eventID == eventID }
    }
```

- [ ] **Step 4: Load the window before scrolling in `jumpToEventID`**

In `jumpToEventID(_:)` (~1888), replace the body with a flag-gated window load:

```swift
    private func jumpToEventID(_ eventID: String) -> Bool {
        if FeatureFlags.transcriptWindowedBuild,
           eventIDToUserLineID[eventID] == nil,
           let blockIndex = Self.globalBlockIndex(forEventID: eventID, in: coalescedBlocksForFindScan()) {
            ensureBlockLoaded(blockIndex)
        }
        guard let lineID = eventIDToUserLineID[eventID] else { return false }
        jumpToUserPrompt(lineID: lineID)
        imageHighlightLineID = lineID
        imageHighlightToken &+= 1
        return true
    }
```

> `ensureBlockLoaded` (Phase 3) rebuilds `lines`/`visibleLines` and recomputes the index maps (including `eventIDToUserLineID`) for the new window using global ids, so the second `eventIDToUserLineID[eventID]` lookup resolves once the window contains the block.

- [ ] **Step 5: Load the window before scrolling in `jumpToUserPromptIndex`**

In `jumpToUserPromptIndex(_:)` (~1879), replace the body with:

```swift
    private func jumpToUserPromptIndex(_ index: Int) -> Bool {
        if FeatureFlags.transcriptWindowedBuild,
           !(index >= 0 && index < userLineIndices.count),
           let blocks = Optional(coalescedBlocksForFindScan()) {
            // userLineIndices is window-local; locate the nth user block globally and load it.
            let userBlockGlobalIndices = blocks.enumerated().filter { $0.element.kind == .user }.map { $0.offset }
            if index >= 0, index < userBlockGlobalIndices.count {
                ensureBlockLoaded(userBlockGlobalIndices[index])
            }
        }
        guard index >= 0, index < userLineIndices.count else { return false }
        let lineID = userLineIndices[index]
        jumpToUserPrompt(lineID: lineID)
        imageHighlightLineID = lineID
        imageHighlightToken &+= 1
        return true
    }
```

> Note: `userLineIndices` under windowing holds only the loaded window's user line ids, so its `index` no longer maps 1:1 to the nth global user prompt. The block-level resolution above loads the correct global window first; after `ensureBlockLoaded` rebuilds `userLineIndices` for the new window, the caller path that set `pendingUserPromptIndex` (see `rebuildLines`) retries. If `userLineIndices` still does not contain the index after loading (because the window indexes differently), the function returns false and the existing `pendingUserPromptIndex` retry in `rebuildLines` (~835) re-runs it after the rebuild settles.

- [ ] **Step 6: Load the window before scrolling in `jumpToFirstPrompt`**

In `jumpToFirstPrompt()` (~1859), replace the body with:

```swift
    private func jumpToFirstPrompt() {
        if FeatureFlags.transcriptWindowedBuild,
           userPromptLineID(for: .firstUserPrompt, skipAgentsPreamble: skipAgentsPreambleEnabled()) == nil {
            // First user prompt is off-window: load the first user block's window.
            let blocks = coalescedBlocksForFindScan()
            if let firstUserBlock = blocks.firstIndex(where: { $0.kind == .user }) {
                ensureBlockLoaded(firstUserBlock)
            }
        }
        guard let lineID = userPromptLineID(for: .firstUserPrompt, skipAgentsPreamble: skipAgentsPreambleEnabled()) else { return }
        jumpToUserPrompt(lineID: lineID, alignTop: true)
    }
```

- [ ] **Step 7: Run to verify pass**

Run: `./scripts/xcode_test_stable.sh`
Expected: PASS for the new `globalBlockIndex` tests; no regressions (flag-off path unchanged).

- [ ] **Step 8: Commit**

```bash
git add AgentSessions/Views/SessionTerminalView.swift AgentSessionsTests/SessionTerminalFindWindowedTests.swift
git commit -m "feat(transcript): jump-to-range/deep-link load the containing window before scrolling

Tool: Claude Code
Model: claude-opus-4-8
Why: under windowing the target line may be off-window; load its block window then scroll"
```

---

## Task 7: Refresh the global cursor's loaded highlight after a window load

When `ensureBlockLoaded` brings new lines into the window, the existing highlight machinery (`updateLayoutManagerUnifiedFind` / `updateLayoutManagerLocalFind`, driven from `applyContent`/`updateNSView`) only paints occurrences in `unifiedMatchOccurrences` / `findMatchOccurrences`. Task 3 sets those to `currentWindowOccurrences(...)` for the loaded window, but that snapshot is computed BEFORE the new window's lines settle into `visibleSnapshot`. This task makes the occurrence highlight recompute against the freshly loaded window, and ensures the current-match line is scrolled into view via the existing token path.

**Files:**
- Modify: `AgentSessions/Views/SessionTerminalView.swift`

**Interfaces:**
- Consumes: `refreshSearchSnapshotsIfNeeded()`, `ensureSearchSnapshots()`, `unifiedFindToken`/`findToken` auto-scroll path, `scrollTargetLineID`/`scrollTargetToken`.
- Produces: post-load highlight + scroll for the current match.

- [ ] **Step 1: Refresh snapshots after the window load inside `recomputeWindowedFind`**

In `recomputeWindowedFind` (Task 3 Step 3), immediately AFTER `ensureBlockLoaded(location.globalBlockIndex)` and BEFORE computing `target`, force the window's search snapshots to rebuild so `currentWindowOccurrences` sees the new lines:

```swift
        // The window may have grown/shifted; rebuild search snapshots for the new lines.
        refreshSearchSnapshotsIfNeeded()
```

- [ ] **Step 2: Drive a scroll to the current match line via the scroll-target token**

The Find auto-scroll path in `updateNSView` (~4226) scrolls `lineRanges[unifiedCurrentMatchLineID]` when `unifiedFindToken` changes. That token is bumped in `TranscriptPlainView`, not here. To guarantee the newly loaded current-match line is scrolled into view (especially when it was off-window), also set the explicit scroll target. At the END of `recomputeWindowedFind`, after the `switch kind` that assigns `unifiedCurrentMatchLineID` / `findCurrentMatchLineID`, add:

```swift
        let currentLineID = (kind == .unified) ? unifiedCurrentMatchLineID : findCurrentMatchLineID
        if let currentLineID {
            scrollTargetLineID = currentLineID
            scrollTargetToken &+= 1
        }
```

> This reuses the existing `scrollTargetToken` path (`updateNSView` ~4235) which calls `scrollRangeToTop`. It fires only when a current match exists and aligns the match near the top of the viewport, consistent with deep-link jumps.

- [ ] **Step 3: Verify build + existing tests**

Run: `./scripts/xcode_test_stable.sh`
Expected: build succeeds; all tests pass (flag-off path unchanged).

- [ ] **Step 4: Commit**

```bash
git add AgentSessions/Views/SessionTerminalView.swift
git commit -m "fix(transcript): refresh highlight + scroll to current match after windowed Find load

Tool: Claude Code
Model: claude-opus-4-8
Why: after loading a window for an off-window match, repaint occurrences and scroll the match into view"
```

---

## Task 8: Manual QA pass with the flag ON (no code change)

A non-code verification gate. Build the app normally and exercise the windowed Find/jump behaviors against large fixtures.

**Files:** none (manual).

- [ ] **Step 1: Temporarily enable the flag locally for QA**

Set `FeatureFlags.transcriptWindowedBuild = true` in `AgentSessions/Support/FeatureFlags.swift` (DO NOT COMMIT this change — revert before any commit). Build to the default DerivedData (no `-derivedDataPath`) so the bundle is launchable:

Run: `xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 2: Tell the user to run the app and verify**

Per repo QA policy, the user runs the app (Xcode or their normal flow). Provide this checklist for them to verify in a large (10k+ line) hydrated session in terminal mode:

1. ⌘F a term that occurs both near the top and near the bottom. Count shows `1/<total>` with the correct whole-session total (not just the loaded window's count).
2. Find Next repeatedly walks all matches top→bottom, loading older/newer windows as it crosses window boundaries, scrolling each match into view and highlighting it.
3. At the last match, Find Next wraps to the first match (window reloads to the top region).
4. Find Previous from the first match wraps to the last match (window reloads to the bottom region).
5. ⌥⌘F Unified Search behaves identically to ⌘F for counts/navigation/wrap.
6. Jump-to-first-prompt (and any deep-link/event jump) lands on the right prompt even when it was off-window.
7. Toggling role/semantic filters while a query is active keeps counts correct and navigation working.
8. No dropped characters / beachball while typing a query in a 100k+ line hydrated session.

- [ ] **Step 3: Revert the local flag change**

Restore `FeatureFlags.transcriptWindowedBuild = false` in `AgentSessions/Support/FeatureFlags.swift` (the default-on flip happens in Phase 4's final step per the spec, not in this plan unless the user requests it).

Run: `git diff --stat AgentSessions/Support/FeatureFlags.swift`
Expected: no output (file matches committed state).

---

## Self-Review

**Spec coverage** (design spec → Find/jump requirements):

- "model-level text scan over `Session.events` (cheap — text only, no line build) → accurate total match count + each match's global block/ordinal up front" → **Task 1** (`TranscriptFindIndex.build`, `total`, `Location{globalBlockIndex, occurrenceOrdinalInBlock}`), refined for rendered-text parity in **Task 5**.
- "Next/prev navigates that match list, loading older OR newer windows as needed to bring the target into the window, then highlights" → **Task 3** (`recomputeWindowedFind` + `ensureBlockLoaded`), decision logic in **Task 4** (`windowedFindStep`), highlight refresh in **Task 7**.
- "Wrap: next past last → first (and load that window); prev past first → last" → **Task 1** (`advance`), **Task 4** wrap tests.
- "accurate counts" / status `cur/total` → **Task 3** sets `externalMatchCount == externalTotalMatchCount == index.total`; `terminalStatus` then renders `cur/total`.
- "jump-to-range / deep-link / first-prompt load the containing window then scroll" → **Task 6** (`globalBlockIndex(forEventID:)`, flag-gated `ensureBlockLoaded` in `jumpToEventID`/`jumpToUserPromptIndex`/`jumpToFirstPrompt`).
- "Behind `FeatureFlags.transcriptWindowedBuild`; parity-gated before deleting the whole-session path" → **Task 0** + every modification branches on the flag; legacy snapshot path preserved.
- Tests required by the spec ("off-window next/prev, wrap, counts, deep-link jump") → **Task 1** (counts/wrap), **Task 2** (occurrence→line mapping), **Task 4** (off-window next/prev, wrap, counts), **Task 6** (deep-link block resolution).

**Out of scope (correctly deferred):** flipping the default + deleting the whole-session build (spec Phase 4 final step; do only on explicit request). Windowing the event parse (spec follow-on phase 5). Per-block view virtualization (spec Non-Goal).

**Placeholder scan:** No "TBD"/"handle edge cases"/"similar to Task N" — every code step shows complete code. The only narrative notes are the `>` callouts explaining Phase-3 dependencies and the rendered-text divergence rationale, each backed by concrete code.

**Type consistency:** `TranscriptFindIndex.Location{globalBlockIndex, occurrenceOrdinalInBlock}`, `WindowedMatchTarget{lineID, occurrenceRangeInLine}`, `WindowedFindStep{cursor, blockToLoad, total}`, `WindowedFindKind{unified, local}` are used identically across tasks. `advance(from:direction:)`, `location(at:)`, `windowedMatchTarget(for:query:lines:)`, `windowedFindStep(index:currentCursor:resetIndex:direction:)`, `globalBlockIndex(forEventID:in:)`, `coalescedBlocksForFindScan()`, `ensureBlockLoaded(_:)` (Phase 3), and `recomputeWindowedFind(kind:query:resetIndex:direction:)` keep consistent signatures wherever referenced.

**Phase-3 dependency note for the implementer:** This plan assumes `ensureBlockLoaded(_ globalBlockIndex: Int)` exists and synchronously updates `lines`/`visibleLines`/`lineRanges` and the index maps for the new window (per the spec's "Index maps … recomputed from the loaded slice using global ids"). If Phase 3 named it differently (e.g. `loadWindow(containing:)`), substitute that name at every call site in Tasks 3, 6, 7 — the contract (synchronous window extension preserving global ids) is what matters.

---

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-06-30-transcript-phase4-find-jump.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

**Which approach?**
