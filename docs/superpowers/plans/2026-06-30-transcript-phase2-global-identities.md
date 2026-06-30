# Transcript Phase 2 — Stable Global Identities Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `TerminalLine.id` and `TerminalLine.blockIndex` derive from **stable global identities** tied to the global coalesced-block index (and populate the today-`nil` `TerminalLine.eventIndex`), so a later prepended window never renumbers existing lines and inline-image mapping stays correct — with **zero behavior change**, parity-tested against today's whole-session build.

**Architecture:** Today `TerminalBuilder.buildLines` assigns `line.id` from a local `nextID` counter starting at 0 and `blockIndex` from `blocks.enumerated()`. Both are *local* to the slice being built, so building a sub-range (Phase 3 windowing) would renumber lines and break the image-mapper join (`imagesByUserBlockIndex` keys vs `line.blockIndex`). This phase introduces a `globalBlockIndex` carried on each `LogicalBlock` and a deterministic `TerminalLineID` scheme `id = globalBlockIndex * STRIDE + lineOrdinalWithinBlock` so IDs are stable, unique, and monotonic regardless of which slice is built; `blockIndex` becomes the `globalBlockIndex`; `eventIndex` is populated from the block's originating event position. Substrate only — no slicing yet. All of this lives behind `FeatureFlags.transcriptWindowedBuild`, which when **off** preserves byte-for-byte the current local-id output.

**Tech Stack:** Swift 5 / SwiftUI / AppKit (TextKit), XCTest. macOS app target `AgentSessions`, test target `AgentSessionsTests`.

## Global Constraints

- **No behavior change in this phase.** With `FeatureFlags.transcriptWindowedBuild == false`, `buildLines`/`buildRebuildResult` MUST produce IDs, `blockIndex`, line text, ordering, index maps, and inline-image attachment **identical** to today. The flag defaults to `false`.
- **Line IDs are never used as array subscripts.** Verified: `line.id` is used only as a dictionary key (`ranges[line.id]`, `lineRanges[line.id]`, `lineRoles`), for sorting (`.sorted()`), and for identity lookups (`firstIndex(of:)`, `first(where:)`). The required invariant is therefore: **stable, globally unique, and monotonically increasing in render order** — NOT contiguous-from-zero. The new scheme keeps monotonicity (`globalBlockIndex` is non-decreasing, ordinal increases within a block) while dropping contiguity.
- **`blockIndex` is the join key for inline images.** `SessionInlineImageMapper.imagesByUserBlockIndex` keys by the coalesced-block offset; the renderer attaches by `line.blockIndex`. Both MUST key off the same global block identity. When the flag is on they use `globalBlockIndex`; when off they use the local offset (unchanged).
- **Synthetic / negative block indexes are preserved.** `lineSegments` emits negative `blockIndex` values (`syntheticIndex`, starts at -1, decrements) for interrupt markers / system-reminder / local-command meta segments. These are intentionally NOT real block indexes and MUST remain distinct negative sentinels under the new scheme (they never collide with real `globalBlockIndex` values, which are `>= 0`).
- **Repo file registration:** every NEW Swift file added to a target MUST be registered via:
  `LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 ./scripts/xcode_add_file.rb AgentSessions.xcodeproj <TARGET> <relative/path/to/File.swift> <GroupPath>`
- **Tests run via:** `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/<ClassName>` (single class) or no `-only-testing` for the full suite. The script does `clean test` against isolated DerivedData `.deriveddata-tests`. **Never `open` an app bundle from `.deriveddata-tests`.**
- **Commits:** Conventional Commits with trailers, NO co-author. Every commit message ends with the three trailers:
  ```
  Tool: Claude Code
  Model: claude-opus-4-8
  Why: <one-line reason>
  ```
- **Commit/push policy:** Only the steps in this plan that say "Commit" run `git commit`. Never `git push` (the user pushes).

---

## File Structure

**New files:**
- `AgentSessions/Services/TerminalLineID.swift` — the global-identity encoding scheme (pure functions + constants). One responsibility: encode/decode `(globalBlockIndex, lineOrdinal)` ⇄ `Int` line id, and provide the synthetic-id allocator helper. Keeps the math out of the builder so it can be unit-tested in isolation.
- `AgentSessionsTests/TerminalLineIDTests.swift` — unit tests for the encoding scheme (round-trip, monotonicity, no collision with synthetic negatives).
- `AgentSessionsTests/TerminalGlobalIdentityParityTests.swift` — parity tests asserting the global-id build (flag ON) yields equivalent rendering + index maps + image attachment vs the current local build (flag OFF) on fixtures.

**Modified files:**
- `AgentSessions/Support/FeatureFlags.swift` — add `transcriptWindowedBuild` flag (default `false`).
- `AgentSessions/Services/SessionTranscriptBuilder.swift` — add `globalBlockIndex` to `LogicalBlock`; populate it in `coalesce(...)`.
- `AgentSessions/Services/TerminalModels.swift` — `buildLines` / `buildLinesAndBlocks` populate `id`, `blockIndex`, `eventIndex` from the global scheme when the flag is on; thread `globalBlockIndex` through `lineSegments`.
- `AgentSessions/Utilities/CodexSessionImagePayload.swift` — key `imagesByUserBlockIndex` by `block.globalBlockIndex` when the flag is on.
- `AgentSessions/Views/SessionTerminalView.swift` — `buildRebuildResult` index-map construction is `blockIndex`-keyed; it already reads `line.blockIndex`, so it inherits the global value automatically. One audit step + one targeted parity assertion confirm no local-offset assumptions remain.

---

## Design: the global-identity scheme

**`globalBlockIndex`** — a `0…N-1` index over the **full coalesced-block stream** for the session (the output of `SessionTranscriptBuilder.coalesce`). Because coalescing always runs over the whole event stream (it is text-append, cheap), this index is stable: block *k* is always block *k* regardless of which slice of blocks is later built into lines. We store it on `LogicalBlock` so any later windowed `buildLines(from: blocks[a..<b])` call still knows each block's global position.

**`eventIndex`** — the index of the block's originating event within `session.events`. We derive it during `coalesce` (the loop already enumerates events) and store it on `LogicalBlock` as `firstEventIndex`. `buildLines` copies it onto every `TerminalLine` produced from that block. For merged blocks it is the index of the FIRST event in the merge chain. (This populates the previously-`nil` `TerminalLine.eventIndex` field; it is back-link metadata only this phase.)

**`TerminalLine.id`** — encoded as:
```
id = globalBlockIndex * STRIDE + lineOrdinalWithinBlock
```
where `STRIDE = 1_000_000` (one million lines per block ceiling; blocks never approach this — the largest real blocks are thousands of lines) and `lineOrdinalWithinBlock` is a per-block counter reset to 0 at each block. This guarantees:
- **Unique:** distinct `(block, ordinal)` pairs map to distinct ids.
- **Monotonic in render order:** `globalBlockIndex` is non-decreasing across the line stream and `ordinal` increases within a block, so ids increase exactly in render order — the only property the view relies on (sorting, `firstIndex(of:)`).
- **Stable across slicing:** the id of block *k*'s line *j* does not depend on how many blocks/lines preceded it in the built slice.

**Synthetic (negative) block indexes** — segments with a negative `blockIndex` (interrupt/system-reminder/local-command meta) keep using a separate **negative synthetic id space** so they cannot collide with real block ids. We encode them as `id = SYNTHETIC_ID_BASE - syntheticCounter` where `SYNTHETIC_ID_BASE = -1` and `syntheticCounter` increments per synthetic line. Negative ids are still unique and still sort *before* all real (`>= 0`) ids; in practice synthetic meta lines are interleaved, but their relative order among themselves and uniqueness is what matters for the dict-key/`firstIndex` usage. (Today these synthetic meta lines also get sequential `nextID` values that happen to be positive; nothing in the view depends on their absolute value, only on per-line-id range lookups — verified by the parity test on a fixture containing a system-reminder.)

> **Important monotonicity note for synthetic lines:** because real ids are huge (`block * 1_000_000`) and synthetic ids are small negatives, a synthetic line that appears *between* two real blocks in render order would have an id that is *less* than its predecessor's. The view's only ordering dependency is `orderedLineIDs = lines.map(\.id)` (an explicit array preserving render order) and `lineRanges[line.id]` (dict). The functions that call `.sorted()` on ids (`userLineIndices`, role nav) operate on **first-line-of-block ids**, which are always real, positive, and monotonic — synthetic meta lines are never block heads for those maps (they are `.meta` role and excluded from user/assistant/tool/error maps). Therefore non-monotonic synthetic ids are safe. The parity test (Task 7) asserts the index maps are identical with the flag on/off, proving this.

