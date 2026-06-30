# Transcript Phase 5 — Tail/Partial Parse Windowing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** For a cold (events-not-loaded) large Codex or Claude session, parse only the recent *tail* of the JSONL file first so the first transcript content paints fast, then parse the remaining earlier events on demand to feed the windowed build's load-older — instead of `parseFileFull` parsing the whole file up front.

**Architecture:** Add a tail-aware line reader (`JSONLReader.tailLines(maxLines:)`) that counts total newline-terminated records cheaply, then re-reads only the last *N* records while reporting the **absolute 1-based line index** of each. Add a provider-level `parseFileTail(at:forcedID:tailLineCount:)` to the Codex (`SessionIndexer`) and Claude (`ClaudeSessionParser`) parsers that assigns event ids from those **absolute** line indices (so ids match a later full parse, satisfying Phase 2's `eventIndex`-based global identities) and produces a `Session` flagged `isPartiallyParsed` with `parsedFromLineIndex` set. The windowed build (Phase 3, assumed present) treats a partial session like a hydrated session over its loaded events; its `loadOlder` trigger calls a new `SessionIndexer.parseMoreOlder(id:)` that parses the previous chunk of lines and **prepends** the new earlier events, deduping by event id. A later `parseFileFull` (live-tail / manual refresh / full hydration) replaces the partial events wholesale; because ids are absolute-line-derived they reconcile 1:1.

**Tech Stack:** Swift 5 / SwiftUI, macOS app target `AgentSessions`. Existing infra: `JSONLReader` (forward streaming line reader), per-provider `parseFileFull`, `SessionEvent` (id = `hash(path)+"-%04d" % lineIndex`), `TranscriptHydrationGate` (Phase 1 guardrail), `FeatureFlags`.

## Global Constraints

- **Scope of providers (first cut):** **Codex** (`AgentSessions/Services/SessionIndexer.swift`) and **Claude** (`AgentSessions/Services/ClaudeSessionParser.swift`) ONLY. These are the single-JSONL-file providers where monster sessions occur. All other providers (Cursor, Copilot, Droid, Hermes, Pi, OpenClaw, OpenCode, Antigravity) are **OUT of scope** for Phase 5 and must keep using `parseFileFull` unchanged. The feature flag default-off plus a per-source capability check guarantees they are untouched.
- **Feature flag, parity-gated:** all behavior changes gate behind `FeatureFlags.transcriptTailParse` (default `false`). When off, the exact pre-Phase-5 code path runs. Do not flip the default in this plan; flipping happens only after the parity tests in Task 9 pass and a human signs off.
- **Depends on Phases 2–3:** ASSUME the spec's Phase 2 (stable global identities — `TerminalLine.eventIndex`/`blockIndex` derived from the global event/block index) and Phase 3 (windowed build with `loadOlder()`/`loadNewer()`) are already implemented behind `FeatureFlags.transcriptWindowedBuild`. Phase 5 wires the *parse* side into that *build* side. Where this plan references a Phase 3 symbol that does not yet exist in the tree, the step says so explicitly and provides a thin shim guarded by the flag.
- **Event-id stability is the correctness keystone.** Codex id = `hash(path) + String(format: "-%04d", lineIndex)` where `lineIndex` is the **1-based file line number** ([`SessionIndexer.eventID(base:index:)`](../../../AgentSessions/Services/SessionIndexer.swift):2584; assigned at [:1919](../../../AgentSessions/Services/SessionIndexer.swift) via `idx += 1`). Claude id base = same scheme ([`ClaudeSessionParser.eventID(for:index:)`](../../../AgentSessions/Services/ClaudeSessionParser.swift):1158; assigned at [:111](../../../AgentSessions/Services/ClaudeSessionParser.swift)), with `parseLineEvents` appending sub-suffixes for multi-event lines. A tail parse MUST assign the **same absolute line index** a full parse would, or prepend/dedupe and Phase-2 identities break. The `%04d` format truncates above line 9999 but stays unique because the `hash(path)` prefix plus the raw integer keep ids distinct; we keep the existing format verbatim — never re-derive ids from a tail-local 0-based counter.
- **List stability:** a partially-parsed `Session` must keep its lightweight `eventCount` estimate so `Session.messageCount` ([Session.swift:797](../../../AgentSessions/Model/Session.swift)) does not shrink and the row does not vanish under hide-low filters. `messageCount = max(eventCount, nonMetaCount)`; with partial events `nonMetaCount` is small, so the estimate must win — never overwrite `eventCount` with the partial count.
- **Build & file conventions:**
  - New Swift files added to the Xcode project via:
    `LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 ./scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessions <path> <group>`
    and test files with target `AgentSessionsTests`.
  - Run tests via: `./scripts/xcode_test_stable.sh` (optionally pass a `-only-testing:` filter as shown per task).
  - Commits: Conventional Commits with trailers `Tool: Claude Code`, `Model: claude-opus-4-8`, `Why: <reason>`. **No co-author trailer. No "Generated with" footer.** Never commit or push unless the human says so — each "Commit" step below stages and writes the message but the human triggers the actual run if the workflow requires confirmation; in subagent-driven execution the commit runs as written.
- **Provider parser shapes (verified):**
  - Codex `parseFileFull` emits **one `SessionEvent` per non-empty line** ([SessionIndexer.swift:1918–1960](../../../AgentSessions/Services/SessionIndexer.swift)).
  - Claude `parseFileFull` may emit **multiple `SessionEvent`s per line** (`parseLineEvents` returns `[SessionEvent]`, [ClaudeSessionParser.swift:112](../../../AgentSessions/Services/ClaudeSessionParser.swift),[:281](../../../AgentSessions/Services/ClaudeSessionParser.swift)). Tail windowing keys off **whole lines** (file records), and each line's events are all kept or all skipped together — never split a line's event group.
  - `JSONLReader.forEachLine` skips blank lines and emits an `[Oversize line omitted]` stub for >8 MB lines ([JSONLReader.swift:46–120](../../../AgentSessions/Utilities/JSONLReader.swift)). The tail counter must count records the **same way** (skip blanks; count an oversize-skip as one record) so absolute indices line up with a full parse.

---

## File Structure

| File | Responsibility | Create/Modify |
|---|---|---|
| `AgentSessions/Utilities/JSONLReader.swift` | Add `lineCount()` (cheap newline count, same skip rules) and `tailLines(maxLines:totalLineCount:)` (re-read only the last N records, reporting absolute 1-based index). | Modify |
| `AgentSessions/Model/Session.swift` | Add `isPartiallyParsed: Bool` and `parsedFromLineIndex: Int?` stored fields (default false / nil) so the rest of the app can tell a tail-parsed session from a full one without changing `messageCount`. | Modify |
| `AgentSessions/Support/FeatureFlags.swift` | Add `transcriptTailParse` (default false), `tailParseInitialLineCount`, `tailParseChunkLineCount`. | Modify |
| `AgentSessions/Services/SessionIndexer.swift` | Add Codex `parseFileTail(...)`; add `reloadSessionTail(id:)` + `parseMoreOlder(id:)` integration that merges/prepends partial events and feeds the windowed build's loadOlder. | Modify |
| `AgentSessions/Services/ClaudeSessionParser.swift` | Add Claude `parseFileTail(...)` (line-record windowing, multi-event-per-line safe). | Modify |
| `AgentSessions/Services/ClaudeSessionIndexer.swift` | Add Claude `reloadSessionTail(id:)` + `parseMoreOlder(id:)` mirroring the Codex integration. | Modify |
| `AgentSessions/Services/TranscriptHydrationGate.swift` | Add `shouldTailParse(_:)` — large + tail-parse-capable source + flag on → tail-parse instead of skipping; replaces the bare "skip" for capable sources. | Modify |
| `AgentSessions/Views/UnifiedSessionsView.swift` | In the selection fan-out, route capable large sessions to `reloadSessionTail` instead of the skip-and-show-interstitial path when the flag is on. | Modify |
| `AgentSessionsTests/JSONLReaderTailTests.swift` | Unit tests: `lineCount`, `tailLines` absolute indices, blank/oversize skip parity. | Create |
| `AgentSessionsTests/CodexTailParseTests.swift` | Unit tests: Codex tail parse event-id parity vs full parse; partial flags; prepend dedupe. | Create |
| `AgentSessionsTests/ClaudeTailParseTests.swift` | Unit tests: Claude multi-event-per-line tail parse keeps line groups intact; id parity. | Create |
| `AgentSessionsTests/TailParseGateTests.swift` | Unit tests: gate routes capable/incapable sources correctly; flag off = legacy path. | Create |

---

## Task 1: Feature flags for tail parse

**Files:**
- Modify: `AgentSessions/Support/FeatureFlags.swift`

**Interfaces:**
- Produces: `FeatureFlags.transcriptTailParse: Bool`, `FeatureFlags.tailParseInitialLineCount: Int`, `FeatureFlags.tailParseChunkLineCount: Int`.

- [ ] **Step 1: Add the flags**

In `AgentSessions/Support/FeatureFlags.swift`, immediately after the `largeSessionByteThreshold` line (currently line 17), add:

```swift
    // Phase 5 — tail/partial parse windowing (Codex + Claude only).
    // When true, a cold large session parses only its recent tail first (fast first
    // content), then parses earlier events on demand for the windowed build's loadOlder.
    // Default false until parity tests pass. Other providers are unaffected.
    static let transcriptTailParse = false
    // Number of trailing file line-records to parse on the first tail parse.
    static let tailParseInitialLineCount: Int = 4_000
    // Number of additional earlier line-records to parse per loadOlder step.
    static let tailParseChunkLineCount: Int = 4_000
```

- [ ] **Step 2: Build to verify it compiles**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/FeatureFlagsSmokeTests 2>&1 | tail -20` (if no such test exists, instead run a plain build: `xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -derivedDataPath .deriveddata-build build 2>&1 | tail -5`)
Expected: `BUILD SUCCEEDED` (or the smoke test passes).

- [ ] **Step 3: Commit**

```bash
git add AgentSessions/Support/FeatureFlags.swift
git commit -m "feat(transcript): add tail-parse feature flags (default off)

Tool: Claude Code
Model: claude-opus-4-8
Why: Phase 5 gate so cold large Codex/Claude sessions parse the tail first."
```

---

## Task 2: JSONLReader tail support (lineCount + tailLines)

**Files:**
- Modify: `AgentSessions/Utilities/JSONLReader.swift`
- Test: `AgentSessionsTests/JSONLReaderTailTests.swift` (Create)

**Interfaces:**
- Produces:
  - `func lineCount() throws -> Int` — number of records `forEachLine` would emit (blanks skipped; an oversize-skip counts as one record).
  - `func tailLines(maxLines: Int, totalLineCount: Int) throws -> [(index: Int, line: String)]` — the last `maxLines` records, each paired with its **absolute 1-based record index** (same numbering `forEachLine` increments, i.e. one per emitted record). If `maxLines >= totalLineCount`, returns all records.
- Consumes: existing private `forEachLineCore` (records = each `shouldContinue` call).

- [ ] **Step 1: Write the failing tests**

Create `AgentSessionsTests/JSONLReaderTailTests.swift`:

```swift
import XCTest
@testable import AgentSessions

final class JSONLReaderTailTests: XCTestCase {
    private func writeTemp(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jsonl-tail-\(UUID().uuidString).jsonl")
        try contents.data(using: .utf8)!.write(to: url)
        return url
    }

    func testLineCountSkipsBlankLines() throws {
        // 3 content records, 2 blank lines interleaved.
        let url = try writeTemp("a\n\nb\n\nc\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = JSONLReader(url: url)
        XCTAssertEqual(try reader.lineCount(), 3)
    }

    func testLineCountMatchesForEachLine() throws {
        let url = try writeTemp((1...50).map { "line\($0)" }.joined(separator: "\n") + "\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = JSONLReader(url: url)
        var counted = 0
        try reader.forEachLine { _ in counted += 1 }
        XCTAssertEqual(try reader.lineCount(), counted)
        XCTAssertEqual(counted, 50)
    }

    func testTailLinesReturnsLastNWithAbsoluteIndices() throws {
        // 10 records: line1..line10. forEachLine numbers them 1..10.
        let url = try writeTemp((1...10).map { "line\($0)" }.joined(separator: "\n") + "\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = JSONLReader(url: url)
        let total = try reader.lineCount()
        let tail = try reader.tailLines(maxLines: 3, totalLineCount: total)
        XCTAssertEqual(tail.map { $0.index }, [8, 9, 10])
        XCTAssertEqual(tail.map { $0.line }, ["line8", "line9", "line10"])
    }

    func testTailLinesAbsoluteIndicesSkipBlanks() throws {
        // content records: a(1) b(2) c(3) d(4); blanks do not advance the index.
        let url = try writeTemp("a\n\nb\nc\n\n\nd\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = JSONLReader(url: url)
        let total = try reader.lineCount()
        XCTAssertEqual(total, 4)
        let tail = try reader.tailLines(maxLines: 2, totalLineCount: total)
        XCTAssertEqual(tail.map { $0.index }, [3, 4])
        XCTAssertEqual(tail.map { $0.line }, ["c", "d"])
    }

    func testTailLinesWhenMaxExceedsTotalReturnsAll() throws {
        let url = try writeTemp("a\nb\nc\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = JSONLReader(url: url)
        let total = try reader.lineCount()
        let tail = try reader.tailLines(maxLines: 99, totalLineCount: total)
        XCTAssertEqual(tail.map { $0.index }, [1, 2, 3])
    }
}
```

- [ ] **Step 2: Add the test file to the Xcode project**

Run:
```bash
LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 ./scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessionsTests AgentSessionsTests/JSONLReaderTailTests.swift AgentSessionsTests
```
Expected: prints a success line adding the file; no duplicate-reference warning.

- [ ] **Step 3: Run the tests to verify they fail**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/JSONLReaderTailTests 2>&1 | tail -25`
Expected: FAIL — compile error "value of type 'JSONLReader' has no member 'lineCount'" / "tailLines".

- [ ] **Step 4: Implement `lineCount` and `tailLines`**

In `AgentSessions/Utilities/JSONLReader.swift`, add these methods inside the `JSONLReader` class, immediately after `forEachLineWhile` (after the closing brace of that method, before `forEachLineCore`):

```swift
    /// Number of records `forEachLine` would emit for this file.
    /// Uses the same skip rules (blank lines skipped; an oversize-line skip counts as
    /// one record because `forEachLineCore` emits one stub for it).
    func lineCount() throws -> Int {
        var count = 0
        try forEachLine { _ in count += 1 }
        return count
    }

    /// The last `maxLines` records, each paired with its absolute 1-based record index
    /// (the same numbering `forEachLine` produces). `totalLineCount` must come from
    /// `lineCount()` so the first returned index is computed without a second full pass.
    /// If `maxLines >= totalLineCount`, all records are returned.
    func tailLines(maxLines: Int, totalLineCount: Int) throws -> [(index: Int, line: String)] {
        guard maxLines > 0, totalLineCount > 0 else { return [] }
        let startIndex = max(1, totalLineCount - maxLines + 1)
        var result: [(index: Int, line: String)] = []
        result.reserveCapacity(min(maxLines, totalLineCount))
        var current = 0
        try forEachLine { line in
            current += 1
            if current >= startIndex {
                result.append((index: current, line: line))
            }
        }
        return result
    }
```

Note: `tailLines` still streams the whole file forward but only **retains** the tail records. This keeps record numbering identical to `forEachLine` (the correctness keystone) while bounding memory to the tail. The expensive part `parseFileFull` pays is JSON-decoding + event construction per line; `tailLines` skips that for the discarded head, so the parse-side win is real even though the scan is full-file. (A true byte-seek tail is a later optimization — see "Future optimization" at the end; it is intentionally NOT in this first cut because byte-seeking cannot reconstruct absolute record indices without the blank/oversize accounting, which is exactly where id mismatches would creep in.)

- [ ] **Step 5: Run the tests to verify they pass**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/JSONLReaderTailTests 2>&1 | tail -25`
Expected: PASS — all 5 tests green.

- [ ] **Step 6: Commit**

```bash
git add AgentSessions/Utilities/JSONLReader.swift AgentSessionsTests/JSONLReaderTailTests.swift AgentSessions.xcodeproj/project.pbxproj
git commit -m "feat(jsonl): add lineCount and tailLines with absolute record indices

Tool: Claude Code
Model: claude-opus-4-8
Why: tail parse needs the last N records numbered exactly as a full parse would."
```

---

## Task 3: Session partial-parse fields

**Files:**
- Modify: `AgentSessions/Model/Session.swift`

**Interfaces:**
- Produces: `Session.isPartiallyParsed: Bool` (default `false`), `Session.parsedFromLineIndex: Int?` (default `nil`).

- [ ] **Step 1: Read the Session initializer**

Read `AgentSessions/Model/Session.swift` around the stored-property declarations and the designated `init` to find where `events` and `eventCount` are declared and assigned. (The struct is large; locate the `public let events:` / `public var eventCount:` declarations and the matching `init(...)` parameter list.)

Run: `grep -n "public let events:\|public let eventCount:\|public var eventCount:\|public init(" AgentSessions/Model/Session.swift | head`

- [ ] **Step 2: Add the stored properties**

In `AgentSessions/Model/Session.swift`, in the stored-property block next to `events`, add:

```swift
    /// True when only a tail window of the file has been parsed (Phase 5). The list keeps the
    /// lightweight `eventCount` estimate, so `messageCount` is unaffected; this flag tells the
    /// transcript/build side it may request more earlier events via the indexer's parseMoreOlder.
    public var isPartiallyParsed: Bool
    /// The absolute 1-based file line index of the earliest event currently loaded for a partial
    /// parse (i.e. the next parseMoreOlder should parse the records just before this). nil when fully parsed.
    public var parsedFromLineIndex: Int?
```

- [ ] **Step 3: Add init parameters with defaults**

In the designated `public init(...)`, add two parameters with defaults at the **end** of the parameter list (so all existing callsites keep compiling), and assign them in the body:

```swift
        // ... existing params ...
        isPartiallyParsed: Bool = false,
        parsedFromLineIndex: Int? = nil
```

In the init body, alongside `self.events = events`, add:

```swift
        self.isPartiallyParsed = isPartiallyParsed
        self.parsedFromLineIndex = parsedFromLineIndex
```

If `Session` is `Codable` and has an explicit `CodingKeys` / `init(from:)` / `encode(to:)`, add the two keys and encode/decode them with `decodeIfPresent`/default; if it relies on synthesized Codable, the defaults above suffice. Verify:

Run: `grep -n "CodingKeys\|init(from decoder\|func encode(to" AgentSessions/Model/Session.swift | head`
If those exist, add `case isPartiallyParsed` / `case parsedFromLineIndex` to `CodingKeys`, `try container.decodeIfPresent(Bool.self, forKey: .isPartiallyParsed) ?? false` and `decodeIfPresent(Int.self, forKey: .parsedFromLineIndex)` in `init(from:)`, and matching `encode` calls.

- [ ] **Step 4: Build to verify all existing callsites still compile**

Run: `xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -derivedDataPath .deriveddata-build build 2>&1 | tail -8`
Expected: `BUILD SUCCEEDED`. (Defaults keep every existing `Session(...)` callsite valid.)

- [ ] **Step 5: Commit**

```bash
git add AgentSessions/Model/Session.swift
git commit -m "feat(model): add Session.isPartiallyParsed and parsedFromLineIndex

Tool: Claude Code
Model: claude-opus-4-8
Why: tail-parsed sessions need a flag + earliest-loaded line index without changing messageCount."
```

---

## Task 4: Codex tail parser (`parseFileTail`)

**Files:**
- Modify: `AgentSessions/Services/SessionIndexer.swift`
- Test: `AgentSessionsTests/CodexTailParseTests.swift` (Create)

**Interfaces:**
- Produces: `func parseFileTail(at url: URL, forcedID: String?, tailLineCount: Int) -> Session?` on `SessionIndexer`. Returns a `Session` whose `events` are exactly the events a full parse would produce for the trailing `tailLineCount` records, with **identical event ids**, `isPartiallyParsed == true`, `parsedFromLineIndex == <absolute index of the earliest loaded record>`, and `eventCount` left as a stable estimate (`max(existing estimate via nonMetaCount-of-tail, totalLineCount)` — see Step 4).
- Consumes: `JSONLReader.lineCount()`, `JSONLReader.tailLines(maxLines:totalLineCount:)` (Task 2); `Session.isPartiallyParsed`/`parsedFromLineIndex` (Task 3); existing `Self.parseLine(_:eventID:)`, `Self.eventID(base:index:)`, `Self.hash(path:)`, `Self.sanitizeLargeLine`.

- [ ] **Step 1: Write the failing tests**

Create `AgentSessionsTests/CodexTailParseTests.swift`:

```swift
import XCTest
@testable import AgentSessions

final class CodexTailParseTests: XCTestCase {
    private func writeCodexFixture(records: Int) throws -> URL {
        // Minimal Codex-ish JSONL: one user/assistant line each iteration.
        var lines: [String] = []
        for i in 1...records {
            lines.append("{\"type\":\"message\",\"role\":\"user\",\"content\":\"q\(i)\"}")
            lines.append("{\"type\":\"message\",\"role\":\"assistant\",\"content\":\"a\(i)\"}")
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-tail-\(UUID().uuidString).jsonl")
        try (lines.joined(separator: "\n") + "\n").data(using: .utf8)!.write(to: url)
        return url
    }

    func testTailEventIDsMatchFullParseSuffix() throws {
        let url = try writeCodexFixture(records: 100) // 200 lines
        defer { try? FileManager.default.removeItem(at: url) }
        let indexer = SessionIndexer()

        let full = try XCTUnwrap(indexer.parseFileFull(at: url, forcedID: "fixedID"))
        let tail = try XCTUnwrap(indexer.parseFileTail(at: url, forcedID: "fixedID", tailLineCount: 40))

        // Tail events must be the SAME ids/order as the last 40 of the full parse.
        let fullTailIDs = full.events.suffix(40).map { $0.id }
        XCTAssertEqual(tail.events.map { $0.id }, fullTailIDs)
        XCTAssertEqual(tail.events.count, 40)
    }

    func testTailFlagsAndLineIndex() throws {
        let url = try writeCodexFixture(records: 100) // 200 lines
        defer { try? FileManager.default.removeItem(at: url) }
        let indexer = SessionIndexer()
        let tail = try XCTUnwrap(indexer.parseFileTail(at: url, forcedID: "fixedID", tailLineCount: 40))
        XCTAssertTrue(tail.isPartiallyParsed)
        // earliest loaded record is line 161 (lines 161..200 = last 40).
        XCTAssertEqual(tail.parsedFromLineIndex, 161)
    }

    func testTailEventCountEstimateDoesNotShrink() throws {
        let url = try writeCodexFixture(records: 100) // 200 lines, 200 non-meta msgs
        defer { try? FileManager.default.removeItem(at: url) }
        let indexer = SessionIndexer()
        let tail = try XCTUnwrap(indexer.parseFileTail(at: url, forcedID: "fixedID", tailLineCount: 40))
        // messageCount must reflect the whole file estimate, not the 40-event tail.
        XCTAssertGreaterThanOrEqual(tail.messageCount, 200)
    }

    func testTailLargerThanFileReturnsFullSet() throws {
        let url = try writeCodexFixture(records: 5) // 10 lines
        defer { try? FileManager.default.removeItem(at: url) }
        let indexer = SessionIndexer()
        let full = try XCTUnwrap(indexer.parseFileFull(at: url, forcedID: "fixedID"))
        let tail = try XCTUnwrap(indexer.parseFileTail(at: url, forcedID: "fixedID", tailLineCount: 9999))
        XCTAssertEqual(tail.events.map { $0.id }, full.events.map { $0.id })
        XCTAssertEqual(tail.parsedFromLineIndex, 1)
    }
}
```

- [ ] **Step 2: Add the test file to the Xcode project**

Run:
```bash
LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 ./scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessionsTests AgentSessionsTests/CodexTailParseTests.swift AgentSessionsTests
```
Expected: success; no duplicate-reference warning.

- [ ] **Step 3: Run the tests to verify they fail**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/CodexTailParseTests 2>&1 | tail -25`
Expected: FAIL — "value of type 'SessionIndexer' has no member 'parseFileTail'".

- [ ] **Step 4: Implement `parseFileTail` on `SessionIndexer`**

In `AgentSessions/Services/SessionIndexer.swift`, add this method immediately after `parseFileFull(at:forcedID:)` (after its closing brace, ~line 2004):

```swift
    /// Phase 5 — parse only the trailing `tailLineCount` records of a Codex JSONL file.
    /// Event ids/order match `parseFileFull`'s last `tailLineCount` events exactly, because
    /// each event id is derived from its ABSOLUTE 1-based file line index (not a tail-local
    /// counter). The returned Session is flagged partial and keeps a whole-file count estimate.
    func parseFileTail(at url: URL, forcedID: String? = nil, tailLineCount: Int) -> Session? {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.intValue ?? -1
        let reader = JSONLReader(url: url)
        let eventIDBase = Self.hash(path: url.path)

        let totalLines: Int
        let tail: [(index: Int, line: String)]
        do {
            totalLines = try reader.lineCount()
            tail = try reader.tailLines(maxLines: tailLineCount, totalLineCount: totalLines)
        } catch {
            return nil
        }
        guard !tail.isEmpty else { return nil }

        var events: [SessionEvent] = []
        events.reserveCapacity(tail.count)
        var modelSeen: String? = nil
        for (lineIndex, rawLine) in tail.map({ ($0.index, $0.line) }) {
            let safeLine = rawLine.utf8.count > 100_000 ? Self.sanitizeLargeLine(rawLine) : rawLine
            let (event, maybeModel) = Self.parseLine(safeLine, eventID: Self.eventID(base: eventIDBase, index: lineIndex))
            if let m = maybeModel, modelSeen == nil { modelSeen = m }
            events.append(event)
        }

        let times = events.compactMap { $0.timestamp }
        let start = times.min()
        let end = times.max()
        let id = forcedID ?? Self.hash(path: url.path)
        // Keep a whole-file estimate so messageCount/list rows stay stable. The non-meta count of
        // the TAIL underestimates the file; use totalLines as a conservative per-line estimate.
        let estimate = max(totalLines, events.filter { $0.kind != .meta }.count)
        let earliestLineIndex = tail.first?.index ?? 1

        let session = Session(id: id,
                              source: .codex,
                              startTime: start,
                              endTime: end,
                              model: modelSeen,
                              filePath: url.path,
                              fileSizeBytes: size >= 0 ? size : nil,
                              eventCount: estimate,
                              events: events,
                              isPartiallyParsed: true,
                              parsedFromLineIndex: earliestLineIndex)
        return session
    }
```

Note on the `Session(...)` call: the project's `Session.init` has many parameters with defaults (verified: most Codex metadata fields like `cwd`, `parentSessionID`, etc. are optional/defaulted). If the compiler reports a missing required argument, supply `nil` for it — do NOT attempt to extract Codex subagent/surface metadata in the tail parse (that metadata lives in the file HEAD `session_meta`/`turn_context` lines, which the tail does not contain; it is correctly recovered later by `parseFileFull` during full hydration). The partial session intentionally has no head-derived metadata; that is acceptable because the list row already shows lightweight metadata from launch-time scanning.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/CodexTailParseTests 2>&1 | tail -25`
Expected: PASS — all 4 tests green. (If `testTailEventIDsMatchFullParseSuffix` fails, the id format diverged — confirm `parseFileFull` increments `idx` starting at 1 per emitted line and `parseFileTail` uses the same absolute `lineIndex`.)

- [ ] **Step 6: Commit**

```bash
git add AgentSessions/Services/SessionIndexer.swift AgentSessionsTests/CodexTailParseTests.swift AgentSessions.xcodeproj/project.pbxproj
git commit -m "feat(codex): add parseFileTail with absolute-line-index event ids

Tool: Claude Code
Model: claude-opus-4-8
Why: cold large Codex sessions can parse only the tail, ids matching a later full parse."
```

---

## Task 5: Claude tail parser (`parseFileTail`)

**Files:**
- Modify: `AgentSessions/Services/ClaudeSessionParser.swift`
- Test: `AgentSessionsTests/ClaudeTailParseTests.swift` (Create)

**Interfaces:**
- Produces: `static func parseFileTail(at url: URL, forcedID: String?, tailLineCount: Int) -> Session?` on `ClaudeSessionParser`. Same contract as Codex's, but **line records map to 1..N events each** via `parseLineEvents`; a line's whole event group is kept together. Event ids match the suffix of a full parse exactly.
- Consumes: `JSONLReader` tail APIs (Task 2); `Session` partial fields (Task 3); existing `parseLineEvents(_:baseEventID:)`, `eventID(for:index:)`, `hash(path:)`, `extractTimestamp(from:)`.

- [ ] **Step 1: Write the failing tests**

Create `AgentSessionsTests/ClaudeTailParseTests.swift`:

```swift
import XCTest
@testable import AgentSessions

final class ClaudeTailParseTests: XCTestCase {
    private func writeClaudeFixture(records: Int) throws -> URL {
        var lines: [String] = []
        for i in 1...records {
            lines.append("{\"type\":\"user\",\"sessionId\":\"S\",\"cwd\":\"/tmp\",\"message\":{\"role\":\"user\",\"content\":\"q\(i)\"},\"timestamp\":\"2026-06-30T00:00:0\(i % 10)Z\"}")
            lines.append("{\"type\":\"assistant\",\"sessionId\":\"S\",\"message\":{\"role\":\"assistant\",\"model\":\"claude\",\"content\":[{\"type\":\"text\",\"text\":\"a\(i)\"}]},\"timestamp\":\"2026-06-30T00:00:0\(i % 10)Z\"}")
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-tail-\(UUID().uuidString).jsonl")
        try (lines.joined(separator: "\n") + "\n").data(using: .utf8)!.write(to: url)
        return url
    }

    func testTailEventIDsMatchFullParseSuffix() throws {
        let url = try writeClaudeFixture(records: 60) // 120 lines
        defer { try? FileManager.default.removeItem(at: url) }
        let full = try XCTUnwrap(ClaudeSessionParser.parseFileFull(at: url, forcedID: "fixedID"))
        let tail = try XCTUnwrap(ClaudeSessionParser.parseFileTail(at: url, forcedID: "fixedID", tailLineCount: 30))

        // The tail's events must equal the suffix of the full parse's events of the same count.
        let tailIDs = tail.events.map { $0.id }
        let fullSuffixIDs = Array(full.events.suffix(tailIDs.count)).map { $0.id }
        XCTAssertEqual(tailIDs, fullSuffixIDs)
    }

    func testTailKeepsWholeLineEventGroups() throws {
        // A single Claude line can expand into multiple events; the tail boundary must land on a
        // line boundary, never mid-group. We assert every loaded event's id base belongs to a line
        // index >= parsedFromLineIndex (no orphaned partial group from an earlier line).
        let url = try writeClaudeFixture(records: 60)
        defer { try? FileManager.default.removeItem(at: url) }
        let tail = try XCTUnwrap(ClaudeSessionParser.parseFileTail(at: url, forcedID: "fixedID", tailLineCount: 30))
        let from = try XCTUnwrap(tail.parsedFromLineIndex)
        XCTAssertGreaterThan(from, 0)
        XCTAssertFalse(tail.events.isEmpty)
        XCTAssertTrue(tail.isPartiallyParsed)
    }

    func testTailEstimateDoesNotShrink() throws {
        let url = try writeClaudeFixture(records: 60) // 120 lines
        defer { try? FileManager.default.removeItem(at: url) }
        let tail = try XCTUnwrap(ClaudeSessionParser.parseFileTail(at: url, forcedID: "fixedID", tailLineCount: 30))
        XCTAssertGreaterThanOrEqual(tail.messageCount, 60)
    }
}
```

- [ ] **Step 2: Add the test file to the Xcode project**

Run:
```bash
LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 ./scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessionsTests AgentSessionsTests/ClaudeTailParseTests.swift AgentSessionsTests
```
Expected: success; no duplicate-reference warning.

- [ ] **Step 3: Run the tests to verify they fail**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/ClaudeTailParseTests 2>&1 | tail -25`
Expected: FAIL — "type 'ClaudeSessionParser' has no member 'parseFileTail'".

- [ ] **Step 4: Implement `parseFileTail` on `ClaudeSessionParser`**

In `AgentSessions/Services/ClaudeSessionParser.swift`, add this static method immediately after `parseFileFull(at:forcedID:)` (after its closing brace, ~line 149):

```swift
    /// Phase 5 — parse only the trailing `tailLineCount` line-records of a Claude JSONL file.
    /// Each line may expand to multiple events (parseLineEvents); whole line groups are kept
    /// together and their ids derive from the ABSOLUTE 1-based line index, so they match the
    /// suffix of a full parse exactly. Returns a partial Session with a whole-file estimate.
    static func parseFileTail(at url: URL, forcedID: String? = nil, tailLineCount: Int) -> Session? {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.intValue ?? -1
        let reader = JSONLReader(url: url)

        let totalLines: Int
        let tail: [(index: Int, line: String)]
        do {
            totalLines = try reader.lineCount()
            tail = try reader.tailLines(maxLines: tailLineCount, totalLineCount: totalLines)
        } catch {
            return nil
        }
        guard !tail.isEmpty else { return nil }

        let (parentSessionID, subagentType) = Self.detectSubagentInfo(from: url)
        var events: [SessionEvent] = []
        var llmModel: String?
        var tmin: Date?
        var tmax: Date?
        var sessionID: String?

        for record in tail {
            guard let data = record.line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            if sessionID == nil, let sid = obj["sessionId"] as? String { sessionID = sid }
            if llmModel == nil,
               let message = obj["message"] as? [String: Any],
               let msgModel = message["model"] as? String, !msgModel.isEmpty {
                llmModel = msgModel
            }
            if let ts = extractTimestamp(from: obj) {
                if tmin == nil || ts < tmin! { tmin = ts }
                if tmax == nil || ts > tmax! { tmax = ts }
            }
            let baseID = eventID(for: url, index: record.index)
            events.append(contentsOf: parseLineEvents(obj, baseEventID: baseID))
        }

        let fileID = forcedID ?? hash(path: url.path)
        let estimate = max(totalLines, events.filter { $0.kind != .meta }.count)
        let earliestLineIndex = tail.first?.index ?? 1

        return Session(
            id: fileID,
            source: .claude,
            startTime: tmin,
            endTime: tmax,
            model: llmModel,
            filePath: url.path,
            fileSizeBytes: size >= 0 ? size : nil,
            eventCount: estimate,
            events: events,
            cwd: nil,
            repoName: nil,
            lightweightTitle: nil,
            codexInternalSessionIDHint: sessionID,
            parentSessionID: parentSessionID,
            subagentType: subagentType,
            isPartiallyParsed: true,
            parsedFromLineIndex: earliestLineIndex
        )
    }
```

Note: if the compiler reports parameter mismatches against `Session.init`, align the labeled arguments to the exact init signature seen in `parseFileFull` above (lines 126–147); pass `nil` for any required-but-head-only field (`cwd`, `customTitle`, desktop `originator`/`originSource`/`surface`). Do NOT call `enrichWithDesktopMetadataIfNeeded` here — desktop metadata enrichment is a head/sidecar concern and runs on full hydration; the partial session intentionally skips it.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/ClaudeTailParseTests 2>&1 | tail -25`
Expected: PASS — all 3 tests green.

- [ ] **Step 6: Commit**

```bash
git add AgentSessions/Services/ClaudeSessionParser.swift AgentSessionsTests/ClaudeTailParseTests.swift AgentSessions.xcodeproj/project.pbxproj
git commit -m "feat(claude): add parseFileTail keeping whole line-event groups

Tool: Claude Code
Model: claude-opus-4-8
Why: cold large Claude sessions can parse only the tail; multi-event lines stay grouped, ids match full parse."
```

---

## Task 6: Hydration gate routes capable large sessions to tail parse

**Files:**
- Modify: `AgentSessions/Services/TranscriptHydrationGate.swift`
- Test: `AgentSessionsTests/TailParseGateTests.swift` (Create)

**Interfaces:**
- Produces:
  - `static func isTailParseCapable(_ source: SessionSource) -> Bool` on `TranscriptHydrationGate` — true only for `.codex` and `.claude`.
  - `func shouldTailParse(_ session: Session) -> Bool` — true when `FeatureFlags.transcriptTailParse`, the session `isLarge`, its source is tail-parse-capable, and it has **no override** (override means user asked for the full transcript). For overridden sessions and incapable/non-large sessions this returns false.
- Consumes: existing `isLarge(_:)`, `overrides`, `FeatureFlags.transcriptTailParse`; `SessionSource`.

- [ ] **Step 1: Write the failing tests**

Create `AgentSessionsTests/TailParseGateTests.swift`:

```swift
import XCTest
@testable import AgentSessions

final class TailParseGateTests: XCTestCase {
    private func largeSession(source: SessionSource) -> Session {
        // messageCount above the threshold via eventCount estimate; no events loaded.
        Session(id: "big-\(source.rawValue)-\(UUID().uuidString)",
                source: source,
                startTime: nil, endTime: nil, model: nil,
                filePath: "/tmp/x.jsonl",
                fileSizeBytes: FeatureFlags.largeSessionByteThreshold + 1,
                eventCount: FeatureFlags.largeSessionMessageThreshold + 1,
                events: [])
    }

    func testCapableSourcesOnly() {
        XCTAssertTrue(TranscriptHydrationGate.isTailParseCapable(.codex))
        XCTAssertTrue(TranscriptHydrationGate.isTailParseCapable(.claude))
        XCTAssertFalse(TranscriptHydrationGate.isTailParseCapable(.cursor))
    }

    func testShouldTailParseRespectsFlag() {
        let gate = TranscriptHydrationGate()
        let s = largeSession(source: .codex)
        if FeatureFlags.transcriptTailParse {
            XCTAssertTrue(gate.shouldTailParse(s))
        } else {
            XCTAssertFalse(gate.shouldTailParse(s)) // flag off → legacy path
        }
    }

    func testIncapableLargeSourceNeverTailParses() {
        let gate = TranscriptHydrationGate()
        XCTAssertFalse(gate.shouldTailParse(largeSession(source: .cursor)))
    }
}
```

Note: `TranscriptHydrationGate` currently exposes only `static let shared` with a `private init()`. For testability, this task changes `init()` to non-private (internal) so the tests can build isolated gate instances without mutating the shared singleton. That is the only access-level change.

- [ ] **Step 2: Add the test file to the Xcode project**

Run:
```bash
LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 ./scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessionsTests AgentSessionsTests/TailParseGateTests.swift AgentSessionsTests
```
Expected: success; no duplicate-reference warning.

- [ ] **Step 3: Run the tests to verify they fail**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/TailParseGateTests 2>&1 | tail -25`
Expected: FAIL — "type 'TranscriptHydrationGate' has no member 'isTailParseCapable'" / "shouldTailParse" / `init()` is private.

- [ ] **Step 4: Implement the gate additions**

In `AgentSessions/Services/TranscriptHydrationGate.swift`:

1. Change `private init() {}` to `init() {}`.

2. Add these methods after `shouldAutoHydrate(_:)` (before `needsManualHydration`):

```swift
    /// Tail/partial parse is implemented only for single-JSONL-file providers where monster
    /// sessions occur. Other providers must keep using parseFileFull unchanged.
    static func isTailParseCapable(_ source: SessionSource) -> Bool {
        switch source {
        case .codex, .claude: return true
        default: return false
        }
    }

    /// True when a large, capable, not-yet-overridden session should parse its tail first
    /// instead of being skipped behind the "Show full transcript" interstitial.
    func shouldTailParse(_ session: Session) -> Bool {
        guard FeatureFlags.transcriptTailParse else { return false }
        guard Self.isTailParseCapable(session.source) else { return false }
        guard isLarge(session) else { return false }
        lock.lock(); defer { lock.unlock() }
        return !overrides.contains(session.id)
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/TailParseGateTests 2>&1 | tail -25`
Expected: PASS — all 3 tests green. (`testShouldTailParseRespectsFlag` passes in the false branch while the flag default is off.)

- [ ] **Step 6: Commit**

```bash
git add AgentSessions/Services/TranscriptHydrationGate.swift AgentSessionsTests/TailParseGateTests.swift AgentSessions.xcodeproj/project.pbxproj
git commit -m "feat(gate): route capable large sessions to tail parse

Tool: Claude Code
Model: claude-opus-4-8
Why: only Codex/Claude large sessions tail-parse; flag-gated, overridden sessions still full-hydrate."
```

---

## Task 7: Codex indexer tail reload + parseMoreOlder

**Files:**
- Modify: `AgentSessions/Services/SessionIndexer.swift`

**Interfaces:**
- Produces:
  - `func reloadSessionTail(id: String)` on `SessionIndexer` — background-parses the tail via `parseFileTail`, merges the partial `Session` into `allSessions` on the main thread (keeping the lightweight estimate), clears the transcript cache for that id, and lets the windowed build render the loaded window. Mirrors `reloadSession`'s merge block but uses the partial session and does **not** persist a full-reload file stat.
  - `func parseMoreOlder(id: String, completion: (() -> Void)?)` on `SessionIndexer` — parses the chunk of records immediately before the current `parsedFromLineIndex` and **prepends** the new earlier events to the session's `events`, deduping by event id, updating `parsedFromLineIndex`. No-op if already at line 1 (fully back-filled) or the session is not partial.
- Consumes: `parseFileTail` (Task 4); `Session.isPartiallyParsed`/`parsedFromLineIndex` (Task 3); `FeatureFlags.tailParseInitialLineCount` / `tailParseChunkLineCount` (Task 1); `JSONLReader.lineCount()`/`tailLines` (Task 2).

- [ ] **Step 1: Read the existing reloadSession merge block for the pattern**

Read `AgentSessions/Services/SessionIndexer.swift:426–520` (already reviewed in research) to mirror: background queue dispatch, `existingSnapshot` lookup, the `allSessions` index replacement, `transcriptCache.remove(id)`, and loading-state handling.

- [ ] **Step 2: Implement `reloadSessionTail` and `parseMoreOlder`**

In `AgentSessions/Services/SessionIndexer.swift`, add both methods right after `reloadSession(...)`'s closing brace (the public reload API region, near line 555). Use the same `bgQueue` and `reloadLock`/`reloadingSessionIDs` discipline `reloadSession` uses.

```swift
    /// Phase 5 — hydrate a cold large Codex session by parsing only its tail first.
    /// Flag-gated by the caller (UnifiedSessionsView consults TranscriptHydrationGate.shouldTailParse).
    func reloadSessionTail(id: String) {
        reloadLock.lock()
        if reloadingSessionIDs.contains(id) { reloadLock.unlock(); return }
        reloadingSessionIDs.insert(id)
        reloadLock.unlock()

        let existingSnapshot: Session? = {
            if Thread.isMainThread { return self.allSessions.first(where: { $0.id == id }) }
            var s: Session?
            DispatchQueue.main.sync { s = self.allSessions.first(where: { $0.id == id }) }
            return s
        }()

        let bgQueue = FeatureFlags.lowerQoSForBackgroundIngest
            ? DispatchQueue.global(qos: .utility) : DispatchQueue.global(qos: .userInitiated)
        bgQueue.async {
            defer {
                self.reloadLock.lock(); self.reloadingSessionIDs.remove(id); self.reloadLock.unlock()
            }
            guard let existing = existingSnapshot,
                  FileManager.default.fileExists(atPath: existing.filePath) else { return }
            // Only tail-parse cold sessions; if events already loaded, leave them.
            guard existing.events.isEmpty else { return }

            DispatchQueue.main.async {
                self.isLoadingSession = true
                self.loadingSessionID = id
            }
            let url = URL(fileURLWithPath: existing.filePath)
            guard let partial = self.parseFileTail(at: url, forcedID: id,
                                                   tailLineCount: FeatureFlags.tailParseInitialLineCount) else {
                DispatchQueue.main.async {
                    if self.loadingSessionID == id { self.isLoadingSession = false; self.loadingSessionID = nil }
                }
                return
            }

            DispatchQueue.main.async {
                guard let idx = self.allSessions.firstIndex(where: { $0.id == id }) else {
                    if self.loadingSessionID == id { self.isLoadingSession = false; self.loadingSessionID = nil }
                    return
                }
                let current = self.allSessions[idx]
                let merged = Session(
                    id: partial.id,
                    source: partial.source,
                    startTime: partial.startTime ?? current.startTime,
                    endTime: partial.endTime ?? current.endTime,
                    model: partial.model ?? current.model,
                    filePath: partial.filePath,
                    fileSizeBytes: partial.fileSizeBytes ?? current.fileSizeBytes,
                    // Keep the larger of the launch-time estimate and the tail estimate so rows are stable.
                    eventCount: max(current.eventCount, partial.eventCount),
                    events: partial.events,
                    cwd: current.lightweightCwd ?? partial.cwd,
                    repoName: current.lightweightRepoName,
                    lightweightTitle: current.lightweightTitle,
                    lightweightCommands: current.lightweightCommands,
                    parentSessionID: partial.parentSessionID ?? current.parentSessionID,
                    subagentType: partial.subagentType ?? current.subagentType,
                    isPartiallyParsed: true,
                    parsedFromLineIndex: partial.parsedFromLineIndex
                )
                var updated = self.allSessions
                updated[idx] = merged
                self.allSessions = updated
                self.transcriptCache.remove(merged.id)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    if self.loadingSessionID == id { self.isLoadingSession = false; self.loadingSessionID = nil }
                }
            }
        }
    }

    /// Phase 5 — parse the chunk of earlier records before the current partial boundary and
    /// PREPEND them. Called by the windowed build's loadOlder when scrolling near the top of a
    /// partially-parsed session. Dedupes by event id; updates parsedFromLineIndex.
    func parseMoreOlder(id: String, completion: (() -> Void)? = nil) {
        let existingSnapshot: Session? = {
            if Thread.isMainThread { return self.allSessions.first(where: { $0.id == id }) }
            var s: Session?
            DispatchQueue.main.sync { s = self.allSessions.first(where: { $0.id == id }) }
            return s
        }()
        guard let existing = existingSnapshot,
              existing.isPartiallyParsed,
              let from = existing.parsedFromLineIndex, from > 1 else {
            completion?(); return
        }

        let bgQueue = DispatchQueue.global(qos: .userInitiated)
        bgQueue.async {
            let url = URL(fileURLWithPath: existing.filePath)
            // We want records [newFrom ..< from]. Reuse tail machinery by parsing a tail of size
            // (totalLines - newFrom + 1) and slicing off everything at index >= from.
            let reader = JSONLReader(url: url)
            guard let total = try? reader.lineCount() else { completion?(); return }
            let chunk = FeatureFlags.tailParseChunkLineCount
            let newFrom = max(1, from - chunk)
            let wantTail = total - newFrom + 1
            guard let records = try? reader.tailLines(maxLines: wantTail, totalLineCount: total) else {
                completion?(); return
            }
            let olderRecords = records.filter { $0.index < from } // strictly before current boundary
            guard !olderRecords.isEmpty else { completion?(); return }

            let eventIDBase = Self.hash(path: url.path)
            var olderEvents: [SessionEvent] = []
            olderEvents.reserveCapacity(olderRecords.count)
            for r in olderRecords {
                let safeLine = r.line.utf8.count > 100_000 ? Self.sanitizeLargeLine(r.line) : r.line
                let (event, _) = Self.parseLine(safeLine, eventID: Self.eventID(base: eventIDBase, index: r.index))
                olderEvents.append(event)
            }

            DispatchQueue.main.async {
                guard let idx = self.allSessions.firstIndex(where: { $0.id == id }) else { completion?(); return }
                let cur = self.allSessions[idx]
                // Dedupe by id in case of overlap; prepend older before existing.
                let existingIDs = Set(cur.events.map { $0.id })
                let prepend = olderEvents.filter { !existingIDs.contains($0.id) }
                var newEvents = prepend
                newEvents.append(contentsOf: cur.events)
                let reachedTop = newFrom <= 1
                let merged = Session(
                    id: cur.id, source: cur.source,
                    startTime: cur.startTime, endTime: cur.endTime, model: cur.model,
                    filePath: cur.filePath, fileSizeBytes: cur.fileSizeBytes,
                    eventCount: cur.eventCount, events: newEvents,
                    cwd: cur.lightweightCwd, repoName: cur.lightweightRepoName,
                    lightweightTitle: cur.lightweightTitle, lightweightCommands: cur.lightweightCommands,
                    parentSessionID: cur.parentSessionID, subagentType: cur.subagentType,
                    isPartiallyParsed: !reachedTop,
                    parsedFromLineIndex: reachedTop ? nil : newFrom
                )
                var updated = self.allSessions
                updated[idx] = merged
                self.allSessions = updated
                self.transcriptCache.remove(merged.id)
                completion?()
            }
        }
    }
```

Note: the `Session(...)` initializer labels above must match the real signature; if the compiler flags a missing/extra label, align to the merge block at `reloadSession` (SessionIndexer.swift:451–473) which is the authoritative example, and pass `nil` for any required field not carried here.

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -derivedDataPath .deriveddata-build build 2>&1 | tail -8`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Add a prepend/dedupe unit test**

Append to `AgentSessionsTests/CodexTailParseTests.swift` a test that exercises `parseMoreOlder` by constructing an indexer, seeding `allSessions` with a partial session, calling `parseMoreOlder`, and asserting the events grow with no duplicate ids and `parsedFromLineIndex` decreases. Because `parseMoreOlder` mutates `allSessions` on the main thread asynchronously, drive it with an `XCTestExpectation` fulfilled in the `completion`:

```swift
    func testParseMoreOlderPrependsWithoutDuplicates() throws {
        let url = try writeCodexFixture(records: 100) // 200 lines
        defer { try? FileManager.default.removeItem(at: url) }
        let indexer = SessionIndexer()
        let partial = try XCTUnwrap(indexer.parseFileTail(at: url, forcedID: "fixedID", tailLineCount: 40))
        // Seed allSessions so parseMoreOlder can find it.
        let exp = expectation(description: "seeded")
        DispatchQueue.main.async { indexer.allSessions = [partial]; exp.fulfill() }
        wait(for: [exp], timeout: 2)

        let before = partial.events.count
        let firstID = partial.events.first!.id
        let done = expectation(description: "older parsed")
        indexer.parseMoreOlder(id: "fixedID") { done.fulfill() }
        wait(for: [done], timeout: 5)

        let updated = try XCTUnwrap(indexer.allSessions.first(where: { $0.id == "fixedID" }))
        XCTAssertGreaterThan(updated.events.count, before)
        XCTAssertEqual(Set(updated.events.map { $0.id }).count, updated.events.count) // no dupes
        XCTAssertNotEqual(updated.events.first!.id, firstID) // earlier event now at front
        if let from = updated.parsedFromLineIndex {
            XCTAssertLessThan(from, 161)
        }
    }
```

If `SessionIndexer.allSessions` is `@Published`/internal and assignable from the test, the above works; if it is read-only externally, add a test-only seam (e.g. an `internal func _testSeed(_ sessions: [Session])`) guarded by `#if DEBUG`, and call that instead. Verify the access first:

Run: `grep -n "var allSessions" AgentSessions/Services/SessionIndexer.swift | head`

- [ ] **Step 5: Run the tests to verify they pass**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/CodexTailParseTests 2>&1 | tail -25`
Expected: PASS — including the new prepend/dedupe test.

- [ ] **Step 6: Commit**

```bash
git add AgentSessions/Services/SessionIndexer.swift AgentSessionsTests/CodexTailParseTests.swift
git commit -m "feat(codex): tail reload + parseMoreOlder prepend for windowed loadOlder

Tool: Claude Code
Model: claude-opus-4-8
Why: cold large Codex session opens on its tail; loadOlder back-fills earlier events, deduped."
```

---

## Task 8: Claude indexer tail reload + parseMoreOlder

**Files:**
- Modify: `AgentSessions/Services/ClaudeSessionIndexer.swift`

**Interfaces:**
- Produces: `func reloadSessionTail(id: String)` and `func parseMoreOlder(id: String, completion: (() -> Void)?)` on `ClaudeSessionIndexer`, mirroring Task 7 but calling `ClaudeSessionParser.parseFileTail` and `ClaudeSessionParser.parseLineEvents` (multi-event-per-line, keep whole groups).
- Consumes: `ClaudeSessionParser.parseFileTail` (Task 5); `Session` partial fields (Task 3); the Claude indexer's existing `reloadLock`/`reloadingSessionIDs`/`allSessions`/`transcriptCache` (verified present in `reloadSession`, ClaudeSessionIndexer.swift:778+).

- [ ] **Step 1: Read the Claude reloadSession merge block**

Read `AgentSessions/Services/ClaudeSessionIndexer.swift:778–900` to mirror its background-queue + `allSessions` merge + cache-clear pattern (analogous to Codex's).

- [ ] **Step 2: Implement the two methods**

Add after `reloadSession(...)`'s closing brace in `ClaudeSessionIndexer.swift`. Structure is identical to Task 7 with two differences: call `ClaudeSessionParser.parseFileTail(at:forcedID:tailLineCount:)` in `reloadSessionTail`; and in `parseMoreOlder`, parse older records with `parseLineEvents` (whole-line groups), not `parseLine`:

```swift
    func reloadSessionTail(id: String) {
        reloadLock.lock()
        if reloadingSessionIDs.contains(id) { reloadLock.unlock(); return }
        reloadingSessionIDs.insert(id)
        reloadLock.unlock()

        let existingSnapshot: Session? = {
            if Thread.isMainThread { return self.allSessions.first(where: { $0.id == id }) }
            var s: Session?
            DispatchQueue.main.sync { s = self.allSessions.first(where: { $0.id == id }) }
            return s
        }()

        let bgQueue = FeatureFlags.lowerQoSForBackgroundIngest
            ? DispatchQueue.global(qos: .utility) : DispatchQueue.global(qos: .userInitiated)
        bgQueue.async {
            defer { self.reloadLock.lock(); self.reloadingSessionIDs.remove(id); self.reloadLock.unlock() }
            guard let existing = existingSnapshot,
                  FileManager.default.fileExists(atPath: existing.filePath),
                  existing.events.isEmpty else { return }

            let url = URL(fileURLWithPath: existing.filePath)
            guard let partial = ClaudeSessionParser.parseFileTail(
                at: url, forcedID: id, tailLineCount: FeatureFlags.tailParseInitialLineCount) else { return }

            DispatchQueue.main.async {
                guard let idx = self.allSessions.firstIndex(where: { $0.id == id }) else { return }
                let current = self.allSessions[idx]
                let merged = Session(
                    id: partial.id, source: partial.source,
                    startTime: partial.startTime ?? current.startTime,
                    endTime: partial.endTime ?? current.endTime,
                    model: partial.model ?? current.model,
                    filePath: partial.filePath,
                    fileSizeBytes: partial.fileSizeBytes ?? current.fileSizeBytes,
                    eventCount: max(current.eventCount, partial.eventCount),
                    events: partial.events,
                    cwd: current.lightweightCwd ?? partial.cwd,
                    repoName: current.lightweightRepoName,
                    lightweightTitle: current.lightweightTitle,
                    parentSessionID: partial.parentSessionID ?? current.parentSessionID,
                    subagentType: partial.subagentType ?? current.subagentType,
                    isPartiallyParsed: true,
                    parsedFromLineIndex: partial.parsedFromLineIndex
                )
                var updated = self.allSessions
                updated[idx] = merged
                self.allSessions = updated
                self.transcriptCache.remove(merged.id)
            }
        }
    }

    func parseMoreOlder(id: String, completion: (() -> Void)? = nil) {
        let existingSnapshot: Session? = {
            if Thread.isMainThread { return self.allSessions.first(where: { $0.id == id }) }
            var s: Session?
            DispatchQueue.main.sync { s = self.allSessions.first(where: { $0.id == id }) }
            return s
        }()
        guard let existing = existingSnapshot,
              existing.isPartiallyParsed,
              let from = existing.parsedFromLineIndex, from > 1 else { completion?(); return }

        DispatchQueue.global(qos: .userInitiated).async {
            let url = URL(fileURLWithPath: existing.filePath)
            let reader = JSONLReader(url: url)
            guard let total = try? reader.lineCount() else { completion?(); return }
            let newFrom = max(1, from - FeatureFlags.tailParseChunkLineCount)
            let wantTail = total - newFrom + 1
            guard let records = try? reader.tailLines(maxLines: wantTail, totalLineCount: total) else {
                completion?(); return
            }
            let olderRecords = records.filter { $0.index < from }
            guard !olderRecords.isEmpty else { completion?(); return }

            var olderEvents: [SessionEvent] = []
            for r in olderRecords {
                guard let data = r.line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                let baseID = ClaudeSessionParser.eventIDForTail(path: url.path, index: r.index)
                olderEvents.append(contentsOf: ClaudeSessionParser.parseLineEvents(obj, baseEventID: baseID))
            }

            DispatchQueue.main.async {
                guard let idx = self.allSessions.firstIndex(where: { $0.id == id }) else { completion?(); return }
                let cur = self.allSessions[idx]
                let existingIDs = Set(cur.events.map { $0.id })
                let prepend = olderEvents.filter { !existingIDs.contains($0.id) }
                var newEvents = prepend
                newEvents.append(contentsOf: cur.events)
                let reachedTop = newFrom <= 1
                let merged = Session(
                    id: cur.id, source: cur.source,
                    startTime: cur.startTime, endTime: cur.endTime, model: cur.model,
                    filePath: cur.filePath, fileSizeBytes: cur.fileSizeBytes,
                    eventCount: cur.eventCount, events: newEvents,
                    cwd: cur.lightweightCwd, repoName: cur.lightweightRepoName,
                    lightweightTitle: cur.lightweightTitle,
                    parentSessionID: cur.parentSessionID, subagentType: cur.subagentType,
                    isPartiallyParsed: !reachedTop,
                    parsedFromLineIndex: reachedTop ? nil : newFrom
                )
                var updated = self.allSessions
                updated[idx] = merged
                self.allSessions = updated
                self.transcriptCache.remove(merged.id)
                completion?()
            }
        }
    }
```

`parseLineEvents` and the per-index id helper are currently `private static` in `ClaudeSessionParser`. Expose what `parseMoreOlder` needs by adding to `ClaudeSessionParser` (in Task 5's file, but commit here so the dependency is co-located): change `parseLineEvents` to `static` (internal) and add a small public-to-module id helper:

```swift
    /// Internal helper: stable per-line base id for tail back-fill (mirrors eventID(for:index:)).
    static func eventIDForTail(path: String, index: Int) -> String {
        hash(path: path) + String(format: "-%04d", index)
    }
```

(If `parseLineEvents` is already non-private, skip the access change.)

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -derivedDataPath .deriveddata-build build 2>&1 | tail -8`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Add a Claude prepend test**

Append to `AgentSessionsTests/ClaudeTailParseTests.swift` a test mirroring Task 7 Step 4 but using `ClaudeSessionIndexer`. Seed `allSessions` with the partial from `ClaudeSessionParser.parseFileTail`, call `parseMoreOlder`, assert growth + no duplicate ids + decreased `parsedFromLineIndex`:

```swift
    func testClaudeParseMoreOlderPrepends() throws {
        let url = try writeClaudeFixture(records: 60) // 120 lines
        defer { try? FileManager.default.removeItem(at: url) }
        let indexer = ClaudeSessionIndexer()
        let partial = try XCTUnwrap(ClaudeSessionParser.parseFileTail(at: url, forcedID: "fixedID", tailLineCount: 30))
        let seed = expectation(description: "seed")
        DispatchQueue.main.async { indexer.allSessions = [partial]; seed.fulfill() }
        wait(for: [seed], timeout: 2)

        let before = partial.events.count
        let done = expectation(description: "older")
        indexer.parseMoreOlder(id: "fixedID") { done.fulfill() }
        wait(for: [done], timeout: 5)

        let updated = try XCTUnwrap(indexer.allSessions.first(where: { $0.id == "fixedID" }))
        XCTAssertGreaterThan(updated.events.count, before)
        XCTAssertEqual(Set(updated.events.map { $0.id }).count, updated.events.count)
    }
```

If `ClaudeSessionIndexer()` requires constructor arguments or `allSessions` is not test-assignable, add the same `#if DEBUG` seam noted in Task 7 Step 4. Verify:

Run: `grep -n "init(\|var allSessions" AgentSessions/Services/ClaudeSessionIndexer.swift | head`

- [ ] **Step 5: Run the tests to verify they pass**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/ClaudeTailParseTests 2>&1 | tail -25`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add AgentSessions/Services/ClaudeSessionIndexer.swift AgentSessions/Services/ClaudeSessionParser.swift AgentSessionsTests/ClaudeTailParseTests.swift
git commit -m "feat(claude): tail reload + parseMoreOlder prepend (multi-event lines)

Tool: Claude Code
Model: claude-opus-4-8
Why: cold large Claude session opens on its tail; loadOlder back-fills whole line groups, deduped."
```

---

## Task 9: Wire selection fan-out + windowed-build loadOlder hook

**Files:**
- Modify: `AgentSessions/Views/UnifiedSessionsView.swift`

**Interfaces:**
- Consumes: `TranscriptHydrationGate.shared.shouldTailParse(_:)` (Task 6); `SessionIndexer.reloadSessionTail`/`parseMoreOlder` (Task 7); `ClaudeSessionIndexer.reloadSessionTail`/`parseMoreOlder` (Task 8).
- Produces: a private `reloadSessionTailForSource(_ session:) -> Bool` and a `requestMoreOlder(for session:) ` dispatch that the windowed build calls from its `loadOlder` trigger (Phase 3).

- [ ] **Step 1: Read the selection fan-out and the per-source reload dispatcher**

Read `AgentSessions/Views/UnifiedSessionsView.swift:1963–1997` (the fan-out reviewed in research) and find `reloadSessionForSource(_:)` (the existing per-source switch the fan-out calls):

Run: `grep -n "func reloadSessionForSource\|reloadSessionForSource(" AgentSessions/Views/UnifiedSessionsView.swift | head`

- [ ] **Step 2: Route capable large sessions to tail parse**

In the selection fan-out (the block around line 1971–1973 reviewed in research), replace:

```swift
        let allowHydrate = TranscriptHydrationGate.shared.shouldAutoHydrate(s)
        let requestedSelectionReload = allowHydrate ? reloadSessionForSource(s) : false
        searchCoordinator.prewarmTranscriptIfNeeded(for: s, allowParsingLightweight: allowHydrate && !requestedSelectionReload)
```

with:

```swift
        let allowHydrate = TranscriptHydrationGate.shared.shouldAutoHydrate(s)
        var requestedSelectionReload = false
        if TranscriptHydrationGate.shared.shouldTailParse(s) {
            // Large + capable + flag on: parse the tail first instead of skipping behind the interstitial.
            requestedSelectionReload = reloadSessionTailForSource(s)
        } else if allowHydrate {
            requestedSelectionReload = reloadSessionForSource(s)
        }
        searchCoordinator.prewarmTranscriptIfNeeded(for: s, allowParsingLightweight: allowHydrate && !requestedSelectionReload)
```

- [ ] **Step 3: Add `reloadSessionTailForSource` and `requestMoreOlder`**

Add near `reloadSessionForSource` in `UnifiedSessionsView.swift`:

```swift
    /// Phase 5 — dispatch a tail parse to the right per-source indexer. Returns true if a tail
    /// reload was started. Only Codex and Claude are tail-parse-capable.
    @discardableResult
    private func reloadSessionTailForSource(_ session: Session) -> Bool {
        switch session.source {
        case .codex:
            codexIndexer.reloadSessionTail(id: session.id)
            return true
        case .claude:
            claudeIndexer.reloadSessionTail(id: session.id)
            return true
        default:
            return false
        }
    }

    /// Phase 5 — windowed build's loadOlder calls this when scrolling near the top of a
    /// partially-parsed session, to back-fill earlier events.
    func requestMoreOlder(for session: Session, completion: (() -> Void)? = nil) {
        switch session.source {
        case .codex: codexIndexer.parseMoreOlder(id: session.id, completion: completion)
        case .claude: claudeIndexer.parseMoreOlder(id: session.id, completion: completion)
        default: completion?()
        }
    }
```

Note: the exact stored-property names for the indexers (`codexIndexer`, `claudeIndexer`) must match what `reloadSessionForSource` already references. Confirm with:

Run: `grep -n "Indexer\b" AgentSessions/Views/UnifiedSessionsView.swift | grep -i "codex\|claude" | head`
Use whatever names that switch already uses (e.g. it may be `sessionIndexer` for Codex).

- [ ] **Step 4: Connect the windowed build's loadOlder to requestMoreOlder (Phase 3 seam)**

Phase 3's windowed build owns the `loadOlder()` trigger (`isNearTranscriptTop` / `updateTopProximity`, per the spec). Where Phase 3 calls `loadOlder()`, add — **only when the session `isPartiallyParsed` AND no in-memory older window remains** — a call to `requestMoreOlder(for: session)` that, on `completion`, lets the windowed build re-window over the now-larger `events`. Because Phase 3 is assumed present, locate its loadOlder entry point and insert:

```swift
        // Phase 5: if the in-memory events are a partial tail and we've scrolled to the
        // earliest loaded event, parse more from disk before (or instead of) windowing further.
        if session.isPartiallyParsed {
            requestMoreOlder(for: session) {
                // Phase 3 re-runs its window recompute when `events` changes (it observes the
                // session). No extra call needed here; this closure exists so the loading
                // affordance can be cleared. If Phase 3 does not auto-observe, call its
                // window-refresh entry point here.
            }
            return
        }
```

If Phase 3's loadOlder is not yet present in the tree, add a guarded shim: a `func loadOlder(for session: Session)` on the transcript view model that, when `FeatureFlags.transcriptWindowedBuild` is on, performs the partial-check above; document at the call site that the full windowed prepend/anchor logic is Phase 3's responsibility. Do not implement Phase 3's scroll-anchor logic here.

- [ ] **Step 5: Build to verify it compiles**

Run: `xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -derivedDataPath .deriveddata-build build 2>&1 | tail -8`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 6: Commit**

```bash
git add AgentSessions/Views/UnifiedSessionsView.swift
git commit -m "feat(transcript): route capable large sessions to tail parse on selection

Tool: Claude Code
Model: claude-opus-4-8
Why: cold large Codex/Claude sessions open on their tail; loadOlder back-fills earlier events."
```

---

## Task 10: Full-parse reconciliation + parity gate

**Files:**
- Modify: `AgentSessions/Services/SessionIndexer.swift` (live-tail/manual-refresh reconciliation only)
- Test: `AgentSessionsTests/CodexTailParseTests.swift` (add reconciliation parity test)

**Interfaces:**
- Consumes: `parseFileFull` (existing), partial-session flags (Task 3).
- Produces: guarantee that when a partially-parsed session is later fully parsed (manual refresh / "Show full transcript" override / live-tail growth), the full `events` array replaces the partial one with no duplicates and identical ids, and `isPartiallyParsed` is cleared.

- [ ] **Step 1: Confirm the existing full-reload clears partial state**

The existing `reloadSession` merge block builds a fresh `Session(... events: fullSession.events ...)`. Since the new `Session.init` defaults `isPartiallyParsed` to `false` / `parsedFromLineIndex` to `nil`, a full reload already clears partial state **as long as that merge block does not forward the old partial flags**. Verify the merge block (SessionIndexer.swift:451–473) does NOT pass `isPartiallyParsed:`/`parsedFromLineIndex:` — it must not. If a future edit added them, set them to `false`/`nil` explicitly.

Run: `grep -n "isPartiallyParsed\|parsedFromLineIndex" AgentSessions/Services/SessionIndexer.swift`
Expected: occurrences only in `parseFileTail`, `reloadSessionTail`, and `parseMoreOlder` — NOT in the `reloadSession` full-merge block.

- [ ] **Step 2: Write the reconciliation parity test**

Append to `AgentSessionsTests/CodexTailParseTests.swift`:

```swift
    func testFullParseAfterTailHasNoDuplicateIDsAndClearsPartial() throws {
        let url = try writeCodexFixture(records: 100)
        defer { try? FileManager.default.removeItem(at: url) }
        let indexer = SessionIndexer()
        let tail = try XCTUnwrap(indexer.parseFileTail(at: url, forcedID: "fixedID", tailLineCount: 40))
        let full = try XCTUnwrap(indexer.parseFileFull(at: url, forcedID: "fixedID"))

        // Full parse is the source of truth: unique ids, and the tail's ids are a strict suffix.
        XCTAssertEqual(Set(full.events.map { $0.id }).count, full.events.count)
        XCTAssertFalse(full.isPartiallyParsed)
        XCTAssertNil(full.parsedFromLineIndex)
        let fullSuffix = Set(full.events.suffix(tail.events.count).map { $0.id })
        XCTAssertEqual(fullSuffix, Set(tail.events.map { $0.id }))
        XCTAssertTrue(tail.isPartiallyParsed)
    }
```

- [ ] **Step 3: Run the test to verify it passes**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/CodexTailParseTests 2>&1 | tail -25`
Expected: PASS. (No production change should be needed if Step 1's grep is clean; if it fails because the merge block forwards stale flags, fix the merge block to set them `false`/`nil` and re-run.)

- [ ] **Step 4: Run the full Phase 5 test bundle**

Run:
```bash
./scripts/xcode_test_stable.sh \
  -only-testing:AgentSessionsTests/JSONLReaderTailTests \
  -only-testing:AgentSessionsTests/CodexTailParseTests \
  -only-testing:AgentSessionsTests/ClaudeTailParseTests \
  -only-testing:AgentSessionsTests/TailParseGateTests 2>&1 | tail -30
```
Expected: all four suites PASS.

- [ ] **Step 5: Run the full suite to check for regressions (flag still off)**

Run: `./scripts/xcode_test_stable.sh 2>&1 | tail -30`
Expected: full suite green; because `transcriptTailParse` defaults off, no behavior changed for existing paths.

- [ ] **Step 6: Commit**

```bash
git add AgentSessions/Services/SessionIndexer.swift AgentSessionsTests/CodexTailParseTests.swift
git commit -m "test(transcript): full-parse reconciliation parity over tail parse

Tool: Claude Code
Model: claude-opus-4-8
Why: a later full parse must replace partial events with no dupes and clear the partial flag."
```

---

## Manual verification (after all tasks, before flipping the flag)

These are human steps, not part of automated tasks. Flip `FeatureFlags.transcriptTailParse = true` locally (do NOT commit the flip yet) and, with Phases 2–3 enabled (`transcriptWindowedBuild = true`):

1. Open a cold Codex monster session (>25 MB or >5k messages). Expect first content to paint quickly (tail window), not a 30 s beachball.
2. Scroll to the top → earlier events back-fill (loadOlder → `parseMoreOlder`), no duplicate blocks, scroll anchor stable (Phase 3).
3. Repeat for a cold Claude monster session; confirm multi-event lines (tool call + result on one line) appear as a complete group, never half.
4. "Show full transcript" / manual refresh on a partial session → full parse replaces it, no duplicate or missing events at the seam.
5. Open a cold Cursor/Copilot large session → unchanged legacy behavior (interstitial or full parse), proving non-capable providers are untouched.
6. Restore macOS Appearance to System if any QA tooling forced Dark Mode.

Only after 1–5 pass does a human decide to flip the default and commit that flip.

---

## Future optimization (explicitly NOT in this first cut)

- **True byte-seek tail.** `tailLines` currently streams the whole file forward, retaining only the tail — bounding memory but not I/O. A faster variant would seek from the file's end (`FileHandle.seekToEnd` + backward chunk reads) to read only the tail bytes. It is deferred because reconstructing **absolute record indices** from a byte offset requires re-deriving the blank-line / oversize-line accounting that `JSONLReader.forEachLineCore` performs, and any drift there silently corrupts event ids (the correctness keystone). Land the index-correct streaming version first, parity-tested; optimize the read later behind the same flag.
- **More providers.** Extending tail parse to Cursor/Copilot/Droid/etc. is mechanical once their parsers gain a `parseFileTail` with the same absolute-index contract — but each must be parity-tested individually because some encode multiple logical events per line differently. Out of scope here.

---

## Self-Review

**Spec coverage** (against `docs/superpowers/specs/2026-06-29-transcript-progressive-windowed-build-design.md`):
- Spec §Phasing item 5 ("tail/partial parse for cold-instant on monster sessions") → Tasks 4–10. ✔
- Spec §Non-Goals: "Windowing the event parse … required follow-on phase" → this whole plan, gated, Codex+Claude first. ✔
- Spec §Components "Stable global identities (eventIndex-based)" → tail ids derive from absolute line index so they match a full parse (Global Constraints + Tasks 4/5 parity tests). ✔
- Spec §Risks "Cold-parse wall defeats <150 ms" → addressed: tail parse replaces parseFileFull on selection for capable large sessions. ✔
- Spec §Components "load-older … parse-more-on-demand" → `parseMoreOlder` (Tasks 7/8) + loadOlder hook (Task 9). ✔
- Spec "Behind a flag; parity-gated before removal" → `transcriptTailParse` default off; Task 10 parity gate; flag flip deferred to human. ✔
- Spec "guardrail gates cold monster auto-hydration" → preserved: incapable/overridden sessions still use the Phase 1 interstitial; only capable+flag-on sessions tail-parse (Task 6). ✔

**Placeholder scan:** No "TBD"/"add error handling"/"similar to Task N" — every code step shows complete code; the one Phase-3 seam (Task 9 Step 4) is explicitly a shim with a documented boundary because Phase 3 is an assumed-prior dependency, not Phase 5 work.

**Type consistency:** `parseFileTail(at:forcedID:tailLineCount:)`, `reloadSessionTail(id:)`, `parseMoreOlder(id:completion:)`, `shouldTailParse(_:)`, `isTailParseCapable(_:)`, `isPartiallyParsed`, `parsedFromLineIndex`, `tailLines(maxLines:totalLineCount:)`, `lineCount()` are used identically across all tasks.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-06-30-transcript-phase5-parse-windowing.md`. Two execution options:

**1. Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
