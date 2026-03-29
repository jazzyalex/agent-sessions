# Hybrid Subagent Tracking Architecture — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move subagent counting from the HUD view layer into `CodexActiveSessionsModel` as derived model state, using session metadata for identity and lsof + mtime for liveness.

**Architecture:** Identity comes from indexed session metadata (`parentSessionID`). Liveness comes from active-sessions probe (`openSessionLogPaths` per live process + file mtime within a 30s window). The model publishes `activeSubagentCountsByParentSessionID: [String: Int]` as part of its refresh cycle. The HUD consumes this snapshot — no filesystem scanning in the view.

**Tech Stack:** Swift, SwiftUI, XCTest

---

### File Map

- **Modify:** `AgentSessions/Services/CodexActiveSessionsModel.swift` — add `activeSubagentCountsByParentSessionID` property, add `deriveActiveSubagentCounts(...)` method, update `refreshOnce` to call it after indexes are built.
- **Modify:** `AgentSessions/Views/AgentCockpitHUDView.swift` — remove the 80-line subagent pre-pass from `makeRowsSnapshot(...)`, read counts from model instead.
- **Modify:** `AgentSessionsTests/CodexActiveSessionsRegistryTests.swift` — add 6 targeted test cases.

---

### Task 1: Lsof parsing — lowest-FD selection with multiple rollout files

The lsof parsing already selects the lowest-FD path. This task adds test coverage to lock that behavior before refactoring the count derivation.

**Files:**
- Test: `AgentSessionsTests/CodexActiveSessionsRegistryTests.swift`

- [ ] **Step 1: Write failing test — lowest FD wins across out-of-order rollout files**

```swift
func testParseLsofMachineOutput_selectsLowestFDAsSessionLog_outOfOrder() {
    let root = "/Users/test/.codex/sessions"
    // FDs appear out of order: 28 first, then 14.
    let text = """
    p9001
    fcwd
    tDIR
    n/Users/test/Project
    f0
    tCHR
    n/dev/ttys005
    f28w
    tREG
    n\(root)/2026/03/27/rollout-child.jsonl
    f14w
    tREG
    n\(root)/2026/03/27/rollout-parent.jsonl
    """

    let out = CodexActiveSessionsModel.parseLsofMachineOutput(text, sessionsRoots: [root])
    XCTAssertEqual(out.count, 1)
    // Lowest FD (14) wins as the primary session log.
    XCTAssertEqual(out[9001]?.sessionLogPath, "\(root)/2026/03/27/rollout-parent.jsonl")
    XCTAssertEqual(out[9001]?.sessionLogFD, 14)
    // Both paths are collected in openSessionLogPaths.
    XCTAssertEqual(out[9001]?.openSessionLogPaths.count, 2)
    XCTAssertTrue(out[9001]?.openSessionLogPaths.contains("\(root)/2026/03/27/rollout-child.jsonl") ?? false)
    XCTAssertTrue(out[9001]?.openSessionLogPaths.contains("\(root)/2026/03/27/rollout-parent.jsonl") ?? false)
}
```

- [ ] **Step 2: Run test to verify it passes**

Run: `xcodebuild test -scheme AgentSessions -only-testing AgentSessionsTests/CodexActiveSessionsRegistryTests/testParseLsofMachineOutput_selectsLowestFDAsSessionLog_outOfOrder -destination 'platform=macOS' 2>&1 | tail -20`

This should PASS — the implementation already exists. This test locks existing behavior before the refactor.

- [ ] **Step 3: Commit**

```
test(lsof): add coverage for lowest-FD session log selection
```

---

### Task 2: Add `deriveActiveSubagentCounts` to the model

This is the core change: a new static method on `CodexActiveSessionsModel` that computes `[String: Int]` from presences, lookup indexes, and a recency window. This method encapsulates all the logic currently split across the HUD view.

**Files:**
- Modify: `AgentSessions/Services/CodexActiveSessionsModel.swift`
- Test: `AgentSessionsTests/CodexActiveSessionsRegistryTests.swift`

