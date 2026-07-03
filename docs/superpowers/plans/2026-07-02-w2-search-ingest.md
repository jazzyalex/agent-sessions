# W2 — Search Ingest Re-Wire Implementation Plan (instant Enter-search)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make pressing Enter in the search box return results instantly by repopulating the empty `session_search`/`session_tool_io` FTS corpora — the read path (two-tier `SearchCoordinator`, FTS5 tables, triggers, bm25 ranking) is fully wired and currently skips itself because `hasSearchData` finds 0 rows against 3,716 indexed sessions.

**Architecture:** Resurrect the ingest as a dedicated, low-QoS, serial pass (`SearchIngestService`) — the shape the deleted `AnalyticsIndexer.indexFileIfNeeded` had before commit `31f6a619` removed it as collateral damage of the analytics-from-meta refactor. All writer APIs (`upsertSessionSearch` DB.swift:1516, `upsertSessionToolIO` :1541), skip-gates (`fetchSearchReadyPaths` :678, `fetchToolIOReadyPaths` :1378), text builder (`SessionSearchTextBuilder.build`/`.buildToolIO` with 48k/2k and FeatureFlags caps), and format versions survive unused — this plan reconnects them, fixes one deletion asymmetry, and adds a measurement gate on the owner's real 3,716-session corpus. Event-offset checkpoints (replacing the background full parse) are deliberately OUT of scope — split to a future W2b; the tail-first paint already covers cold-open feel.

**Tech Stack:** Swift 5, SQLite (FTS5 external-content + triggers, WAL), XCTest (`IndexDBTestHooks.applicationSupportDirectoryProvider` for temp-DB isolation), `Perf` spans.

## Global Constraints

- Commits: Conventional Commits with trailers `Tool: Claude Code` / `Model: claude-fable-5` / `Why: <reason>`. No co-author. Per-task commits authorized for this program; NEVER push.
- Work on `perf/search-quick-wins`; no branches/worktrees.
- New Swift files added via `LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 ./scripts/xcode_add_file.rb AgentSessions.xcodeproj <TARGET> <path> <group>`; beware duplicate-reference gotcha.
- Tests via `./scripts/xcode_test_stable.sh [-only-testing:AgentSessionsTests/<Class>]`; full suite green before each commit.
- Ingest is a background citizen: `.utility` QoS, serial (one file at a time), explicit yields between files; it must never contend with interactive work (the perf program just spent 20+ commits protecting the main thread).
- Ingest text goes through `SessionSearchTextBuilder` UNCHANGED (caps: 48_000 chars/session, 2_000/field, head/middle/tail sampling) — format_version stays 4; changing the text shape means bumping `FeatureFlags.sessionSearchFormatVersion`, which forces a full re-ingest for every user. Don't.
- Memory: each file's `parseFileFull` result (events incl. rawJSON) must be scoped to that file's iteration — build text, upsert, release before the next file. Never accumulate parsed sessions.

---

### Task 1: Fix the deletion asymmetry (stale search rows on file removal)

`DB.deleteSessionsForPaths(source:paths:)` (DB.swift:1242) deletes from `session_days`/`session_meta`/`files`/rollups but NOT `session_search`/`session_tool_io` — deleted files would leave stale FTS rows matching forever once the corpus is populated.

**Files:**
- Modify: `AgentSessions/Indexing/DB.swift:1242` (`deleteSessionsForPaths`)
- Test: create `AgentSessionsTests/SearchIngestTests.swift` (this file hosts all W2 tests; add to project per Global Constraints)

**Interfaces:**
- Consumes: existing `upsertSessionSearch`/`upsertSessionToolIO` (to seed test rows), `IndexDBTestHooks.applicationSupportDirectoryProvider` (DB.swift:5) for temp-dir DB isolation.
- Produces: `deleteSessionsForPaths` also removing `session_search` + `session_tool_io` rows for the affected session ids (FTS shadow rows cascade via the existing AFTER DELETE triggers, DB.swift:316-322).

- [ ] **Step 1: Write the failing test**

Create `AgentSessionsTests/SearchIngestTests.swift`:

```swift
import XCTest
@testable import AgentSessions

final class SearchIngestTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("w2-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        IndexDBTestHooks.applicationSupportDirectoryProvider = { [tempDir] in tempDir }
    }

    override func tearDown() async throws {
        IndexDBTestHooks.applicationSupportDirectoryProvider = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testDeleteSessionsForPathsAlsoRemovesSearchRows() async throws {
        let db = try IndexDB()
        try await db.begin()
        try await db.upsertFile(path: "/tmp/a.jsonl", mtime: 1, size: 10, source: "codex")
        try await db.upsertSessionMeta(/* construct a minimal SessionMetaRow for session id "s1", source "codex", path "/tmp/a.jsonl" — copy the row-construction pattern from an existing DB test or from SessionIndexer.sessionMetaRow */)
        try await db.upsertSessionSearch(sessionID: "s1", source: "codex", mtime: 1, size: 10, text: "needle haystack")
        try await db.upsertSessionToolIO(sessionID: "s1", source: "codex", mtime: 1, size: 10, refTS: 1, text: "tool output needle")
        try await db.commit()

        try await db.deleteSessionsForPaths(source: "codex", paths: ["/tmp/a.jsonl"])

        let hasData = try await db.hasSearchData(sources: ["codex"])
        XCTAssertFalse(hasData, "search rows for deleted files must be removed")
    }
}
```

