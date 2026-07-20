# Claude Cowork Session Labeling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Cowork sessions visually distinct from Claude Desktop Code-tab sessions (a "cowork" surface pill) and give them live sidecar parity (renames live-update, archived Cowork sessions match the existing archived-Desktop filter).

**Architecture:** Cowork ingestion already works end-to-end — `ClaudeSessionDiscovery` walks `~/Library/Application Support/Claude/local-agent-mode-sessions/**/local_*/.claude/projects/**/*.jsonl`, and `ClaudeSessionParser.enrichWithDesktopMetadataIfNeeded` bakes sidecar title/cwd/model into the parsed `Session` with `originSource: "local-agent-mode"`. What's missing: (1) Cowork rows render the same "desk" pill as Claude Desktop Code-tab rows; (2) the live sidecar overlay (`UnifiedSessionIndexer.claudeArchive`, built from `ClaudeDesktopSessionTitles.records()`) only walks the `claude-code-sessions` root, so Cowork renames don't live-update and archived Cowork sessions never match `showArchivedClaudeDesktopOnly`. This plan adds a path-first `Session.isClaudeCoworkSession` classifier, a `cowork` pill, and a second overlay root.

**Tech Stack:** Swift / SwiftUI, XCTest. No new files, no DB schema changes, no new `SessionSource` case.

## Global Constraints

- **No new Swift files.** All changes go into existing files, so `scripts/xcode_add_file.rb` is never needed.
- **Path-first classification.** DB-hydrated sessions have NULL `originator`/`originSource`/`surface` (hydration never re-parses unchanged files). Any Cowork check MUST key off `filePath` first, metadata second — same rationale as `Session.isArchivedCodexDesktopSession` (Session.swift:350-363).
- **Commit protocol** (repo CLAUDE.md): Conventional Commits, no "Generated with Claude Code" footer, no Co-Authored-By. Trailers only: `Tool:`, `Model:`, `Why:`. Author = repository owner. Commit only the paths named in each task (`git commit -- <paths>`).
- **Test command** (agents.md): `xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "$PWD/.deriveddata-tests" -parallel-testing-enabled NO test` (add `-only-testing:` per task; final task runs the full suite). Never `open` an app built in `.deriveddata-tests`.
- **Pill copy:** lowercase monospaced label `cowork` (existing pills: `desk`, `vsc`, `cli`).

---

### Task 1: `Session.isClaudeCoworkSession` classifier

**Files:**
- Modify: `AgentSessions/Model/Session.swift` (insert after `isClaudeDesktopSession`, which ends at line 348)
- Test: `AgentSessionsTests/SessionRowDisplayTests.swift` (append to existing class — no new file)

**Interfaces:**
- Consumes: existing stored properties `source`, `filePath`, `originSource`.
- Produces: `public var isClaudeCoworkSession: Bool` on `Session` — Tasks 2 depends on this exact name.

- [ ] **Step 1: Write the failing tests**

Append to `AgentSessionsTests/SessionRowDisplayTests.swift` (inside `final class SessionRowDisplayTests`):