- [ ] **Step 1: Write failing tests for Codex count derivation**

Add these tests. They call the new static method which doesn't exist yet, so they won't compile.

```swift
// MARK: - deriveActiveSubagentCounts

private func makeSession(id: String,
                         source: SessionSource,
                         cwd: String?,
                         filePath: String,
                         parentSessionID: String? = nil,
                         subagentType: String? = nil) -> Session {
    Session(
        id: id, source: source,
        startTime: Date().addingTimeInterval(-10), endTime: Date(),
        model: nil, filePath: filePath, eventCount: 0, events: [],
        cwd: cwd, repoName: nil, lightweightTitle: nil,
        parentSessionID: parentSessionID, subagentType: subagentType
    )
}

func testDeriveSubagentCounts_codex_parentResolvedViaMetadata_childCountedByMtime() {
    let parentLogPath = "/sessions/rollout-parent.jsonl"
    let childLogPath = "/sessions/rollout-child.jsonl"

    // Parent session: no parentSessionID.
    let parentSession = makeSession(id: "parent-001", source: .codex, cwd: "/proj", filePath: parentLogPath)
    // Child session: has parentSessionID pointing to parent.
    let childSession = makeSession(id: "child-001", source: .codex, cwd: "/proj", filePath: childLogPath,
                                   parentSessionID: "parent-001", subagentType: "Explore")

    // Build lookup indexes with both sessions keyed by log path.
    let parentLogKey = CodexActiveSessionsModel.logLookupKey(
        source: .codex,
        normalizedPath: CodexActiveSessionsModel.normalizePath(parentLogPath)
    )
    let childLogKey = CodexActiveSessionsModel.logLookupKey(
        source: .codex,
        normalizedPath: CodexActiveSessionsModel.normalizePath(childLogPath)
    )
    let indexes = SessionLookupIndexes(
        byLogPath: [parentLogKey: parentSession, childLogKey: childSession],
        bySessionID: ["parent-001": parentSession, "child-001": childSession],
        byWorkspace: [:]
    )

    // Presence has both files open.
    var presence = makeFallbackPresence(source: .codex, lastSeenAt: Date(), workspaceRoot: "/proj", tty: "/dev/ttys001", pid: 100)
    presence.sessionLogPath = parentLogPath
    presence.openSessionLogPaths = [parentLogPath, childLogPath]

    // Child mtime is recent (within 30s).
    let counts = CodexActiveSessionsModel.deriveActiveSubagentCounts(
        presences: [presence],
        lookupIndexes: indexes,
        recentWriteWindow: 30,
        childMtimeOverrides: [childLogPath: Date()]
    )

    XCTAssertEqual(counts["parent-001"], 1)
}

func testDeriveSubagentCounts_codex_staleChildNotCounted() {
    let parentLogPath = "/sessions/rollout-parent2.jsonl"
    let childLogPath = "/sessions/rollout-child-stale.jsonl"

    let parentSession = makeSession(id: "parent-002", source: .codex, cwd: "/proj", filePath: parentLogPath)
    let childSession = makeSession(id: "child-002", source: .codex, cwd: "/proj", filePath: childLogPath,
                                   parentSessionID: "parent-002", subagentType: "test")

    let parentLogKey = CodexActiveSessionsModel.logLookupKey(
        source: .codex,
        normalizedPath: CodexActiveSessionsModel.normalizePath(parentLogPath)
    )
    let childLogKey = CodexActiveSessionsModel.logLookupKey(
        source: .codex,
        normalizedPath: CodexActiveSessionsModel.normalizePath(childLogPath)
    )
    let indexes = SessionLookupIndexes(
        byLogPath: [parentLogKey: parentSession, childLogKey: childSession],
        bySessionID: [:],
        byWorkspace: [:]
    )

    var presence = makeFallbackPresence(source: .codex, lastSeenAt: Date(), workspaceRoot: "/proj", tty: "/dev/ttys002", pid: 200)
    presence.sessionLogPath = parentLogPath
    presence.openSessionLogPaths = [parentLogPath, childLogPath]

    // Child mtime is 5 minutes ago — outside 30s window.
    let counts = CodexActiveSessionsModel.deriveActiveSubagentCounts(
        presences: [presence],
        lookupIndexes: indexes,
        recentWriteWindow: 30,
        childMtimeOverrides: [childLogPath: Date().addingTimeInterval(-300)]
    )

    // Stale child should not be counted.
    XCTAssertNil(counts["parent-002"])
}

func testDeriveSubagentCounts_codex_preferredLogIsChild_parentStillResolved() {
    // Edge case: lsof picks a child file as sessionLogPath (e.g., child has lower FD).
    // The method should still resolve the parent via metadata.
    let parentLogPath = "/sessions/rollout-parent3.jsonl"
    let childLogPath = "/sessions/rollout-child3.jsonl"

    let parentSession = makeSession(id: "parent-003", source: .codex, cwd: "/proj", filePath: parentLogPath)
    let childSession = makeSession(id: "child-003", source: .codex, cwd: "/proj", filePath: childLogPath,
                                   parentSessionID: "parent-003", subagentType: "Explore")

    let parentLogKey = CodexActiveSessionsModel.logLookupKey(
        source: .codex,
        normalizedPath: CodexActiveSessionsModel.normalizePath(parentLogPath)
    )
    let childLogKey = CodexActiveSessionsModel.logLookupKey(
        source: .codex,
        normalizedPath: CodexActiveSessionsModel.normalizePath(childLogPath)
    )
    let indexes = SessionLookupIndexes(
        byLogPath: [parentLogKey: parentSession, childLogKey: childSession],
        bySessionID: [:],
        byWorkspace: [:]
    )

    // Presence has child as sessionLogPath (misresolution).
    var presence = makeFallbackPresence(source: .codex, lastSeenAt: Date(), workspaceRoot: "/proj", tty: "/dev/ttys003", pid: 300)
    presence.sessionLogPath = childLogPath
    presence.openSessionLogPaths = [parentLogPath, childLogPath]

    let counts = CodexActiveSessionsModel.deriveActiveSubagentCounts(
        presences: [presence],
        lookupIndexes: indexes,
        recentWriteWindow: 30,
        childMtimeOverrides: [childLogPath: Date()]
    )

    // Count should be on the parent, not the child.
    XCTAssertEqual(counts["parent-003"], 1)
    XCTAssertNil(counts["child-003"])
}
```