Adapt the `upsertSessionMeta` row construction to the real `SessionMetaRow` initializer (read DB.swift for its shape); if `deleteSessionsForPaths` resolves session ids via a meta JOIN, the meta row is required test setup — mirror how the production caller uses it. If any of these helper methods are actor-isolated differently than sketched, follow the real signatures.

- [ ] **Step 2: Run to verify it fails**

`./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/SearchIngestTests` — after adding the file to the project. Expected: FAIL (hasSearchData still true — rows not deleted).

- [ ] **Step 3: Implement**

In `deleteSessionsForPaths`, alongside the existing deletes and inside the same transaction, delete `session_search` and `session_tool_io` rows for the session ids being removed (the method already resolves ids/paths for `session_meta` — reuse that resolution; the FTS AFTER DELETE triggers handle the shadow tables).

- [ ] **Step 4: Run to verify green**, then full suite once.

- [ ] **Step 5: Commit**

```bash
git add AgentSessions/Indexing/DB.swift AgentSessionsTests/SearchIngestTests.swift AgentSessions.xcodeproj/project.pbxproj
git commit -m "fix(search): delete session_search/tool_io rows when session files are removed

Tool: Claude Code
Model: claude-fable-5
Why: deleteSessionsForPaths left stale FTS rows; harmless while the corpus was empty, wrong once W2 repopulates it"
```

---

### Task 2: `SearchIngestService` — the dedicated ingest pass

**Files:**
- Create: `AgentSessions/Search/SearchIngestService.swift` (app target)
- Test: `AgentSessionsTests/SearchIngestTests.swift` (extend)

**Interfaces:**
- Consumes: `DB.fetchSearchReadyPaths(for:)`, `DB.upsertFile/upsertSessionSearch/upsertSessionToolIO`, `SessionSearchTextBuilder.build(session:)/.buildToolIO(session:)`, per-source full parsers (`SessionIndexer.parseFileFull(at:)` for Codex; `ClaudeSessionParser`/`GeminiSessionParser`/`OpenCodeSessionParser`/`CopilotSessionParser`/`DroidSessionParser` `.parseFileFull` — mirror the deleted `AnalyticsIndexer.parseSession` dispatch, visible in `git show 31f6a619`).
- Produces:

```swift
/// Dedicated search-corpus ingest. Serial, .utility, yields between files.
/// Skip-gated by fetchSearchReadyPaths (mtime+size+format_version), so
/// steady-state incremental runs touch only new/changed files.
actor SearchIngestService {
    struct FileRef { let path: String; let mtime: Int64; let size: Int64 }
    struct Progress { let processed: Int; let total: Int; let skipped: Int }

    init(db: IndexDB)

    /// Ingest one source's files. `files` comes from the caller's discovery
    /// (path+mtime+size). Returns final Progress. Cancellable between files.
    func ingest(source: SessionSource,
                files: [FileRef],
                toolIOEnabled: Bool,
                yieldNanoseconds: UInt64 = 40_000_000) async throws -> Progress
}
```