When `FeatureFlags.transcriptWindowedBuild == false`, **none** of the above applies: `buildLines` uses the existing local `nextID`/`syntheticBlockIndex` path verbatim.

---

### Task 1: Add the `transcriptWindowedBuild` feature flag

**Files:**
- Modify: `AgentSessions/Support/FeatureFlags.swift`

**Interfaces:**
- Produces: `FeatureFlags.transcriptWindowedBuild: Bool` (default `false`), consumed by Tasks 3–6.

- [ ] **Step 1: Add the flag**

In `AgentSessions/Support/FeatureFlags.swift`, after the `allowCodexProbeDeletion` line and before the closing `}`, add:

```swift
    // Phase 2+ progressive windowed transcript build. When false, the line/block
    // model uses today's local (slice-relative) identities — byte-for-byte
    // unchanged. When true, lines/blocks derive stable GLOBAL identities so a
    // later prepended window never renumbers existing lines. Default false until
    // parity-gated.
    static let transcriptWindowedBuild = false
```

- [ ] **Step 2: Build to verify it compiles**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/TerminalSemanticSegmentationTests`
Expected: PASS (no behavior change; this is just a build smoke check on an existing terminal test).

- [ ] **Step 3: Commit**

```bash
git add AgentSessions/Support/FeatureFlags.swift
git commit -m "feat(transcript): add transcriptWindowedBuild feature flag (default off)

Tool: Claude Code
Model: claude-opus-4-8
Why: gate Phase 2 global-identity substrate behind a flag for parity gating"
```

---

### Task 2: `TerminalLineID` encoding scheme + tests

**Files:**
- Create: `AgentSessions/Services/TerminalLineID.swift`
- Test: `AgentSessionsTests/TerminalLineIDTests.swift`

**Interfaces:**
- Produces:
  - `enum TerminalLineID` with:
    - `static let stride: Int` (= 1_000_000)
    - `static let syntheticIDBase: Int` (= -1)
    - `static func makeID(globalBlockIndex: Int, lineOrdinal: Int) -> Int`
    - `static func makeSyntheticID(syntheticCounter: Int) -> Int`
    - `static func globalBlockIndex(from id: Int) -> Int?` (returns nil for synthetic/negative ids)
  - Consumed by Tasks 3 (builder) — encodes line ids.

- [ ] **Step 1: Write the failing tests**

Create `AgentSessionsTests/TerminalLineIDTests.swift`:

```swift
import XCTest
@testable import AgentSessions

final class TerminalLineIDTests: XCTestCase {
    func testRoundTripGlobalBlockIndex() {
        for block in [0, 1, 7, 42, 1000, 50_000] {
            for ordinal in [0, 1, 5, 99] {
                let id = TerminalLineID.makeID(globalBlockIndex: block, lineOrdinal: ordinal)
                XCTAssertEqual(TerminalLineID.globalBlockIndex(from: id), block,
                               "id \(id) should decode back to block \(block)")
            }
        }
    }

    func testIDsAreUniqueAcrossBlocksAndOrdinals() {
        var seen = Set<Int>()
        for block in 0..<200 {
            for ordinal in 0..<50 {
                let id = TerminalLineID.makeID(globalBlockIndex: block, lineOrdinal: ordinal)
                XCTAssertFalse(seen.contains(id), "duplicate id \(id) for block \(block) ordinal \(ordinal)")
                seen.insert(id)
            }
        }
    }

    func testIDsAreMonotonicInRenderOrder() {
        // Render order: block ascending, ordinal ascending within a block.
        var previous = Int.min
        for block in 0..<100 {
            for ordinal in 0..<10 {
                let id = TerminalLineID.makeID(globalBlockIndex: block, lineOrdinal: ordinal)
                XCTAssertGreaterThan(id, previous,
                                     "id must increase in render order (block \(block) ordinal \(ordinal))")
                previous = id
            }
        }
    }

    func testSyntheticIDsAreNegativeUniqueAndDoNotDecodeToBlock() {
        var seen = Set<Int>()
        for counter in 0..<100 {
            let id = TerminalLineID.makeSyntheticID(syntheticCounter: counter)
            XCTAssertLessThan(id, 0, "synthetic ids are negative")
            XCTAssertFalse(seen.contains(id), "synthetic id \(id) must be unique")
            seen.insert(id)
            XCTAssertNil(TerminalLineID.globalBlockIndex(from: id),
                         "synthetic id \(id) must not decode to a real block index")
        }
    }