- [ ] **Step 2: Run tests to verify they fail (won't compile)**

Run: `xcodebuild test -scheme AgentSessions -only-testing AgentSessionsTests/CodexActiveSessionsRegistryTests/testDeriveSubagentCounts_codex_parentResolvedViaMetadata_childCountedByMtime -destination 'platform=macOS' 2>&1 | tail -20`

Expected: Compilation failure — `deriveActiveSubagentCounts` does not exist.

- [ ] **Step 3: Implement `deriveActiveSubagentCounts` static method**

In `AgentSessions/Services/CodexActiveSessionsModel.swift`, add after the `parseLsofMachineOutput` methods (around line 3597):

```swift
// MARK: - Derived subagent counts (hybrid passive architecture)

/// Derives active subagent counts per parent session ID.
///
/// Identity: resolved from session metadata (parentSessionID).
/// Liveness: open log paths on a live process + file mtime within recentWriteWindow.
///
/// This is best-effort, not exact. Codex keeps all file handles open for the
/// process lifetime, so an open FD does not guarantee the subagent is still
/// running. The mtime check filters out finished subagents whose files are
/// no longer being written. If passive accuracy proves insufficient, the next
/// step is explicit instrumentation from the runtime itself.
///
/// - Parameters:
///   - presences: Live process presences from the active-sessions probe.
///   - lookupIndexes: Session metadata indexes for identity resolution.
///   - recentWriteWindow: Seconds within which a file mtime counts as "active".
///   - childMtimeOverrides: Optional overrides for file mtimes (for testing).
///     When nil for a path, the real filesystem mtime is used.
nonisolated static func deriveActiveSubagentCounts(
    presences: [CodexActivePresence],
    lookupIndexes: SessionLookupIndexes,
    recentWriteWindow: TimeInterval = 30,
    childMtimeOverrides: [String: Date]? = nil
) -> [String: Int] {
    let fm = FileManager.default
    let now = Date()
    let recencyCutoff = now.addingTimeInterval(-recentWriteWindow)
    var result: [String: Int] = [:]

    // Claude: scan subagents/ directory for each active Claude presence.
    for presence in presences where presence.source == .claude {
        guard let logPath = presence.sessionLogPath else { continue }
        let logURL = URL(fileURLWithPath: logPath)
        let parentDir = logURL.deletingLastPathComponent()
        let subagentsDir = parentDir.appendingPathComponent(
            logURL.deletingPathExtension().lastPathComponent
        ).appendingPathComponent("subagents")
        guard fm.fileExists(atPath: subagentsDir.path) else { continue }
        guard let contents = try? fm.contentsOfDirectory(
            at: subagentsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { continue }
        var activeCount = 0
        for file in contents where file.pathExtension == "jsonl" {
            let mtime: Date
            if let override = childMtimeOverrides?[file.path] {
                mtime = override
            } else {
                mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            }
            if mtime > recencyCutoff { activeCount += 1 }
        }
        if activeCount > 0 {
            let logNorm = normalizePath(logPath)
            let key = logLookupKey(source: .claude, normalizedPath: logNorm)
            if let sessionID = lookupIndexes.byLogPath[key]?.id {
                result[sessionID] = activeCount
            }
        }
    }

    // Codex / OpenCode: resolve parent/child via session metadata.
    for presence in presences where presence.source != .claude {
        guard presence.openSessionLogPaths.count > 1 else { continue }

        // Find the parent session among open paths: the one without parentSessionID.
        var parentSessionID: String?
        var parentPath: String?
        for path in presence.openSessionLogPaths {
            let norm = normalizePath(path)
            let key = logLookupKey(source: presence.source, normalizedPath: norm)
            if let session = lookupIndexes.byLogPath[key], session.parentSessionID == nil {
                parentSessionID = session.id
                parentPath = path
                break
            }
        }
        // Fallback: use presence.sessionLogPath if no non-subagent session found.
        if parentSessionID == nil, let logPath = presence.sessionLogPath {
            let norm = normalizePath(logPath)
            let key = logLookupKey(source: presence.source, normalizedPath: norm)
            parentSessionID = lookupIndexes.byLogPath[key]?.id
            parentPath = logPath
        }
        guard let parentSessionID, let parentPath else { continue }

        // Count non-parent paths with recent mtime as active subagents.
        var activeCount = 0
        for path in presence.openSessionLogPaths {
            guard path != parentPath else { continue }
            let mtime: Date
            if let override = childMtimeOverrides?[path] {
                mtime = override
            } else {
                mtime = (try? fm.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
            }
            if mtime > recencyCutoff { activeCount += 1 }
        }
        if activeCount > 0 {
            result[parentSessionID] = max(result[parentSessionID] ?? 0, activeCount)
        }
    }

    return result
}
```

- [ ] **Step 4: Check that `Session` init accepts `parentSessionID`, `subagentType`, `logPath` parameters**

The tests create `Session` objects with these fields. Check the `Session` type and `makeFallbackSession` helper to ensure the test code compiles. The test helper may need updating to support these parameters — if `makeFallbackSession` doesn't accept them, create sessions directly or extend the helper.

Verify by reading `Session` struct and adjusting tests if needed before running.

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild test -scheme AgentSessions -only-testing AgentSessionsTests/CodexActiveSessionsRegistryTests/testDeriveSubagentCounts_codex_parentResolvedViaMetadata_childCountedByMtime -only-testing AgentSessionsTests/CodexActiveSessionsRegistryTests/testDeriveSubagentCounts_codex_staleChildNotCounted -only-testing AgentSessionsTests/CodexActiveSessionsRegistryTests/testDeriveSubagentCounts_codex_preferredLogIsChild_parentStillResolved -destination 'platform=macOS' 2>&1 | tail -30`

Expected: All 3 PASS.

- [ ] **Step 6: Commit**

```
feat(model): add deriveActiveSubagentCounts for hybrid passive tracking
```

---

### Task 3: Add Claude subagent count test

**Files:**
- Test: `AgentSessionsTests/CodexActiveSessionsRegistryTests.swift`

- [ ] **Step 1: Write test for Claude directory-based discovery**

This test validates that the Claude path through `deriveActiveSubagentCounts` works. It requires a real temp directory with files since Claude discovery uses `FileManager.contentsOfDirectory`.

```swift
func testDeriveSubagentCounts_claude_subagentsDirectory_recentFileCounted() throws {
    // Set up a temp directory mimicking Claude's structure:
    //   <tmpdir>/<UUID>.jsonl          (parent log)
    //   <tmpdir>/<UUID>/subagents/agent-1.jsonl  (active child)
    //   <tmpdir>/<UUID>/subagents/agent-2.jsonl  (stale child)
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let parentUUID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    let parentLog = tmp.appendingPathComponent("\(parentUUID).jsonl")
    let subagentsDir = tmp.appendingPathComponent(parentUUID).appendingPathComponent("subagents")
    try FileManager.default.createDirectory(at: subagentsDir, withIntermediateDirectories: true)
    try Data("{}".utf8).write(to: parentLog)

    // Active child: touch now.
    let activeChild = subagentsDir.appendingPathComponent("agent-1.jsonl")
    try Data("{}".utf8).write(to: activeChild)

    // Stale child: backdate to 5 minutes ago.
    let staleChild = subagentsDir.appendingPathComponent("agent-2.jsonl")
    try Data("{}".utf8).write(to: staleChild)
    try FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(-300)],
        ofItemAtPath: staleChild.path
    )

    let parentSession = makeSession(id: parentUUID, source: .claude, cwd: "/proj", filePath: parentLog.path)
    let logNorm = CodexActiveSessionsModel.normalizePath(parentLog.path)
    let logKey = CodexActiveSessionsModel.logLookupKey(source: .claude, normalizedPath: logNorm)
    let indexes = SessionLookupIndexes(
        byLogPath: [logKey: parentSession],
        bySessionID: [parentUUID: parentSession],
        byWorkspace: [:]
    )

    var presence = makeFallbackPresence(source: .claude, lastSeenAt: Date(), workspaceRoot: "/proj", tty: "/dev/ttys010", pid: 500)
    presence.sessionLogPath = parentLog.path

    let counts = CodexActiveSessionsModel.deriveActiveSubagentCounts(
        presences: [presence],
        lookupIndexes: indexes,
        recentWriteWindow: 30
    )

    // Only the active child should be counted; stale one is filtered.
    XCTAssertEqual(counts[parentUUID], 1)
}
```

- [ ] **Step 2: Run test to verify it passes**

Run: `xcodebuild test -scheme AgentSessions -only-testing AgentSessionsTests/CodexActiveSessionsRegistryTests/testDeriveSubagentCounts_claude_subagentsDirectory_recentFileCounted -destination 'platform=macOS' 2>&1 | tail -20`

Expected: PASS.

- [ ] **Step 3: Commit**

```
test(model): add Claude subagent directory discovery coverage
```

---

### Task 4: Wire `deriveActiveSubagentCounts` into the refresh cycle

Add the published property to `CodexActiveSessionsModel` and call the derivation at the end of `refreshOnce`, after lookup indexes are populated.

**Files:**
- Modify: `AgentSessions/Services/CodexActiveSessionsModel.swift`

- [ ] **Step 1: Add published property**

Near line 153 (after `@Published private(set) var presences`), add:

```swift
/// Derived active subagent counts per parent session ID.
/// Computed during the refresh cycle from live presences + session metadata.
/// Best-effort: relies on open FDs and file mtime, not explicit instrumentation.
private(set) var activeSubagentCountsByParentSessionID: [String: Int] = [:]
```

Note: this is intentionally NOT `@Published`. It updates on the same cadence as `presences` and `activeMembershipVersion`, so consumers already get notified via those publishers. Avoiding a separate `@Published` prevents redundant SwiftUI invalidations.

- [ ] **Step 2: Add `updateActiveSubagentCounts` method to `CodexActiveSessionsModel`**

The model's internal `byLogPath` maps `String → CodexActivePresence`, but `deriveActiveSubagentCounts` needs `SessionLookupIndexes` (which maps `String → Session`) to check `parentSessionID`. Sessions live in the registry/store layer, not in the active-sessions model. The HUD derived-state model already builds `SessionLookupIndexes` from its session arrays, so it will call into the model with the indexes.

Add this method to `CodexActiveSessionsModel`:

```swift
/// Updates derived subagent counts. Called by the HUD derived-state model
/// after session indexes are rebuilt, so the count is model-owned state
/// rather than view-local computation.
func updateActiveSubagentCounts(lookupIndexes: SessionLookupIndexes) {
    activeSubagentCountsByParentSessionID = Self.deriveActiveSubagentCounts(
        presences: presences,
        lookupIndexes: lookupIndexes,
        recentWriteWindow: 30
    )
}
```

- [ ] **Step 3: Call `updateActiveSubagentCounts` from `rebuildIfReady`**

In `AgentCockpitHUDView.swift`, in `AgentCockpitHUDDerivedStateModel.rebuildIfReady` (line 433), add the call right before the `makeRowsSnapshot` call (line 438):

```swift
activeCodex.updateActiveSubagentCounts(lookupIndexes: lookupIndexes)
```

This ensures the model's counts are fresh before `makeRowsSnapshot` reads them.

- [ ] **Step 4: Verify the refresh integration compiles**

Run: `xcodebuild build -scheme AgentSessions -destination 'platform=macOS' 2>&1 | tail -20`

Expected: Build succeeds.

- [ ] **Step 5: Commit**

```
feat(model): wire deriveActiveSubagentCounts into refresh cycle
```

---

### Task 5: Remove the subagent pre-pass from the HUD

Replace the ~80-line pre-pass in `makeRowsSnapshot` with a read from the model's derived state.

**Files:**
- Modify: `AgentSessions/Views/AgentCockpitHUDView.swift`

- [ ] **Step 1: Replace the pre-pass with model read**

In `makeRowsSnapshot`, replace everything from the comment `// Pre-pass: count currently-active subagent files per parent session.` (line 1767) through the end of the Codex/OpenCode loop (line 1849) with:

```swift
// Subagent counts are derived by the model during the refresh cycle.
// The model combines session metadata (identity) with lsof open paths
// and file mtime (liveness) to produce counts. See
// CodexActiveSessionsModel.deriveActiveSubagentCounts for the policy.
let activeSubagentsBySessionID = activeCodex.activeSubagentCountsByParentSessionID
```

- [ ] **Step 2: Verify the downstream usage still compiles**

The existing line at ~1989 already reads `activeSubagentsBySessionID`:
```swift
activeSubagentCount: row.resolvedSessionID.flatMap { activeSubagentsBySessionID[$0] } ?? 0
```
This should continue to work unchanged since the variable name matches.

- [ ] **Step 3: Build and verify**

Run: `xcodebuild build -scheme AgentSessions -destination 'platform=macOS' 2>&1 | tail -20`

Expected: Build succeeds.

- [ ] **Step 4: Run all existing tests**

Run: `xcodebuild test -scheme AgentSessions -destination 'platform=macOS' 2>&1 | tail -30`

Expected: All tests pass.

- [ ] **Step 5: Commit**

```
refactor(cockpit): remove subagent pre-pass from HUD, consume model-derived counts
```

---

### Task 6: Add test that HUD rows consume model-derived counts

Verify end-to-end that `makeRowsSnapshot` uses the model's counts, not its own filesystem scan.

