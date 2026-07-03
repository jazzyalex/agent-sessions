# Perf "Instant UI" Revised Master Plan (post-Fable-review)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every dominant Agent Sessions action feel instant — transcript open < 150 ms to first content, sort ≈ 0.2 s, idle near-zero CPU — by first removing two accidental quadratics in the transcript build path, then landing a two-stage transcript open (windowed first paint + gated full-build swap), plus targeted sort/HUD quick wins.

**Architecture:** This plan integrates the independent architecture review (`docs/perf-fable-review.md`) into the existing windowed-build program. Workstream 0 fixes superlinear hot spots that inflate the measured 30 s monster build (copy-on-write string append in the coalescer; an O(blocks × userBlocks) anchor scan in the rebuild index maps). Workstream 1 amends transcript Phase 3: on open, build only the last window of whole coalesced blocks (first paint), then continue the full build off-main and swap it in **only under a character threshold** — above it, the window remains the operating regime and the existing Phase 3 Tasks 6–8 (loadOlder prepend) stay the path to older content. Workstream 4/HUD are contained quick wins on profiled residuals. Larger redesigns (FTS ingest + parse checkpoints, presence actor, NSTableView list) are gated follow-on plans, listed at the end with their triggers.

**Tech Stack:** Swift 5, SwiftUI + AppKit (`NSTextView`/TextKit 1), XCTest, SQLite (FTS5), `os_signpost` perf spans (`Perf.begin/end`), self-driving DEBUG bench harness (`AS_PERF_BENCH`).

## Global Constraints

- Everything transcript-windowing-related stays behind `FeatureFlags.transcriptWindowedBuild` (default `false`), parity-gated. Workstream 0 fixes are flag-independent (they change no observable output, only cost).
- **Commits:** Conventional Commits with trailers `Tool: Claude Code` / `Model: claude-fable-5` / `Why: <reason>`. No co-author, no "Generated with" footer. **Do not run `git commit`/`git push` unless the user explicitly asks** — each task's Commit step stages the message for the user; run it only on their say-so. (CLAUDE.md.)
- **New Swift files** must be added to the Xcode project:
  `LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 ./scripts/xcode_add_file.rb AgentSessions.xcodeproj <TARGET> <path> <group>`
  App-target files → target `AgentSessions`; test files → target `AgentSessionsTests`. Watch the known duplicate-file-reference gotcha: if the script reports the file already referenced, do not add it twice.
- **Tests** run via `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/<ClassName>` (full suite: no `-only-testing`).
- No branch/worktree creation without explicit user approval; work on the current branch (`perf/search-quick-wins`).
- Perf claims require evidence: every "faster" claim in this plan has a measurement step; record numbers in `docs/perf-master-plan.md` (Task 4).

---

## Roadmap and existing-document status

Execution order: Tasks 1→4 (Workstream 0, do first — they change downstream economics), Tasks 5–7 (independent quick wins, any order, parallelizable), Tasks 8–9 (Workstream 1, transcript open). Deferred workstreams follow at the end.

| Existing doc | Status under this plan |
|---|---|
| `docs/perf-master-plan.md` | Priority order **superseded** by this plan (pointer added in Task 4). |
| `plans/2026-06-30-transcript-phase2-global-identities.md` | **Done, unchanged.** Its global-ID substrate is what makes Task 9's swap possible. |
| `plans/2026-06-30-transcript-phase3-windowed-build.md` Tasks 1–3 | **Done, unchanged** (flag, `TranscriptWindow`, slice `buildLines`). |
| Phase 3 Tasks 4–5 (open with window, window state) | **Superseded** by Tasks 8–9 here (two-stage open subsumes them). |
| Phase 3 Tasks 6–8 (loadOlder prepend, scroll anchor, parity/QA) | **Retained, demoted** to the over-threshold (monster) tier; execute per that doc **after** Task 9 lands. |
| `plans/2026-06-30-transcript-phase4-find-jump.md` | **Retained, re-scoped after Task 9:** under-threshold sessions get whole-session Find for free post-swap; the window-paging Find machinery is needed only for the over-threshold tier. Re-evaluate scope before starting. |
| `plans/2026-06-30-transcript-phase5-parse-windowing.md` | **Superseded** by deferred Workstream 2 (ingest + event-offset checkpoints); do not execute as written. |

A deliberate deviation from the review (`docs/perf-fable-review.md` §1.2): the review proposed swapping the full build in for *all* sessions. Apply cost (attributed-string build + `setAttributedString` + layout on the main thread) scales with total characters regardless of where the model build ran, so an unconditional swap would reintroduce a multi-second main-thread stall on monsters. Hence the `transcriptFullSwapMaxChars` gate in Task 9, and the retention of Phase 3 Tasks 6–8 for the tier above it.

A deliberate exclusion: the review's "normalize-once" micro-optimization (`ToolTextBlockNormalizer.normalize` runs in both `buildLines` and the rebuild's tool-group-key loop) is **not** in this plan — deduplicating it means threading normalizer output through `buildLines`' signature, which risks the Phase 2/3 parity surface for a minor win. Revisit only if Task 4's post-fix profile still shows it.

---

### Task 1: Coalescer delta-merge — remove the copy-on-write quadratic

`SessionTranscriptBuilder.coalesce` merges delta chains via `var merged = last; merged.text += b.text; blocks.removeLast(); blocks.append(merged)`. At the moment of the append, `blocks.last` still references the same string buffer, so copy-on-write duplicates the entire accumulated text on every delta — O(chain²) bytes for a k-delta chain. Mutating the array element in place keeps the buffer uniquely referenced → amortized O(1) append.

**Files:**
- Create: `AgentSessionsTests/PerfQuickWinsTests.swift`
- Modify: `AgentSessions/Services/SessionTranscriptBuilder.swift:488-498`

**Interfaces:**
- Consumes: `SessionTranscriptBuilder.coalescedBlocks(for:includeMeta:)` (public, unchanged signature).
- Produces: no interface change; identical output, linear cost. Later tasks (3, 8, 9) assume coalesce is cheap.

- [ ] **Step 1: Create the test file with shared fixtures and the failing perf canary**

Create `AgentSessionsTests/PerfQuickWinsTests.swift`:

```swift
import XCTest
@testable import AgentSessions

final class PerfQuickWinsTests: XCTestCase {

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

    private func toolResultEvent(_ id: String, output: String, toolName: String = "shell") -> SessionEvent {
        SessionEvent(id: id, timestamp: nil, kind: .tool_result, role: "tool", text: nil,
                     toolName: toolName, toolInput: nil, toolOutput: output,
                     messageID: "t-\(id)", parentID: nil, isDelta: false, rawJSON: "{}")
    }

    private func session(_ events: [SessionEvent]) -> Session {
        Session(id: "s-perf", source: .codex, startTime: nil, endTime: nil,
                model: "test", filePath: "/tmp/perf.jsonl", fileSizeBytes: nil,
                eventCount: events.count, events: events)
    }

    // MARK: - Task 1: coalescer delta-merge must be linear, not CoW-quadratic

    func testCoalesceLongDeltaChainIsLinearAndLossless() {
        let chunk = String(repeating: "x", count: 200)
        var events: [SessionEvent] = []
        events.reserveCapacity(20_000)
        for i in 0..<20_000 {
            events.append(assistantDelta("a-\(i)", chunk, messageID: "m-single"))
        }
        let s = session(events)

        let start = Date()
        let blocks = SessionTranscriptBuilder.coalescedBlocks(for: s, includeMeta: false)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(blocks.count, 1, "one merge chain must coalesce to one block")
        XCTAssertEqual(blocks[0].text.utf8.count, 20_000 * 200, "no bytes lost in merge")
        XCTAssertEqual(blocks[0].globalBlockIndex, 0)
        XCTAssertEqual(blocks[0].firstEventIndex, 0)
        // Quadratic CoW copies ~40 GB here (minutes); linear is milliseconds.
        XCTAssertLessThan(elapsed, 2.0,
            "coalescing a long delta chain must be linear (CoW append was quadratic)")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails (or times out) on current code**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/PerfQuickWinsTests 2>&1 | tail -20`
Expected: build fails first because the file isn't in the project — add it:
`LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 ./scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessionsTests AgentSessionsTests/PerfQuickWinsTests.swift AgentSessionsTests`
Re-run. Expected: `testCoalesceLongDeltaChainIsLinearAndLossless` FAILS on the 2.0 s assertion (or hangs → reduce to 5_000 events to see the failure quickly, then restore 20_000).

- [ ] **Step 3: Fix the merge to mutate in place**