```swift
    // MARK: - Cowork classification (2026-07-19 cowork labeling)

    private func makeClaudeSession(
        filePath: String,
        source: SessionSource = .claude,
        originator: String? = nil,
        originSource: String? = nil
    ) -> Session {
        Session(
            id: "cowork-test",
            source: source,
            startTime: nil,
            endTime: nil,
            model: nil,
            filePath: filePath,
            eventCount: 0,
            events: [],
            cwd: nil,
            repoName: nil,
            lightweightTitle: nil,
            originator: originator,
            originSource: originSource
        )
    }

    private static let coworkTranscriptPath =
        "/Users/test/Library/Application Support/Claude/local-agent-mode-sessions/acct-1/ws-1/local_0b5ef277-1234/.claude/projects/-sessions-outputs/44ebb75a-48e4-4460-9d76-a19c62c10701.jsonl"

    func testIsClaudeCoworkSessionMatchesLocalAgentModePath() {
        // Path-only signal: hydrated sessions have nil originator/originSource.
        let s = makeClaudeSession(filePath: Self.coworkTranscriptPath)
        XCTAssertTrue(s.isClaudeCoworkSession)
    }

    func testIsClaudeCoworkSessionFalseForCodeTabTranscript() {
        // Claude Desktop Code-tab transcript: ~/.claude/projects path, desktop metadata.
        let s = makeClaudeSession(
            filePath: "/Users/test/.claude/projects/-Users-test-Repo/aaaa1111-2222-3333-4444-555566667777.jsonl",
            originator: "Claude Desktop",
            originSource: "claude-desktop"
        )
        XCTAssertFalse(s.isClaudeCoworkSession)
    }

    func testIsClaudeCoworkSessionMatchesOriginSourceFallback() {
        // Freshly-parsed session under a custom root: metadata still identifies it.
        let s = makeClaudeSession(filePath: "/tmp/some-transcript.jsonl", originSource: "local-agent-mode")
        XCTAssertTrue(s.isClaudeCoworkSession)
    }

    func testIsClaudeCoworkSessionFalseForNonClaudeSource() {
        let s = makeClaudeSession(filePath: Self.coworkTranscriptPath, source: .codex)
        XCTAssertFalse(s.isClaudeCoworkSession)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run:
```bash
xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "$PWD/.deriveddata-tests" -parallel-testing-enabled NO -only-testing:AgentSessionsTests/SessionRowDisplayTests test
```
Expected: BUILD FAILURE — `value of type 'Session' has no member 'isClaudeCoworkSession'`.

- [ ] **Step 3: Implement the classifier**

In `AgentSessions/Model/Session.swift`, immediately after the closing brace of `isClaudeDesktopSession` (line 348), insert:

```swift
    /// True for Cowork transcripts — Claude Desktop's local-agent mode, whose
    /// sessions live under
    /// `~/Library/Application Support/Claude/local-agent-mode-sessions/**/local_*/.claude/projects/**`.
    /// A Cowork session is also a `isClaudeDesktopSession` (Cowork runs inside
    /// the Desktop app); this is the narrower check.
    ///
    /// Path-first, mirroring `isArchivedCodexDesktopSession`: hydrated sessions
    /// routinely have nil `originator`/`originSource`/`surface` (launch hydrates
    /// from SQLite and never re-parses unchanged files), so the on-disk location
    /// is the reliable signal. `originSource == "local-agent-mode"` is kept as a
    /// fallback for freshly-parsed sessions under nonstandard roots.
    public var isClaudeCoworkSession: Bool {
        guard source == .claude else { return false }
        let components = URL(fileURLWithPath: filePath).standardizedFileURL.pathComponents
        if components.contains("local-agent-mode-sessions"),
           components.contains(".claude"),
           components.contains("projects"),
           components.contains(where: { $0.hasPrefix("local_") }) {
            return true
        }
        return originSource?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "local-agent-mode"
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Same command as Step 2. Expected: PASS (all `SessionRowDisplayTests`, including the 4 new tests).

- [ ] **Step 5: Commit**

```bash
git add AgentSessions/Model/Session.swift AgentSessionsTests/SessionRowDisplayTests.swift
git commit -- AgentSessions/Model/Session.swift AgentSessionsTests/SessionRowDisplayTests.swift -m "feat(cowork): add path-first Session.isClaudeCoworkSession classifier

Tool: Claude Code
Model: Fable 5
Why: Cowork transcripts need a hydration-safe discriminator before they can get their own surface pill"
```

---

### Task 2: `cowork` surface pill

**Files:**
- Modify: `AgentSessions/Views/UnifiedSessionsView.swift` (`CodexSurfacePill`, ~line 2918)
- Modify: `AgentSessions/Services/SessionRowsBuilder.swift` (`claudeDesktopSurfacePill` line 356, `applyingLiveClaudeArchiveState` line 307, delete `isClaudeDesktopLocalAgentPath` line 366)
- Test: `AgentSessionsTests/SessionRowDisplayTests.swift`

**Interfaces:**
- Consumes: `Session.isClaudeCoworkSession` (Task 1).
- Produces: `UnifiedSessionsView.CodexSurfacePill.cowork(isArchived: Bool = false) -> CodexSurfacePill` with `label == "cowork"`. `surfacePills`/`staticSurfacePills`/`applyingLiveClaudeArchiveState` signatures unchanged.

- [ ] **Step 1: Write the failing tests**

Append to `AgentSessionsTests/SessionRowDisplayTests.swift`:

```swift
    // MARK: - Cowork surface pill

    func testCoworkSessionGetsCoworkPillNotDeskPill() {
        // Freshly-parsed Cowork session: sidecar enrichment sets originator
        // "Claude Desktop" — the cowork path check must win over that.
        let s = makeClaudeSession(
            filePath: Self.coworkTranscriptPath,
            originator: "Claude Desktop",
            originSource: "local-agent-mode"
        )
        let pills = UnifiedSessionsView.surfacePills(for: s)
        XCTAssertEqual(pills.map(\.label), ["cowork"])
        XCTAssertEqual(pills.map(\.isArchived), [false])
    }

    func testHydratedCoworkSessionWithNilMetadataGetsCoworkPill() {
        // Hydrated-from-DB shape: all surface metadata nil, path is the only signal.
        let s = makeClaudeSession(filePath: Self.coworkTranscriptPath)
        XCTAssertEqual(UnifiedSessionsView.surfacePills(for: s).map(\.label), ["cowork"])
    }

    func testClaudeCodeTabSessionKeepsDeskPill() {
        let s = makeClaudeSession(
            filePath: "/Users/test/.claude/projects/-Users-test-Repo/aaaa1111-2222-3333-4444-555566667777.jsonl",
            originator: "Claude Desktop"
        )
        XCTAssertEqual(UnifiedSessionsView.surfacePills(for: s).map(\.label), ["desk"])
    }

    func testApplyingLiveClaudeArchiveStatePromotesCoworkPill() {
        let s = makeClaudeSession(filePath: Self.coworkTranscriptPath)
        let staticPills = UnifiedSessionsView.staticSurfacePills(for: s)
        XCTAssertEqual(staticPills.map(\.label), ["cowork"])
        XCTAssertEqual(staticPills.map(\.isArchived), [false])

        let patched = UnifiedSessionsView.applyingLiveClaudeArchiveState(
            to: staticPills,
            session: s,
            isClaudeArchived: true
        )
        XCTAssertEqual(patched.map(\.label), ["cowork"])
        XCTAssertEqual(patched.map(\.isArchived), [true])

        // Parity with the legacy single-call path.
        let legacyDirect = UnifiedSessionsView.surfacePills(for: s, isClaudeArchived: true)
        XCTAssertEqual(patched.map(\.identity), legacyDirect.map(\.identity))
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run:
```bash
xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "$PWD/.deriveddata-tests" -parallel-testing-enabled NO -only-testing:AgentSessionsTests/SessionRowDisplayTests test
```
Expected: FAIL — `testCoworkSessionGetsCoworkPillNotDeskPill` gets `["desk"]`, not `["cowork"]`.

- [ ] **Step 3: Add `CodexSurfacePill.cowork`**

In `AgentSessions/Views/UnifiedSessionsView.swift`, inside `struct CodexSurfacePill` directly after the `static func desktop(isArchived:)` factory (ends line 2933), insert:

```swift
        static func cowork(isArchived: Bool = false) -> CodexSurfacePill {
            CodexSurfacePill(
                label: "cowork",
                accessibilityLabel: isArchived ? "Claude Cowork archived session" : "Cowork session",
                usesFullAccessibilityLabel: isArchived,
                isArchived: isArchived
            )
        }
```

- [ ] **Step 4: Route Cowork sessions to the new pill**

In `AgentSessions/Services/SessionRowsBuilder.swift`, replace `claudeDesktopSurfacePill` (lines 356-364) with:

```swift
    private static func claudeDesktopSurfacePill(for session: Session, isArchived: Bool) -> UnifiedSessionsView.CodexSurfacePill? {
        guard session.source == .claude else { return nil }
        // Cowork first: sidecar enrichment also stamps originator "Claude
        // Desktop" on Cowork sessions, so the narrower (path-first) check must
        // win before the generic Desktop match.
        if session.isClaudeCoworkSession {
            return .cowork(isArchived: isArchived)
        }
        let originator = session.originator?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if originator == "claude desktop" {
            return .desktop(isArchived: isArchived)
        }
        return nil
    }
```

and delete the now-unused `isClaudeDesktopLocalAgentPath` helper (lines 366-372) — its predicate is subsumed by `Session.isClaudeCoworkSession`, and the removed `originSource == "local-agent-mode"` condition is likewise now routed to the cowork branch.

- [ ] **Step 5: Make the live-archive patch cowork-aware**

In `AgentSessions/Services/SessionRowsBuilder.swift`, replace the body of `applyingLiveClaudeArchiveState` (lines 307-321) with:

```swift
    static func applyingLiveClaudeArchiveState(
        to staticPills: [UnifiedSessionsView.CodexSurfacePill],
        session: Session,
        isClaudeArchived: Bool
    ) -> [UnifiedSessionsView.CodexSurfacePill] {
        guard session.source == .claude,
              !session.isSideChat,
              isClaudeArchived,
              staticPills.count == 1,
              staticPills[0].isArchived == false else {
            return staticPills
        }
        switch staticPills[0].label {
        case "cowork":
            return [.cowork(isArchived: true)]
        case "desk":
            return [.desktop(isArchived: true)]
        default:
            return staticPills
        }
    }
```

(Keep the existing doc comment above it unchanged; append one line to it: `/// Cowork sessions get the same promotion with their own pill: "cowork" -> [.cowork(isArchived: true)].`)

- [ ] **Step 6: Run tests to verify they pass**

Same command as Step 2. Expected: PASS — all `SessionRowDisplayTests`, including the pre-existing `testApplyingLiveClaudeArchiveStatePromotesSwitchBranchDesktopPill` (Code-tab sessions still reach `.desktop` via the `surface == .desktop` switch branch — untouched) and `testApplyingLiveClaudeArchiveStateNoOpForSideChatSession`.

- [ ] **Step 7: Commit**

```bash
git add AgentSessions/Views/UnifiedSessionsView.swift AgentSessions/Services/SessionRowsBuilder.swift AgentSessionsTests/SessionRowDisplayTests.swift
git commit -- AgentSessions/Views/UnifiedSessionsView.swift AgentSessions/Services/SessionRowsBuilder.swift AgentSessionsTests/SessionRowDisplayTests.swift -m "feat(cowork): distinct cowork surface pill for local-agent-mode sessions

Tool: Claude Code
Model: Fable 5
Why: Cowork rows were indistinguishable from Claude Desktop Code-tab rows (both showed desk)"
```

---

### Task 3: Live sidecar overlay for Cowork (renames + archived filter parity)

**Files:**
- Modify: `AgentSessions/ClaudeStatus/ClaudeDesktopSessionTitles.swift`
- Modify: `AgentSessions/Services/UnifiedSessionIndexer.swift` (`rebuildClaudeArchiveOverlay`, line 532)
- Test: `AgentSessionsTests/ClaudeDesktopSessionTitlesTests.swift`

**Interfaces:**
- Consumes: existing `ClaudeDesktopSessionTitles.records(root:fileManager:)` and its per-root mtime cache.
- Produces: `ClaudeDesktopSessionTitles.coworkRoot() -> URL` and `ClaudeDesktopSessionTitles.records(roots: [URL], fileManager: FileManager = .default) -> [String: ClaudeDesktopSidecarRecord]`. Single-root `records(root:)` keeps its exact signature and behavior (existing tests must stay green).

The join needs no changes: `Session.claudeArchiveJoinKey` is the transcript filename UUID, which equals the Cowork sidecar's `cliSessionId` — so `claudeDesktopTitle(for:)`, `isArchivedClaudeDesktop(_:)`, and the `showArchivedClaudeDesktopOnly` filter all start working for Cowork the moment their records enter the overlay.

- [ ] **Step 1: Write the failing tests**

Append to `AgentSessionsTests/ClaudeDesktopSessionTitlesTests.swift` (inside the class; it already has `root`, `setUpWithError` resetting the cache, and `makeSessionDir()`):

```swift
    // MARK: - Multi-root (Cowork overlay, 2026-07-19)

    func testRecordsMultiRootMergesNewerMtimeWins() throws {
        let rootA = root.appendingPathComponent("code-sessions", isDirectory: true)
        let rootB = root.appendingPathComponent("local-agent-mode-sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: rootA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rootB, withIntermediateDirectories: true)

        let older = rootA.appendingPathComponent("local_a.json")
        let newer = rootB.appendingPathComponent("local_b.json")
        try """
        {"sessionId":"local_a","cliSessionId":"shared-1111","title":"Older title"}
        """.write(to: older, atomically: true, encoding: .utf8)
        try """
        {"sessionId":"local_b","cliSessionId":"shared-1111","title":"Newer title"}
        """.write(to: newer, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(10)],
            ofItemAtPath: newer.path
        )

        let merged = ClaudeDesktopSessionTitles.records(roots: [rootA, rootB])
        XCTAssertEqual(merged["shared-1111"]?.title, "Newer title")
    }

    func testRecordsMultiRootToleratesMissingRoot() throws {
        let rootA = root.appendingPathComponent("code-sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: rootA, withIntermediateDirectories: true)
        try """
        {"sessionId":"local_k","cliSessionId":"keep-3333","title":"Kept"}
        """.write(to: rootA.appendingPathComponent("local_k.json"), atomically: true, encoding: .utf8)

        let missing = root.appendingPathComponent("does-not-exist", isDirectory: true)
        let merged = ClaudeDesktopSessionTitles.records(roots: [rootA, missing])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged["keep-3333"]?.title, "Kept")
    }

    func testRecordsSkipsHeavyCoworkDirectories() throws {
        // uploads/outputs/cowork_plugins/skills-plugin can hold thousands of
        // files; the walk must skipDescendants, never parse json inside them.
        let coworkRoot = root.appendingPathComponent("local-agent-mode-sessions", isDirectory: true)
        let sessionDir = coworkRoot.appendingPathComponent("acct/ws", isDirectory: true)
        let uploads = sessionDir.appendingPathComponent("uploads", isDirectory: true)
        try FileManager.default.createDirectory(at: uploads, withIntermediateDirectories: true)

        try """
        {"sessionId":"local_real","cliSessionId":"real-4444","title":"Real Cowork task"}
        """.write(to: sessionDir.appendingPathComponent("local_real.json"), atomically: true, encoding: .utf8)
        try """
        {"sessionId":"local_decoy","cliSessionId":"decoy-5555","title":"Decoy inside uploads"}
        """.write(to: uploads.appendingPathComponent("local_decoy.json"), atomically: true, encoding: .utf8)

        let records = ClaudeDesktopSessionTitles.records(roots: [coworkRoot])
        XCTAssertEqual(records["real-4444"]?.title, "Real Cowork task")
        XCTAssertNil(records["decoy-5555"], "files inside skipped directories must not be parsed")

        let counts = ClaudeDesktopSessionTitles.debugParseAndHitCounts()
        XCTAssertEqual(counts.parsed, 1, "the decoy must be skipped by skipDescendants, not parsed-and-discarded")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run:
```bash
xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "$PWD/.deriveddata-tests" -parallel-testing-enabled NO -only-testing:AgentSessionsTests/ClaudeDesktopSessionTitlesTests test
```
Expected: BUILD FAILURE — `type 'ClaudeDesktopSessionTitles' has no member 'records(roots:)'`.

- [ ] **Step 3: Implement multi-root records + skip set**

In `AgentSessions/ClaudeStatus/ClaudeDesktopSessionTitles.swift`:

3a. After `defaultRoot()` (line 24), add:

```swift
    /// Root of Cowork (local-agent mode) session metadata. Same `local_*.json`
    /// sidecar shape as `claude-code-sessions`, different tree.
    static func coworkRoot() -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Claude/local-agent-mode-sessions", isDirectory: true)
    }

    /// Directory names inside the Cowork tree that hold session artifacts
    /// (uploaded files, generated outputs, plugin bundles) — potentially
    /// thousands of entries, never sidecar metadata. Mirrors the skip list in
    /// `ClaudeSessionDiscovery.desktopLocalAgentRoots`. The nested `.claude`
    /// transcript dirs are already excluded by `.skipsHiddenFiles`.
    private static let skippedDirectoryNames: Set<String> =
        ["uploads", "outputs", "cowork_plugins", "skills-plugin"]