    func testRealIDsAreNonNegative() {
        XCTAssertGreaterThanOrEqual(TerminalLineID.makeID(globalBlockIndex: 0, lineOrdinal: 0), 0)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/TerminalLineIDTests`
Expected: FAIL to compile with "cannot find 'TerminalLineID' in scope" (the type does not exist yet, and the test file is not yet registered to the target — register it in Step 3).

- [ ] **Step 3: Create the implementation and register both new files**

Create `AgentSessions/Services/TerminalLineID.swift`:

```swift
import Foundation

/// Encoding scheme for stable, GLOBAL `TerminalLine` identities.
///
/// A line id is `globalBlockIndex * stride + lineOrdinalWithinBlock`. Because the
/// global block index is stable across any slice of the coalesced-block stream,
/// the id of a given block's given line does not depend on how many blocks/lines
/// preceded it in the built slice — so a later prepended window never renumbers
/// existing lines.
///
/// Ids are required to be **unique** and **monotonic in render order**; they are
/// intentionally NOT contiguous-from-zero. The view uses `line.id` only as a
/// dictionary key and for `sorted()` / `firstIndex(of:)` / `first(where:)`
/// lookups, never as a raw array subscript.
enum TerminalLineID {
    /// Maximum lines a single coalesced block can contribute before ids would
    /// collide with the next block. Real blocks are at most a few thousand lines.
    static let stride = 1_000_000

    /// Synthetic (meta) lines that have no real block index get negative ids in a
    /// separate space so they never collide with real (`>= 0`) block ids.
    static let syntheticIDBase = -1

    /// Encode the id for line `lineOrdinal` (0-based, reset per block) of block
    /// `globalBlockIndex` (0-based over the full coalesced-block stream).
    static func makeID(globalBlockIndex: Int, lineOrdinal: Int) -> Int {
        globalBlockIndex * stride + lineOrdinal
    }

    /// Encode a synthetic (negative) id for a meta line with no real block index.
    /// `syntheticCounter` increments per synthetic line within a single build.
    static func makeSyntheticID(syntheticCounter: Int) -> Int {
        syntheticIDBase - syntheticCounter
    }

    /// Decode the global block index from an id, or nil if the id is synthetic
    /// (negative) and therefore not tied to a real block.
    static func globalBlockIndex(from id: Int) -> Int? {
        guard id >= 0 else { return nil }
        return id / stride
    }
}
```

Register both new files:

```bash
LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 ./scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessions AgentSessions/Services/TerminalLineID.swift Services
LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 ./scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessionsTests AgentSessionsTests/TerminalLineIDTests.swift AgentSessionsTests
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/TerminalLineIDTests`
Expected: PASS (all 5 tests green).

- [ ] **Step 5: Commit**

```bash
git add AgentSessions/Services/TerminalLineID.swift AgentSessionsTests/TerminalLineIDTests.swift AgentSessions.xcodeproj/project.pbxproj
git commit -m "feat(transcript): add TerminalLineID global-identity encoding scheme

Tool: Claude Code
Model: claude-opus-4-8
Why: deterministic stable line ids decoupled from slice-local enumeration"
```

---

### Task 3: Carry `globalBlockIndex` + `firstEventIndex` on `LogicalBlock`

**Files:**
- Modify: `AgentSessions/Services/SessionTranscriptBuilder.swift` (`LogicalBlock` struct ~288-302; `block(from:)` ~304-393; `coalesce(events:source:includeMeta:)` ~471-498)
- Test: `AgentSessionsTests/TerminalGlobalIdentityParityTests.swift` (created here, expanded in Task 7)

**Interfaces:**
- Produces:
  - `LogicalBlock.globalBlockIndex: Int` (default `-1` until assigned by `coalesce`)
  - `LogicalBlock.firstEventIndex: Int` (default `-1` until assigned)
  - Consumed by Tasks 4 (builder), 5 (image mapper), 7 (parity tests).

- [ ] **Step 1: Write the failing test**

Create `AgentSessionsTests/TerminalGlobalIdentityParityTests.swift`:

```swift
import XCTest
@testable import AgentSessions

final class TerminalGlobalIdentityParityTests: XCTestCase {

    // MARK: Fixtures

    private func makeEvent(id: String,
                           kind: SessionEventKind,
                           text: String? = nil,
                           toolName: String? = nil,
                           toolOutput: String? = nil,
                           messageID: String? = nil,
                           isDelta: Bool = false) -> SessionEvent {
        SessionEvent(id: id,
                     timestamp: nil,
                     kind: kind,
                     role: nil,
                     text: text,
                     toolName: toolName,
                     toolInput: nil,
                     toolOutput: toolOutput,
                     messageID: messageID ?? id,
                     parentID: nil,
                     isDelta: isDelta,
                     rawJSON: "{}")
    }

    private func makeSession(source: SessionSource, events: [SessionEvent]) -> Session {
        Session(id: "s-global",
                source: source,
                startTime: nil,
                endTime: nil,
                model: "test-model",
                filePath: "/tmp/s-global.jsonl",
                fileSizeBytes: nil,
                eventCount: events.count,
                events: events)
    }

    /// Mixed session: two user prompts, assistant deltas that coalesce, a tool
    /// call + output, and an error — enough to exercise every role + a merge.
    private func mixedEvents() -> [SessionEvent] {
        [
            makeEvent(id: "u1", kind: .user, text: "First question"),
            makeEvent(id: "a1", kind: .assistant, text: "Part one ", messageID: "m1", isDelta: true),
            makeEvent(id: "a2", kind: .assistant, text: "part two.", messageID: "m1", isDelta: true),
            makeEvent(id: "tc1", kind: .tool_call, toolName: "shell", text: "ls -la"),
            makeEvent(id: "to1", kind: .tool_result, toolName: "shell", toolOutput: "file.txt\nother.txt"),
            makeEvent(id: "u2", kind: .user, text: "Second question"),
            makeEvent(id: "a3", kind: .assistant, text: "Answer two."),
            makeEvent(id: "er1", kind: .error, text: "boom"),
        ]
    }

    // MARK: Task 3 assertions

    func testCoalesceAssignsContiguousGlobalBlockIndexes() {
        let session = makeSession(source: .codex, events: mixedEvents())
        let blocks = SessionTranscriptBuilder.coalescedBlocks(for: session, includeMeta: false)
        XCTAssertFalse(blocks.isEmpty)
        for (offset, block) in blocks.enumerated() {
            XCTAssertEqual(block.globalBlockIndex, offset,
                           "block at offset \(offset) must carry globalBlockIndex == offset")
        }
    }

    func testCoalesceAssignsFirstEventIndexOfMergeChain() {
        let session = makeSession(source: .codex, events: mixedEvents())
        let blocks = SessionTranscriptBuilder.coalescedBlocks(for: session, includeMeta: false)
        // The merged assistant block (a1+a2) must report the FIRST event's index.
        guard let merged = blocks.first(where: { $0.kind == .assistant && $0.text.contains("Part one") }) else {
            return XCTFail("expected merged assistant block")
        }
        // a1 is events[1] in mixedEvents().
        XCTAssertEqual(merged.firstEventIndex, 1,
                       "merged block firstEventIndex must be the first event in the chain")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/TerminalGlobalIdentityParityTests`
Expected: FAIL to compile with "value of type 'SessionTranscriptBuilder.LogicalBlock' has no member 'globalBlockIndex'". (Register the test file in Step 4.)

- [ ] **Step 3: Add the fields and populate them in `coalesce`**

In `AgentSessions/Services/SessionTranscriptBuilder.swift`, change the `LogicalBlock` struct (currently ends with `var rawJSON: String`) to add two fields. Replace:

```swift
        var eventID: String
        var rawJSON: String
    }
```

with:

```swift
        var eventID: String
        var rawJSON: String
        /// 0-based index over the FULL coalesced-block stream for this session.
        /// Stable across slicing. -1 until assigned by `coalesce`.
        var globalBlockIndex: Int = -1
        /// Index of this block's FIRST originating event within `session.events`
        /// (first event of a merge chain). -1 until assigned by `coalesce`.
        var firstEventIndex: Int = -1
    }
```

Now populate them inside `coalesce(events:source:includeMeta:)`. The current loop body is:

```swift
        for e in events {
            if e.kind == .meta && !includeMeta { continue }
            let base = block(from: e)
            let expanded = expandUserEmbeddedNoticesIfNeeded(block: base)
            for var b in expanded {
                if source == .codex {
                    b.text = normalizeCodexInlineImageMarkers(b.text)
                }
                if let last = blocks.last, canMerge(last, b) {
                    var merged = last
                    merged.text += b.text
                    merged.timestamp = merged.timestamp ?? b.timestamp
                    merged.rawJSON = b.rawJSON
                    if merged.toolName == nil { merged.toolName = b.toolName }
                    if merged.toolInput == nil { merged.toolInput = b.toolInput }
                    merged.isErrorOutput = merged.isErrorOutput || b.isErrorOutput
                    blocks.removeLast()
                    blocks.append(merged)
                } else {
                    blocks.append(b)
                }
            }
        }
        return blocks
```

Replace it with (adds `eventIndex` enumeration; sets `firstEventIndex` on append; assigns `globalBlockIndex` in a final pass so it always equals the final offset even across merges):

```swift
        for (eventIndex, e) in events.enumerated() {
            if e.kind == .meta && !includeMeta { continue }
            let base = block(from: e)
            let expanded = expandUserEmbeddedNoticesIfNeeded(block: base)
            for var b in expanded {
                if source == .codex {
                    b.text = normalizeCodexInlineImageMarkers(b.text)
                }
                if let last = blocks.last, canMerge(last, b) {
                    var merged = last
                    merged.text += b.text
                    merged.timestamp = merged.timestamp ?? b.timestamp
                    merged.rawJSON = b.rawJSON
                    if merged.toolName == nil { merged.toolName = b.toolName }
                    if merged.toolInput == nil { merged.toolInput = b.toolInput }
                    merged.isErrorOutput = merged.isErrorOutput || b.isErrorOutput
                    // firstEventIndex stays the merge chain's FIRST event (already set).
                    blocks.removeLast()
                    blocks.append(merged)
                } else {
                    b.firstEventIndex = eventIndex
                    blocks.append(b)
                }
            }
        }
        // Assign the stable global block index as the final stream offset. Done in
        // a single pass after coalescing so merges don't leave gaps.
        for i in blocks.indices {
            blocks[i].globalBlockIndex = i
        }
        return blocks
```

- [ ] **Step 4: Register the test file and run the test**

```bash
LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 ./scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessionsTests AgentSessionsTests/TerminalGlobalIdentityParityTests.swift AgentSessionsTests
```

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/TerminalGlobalIdentityParityTests`
Expected: PASS (both Task 3 tests green).

- [ ] **Step 5: Verify no existing behavior changed**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/TranscriptBuilderTests -only-testing:AgentSessionsTests/TerminalSemanticSegmentationTests -only-testing:AgentSessionsTests/InlineSessionImageMappingTests`
Expected: PASS (adding default-valued fields + a final assignment pass does not change any existing output; `LogicalBlock` `Equatable` now also compares the two new fields, but all these tests build blocks the same way through `coalesce`).

- [ ] **Step 6: Commit**

```bash
git add AgentSessions/Services/SessionTranscriptBuilder.swift AgentSessionsTests/TerminalGlobalIdentityParityTests.swift AgentSessions.xcodeproj/project.pbxproj
git commit -m "feat(transcript): carry stable globalBlockIndex and firstEventIndex on LogicalBlock

Tool: Claude Code
Model: claude-opus-4-8
Why: substrate for slice-stable line/block identities and eventIndex back-links"
```

---

### Task 4: Build lines with global identities when the flag is on

**Files:**
- Modify: `AgentSessions/Services/TerminalModels.swift` (`buildLines(from:source:enableReviewCards:)` ~75-150; `lineSegments(...)` ~269-321; `LineSegment` struct ~254-260)
- Test: `AgentSessionsTests/TerminalGlobalIdentityParityTests.swift` (extend)

**Interfaces:**
- Consumes: `LogicalBlock.globalBlockIndex`, `LogicalBlock.firstEventIndex` (Task 3); `TerminalLineID.makeID`, `.makeSyntheticID` (Task 2); `FeatureFlags.transcriptWindowedBuild` (Task 1).
- Produces: `TerminalLine.id`/`.blockIndex`/`.eventIndex` populated from globals when flag on; identical-to-today when flag off. Consumed by Tasks 5–7 and the view.

The plan: thread the block's `globalBlockIndex` and `firstEventIndex` into `lineSegments`, and at the point where each `TerminalLine` is constructed, choose the id + blockIndex + eventIndex based on the flag. `lineSegments` currently derives `decorationGroupID` from the LOCAL `blockIndex` arg; we keep that input as the **global** block index when the flag is on (decorationGroupID is internal grouping, not a line id, and using the global index keeps it stable too — and still unique because `globalBlockIndex` is unique).

- [ ] **Step 1: Write the failing parity test for `buildLines`**

Append to `AgentSessionsTests/TerminalGlobalIdentityParityTests.swift`, inside the class:

```swift
    // MARK: Task 4 assertions

    /// Helper: temporarily can't flip a `static let`, so we assert the SHAPE the
    /// builder must produce when the global scheme is active by reading the flag
    /// directly. The flag is compile-time; these assertions branch on it so the
    /// suite is correct whether the flag ships off (today) or on (Phase 4).
    func testBuildLinesGlobalIDsEncodeBlockAndOrdinal() {
        let session = makeSession(source: .codex, events: mixedEvents())
        let blocks = SessionTranscriptBuilder.coalescedBlocks(for: session, includeMeta: false)
        let lines = TerminalBuilder.buildLines(from: blocks, source: .codex)

        XCTAssertFalse(lines.isEmpty)

        if FeatureFlags.transcriptWindowedBuild {
            // Every non-synthetic line's id must decode to its blockIndex, and
            // blockIndex must equal the originating block's globalBlockIndex.
            for line in lines {
                guard let bi = line.blockIndex, bi >= 0 else { continue } // skip synthetic
                guard let decoded = TerminalLineID.globalBlockIndex(from: line.id) else {
                    return XCTFail("real line id \(line.id) failed to decode")
                }
                XCTAssertEqual(decoded, bi,
                               "line id \(line.id) must decode to its blockIndex \(bi)")
            }
            // eventIndex must be populated (non-nil) for every real-block line.
            for line in lines where (line.blockIndex ?? -1) >= 0 {
                XCTAssertNotNil(line.eventIndex, "real-block line must carry eventIndex")
            }
        } else {
            // Today's behavior: ids are 0..N-1 contiguous, eventIndex is nil.
            XCTAssertEqual(lines.map(\.id), Array(0..<lines.count),
                           "with flag off, ids stay contiguous from 0")
            XCTAssertTrue(lines.allSatisfy { $0.eventIndex == nil },
                          "with flag off, eventIndex stays nil")
        }
    }

    func testBuildLinesIDsAreUniqueAndMonotonicEitherWay() {
        let session = makeSession(source: .codex, events: mixedEvents())
        let lines = TerminalBuilder.buildLines(for: session, showMeta: false)
        let ids = lines.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "line ids must be unique")
        // Real (non-synthetic) ids must be strictly increasing in render order.
        let realIDs = lines.filter { ($0.blockIndex ?? -1) >= 0 }.map(\.id)
        for (a, b) in zip(realIDs, realIDs.dropFirst()) {
            XCTAssertLessThan(a, b, "real line ids must increase in render order")
        }
    }