In `AgentSessions/Services/SessionTranscriptBuilder.swift`, replace the merge branch inside `coalesce(events:source:includeMeta:)` (currently lines 488–503):

```swift
                // Merge in place: taking a copy of `blocks.last` and appending to it
                // makes the accumulated text buffer multiply-referenced, so every
                // delta append triggers a full CoW copy (quadratic in chain length).
                var mergeWithLast = false
                if let last = blocks.last {
                    mergeWithLast = canMerge(last, b)
                }
                if mergeWithLast {
                    let i = blocks.count - 1
                    blocks[i].text += b.text
                    if blocks[i].timestamp == nil { blocks[i].timestamp = b.timestamp }
                    blocks[i].rawJSON = b.rawJSON
                    if blocks[i].toolName == nil { blocks[i].toolName = b.toolName }
                    if blocks[i].toolInput == nil { blocks[i].toolInput = b.toolInput }
                    blocks[i].isErrorOutput = blocks[i].isErrorOutput || b.isErrorOutput
                    // firstEventIndex stays the merge chain's FIRST event (already set).
                } else {
                    b.firstEventIndex = eventIndex
                    blocks.append(b)
                }
```

(The `if let last = blocks.last, canMerge(last, b)` form must go: `last` staying in scope during the mutation would keep the buffer multiply-referenced and defeat the fix.)

- [ ] **Step 4: Run the canary and the transcript parity suites**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/PerfQuickWinsTests 2>&1 | tail -10`
Expected: PASS in well under 2 s.
Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/TranscriptWindowedBuildTests -only-testing:AgentSessionsTests/TranscriptBuilderTests 2>&1 | tail -10`
Expected: PASS — merge output byte-identical.

- [ ] **Step 5: Stage the commit (run only on user request)**

```bash
git add AgentSessionsTests/PerfQuickWinsTests.swift AgentSessions/Services/SessionTranscriptBuilder.swift AgentSessions.xcodeproj/project.pbxproj
git commit -m "perf(transcript): make coalescer delta merge linear (in-place append, no CoW copy)

Tool: Claude Code
Model: claude-fable-5
Why: merging via a copied block made every delta append duplicate the accumulated text (O(chain^2) bytes)"
```

---

### Task 2: Cache the error/code-detection regexes (per-event → once)

`textLooksLikeError` compiles two `NSRegularExpression`s per tool-result event (via `parseExitValue`), and `looksLikeLineNumberedSourceDump` evaluates a per-line `.regularExpression` range search that recompiles per call. Pin behavior with tests, then hoist compilation to statics. This is a refactor: the pinning tests pass before and after; the deliverable is unchanged behavior at lower cost.

**Files:**
- Modify: `AgentSessions/Services/SessionTranscriptBuilder.swift:405-439` (`textLooksLikeError`, `parseExitValue`)
- Modify: `AgentSessions/Services/TerminalModels.swift:535-547` (`looksLikeLineNumberedSourceDump`)
- Test: `AgentSessionsTests/PerfQuickWinsTests.swift`

**Interfaces:**
- Consumes: fixtures from Task 1.
- Produces: no interface change.

- [ ] **Step 1: Add behavior-pinning tests**

Append to `PerfQuickWinsTests.swift`:

```swift
    // MARK: - Task 2: error/code detection behavior pins (guard the regex hoist)

    func testToolResultErrorClassificationByExitCodeAndPrefix() {
        let cases: [(output: String, isError: Bool)] = [
            ("exit code: 1\nboom", true),
            ("Exit Code: 0\nfine", false),
            ("exit status 2", true),
            ("[error] failed to fetch", true),
            ("error: no such file", true),
            ("all good\nexit code: 1 mentioned later is ignored", false),
            ("plain output", false)
        ]
        for (output, isError) in cases {
            let s = session([toolResultEvent("t1", output: output)])
            let blocks = SessionTranscriptBuilder.coalescedBlocks(for: s, includeMeta: false)
            XCTAssertEqual(blocks.count, 1)
            XCTAssertEqual(blocks[0].isErrorOutput, isError, "output: \(output)")
        }
    }

    func testReadToolNumberedDumpClassifiedAsCode() {
        let dump = "1\t| import Foundation\n2\t| struct Foo {}\n3\t| // done"
        let s = session([toolResultEvent("t1", output: dump, toolName: "Read")])
        let blocks = SessionTranscriptBuilder.coalescedBlocks(for: s, includeMeta: false)
        let lines = TerminalBuilder.buildLines(from: blocks, source: .codex, enableReviewCards: true)
        XCTAssertFalse(lines.isEmpty)
        XCTAssertTrue(lines.contains { $0.semanticKind == .code },
                      "line-numbered read-tool output must render as a code segment")
    }
```

- [ ] **Step 2: Run to confirm the pins pass on current code**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/PerfQuickWinsTests 2>&1 | tail -10`
Expected: PASS. If a case fails, the expectation is wrong — fix the *test* to match current behavior (this task must not change behavior), and note it.

- [ ] **Step 3: Hoist the regexes**

In `SessionTranscriptBuilder.swift`, replace `parseExitValue` and its call sites in `textLooksLikeError`:

```swift
    private static let exitCodeRegex: NSRegularExpression? =
        try? NSRegularExpression(pattern: "exit code[:\\s]*(-?\\d+)", options: [.caseInsensitive])
    private static let exitStatusRegex: NSRegularExpression? =
        try? NSRegularExpression(pattern: "exit status[:\\s]*(-?\\d+)", options: [.caseInsensitive])

    private static func parseExitValue(from text: String, regex: NSRegularExpression?) -> Int? {
        guard let regex else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges >= 2,
              let valueRange = Range(match.range(at: 1), in: text),
              !valueRange.isEmpty else {
            return nil
        }
        return Int(text[valueRange])
    }
```

and in `textLooksLikeError` change the two calls to:

```swift
        if let code = parseExitValue(from: lower, regex: exitCodeRegex), code != 0 {
            return true
        }
        if let status = parseExitValue(from: lower, regex: exitStatusRegex), status != 0 {
            return true
        }
```

In `TerminalModels.swift`, replace `looksLikeLineNumberedSourceDump` (keep the pattern string byte-identical so matching semantics cannot drift):

```swift
    private static let lineNumberedDumpRegex: NSRegularExpression? =
        try? NSRegularExpression(pattern: "^\\d+\\s*(\\u{2192}|\\||:)\\s", options: [])

    private static func looksLikeLineNumberedSourceDump(_ text: String) -> Bool {
        guard let regex = lineNumberedDumpRegex else { return false }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var matches = 0
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let range = NSRange(line.startIndex..., in: line)
            if regex.firstMatch(in: line, options: [], range: range) != nil {
                matches += 1
                if matches >= 2 { return true }
            }
        }
        return false
    }
```

- [ ] **Step 4: Run the pins + transcript suites**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/PerfQuickWinsTests -only-testing:AgentSessionsTests/TranscriptBuilderTests 2>&1 | tail -10`
Expected: PASS, identical results to Step 2.

- [ ] **Step 5: Stage the commit (run only on user request)**

```bash
git add AgentSessions/Services/SessionTranscriptBuilder.swift AgentSessions/Services/TerminalModels.swift AgentSessionsTests/PerfQuickWinsTests.swift
git commit -m "perf(transcript): cache error/code-detection regexes instead of compiling per event

Tool: Claude Code
Model: claude-fable-5
Why: parseExitValue compiled two NSRegularExpressions per tool_result event during coalesce"
```

---

### Task 3: Replace the O(blocks × userBlocks) user-anchor scan with an O(blocks) sweep

`buildRebuildResult`'s `nearestUserBlockIndex` filters the full `userBlockIndices` array for **every** block ([SessionTerminalView.swift:988-1000](../../AgentSessions/Views/SessionTerminalView.swift)). Extract the anchor computation into a pure, tested helper with identical semantics and linear cost.

**Files:**
- Create: `AgentSessions/Services/TranscriptUserAnchors.swift`
- Modify: `AgentSessions/Views/SessionTerminalView.swift:986-1016`
- Test: `AgentSessionsTests/PerfQuickWinsTests.swift`

**Interfaces:**
- Produces: `TranscriptUserAnchors.anchors(userBlockIndices: [Int], preambleUserBlockIndexes: Set<Int>, blockCount: Int) -> [Int?]` — for each block index, the anchoring user-block index under the exact legacy preference order: last non-preamble user at/before → last user at/before → first non-preamble user after → first user after → nil. Task 8 consumes this indirectly via `buildRebuildResult`.

- [ ] **Step 1: Write the failing parity tests (fast vs verbatim legacy reference)**