```

3b. In `records(root:fileManager:)`, add `.isDirectoryKey` to the enumerator's keys (line 61):

```swift
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey],
```

and at the top of the `for case let url as URL in enumerator` loop (line 78), before the existing `guard`, insert:

```swift
            if skippedDirectoryNames.contains(url.lastPathComponent),
               (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                enumerator.skipDescendants()
                continue
            }
```

3c. After `records(root:fileManager:)` (line 108), add the multi-root merge:

```swift
    /// Merge of `records(root:)` across several roots. Duplicate `cliSessionId`s
    /// resolve last-writer-wins by sidecar mtime, matching the single-root rule.
    /// Each root keeps its own mtime cache entry (cache is keyed by root).
    static func records(roots: [URL], fileManager: FileManager = .default) -> [String: ClaudeDesktopSidecarRecord] {
        var merged: [String: ClaudeDesktopSidecarRecord] = [:]
        for rootURL in roots {
            for (cli, record) in records(root: rootURL, fileManager: fileManager) {
                if let existing = merged[cli], existing.modifiedAt >= record.modifiedAt { continue }
                merged[cli] = record
            }
        }
        return merged
    }
```

- [ ] **Step 4: Point the overlay at both roots**

In `AgentSessions/Services/UnifiedSessionIndexer.swift`, replace the body of `rebuildClaudeArchiveOverlay()` (lines 532-535):

```swift
    func rebuildClaudeArchiveOverlay() {
        let records = ClaudeDesktopSessionTitles.records(
            roots: [ClaudeDesktopSessionTitles.defaultRoot(), ClaudeDesktopSessionTitles.coworkRoot()]
        )
        if records != claudeArchive { claudeArchive = records }
    }
