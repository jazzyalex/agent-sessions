# Transcript Phase 3 — Windowed Build on Open + Load-Older/Newer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When `FeatureFlags.transcriptWindowedBuild` is on, build `TerminalLine`s for only a boundary-safe *window* of whole coalesced blocks on open, render into the existing `NSTextView` unchanged, and load+prepend the previous window (preserving scroll anchor) on scroll-near-top — append-on-tail unchanged — with index maps recomputed from the loaded slice using stable global ids.

**Architecture:** Introduce a pure, testable `TranscriptWindow` value type that computes block-index window ranges over the pre-coalesced block array (the coalescer runs once to get cheap boundaries; we then slice *whole blocks*). `TerminalBuilder` gains a slice-aware entry point that builds lines for a contiguous block range while assigning **global, stable** line ids and `blockIndex`/`eventIndex` derived from the global block index (delivered by Phase 2). `SessionTerminalView` keeps a loaded-block window in `@State`, builds the last window on open, and prepends earlier windows on near-top with O(1) dedupe by global block id. The whole-session build path is retained byte-for-byte behind the flag-off branch; parity tests gate it.

**Tech Stack:** Swift 5 / SwiftUI / AppKit (`NSTextView`), XCTest. Build via `./scripts/xcode_test_stable.sh`.

## Global Constraints

- **Renderer is unchanged.** `buildAttributedString` + `applyContent` + `appendTailContent` are not modified. The window only changes *which* `TerminalLine`s populate `lines`/`visibleLines`. (Spec: "render into the existing NSTextView … attr-build + applyContent unchanged".)
- **Gate everything behind `FeatureFlags.transcriptWindowedBuild` (default `false`).** Flag off = today's whole-session build, unchanged. (Spec Phasing item 3; Risks "Big-bang regression".)
- **Window unit = whole coalesced blocks, boundary-safe.** Never cut inside a `canMerge` chain (same `messageID` / delta run / `toolName`). The coalescer already merges *across events* into whole `LogicalBlock`s ([SessionTranscriptBuilder.swift:448](../../../AgentSessions/Services/SessionTranscriptBuilder.swift)), so windowing over the *post-coalesce* `[LogicalBlock]` array by block index is inherently boundary-safe — never slice raw events. (Spec Components: "Window unit = whole coalesced blocks".)
- **Stable global identities come from Phase 2.** This plan ASSUMES Phase 2 already changed `TerminalBuilder.buildLines(from:source:...)` so that `TerminalLine.id` and `TerminalLine.blockIndex`/`eventIndex` derive from the **global** coalesced-block index passed in, not from a local `nextID`/`blocks.enumerated()` starting at 0. If that signature does not yet exist, **STOP and confirm Phase 2 landed** before starting Task 2. (Spec Components: "Stable global identities (model change, required)".)
- **Build each block exactly once; dedupe on prepend by global block id.** (Spec Risks: "Window boundary splits a merged block / dupes on prepend".)
- **Commits:** Conventional Commits with trailers `Tool: Claude Code` / `Model: claude-opus-4-8` / `Why: <reason>`. No co-author, no "Generated with" footer. **Do not commit or push unless the user explicitly asks** — the "Commit" step in each task stages the message for the user; only run it on their say-so. (CLAUDE.md.)
- **New Swift files** are added to the Xcode project via:
  `LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 ./scripts/xcode_add_file.rb AgentSessions.xcodeproj <TARGET> <path> <group>`
  App-target files use target `AgentSessions`; test files use target `AgentSessionsTests`.
- **Tests** run via `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/<ClassName>`.

---

## Phase 2 Interface (assumed delivered — referenced, not built here)

This plan depends on these Phase 2 outputs. If the real Phase 2 names differ, adapt callsites in Tasks 2–7 to match — the *shapes* below are what Phase 3 needs:

- `TerminalBuilder.buildLines(from blocks: [SessionTranscriptBuilder.LogicalBlock], source: SessionSource, enableReviewCards: Bool) -> [TerminalLine]` already assigns **global** ids: `TerminalLine.id` is derived from `(globalBlockIndex, lineOrdinalWithinBlock)` and is stable regardless of where the slice starts; `TerminalLine.blockIndex` and `TerminalLine.eventIndex` carry the **global** coalesced-block index. Building over the same global blocks twice yields identical ids.
- `LogicalBlock.eventID` (already exists, [SessionTranscriptBuilder.swift:300](../../../AgentSessions/Services/SessionTranscriptBuilder.swift)) uniquely identifies the block's originating event and is used as the **global block id** for dedupe.

> Phase 3 does **not** re-derive global ids; it only chooses *which contiguous global block range* to build and stitches the resulting line arrays. If Phase 2 used a different global-id scheme, only the `globalBlockIndex` references below change.

---

## File Structure

| File | Responsibility | New/Modified |
|---|---|---|
| `AgentSessions/Services/TranscriptWindow.swift` | Pure value type: given total block count + block kinds, compute the boundary-safe block-index range for the last window, the previous (older) window, and the next (newer) window. Window-size policy lives here. | **Create** |
| `AgentSessions/Services/TerminalModels.swift` | Add `TerminalBuilder.buildLines(from blocks:source:enableReviewCards:blockRange:)` slice entry point that builds lines for a contiguous global block range while preserving global ids. | Modify |
| `AgentSessions/Support/FeatureFlags.swift` | Add `transcriptWindowedBuild` flag (default `false`) + `transcriptWindowBlockTarget`. | Modify |
| `AgentSessions/Views/SessionTerminalView.swift` | Hold the loaded-block window (`@State`); build last window on open when flag on; recompute `RebuildResult` over the slice; `loadOlder()` prepend + dedupe + scroll-anchor restore; near-top trigger; keep whole-session path on flag-off. | Modify |
| `AgentSessionsTests/TranscriptWindowTests.swift` | Unit tests for window math + boundary safety. | **Create** |
| `AgentSessionsTests/TranscriptWindowedBuildTests.swift` | Parity vs whole-session build over a full window; global-id stability across prepend; delta/tool stream crossing a window boundary. | **Create** |

---

## Task 1: Feature flag + window-size policy constants

**Files:**
- Modify: `AgentSessions/Support/FeatureFlags.swift:54` (before the closing `}`)

**Interfaces:**
- Produces: `FeatureFlags.transcriptWindowedBuild: Bool` (default `false`); `FeatureFlags.transcriptWindowBlockTarget: Int` (target whole-block count per window); `FeatureFlags.transcriptWindowNearTopLoadOlder: Bool`.

- [ ] **Step 1: Add the flag + policy constants**

In `AgentSessions/Support/FeatureFlags.swift`, immediately before the final closing brace (currently line 54–55, after `allowCodexProbeDeletion`), insert:

```swift
    // Phase 3 — Windowed transcript build (terminal renderer).
    // When true, building the terminal transcript for an already-hydrated session
    // builds lines for only the last window of whole coalesced blocks; scrolling
    // near the top loads + prepends the previous window. Default off; parity-gated
    // against the whole-session build before flipping the default.
    static let transcriptWindowedBuild = false
    // Target number of WHOLE coalesced blocks per window. The window is expanded
    // outward to whole-block boundaries, so the realized line count varies with
    // block sizes; this bounds the block count, not the line count.
    static let transcriptWindowBlockTarget: Int = 400
    // When true, scrolling near the transcript top loads the previous (older) window.
    static let transcriptWindowNearTopLoadOlder = true
```

- [ ] **Step 2: Build to verify it compiles**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/TranscriptBuilderTests 2>&1 | tail -20`
Expected: build succeeds; existing `TranscriptBuilderTests` still PASS (no behavior change yet).

- [ ] **Step 3: Commit**

```bash
git add AgentSessions/Support/FeatureFlags.swift
git commit -m "feat(transcript): add transcriptWindowedBuild feature flag + window policy

Tool: Claude Code
Model: claude-opus-4-8
Why: Phase 3 windowed build must ship behind a default-off, parity-gated flag"
```

---

## Task 2: `TranscriptWindow` value type (window math, boundary-safe by block index)

The window is a contiguous range of **global block indices** into the post-coalesce `[LogicalBlock]` array. Because the array is already coalesced (whole `canMerge` chains are single blocks), *any* block-index range is boundary-safe. This type only decides *which* range, and centralizes the size policy.

**Files:**
- Create: `AgentSessions/Services/TranscriptWindow.swift`
- Create: `AgentSessionsTests/TranscriptWindowTests.swift`

**Interfaces:**
- Produces:
  - `struct TranscriptWindow: Equatable, Sendable { let lowerBlock: Int; let upperBlock: Int }` — half-open is avoided; `lowerBlock...upperBlock` is the **inclusive** range of global block indices currently loaded. Empty window encoded as `lowerBlock > upperBlock`.
  - `static func lastWindow(totalBlocks: Int, blockTarget: Int) -> TranscriptWindow` — the last `blockTarget` blocks (or all if fewer). For `totalBlocks == 0`, returns the empty window `TranscriptWindow(lowerBlock: 0, upperBlock: -1)`.
  - `func expandedOlder(blockTarget: Int) -> TranscriptWindow` — extends `lowerBlock` down by `blockTarget` (clamped at 0); `upperBlock` unchanged.
  - `func expandedNewer(totalBlocks: Int, blockTarget: Int) -> TranscriptWindow` — extends `upperBlock` up by `blockTarget` (clamped at `totalBlocks - 1`); `lowerBlock` unchanged.
  - `var isEmpty: Bool { lowerBlock > upperBlock }`
  - `var blockCount: Int { isEmpty ? 0 : upperBlock - lowerBlock + 1 }`
  - `var coversTop: Bool` — true when `lowerBlock <= 0` (nothing older to load).
  - `func coversBottom(totalBlocks: Int) -> Bool` — true when `upperBlock >= totalBlocks - 1`.

- [ ] **Step 1: Write the failing tests**

Create `AgentSessionsTests/TranscriptWindowTests.swift`:

```swift
import XCTest
@testable import AgentSessions