Append to `PerfQuickWinsTests.swift`:

```swift
    // MARK: - Task 3: user-anchor sweep parity with the legacy quadratic scan

    /// Verbatim port of the legacy nearestUserBlockIndex closure, used as the oracle.
    private func legacyNearestUserBlockIndex(idx: Int,
                                             userBlockIndices: [Int],
                                             preamble: Set<Int>) -> Int? {
        let prior = userBlockIndices.filter { $0 <= idx }
        if let preferred = prior.last(where: { !preamble.contains($0) }) ?? prior.last {
            return preferred
        }
        let after = userBlockIndices.filter { $0 > idx }
        if let preferred = after.first(where: { !preamble.contains($0) }) ?? after.first {
            return preferred
        }
        return nil
    }

    func testUserAnchorsMatchLegacySemanticsAcrossRandomizedConfigurations() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<50 {
            let blockCount = Int.random(in: 1...80, using: &generator)
            let userBlockIndices = (0..<blockCount).filter { _ in Bool.random(using: &generator) }
            let preamble = Set(userBlockIndices.filter { _ in Bool.random(using: &generator) })

            let fast = TranscriptUserAnchors.anchors(userBlockIndices: userBlockIndices,
                                                     preambleUserBlockIndexes: preamble,
                                                     blockCount: blockCount)
            XCTAssertEqual(fast.count, blockCount)
            for idx in 0..<blockCount {
                XCTAssertEqual(fast[idx],
                               legacyNearestUserBlockIndex(idx: idx,
                                                           userBlockIndices: userBlockIndices,
                                                           preamble: preamble),
                               "idx \(idx), users \(userBlockIndices), preamble \(preamble)")
            }
        }
    }

    func testUserAnchorsEdgeCases() {
        XCTAssertEqual(TranscriptUserAnchors.anchors(userBlockIndices: [],
                                                     preambleUserBlockIndexes: [],
                                                     blockCount: 3),
                       [nil, nil, nil])
        // Block before the first user block anchors forward.
        XCTAssertEqual(TranscriptUserAnchors.anchors(userBlockIndices: [2],
                                                     preambleUserBlockIndexes: [],
                                                     blockCount: 4),
                       [2, 2, 2, 2])
        // Non-preamble prior beats a later preamble prior.
        XCTAssertEqual(TranscriptUserAnchors.anchors(userBlockIndices: [0, 2],
                                                     preambleUserBlockIndexes: [2],
                                                     blockCount: 4),
                       [0, 0, 0, 0])
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/PerfQuickWinsTests 2>&1 | tail -10`
Expected: BUILD FAILURE — `TranscriptUserAnchors` not defined.

- [ ] **Step 3: Implement the helper**

Create `AgentSessions/Services/TranscriptUserAnchors.swift`:

```swift
import Foundation

/// Linear-time replacement for the per-block "nearest user block" scan used by
/// the transcript rebuild index maps. Semantics are pinned to the legacy
/// implementation: prefer the last non-preamble user block at/before the index,
/// then the last user block at/before it, then the first non-preamble user
/// block after it, then the first user block after it.
enum TranscriptUserAnchors {
    static func anchors(userBlockIndices: [Int],
                        preambleUserBlockIndexes: Set<Int>,
                        blockCount: Int) -> [Int?] {
        guard blockCount > 0 else { return [] }
        var result = [Int?](repeating: nil, count: blockCount)

        // Forward: last user at/before idx, preferring non-preamble.
        var u = 0
        var lastUser: Int? = nil
        var lastNonPreamble: Int? = nil
        for idx in 0..<blockCount {
            while u < userBlockIndices.count, userBlockIndices[u] <= idx {
                lastUser = userBlockIndices[u]
                if !preambleUserBlockIndexes.contains(userBlockIndices[u]) {
                    lastNonPreamble = userBlockIndices[u]
                }
                u += 1
            }
            result[idx] = lastNonPreamble ?? lastUser
        }

        // Backward fill for blocks with no user block at/before them: first user
        // after idx, preferring non-preamble.
        var v = userBlockIndices.count - 1
        var firstAfter: Int? = nil
        var firstNonPreambleAfter: Int? = nil
        for idx in stride(from: blockCount - 1, through: 0, by: -1) {
            while v >= 0, userBlockIndices[v] > idx {
                firstAfter = userBlockIndices[v]
                if !preambleUserBlockIndexes.contains(userBlockIndices[v]) {
                    firstNonPreambleAfter = userBlockIndices[v]
                }
                v -= 1
            }
            if result[idx] == nil {
                result[idx] = firstNonPreambleAfter ?? firstAfter
            }
        }
        return result
    }
}
```

Add to project:
`LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 ./scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessions AgentSessions/Services/TranscriptUserAnchors.swift AgentSessions/Services`

- [ ] **Step 4: Run to verify the parity tests pass**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/PerfQuickWinsTests 2>&1 | tail -10`
Expected: PASS.

- [ ] **Step 5: Wire into `buildRebuildResult`**

In `SessionTerminalView.swift`, inside `buildRebuildResult`, replace the block starting `var eventIDToUserLineID: [String: Int] = [:]` through the end of its `for (idx, block) in blocks.enumerated()` loop (currently lines 986–1016) with:

```swift
        var eventIDToUserLineID: [String: Int] = [:]
        if !blocks.isEmpty {
            let userBlockIndices = blocks.enumerated().compactMap { $0.element.kind == .user ? $0.offset : nil }
            let anchors = TranscriptUserAnchors.anchors(userBlockIndices: userBlockIndices,
                                                        preambleUserBlockIndexes: preambleUserBlockIndexes,
                                                        blockCount: blocks.count)

            for (idx, block) in blocks.enumerated() {
                let targetUserBlockOffset: Int? = block.kind == .user ? idx : anchors[idx]
                guard let targetUserBlockOffset,
                      blocks.indices.contains(targetUserBlockOffset) else { continue }
                // firstLineForBlock is keyed by line.blockIndex == globalBlockIndex.
                let lookupKey = blocks[targetUserBlockOffset].globalBlockIndex
                guard let lineID = firstLineForBlock[lookupKey] else { continue }
                eventIDToUserLineID[block.eventID] = lineID
            }
        }
```

- [ ] **Step 6: Run the transcript/terminal suites**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/PerfQuickWinsTests -only-testing:AgentSessionsTests/TranscriptWindowedBuildTests 2>&1 | tail -10`
Expected: PASS. Then run the full suite once: `./scripts/xcode_test_stable.sh 2>&1 | tail -20` — expected all green (~1025 tests).

- [ ] **Step 7: Stage the commit (run only on user request)**

```bash
git add AgentSessions/Services/TranscriptUserAnchors.swift AgentSessions/Views/SessionTerminalView.swift AgentSessionsTests/PerfQuickWinsTests.swift AgentSessions.xcodeproj/project.pbxproj
git commit -m "perf(transcript): O(n) user-anchor sweep replaces per-block quadratic scan in rebuild index maps

Tool: Claude Code
Model: claude-fable-5
Why: nearestUserBlockIndex filtered all user blocks for every block (O(B*U)), a large share of monster-session opens"
```

---

### Task 4: Perf spans + measurement gate + documentation reconciliation

Make the transcript build permanently observable, re-measure the monster session post-Tasks 1–3, and record the new baseline. **This is a gate:** Task 9's threshold tuning and the deferred workstreams' priorities read from these numbers.

**Files:**
- Modify: `AgentSessions/Views/SessionTerminalView.swift` (`buildRebuildResult`)
- Modify: `AgentSessions/Services/SessionTranscriptBuilder.swift` (`coalescedBlocks`)
- Modify: `docs/perf-master-plan.md` (pointer + numbers)

**Interfaces:**
- Produces: `Perf` spans `transcriptCoalesce` and `transcriptModelBuild` visible under `AS_PERF_MONITOR=1`.

- [ ] **Step 1: Add the spans**

In `SessionTranscriptBuilder.swift`, change `coalescedBlocks`:

```swift
    static func coalescedBlocks(for session: Session,
                                includeMeta: Bool) -> [LogicalBlock] {
        let _span = Perf.begin("transcriptCoalesce", thresholdMs: 20, "events=\(session.events.count)")
        defer { Perf.end(_span) }
        return coalesce(session: session, includeMeta: includeMeta)
    }
```

In `SessionTerminalView.swift`, at the top of `buildRebuildResult` (before the `coalescedBlocks` call):

```swift
        let _span = Perf.begin("transcriptModelBuild", thresholdMs: 50, "events=\(session.events.count)")
        defer { Perf.end(_span) }
```