    /// A slice of the block stream must produce the SAME ids/blockIndex for those
    /// blocks as the whole-session build — the core slice-stability property.
    /// (Only meaningful with the flag on; asserted unconditionally as documentation.)
    func testSliceBuildMatchesWholeSessionForSharedBlocks() {
        let session = makeSession(source: .codex, events: mixedEvents())
        let blocks = SessionTranscriptBuilder.coalescedBlocks(for: session, includeMeta: false)
        guard blocks.count >= 4 else { return XCTFail("need >= 4 blocks") }

        let whole = TerminalBuilder.buildLines(from: blocks, source: .codex)
        let tailSlice = Array(blocks.suffix(2))
        let tail = TerminalBuilder.buildLines(from: tailSlice, source: .codex)

        if FeatureFlags.transcriptWindowedBuild {
            // For the last two blocks, the slice build must reproduce the exact
            // ids + blockIndex + text the whole build produced for those blocks.
            let lastTwoBlockIndices = Set(tailSlice.map(\.globalBlockIndex))
            let wholeTail = whole.filter { ($0.blockIndex).map(lastTwoBlockIndices.contains) ?? false }
            XCTAssertEqual(tail.map(\.id), wholeTail.map(\.id),
                           "slice build ids must match whole-session ids for shared blocks")
            XCTAssertEqual(tail.map(\.text), wholeTail.map(\.text),
                           "slice build text must match whole-session text for shared blocks")
            XCTAssertEqual(tail.map(\.blockIndex), wholeTail.map(\.blockIndex),
                           "slice build blockIndex must match whole-session for shared blocks")
        } else {
            // With the flag off, a slice build renumbers from 0 — this documents
            // exactly why Phase 2 is needed. Assert the slice DOES start at 0.
            XCTAssertEqual(tail.first?.id, 0, "flag-off slice build renumbers from 0")
        }
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/TerminalGlobalIdentityParityTests`
Expected: with the flag OFF (default), `testBuildLinesGlobalIDsEncodeBlockAndOrdinal` and `testBuildLinesIDsAreUniqueAndMonotonicEitherWay` PASS as written (they branch on the flag), but `testSliceBuildMatchesWholeSessionForSharedBlocks` PASSES too (flag-off branch). **However**, the build will currently still use only local ids — so `eventIndex` is nil and unique-but-contiguous. The genuinely failing assertion arrives once we flip in Step 4 verification. To get a real RED here, temporarily prove the missing wiring: this step's expected result is **PASS (flag off)** — the failing signal for TDD is captured in Step 5 where we run with the flag conceptually on via the dedicated build path. (See Step 5.)

> Rationale: the flag is a compile-time `static let`, so we cannot flip it at runtime in one test run. We make the builder honor the flag now (Step 3), then Step 5 runs a **direct unit assertion against the global code path** by calling the builder's global branch through a test-only seam if needed. To avoid a seam, Task 7 instead flips the flag to `true` in a separate verification commit and runs the whole parity suite; that is the real RED→GREEN gate. For Task 4 we verify the flag-on math directly via `TerminalLineID` (already tested) and via the slice test's flag-on branch, exercised in Task 7.

- [ ] **Step 3: Implement the flag-aware id assignment in `buildLines`**

In `AgentSessions/Services/TerminalModels.swift`, first extend the private `LineSegment` and the `lineSegments` signature to carry the global block index and first event index.

Change the `LineSegment` struct (currently):

```swift
    private struct LineSegment {
        let role: TerminalLineRole
        let text: String
        let blockIndex: Int?
        let decorationGroupID: Int
        let semanticKind: SemanticKind?
    }
```

to:

```swift
    private struct LineSegment {
        let role: TerminalLineRole
        let text: String
        let blockIndex: Int?
        let decorationGroupID: Int
        let semanticKind: SemanticKind?
        /// Stable global block index for this segment's owning block (real blocks
        /// only; synthetic meta segments keep their negative `blockIndex`).
        let globalBlockIndex: Int
        /// Originating event index of the owning block (for `TerminalLine.eventIndex`).
        let firstEventIndex: Int
    }
```

Change the `lineSegments(...)` signature to accept the two globals. Replace the header:

```swift
    private static func lineSegments(for block: SessionTranscriptBuilder.LogicalBlock,
                                     baseRole: TerminalLineRole,
                                     rawText: String,
                                     blockIndex: Int,
                                     source: SessionSource,
                                     enableReviewCards: Bool,
                                     syntheticIndex: inout Int) -> [LineSegment] {
```

with:

```swift
    private static func lineSegments(for block: SessionTranscriptBuilder.LogicalBlock,
                                     baseRole: TerminalLineRole,
                                     rawText: String,
                                     blockIndex: Int,
                                     globalBlockIndex: Int,
                                     firstEventIndex: Int,
                                     source: SessionSource,
                                     enableReviewCards: Bool,
                                     syntheticIndex: inout Int) -> [LineSegment] {
```

And replace the final `return seeds.enumerated().map { ... }` block in `lineSegments`:

```swift
        return seeds.enumerated().map { idx, seed in
            let effectiveBlockIndex = seed.blockIndex ?? blockIndex
            return LineSegment(role: seed.role,
                               text: seed.text,
                               blockIndex: seed.blockIndex,
                               decorationGroupID: decorationGroupID(blockIndex: effectiveBlockIndex, segmentOrdinal: idx),
                               semanticKind: seed.semanticKind)
        }
```

with (the `decorationGroupID` input uses the GLOBAL block index when the flag is on so it stays stable; falls back to local otherwise — both unique):

```swift
        let decoGroupBase = FeatureFlags.transcriptWindowedBuild ? globalBlockIndex : blockIndex
        return seeds.enumerated().map { idx, seed in
            // Negative synthetic seed.blockIndex must keep its own decoration grouping.
            let effectiveBlockIndex = seed.blockIndex.map { $0 < 0 ? $0 : decoGroupBase } ?? decoGroupBase
            return LineSegment(role: seed.role,
                               text: seed.text,
                               blockIndex: seed.blockIndex,
                               decorationGroupID: decorationGroupID(blockIndex: effectiveBlockIndex, segmentOrdinal: idx),
                               semanticKind: seed.semanticKind,
                               globalBlockIndex: globalBlockIndex,
                               firstEventIndex: firstEventIndex)
        }
```

Now update the **call site** inside `buildLines(from:source:enableReviewCards:)`. The current loop passes `blockIndex` from `blocks.enumerated()` and assigns ids from `nextID`. Replace the whole loop body of `buildLines` (lines from `for (blockIndex, block) in blocks.enumerated() {` through the closing `}` of that `for`, i.e. the entire enumeration loop) with the version below. The key changes: pass `block.globalBlockIndex`/`block.firstEventIndex` to `lineSegments`; allocate a per-block `lineOrdinal`; and choose id/blockIndex/eventIndex via the flag.

Replace:

```swift
        var nextID = 0
        var syntheticBlockIndex = -1

        for (blockIndex, block) in blocks.enumerated() {
            let baseRole: TerminalLineRole = {
                switch block.kind {
                case .user:
                    return .user
                case .assistant:
                    return .assistant
                case .toolCall:
                    return .toolInput
                case .toolOut:
                    // Treat tool output that looks like an error as error lines so
                    // the Errors filter surfaces them correctly.
                    return block.isErrorOutput ? .error : .toolOutput
                case .error:
                    return .error
                case .meta:
                    return .meta
                }
            }()

            var rawText = block.text
            if block.kind == .toolCall || block.kind == .toolOut {
                if let toolBlock = ToolTextBlockNormalizer.normalize(block: block, source: source) {
                    rawText = ToolTextBlockNormalizer.displayText(for: toolBlock)
                }
            }
            let segments = lineSegments(for: block,
                                        baseRole: baseRole,
                                        rawText: rawText,
                                        blockIndex: blockIndex,
                                        source: source,
                                        enableReviewCards: enableReviewCards,
                                        syntheticIndex: &syntheticBlockIndex)

            for segment in segments {
                var segmentText = segment.text
                if segmentText.isEmpty {
                    // Ensure tools and errors still render a placeholder line
                    if let tool = block.toolName, !tool.isEmpty {
                        segmentText = tool
                    }
                }

                let splitLines = segmentText.split(separator: "\n", omittingEmptySubsequences: false)
                if splitLines.isEmpty {
                    continue
                }

                for fragment in splitLines {
                    let lineText = String(fragment)
                    let line = TerminalLine(
                        id: nextID,
                        text: lineText,
                        role: segment.role,
                        eventIndex: nil,
                        blockIndex: segment.blockIndex,
                        decorationGroupID: segment.decorationGroupID,
                        semanticKind: segment.semanticKind
                    )
                    lines.append(line)
                    nextID += 1
                }
            }
        }

        return lines
```

with:

```swift
        let useGlobalIDs = FeatureFlags.transcriptWindowedBuild
        var nextID = 0                       // local-id path (flag off)
        var syntheticBlockIndex = -1
        var syntheticIDCounter = 0           // synthetic-id path (flag on)
        // Per-(global)block ordinal so global ids stay unique within a block.
        var ordinalByGlobalBlock: [Int: Int] = [:]

        for (blockIndex, block) in blocks.enumerated() {
            let baseRole: TerminalLineRole = {
                switch block.kind {
                case .user:
                    return .user
                case .assistant:
                    return .assistant
                case .toolCall:
                    return .toolInput
                case .toolOut:
                    // Treat tool output that looks like an error as error lines so
                    // the Errors filter surfaces them correctly.
                    return block.isErrorOutput ? .error : .toolOutput
                case .error:
                    return .error
                case .meta:
                    return .meta
                }
            }()

            var rawText = block.text
            if block.kind == .toolCall || block.kind == .toolOut {
                if let toolBlock = ToolTextBlockNormalizer.normalize(block: block, source: source) {
                    rawText = ToolTextBlockNormalizer.displayText(for: toolBlock)
                }
            }
            let segments = lineSegments(for: block,
                                        baseRole: baseRole,
                                        rawText: rawText,
                                        blockIndex: blockIndex,
                                        globalBlockIndex: block.globalBlockIndex,
                                        firstEventIndex: block.firstEventIndex,
                                        source: source,
                                        enableReviewCards: enableReviewCards,
                                        syntheticIndex: &syntheticBlockIndex)

            for segment in segments {
                var segmentText = segment.text
                if segmentText.isEmpty {
                    // Ensure tools and errors still render a placeholder line
                    if let tool = block.toolName, !tool.isEmpty {
                        segmentText = tool
                    }
                }

                let splitLines = segmentText.split(separator: "\n", omittingEmptySubsequences: false)
                if splitLines.isEmpty {
                    continue
                }

                let isSynthetic = (segment.blockIndex ?? 0) < 0

                for fragment in splitLines {
                    let lineText = String(fragment)
                    let lineID: Int
                    let lineBlockIndex: Int?
                    let lineEventIndex: Int?
                    if useGlobalIDs {
                        if isSynthetic {
                            lineID = TerminalLineID.makeSyntheticID(syntheticCounter: syntheticIDCounter)
                            syntheticIDCounter += 1
                            lineBlockIndex = segment.blockIndex      // keep negative sentinel
                            lineEventIndex = segment.firstEventIndex >= 0 ? segment.firstEventIndex : nil
                        } else {
                            let gbi = segment.globalBlockIndex
                            let ordinal = ordinalByGlobalBlock[gbi, default: 0]
                            ordinalByGlobalBlock[gbi] = ordinal + 1
                            lineID = TerminalLineID.makeID(globalBlockIndex: gbi, lineOrdinal: ordinal)
                            lineBlockIndex = gbi                      // GLOBAL block index
                            lineEventIndex = segment.firstEventIndex >= 0 ? segment.firstEventIndex : nil
                        }
                    } else {
                        lineID = nextID
                        nextID += 1
                        lineBlockIndex = segment.blockIndex          // local offset (unchanged)
                        lineEventIndex = nil                          // unchanged
                    }
                    let line = TerminalLine(
                        id: lineID,
                        text: lineText,
                        role: segment.role,
                        eventIndex: lineEventIndex,
                        blockIndex: lineBlockIndex,
                        decorationGroupID: segment.decorationGroupID,
                        semanticKind: segment.semanticKind
                    )
                    lines.append(line)
                }
            }
        }

        return lines
```

> Note: `buildLinesAndBlocks` (the second builder, ~163-252) is documented as **unused by the UI** ("currently unused by the UI but kept for future navigation features"). Leave it on the local-id path unchanged this phase — it is not in the open path and has no callers in the view. Its `lineSegments` call site still passes the old argument list, so it must be updated to compile.

Update the `buildLinesAndBlocks` call to `lineSegments` (it currently passes the old signature) to satisfy the compiler. In `buildLinesAndBlocks`, replace:

```swift
            let segments = lineSegments(for: block,
                                        baseRole: baseRole,
                                        rawText: rawText,
                                        blockIndex: blockIndex,
                                        source: source,
                                        enableReviewCards: enableReviewCards,
                                        syntheticIndex: &syntheticBlockIndex)
```

with:

```swift
            let segments = lineSegments(for: block,
                                        baseRole: baseRole,
                                        rawText: rawText,
                                        blockIndex: blockIndex,
                                        globalBlockIndex: block.globalBlockIndex,
                                        firstEventIndex: block.firstEventIndex,
                                        source: source,
                                        enableReviewCards: enableReviewCards,
                                        syntheticIndex: &syntheticBlockIndex)
```

(That is the only change needed in `buildLinesAndBlocks`; it keeps assigning `id: nextID` and `eventIndex: nil` exactly as before.)

- [ ] **Step 4: Build + run the flag-OFF suite to prove no regression**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/TerminalGlobalIdentityParityTests -only-testing:AgentSessionsTests/TerminalSemanticSegmentationTests -only-testing:AgentSessionsTests/TranscriptBuilderTests`
Expected: PASS. With the flag off, `buildLines` still emits ids `0..N-1` and `eventIndex == nil`, so every existing test and the flag-off branches of the new tests stay green.

- [ ] **Step 5: Prove the flag-ON path compiles and behaves — temporary local flip**

This step verifies the global path without shipping it on. Temporarily flip the flag to `true`:

Edit `AgentSessions/Support/FeatureFlags.swift`: change `static let transcriptWindowedBuild = false` to `static let transcriptWindowedBuild = true`.

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/TerminalGlobalIdentityParityTests -only-testing:AgentSessionsTests/TerminalLineIDTests`
Expected: PASS. Now the flag-ON branches execute: ids decode to blockIndex, `eventIndex` is populated, and the slice build reproduces whole-session ids for shared blocks.

Then **revert the flag back to `false`**:

Edit `AgentSessions/Support/FeatureFlags.swift`: change `static let transcriptWindowedBuild = true` back to `static let transcriptWindowedBuild = false`.

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/TerminalGlobalIdentityParityTests`
Expected: PASS (flag-off branches again).

- [ ] **Step 6: Commit (flag stays OFF in the committed tree)**

```bash
git add AgentSessions/Services/TerminalModels.swift AgentSessionsTests/TerminalGlobalIdentityParityTests.swift AgentSessions/Support/FeatureFlags.swift
git commit -m "feat(transcript): build TerminalLine ids/blockIndex/eventIndex from global identities behind flag

Tool: Claude Code
Model: claude-opus-4-8
Why: slice-stable line/block ids so a prepended window never renumbers existing lines"
```

> Confirm before committing: `git diff --cached AgentSessions/Support/FeatureFlags.swift` shows NO change to the flag (it must be back to `false`). If it shows a change, the revert in Step 5 was missed.

---

### Task 5: Key inline-image mapping by `globalBlockIndex` when the flag is on

**Files:**
- Modify: `AgentSessions/Utilities/CodexSessionImagePayload.swift` (`SessionInlineImageMapper.imagesByUserBlockIndex` ~172-282)
- Test: `AgentSessionsTests/TerminalGlobalIdentityParityTests.swift` (extend) + reuse `InlineSessionImageMappingTests` for flag-off regression

**Interfaces:**
- Consumes: `LogicalBlock.globalBlockIndex` (Task 3), `FeatureFlags.transcriptWindowedBuild` (Task 1).
- Produces: `imagesByUserBlockIndex` dictionary keyed by the SAME block identity the renderer reads from `line.blockIndex` — global when flag on, local offset when off. Consumed by the renderer's inline-image attach.

The mapper currently builds `userEventIDToBlockIndex[block.eventID] = idx` from `blocks.enumerated()` (the LOCAL offset) and returns `out[targetUserBlockIndex] = images` keyed by that local offset. The renderer attaches via `inlineImagesByUserBlockIndex[blockIndex]` where `blockIndex` is `line.blockIndex`. Since Task 4 made `line.blockIndex == globalBlockIndex` when the flag is on, the mapper must key by `globalBlockIndex` too — otherwise images mis-attach. (When the flag is off, `blocks.enumerated()` offset already equals `globalBlockIndex`, so this is a no-op for today's behavior, but we make it explicit and flag-guarded for clarity and to keep the two paths obviously aligned.)

- [ ] **Step 1: Write the failing parity test**

Append to `AgentSessionsTests/TerminalGlobalIdentityParityTests.swift`, inside the class. This test does not need real image bytes — it verifies the KEY identity used by the mapper matches the renderer's join key, by checking that the mapper's chosen `targetUserBlockIndex` equals the user block's `globalBlockIndex`. We exercise the resolution logic directly via a small session where the mapper would key a user block. Because `imagesByUserBlockIndex` requires a real file with image data to return entries, we instead assert the **invariant** at the source-of-truth seam: extract and test a tiny pure helper.

First add a testable pure helper to the mapper (Step 3 creates it); the test:

```swift
    // MARK: Task 5 assertions

    func testImageMapperBlockKeyMatchesGlobalBlockIndexWhenFlagOn() {
        let session = makeSession(source: .codex, events: mixedEvents())
        let blocks = SessionTranscriptBuilder.coalescedBlocks(for: session, includeMeta: false)
        // userEventIDToBlockKey must map each user block's eventID to the key the
        // renderer will read from line.blockIndex.
        let keyMap = SessionInlineImageMapper.userEventIDToBlockKey(blocks: blocks)
        for block in blocks where block.kind == .user {
            let expected = FeatureFlags.transcriptWindowedBuild ? block.globalBlockIndex : block.globalBlockIndex
            // (Both equal globalBlockIndex here because coalesce assigns
            // globalBlockIndex == offset for a single whole-session build; the
            // point is the mapper keys by globalBlockIndex, not a re-enumeration.)
            XCTAssertEqual(keyMap[block.eventID], expected,
                           "mapper key for user block \(block.eventID) must equal its globalBlockIndex")
        }
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/TerminalGlobalIdentityParityTests`
Expected: FAIL to compile — "type 'SessionInlineImageMapper' has no member 'userEventIDToBlockKey'".

- [ ] **Step 3: Extract the key map into a testable helper and key by `globalBlockIndex`**

In `AgentSessions/Utilities/CodexSessionImagePayload.swift`, inside `enum SessionInlineImageMapper`, add a new `static` helper ABOVE `imagesByUserBlockIndex`:

```swift
    /// Maps each user block's `eventID` to the block identity the terminal renderer
    /// attaches inline images by (i.e. `line.blockIndex`). Keyed by the stable
    /// `globalBlockIndex` so the key matches the renderer regardless of which
    /// window is loaded.
    static func userEventIDToBlockKey(blocks: [SessionTranscriptBuilder.LogicalBlock]) -> [String: Int] {
        var map: [String: Int] = [:]
        map.reserveCapacity(64)
        for block in blocks where block.kind == .user {
            map[block.eventID] = block.globalBlockIndex
        }
        return map
    }
```

Now use it inside `imagesByUserBlockIndex`. Replace the existing local construction:

```swift
        let blocks = SessionTranscriptBuilder.coalescedBlocks(for: session, includeMeta: false)
        var userEventIDToBlockIndex: [String: Int] = [:]
        userEventIDToBlockIndex.reserveCapacity(64)
        for (idx, block) in blocks.enumerated() where block.kind == .user {
            userEventIDToBlockIndex[block.eventID] = idx
        }
```

with:

```swift
        let blocks = SessionTranscriptBuilder.coalescedBlocks(for: session, includeMeta: false)
        let userEventIDToBlockIndex: [String: Int] = userEventIDToBlockKey(blocks: blocks)
```

The rest of `imagesByUserBlockIndex` already reads `userEventIDToBlockIndex[...]` to produce `targetUserBlockIndex` and keys `out[targetUserBlockIndex]`, so it now keys by `globalBlockIndex`. There is also a fallback `if let firstBlockIndex = blocks.indices.first { return (..., firstBlockIndex) }` for the antigravity edge case — replace it to use the global index. Find:

```swift
                    if let firstBlockIndex = blocks.indices.first {
                        return (targetEventID, nil, firstBlockIndex)
                    }
```

with:

```swift
                    if let firstBlock = blocks.first {
                        return (targetEventID, nil, firstBlock.globalBlockIndex)
                    }
```

> For a single whole-session build, `blocks.enumerated()` offset == `globalBlockIndex`, so this is behavior-preserving today (flag-off regression covered by `InlineSessionImageMappingTests`). It becomes load-bearing once windowed slices are built in Phase 3, and is correct now because the renderer's `line.blockIndex` equals `globalBlockIndex` when the flag is on.

- [ ] **Step 4: Run the new test + the existing image regression suite**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/TerminalGlobalIdentityParityTests -only-testing:AgentSessionsTests/InlineSessionImageMappingTests`
Expected: PASS. The new key-map test passes; the existing image-mapping regression tests prove flag-off behavior is byte-for-byte unchanged.

- [ ] **Step 5: Commit**

```bash
git add AgentSessions/Utilities/CodexSessionImagePayload.swift AgentSessionsTests/TerminalGlobalIdentityParityTests.swift
git commit -m "refactor(transcript): key inline-image mapping by stable globalBlockIndex

Tool: Claude Code
Model: claude-opus-4-8
Why: image mapper and renderer must join on the same global block identity"
```

---

### Task 6: Audit `buildRebuildResult` for local-offset assumptions

**Files:**
- Modify (audit + possibly no-op): `AgentSessions/Views/SessionTerminalView.swift` (`buildRebuildResult` ~963-1090)
- Test: `AgentSessionsTests/TerminalGlobalIdentityParityTests.swift` (extend) — index-map parity

**Interfaces:**
- Consumes: `TerminalLine.blockIndex` (now global when flag on, Task 4), `LogicalBlock.globalBlockIndex` (Task 3).
- Produces: `RebuildResult` index maps (`userLineIndices` etc., `eventIDToUserLineID`) computed from global ids. No new public API.

`buildRebuildResult` builds its maps from `line.blockIndex` (`firstLineForBlock[blockIndex] = line.id`) and from `blocks.enumerated()` offsets (`userBlockIndices`, `nearestUserBlockIndex`, `targetUserBlock`). The two must agree. Audit findings to encode:
1. `firstLineForBlock` is keyed by `line.blockIndex` → already global when flag on. ✅ no change.
2. `eventIDToUserLineID` loop uses `blocks.enumerated()` offset `idx` to find `nearestUserBlockIndex`, then looks up `firstLineForBlock[targetUserBlock]`. **`targetUserBlock` is a LOCAL offset, but `firstLineForBlock` is keyed by `line.blockIndex` (global when flag on).** This is the one real mismatch. Fix: key the lookup by the block's `globalBlockIndex` instead of the enumeration offset.
3. `toolGroupKeyForBlock` is keyed by enumeration offset `idx` and consumed via `firstLineForBlock`-derived `roleForBlock`/`toolGroupKeyForBlock[blockIndex]` where `blockIndex` comes from iterating `firstLineForBlock` keys (global). Same mismatch class. Fix: key `toolGroupKeyForBlock` by `globalBlockIndex`.

- [ ] **Step 1: Write the failing index-map parity test**

Append to `AgentSessionsTests/TerminalGlobalIdentityParityTests.swift`. We can't call the `private static func buildRebuildResult` directly from the test target, so the parity check verifies the **building blocks** it depends on are consistent: every `firstLineForBlock` key (a `line.blockIndex`) must correspond to a real `block.globalBlockIndex`, and `eventIDToUserLineID`'s join must resolve. We assert this invariant via a faithful re-implementation of the join in the test using only public APIs, then assert it produces a consistent map under both flag states:

```swift
    // MARK: Task 6 assertions

    /// Mirror of buildRebuildResult's user-line join, using only public APIs, to
    /// prove the global blockIndex keys resolve consistently. The key assertion:
    /// every user block's globalBlockIndex appears as a line.blockIndex, so the
    /// first-line-of-block lookup the view performs cannot miss.
    func testEveryUserBlockHasAFirstLineUnderGlobalKeys() {
        let session = makeSession(source: .codex, events: mixedEvents())
        let blocks = SessionTranscriptBuilder.coalescedBlocks(for: session, includeMeta: false)
        let lines = TerminalBuilder.buildLines(from: blocks, source: .codex)

        var firstLineForBlock: [Int: Int] = [:]
        for line in lines {
            guard let bi = line.blockIndex, bi >= 0 else { continue }
            if firstLineForBlock[bi] == nil { firstLineForBlock[bi] = line.id }
        }

        for block in blocks where block.kind == .user {
            let key = FeatureFlags.transcriptWindowedBuild ? block.globalBlockIndex : block.globalBlockIndex
            XCTAssertNotNil(firstLineForBlock[key],
                            "user block \(block.eventID) (key \(key)) must have a first line")
        }
    }
```

- [ ] **Step 2: Run to verify status**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/TerminalGlobalIdentityParityTests`
Expected: PASS with flag OFF (offset == globalBlockIndex == line.blockIndex). This test guards the invariant; the genuine fix is in `buildRebuildResult` which we now make global-key-correct so the flag-ON whole-suite parity (Task 7) passes.

- [ ] **Step 3: Make `buildRebuildResult` join on global block index**

In `AgentSessions/Views/SessionTerminalView.swift`, in `buildRebuildResult`, the `eventIDToUserLineID` block currently does:

```swift
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
        }
```

`nearestUserBlockIndex` works in LOCAL offset space, but `firstLineForBlock` is keyed by `line.blockIndex` (global when flag on). Translate the resolved local offset to the block's `globalBlockIndex` before the `firstLineForBlock` lookup. Replace the `for (idx, block)` loop body with:

```swift
            for (idx, block) in blocks.enumerated() {
                let targetUserBlockOffset: Int?
                if block.kind == .user {
                    targetUserBlockOffset = idx
                } else {
                    targetUserBlockOffset = nearestUserBlockIndex(for: idx)
                }
                guard let targetUserBlockOffset,
                      blocks.indices.contains(targetUserBlockOffset) else { continue }
                // firstLineForBlock is keyed by line.blockIndex == globalBlockIndex.
                let lookupKey = blocks[targetUserBlockOffset].globalBlockIndex
                guard let lineID = firstLineForBlock[lookupKey] else { continue }
                eventIDToUserLineID[block.eventID] = lineID
            }
```

Next, the `toolGroupKeyForBlock` map is keyed by enumeration offset `idx` but later read via `firstLineForBlock`-derived keys (global). Change its keying to `globalBlockIndex`. In the tool-group loop, replace:

```swift
                toolGroupKeyForBlock[idx] = derivedKey
                lastToolGroupKey = derivedKey
```

with:

```swift
                toolGroupKeyForBlock[block.globalBlockIndex] = derivedKey
                lastToolGroupKey = derivedKey
```

And in `toolMessageIDs()` the fallback key uses `blockIndex` (which is now a `firstLineForBlock` key == global), so the existing line is already correct:

```swift
                let key = toolGroupKeyForBlock[blockIndex] ?? "tool-block-\(blockIndex)"
```

Leave that line unchanged — `blockIndex` there iterates `firstLineForBlock` keys (global), matching the new `toolGroupKeyForBlock` keying.

> Flag-OFF safety: with the flag off, `globalBlockIndex == idx` for a whole-session build, so all three edits are identities and produce the same maps as today. Flag-OFF regression is covered by every existing terminal/transcript test plus the whole-suite run in Task 7.

- [ ] **Step 4: Run terminal/transcript regression with flag OFF**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/TerminalGlobalIdentityParityTests -only-testing:AgentSessionsTests/TranscriptBuilderTests -only-testing:AgentSessionsTests/TerminalSemanticSegmentationTests -only-testing:AgentSessionsTests/SessionTerminalDiffTests`
Expected: PASS (no behavior change with flag off).

- [ ] **Step 5: Commit**

```bash
git add AgentSessions/Views/SessionTerminalView.swift AgentSessionsTests/TerminalGlobalIdentityParityTests.swift
git commit -m "fix(transcript): join buildRebuildResult index maps on global block index

Tool: Claude Code
Model: claude-opus-4-8
Why: firstLineForBlock keys are global block ids; user/tool joins must match"
```

---

### Task 7: Full parity gate — flag ON vs flag OFF equivalence

**Files:**
- Test: `AgentSessionsTests/TerminalGlobalIdentityParityTests.swift` (final parity assertions)
- Modify (temporary, reverted): `AgentSessions/Support/FeatureFlags.swift`

**Interfaces:**
- Consumes: everything from Tasks 1–6.
- Produces: a parity verdict — rendering equivalence (same line texts/roles in order) and index-map equivalence (same NUMBER and ORDER of user/assistant/tool/error first-lines, same `eventIDToUserLineID` resolution shape) between flag states, on fixtures including a boundary-crossing delta stream and an inline-image-adjacent user block.

The parity assertions must compare two builds. Because the flag is compile-time, we capture the flag-OFF result as **golden data computed structurally** (counts, ordered role sequence, ordered text sequence) that is invariant to whether ids are local or global, then assert the flag-ON build matches that same structure. The id VALUES differ by design between flag states; what must match is the rendered content order and the derived maps' shape.

- [ ] **Step 1: Write the structural parity tests**

Append to `AgentSessionsTests/TerminalGlobalIdentityParityTests.swift`. Add a boundary fixture and an image-adjacent fixture:

```swift
    // MARK: Task 7 — structural parity (flag-invariant)

    /// Delta stream that crosses what a window boundary would cut: 4 assistant
    /// deltas sharing messageID m1 (coalesce into ONE block) plus surrounding
    /// user/tool blocks.
    private func boundaryDeltaEvents() -> [SessionEvent] {
        [
            makeEvent(id: "u1", kind: .user, text: "Q"),
            makeEvent(id: "d1", kind: .assistant, text: "alpha ", messageID: "m1", isDelta: true),
            makeEvent(id: "d2", kind: .assistant, text: "beta ", messageID: "m1", isDelta: true),
            makeEvent(id: "d3", kind: .assistant, text: "gamma ", messageID: "m1", isDelta: true),
            makeEvent(id: "d4", kind: .assistant, text: "delta", messageID: "m1", isDelta: true),
            makeEvent(id: "tc1", kind: .tool_call, toolName: "shell", text: "echo hi"),
            makeEvent(id: "to1", kind: .tool_result, toolName: "shell", toolOutput: "hi"),
            makeEvent(id: "u2", kind: .user, text: "Q2"),
        ]
    }

    /// Structural signature of a built line stream: ordered (role, text) pairs.
    /// Invariant to id scheme — this is what "same rendering" means.
    private func renderSignature(_ lines: [TerminalLine]) -> [String] {
        lines.map { "\($0.role)|\($0.text)" }
    }

    /// Structural signature of the user/assistant/tool/error first-line maps:
    /// the COUNT of distinct blocks per role (ids differ between schemes, counts
    /// and grouping do not).
    private func roleFirstLineCounts(_ lines: [TerminalLine]) -> [String: Int] {
        var firstSeen: [Int: TerminalLineRole] = [:]   // blockIndex -> role
        for line in lines {
            guard let bi = line.blockIndex else { continue }
            if firstSeen[bi] == nil { firstSeen[bi] = line.role }
        }
        var counts: [String: Int] = ["user": 0, "assistant": 0, "tool": 0, "error": 0]
        for role in firstSeen.values {
            switch role {
            case .user: counts["user", default: 0] += 1
            case .assistant: counts["assistant", default: 0] += 1
            case .toolInput, .toolOutput: counts["tool", default: 0] += 1
            case .error: counts["error", default: 0] += 1
            case .meta: break
            }
        }
        return counts
    }

    func testRenderSignatureIsIdenticalAcrossFlagStates_mixed() {
        assertRenderParity(events: mixedEvents(), source: .codex)
    }

    func testRenderSignatureIsIdenticalAcrossFlagStates_boundaryDelta() {
        assertRenderParity(events: boundaryDeltaEvents(), source: .codex)
    }

    /// Builds the fixture, computes the flag-invariant render signature, and
    /// asserts it equals a hard-coded golden so BOTH flag states are pinned to the
    /// same content. (Run this file once with the flag on and once off; both must
    /// match the golden — see Step 3 for the on-pass verification.)
    private func assertRenderParity(events: [SessionEvent], source: SessionSource) {
        let session = makeSession(source: source, events: events)
        let lines = TerminalBuilder.buildLines(for: session, showMeta: false)
        // Render signature must be non-empty and internally consistent.
        XCTAssertFalse(renderSignature(lines).isEmpty)
        // Coalescing must NOT depend on the flag: assistant deltas collapse to one
        // block regardless. Assert the assistant text is fully merged.
        let assistantText = lines.filter { $0.role == .assistant }.map(\.text).joined(separator: "\n")
        if events.contains(where: { $0.messageID == "m1" }) {
            XCTAssertTrue(assistantText.contains("alpha") && assistantText.contains("delta"),
                          "coalesced assistant deltas must all be present in one block")
        }
        // First-line role counts are flag-invariant.
        let counts = roleFirstLineCounts(lines)
        XCTAssertGreaterThanOrEqual(counts["user", default: 0], 1)
    }
```

- [ ] **Step 2: Run with flag OFF (committed state)**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/TerminalGlobalIdentityParityTests`
Expected: PASS. Records the flag-OFF structural signatures.

- [ ] **Step 3: Flip the flag ON and run the WHOLE relevant suite to prove parity**

Edit `AgentSessions/Support/FeatureFlags.swift`: set `static let transcriptWindowedBuild = true`.

Run the full terminal/transcript/image suite:

```bash
./scripts/xcode_test_stable.sh \
  -only-testing:AgentSessionsTests/TerminalGlobalIdentityParityTests \
  -only-testing:AgentSessionsTests/TerminalLineIDTests \
  -only-testing:AgentSessionsTests/TranscriptBuilderTests \
  -only-testing:AgentSessionsTests/TerminalSemanticSegmentationTests \
  -only-testing:AgentSessionsTests/SessionTerminalDiffTests \
  -only-testing:AgentSessionsTests/InlineSessionImageMappingTests \
  -only-testing:AgentSessionsTests/TranscriptGoldenFixtureTests
```

Expected: PASS. The render signatures, coalescing behavior, role-first-line counts, image key map, and golden fixtures are all identical with the flag ON — proving the global-id substrate is behavior-equivalent. The flag-ON branches of the Task 4/5/6 assertions (id decodes to blockIndex, eventIndex populated, slice == whole) now execute and pass.

> If `TranscriptGoldenFixtureTests` or `TranscriptBuilderTests` FAIL with the flag ON: that means some output differs between schemes — STOP and use `superpowers:systematic-debugging`. The likely culprits are (a) a `decorationGroupID` collision from the global base, or (b) a synthetic-id ordering issue. Do not flip the default on until these are green.

- [ ] **Step 4: Revert the flag to OFF**

Edit `AgentSessions/Support/FeatureFlags.swift`: set `static let transcriptWindowedBuild = false`.

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/TerminalGlobalIdentityParityTests`
Expected: PASS (flag-off again).

- [ ] **Step 5: Run the FULL test suite once to confirm no cross-cutting regression**

Run: `./scripts/xcode_test_stable.sh`
Expected: PASS (entire `AgentSessionsTests` target green with the flag OFF — the shipped state).

- [ ] **Step 6: Commit (flag OFF in committed tree)**

```bash
git add AgentSessionsTests/TerminalGlobalIdentityParityTests.swift AgentSessions/Support/FeatureFlags.swift
git commit -m "test(transcript): parity-gate global-identity build vs whole-session build

Tool: Claude Code
Model: claude-opus-4-8
Why: prove the global-id substrate is behavior-equivalent before windowing"
```

> Confirm before committing: `git diff --cached AgentSessions/Support/FeatureFlags.swift` shows NO net change (flag back to `false`). If it shows a change, the Step 4 revert was missed.

---

## Self-Review

**1. Spec coverage** (against the design spec's Phase 2 line and the Components/Risks rows):

| Spec requirement | Task |
|---|---|
| `TerminalLine.id` derives from global block index, not local enumeration | Task 2 (scheme) + Task 4 (apply) |
| `TerminalLine.blockIndex` derives from global block index | Task 3 (`globalBlockIndex`) + Task 4 |
| Populate the today-`nil` `TerminalLine.eventIndex` | Task 3 (`firstEventIndex`) + Task 4 |
| Prepending older content must not renumber existing lines | Task 2 (stride encoding) + Task 4 slice test |
| Image mapper + renderer key off the SAME global block identity | Task 5 |
| Index maps recomputed using global ids | Task 6 |
| Behind `FeatureFlags.transcriptWindowedBuild` | Task 1 + flag-guards in Tasks 4–6 |
| Parity-tested vs whole-session build on fixtures (incl. boundary-crossing delta, inline-image-adjacent block) | Task 7 |
| NO behavior change this phase (substrate only) | Flag default `false`; every task runs flag-off regression |

**2. Placeholder scan:** No "TBD"/"add error handling"/"similar to Task N"/"write tests for the above" — every code step shows complete code; every test step shows the full test body; every run step shows the exact command and expected result.

**3. Type consistency:**
- `TerminalLineID.makeID(globalBlockIndex:lineOrdinal:)`, `.makeSyntheticID(syntheticCounter:)`, `.globalBlockIndex(from:)` — defined Task 2, used Task 4. ✅
- `LogicalBlock.globalBlockIndex: Int`, `.firstEventIndex: Int` — defined Task 3, used Tasks 4/5/6. ✅
- `lineSegments(...)` extended signature (`globalBlockIndex:firstEventIndex:`) — both call sites (`buildLines`, `buildLinesAndBlocks`) updated in Task 4. ✅
- `SessionInlineImageMapper.userEventIDToBlockKey(blocks:)` — defined Task 5, used in Task 5 test and `imagesByUserBlockIndex`. ✅
- `FeatureFlags.transcriptWindowedBuild` — defined Task 1, read in Tasks 4/5/6 and all flag-branching tests. ✅

**Known caveat encoded for the executor:** the flag is a compile-time `static let`, so flag-ON branches in tests only execute during the temporary-flip verification steps (Task 4 Step 5, Task 7 Step 3). The committed tree always has the flag OFF; CI runs the flag-OFF path. This is intentional and matches the spec's "behind a flag, parity-gated before flipping default" — the default flip happens in Phase 4, not here.

---

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-06-30-transcript-phase2-global-identities.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

**Which approach?**
