# Codex Guardian Subagent Classification Fix — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop Codex guardian (approval-reviewer) subagent sessions from rendering as duplicate-looking sibling rows of their parent. Root fix: parse the `{"subagent":{"other":"guardian"}}` source shape (and the top-level `parent_thread_id` newer Codex builds stamp) so `subagent_type`/`parent_session_id` are persisted and hydration-safe; then the existing hierarchy builder nests them and the new work pill stops mislabeling them.

**Architecture:** The user-visible symptom (two `work`-pill rows, "Check Codex SSD write issue", 7/19 ~5:46 PM) is two DISTINCT Codex sessions: the real vscode-source work session `019f7ce5-…aba48` and a guardian subagent `019f7ce7-…6cf0c` whose Codex `source` is `{"subagent":{"other":"guardian"}}` and whose transcript is a verbatim quotation of the parent's. Verified facts driving the design:

1. **Parser gap (root cause, pre-existing).** Both Codex parse blocks — `SessionIndexer.parseFileFull` (SessionIndexer.swift:2014-2024) and `SessionIndexer.lightweightSession` (:2277-2289) — extract subagent info only for the string form (`{"subagent":"review"}`) and the `thread_spawn` dict form. There is no branch for `{"subagent":{"other":"guardian"}}`, so all 70 guardian rollouts get `subagentType = nil`, `parentSessionID = nil`, `isSubagent == false`. Control case proving the plumbing works when the parser matches: index.db has 650 rows with `subagent_type='review'` and 1,237 Codex rows with non-NULL `parent_session_id`.
2. **Parent link IS in metadata (diagnosis said it wasn't).** New Codex builds (0.145+) stamp a top-level `payload.parent_thread_id` on the guardian's `session_meta` line (present on 2/70 guardians incl. this one, 463/954 thread_spawn rollouts, 5 review rollouts). The parser never reads it. `thread_spawn_edges` in `state_5.sqlite` indeed has no guardian edge — but transcript-body text parsing is NOT needed.
3. **Work-pill precedence (regression, today's 72ab8c91).** `SessionRowsBuilder.surfacePills` (:342-344) returns `[.work(...)]` for any Codex session whose cwd matches `Codex/<date>/<slug>` BEFORE the surface switch. The guardian inherits the parent's work cwd, so both rows show identical `work` pills. (Pre-regression the pair was already near-identical when hydrated — both fell to the `.none` branch → "cli" pill — because surface metadata is NULLed in the DB; the switch's `.subagent` branch never rendered a subagent marker anyway. The pill reorder alone is NOT a fix; it needs `isSubagent`, which needs fix 1.)
4. **Backfill needed.** Hydration never re-parses unchanged files, so fixing the parser relabels nothing that's already indexed. DB.swift has a sanctioned one-shot mechanism: bootstrap migration markers + the corpus-preserving `reindexSessionMeta(db, sources:)` static primitive (DB.swift:1344-1355, contract pinned by `AgentSessionsTests/Indexing/MigrationCorpusPreservationTests.swift`).
5. **Bonus defect found during verification.** `Session.deriveCodexInternalSessionID` (Session.swift:719-744) prefers `payload.session_id` — which newer Codex builds set to the PARENT's UUID on subagent rollouts. The guardian's index.db row already has `codex_internal_session_id = 019f7ce5…` (the parent!). That corrupts resume (`codex resume` on the guardian row would resume the parent) and is exactly the hint-collision `SubagentHierarchyBuilder` warns about at its "Only register hints for non-subagent sessions" comment. `CodexActiveSessionsModel` (:1290) already prefers `payload.id`; the derive function should too.
6. **Nesting comes free.** `SubagentHierarchyBuilder` already (a) resolves explicit `parentSessionID` via the parent's internal-ID hint and (b) infers role-only Codex parents by same-cwd + ≤6h (`inferredRoleOnlyCodexParentID`). Once `subagentType`/`parentSessionID` are populated, guardians nest with zero new UI.
7. **Complete source-shape census** (first lines of all 2,758 `~/.codex/sessions/**/rollout-*.jsonl`): `cli` 546, `exec` 265, `vscode` 200, absent 65, `{"subagent":"review"}` 650, `{"subagent":"memory_consolidation"}` 7, `{"subagent":{"thread_spawn":{…}}}` 954, `{"subagent":{"other":"guardian"}}` 70. **Only the guardian shape is unhandled.** `other` is Codex's catch-all string variant; a defensive first-key fallback future-proofs unknown struct variants.

**Tech Stack:** Swift / SwiftUI, XCTest, SQLite. No new files, no schema (column) changes — one new migration *marker* row only.

## Global Constraints

- **HARD: hydration trap.** DB-hydrated sessions have NULL `codex_surface`/`codex_originator`/`surface`/`originator` (SearchIngest NULLs them; hydration never re-parses unchanged files). Every classification added here keys ONLY on persisted-and-restored columns: `subagent_type`, `parent_session_id`, `cwd`, `codex_internal_session_id`, file path. This trap already broke the archived-Codex filter once — do not regress it.
- **No new Swift files.** All changes go into existing files, so `scripts/xcode_add_file.rb` is never needed.
- **Commit protocol** (repo CLAUDE.md): Conventional Commits; trailers `Tool:`, `Model:`, `Why:` only — NO "Generated with Claude Code" footer, NO Co-Authored-By. Author = repository owner. Commit only the paths named in each task via `git commit -- <paths>`.
- **Test command** (agents.md): `xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "$PWD/.deriveddata-tests" -parallel-testing-enabled NO test` (add `-only-testing:` per task; final task runs the full suite). **Never `open` an app bundle built in `.deriveddata-tests`.**
- **Migration guardrail** (DB.swift:376-391): a NEW reindex marker must use the corpus-preserving `reindexSessionMeta(db, sources:)` static form — never `DELETE FROM session_search`/`session_tool_io` (that blanks search for the whole multi-minute reparse).
- **Owner QA batched at feature-complete** — no intermediate app relaunches; the agent builds, the owner runs.

## Recommendation on parent-child nesting — DO IT (it is nearly free), but not the way the diagnosis framed it

The diagnosis assumed the only parent link is the literal `Reviewed Codex session id: <uuid>` text inside the guardian transcript and implied nesting would require body-text parsing. That is wrong on both counts: (a) new-format rollouts carry `payload.parent_thread_id` in `session_meta` — a real metadata field this plan starts persisting (Task 1); (b) for the 68 older guardians without it, `SubagentHierarchyBuilder.inferredRoleOnlyCodexParentID` already nests role-only Codex subagents under the nearest same-cwd non-subagent session within 6 hours — guardians always inherit the parent's cwd and spawn minutes after it, so inference lands correctly. **Do NOT add transcript-body parsing** — fragile, and redundant with the two signals above. Nesting therefore needs no dedicated task: it activates as a consequence of Task 1 + Task 2, and Task 1's hierarchy test pins it.

---

### Task 1: Parser — classify `{"subagent":{"other":…}}` and read top-level `parent_thread_id` (root fix)

**Files:**
- Modify: `AgentSessions/Services/SessionIndexer.swift` (two blocks: `parseFileFull` ~:2014-2024, `lightweightSession` ~:2277-2289)
- Test: `AgentSessionsTests/SessionParserTests.swift` (append inside `final class SessionParserTests`, after `testCodexSurfaceClassifiesSubagentObjectAndPreservesHierarchy` ~:1494)

**Interfaces:**
- Consumes: `session_meta` payload dict already in scope in both blocks.
- Produces: `subagentType == "guardian"` and (when present) `parentSessionID` from `payload["parent_thread_id"]` for guardian rollouts; Task 2 and Task 3 depend on these being persisted.
- Note: `classifyCodexSurface` (:1929) already returns `.subagent` for ANY dict with a `subagent` key — no change needed there.

- [ ] **Step 1: Write the failing tests**

Append to `AgentSessionsTests/SessionParserTests.swift`:

```swift
    // MARK: - Codex guardian subagent classification (2026-07-19)

    func testCodexGuardianOtherSubagentClassifiesAndLinksParent() throws {
        // Newer Codex builds (0.145+) spawn guardian approval reviewers with
        // source {"subagent":{"other":"guardian"}} and stamp the parent link
        // at payload top level (NOT inside thread_spawn, and there is no
        // thread_spawn_edges row for them).
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-CodexGuardian-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let url = root.appendingPathComponent("rollout-2026-07-19T17-22-56-019f7ce7-8979-7203-8867-34084576cf0c.jsonl")
        let lines = [
            #"{"timestamp":"2026-07-20T00:22:56.633Z","type":"session_meta","payload":{"session_id":"019f7ce5-7a52-7e32-8fc5-99c3193aba48","id":"019f7ce7-8979-7203-8867-34084576cf0c","parent_thread_id":"019f7ce5-7a52-7e32-8fc5-99c3193aba48","cwd":"/Users/test/Documents/Codex/2026-07-19/kaize-slug","originator":"codex_work_desktop","source":{"subagent":{"other":"guardian"}},"thread_source":"subagent"}}"#,
            #"{"timestamp":"2026-07-20T00:22:57.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Assess the planned action"}]}}"#
        ]
        try lines.joined(separator: "\n").data(using: .utf8)!.write(to: url)

        let session = SessionIndexer().parseFile(at: url)
        XCTAssertEqual(session?.subagentType, "guardian")
        XCTAssertEqual(session?.parentSessionID, "019f7ce5-7a52-7e32-8fc5-99c3193aba48")
        XCTAssertTrue(session?.isSubagent == true)
        XCTAssertEqual(session?.codexSurface, .subagent)
    }

    func testCodexGuardianWithoutTopLevelParentStillClassifies() throws {
        // 68 of 70 on-disk guardian rollouts predate the parent_thread_id
        // stamp: subagentType alone must classify them (parent then resolves
        // via SubagentHierarchyBuilder's role-only same-cwd inference).
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-CodexGuardianOld-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let url = root.appendingPathComponent("rollout-2026-06-01T10-00-00-019f0000-0000-7000-8000-000000000001.jsonl")
        let lines = [
            #"{"timestamp":"2026-06-01T17:00:00.000Z","type":"session_meta","payload":{"id":"019f0000-0000-7000-8000-000000000001","cwd":"/tmp/repo","originator":"codex_work_desktop","source":{"subagent":{"other":"guardian"}}}}"#,
            #"{"timestamp":"2026-06-01T17:00:01.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Assess"}]}}"#
        ]
        try lines.joined(separator: "\n").data(using: .utf8)!.write(to: url)

        let session = SessionIndexer().parseFile(at: url)
        XCTAssertEqual(session?.subagentType, "guardian")
        XCTAssertNil(session?.parentSessionID)
        XCTAssertTrue(session?.isSubagent == true)
    }

    func testCodexUnknownSubagentStructVariantFallsBackToVariantName() throws {
        // Future-proofing: an unrecognized struct variant must still classify
        // as a subagent (variant name as type) instead of silently reading as
        // a root session — that silence is exactly how guardian slipped through.
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-CodexFutureSub-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let url = root.appendingPathComponent("rollout-2026-07-19T18-00-00-019f0000-0000-7000-8000-000000000002.jsonl")
        let lines = [
            #"{"timestamp":"2026-07-20T01:00:00.000Z","type":"session_meta","payload":{"id":"019f0000-0000-7000-8000-000000000002","cwd":"/tmp/repo","source":{"subagent":{"future_kind":{"detail":1}}}}}"#,
            #"{"timestamp":"2026-07-20T01:00:01.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"hi"}]}}"#
        ]
        try lines.joined(separator: "\n").data(using: .utf8)!.write(to: url)

        let session = SessionIndexer().parseFile(at: url)
        XCTAssertEqual(session?.subagentType, "future_kind")
        XCTAssertTrue(session?.isSubagent == true)
    }

    func testSubagentHierarchyNestsGuardianUnderExplicitParent() {
        // End-to-end row shape: guardian with an explicit parentSessionID nests
        // under the parent resolved via the parent's internal-ID hint.
        let parent = makeCodexHierarchySession(
            id: "work-parent",
            runtimeID: "019f7ce5-7a52-7e32-8fc5-99c3193aba48",
            timestamp: "2026-07-19T17-20-41",
            cwd: "/Users/test/Documents/Codex/2026-07-19/kaize-slug"
        )
        let guardian = makeCodexHierarchySession(
            id: "guardian-child",
            runtimeID: "019f7ce7-8979-7203-8867-34084576cf0c",
            timestamp: "2026-07-19T17-22-56",
            cwd: "/Users/test/Documents/Codex/2026-07-19/kaize-slug",
            parentSessionID: "019f7ce5-7a52-7e32-8fc5-99c3193aba48",
            subagentType: "guardian"
        )

        let result = SubagentHierarchyBuilder.build(
            sessions: [parent, guardian],
            hierarchyEnabled: true
        )
        XCTAssertEqual(result.sessions.map(\.id), ["work-parent", "guardian-child"])
        XCTAssertEqual(result.rowMeta["work-parent"]?.childCount, 1)
        XCTAssertEqual(result.rowMeta["guardian-child"]?.depth, 1)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "$PWD/.deriveddata-tests" -parallel-testing-enabled NO -only-testing:AgentSessionsTests/SessionParserTests test
```
Expected: the three new parse tests FAIL on `subagentType` (nil ≠ "guardian"/"future_kind"); the hierarchy test passes already (it feeds fields directly) — it pins the downstream contract.

- [ ] **Step 3: Implement — parseFileFull block**

In `AgentSessions/Services/SessionIndexer.swift`, replace the subagent-extraction block inside `parseFileFull` (currently :2014-2024):

```swift
                        if let source = payload["source"],
                           let sourceDict = source as? [String: Any],
                           let subagentInfo = sourceDict["subagent"] {
                            if let subStr = subagentInfo as? String {
                                subagentType = subStr
                            } else if let subDict = subagentInfo as? [String: Any] {
                                if let threadSpawn = subDict["thread_spawn"] as? [String: Any] {
                                    parentSessionID = threadSpawn["parent_thread_id"] as? String
                                    subagentType = threadSpawn["agent_role"] as? String
                                } else if let other = subDict["other"] as? String {
                                    // Codex's catch-all variant, e.g. {"other":"guardian"}
                                    // (approval-reviewer subagents; 70 on disk as of 2026-07-19).
                                    subagentType = other
                                } else if let variant = subDict.keys.sorted().first {
                                    // Unknown future struct variant: keep the variant name so
                                    // the session still classifies as a subagent instead of
                                    // silently reading as a root session.
                                    subagentType = variant
                                }
                            }
                            if parentSessionID == nil {
                                // Newer Codex builds (0.145+) also stamp the parent link at
                                // payload top level; guardian rollouts have ONLY this form
                                // (thread_spawn_edges has no row for them).
                                parentSessionID = payload["parent_thread_id"] as? String
                            }
                        }
```

- [ ] **Step 4: Implement — lightweightSession block**

Apply the IDENTICAL replacement to the near-duplicate block inside `lightweightSession` (currently :2277-2289 — the one guarded by `if parentSessionID == nil, objType == "session_meta"`). Keep the two blocks textually identical so future greps for `parent_thread_id` find both.

- [ ] **Step 5: Run tests to verify they pass**

Same command as Step 2. Expected: PASS (all `SessionParserTests`, including the 4 new tests).

- [ ] **Step 6: Commit**

```bash
git add AgentSessions/Services/SessionIndexer.swift AgentSessionsTests/SessionParserTests.swift
git commit -- AgentSessions/Services/SessionIndexer.swift AgentSessionsTests/SessionParserTests.swift -m "fix(codex): classify guardian ({\"subagent\":{\"other\":...}}) rollouts as subagents

Read the other-variant subagent kind and the top-level payload
parent_thread_id in both Codex parse blocks. Guardian approval-reviewer
sessions previously parsed as root sessions (subagentType/parentSessionID
nil), rendering as duplicate-looking siblings of their parent.

Tool: Claude Code
Model: Fable 5
Why: {\"subagent\":{\"other\":\"guardian\"}} had no parser branch, so all 70 guardian rollouts classified as root work sessions"
```

---

### Task 2: One-shot backfill — corpus-preserving Codex reindex marker

Fixing the parser relabels nothing already indexed: hydration never re-parses unchanged files, and all ~70 existing guardian rows sit in `session_meta` with NULL `subagent_type`/`parent_session_id`. A one-time marker forces re-derivation.

**Files:**
- Modify: `AgentSessions/Indexing/DB.swift` (bootstrap, after the `claudeWorkflowReindex` marker ending :465, before `try exec(db, "COMMIT;")`)

**Interfaces:**
- Consumes: existing `migrationApplied(_:key:)`, `execBind`, and the static `reindexSessionMeta(_:sources:)` primitive (:1347).
- Produces: marker `codex_guardian_subagent_reindex_v1` in `schema_migrations`.

- [ ] **Step 1: Implement the marker**

Insert after the `claudeWorkflowReindex` block (:465):

```swift
        // Re-derive Codex session_meta so guardian approval-reviewer subagents
        // ({"subagent":{"other":"guardian"}}) get subagent_type/parent_session_id
        // populated by the fixed SessionIndexer extraction, and internal session
        // ids stop pointing at the parent (deriveCodexInternalSessionID fix).
        // Corpus-preserving per the guardrail above: session_meta only.
        let codexGuardianReindex = "codex_guardian_subagent_reindex_v1"
        if !migrationApplied(db, key: codexGuardianReindex) {
            try reindexSessionMeta(db, sources: ["codex"])
            try execBind(db, "INSERT OR IGNORE INTO schema_migrations(key) VALUES(?);", codexGuardianReindex)
        }
```

Note: this deliberately does NOT copy the older markers' `DELETE FROM files/session_search/...` shape — the guardrail comment at :376-391 forbids it, and `MigrationCorpusPreservationTests` pins the primitive this marker calls.

- [ ] **Step 2: Run the DB-level suites**

```bash
xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "$PWD/.deriveddata-tests" -parallel-testing-enabled NO -only-testing:AgentSessionsTests/MigrationCorpusPreservationTests -only-testing:AgentSessionsTests/DBSmokeTests -only-testing:AgentSessionsTests/CoreSessionMetaTests test
```
Expected: PASS. (The marker itself executes at app launch; the primitive's behavior is what the tests pin.)

- [ ] **Step 3: Commit**

```bash
git add AgentSessions/Indexing/DB.swift
git commit -- AgentSessions/Indexing/DB.swift -m "fix(index): one-shot codex reindex to backfill guardian subagent metadata

Tool: Claude Code
Model: Fable 5
Why: hydration never re-parses unchanged files, so the parser fix alone would leave all existing guardian rows mislabeled forever"
```

---

### Task 3: Work-pill precedence — subagents never take the `work` pill

**Files:**
- Modify: `AgentSessions/Services/SessionRowsBuilder.swift` (`surfacePills`, :342-344)
- Test: `AgentSessionsTests/SessionRowDisplayTests.swift` (append near the existing "Codex work surface pill" section, ~:432)

**Interfaces:**
- Consumes: `Session.isCodexWorkSession` (cwd-keyed, hydration-safe) and `Session.isSubagent` (keyed on `subagentType`/`parentSessionID` — persisted columns, hydration-safe after Tasks 1-2).
- Behavior decision: a Codex subagent inside a work workspace renders NO surface pill — matching the existing hydrated behavior of every other Codex subagent (the `.none` switch branch returns `[]` for `isSubagent`), and matching fresh-parse once this branch fires before the switch. The nested/`sub` row treatment carries the semantics; a second `work` pill on the child is what produced the "duplicate row" read.

- [ ] **Step 1: Write the failing tests**

Append to `AgentSessionsTests/SessionRowDisplayTests.swift` (the `makeCodexSession` helper is at :373 — first extend it with a `subagentType: String? = nil` parameter passed through to the `Session` initializer, mirroring `makeCodexHierarchySession` in SessionParserTests.swift:63):

```swift
    func testCodexWorkSubagentGetsNoWorkPill() {
        // Guardian approval reviewer inherits the parent's work cwd; it must
        // not duplicate the parent's work pill (hydrated shape: nil surface
        // metadata, subagent_type restored from DB).
        let s = makeCodexSession(cwd: Self.codexWorkCwd, subagentType: "guardian")
        XCTAssertTrue(s.isCodexWorkSession)
        XCTAssertTrue(s.isSubagent)
        XCTAssertEqual(UnifiedSessionsView.surfacePills(for: s), [])
    }

    func testCodexWorkSubagentGetsNoWorkPillFreshParse() {
        // Freshly-parsed shape: originator/surface metadata present. Must agree
        // with the hydrated shape (no pill), not fall through to the switch's
        // .subagent branch (which would render a desk pill off the
        // codex_work_desktop originator).
        let s = makeCodexSession(
            cwd: Self.codexWorkCwd,
            codexOriginator: "codex_work_desktop",
            codexSurface: .subagent,
            subagentType: "guardian"
        )
        XCTAssertEqual(UnifiedSessionsView.surfacePills(for: s), [])
    }

    func testCodexWorkRootSessionKeepsWorkPill() {
        let s = makeCodexSession(cwd: Self.codexWorkCwd)
        XCTAssertEqual(UnifiedSessionsView.surfacePills(for: s).map(\.label), ["work"])
    }
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "$PWD/.deriveddata-tests" -parallel-testing-enabled NO -only-testing:AgentSessionsTests/SessionRowDisplayTests test
```
Expected: the two subagent tests FAIL (pills == `["work"]`); the root-session test passes.

- [ ] **Step 3: Implement**

In `AgentSessions/Services/SessionRowsBuilder.swift`, replace :342-344:

```swift
        if session.isCodexWorkSession {
            // A subagent spawned inside the work workspace (e.g. a guardian
            // approval reviewer) inherits the parent's cwd; giving it the same
            // work pill made it read as a duplicate of the parent row. It gets
            // no surface pill — same as every other Codex subagent's hydrated
            // rendering (the .none branch below) — and the hierarchy row
            // treatment (nesting / "sub" marker) carries the semantics.
            if session.isSubagent { return [] }
            return [.work(isArchived: session.isArchivedCodexDesktopSession)]
        }
```

- [ ] **Step 4: Run tests to verify they pass**

Same command as Step 2. Expected: PASS, including all pre-existing work-pill tests from 72ab8c91.

- [ ] **Step 5: Commit**

```bash
git add AgentSessions/Services/SessionRowsBuilder.swift AgentSessionsTests/SessionRowDisplayTests.swift
git commit -- AgentSessions/Services/SessionRowsBuilder.swift AgentSessionsTests/SessionRowDisplayTests.swift -m "fix(pills): codex work pill must not swallow subagent rows

Tool: Claude Code
Model: Fable 5
Why: 72ab8c91's cwd-shape check ran before any subagent handling, so a guardian inheriting the parent's work cwd duplicated the parent's work pill"
```

---

### Task 4: `deriveCodexInternalSessionID` — stop subagent rows adopting the parent's UUID

Found during verification, not in the original diagnosis. Newer Codex builds set `payload.session_id` = the PARENT thread's UUID on subagent `session_meta` lines while `payload.id` is the thread's own UUID (on-disk census: 12 files diverge today — 2 guardian + 10 thread_spawn — and ALL new subagent rollouts will). The current preference order (Session.swift:719-744: `payload.session_id` before `payload.id`) already wrote the parent's UUID into the guardian's `codex_internal_session_id` in index.db, which (a) makes Resume on the guardian row target the parent and (b) is the exact hint-collision `SubagentHierarchyBuilder`'s registration guard warns about. `CodexActiveSessionsModel.parsedActiveSubagentSessionMeta` (:1290) already prefers `payload.id` — this aligns the derive function with it.

**Files:**
- Modify: `AgentSessions/Model/Session.swift` (`deriveCodexInternalSessionID`, :719-744)
- Test: `AgentSessionsTests/SessionParserTests.swift`

**Interfaces:**
- Consumes/produces: same signature; only the within-payload preference order changes. The top-level `obj["session_id"]` check and the regex fallback are untouched (old formats).

- [ ] **Step 1: Write the failing test**

Append to `AgentSessionsTests/SessionParserTests.swift`:

```swift
    func testCodexInternalSessionIDPrefersOwnIDOverParentPointingSessionID() throws {
        // Newer Codex builds set payload.session_id to the PARENT's UUID on
        // subagent rollouts; payload.id is the thread's own UUID. Resume and
        // hierarchy joins must use the OWN id.
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-CodexOwnID-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let url = root.appendingPathComponent("rollout-2026-07-19T17-22-56-019f7ce7-8979-7203-8867-34084576cf0c.jsonl")
        let lines = [
            #"{"timestamp":"2026-07-20T00:22:56.633Z","type":"session_meta","payload":{"session_id":"019f7ce5-7a52-7e32-8fc5-99c3193aba48","id":"019f7ce7-8979-7203-8867-34084576cf0c","parent_thread_id":"019f7ce5-7a52-7e32-8fc5-99c3193aba48","cwd":"/tmp","source":{"subagent":{"other":"guardian"}}}}"#,
            #"{"timestamp":"2026-07-20T00:22:57.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Assess"}]}}"#
        ]
        try lines.joined(separator: "\n").data(using: .utf8)!.write(to: url)

        let session = SessionIndexer().parseFile(at: url)
        XCTAssertEqual(session?.codexInternalSessionIDHint, "019f7ce7-8979-7203-8867-34084576cf0c")
    }
```

- [ ] **Step 2: Run tests to verify it fails**

```bash
xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "$PWD/.deriveddata-tests" -parallel-testing-enabled NO -only-testing:AgentSessionsTests/SessionParserTests test
```
Expected: FAIL — hint is `019f7ce5-…` (the parent).

- [ ] **Step 3: Implement**

In `Session.deriveCodexInternalSessionID` (Session.swift:719-744), swap the within-payload order so the `session_meta` `payload.id` check comes FIRST — minimal diff, keeping the top-level `obj["session_id"]` check and regex fallback where they are:

```swift
                if let v = obj["session_id"] as? String, !v.isEmpty { return v }
                if let payload = obj["payload"] as? [String: Any] {
                    // session_meta's `payload.id` is the thread's OWN UUID. It must win
                    // over `payload.session_id`, which newer Codex builds (0.145+) set
                    // to the PARENT thread's UUID on subagent rollouts — preferring
                    // session_id made guardian rows resume/join as their parent.
                    if let t = obj["type"] as? String, t == "session_meta",
                       let v = payload["id"] as? String, !v.isEmpty { return v }
                    if let v = payload["session_id"] as? String, !v.isEmpty { return v }
                }
```

- [ ] **Step 4: Run tests to verify they pass**

Same command as Step 2. Expected: PASS (whole `SessionParserTests` class — watch for any pre-existing test pinning the old order; if one exists, its expectation encodes the bug and should be updated with a comment, not worked around).

- [ ] **Step 5: Commit**

```bash
git add AgentSessions/Model/Session.swift AgentSessionsTests/SessionParserTests.swift
git commit -- AgentSessions/Model/Session.swift AgentSessionsTests/SessionParserTests.swift -m "fix(codex): prefer session_meta payload.id over parent-pointing session_id

Tool: Claude Code
Model: Fable 5
Why: new-format subagent rollouts set payload.session_id to the parent's UUID, so guardian rows stored the parent's internal id (wrong Resume target, hierarchy hint collision)"
```

---

### Task 5: Full suite, changelog, owner QA

**Files:**
- Modify: `docs/CHANGELOG.md` (append under Unreleased/current heading, matching existing entry style)

- [ ] **Step 1: Full test suite**

```bash
xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "$PWD/.deriveddata-tests" -parallel-testing-enabled NO test
```
Expected: PASS, zero failures.

- [ ] **Step 2: Changelog entry**

Add under the current heading in `docs/CHANGELOG.md`:

```markdown
- Fixed: Codex guardian (approval-reviewer) subagent sessions no longer render as duplicate-looking sibling rows of their work session — they classify as subagents, nest under their parent, and no longer duplicate the `work` pill (one-time Codex metadata reindex on first launch).
- Fixed: subagent rollouts from new Codex builds no longer adopt the parent's internal session id (Resume on a subagent row targeted the parent).
```

- [ ] **Step 3: Commit**

```bash
git add docs/CHANGELOG.md
git commit -- docs/CHANGELOG.md -m "docs: changelog for codex guardian subagent fix

Tool: Claude Code
Model: Fable 5
Why: user-facing fix batch needs a changelog record before release"
```

- [ ] **Step 4: Owner QA (batched, feature-complete)**

Build for the owner to run through their normal flow (do NOT drive the app; do NOT `open` anything from `.deriveddata-tests`). Checklist for the owner:
1. First launch after update: expect a one-time Codex reindex (brief); search stays usable throughout (corpus-preserving).
2. The 7/19 ~5:46 PM pair: ONE top-level "Check Codex SSD write issue" row with a `work` pill and a `(1)` disclosure; the guardian nests beneath it (indented, no `work` pill).
3. Spot-check an older guardian (they exist back through June): nested under its same-cwd parent, or flat with the `sub` marker if the parent aged out of the 6h inference window — either is correct, a second work-pill sibling is not.
4. Verify backfill: `sqlite3 -readonly "$HOME/Library/Application Support/AgentSessions/index.db" "SELECT COUNT(*) FROM session_meta WHERE source='codex' AND subagent_type='guardian';"` → expect ≈70.

---

## Explicitly out of scope (noted for follow-up, do not build here)

- **Live-status guardian attribution:** `CodexActiveSessionsModel` (:1296) and `CodexRunwayModel.parentSessionID(from:)` (:1755) recognize only `thread_spawn` parents, so a RUNNING guardian appears as an independent active session in QM/Runway for its (short) lifetime. Cosmetic and rare; piggybacks on the same top-level `parent_thread_id` read if it ever annoys.
- **Transcript-body parent extraction** (`Reviewed Codex session id: <uuid>`): rejected — fragile, and redundant with `payload.parent_thread_id` + role-only cwd inference (see recommendation above).
- **Usage/burn-rate attribution for guardians:** the burn-rate subagent cap shipped 2026-07-19 keys on its own session detection; whether guardian sessions are counted correctly there was not verified in this investigation.