**Files:**
- Test: `AgentSessionsTests/CodexActiveSessionsRegistryTests.swift`

- [ ] **Step 1: Write test**

This test verifies the static `deriveActiveSubagentCounts` produces the count that would appear in `activeSubagentCount` on a HUD row. Since `makeRowsSnapshot` is tightly coupled to `CodexActiveSessionsModel` instance state, test the derivation function directly with a scenario that previously required the HUD pre-pass:

```swift
func testDeriveSubagentCounts_codex_activeChildWithinWindow_countedEvenIfParentAlsoOpen() {
    let parentLogPath = "/sessions/rollout-parent4.jsonl"
    let childLogPath = "/sessions/rollout-child4.jsonl"

    let parentSession = makeSession(id: "parent-004", source: .codex, cwd: "/proj", filePath: parentLogPath)
    let childSession = makeSession(id: "child-004", source: .codex, cwd: "/proj", filePath: childLogPath,
                                   parentSessionID: "parent-004", subagentType: "general")

    let parentLogKey = CodexActiveSessionsModel.logLookupKey(
        source: .codex,
        normalizedPath: CodexActiveSessionsModel.normalizePath(parentLogPath)
    )
    let childLogKey = CodexActiveSessionsModel.logLookupKey(
        source: .codex,
        normalizedPath: CodexActiveSessionsModel.normalizePath(childLogPath)
    )
    let indexes = SessionLookupIndexes(
        byLogPath: [parentLogKey: parentSession, childLogKey: childSession],
        bySessionID: [:],
        byWorkspace: [:]
    )

    var presence = makeFallbackPresence(source: .codex, lastSeenAt: Date(), workspaceRoot: "/proj", tty: "/dev/ttys004", pid: 400)
    presence.sessionLogPath = parentLogPath
    presence.openSessionLogPaths = [parentLogPath, childLogPath]

    // Child is active (mtime = now).
    let counts = CodexActiveSessionsModel.deriveActiveSubagentCounts(
        presences: [presence],
        lookupIndexes: indexes,
        recentWriteWindow: 30,
        childMtimeOverrides: [childLogPath: Date()]
    )

    XCTAssertEqual(counts["parent-004"], 1)
}
```

- [ ] **Step 2: Run test to verify it passes**

Run: `xcodebuild test -scheme AgentSessions -only-testing AgentSessionsTests/CodexActiveSessionsRegistryTests/testDeriveSubagentCounts_codex_activeChildWithinWindow_countedEvenIfParentAlsoOpen -destination 'platform=macOS' 2>&1 | tail -20`

Expected: PASS.

- [ ] **Step 3: Run all tests as final validation**

Run: `xcodebuild test -scheme AgentSessions -destination 'platform=macOS' 2>&1 | tail -30`

Expected: All tests pass.

- [ ] **Step 4: Commit**

```
test(model): add coverage for active child within recency window
```

---

### Implementation Notes

**What this does NOT do (by design):**
- No explicit runtime registry or CLI/plugin instrumentation.
- No feature flag.
- No pure DB-only query path for liveness.
- If passive accuracy is still unsatisfactory after this refactor, the next architectural step is explicit instrumentation that publishes exact live child-session state from the runtime itself.

**Recency window:** 30s for all providers. Defined as the `recentWriteWindow` parameter default.

**Test strategy:** Tests use `childMtimeOverrides` to inject deterministic timestamps rather than touching the real filesystem (except the Claude directory test which needs real files for `contentsOfDirectory`).