```

Also update the doc comment on `claudeArchive` (line 506) from "Claude Desktop sidecar records" to "Claude Desktop + Cowork sidecar records".

- [ ] **Step 5: Run tests to verify they pass**

Same command as Step 2. Expected: PASS — the 3 new tests plus the pre-existing cache tests (`testCachesUnchangedFilesByMtime`, `testDeletedFileIsNotServedFromCache`) stay green, proving `records(root:)` semantics are unchanged.

- [ ] **Step 6: Commit**

```bash
git add AgentSessions/ClaudeStatus/ClaudeDesktopSessionTitles.swift AgentSessions/Services/UnifiedSessionIndexer.swift AgentSessionsTests/ClaudeDesktopSessionTitlesTests.swift
git commit -- AgentSessions/ClaudeStatus/ClaudeDesktopSessionTitles.swift AgentSessions/Services/UnifiedSessionIndexer.swift AgentSessionsTests/ClaudeDesktopSessionTitlesTests.swift -m "feat(cowork): include local-agent-mode sidecars in the live title/archive overlay

Tool: Claude Code
Model: Fable 5
Why: Cowork renames didn't live-update and archived Cowork sessions never matched the archived-Desktop filter"
```

---

### Task 4: Full-suite verification + owner QA handoff

**Files:**
- No source changes. Verification only.

- [ ] **Step 1: Run the full test suite**

Run:
```bash
xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "$PWD/.deriveddata-tests" -parallel-testing-enabled NO clean test
```
Expected: `** TEST SUCCEEDED **`. Watch specifically for `SessionRowDisplayTests`, `ClaudeDesktopSessionTitlesTests`, `ClaudeDesktopSidecarReaderTests`, and `NewProviderDiscoverabilityTests` (no new `SessionSource` case, so it must be unaffected).

- [ ] **Step 2: Grep for missed callsites of changed interfaces**

Per user global rules:
```bash
rg -n "isClaudeDesktopLocalAgentPath" AgentSessions AgentSessionsTests   # expect: no hits (helper deleted)
rg -n "records\(root:" AgentSessions | rg -v "Tests"                     # expect: only ClaudeDesktopSessionTitles.swift internals
rg -n "rebuildClaudeArchiveOverlay" AgentSessions                        # expect: unchanged callsites still compile (covered by build)
```
Expected: matches as annotated; anything unexpected gets fixed before handoff.

- [ ] **Step 3: Build for the owner and hand off QA (do NOT drive the app)**

Build a runnable app (default DerivedData, NOT `.deriveddata-tests`):
```bash
xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug -destination 'platform=macOS,arch=arm64' build
```
Then tell the user to relaunch and check (owner QA, per repo convention):
1. Cowork rows (e.g. "Redesign junior tennis analytics website", "Sponsorship proposal revision") show a `cowork` pill; Claude Desktop Code-tab rows still show `desk`; terminal CLI rows show `cli`.
2. Renaming a session in Cowork updates the AS list title without reindexing.
3. The Claude archived-Desktop icon toggle now also surfaces archived Cowork sessions, with the italic/accent archived pill styling.
4. Scheduled-task runs (many "Haiku hourly pin" Cowork entries) are labeled `cowork` too — expected, they live in the same tree.

**Known intentional behavior changes** (surface to the user, not bugs):
- The archived-Desktop filter's result set grows to include archived Cowork sessions.
- The in-app archive/restore action (writes `isArchived` to the sidecar via `ClaudeArchiveRestore`) becomes reachable for Cowork rows through the same overlay; it uses the identical sidecar mechanism, but its effect inside the Cowork UI should be eyeballed once during QA.

---

## Self-review notes

- **Spec coverage:** badge (Tasks 1-2), live titles + archive parity (Task 3), no new filter UI (per scope decision) — covered.
- **Type consistency:** `isClaudeCoworkSession` (Task 1) consumed in Task 2; `cowork(isArchived:)` factory name consistent across Task 2 steps; `records(roots:)` signature consistent between Task 3 steps 1 and 3.
- **Hydration constraint:** pill path and classifier are path-first; only the freshly-parsed fallback reads `originSource`.
- **Existing-test protection:** Task 2 Step 6 and Task 3 Step 5 explicitly re-run the pre-existing pins (`testApplyingLiveClaudeArchiveStatePromotesSwitchBranchDesktopPill`, side-chat no-op, mtime-cache tests).