final class TranscriptWindowTests: XCTestCase {

    func testLastWindowFewerBlocksThanTargetCoversAll() {
        let w = TranscriptWindow.lastWindow(totalBlocks: 10, blockTarget: 400)
        XCTAssertEqual(w.lowerBlock, 0)
        XCTAssertEqual(w.upperBlock, 9)
        XCTAssertEqual(w.blockCount, 10)
        XCTAssertTrue(w.coversTop)
        XCTAssertTrue(w.coversBottom(totalBlocks: 10))
        XCTAssertFalse(w.isEmpty)
    }

    func testLastWindowMoreBlocksThanTargetTakesTail() {
        let w = TranscriptWindow.lastWindow(totalBlocks: 1000, blockTarget: 400)
        XCTAssertEqual(w.lowerBlock, 600)
        XCTAssertEqual(w.upperBlock, 999)
        XCTAssertEqual(w.blockCount, 400)
        XCTAssertFalse(w.coversTop)
        XCTAssertTrue(w.coversBottom(totalBlocks: 1000))
    }

    func testLastWindowZeroBlocksIsEmpty() {
        let w = TranscriptWindow.lastWindow(totalBlocks: 0, blockTarget: 400)
        XCTAssertTrue(w.isEmpty)
        XCTAssertEqual(w.blockCount, 0)
        XCTAssertTrue(w.coversTop)
        XCTAssertTrue(w.coversBottom(totalBlocks: 0))
    }

    func testExpandedOlderExtendsLowerClampedAtZero() {
        let w = TranscriptWindow.lastWindow(totalBlocks: 1000, blockTarget: 400) // 600...999
        let older = w.expandedOlder(blockTarget: 400)
        XCTAssertEqual(older.lowerBlock, 200)
        XCTAssertEqual(older.upperBlock, 999)
        let older2 = older.expandedOlder(blockTarget: 400)
        XCTAssertEqual(older2.lowerBlock, 0) // clamped, not -200
        XCTAssertTrue(older2.coversTop)
    }