Behavior per file: skip if path ∈ `fetchSearchReadyPaths` (already current); else full-parse (dispatch by source), `SessionSearchTextBuilder.build`, then in one transaction `upsertFile` + `upsertSessionSearch` (+ `upsertSessionToolIO` when `toolIOEnabled` and the session's refTS ≥ the `toolIOIndexRecentDays` cutoff — mirror the deleted logic from `git show 31f6a619`); `Task.sleep(yieldNanoseconds)` between files; `try Task.checkCancellation()` between files; a `Perf.begin("searchIngestFile", thresholdMs: 200, "path=...")` span per file. Parsed session lifetime is scoped to the loop body.

- [ ] **Step 1: Write failing tests** (extend SearchIngestTests):
  - `testIngestPopulatesSearchCorpusFromJSONLFixture`: write 2 small Codex-shaped JSONL fixture files into tempDir (reuse the line shapes from ReverseJSONLTailReaderTests' fixtures / parseLine-accepted minimal events); run `ingest(source: .codex, files: [...], toolIOEnabled: false)`; assert `hasSearchData == true` and `searchSessionIDsFTS` MATCH on a word planted in one fixture returns exactly that session id.
  - `testIngestSkipsAlreadyCurrentFiles`: run ingest twice with identical files; second `Progress.skipped == total`.
  - `testIngestReindexesOnMtimeChange`: bump one file's mtime+content; re-run; the changed file re-ingests (planted new word findable), the other skips.
- [ ] **Step 2: RED** (service missing → build failure). Add files to project.
- [ ] **Step 3: Implement** per the interface above. Read `git show 31f6a619` FIRST and mirror the deleted `indexFileIfNeeded` transaction shape exactly (it was correct; don't redesign it).
- [ ] **Step 4: GREEN**, then full suite.
- [ ] **Step 5: Commit** — `feat(search): SearchIngestService — dedicated serial ingest repopulating the FTS corpus` + trailers, Why: `the read path skips FTS because session_search has 0 rows; the writer pass was removed with the analytics refactor (31f6a619)`.

---

### Task 3: Trigger wiring — backfill after launch refresh, incremental on delta

**Files:**
- Modify: `AgentSessions/Services/UnifiedSessionIndexer.swift` (post-refresh hook, ~where per-source refresh completes)
- Test: `AgentSessionsTests/SearchIngestTests.swift` (extend where testable; wiring itself is glue)

**Interfaces:**
- Consumes: `SearchIngestService.ingest`, each source indexer's discovered file list (path/mtime/size — the same discovery the refresh pass uses; for Codex, `CodexSessionDiscovery` output already carried by `SessionIndexer.refresh`).
- Produces: after a source's refresh completes (launch or delta), a background `Task(priority: .utility)` kicks `ingest` for that source's current file list, single-flight per source (an in-flight ingest for a source is not restarted; a follow-up request coalesces to one pending re-run). Store the service on the unified indexer.

Requirements:
- Single-flight + coalescing per source (grep how the codebase does this elsewhere — e.g. prewarm's in-flight sets — and match the idiom).
- Do NOT block or delay the refresh itself; ingest strictly follows it.
- App-quit/session-change safety: ingest tasks are cancellable; cancellation between files leaves the DB consistent (each file is one transaction).
- The first run on a real corpus is a big backfill (thousands of files, the monster takes ~10s to parse alone): that is acceptable at `.utility` — but log start/end via `Perf.event("searchIngest", "source=… files=… skipped=…")` so measurement (Task 4) can see it.
- toolIOEnabled comes from the existing pref (`PreferencesKey.Advanced.enableRecentToolIOIndex` — the deleted code read it; keep default-off semantics).

Steps: failing test where feasible (single-flight logic can be extracted pure and tested; the Task wiring itself is verified by Task 4's live measurement) → implement → full suite → commit `feat(search): kick search ingest after source refresh (backfill + incremental)` + trailers.

---

### Task 4: Measurement gate — live backfill + Enter-search timing (controller + user)

No subagent. The controller (with the user) runs:

- [ ] Build Debug, launch with `AS_PERF_MONITOR=1`, let the backfill run (watch `searchIngest`/`searchIngestFile` spans; expect minutes of low-priority churn on ~3,716 sessions, one-time).
- [ ] Verify: `sqlite3 ~/Library/Application\ Support/AgentSessions/index.db "SELECT COUNT(*) FROM session_search"` ≈ session count; `hasSearchData` path now taken (instant tier live).
- [ ] User QA: type-ahead feel; Enter-search on a word known to appear in old sessions — target: results < ~1s (FTS + bm25), deep scan only appending for unindexed stragglers.
- [ ] App responsiveness DURING backfill (list scroll, transcript open) — the .utility + yield discipline must hold; STALL log stays quiet.
- [ ] Record numbers in `docs/perf-master-plan.md` (W3 section→ append a W2 outcomes note) and the ledger. GATE: if Enter-search is still slow with a populated corpus, STOP and profile the read path before touching anything else.

---

### Task 5: Prune + retention housekeeping (small)

The deleted pass also ran `pruneOldToolIO(cutoffTS:oldBytesCap:)` (DB.swift:1773, orphaned). Re-wire it: after a completed tool-IO-enabled ingest, prune per `FeatureFlags.toolIOIndexRecentDays`/`toolIOIndexOldBytesCap`. Skip entirely when the pref is off. Test: seed old rows, run prune, assert cap respected. Commit `chore(search): re-wire tool-IO retention prune after ingest` + trailers.

---

## Deferred (explicitly NOT this plan)

- **W2b — event-offset checkpoints / partial hydration**: replacing the ~11s background full parse with on-demand ranged parsing (needs JSONLReader byte-offset exposure — recon confirmed offsets are internal-only today — plus loadOlder integration). Tail-first paint already covers cold-open feel; do W2b with the Phase-3 loadOlder work.
- Search-text format changes (would bump format_version 4 and force global re-ingest).
- Search UX changes (result presentation, snippets) — separate product work.