- [ ] **Step 2: Build and verify spans compile and the suite is green**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/TranscriptWindowedBuildTests 2>&1 | tail -10`
Expected: PASS.

- [ ] **Step 3: Measure on the real monster session**

Build a Debug app to the default DerivedData (do NOT reuse a test `-derivedDataPath`; see CLAUDE.md), then launch the binary directly with monitoring, stdout to the shell:

```bash
xcodebuild -scheme AgentSessions -configuration Debug build 2>&1 | tail -3
APP=$(ls -dt ~/Library/Developer/Xcode/DerivedData/AgentSessions-*/Build/Products/Debug/AgentSessions.app | head -1)
AS_PERF_MONITOR=1 "$APP/Contents/MacOS/AgentSessions"
```

Then **ask the user** to open the known 619k-line session (and a mid-size ~5.7k-line one) — do not drive the app via automation. Capture the `transcriptCoalesce` / `transcriptModelBuild` / `[perf][STALL]` lines from stdout.

- [ ] **Step 4: Record the numbers and reconcile the docs**

In `docs/perf-master-plan.md`: add at the top `> Priority order superseded by docs/superpowers/plans/2026-07-01-perf-instant-master-plan.md (post-review).` and record a small table: monster/mid-size `transcriptModelBuild` before (30,653 ms / 926 ms, from the prior profile) vs after Tasks 1–3.

**Gate decision recorded in the same table:** if the monster build is now ≤ ~5 s, proceed with Task 9's default threshold; if it is still ≥ 15 s, the quadratics were not the dominant cost — stop and re-profile (`sample` during the build) before Task 9, and note findings.

- [ ] **Step 5: Stage the commit (run only on user request)**

```bash
git add AgentSessions/Services/SessionTranscriptBuilder.swift AgentSessions/Views/SessionTerminalView.swift docs/perf-master-plan.md
git commit -m "perf(transcript): add coalesce/model-build perf spans; record post-fix baseline

Tool: Claude Code
Model: claude-fable-5
Why: windowed-build decisions (swap threshold, deferred workstream priority) key off the measured post-quadratic baseline"
```

---

### Task 5: Remove the redundant first `updateCachedRows` on sort

The `onChange(of: sortOrder)` handler sets `unified.sortDescriptor` (which re-sorts off-main and republishes `unified.sessions`, whose own `onChange` calls `updateCachedRows()`), **and** calls `updateCachedRows()` immediately against the still-unsorted array — ~115 ms of wasted work plus a pointless Table diff per sort. This is the "first is redundant" residual from the profile.

**Files:**
- Modify: `AgentSessions/Views/UnifiedSessionsView.swift:1114-1115`

**Interfaces:**
- Consumes: existing `onChange(of: unified.sessions)` pipeline (lines 1137–1157) which already calls `updateCachedRows()` + selection reconciliation.

- [ ] **Step 1: Make the edit**

In the `onChange(of: sortOrder)` handler, delete these two lines (currently 1114–1115, immediately after `unified.sortDescriptor = .init(key: key, ascending: first.order == .forward)`):

```swift
            updateCachedRows()
            refreshSelectionSourceFromCachedRows()
```

and replace with a comment:

```swift
            // No immediate updateCachedRows() here: the sortDescriptor fast path
            // re-sorts off-main and republishes unified.sessions, whose onChange
            // rebuilds rows + reconciles selection. An immediate rebuild here ran
            // against the pre-sort array — pure waste (~115 ms) plus a Table diff.
```

- [ ] **Step 2: Verify with the sort bench harness**

Build Debug (as in Task 4 Step 3), then:

```bash
AS_PERF_BENCH=sort AS_PERF_BENCH_DELAY=20 AS_PERF_BENCH_CYCLES=6 AS_PERF_BENCH_INTERVAL=3 "$APP/Contents/MacOS/AgentSessions" 2>&1 | grep -E "updateCachedRows|STALL|reorderRebuild"
```

Expected: exactly **one** `updateCachedRows` span per sort toggle (previously two), no new `[perf][STALL]` regressions, `reorderRebuild` still firing on large reorders. Record per-sort wall time next to Task 4's numbers.

- [ ] **Step 3: Manual sanity + full suite**

Ask the user to click through sort columns and confirm: rows re-sort, selection behaves, no stale ordering. Run the full suite: `./scripts/xcode_test_stable.sh 2>&1 | tail -20` — expected green.

- [ ] **Step 4: Stage the commit (run only on user request)**

```bash
git add AgentSessions/Views/UnifiedSessionsView.swift
git commit -m "perf(list): drop redundant pre-sort updateCachedRows on sortOrder change