    func testExpandedNewerExtendsUpperClampedAtTotal() {
        let w = TranscriptWindow(lowerBlock: 0, upperBlock: 399)
        let newer = w.expandedNewer(totalBlocks: 1000, blockTarget: 400)
        XCTAssertEqual(newer.lowerBlock, 0)
        XCTAssertEqual(newer.upperBlock, 799)
        let newerToEnd = newer.expandedNewer(totalBlocks: 1000, blockTarget: 400)
        XCTAssertEqual(newerToEnd.upperBlock, 999) // clamped at totalBlocks-1
        XCTAssertTrue(newerToEnd.coversBottom(totalBlocks: 1000))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/TranscriptWindowTests 2>&1 | tail -20`
Expected: FAIL — build error "cannot find 'TranscriptWindow' in scope".

- [ ] **Step 3: Create the type**

Create `AgentSessions/Services/TranscriptWindow.swift`:

```swift
import Foundation

/// A contiguous, inclusive range of **global** coalesced-block indices currently
/// loaded into the terminal transcript.
///
/// The block array fed to the window is already coalesced — every `canMerge`
/// chain (same `messageID` / delta run / tool stream) is a single `LogicalBlock`.
/// Therefore *any* block-index range is boundary-safe: a window can never cut
/// inside a merge chain. This type only decides which range to load and owns the
/// window-size policy; it never slices raw events.
struct TranscriptWindow: Equatable, Sendable {
    /// Lowest global block index in the window (inclusive).
    let lowerBlock: Int
    /// Highest global block index in the window (inclusive).
    let upperBlock: Int

    var isEmpty: Bool { lowerBlock > upperBlock }

    var blockCount: Int { isEmpty ? 0 : upperBlock - lowerBlock + 1 }

    /// True when there is nothing older to load (the window reaches block 0).
    var coversTop: Bool { lowerBlock <= 0 }

    /// True when there is nothing newer to load (the window reaches the last block).
    func coversBottom(totalBlocks: Int) -> Bool { upperBlock >= totalBlocks - 1 }

    /// The last `blockTarget` whole blocks (or all blocks if fewer).
    static func lastWindow(totalBlocks: Int, blockTarget: Int) -> TranscriptWindow {
        guard totalBlocks > 0 else {
            return TranscriptWindow(lowerBlock: 0, upperBlock: -1)
        }
        let target = max(1, blockTarget)
        let lower = max(0, totalBlocks - target)
        return TranscriptWindow(lowerBlock: lower, upperBlock: totalBlocks - 1)
    }

    /// Extend the window downward (older) by `blockTarget` whole blocks, clamped at 0.
    func expandedOlder(blockTarget: Int) -> TranscriptWindow {
        guard !isEmpty else { return self }
        let target = max(1, blockTarget)
        return TranscriptWindow(lowerBlock: max(0, lowerBlock - target), upperBlock: upperBlock)
    }

    /// Extend the window upward (newer) by `blockTarget` whole blocks, clamped at
    /// `totalBlocks - 1`.
    func expandedNewer(totalBlocks: Int, blockTarget: Int) -> TranscriptWindow {
        guard !isEmpty, totalBlocks > 0 else { return self }
        let target = max(1, blockTarget)
        return TranscriptWindow(lowerBlock: lowerBlock,
                                upperBlock: min(totalBlocks - 1, upperBlock + target))
    }
}
```

- [ ] **Step 4: Add the new files to the Xcode project**

Run:
```bash
LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 ./scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessions AgentSessions/Services/TranscriptWindow.swift AgentSessions/Services
LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 ./scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessionsTests AgentSessionsTests/TranscriptWindowTests.swift AgentSessionsTests
```
Expected: each prints a confirmation and no error; `git status` shows `AgentSessions.xcodeproj/project.pbxproj` modified.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/TranscriptWindowTests 2>&1 | tail -20`
Expected: PASS — all 5 tests green.

- [ ] **Step 6: Commit**

```bash
git add AgentSessions/Services/TranscriptWindow.swift AgentSessionsTests/TranscriptWindowTests.swift AgentSessions.xcodeproj/project.pbxproj
git commit -m "feat(transcript): add TranscriptWindow value type for boundary-safe block windowing

Tool: Claude Code
Model: claude-opus-4-8
Why: Phase 3 needs a pure, tested unit for window-size policy and older/newer extension"
```

---

## Task 3: Slice-aware `TerminalBuilder.buildLines` (build a contiguous block range, global ids preserved)

`TerminalBuilder.buildLines(from:source:enableReviewCards:)` already builds over a `[LogicalBlock]` and (per Phase 2) assigns **global** ids. The cheapest, lowest-risk way to build a window is: coalesce once to get the full `[LogicalBlock]` array (cheap — text-append), then call the *existing* Phase-2 builder on the **sub-slice** `Array(blocks[range])`. For the ids to stay global and stable, the builder must know each block's **global** index. We add an overload that takes the full block array plus the range to build, so the global index is `range.lowerBound + localOffset`.

**Files:**
- Modify: `AgentSessions/Services/TerminalModels.swift:75-150` (add an overload alongside `buildLines(from:source:enableReviewCards:)`)
- Test: `AgentSessionsTests/TranscriptWindowedBuildTests.swift` (created here)

**Interfaces:**
- Consumes (from Phase 2): the existing `buildLines(from:source:enableReviewCards:)` global-id semantics.
- Produces: `TerminalBuilder.buildLines(from allBlocks: [SessionTranscriptBuilder.LogicalBlock], blockRange: ClosedRange<Int>, source: SessionSource, enableReviewCards: Bool) -> [TerminalLine]` — builds lines for `allBlocks[blockRange]` only, with each line's `id`/`blockIndex`/`eventIndex` identical to what the whole-array build would produce for those same blocks.

> **Implementation note for the engineer:** Phase 2 already made the per-block id derive from the block's global index. The simplest correct implementation passes the **global starting index** into the existing builder. If Phase 2's `buildLines(from:source:enableReviewCards:)` does *not* accept a starting global index, add a `globalBlockOffset: Int = 0` parameter to it (defaulting to 0 keeps every existing callsite unchanged) and use `blockIndex + globalBlockOffset` everywhere `blockIndex` currently feeds an id, `blockIndex`, `eventIndex`, or `decorationGroupID`. The overload below assumes that parameter exists.

- [ ] **Step 1: Write the failing parity test**

Create `AgentSessionsTests/TranscriptWindowedBuildTests.swift`:

```swift
import XCTest
@testable import AgentSessions

final class TranscriptWindowedBuildTests: XCTestCase {

    // MARK: - Fixtures

    private func userEvent(_ id: String, _ text: String) -> SessionEvent {
        SessionEvent(id: id, timestamp: nil, kind: .user, role: "user", text: text,
                     toolName: nil, toolInput: nil, toolOutput: nil,
                     messageID: "m-\(id)", parentID: nil, isDelta: false, rawJSON: "{}")
    }

    private func assistantDelta(_ id: String, _ text: String, messageID: String) -> SessionEvent {
        SessionEvent(id: id, timestamp: nil, kind: .assistant, role: "assistant", text: text,
                     toolName: nil, toolInput: nil, toolOutput: nil,
                     messageID: messageID, parentID: nil, isDelta: true, rawJSON: "{}")
    }

    /// Alternating user prompt + 3-chunk assistant delta stream, repeated `pairs` times.
    private func deltaSession(pairs: Int) -> Session {
        var events: [SessionEvent] = []
        for p in 0..<pairs {
            events.append(userEvent("u-\(p)", "Question number \(p)\nwith two lines"))
            let mid = "asst-\(p)"
            events.append(assistantDelta("a-\(p)-0", "Answer \(p) chunk-0\n", messageID: mid))
            events.append(assistantDelta("a-\(p)-1", "chunk-1\n", messageID: mid))
            events.append(assistantDelta("a-\(p)-2", "chunk-2", messageID: mid))
        }
        return Session(id: "s-delta", source: .codex, startTime: nil, endTime: nil,
                       model: "test", filePath: "/tmp/delta.jsonl", fileSizeBytes: nil,
                       eventCount: events.count, events: events)
    }

    // MARK: - Parity: a full window equals the matching slice of the whole-session build

    func testWindowedBuildMatchesWholeSessionBuildForFullWindow() {
        let session = deltaSession(pairs: 50)
        let blocks = SessionTranscriptBuilder.coalescedBlocks(for: session, includeMeta: false)
        XCTAssertGreaterThan(blocks.count, 20)

        let whole = TerminalBuilder.buildLines(from: blocks, source: session.source, enableReviewCards: true)

        // Build a middle window of whole blocks.
        let range = 10...(blocks.count - 5)
        let windowed = TerminalBuilder.buildLines(from: blocks, blockRange: range,
                                                  source: session.source, enableReviewCards: true)

        // Every windowed line must be byte-identical (id, text, role, blockIndex,
        // eventIndex, decorationGroupID, semanticKind) to the same global line in
        // the whole-session build.
        let wholeByID = Dictionary(uniqueKeysWithValues: whole.map { ($0.id, $0) })
        XCTAssertFalse(windowed.isEmpty)
        for line in windowed {
            guard let match = wholeByID[line.id] else {
                XCTFail("windowed line id \(line.id) not present in whole build")
                continue
            }
            XCTAssertEqual(line.text, match.text)
            XCTAssertEqual(line.role, match.role)
            XCTAssertEqual(line.blockIndex, match.blockIndex)
            XCTAssertEqual(line.eventIndex, match.eventIndex)
            XCTAssertEqual(line.decorationGroupID, match.decorationGroupID)
            XCTAssertEqual(line.semanticKind, match.semanticKind)
        }
    }

    // MARK: - Global id stability across prepend (older window built separately)

    func testOlderWindowProducesGloballyDistinctNonOverlappingLineIDs() {
        let session = deltaSession(pairs: 50)
        let blocks = SessionTranscriptBuilder.coalescedBlocks(for: session, includeMeta: false)

        let tail = TranscriptWindow.lastWindow(totalBlocks: blocks.count, blockTarget: 8)
        let older = tail.expandedOlder(blockTarget: 8)
        // The "newly revealed" older slice is older.lowerBlock ..< tail.lowerBlock.
        let olderOnlyRange = older.lowerBlock...(tail.lowerBlock - 1)

        let tailLines = TerminalBuilder.buildLines(from: blocks, blockRange: tail.lowerBlock...tail.upperBlock,
                                                   source: session.source, enableReviewCards: true)
        let olderLines = TerminalBuilder.buildLines(from: blocks, blockRange: olderOnlyRange,
                                                    source: session.source, enableReviewCards: true)

        let tailIDs = Set(tailLines.map(\.id))
        let olderIDs = Set(olderLines.map(\.id))
        // Prepend dedupe relies on disjoint ids between the older slice and the tail.
        XCTAssertTrue(tailIDs.isDisjoint(with: olderIDs),
                      "older + tail windows must not share line ids (prepend would dupe)")
        // And concatenation equals the whole-window build for lowerOlder...tailUpper.
        let combined = TerminalBuilder.buildLines(from: blocks,
                                                  blockRange: older.lowerBlock...tail.upperBlock,
                                                  source: session.source, enableReviewCards: true)
        XCTAssertEqual(olderLines.map(\.id) + tailLines.map(\.id), combined.map(\.id))
    }

    // MARK: - Delta/tool stream is one whole block; window never splits it

    func testAssistantDeltaStreamIsSingleBlockSoWindowCannotSplitIt() {
        let session = deltaSession(pairs: 3)
        let blocks = SessionTranscriptBuilder.coalescedBlocks(for: session, includeMeta: false)
        // Each pair = 1 user block + 1 coalesced assistant block (3 deltas merged).
        XCTAssertEqual(blocks.count, 6)
        let assistantBlocks = blocks.filter { $0.kind == .assistant }
        XCTAssertEqual(assistantBlocks.count, 3)
        // The merged assistant text contains all three chunks — proves coalescing
        // happened, so any block-index window keeps the whole stream intact.
        XCTAssertTrue(assistantBlocks[0].text.contains("chunk-0"))
        XCTAssertTrue(assistantBlocks[0].text.contains("chunk-1"))
        XCTAssertTrue(assistantBlocks[0].text.contains("chunk-2"))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/TranscriptWindowedBuildTests 2>&1 | tail -25`
Expected: FAIL — `testWindowedBuildMatchesWholeSessionBuildForFullWindow` and `testOlderWindowProducesGloballyDistinctNonOverlappingLineIDs` fail to compile: "extra argument 'blockRange'". (`testAssistantDeltaStreamIsSingleBlockSoWindowCannotSplitIt` may pass — it uses only existing APIs.)

- [ ] **Step 3: Add the slice-aware overload**

In `AgentSessions/Services/TerminalModels.swift`, immediately after the existing `buildLines(from blocks:source:enableReviewCards:)` (ends at line 150), add:

```swift
    /// Build lines for only a contiguous range of **global** coalesced blocks.
    ///
    /// `allBlocks` is the full, already-coalesced block array (so boundaries are
    /// merge-safe). `blockRange` is the inclusive range of global block indices to
    /// build. Each produced `TerminalLine`'s `id` / `blockIndex` / `eventIndex` /
    /// `decorationGroupID` are identical to what `buildLines(from: allBlocks, …)`
    /// would assign to the same blocks, because the builder is told the global
    /// starting index of the slice. This makes windows stitchable: an older window
    /// and the tail window produce disjoint, globally-consistent ids.
    static func buildLines(from allBlocks: [SessionTranscriptBuilder.LogicalBlock],
                           blockRange: ClosedRange<Int>,
                           source: SessionSource,
                           enableReviewCards: Bool = true) -> [TerminalLine] {
        guard !allBlocks.isEmpty else { return [] }
        let lower = max(0, blockRange.lowerBound)
        let upper = min(allBlocks.count - 1, blockRange.upperBound)
        guard lower <= upper else { return [] }
        let slice = Array(allBlocks[lower...upper])
        // `globalBlockOffset` (added in Phase 2) makes every per-block id derive
        // from `localIndex + lower`, i.e. the block's global index.
        return buildLines(from: slice,
                          source: source,
                          enableReviewCards: enableReviewCards,
                          globalBlockOffset: lower)
    }
```

> If Phase 2 did **not** add `globalBlockOffset` to `buildLines(from:source:enableReviewCards:)`, add it now: give the existing method signature `buildLines(from blocks:source:enableReviewCards:globalBlockOffset: Int = 0)`, and in its body replace every use of the loop's local `blockIndex` that feeds an id / `blockIndex` / `eventIndex` / `decorationGroupID` with `(blockIndex + globalBlockOffset)`. The `default = 0` keeps `buildRebuildResult` and all other callsites byte-identical. Apply the same change to `buildLinesAndBlocks(from:…)` only if a windowed callsite needs it (none in this plan — skip it).

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/TranscriptWindowedBuildTests 2>&1 | tail -25`
Expected: PASS — all 3 tests green, proving full-window parity, disjoint stitchable ids, and that the delta stream is one block.

- [ ] **Step 5: Add the test file to the project**

Run:
```bash
LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 ./scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessionsTests AgentSessionsTests/TranscriptWindowedBuildTests.swift AgentSessionsTests
```
Expected: confirmation, no error.

- [ ] **Step 6: Run the full existing builder suite to confirm no regression**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/TranscriptBuilderTests -only-testing:AgentSessionsTests/TerminalSemanticSegmentationTests -only-testing:AgentSessionsTests/TranscriptGoldenFixtureTests 2>&1 | tail -25`
Expected: PASS — the `globalBlockOffset = 0` default leaves whole-session output identical.

- [ ] **Step 7: Commit**

```bash
git add AgentSessions/Services/TerminalModels.swift AgentSessionsTests/TranscriptWindowedBuildTests.swift AgentSessions.xcodeproj/project.pbxproj
git commit -m "feat(transcript): add slice-aware TerminalBuilder.buildLines over a block range

Tool: Claude Code
Model: claude-opus-4-8
Why: windowed build needs to build a contiguous block range while keeping global, stitchable line ids"
```

---

## Task 4: Build the last window on open (flag-on), whole session on open (flag-off)

`buildRebuildResult` currently coalesces the whole session and builds all lines. We add a window-aware sibling that coalesces once (to get global block boundaries cheaply), chooses the last window via `TranscriptWindow.lastWindow`, builds only that block range, and recomputes the `RebuildResult` index maps over the slice using the **global** line ids. When the flag is off, the existing whole-session `buildRebuildResult` runs unchanged.

**Files:**
- Modify: `AgentSessions/Views/SessionTerminalView.swift` — add window `@State` (near :102), a `buildWindowedRebuildResult(...)` static (near :963), and route `rebuildLines` (:794) through it when the flag is on.

**Interfaces:**
- Consumes: `TranscriptWindow`, `TerminalBuilder.buildLines(from:blockRange:source:enableReviewCards:)`, the existing `RebuildResult` (:783).
- Produces:
  - `@State private var loadedWindow: TranscriptWindow` and `@State private var totalBlockCount: Int` on `SessionTerminalView`.
  - `static func buildWindowedRebuildResult(session:skipAgentsPreamble:enableReviewCards:window:) -> (RebuildResult, TranscriptWindow, Int)` returning the result for the loaded slice, the realized window, and the total block count.

- [ ] **Step 1: Add window state**

In `AgentSessions/Views/SessionTerminalView.swift`, after line 104 (`@State private var visibleLinesSignature: Int = 0`), add:

```swift
    // Phase 3 — windowed build state. `loadedWindow` is the inclusive global
    // block-index range currently materialized into `lines`; `totalBlockCount`
    // is the full coalesced block count for the session. Both are meaningful only
    // when FeatureFlags.transcriptWindowedBuild is on.
    @State private var loadedWindow = TranscriptWindow(lowerBlock: 0, upperBlock: -1)
    @State private var totalBlockCount: Int = 0
    @State private var isLoadingOlderWindow = false
```

- [ ] **Step 2: Extract the index-map computation so the slice path can reuse it**

The index-map logic inside `buildRebuildResult` (the body from line 968 `let startLineID` through the `return RebuildResult(...)` at 1074–1083) operates purely on `(blocks, built, session, skipAgentsPreamble)`. Extract it verbatim into a reusable static so both the whole-session and windowed paths share one implementation. In `SessionTerminalView.swift`, add immediately **after** the existing `buildRebuildResult` (after line 1084):

```swift
    /// Compute a `RebuildResult` from an already-built line array + its source blocks.
    /// Shared by the whole-session and windowed build paths. `blocks` and `built`
    /// must use the SAME global block indices (the windowed path passes the full
    /// block array and the slice's lines; index maps key off global ids in `built`).
    nonisolated private static func makeRebuildResult(session: Session,
                                                      blocks: [SessionTranscriptBuilder.LogicalBlock],
                                                      built: [TerminalLine],
                                                      skipAgentsPreamble: Bool) -> RebuildResult {
        let startLineID = conversationStartLineIDIfNeeded(session: session, lines: built, enabled: skipAgentsPreamble)
        let preambleUserBlockIndexes = computePreambleUserBlockIndexes(session: session, blocks: blocks)

        var firstLineForBlock: [Int: Int] = [:]
        var roleForBlock: [Int: TerminalLineRole] = [:]
        var toolGroupKeyForBlock: [Int: String] = [:]
        var lastToolGroupKey: String? = nil
        var lastToolName: String? = nil

        for line in built {
            guard let blockIndex = line.blockIndex else { continue }
            if firstLineForBlock[blockIndex] == nil {
                firstLineForBlock[blockIndex] = line.id
                roleForBlock[blockIndex] = line.role
            }
        }

        var eventIDToUserLineID: [String: Int] = [:]
        if !blocks.isEmpty {
            let userBlockIndices = blocks.enumerated().compactMap { $0.element.kind == .user ? $0.offset : nil }

            func nearestUserBlockIndex(for idx: Int) -> Int? {
                let prior = userBlockIndices.filter { $0 <= idx }
                if let preferred = prior.last(where: { !preambleUserBlockIndexes.contains($0) }) ?? prior.last {
                    return preferred
                }
                let after = userBlockIndices.filter { $0 > idx }
                if let preferred = after.first(where: { !preambleUserBlockIndexes.contains($0) }) ?? after.first {
                    return preferred
                }
                return nil
            }

            for (idx, block) in blocks.enumerated() {
                let targetUserBlock: Int?
                if block.kind == .user {
                    targetUserBlock = idx
                } else {
                    targetUserBlock = nearestUserBlockIndex(for: idx)
                }
                guard let targetUserBlock,
                      let lineID = firstLineForBlock[targetUserBlock] else { continue }
                eventIDToUserLineID[block.eventID] = lineID
            }

            for (idx, block) in blocks.enumerated() {
                guard block.kind == .toolCall || block.kind == .toolOut else {
                    lastToolGroupKey = nil
                    lastToolName = nil
                    continue
                }

                let normalizedName = block.toolName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                var derivedKey: String? = nil

                if let toolBlock = ToolTextBlockNormalizer.normalize(block: block, source: session.source),
                   let groupKey = toolBlock.groupKey,
                   !groupKey.isEmpty {
                    derivedKey = groupKey
                }

                if derivedKey == nil,
                   block.kind == .toolOut,
                   let last = lastToolGroupKey {
                    if let lastName = lastToolName, let normalizedName {
                        if lastName == normalizedName { derivedKey = last }
                    } else {
                        derivedKey = last
                    }
                }

                if derivedKey == nil {
                    derivedKey = "tool-block-\(idx)"
                }

                toolGroupKeyForBlock[idx] = derivedKey
                lastToolGroupKey = derivedKey
                if let normalizedName { lastToolName = normalizedName }
            }
        }

        func messageIDs(for roleMatch: (TerminalLineRole) -> Bool) -> [Int] {
            firstLineForBlock.compactMap { blockIndex, lineID in
                guard let role = roleForBlock[blockIndex], roleMatch(role) else { return nil }
                return lineID
            }
            .sorted()
        }

        func toolMessageIDs() -> [Int] {
            var grouped: [String: Int] = [:]
            for (blockIndex, lineID) in firstLineForBlock {
                guard let role = roleForBlock[blockIndex], role == .toolInput || role == .toolOutput else { continue }
                let key = toolGroupKeyForBlock[blockIndex] ?? "tool-block-\(blockIndex)"
                if let existing = grouped[key] {
                    grouped[key] = min(existing, lineID)
                } else {
                    grouped[key] = lineID
                }
            }
            return grouped.values.sorted()
        }

        return RebuildResult(
            lines: built,
            conversationStartLineID: startLineID,
            preambleUserBlockIndexes: preambleUserBlockIndexes,
            userLineIndices: messageIDs { $0 == .user },
            assistantLineIndices: messageIDs { $0 == .assistant },
            toolLineIndices: toolMessageIDs(),
            errorLineIndices: messageIDs { $0 == .error },
            eventIDToUserLineID: eventIDToUserLineID
        )
    }
```

Then replace the body of the existing `buildRebuildResult` (lines 966–1083) with a thin wrapper that calls the shared helper, so there is exactly one copy of the index-map logic:

```swift
    nonisolated private static func buildRebuildResult(session: Session,
                                                       skipAgentsPreamble: Bool,
                                                       enableReviewCards: Bool) -> RebuildResult {
        let blocks = SessionTranscriptBuilder.coalescedBlocks(for: session, includeMeta: false)
        let built = TerminalBuilder.buildLines(from: blocks, source: session.source, enableReviewCards: enableReviewCards)
        return makeRebuildResult(session: session, blocks: blocks, built: built, skipAgentsPreamble: skipAgentsPreamble)
    }
```

> **For the index maps over a window:** `makeRebuildResult` receives the **full** `blocks` array (for `eventIDToUserLineID` nearest-user resolution and tool grouping to be correct even when the nearest user block is off-window) but `built` contains only the windowed lines. `firstLineForBlock` is therefore populated only for in-window blocks; off-window `eventIDToUserLineID` entries are dropped because their `targetUserBlock` has no in-window first line — correct, since you cannot scroll-jump to a line that isn't loaded. (Spec: "Index maps recomputed from the loaded slice using global ids".)

- [ ] **Step 3: Add the windowed builder**

Immediately after the new `buildRebuildResult` wrapper, add:

```swift
    /// Build a `RebuildResult` for only the last (or supplied) window of whole blocks.
    /// Returns the result for the loaded slice, the realized window (clamped to the
    /// session), and the total coalesced block count.
    nonisolated private static func buildWindowedRebuildResult(session: Session,
                                                               skipAgentsPreamble: Bool,
                                                               enableReviewCards: Bool,
                                                               window requested: TranscriptWindow?) -> (RebuildResult, TranscriptWindow, Int) {
        let blocks = SessionTranscriptBuilder.coalescedBlocks(for: session, includeMeta: false)
        let total = blocks.count
        let window: TranscriptWindow = {
            if let requested, !requested.isEmpty {
                let lower = max(0, requested.lowerBlock)
                let upper = min(total - 1, requested.upperBlock)
                return TranscriptWindow(lowerBlock: lower, upperBlock: upper)
            }
            return TranscriptWindow.lastWindow(totalBlocks: total,
                                               blockTarget: FeatureFlags.transcriptWindowBlockTarget)
        }()

        guard !window.isEmpty else {
            return (makeRebuildResult(session: session, blocks: blocks, built: [], skipAgentsPreamble: skipAgentsPreamble),
                    window, total)
        }

        let built = TerminalBuilder.buildLines(from: blocks,
                                               blockRange: window.lowerBlock...window.upperBlock,
                                               source: session.source,
                                               enableReviewCards: enableReviewCards)
        let result = makeRebuildResult(session: session, blocks: blocks, built: built, skipAgentsPreamble: skipAgentsPreamble)
        return (result, window, total)
    }
```

- [ ] **Step 4: Route `rebuildLines` through the windowed path on the flag**

Replace the body of `rebuildLines` (lines 794–892). The change: when the flag is on, call `buildWindowedRebuildResult` with the current `loadedWindow` (or `nil` to mean "last window" on a fresh build), and update `loadedWindow`/`totalBlockCount`. Keep the entire existing apply/scroll/search-reset block. The flag-off branch is byte-identical to today.

```swift
    private func rebuildLines(priority: TaskPriority, debounceNanoseconds: UInt64 = 0) {
        rebuildTask?.cancel()

        let sessionSnapshot = session
        let skipAgentsPreamble = skipAgentsPreambleEnabled()
        let reviewCardsEnabled = transcriptReviewCardsEnabled
        let windowed = FeatureFlags.transcriptWindowedBuild
        // A fresh rebuild (session change / filter change) always starts from the
        // last window; an in-place refresh keeps the current window if non-empty.
        let requestedWindow: TranscriptWindow? = (windowed && !loadedWindow.isEmpty) ? loadedWindow : nil

        rebuildTask = Task.detached(priority: priority) { [sessionSnapshot, skipAgentsPreamble, reviewCardsEnabled, debounceNanoseconds, windowed, requestedWindow] in
            if debounceNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: debounceNanoseconds)
            }
            guard !Task.isCancelled else { return }

            let result: RebuildResult
            let realizedWindow: TranscriptWindow
            let realizedTotal: Int
            if windowed {
                let (r, w, t) = Self.buildWindowedRebuildResult(session: sessionSnapshot,
                                                                skipAgentsPreamble: skipAgentsPreamble,
                                                                enableReviewCards: reviewCardsEnabled,
                                                                window: requestedWindow)
                result = r
                realizedWindow = w
                realizedTotal = t
            } else {
                result = Self.buildRebuildResult(session: sessionSnapshot,
                                                 skipAgentsPreamble: skipAgentsPreamble,
                                                 enableReviewCards: reviewCardsEnabled)
                realizedWindow = TranscriptWindow(lowerBlock: 0, upperBlock: -1)
                realizedTotal = 0
            }
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard !Task.isCancelled else { return }

                if windowed {
                    loadedWindow = realizedWindow
                    totalBlockCount = realizedTotal
                }

                let priorLines = lines
                let appendOnlyUpdate: Bool = {
                    if case .append = Self.tailPatchStrategy(previous: priorLines, current: result.lines) {
                        return true
                    }
                    return false
                }()

                lines = result.lines
                visibleLines = applyLineFilters(result.lines)
                visibleLinesSignature = Self.stableLineSignature(for: visibleLines)
                refreshSearchSnapshotsIfNeeded()
                conversationStartLineID = result.conversationStartLineID
                preambleUserBlockIndexes = result.preambleUserBlockIndexes
                userLineIndices = result.userLineIndices
                assistantLineIndices = result.assistantLineIndices
                toolLineIndices = result.toolLineIndices
                errorLineIndices = result.errorLineIndices
                eventIDToUserLineID = result.eventIDToUserLineID

                if let pendingIndex = pendingUserPromptIndex, jumpToUserPromptIndex(pendingIndex) {
                    pendingUserPromptIndex = nil
                }
                if let pending = pendingEventJumpID, jumpToEventID(pending) {
                    pendingEventJumpID = nil
                }

                if appendOnlyUpdate {
                    if !unifiedQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        recomputeUnifiedMatches(resetIndex: false, preserveCurrentLine: true)
                    } else {
                        unifiedMatchOccurrences = []
                        unifiedCurrentMatchLineID = nil
                        unifiedExternalMatchCount = 0
                        unifiedExternalTotalMatchCount = 0
                        unifiedExternalCurrentMatchIndex = 0
                    }

                    if !findQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        recomputeFindMatches(resetIndex: false, preserveCurrentLine: true)
                    } else {
                        findMatchOccurrences = []
                        findCurrentMatchLineID = nil
                        externalMatchCount = 0
                        externalTotalMatchCount = 0
                        externalCurrentMatchIndex = 0
                    }
                } else {
                    unifiedMatchOccurrences = []
                    unifiedCurrentMatchLineID = nil
                    unifiedExternalMatchCount = 0
                    unifiedExternalTotalMatchCount = 0
                    unifiedExternalCurrentMatchIndex = 0

                    findMatchOccurrences = []
                    findCurrentMatchLineID = nil
                    roleNavPositions = [:]
                    semanticNavPositions = [:]
                    externalMatchCount = 0
                    externalTotalMatchCount = 0
                    externalCurrentMatchIndex = 0

                    if !unifiedQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        recomputeUnifiedMatches(resetIndex: true)
                    }
                    if !findQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        recomputeFindMatches(resetIndex: true)
                    }
                }

                if unifiedQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   findQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    applyAutoScrollIfNeeded(sessionID: sessionSnapshot.id, skipAgentsPreamble: skipAgentsPreamble)
                }
            }
        }
    }
```

- [ ] **Step 5: Build + run the existing terminal tests to confirm flag-off parity**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/TranscriptBuilderTests -only-testing:AgentSessionsTests/TerminalKindTests -only-testing:AgentSessionsTests/SessionTerminalDiffTests 2>&1 | tail -25`
Expected: PASS — flag defaults off, so behavior is unchanged; the `buildRebuildResult` refactor is output-identical.

- [ ] **Step 6: Commit**

```bash
git add AgentSessions/Views/SessionTerminalView.swift
git commit -m "feat(transcript): build last block window on open behind transcriptWindowedBuild

Tool: Claude Code
Model: claude-opus-4-8
Why: bound hydrated open cost to a window of whole blocks; flag-off path unchanged"
```

---

## Task 5: Load-older + prepend with dedupe and scroll-anchor restore

On near-top, build the previous window's **newly revealed** block slice, prepend its lines to `lines`, dedupe by global line id, and restore the scroll position so the previously-top line stays put. Restoration uses the existing `NSTextView` scroll plumbing: capture the document-visible top line id + its pixel offset before the prepend, then after `applyContent` re-lays-out, scroll so that line returns to the same screen offset.

**Files:**
- Modify: `AgentSessions/Views/SessionTerminalView.swift` — add `loadOlderWindow()` (near the windowed builder), and wire it to `onTopProximityChange` in `TranscriptPlainView`.
- Modify: `AgentSessions/Views/TranscriptPlainView.swift:868` (`updateTopProximity`) to trigger load-older.

**Interfaces:**
- Consumes: `loadedWindow`, `totalBlockCount`, `TranscriptWindow.expandedOlder`, `buildWindowedRebuildResult`.
- Produces: `func loadOlderWindow()` on `SessionTerminalView`; a notification or binding for `TranscriptPlainView` to request it. Because `SessionTerminalView` owns the window state and the `NSTextView`, the trigger and the prepend both live inside `SessionTerminalView`; `TranscriptPlainView` only forwards the near-top signal.

> **Anchor mechanism (no new SwiftUI plumbing):** `SessionTerminalView` already observes scroll via the coordinator (`installScrollObserver`, `emitBottomProximityIfNeeded` computes `nearTop` at :3306). We add a coordinator-level "near top" callback that calls back into the view's `loadOlderWindow()`. The prepend is performed by setting `loadedWindow` to the expanded window and re-running the windowed build through `rebuildLines`, then restoring scroll in `applyContent`'s aftermath via a captured anchor.

- [ ] **Step 1: Write the failing prepend-dedupe parity test**

Add to `AgentSessionsTests/TranscriptWindowedBuildTests.swift` (inside the class):

```swift
    // MARK: - Prepend produces exactly the whole-window build (no dupes, no gaps)

    func testPrependOlderThenTailEqualsWholeWindowBuild() {
        let session = deltaSession(pairs: 60)
        let blocks = SessionTranscriptBuilder.coalescedBlocks(for: session, includeMeta: false)

        let tail = TranscriptWindow.lastWindow(totalBlocks: blocks.count, blockTarget: 20)
        let expanded = tail.expandedOlder(blockTarget: 20)

        // Tail lines (initial load).
        var loaded = TerminalBuilder.buildLines(from: blocks,
                                                blockRange: tail.lowerBlock...tail.upperBlock,
                                                source: session.source, enableReviewCards: true)
        // Newly revealed older slice only.
        let olderSlice = TerminalBuilder.buildLines(from: blocks,
                                                    blockRange: expanded.lowerBlock...(tail.lowerBlock - 1),
                                                    source: session.source, enableReviewCards: true)

        // Simulate the prepend + dedupe-by-id the view performs.
        let existingIDs = Set(loaded.map(\.id))
        let deduped = olderSlice.filter { !existingIDs.contains($0.id) }
        loaded = deduped + loaded

        // Must equal a single whole-window build over the expanded range.
        let whole = TerminalBuilder.buildLines(from: blocks,
                                               blockRange: expanded.lowerBlock...expanded.upperBlock,
                                               source: session.source, enableReviewCards: true)
        XCTAssertEqual(loaded.map(\.id), whole.map(\.id))
        XCTAssertEqual(loaded.map(\.text), whole.map(\.text))
        // Ids strictly increasing (prepend preserved order, no renumber).
        XCTAssertEqual(loaded.map(\.id), loaded.map(\.id).sorted())
    }

    func testPrependIsIdempotentWhenOlderWindowAlreadyLoaded() {
        let session = deltaSession(pairs: 30)
        let blocks = SessionTranscriptBuilder.coalescedBlocks(for: session, includeMeta: false)
        let full = 0...(blocks.count - 1)
        var loaded = TerminalBuilder.buildLines(from: blocks, blockRange: full,
                                                source: session.source, enableReviewCards: true)
        // Re-prepending an overlapping slice must add nothing.
        let overlap = TerminalBuilder.buildLines(from: blocks, blockRange: 0...5,
                                                 source: session.source, enableReviewCards: true)
        let existingIDs = Set(loaded.map(\.id))
        let deduped = overlap.filter { !existingIDs.contains($0.id) }
        XCTAssertTrue(deduped.isEmpty, "overlapping prepend must dedupe to nothing")
        loaded = deduped + loaded
        let whole = TerminalBuilder.buildLines(from: blocks, blockRange: full,
                                               source: session.source, enableReviewCards: true)
        XCTAssertEqual(loaded.map(\.id), whole.map(\.id))
    }
```

- [ ] **Step 2: Run to verify the new tests fail or pass**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/TranscriptWindowedBuildTests 2>&1 | tail -25`
Expected: PASS — these tests exercise the *already-implemented* slice builder + the dedupe contract. They are the executable spec the view code in Step 3 must honor. (If they fail, the slice builder from Task 3 is wrong — fix that before proceeding.)

- [ ] **Step 3: Add `loadOlderWindow()` and the anchor capture/restore to the view**

In `SessionTerminalView.swift`, add (after `buildWindowedRebuildResult`):

```swift
    /// Load the previous (older) window and PREPEND it, preserving scroll position.
    /// No-op when the flag is off, the window already covers the top, a load is in
    /// flight, or the session isn't hydrated.
    @MainActor
    private func loadOlderWindow() {
        guard FeatureFlags.transcriptWindowedBuild,
              FeatureFlags.transcriptWindowNearTopLoadOlder,
              !isLoadingOlderWindow,
              !loadedWindow.isEmpty,
              !loadedWindow.coversTop else { return }

        isLoadingOlderWindow = true
        let target = loadedWindow.expandedOlder(blockTarget: FeatureFlags.transcriptWindowBlockTarget)
        let sessionSnapshot = session
        let skipAgentsPreamble = skipAgentsPreambleEnabled()
        let reviewCardsEnabled = transcriptReviewCardsEnabled

        // Capture the scroll anchor (top visible line id + its pixel offset) BEFORE
        // we change `lines`, so we can restore it after the prepend re-lays-out.
        let anchor = captureTopScrollAnchor()

        Task.detached(priority: .userInitiated) { [sessionSnapshot, skipAgentsPreamble, reviewCardsEnabled, target] in
            let (result, window, total) = Self.buildWindowedRebuildResult(session: sessionSnapshot,
                                                                          skipAgentsPreamble: skipAgentsPreamble,
                                                                          enableReviewCards: reviewCardsEnabled,
                                                                          window: target)
            await MainActor.run {
                defer { isLoadingOlderWindow = false }
                // Dedupe by global line id: keep only lines not already loaded.
                let existingIDs = Set(lines.map(\.id))
                let revealed = result.lines.filter { !existingIDs.contains($0.id) }
                guard !revealed.isEmpty else {
                    loadedWindow = window
                    totalBlockCount = total
                    return
                }

                loadedWindow = window
                totalBlockCount = total

                // Prepend, then refresh derived state from the now-larger slice.
                let merged = revealed + lines
                lines = merged
                visibleLines = applyLineFilters(merged)
                visibleLinesSignature = Self.stableLineSignature(for: visibleLines)
                refreshSearchSnapshotsIfNeeded()
                conversationStartLineID = result.conversationStartLineID
                preambleUserBlockIndexes = result.preambleUserBlockIndexes
                userLineIndices = result.userLineIndices
                assistantLineIndices = result.assistantLineIndices
                toolLineIndices = result.toolLineIndices
                errorLineIndices = result.errorLineIndices
                eventIDToUserLineID = result.eventIDToUserLineID

                pendingScrollAnchorRestore = anchor
            }
        }
    }
```

Add the anchor state near the window state (after `isLoadingOlderWindow`):

```swift
    /// Captured top-line anchor to restore after a load-older prepend re-lays-out.
    @State private var pendingScrollAnchorRestore: ScrollAnchor? = nil
```

Add the anchor type + capture/restore helpers. Place them next to the existing scroll helpers (near `applyContent`, ~:4310). `captureTopScrollAnchor` reads the coordinator's active scroll view + the line range map to find the first fully-visible line; `restoreScrollAnchor` finds that line's new rect and scrolls so it sits at the same screen offset:

```swift
    struct ScrollAnchor: Equatable {
        let lineID: Int
        /// Pixel distance from the line's top to the viewport top at capture time.
        let offsetWithinViewport: CGFloat
    }

    @MainActor
    private func captureTopScrollAnchor() -> ScrollAnchor? {
        guard let coordinator = activeCoordinator,
              let scrollView = coordinator.activeScrollView,
              let lm = coordinator.activeLayoutManager,
              let tv = scrollView.documentView as? NSTextView,
              let tc = tv.textContainer else { return nil }
        let visibleTopY = scrollView.contentView.documentVisibleRect.origin.y
        let origin = tv.textContainerOrigin
        // Find the first line whose rect bottom is below the viewport top.
        for entry in coordinator.lineIndex {
            let glyph = lm.glyphRange(forCharacterRange: entry.range, actualCharacterRange: nil)
            var rect = lm.boundingRect(forGlyphRange: glyph, in: tc)
            rect.origin.y += origin.y
            if rect.maxY > visibleTopY {
                return ScrollAnchor(lineID: entry.id, offsetWithinViewport: rect.minY - visibleTopY)
            }
        }
        return nil
    }

    @MainActor
    private func restoreScrollAnchor(_ anchor: ScrollAnchor) {
        guard let coordinator = activeCoordinator,
              let scrollView = coordinator.activeScrollView,
              let lm = coordinator.activeLayoutManager,
              let tv = scrollView.documentView as? NSTextView,
              let tc = tv.textContainer,
              let entry = coordinator.lineIndex.first(where: { $0.id == anchor.lineID }) else { return }
        lm.ensureLayout(for: tc)
        let glyph = lm.glyphRange(forCharacterRange: entry.range, actualCharacterRange: nil)
        var rect = lm.boundingRect(forGlyphRange: glyph, in: tc)
        rect.origin.y += tv.textContainerOrigin.y
        let targetY = max(0, rect.minY - anchor.offsetWithinViewport)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: targetY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
```

> **`activeCoordinator` / `activeScrollView` / `activeLayoutManager` / `lineIndex`:** the coordinator already exposes `activeScrollView`, `activeLayoutManager`, and `lineIndex` (used at :3301, :4335, :4338). If `SessionTerminalView` lacks an `activeCoordinator` handle, store the coordinator in a `@State` weak box set in `makeNSView`/`updateNSView` (the coordinator is created in `makeCoordinator`). Add to the view, near the other `@State`: `@State private var activeCoordinator: Coordinator? = nil`, and set `activeCoordinator = context.coordinator` at the top of `updateNSView` (line 4138, after the `guard let tv`). This is read-only use of already-existing coordinator fields.

- [ ] **Step 4: Restore the anchor after the prepend re-lays-out**

In `applyContent` (the full-rebuild path the prepend takes — a prepend changes the prefix so `tailPatchStrategy` returns `.replaceSuffix`/`nil`, routing to `applyContent` at :4185), restore the anchor at the very end. Insert just before `emitRenderCompleteIfNeeded(context:)` (line 4352):

```swift
        if let anchor = pendingScrollAnchorRestore {
            // Defer to the next runloop so TextKit has finished laying out the
            // prepended content before we measure the anchor line's new rect.
            DispatchQueue.main.async {
                restoreScrollAnchor(anchor)
                pendingScrollAnchorRestore = nil
            }
        }
```

- [ ] **Step 5: Wire the near-top trigger to `loadOlderWindow()`**

`onTopProximityChange` currently flows to `TranscriptPlainView.updateTopProximity` (:868), which only sets `isNearTranscriptTop`. We additionally need the *terminal* view to react. The cleanest hook: in `SessionTerminalView.updateNSView`, when the coordinator emits near-top, call `loadOlderWindow()`. Add a coordinator callback. In the `Coordinator` (near `onTopProximityChange` at :3185), add:

```swift
        var onNearTopLoadOlder: (() -> Void)?
```

In `emitBottomProximityIfNeeded` (after the `onTopProximityChange` dispatch at :3312–3313), add:

```swift
            if nearTop {
                DispatchQueue.main.async { [weak self] in
                    self?.onNearTopLoadOlder?()
                }
            }
```

In `updateNSView` (where the other coordinator callbacks are assigned, ~:4142), add:

```swift
        context.coordinator.onNearTopLoadOlder = { loadOlderWindow() }
```

> `loadOlderWindow` is a method on the `SessionTerminalView` struct value captured by the closure; SwiftUI re-runs `updateNSView` with a fresh `self`, so the closure always calls the current view's method. The guards inside `loadOlderWindow` make repeated near-top emissions idempotent (the `isLoadingOlderWindow` flag + `coversTop` short-circuit).

- [ ] **Step 6: Run the windowed tests + a smoke build**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/TranscriptWindowedBuildTests -only-testing:AgentSessionsTests/TranscriptWindowTests 2>&1 | tail -25`
Expected: PASS — prepend/dedupe parity tests green; the view compiles.

- [ ] **Step 7: Commit**

```bash
git add AgentSessions/Views/SessionTerminalView.swift AgentSessionsTests/TranscriptWindowedBuildTests.swift
git commit -m "feat(transcript): load-older prepend with dedupe and scroll-anchor restore

Tool: Claude Code
Model: claude-opus-4-8
Why: scrolling near the top of a windowed transcript must reveal older blocks without losing scroll position"
```

---

## Task 6: Live-tail interaction (append stays append; window tracks the bottom)

When new events arrive (live-tail), `rebuildLines` re-runs. With the flag on, a fresh rebuild rebuilds the *last* window (`requestedWindow == loadedWindow`), which already includes the tail. But if the user has loaded older windows (so `loadedWindow` no longer starts at the last-window lower bound) AND is pinned to the bottom, the rebuild must keep the bottom visible and extend `upperBlock` to the new last block. We ensure: (a) when new blocks arrive, the loaded window's `upperBlock` is bumped to the new last block so the tail is built; (b) the existing append-only `tailPatchStrategy` path still fires (ids are global + stable, so appended lines have strictly greater ids).

**Files:**
- Modify: `AgentSessions/Views/SessionTerminalView.swift` — in the windowed branch of `rebuildLines`, when rebuilding with a non-empty `requestedWindow`, extend its `upperBlock` to the latest block before building.

**Interfaces:**
- Consumes: `TranscriptWindow.expandedNewer`, `buildWindowedRebuildResult`.
- Produces: tail growth keeps `loadedWindow.upperBlock` at the last block; the append-only update path (`appendOnlyUpdate`) continues to work because slice ids are global.

- [ ] **Step 1: Write the failing tail-growth parity test**

Add to `AgentSessionsTests/TranscriptWindowedBuildTests.swift`:

```swift
    // MARK: - Live-tail: appending events extends the window's tail with stable ids

    func testAppendingEventsExtendsTailWithStrictlyGreaterIDs() {
        let before = deltaSession(pairs: 20)
        let beforeBlocks = SessionTranscriptBuilder.coalescedBlocks(for: before, includeMeta: false)
        let beforeWindow = TranscriptWindow.lastWindow(totalBlocks: beforeBlocks.count, blockTarget: 10)
        let beforeLines = TerminalBuilder.buildLines(from: beforeBlocks,
                                                     blockRange: beforeWindow.lowerBlock...beforeWindow.upperBlock,
                                                     source: before.source, enableReviewCards: true)

        // Same session + one more pair appended (live-tail).
        var events = before.events
        events.append(userEvent("u-extra", "Follow-up question"))
        events.append(assistantDelta("a-extra-0", "Tail answer\n", messageID: "asst-extra"))
        events.append(assistantDelta("a-extra-1", "more", messageID: "asst-extra"))
        let after = Session(id: before.id, source: .codex, startTime: nil, endTime: nil,
                            model: "test", filePath: before.filePath, fileSizeBytes: nil,
                            eventCount: events.count, events: events)
        let afterBlocks = SessionTranscriptBuilder.coalescedBlocks(for: after, includeMeta: false)

        // Window extended to the new last block (same lower, new upper).
        let extended = TranscriptWindow(lowerBlock: beforeWindow.lowerBlock, upperBlock: afterBlocks.count - 1)
        let afterLines = TerminalBuilder.buildLines(from: afterBlocks,
                                                    blockRange: extended.lowerBlock...extended.upperBlock,
                                                    source: after.source, enableReviewCards: true)

        // The earlier lines must be an exact prefix (append-only), so tailPatchStrategy
        // returns .append rather than a full reload.
        XCTAssertEqual(Array(afterLines.prefix(beforeLines.count)).map(\.id), beforeLines.map(\.id))
        XCTAssertEqual(Array(afterLines.prefix(beforeLines.count)).map(\.text), beforeLines.map(\.text))
        // New tail ids are strictly greater than every prior id.
        let maxBefore = beforeLines.map(\.id).max() ?? -1
        for line in afterLines.suffix(afterLines.count - beforeLines.count) {
            XCTAssertGreaterThan(line.id, maxBefore)
        }
        // tailPatchStrategy classifies this as a pure append.
        let strategy = SessionTerminalView.tailPatchStrategy(previous: beforeLines, current: afterLines)
        XCTAssertEqual(strategy, .append(startIndex: beforeLines.count))
    }
```

- [ ] **Step 2: Run to verify it fails (or passes)**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/TranscriptWindowedBuildTests/testAppendingEventsExtendsTailWithStrictlyGreaterIDs 2>&1 | tail -20`
Expected: PASS if Phase 2 global ids are append-stable (they must be, by design). If it FAILS with mismatched prefix ids, Phase 2's id scheme is not append-stable for a growing tail — STOP and reconcile with Phase 2 before continuing; windowed live-tail depends on this invariant.

- [ ] **Step 3: Extend the window tail on rebuild**

In `rebuildLines` (Task 4 version), change the `requestedWindow` computation so a non-empty current window always tracks the latest bottom. Replace the `requestedWindow` line:

```swift
        let requestedWindow: TranscriptWindow? = (windowed && !loadedWindow.isEmpty) ? loadedWindow : nil
```

with:

```swift
        // On rebuild, if a window is already loaded, keep its lower bound but let
        // the windowed builder clamp/extend the upper bound to the current last
        // block (handled inside buildWindowedRebuildResult, which clamps to total).
        // To ensure the tail is included after new events arrive, push upperBlock
        // to a large sentinel; buildWindowedRebuildResult clamps it to total-1.
        let requestedWindow: TranscriptWindow? = {
            guard windowed, !loadedWindow.isEmpty else { return nil }
            return TranscriptWindow(lowerBlock: loadedWindow.lowerBlock, upperBlock: Int.max)
        }()
```

`buildWindowedRebuildResult` already clamps `upper = min(total - 1, requested.upperBlock)` (Task 4, Step 3), so `Int.max` resolves to "through the last block". This guarantees newly appended blocks are built, while the lower bound (older windows the user loaded) is preserved.

- [ ] **Step 4: Run the windowed tests**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/TranscriptWindowedBuildTests 2>&1 | tail -25`
Expected: PASS — all windowed tests, including tail growth.

- [ ] **Step 5: Commit**

```bash
git add AgentSessions/Views/SessionTerminalView.swift AgentSessionsTests/TranscriptWindowedBuildTests.swift
git commit -m "feat(transcript): keep windowed transcript tail tracking the latest block on live-tail

Tool: Claude Code
Model: claude-opus-4-8
Why: live-tail must append into the windowed view without dropping the bottom or full-reloading"
```

---

## Task 7: Reset window on session/filter change + full parity regression test

A fresh session selection or filter toggle must reset `loadedWindow` to empty so the next `rebuildLines` starts from the last window (not a stale older window from the previous session). The view already calls `rebuildLines` on session change ([:245](../../../AgentSessions/Views/SessionTerminalView.swift)) and filter change ([:254/:257](../../../AgentSessions/Views/SessionTerminalView.swift)); we reset the window state there.

**Files:**
- Modify: `AgentSessions/Views/SessionTerminalView.swift:226-260` (the `.onAppear` / `.onChange(of: session.id)` / filter `.onChange` handlers).
- Test: `AgentSessionsTests/TranscriptWindowedBuildTests.swift`.

**Interfaces:**
- Consumes: `loadedWindow`, `totalBlockCount`, `isLoadingOlderWindow`.
- Produces: window state reset to empty before each fresh `rebuildLines`; a small-session sanity that windowed == whole when the session fits in one window.

- [ ] **Step 1: Write the failing "small session = identical" parity test**

Add to `AgentSessionsTests/TranscriptWindowedBuildTests.swift`:

```swift
    // MARK: - Small session fits in one window → windowed build == whole-session build

    func testSmallSessionWindowEqualsWholeSessionBuild() {
        let session = deltaSession(pairs: 5) // 10 blocks < default target
        let blocks = SessionTranscriptBuilder.coalescedBlocks(for: session, includeMeta: false)
        let whole = TerminalBuilder.buildLines(from: blocks, source: session.source, enableReviewCards: true)

        let window = TranscriptWindow.lastWindow(totalBlocks: blocks.count,
                                                 blockTarget: FeatureFlags.transcriptWindowBlockTarget)
        XCTAssertTrue(window.coversTop)
        XCTAssertTrue(window.coversBottom(totalBlocks: blocks.count))
        let windowed = TerminalBuilder.buildLines(from: blocks,
                                                  blockRange: window.lowerBlock...window.upperBlock,
                                                  source: session.source, enableReviewCards: true)

        XCTAssertEqual(windowed.map(\.id), whole.map(\.id))
        XCTAssertEqual(windowed.map(\.text), whole.map(\.text))
        XCTAssertEqual(windowed.map(\.blockIndex), whole.map(\.blockIndex))
        XCTAssertEqual(windowed.map(\.decorationGroupID), whole.map(\.decorationGroupID))
    }
```

- [ ] **Step 2: Run to verify it passes**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/TranscriptWindowedBuildTests/testSmallSessionWindowEqualsWholeSessionBuild 2>&1 | tail -20`
Expected: PASS — a session smaller than the target builds identically whole vs windowed (the single most important parity guarantee for flipping the default later).

- [ ] **Step 3: Reset window state on fresh builds**

In `SessionTerminalView.swift`, in the `.onChange(of: session.id)` handler and each filter `.onChange` handler that calls `rebuildLines` (around lines 245/254/257), add a reset immediately before the `rebuildLines(...)` call. Add this helper near `rebuildLines` (after :792):

```swift
    private func resetWindowState() {
        guard FeatureFlags.transcriptWindowedBuild else { return }
        loadedWindow = TranscriptWindow(lowerBlock: 0, upperBlock: -1)
        totalBlockCount = 0
        isLoadingOlderWindow = false
        pendingScrollAnchorRestore = nil
    }
```

Then at each fresh-build callsite, change e.g.:

```swift
            rebuildLines(priority: .userInitiated)
```

to:

```swift
            resetWindowState()
            rebuildLines(priority: .userInitiated)
```

Apply this to the `.onAppear` (:229), the session-change `.onChange` (:245), and the role/semantic filter `.onChange` handlers (:254, :257). **Do not** add `resetWindowState()` to the live-tail/utility rebuild at :295 (`rebuildLines(priority: .utility, debounceNanoseconds: …)`) — that path must preserve the loaded window so live-tail appends rather than collapsing back to the last window.

> Filter toggles changing `activeRoles`/`activeSemanticKinds` only affect `applyLineFilters`, not the build, so strictly they need not rebuild the *window*; but resetting to the last window on a filter change matches today's "rebuild from scratch" semantics and avoids a stale older-window + filtered view interaction. Keeping the reset here is the conservative, parity-preserving choice.

- [ ] **Step 4: Run the full windowed + builder suite**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/TranscriptWindowedBuildTests -only-testing:AgentSessionsTests/TranscriptWindowTests -only-testing:AgentSessionsTests/TranscriptBuilderTests 2>&1 | tail -25`
Expected: PASS — all windowed unit tests + the legacy builder suite green.

- [ ] **Step 5: Commit**

```bash
git add AgentSessions/Views/SessionTerminalView.swift AgentSessionsTests/TranscriptWindowedBuildTests.swift
git commit -m "feat(transcript): reset windowed transcript window on session/filter change

Tool: Claude Code
Model: claude-opus-4-8
Why: a fresh selection must start from the last window, not a stale older window from the previous session"
```

---

## Task 8: Manual QA + full-suite gate (flag default-off, then flag-on smoke)

No code change unless QA finds a defect. This task confirms the flag-off path is untouched and the flag-on path behaves per spec.

**Files:** none (QA only). If a defect is found, write a failing test reproducing it, then fix.

- [ ] **Step 1: Run the entire test suite (flag off — production default)**

Run: `./scripts/xcode_test_stable.sh 2>&1 | tail -40`
Expected: PASS — the whole suite. Because `transcriptWindowedBuild = false`, every existing behavior is byte-identical; the only new tests are the windowed ones, which exercise the slice builder directly.

- [ ] **Step 2: Manual flag-on smoke (build, hand to user)**

Temporarily flip `FeatureFlags.transcriptWindowedBuild = true` **locally (uncommitted)**, build the app to the default DerivedData (NOT the test derived-data path — see CLAUDE.md), `killall AgentSessions` and relaunch, then verify with the user on a large hydrated session:
- Open is fast; only the tail is visible initially.
- Scrolling to the very top reveals older content and the scroll position does NOT jump (anchor holds).
- Repeated scroll-to-top eventually reaches the first prompt (`coversTop`); no dupes, no gaps at any boundary.
- A live session still appends new output at the bottom while a window is loaded.
- Inline images land on the correct block; linkification, Copy Block, role/semantic filters, and export operate on the loaded window.
- Then **revert the local flag flip** (leave `transcriptWindowedBuild = false` committed).

> Per the user's QA rules: **I build, the user runs it.** Do not drive the app via computer-use; relaunch and tell the user exactly what to check. Restore macOS Appearance to System if any automation changed it.

- [ ] **Step 3: Commit (only if a QA-driven fix was made)**

```bash
git add -A
git commit -m "fix(transcript): <specific QA finding>

Tool: Claude Code
Model: claude-opus-4-8
Why: <what the manual QA surfaced>"
```

---

## Self-Review

**1. Spec coverage**

| Spec requirement | Task |
|---|---|
| Window the build into the existing single `NSTextView`; keep renderer/attr/layout | Tasks 3–4 (slice builder feeds `lines`; `applyContent` unchanged) |
| Window unit = whole coalesced blocks, boundary-safe (never cut a `canMerge` chain) | Task 2 (`TranscriptWindow` over post-coalesce block indices) + Task 3 test `testAssistantDeltaStreamIsSingleBlockSoWindowCannotSplitIt` |
| Build each block exactly once; dedupe on prepend by global id | Task 5 (`loadOlderWindow` dedupe by `Set(lines.map(\.id))`) + tests |
| Stable global identities (from Phase 2); prepend must not renumber | Global-id assumption stated up front; Tasks 3/5 tests assert disjoint, strictly-increasing ids |
| Index maps recomputed from the loaded slice using global ids | Task 4 (`makeRebuildResult` over the slice's `built` lines) |
| Load-older / load-newer triggers; reuse `isNearTranscriptTop`/`updateTopProximity`; preserve scroll anchor | Task 5 (`onNearTopLoadOlder` + `captureTopScrollAnchor`/`restoreScrollAnchor`) |
| Live-tail append path | Task 6 (window tail tracks last block; `tailPatchStrategy` append-only) |
| Window size policy | Task 1 (`transcriptWindowBlockTarget`) + Task 2 (`lastWindow`/`expandedOlder`/`expandedNewer`) |
| Behind `FeatureFlags.transcriptWindowedBuild`, default off, parity-gated | Task 1 + flag-off branches in Tasks 4–7 + parity tests in Tasks 3/5/6/7 |
| Tests: windowed parity for a full window; scroll-anchor stability; delta/tool stream crossing a boundary | Task 3 (full-window parity, delta-as-one-block), Task 5 (prepend parity + anchor mechanism), Task 6 (tail append) |

> **Out of scope here (correctly deferred to spec Phase 4):** bidirectional Find + counts via model scan, jump-to-range loading off-window targets, flipping the default, and removing the whole-session build. Inline-image global-id reconciliation is a Phase 2 deliverable (image mapper keys off global block id); Task 5/QA only verify it still attaches within the loaded window. Load-*newer*-on-near-bottom for the non-tail case (when the user scrolled up via older windows and then scrolls back down past the loaded bottom) is naturally covered because the window always extends to the last block on rebuild (Task 6); an explicit near-bottom "load forward into a capped window" is not required while the tail is always resident.

**2. Placeholder scan:** No "TBD"/"handle edge cases"/"similar to Task N". Every code step shows complete code. The one conditional ("if Phase 2 lacks `globalBlockOffset`, add it") is a precise, self-contained instruction with the exact parameter and default, not a placeholder.

**3. Type consistency:** `TranscriptWindow(lowerBlock:upperBlock:)`, `lastWindow(totalBlocks:blockTarget:)`, `expandedOlder(blockTarget:)`, `expandedNewer(totalBlocks:blockTarget:)`, `coversTop`, `coversBottom(totalBlocks:)`, `isEmpty`, `blockCount` are used identically across Tasks 2/4/5/6/7. `buildLines(from:blockRange:source:enableReviewCards:)`, `buildWindowedRebuildResult(session:skipAgentsPreamble:enableReviewCards:window:)`, `makeRebuildResult(session:blocks:built:skipAgentsPreamble:)`, `loadOlderWindow()`, `resetWindowState()`, `captureTopScrollAnchor()`/`restoreScrollAnchor(_:)`, `ScrollAnchor(lineID:offsetWithinViewport:)`, and the `@State` names (`loadedWindow`, `totalBlockCount`, `isLoadingOlderWindow`, `pendingScrollAnchorRestore`, `activeCoordinator`) are consistent throughout.

---

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-06-30-transcript-phase3-windowed-build.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — execute tasks in this session using executing-plans, batch execution with checkpoints.

**Which approach?**