Tool: Claude Code
Model: claude-fable-5
Why: the immediate rebuild ran against the pre-sort array; the sessions onChange already rebuilds after the off-main re-sort"
```

---

### Task 6: `SubagentHierarchyBuilder` — derive file base names without `URL`

`build()` constructs `URL(fileURLWithPath:)` per non-subagent session per call ([SubagentHierarchyBuilder.swift:74](../../AgentSessions/Services/SubagentHierarchyBuilder.swift)) — the 60–90 ms sort residual. Pure string slicing is ~100× cheaper.

**Files:**
- Modify: `AgentSessions/Services/SubagentHierarchyBuilder.swift:74-75`
- Test: `AgentSessionsTests/PerfQuickWinsTests.swift`

**Interfaces:**
- Produces: `SubagentHierarchyBuilder.fileBaseName(ofPath:) -> String` (internal static, tested).

- [ ] **Step 1: Write the failing tests**

Append to `PerfQuickWinsTests.swift`:

```swift
    // MARK: - Task 6: URL-free file base name derivation

    func testFileBaseNameMatchesURLBehavior() {
        let paths = [
            "/Users/x/.claude/projects/p/0a1b2c3d-1111-2222-3333-444455556666.jsonl",
            "/tmp/archive.tar.gz",          // only the LAST extension is dropped
            "/tmp/noext",
            "relative/dir/file.jsonl",
            "justafile.jsonl",
            "/tmp/.hiddenfile",             // leading dot is not an extension separator
            "/tmp/dir.with.dots/name.jsonl"
        ]
        for path in paths {
            let expected = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            XCTAssertEqual(SubagentHierarchyBuilder.fileBaseName(ofPath: path), expected, "path: \(path)")
        }
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/PerfQuickWinsTests 2>&1 | tail -10`
Expected: BUILD FAILURE — `fileBaseName(ofPath:)` not defined.

- [ ] **Step 3: Implement and swap the call site**

In `SubagentHierarchyBuilder.swift` add:

```swift
    /// URL-free equivalent of URL(fileURLWithPath:).deletingPathExtension()
    /// .lastPathComponent for plain file paths — build() calls this once per
    /// top-level session per sort, where URL construction dominated.
    static func fileBaseName(ofPath path: String) -> String {
        let name: Substring
        if let slash = path.lastIndex(of: "/") {
            name = path[path.index(after: slash)...]
        } else {
            name = path[...]
        }
        if let dot = name.lastIndex(of: "."), dot != name.startIndex {
            return String(name[..<dot])
        }
        return String(name)
    }
```

Replace lines 74–75:

```swift
                let fileName = URL(fileURLWithPath: s.filePath)
                    .deletingPathExtension().lastPathComponent
```

with:

```swift
                let fileName = fileBaseName(ofPath: s.filePath)
```

- [ ] **Step 4: Run tests**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/PerfQuickWinsTests 2>&1 | tail -10`
Expected: PASS. If any existing `SubagentHierarchy*` test class exists, run it too:
`./scripts/xcode_test_stable.sh 2>&1 | tail -20` — expected green.
If a URL-behavior case diverges (e.g., trailing-slash paths), match URL behavior in the helper, not vice versa.

- [ ] **Step 5: Stage the commit (run only on user request)**

```bash
git add AgentSessions/Services/SubagentHierarchyBuilder.swift AgentSessionsTests/PerfQuickWinsTests.swift
git commit -m "perf(list): derive session file base names via string slicing, not URL init

Tool: Claude Code
Model: claude-fable-5
Why: URL(fileURLWithPath:) per top-level session made SubagentHierarchyBuilder.build a 60-90ms sort residual"
```

---

### Task 7: HUD rebuild gate — skip the 35 ms rebuild on no-change poll ticks

`AgentCockpitHUDDerivedStateModel.rebuildIfReady` recomputes `makeRowsSnapshot` (~35 ms, main thread) on every ~2 s presence publish, then discards the result when unchanged. `CodexActiveSessionsModel` already maintains `activeMembershipVersion`/`subagentBadgeVersion` that bump only on real change — gate the compute on them, with a periodic fallback so age-based active/idle reclassification still happens.

**Files:**
- Create: `AgentSessions/Support/HUDRebuildGate.swift`
- Create: `AgentSessionsTests/HUDRebuildGateTests.swift`
- Modify: `AgentSessions/Views/AgentCockpitHUDView.swift:382-555` (the derived-state model)

**Interfaces:**
- Consumes: `CodexActiveSessionsModel.activeMembershipVersion: UInt64`, `.subagentBadgeVersion: UInt64` (both `@Published private(set)`, readable).
- Produces: `struct HUDRebuildGate` with `Inputs`, `shouldRebuild(inputs:now:) -> Bool` (mutating), `forceNextRebuild()` (mutating).

- [ ] **Step 1: Write the failing tests**

Create `AgentSessionsTests/HUDRebuildGateTests.swift`:

```swift
import XCTest
@testable import AgentSessions

final class HUDRebuildGateTests: XCTestCase {

    private func inputs(membership: UInt64 = 1, badge: UInt64 = 1,
                        sessions: UInt64 = 1, compact: Bool = false,
                        probes: Bool = false) -> HUDRebuildGate.Inputs {
        HUDRebuildGate.Inputs(membershipVersion: membership, badgeVersion: badge,
                              sessionsGeneration: sessions, isCompact: compact,
                              showProbes: probes)
    }

    func testFirstCallAlwaysRebuilds() {
        var gate = HUDRebuildGate(staleReclassifyInterval: 5)
        XCTAssertTrue(gate.shouldRebuild(inputs: inputs(), now: Date(timeIntervalSince1970: 100)))
    }

    func testUnchangedInputsWithinIntervalSkip() {
        var gate = HUDRebuildGate(staleReclassifyInterval: 5)
        _ = gate.shouldRebuild(inputs: inputs(), now: Date(timeIntervalSince1970: 100))
        XCTAssertFalse(gate.shouldRebuild(inputs: inputs(), now: Date(timeIntervalSince1970: 102)))
        XCTAssertFalse(gate.shouldRebuild(inputs: inputs(), now: Date(timeIntervalSince1970: 104)))
    }

    func testUnchangedInputsRebuildAfterStaleInterval() {
        var gate = HUDRebuildGate(staleReclassifyInterval: 5)
        _ = gate.shouldRebuild(inputs: inputs(), now: Date(timeIntervalSince1970: 100))
        XCTAssertTrue(gate.shouldRebuild(inputs: inputs(), now: Date(timeIntervalSince1970: 105.1)),
                      "age-based active/idle reclassification needs a periodic recompute")
    }

    func testAnyInputChangeRebuildsImmediately() {
        var gate = HUDRebuildGate(staleReclassifyInterval: 5)
        _ = gate.shouldRebuild(inputs: inputs(), now: Date(timeIntervalSince1970: 100))
        XCTAssertTrue(gate.shouldRebuild(inputs: inputs(membership: 2), now: Date(timeIntervalSince1970: 100.5)))
        XCTAssertTrue(gate.shouldRebuild(inputs: inputs(membership: 2, badge: 2), now: Date(timeIntervalSince1970: 100.6)))
        XCTAssertTrue(gate.shouldRebuild(inputs: inputs(membership: 2, badge: 2, sessions: 2), now: Date(timeIntervalSince1970: 100.7)))
        XCTAssertTrue(gate.shouldRebuild(inputs: inputs(membership: 2, badge: 2, sessions: 2, compact: true), now: Date(timeIntervalSince1970: 100.8)))
    }

    func testForceNextRebuildResetsTheGate() {
        var gate = HUDRebuildGate(staleReclassifyInterval: 5)
        _ = gate.shouldRebuild(inputs: inputs(), now: Date(timeIntervalSince1970: 100))
        gate.forceNextRebuild()
        XCTAssertTrue(gate.shouldRebuild(inputs: inputs(), now: Date(timeIntervalSince1970: 100.5)))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/HUDRebuildGateTests 2>&1 | tail -10`
Expected: BUILD FAILURE — add the test file to the project first:
`LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 ./scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessionsTests AgentSessionsTests/HUDRebuildGateTests.swift AgentSessionsTests`
Re-run; expected: still fails — `HUDRebuildGate` not defined.

- [ ] **Step 3: Implement the gate**

Create `AgentSessions/Support/HUDRebuildGate.swift`:

```swift
import Foundation

/// Skip-gate for the Cockpit HUD derived-state rebuild. The presence poll
/// publishes every ~2 s even when nothing changed; recomputing the rows
/// snapshot costs ~35 ms on the main thread per tick. Rebuild only when a
/// versioned input changed, or when `staleReclassifyInterval` has elapsed
/// (so age-based active/idle classification still refreshes).
struct HUDRebuildGate {
    struct Inputs: Equatable {
        var membershipVersion: UInt64
        var badgeVersion: UInt64
        var sessionsGeneration: UInt64
        var isCompact: Bool
        var showProbes: Bool
    }

    let staleReclassifyInterval: TimeInterval
    private var lastInputs: Inputs?
    private var lastRebuildAt: Date?

    init(staleReclassifyInterval: TimeInterval) {
        self.staleReclassifyInterval = staleReclassifyInterval
    }

    mutating func shouldRebuild(inputs: Inputs, now: Date) -> Bool {
        if inputs != lastInputs {
            mark(inputs: inputs, now: now)
            return true
        }
        if let last = lastRebuildAt, now.timeIntervalSince(last) < staleReclassifyInterval {
            return false
        }
        mark(inputs: inputs, now: now)
        return true
    }

    mutating func forceNextRebuild() {
        lastInputs = nil
        lastRebuildAt = nil
    }

    private mutating func mark(inputs: Inputs, now: Date) {
        lastInputs = inputs
        lastRebuildAt = now
    }
}
```

Add to project:
`LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 ./scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessions AgentSessions/Support/HUDRebuildGate.swift AgentSessions/Support`

- [ ] **Step 4: Run gate tests**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/HUDRebuildGateTests 2>&1 | tail -10`
Expected: PASS.

- [ ] **Step 5: Wire into the HUD model**

In `AgentCockpitHUDView.swift`, inside `AgentCockpitHUDDerivedStateModel`:

(a) Add state next to `private var rebuildScheduled: Bool = false`:

```swift
    private var sessionsGeneration: UInt64 = 0
    private var rebuildGate = HUDRebuildGate(staleReclassifyInterval: 5)
```

(b) In each of the three indexer sinks (`codexIndexer.$allSessions`, `claudeIndexer.$allSessions`, `opencodeIndexer.$allSessions`), add `sessionsGeneration &+= 1` immediately after the sessions assignment (e.g., after `codexSessions = sessions`).

(c) In `bind(activeCodex:)`, add `rebuildGate.forceNextRebuild()` as the first line (a rebind must never be gated away).

(d) In `rebuildIfReady`, insert the gate after `let showProbes = ...` and move the perf span below it so skipped ticks don't log:

```swift
    private func rebuildIfReady(activeCodex: CodexActiveSessionsModel? = nil) {
        let activeCodex = activeCodex ?? self.activeCodex
        guard let activeCodex else { return }
        let now = Date()
        let showProbes = UserDefaults.standard.bool(forKey: PreferencesKey.Cockpit.showProbeSessionsInHUD)
        let gateInputs = HUDRebuildGate.Inputs(
            membershipVersion: activeCodex.activeMembershipVersion,
            badgeVersion: activeCodex.subagentBadgeVersion,
            sessionsGeneration: sessionsGeneration,
            isCompact: isCompact,
            showProbes: showProbes
        )
        guard rebuildGate.shouldRebuild(inputs: gateInputs, now: now) else { return }
#if DEBUG
        let _hudSpan = Perf.begin("hudRebuild", thresholdMs: 4)
        defer { Perf.end(_hudSpan) }
#endif
        let activeSubagentCounts = CodexActiveSessionsModel.activeSubagentCounts(
```

(the remainder of the method is unchanged; delete the old `let now = Date()` / `let showProbes = ...` lines that the snippet replaces).

- [ ] **Step 6: Verify behavior**

Run: `./scripts/xcode_test_stable.sh 2>&1 | tail -20` — expected green.
Then build Debug and launch with `AS_PERF_MONITOR=1` (Task 4 Step 3 commands); with the Cockpit HUD open and **no agent activity**, `hudRebuild` spans must appear at most every ~5 s (previously every ~2 s). Ask the user to start/stop an agent session and confirm the HUD row updates promptly (≤ one poll tick — version bump bypasses the gate).

- [ ] **Step 7: Stage the commit (run only on user request)**

```bash
git add AgentSessions/Support/HUDRebuildGate.swift AgentSessionsTests/HUDRebuildGateTests.swift AgentSessions/Views/AgentCockpitHUDView.swift AgentSessions.xcodeproj/project.pbxproj
git commit -m "perf(hud): gate rows-snapshot rebuild on membership/badge/sessions versions + 5s reclassify fallback

Tool: Claude Code
Model: claude-fable-5
Why: rebuildIfReady recomputed a ~35ms snapshot on every 2s poll tick and then discarded it when unchanged — the main idle-energy driver"
```

---

### Task 8: `buildRebuildResult` slice overload (model layer for the two-stage open)

Give `buildRebuildResult` a variant that takes pre-coalesced blocks plus an optional block range: lines are built for the range only, while index maps keep whole-session anchor semantics (graceful subset where anchors fall off-window). This supersedes the "recompute index maps over the slice" portion of Phase 3 Tasks 4–5.

**Files:**
- Modify: `AgentSessions/Views/SessionTerminalView.swift:783-792` (RebuildResult access), `:963-1091` (buildRebuildResult)
- Test: `AgentSessionsTests/TranscriptWindowedBuildTests.swift`

**Interfaces:**
- Consumes: `TerminalBuilder.buildLines(from:blockRange:source:enableReviewCards:)` (Phase 3 Task 3), `TranscriptWindow` (Phase 3 Task 2), `TranscriptUserAnchors` (Task 3).
- Produces: `SessionTerminalView.buildRebuildResult(session:blocks:blockRange:skipAgentsPreamble:enableReviewCards:) -> RebuildResult` — `nonisolated static`, **internal** (test-visible); `blockRange == nil` means full build. `RebuildResult` and the existing 3-argument entry point become internal wrappers. Task 9 consumes this.

- [ ] **Step 1: Write the failing parity test**

Append to `TranscriptWindowedBuildTests.swift` (fixtures `deltaSession(pairs:)` already exist there):

```swift
    // MARK: - RebuildResult slice parity (two-stage open substrate)

    func testSliceRebuildResultIsConsistentSubsetOfFullBuild() {
        let session = deltaSession(pairs: 60)
        let blocks = SessionTranscriptBuilder.coalescedBlocks(for: session, includeMeta: false)
        let full = SessionTerminalView.buildRebuildResult(session: session, blocks: blocks,
                                                          blockRange: nil,
                                                          skipAgentsPreamble: false,
                                                          enableReviewCards: true)
        let window = TranscriptWindow.lastWindow(totalBlocks: blocks.count, blockTarget: 16)
        let slice = SessionTerminalView.buildRebuildResult(session: session, blocks: blocks,
                                                           blockRange: window.lowerBlock...window.upperBlock,
                                                           skipAgentsPreamble: false,
                                                           enableReviewCards: true)
        XCTAssertFalse(slice.lines.isEmpty)
        XCTAssertLessThan(slice.lines.count, full.lines.count)

        if FeatureFlags.transcriptWindowedBuild {
            // Slice lines are exactly the suffix of the full build (global ids).
            XCTAssertEqual(slice.lines.map(\.id),
                           Array(full.lines.map(\.id).suffix(slice.lines.count)))
            // Role nav indices are full-build entries restricted to windowed line ids.
            let sliceIDs = Set(slice.lines.map(\.id))
            XCTAssertEqual(slice.userLineIndices, full.userLineIndices.filter { sliceIDs.contains($0) })
            XCTAssertEqual(slice.assistantLineIndices, full.assistantLineIndices.filter { sliceIDs.contains($0) })
            XCTAssertEqual(slice.toolLineIndices, full.toolLineIndices.filter { sliceIDs.contains($0) })
            XCTAssertEqual(slice.errorLineIndices, full.errorLineIndices.filter { sliceIDs.contains($0) })
            // Every slice eventID→line entry agrees with the full map.
            for (eventID, lineID) in slice.eventIDToUserLineID {
                XCTAssertEqual(full.eventIDToUserLineID[eventID], lineID, "eventID \(eventID)")
            }
        } else {
            // Flag off: local ids renumber; only structural sanity applies.
            XCTAssertEqual(slice.lines.first?.id, 0)
        }
    }

    func testNilBlockRangeMatchesLegacyEntryPoint() {
        let session = deltaSession(pairs: 20)
        let blocks = SessionTranscriptBuilder.coalescedBlocks(for: session, includeMeta: false)
        let viaBlocks = SessionTerminalView.buildRebuildResult(session: session, blocks: blocks,
                                                               blockRange: nil,
                                                               skipAgentsPreamble: false,
                                                               enableReviewCards: true)
        let legacy = SessionTerminalView.buildRebuildResult(session: session,
                                                            skipAgentsPreamble: false,
                                                            enableReviewCards: true)
        XCTAssertEqual(viaBlocks.lines.map(\.id), legacy.lines.map(\.id))
        XCTAssertEqual(viaBlocks.lines.map(\.text), legacy.lines.map(\.text))
        XCTAssertEqual(viaBlocks.userLineIndices, legacy.userLineIndices)
        XCTAssertEqual(viaBlocks.eventIDToUserLineID, legacy.eventIDToUserLineID)
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/TranscriptWindowedBuildTests 2>&1 | tail -10`
Expected: BUILD FAILURE — no such overload, and `buildRebuildResult`/`RebuildResult` are `private`.

- [ ] **Step 3: Implement**

In `SessionTerminalView.swift`:

(a) Change `private struct RebuildResult: Sendable` → `struct RebuildResult: Sendable` (line 783).

(b) Rewrite the entry points (replacing the current `nonisolated private static func buildRebuildResult(session:skipAgentsPreamble:enableReviewCards:)` signature and its first two lines; the body from `let startLineID = ...` onward is **unchanged**):

```swift
    nonisolated static func buildRebuildResult(session: Session,
                                               skipAgentsPreamble: Bool,
                                               enableReviewCards: Bool) -> RebuildResult {
        let blocks = SessionTranscriptBuilder.coalescedBlocks(for: session, includeMeta: false)
        return buildRebuildResult(session: session, blocks: blocks, blockRange: nil,
                                  skipAgentsPreamble: skipAgentsPreamble,
                                  enableReviewCards: enableReviewCards)
    }

    /// Slice-aware variant. `blocks` is the FULL coalesced array (anchor and
    /// preamble semantics stay whole-session); `blockRange` limits which blocks
    /// get lines built. Index maps that reference off-window blocks degrade to
    /// a consistent subset (missing entries, never wrong ones) because
    /// firstLineForBlock only contains windowed blocks.
    nonisolated static func buildRebuildResult(session: Session,
                                               blocks: [SessionTranscriptBuilder.LogicalBlock],
                                               blockRange: ClosedRange<Int>?,
                                               skipAgentsPreamble: Bool,
                                               enableReviewCards: Bool) -> RebuildResult {
        let _span = Perf.begin("transcriptModelBuild", thresholdMs: 50,
                               "events=\(session.events.count) range=\(blockRange.map { "\($0)" } ?? "full")")
        defer { Perf.end(_span) }
        let built: [TerminalLine]
        if let blockRange {
            built = TerminalBuilder.buildLines(from: blocks, blockRange: blockRange,
                                               source: session.source, enableReviewCards: enableReviewCards)
        } else {
            built = TerminalBuilder.buildLines(from: blocks, source: session.source,
                                               enableReviewCards: enableReviewCards)
        }
        let startLineID = conversationStartLineIDIfNeeded(session: session, lines: built, enabled: skipAgentsPreamble)
        // ... existing body continues unchanged from here (preambleUserBlockIndexes,
        // firstLineForBlock over `built`, anchors over full `blocks`, tool group keys,
        // messageIDs()/toolMessageIDs(), return RebuildResult(...)).
    }
```

Note: the existing single `Perf.begin("transcriptModelBuild"...)` from Task 4 moves into this variant (do not double-instrument the wrapper).

- [ ] **Step 4: Run tests**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/TranscriptWindowedBuildTests 2>&1 | tail -10`
Expected: PASS (flag-off assertions active).
Then flip `FeatureFlags.transcriptWindowedBuild = true` locally, re-run the same suite plus the terminal/transcript/golden suites used by the Phase 2 verification, confirm PASS, and **revert the flag to `false`**.

- [ ] **Step 5: Stage the commit (run only on user request)**

```bash
git add AgentSessions/Views/SessionTerminalView.swift AgentSessionsTests/TranscriptWindowedBuildTests.swift
git commit -m "feat(transcript): slice-aware buildRebuildResult over a block range (two-stage open substrate)

Tool: Claude Code
Model: claude-fable-5
Why: the windowed first paint and the full-build swap need RebuildResults built from the same pre-coalesced blocks"
```

---

### Task 9: Two-stage open — windowed first paint, then gated full-build swap

When the flag is on: build and show the last window immediately (< 150 ms to content), then keep building the whole session off-main and swap it in **only when total transcript characters ≤ `transcriptFullSwapMaxChars`** (apply cost — attr build + `setAttributedString` + layout — is main-thread and scales with characters). Above the threshold the window stays and Phase 3 Tasks 6–8 (loadOlder) remain the path to older content. Includes a prepend-safe scroll anchor in `applyContent` that also serves the future loadOlder path.

**Files:**
- Modify: `AgentSessions/Support/FeatureFlags.swift` (add `transcriptFullSwapMaxChars`)
- Modify: `AgentSessions/Views/SessionTerminalView.swift:794-892` (`rebuildLines` → two-stage; extract `applyRebuild`), `:4317-4360` (`applyContent` anchor)
- Test: `AgentSessionsTests/TranscriptWindowedBuildTests.swift` (threshold policy)

**Interfaces:**
- Consumes: `buildRebuildResult(session:blocks:blockRange:...)` (Task 8), `TranscriptWindow.lastWindow` (Phase 3 Task 2), `FeatureFlags.transcriptWindowBlockTarget` (Phase 3 Task 1).
- Produces: `FeatureFlags.transcriptFullSwapMaxChars: Int`; `SessionTerminalView.shouldSwapToFullBuild(totalChars:) -> Bool` (static, tested); the two-stage `rebuildLines`.

- [ ] **Step 1: Add the flag constant + policy helper + failing test**

In `FeatureFlags.swift`, after `transcriptWindowNearTopLoadOlder`:

```swift
    // Two-stage open: after the windowed first paint, the full-session build is
    // swapped in ONLY when total transcript characters are at or below this
    // threshold. Applying content costs main-thread time proportional to
    // characters (attr build + setAttributedString + layout), so an unbounded
    // swap would reintroduce a beachball on monster sessions. Tune with the
    // transcriptSwapApply perf span.
    static let transcriptFullSwapMaxChars: Int = 800_000
```

In `SessionTerminalView.swift` (near `tailPatchStrategy`):

```swift
    nonisolated static func shouldSwapToFullBuild(totalChars: Int) -> Bool {
        totalChars <= FeatureFlags.transcriptFullSwapMaxChars
    }
```

Append to `TranscriptWindowedBuildTests.swift`:

```swift
    func testFullSwapThresholdPolicy() {
        XCTAssertTrue(SessionTerminalView.shouldSwapToFullBuild(totalChars: 0))
        XCTAssertTrue(SessionTerminalView.shouldSwapToFullBuild(totalChars: FeatureFlags.transcriptFullSwapMaxChars))
        XCTAssertFalse(SessionTerminalView.shouldSwapToFullBuild(totalChars: FeatureFlags.transcriptFullSwapMaxChars + 1))
    }
```

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/TranscriptWindowedBuildTests 2>&1 | tail -10`
Expected: FAIL (missing symbol) → implement the two snippets above → PASS.

- [ ] **Step 2: Extract `applyRebuild` from the `MainActor.run` body**

In `rebuildLines`, the entire closure body inside `await MainActor.run { ... }` (lines 812–890: from `let priorLines = lines` through the `applyAutoScrollIfNeeded` call) moves verbatim into a new method on `SessionTerminalView`:

```swift
    private func applyRebuild(_ result: RebuildResult,
                              sessionSnapshot: Session,
                              skipAgentsPreamble: Bool) {
        // (verbatim former MainActor.run body; `result`, `sessionSnapshot`,
        // `skipAgentsPreamble` were already the only captured inputs)
    }
```

and the call site becomes `await MainActor.run { guard !Task.isCancelled else { return }; applyRebuild(result, sessionSnapshot: sessionSnapshot, skipAgentsPreamble: skipAgentsPreamble) }`. Pure mechanical extraction — build to confirm, no behavior change: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/TranscriptWindowedBuildTests 2>&1 | tail -5` → PASS.

- [ ] **Step 3: Make `rebuildLines` two-stage behind the flag**

Replace the `rebuildTask = Task.detached(...)` block in `rebuildLines` with:

```swift
        rebuildTask = Task.detached(priority: priority) { [sessionSnapshot, skipAgentsPreamble, reviewCardsEnabled, debounceNanoseconds] in
            if debounceNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: debounceNanoseconds)
            }
            guard !Task.isCancelled else { return }

            var fullBlocks: [SessionTranscriptBuilder.LogicalBlock]? = nil
            if FeatureFlags.transcriptWindowedBuild {
                let blocks = SessionTranscriptBuilder.coalescedBlocks(for: sessionSnapshot, includeMeta: false)
                fullBlocks = blocks
                let window = TranscriptWindow.lastWindow(totalBlocks: blocks.count,
                                                         blockTarget: FeatureFlags.transcriptWindowBlockTarget)
                if !window.isEmpty, !window.coversTop {
                    // Stage 1: last-window first paint.
                    let windowResult = Self.buildRebuildResult(session: sessionSnapshot,
                                                               blocks: blocks,
                                                               blockRange: window.lowerBlock...window.upperBlock,
                                                               skipAgentsPreamble: skipAgentsPreamble,
                                                               enableReviewCards: reviewCardsEnabled)
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        guard !Task.isCancelled else { return }
                        applyRebuild(windowResult, sessionSnapshot: sessionSnapshot,
                                     skipAgentsPreamble: skipAgentsPreamble)
                    }
                    // Stage 2 gate: swapping in the whole session costs main-thread
                    // apply time proportional to characters. Above the threshold the
                    // window remains the operating regime (loadOlder — Phase 3
                    // Tasks 6–8 — is the path to older content).
                    let totalChars = blocks.reduce(0) { $0 + $1.text.utf8.count }
                    guard Self.shouldSwapToFullBuild(totalChars: totalChars) else { return }
                }
            }

            let result: RebuildResult
            if let fullBlocks {
                result = Self.buildRebuildResult(session: sessionSnapshot, blocks: fullBlocks,
                                                 blockRange: nil,
                                                 skipAgentsPreamble: skipAgentsPreamble,
                                                 enableReviewCards: reviewCardsEnabled)
            } else {
                result = Self.buildRebuildResult(session: sessionSnapshot,
                                                 skipAgentsPreamble: skipAgentsPreamble,
                                                 enableReviewCards: reviewCardsEnabled)
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard !Task.isCancelled else { return }
                applyRebuild(result, sessionSnapshot: sessionSnapshot,
                             skipAgentsPreamble: skipAgentsPreamble)
            }
        }
```

Flag-off behavior is byte-identical to today (single full build via the legacy entry point).

- [ ] **Step 4: Prepend-safe scroll anchor in `applyContent`**

The swap replaces a suffix (the window) with a superset that adds content **above** it; character-position scrolling would visibly jump for a user who scrolled up pre-swap. In `applyContent(to:context:)`, capture/restore an anchor around the storage replacement. Insert **before** `textView.textStorage?.setAttributedString(attr)` (line 4333):

```swift
        // Preserve the viewport when new content is prepended above the old first
        // line (windowed first paint → full swap now; loadOlder prepend later).
        var swapAnchor: (lineID: Int, offsetY: CGFloat)? = nil
        if let scrollView = textView.enclosingScrollView,
           let lm = textView.layoutManager, let tc = textView.textContainer,
           let oldFirstID = context.coordinator.orderedLineIDs.first,
           let newFirstID = lines.first?.id,
           newFirstID != oldFirstID,
           context.coordinator.lineRanges[oldFirstID] != nil,
           lines.contains(where: { $0.id == oldFirstID }),
           scrollView.contentView.bounds.origin.y > 0 {
            let visibleY = scrollView.contentView.bounds.origin.y
            let glyphIndex = lm.glyphIndex(for: CGPoint(x: 5, y: visibleY), in: tc)
            let charIndex = lm.characterIndexForGlyph(at: glyphIndex)
            if let idx = context.coordinator.orderedLineRanges.lastIndex(where: { $0.location <= charIndex }),
               context.coordinator.orderedLineIDs.indices.contains(idx) {
                let anchorRange = context.coordinator.orderedLineRanges[idx]
                let rect = lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: anchorRange, actualCharacterRange: nil), in: tc)
                swapAnchor = (context.coordinator.orderedLineIDs[idx], visibleY - rect.minY)
            }
        }
```

and **after** the coordinator range maps are updated (immediately after `context.coordinator.orderedLineIDs = lines.map(\.id)` and before `pruneLinkCache`):

```swift
        if let swapAnchor,
           let scrollView = textView.enclosingScrollView,
           let lm = textView.layoutManager, let tc = textView.textContainer,
           let newRange = ranges[swapAnchor.lineID] {
            lm.ensureLayout(forCharacterRange: NSRange(location: 0, length: newRange.location + newRange.length))
            let rect = lm.boundingRect(forGlyphRange: lm.glyphRange(forCharacterRange: newRange, actualCharacterRange: nil), in: tc)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, rect.minY + swapAnchor.offsetY)))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
```

Guards to note: the anchor only engages when content actually prepended (`newFirstID != oldFirstID` with the old first line still present) **and** the user is scrolled away from the very top of the old window; the pinned-at-bottom default is untouched (the existing `applyAutoScrollIfNeeded` path still governs it). Add a perf span around the stage-2 apply while tuning: wrap the stage-2 `applyRebuild` call site as `let _s = Perf.begin("transcriptSwapApply", thresholdMs: 50); applyRebuild(...); Perf.end(_s)` — keep it after tuning; it's the number that validates `transcriptFullSwapMaxChars`.

- [ ] **Step 5: Regression suites, flag-on parity, and manual QA gate**

1. Full suite flag-off: `./scripts/xcode_test_stable.sh 2>&1 | tail -20` — expected green (flag-off path unchanged).
2. Flip `FeatureFlags.transcriptWindowedBuild = true`, run the full suite plus the Phase-2 parity set (terminal/transcript/image/golden suites) — expected green.
3. Build Debug (flag still on) and hand to the user for visual QA — the checklist:
   - open a small session → identical to before (window covers all → single full build);
   - open a mid-size (~5.7k-line) session → content appears instantly, then Find/minimap/role nav silently become whole-session (`transcriptSwapApply` span ≤ ~150 ms);
   - open the monster session → tail appears fast, **no beachball**, scrolling up stops at the window top (loadOlder arrives with Phase 3 Tasks 6–8);
   - in the mid-size session, scroll up inside the window immediately after open → when the swap lands, the viewport must not visibly jump;
   - live-tail on an active session still appends; filters/Copy Block/export work in both tiers.
4. Revert the flag to `false` for commit (default stays off until the Phase 3 QA gate flips it).

- [ ] **Step 6: Stage the commit (run only on user request)**

```bash
git add AgentSessions/Support/FeatureFlags.swift AgentSessions/Views/SessionTerminalView.swift AgentSessionsTests/TranscriptWindowedBuildTests.swift
git commit -m "feat(transcript): two-stage open — windowed first paint, char-gated full-build swap with scroll anchor

Tool: Claude Code
Model: claude-fable-5
Why: instant first content for hydrated sessions; under-threshold sessions regain whole-session Find/selection ~1s later, monsters stay windowed to avoid main-thread apply stalls"
```

---

## Deferred workstreams (gated; each gets its own plan doc when its gate opens)

> **Owner priorities (2026-07-01, verbatim direction):** after transcript work, **instant search is next** (= W2 below), then overall snappiness. **Analytics perf can be skipped** — do not invest there. **GitHub inspector is a removal candidate** ("may drop fully, probably dead code") — needs one confirmation pass (inventory what it is, who references it) before deletion; add to the close-out cleanup list, do not delete without explicit go.

**W2 — FTS ingest re-wire + per-session event-offset checkpoints (supersedes Phase 5; closes Problem D).**
*Gate:* Tasks 1–9 landed and the Task 4 baseline recorded. *Scope when planned:* restore the `session_search`/`session_tool_io` ingest writer (removed in `31f6a619`) as an idle-QoS incremental pass keyed by `files(mtime,size)` via the existing `fetchSearchReadyPaths`; in the same streaming pass, persist per-session event checkpoints `(lineIndex, byteOffset)` every K events (blob column keyed by session, invalidated by mtime/size, fast-forwardable on append since JSONL is append-only); add `parseFileFull(from: checkpoint)` seeded with the checkpoint's `lineIndex` so `eventID(base:index:)` stays identical to a full parse; a shared `ReverseJSONLLineReader` as the unindexed-file fallback; then reduce `SessionEvent.rawJSON` retention (re-readable via checkpoints) so hydrated-session memory actually scales with the window. This is one workstream on purpose: the ingest stream is the only full-file pass, and both search and cold-open windowing fall out of it.

**W3 — Presence engine off the main actor (Problem C, structural).**
*Gate:* Task 7 shipped; pursue if "Using Significant Energy" persists (the remaining drivers are the 2 s `ps`/`lsof`/AppleScript probe spawns themselves, not the HUD). *Scope when planned:* `actor PresenceEngine` owning caches/probes/merge with `AsyncStream<PresenceSnapshot>` output; FSEvents/`DispatchSource` on registry roots replacing the registry disk poll (slow sweep as TTL backstop); probe backoff when no consumer is visible; iTerm probing via `osascript` subprocess (NSAppleScript is not thread-safe). The `activeMembershipVersion` discipline ports as-is.

**W4 — ID-space failure policy (review §3, small).**
*Gate:* before flipping `transcriptWindowedBuild` default on. *Scope when planned:* a block whose ordinal reaches `TerminalLineID.stride` currently aliases into the next block's id space **silently in Release** (the guard is assert-only). At line-build time, stop emitting lines for such a block and emit one synthetic meta line ("… output truncated, N more lines") plus an `os_log` fault — truncation of a >1M-line single block is honest policy, not data loss. Same audit for `decorationGroupID` (`blockIndex * 1000 + segmentOrdinal`, [TerminalModels.swift:587](../../AgentSessions/Services/TerminalModels.swift)), which aliases at >1000 segments per block.

**W6 — TranscriptDerivedState extraction (structural close-out; added 2026-07-01 after the Phase-4 gate).**
*Gate:* after Task 9 lands and is QA'd. *Diagnosis (from measurement, not taste):* every profiled defect this program found is one architectural gap wearing different costumes — derived state recomputed on demand in the view layer (toolbar nav indices rescanned per layout probe; coalesce re-derived by every call site; HUD snapshot rebuilt and discarded per tick; rows rebuilt twice per sort). Phase 4's fixes (nav-index cache, coalesce memo, normalize memo, build-signature dedupe) are the ad-hoc embryo of the missing layer. *Scope when planned:* extract a `TranscriptDerivedState` owner — coalesced blocks, lines, visible lines, nav/semantic indices, image maps — computed off-main, invalidated by explicit keys (session id, event count, file size, filter/settings signature), consolidating the Phase-4 caches into one place; `SessionTerminalView` shrinks to rendering + intents. NOT a rewrite: the ~1,050 tests encoding provider/parser/image behavioral knowledge are the asset a rewrite would forfeit. *Escalation rule (agreed with product owner):* if, after this program (incl. Task 9 and W6) the monster session still isn't instant-open or idle still isn't quiet, escalate to a standalone rewrite of the transcript module — designed from this program's profiling data.

**W5 — Session list at 40k rows.**
*Gate:* a measurement, not a feeling — generate a synthetic 40k-row `session_meta` fixture, drive `AS_PERF_BENCH=sort`, and record p95 sort wall time after Tasks 5–6. If p95 > ~200 ms: plan the `NSTableView`/`NSViewRepresentable` swap behind the existing `cachedRows` row model (wholesale reorder = `reloadData`, the case diffable diffing is worst at). Also spike scroll-position capture/restore across the `tableReorderGeneration` identity bump — if it works, the "sort resets scroll" tradeoff disappears without any rewrite.

## Verification summary

| Claim | Evidence |
|---|---|
| Coalesce linear | Task 1 canary (< 2 s where quadratic took minutes) + byte-identical parity suites |
| Index maps linear | Task 3 randomized parity vs verbatim legacy oracle |
| Monster build shrinks | Task 4 measured `transcriptModelBuild` before/after in `docs/perf-master-plan.md` |
| One `updateCachedRows` per sort | Task 5 `AS_PERF_BENCH=sort` span count |
| HUD idle compute ≥ 2.5× down | Task 7 `hudRebuild` span cadence (≤ every 5 s idle) + prompt update on activity |
| First content < 150 ms hydrated | Task 9 QA + `transcriptModelBuild range=…` span on stage 1 |
| No swap beachball | Task 9 `transcriptSwapApply` span ≤ ~150 ms under threshold; monsters never swap |
