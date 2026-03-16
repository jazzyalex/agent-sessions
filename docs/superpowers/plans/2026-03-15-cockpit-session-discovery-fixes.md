# Cockpit Session Discovery Fixes

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix two bugs causing Claude Code sessions to be invisible or mislabeled in the Cockpit HUD.

**Architecture:** (A) Remove the dead `lsof -c claude` call since Claude Code sets `process.title` to a version string, making lsof's command-name filter always miss. The ps-based fallback already handles discovery. (B) Prevent multiple presences sharing a workspace from all resolving to the same indexed session — only the first match claims it, others stay unresolved so they display as generic "Active Claude session" rows instead of showing stolen content.

**Tech Stack:** Swift, XCTest, Xcode (scheme: AgentSessionsLogicTests)

---

## Chunk 1: Remove dead `lsof -c claude` call

### Task 1: Add test proving ps-only discovery works without lsof -c

**Files:**
- Modify: `AgentSessionsTests/CodexActiveSessionsRegistryTests.swift`

- [ ] **Step 1: Write test verifying Claude sessions are found via ps-based PID query only**

Add a test that calls `parseLsofMachineOutput` with a PID-based lsof result (no `-c claude` involved) and confirms the Claude session is correctly parsed with cwd, tty, and sessionLogPath.

```swift
func testClaudeSessionDiscoveredViaPIDBasedLsofQuery() {
    // Simulates the output from `lsof -p {PID}` (the ps fallback path),
    // NOT from `lsof -c claude` (which returns nothing because Claude Code
    // sets process.title to its version string).
    let root = "/Users/test/.claude"
    let text = """
    p42001
    fcwd
    tDIR
    n/Users/test/Repository/MyProject
    f0
    tCHR
    n/dev/ttys015
    f26w
    tREG
    n/Users/test/.claude/projects/-Users-test-Repository-MyProject/abc12345-6789-abcd-ef01-234567890abc.jsonl
    """

    let out = CodexActiveSessionsModel.parseLsofMachineOutput(text, sessionsRoots: [root], source: .claude)
    XCTAssertEqual(out.count, 1)
    XCTAssertEqual(out[42001]?.cwd, "/Users/test/Repository/MyProject")
    XCTAssertEqual(out[42001]?.tty, "/dev/ttys015")
    XCTAssertEqual(
        out[42001]?.sessionLogPath,
        "/Users/test/.claude/projects/-Users-test-Repository-MyProject/abc12345-6789-abcd-ef01-234567890abc.jsonl"
    )
    XCTAssertEqual(out[42001]?.sessionID, "abc12345-6789-abcd-ef01-234567890abc")
}
```

- [ ] **Step 2: Run test to verify it passes**

Run: `xcodebuild test -project AgentSessions.xcodeproj -scheme AgentSessionsLogicTests -testLanguage en -only-testing:AgentSessionsTests/CodexActiveSessionsRegistryTests/testClaudeSessionDiscoveredViaPIDBasedLsofQuery 2>&1 | tail -20`

Expected: PASS (this test validates existing behavior — the parser already works)

- [ ] **Step 3: Commit**

```bash
git add AgentSessionsTests/CodexActiveSessionsRegistryTests.swift
git commit -m "test: add test for ps-based Claude session discovery path"
```

### Task 2: Remove the dead `lsof -c claude` call

**Files:**
- Modify: `AgentSessions/Services/CodexActiveSessionsModel.swift:826-832`

- [ ] **Step 4: Remove the `claudeInfos` lsof -c query**

In `discoverProcessPresences`, remove the `claudeInfos` query that uses `lsof -c claude` (lines 826-832) and change the merge at line 870 to use only `claudeCommandInfos`.

Replace:
```swift
        let claudeInfos = await discoverLsofPIDInfos(
            generation: generation,
            source: .claude,
            queryArguments: ["-w", "-a", "-c", "claude", "-u", user, "-nP", "-F", "pftn"],
            sessionsRoots: claudeSessionRoots,
            timeout: timeout
        )
        let claudeCommandInfos: [Int: LsofPIDInfo]
        if claudeCommandPIDs.isEmpty {
            claudeCommandInfos = [:]
        } else {
            claudeCommandInfos = await discoverLsofPIDInfos(
                generation: generation,
                source: .claude,
                queryArguments: ["-w", "-a", "-p", claudeCommandPIDs.map(String.init).joined(separator: ","), "-u", user, "-nP", "-F", "pftn"],
                sessionsRoots: claudeSessionRoots,
                timeout: timeout
            )
        }
```

With:
```swift
        // Claude Code sets process.title to its version string (e.g. "2.1.76"),
        // so `lsof -c claude` never matches. Discover via ps-based PID query only.
        let claudeInfos: [Int: LsofPIDInfo]
        if claudeCommandPIDs.isEmpty {
            claudeInfos = [:]
        } else {
            claudeInfos = await discoverLsofPIDInfos(
                generation: generation,
                source: .claude,
                queryArguments: ["-w", "-a", "-p", claudeCommandPIDs.map(String.init).joined(separator: ","), "-u", user, "-nP", "-F", "pftn"],
                sessionsRoots: claudeSessionRoots,
                timeout: timeout
            )
        }
```

Also update the merge at line 870 from:
```swift
            .claude: Self.mergePIDInfos(claudeInfos, with: claudeCommandInfos),
```
To:
```swift
            .claude: claudeInfos,
```

- [ ] **Step 5: Run all existing tests**

Run: `xcodebuild test -project AgentSessions.xcodeproj -scheme AgentSessionsLogicTests -testLanguage en 2>&1 | tail -20`

Expected: All tests PASS

- [ ] **Step 6: Commit**

```bash
git add AgentSessions/Services/CodexActiveSessionsModel.swift
git commit -m "fix: skip dead lsof -c claude query in process discovery

Claude Code sets process.title to its version string (e.g. 2.1.76),
making lsof's -c command-name filter always return empty results.
The ps-based PID fallback already discovers all Claude sessions.
Removing the dead call saves ~0.75s per probe cycle."
```

---

## Chunk 2: Prevent workspace-only resolution from claiming same session for multiple presences

### Task 3: Add test for workspace dedup behavior

**Files:**
- Modify: `AgentSessionsTests/CodexActiveSessionsRegistryTests.swift`

- [ ] **Step 7: Write test showing two presences with same workspace resolve independently**

This test verifies that when two presences share the same workspace but have no log path or session ID, only the first one resolves to the indexed session — the second should remain unresolved rather than displaying stolen content.

We cannot easily test `makeRowsSnapshot` directly (it's `fileprivate`). Instead, test the underlying resolution behavior by verifying that the `resolveByWorkspace` lookup returns only one session per workspace key — which is already the case. The fix needs to be at the `makeRowsSnapshot` level: track which sessions have been claimed.

Since `makeRowsSnapshot` is `fileprivate`, we need to add a `static` test-accessible helper or test via the public snapshot API. The simplest approach is to refactor the workspace-claim tracking into a testable static function.

- [ ] **Step 8: Add workspace-claim tracking to makeRowsSnapshot**

In `AgentCockpitHUDView.swift`, inside `makeRowsSnapshot`, add a `Set<String>` to track which session IDs have already been claimed by a workspace-only resolution. When a second presence tries to claim the same session via workspace, it gets `nil` instead.

In the `mappedRows` closure, after the session resolution chain (line 1723-1727), add claim tracking:

Replace:
```swift
            let session = logNorm.flatMap { normalized in
                lookupIndexes.byLogPath[CodexActiveSessionsModel.logLookupKey(source: presence.source, normalizedPath: normalized)]
            } ?? Self.resolveBySessionID(presence.sessionId, source: presence.source, lookupIndexes: lookupIndexes)
                ?? Self.resolveByWorkspace(presence.workspaceRoot, source: presence.source, lookupIndexes: lookupIndexes)
                ?? fallbackSessionByPresenceKey[presenceKey]
```

With:
```swift
            let resolvedByLogOrID = logNorm.flatMap { normalized in
                lookupIndexes.byLogPath[CodexActiveSessionsModel.logLookupKey(source: presence.source, normalizedPath: normalized)]
            } ?? Self.resolveBySessionID(presence.sessionId, source: presence.source, lookupIndexes: lookupIndexes)
            let isDefinitiveMatch = resolvedByLogOrID != nil
            let session = resolvedByLogOrID
                ?? Self.resolveByWorkspace(presence.workspaceRoot, source: presence.source, lookupIndexes: lookupIndexes)
                ?? fallbackSessionByPresenceKey[presenceKey]
```

Then, to prevent the same session being used for multiple workspace-only matches, change `mappedRows` from a simple `compactMap` to a loop that maintains a `claimedSessionIDs` set. Before constructing the row, check:

```swift
            // Prevent multiple workspace-only matches from claiming the same session.
            // Without a log path or session ID, the workspace match is ambiguous —
            // a second presence in the same directory is likely a different session.
            let effectiveSession: Session?
            if let session, !isDefinitiveMatch {
                if claimedSessionIDs.contains(session.id) {
                    effectiveSession = nil
                } else {
                    claimedSessionIDs.insert(session.id)
                    effectiveSession = session
                }
            } else {
                effectiveSession = session
            }
```

Then use `effectiveSession` instead of `session` for the rest of the row construction.

**Full replacement** — replace the `let mappedRows` block (lines 1718-1771):

```swift
        var claimedSessionIDs: Set<String> = []
        let mappedRows: [LegacyMappedRow] = presences.compactMap { presence in
            guard supportedSources.contains(presence.source) else { return nil }
            let logNorm = presence.sessionLogPath.map(CodexActiveSessionsModel.normalizePath)
            let presenceKey = CodexActiveSessionsModel.presenceKey(for: presence)

            let resolvedByLogOrID = logNorm.flatMap { normalized in
                lookupIndexes.byLogPath[CodexActiveSessionsModel.logLookupKey(source: presence.source, normalizedPath: normalized)]
            } ?? Self.resolveBySessionID(presence.sessionId, source: presence.source, lookupIndexes: lookupIndexes)
            let isDefinitiveMatch = resolvedByLogOrID != nil
            let candidate = resolvedByLogOrID
                ?? Self.resolveByWorkspace(presence.workspaceRoot, source: presence.source, lookupIndexes: lookupIndexes)
                ?? fallbackSessionByPresenceKey[presenceKey]

            // Prevent multiple workspace-only matches from claiming the same session.
            // Without a log path or session ID, the workspace match is ambiguous —
            // a second presence in the same directory is likely a different session.
            let session: Session?
            if let candidate, !isDefinitiveMatch {
                if claimedSessionIDs.contains(candidate.id) {
                    session = nil
                } else {
                    claimedSessionIDs.insert(candidate.id)
                    session = candidate
                }
            } else {
                session = candidate
            }

            if Self.shouldHideUnresolvedPresencePlaceholder(presence, resolvedSession: session, lookupIndexes: lookupIndexes) {
                return nil
            }

            let title = session?.title
                ?? presence.sessionId.map { "Session \($0.prefix(8))" }
                ?? "Active \(presence.source.displayName) session"

            let repo = Self.projectLabel(resolvedSession: session, presence: presence)
            let date = session?.modifiedAt ?? Self.parseSessionTimestamp(from: presence)
            let lastActivityAt = activeCodex.lastActivityAt(for: presence) ?? date
            let liveState = activeCodex.liveState(for: presence)
            let idleReason = activeCodex.idleReason(for: presence)

            let stableID: String =
                "\(presence.source.rawValue)|" + (logNorm
                ?? presence.sessionId
                ?? presence.sourceFilePath
                ?? presence.pid.map { "pid:\($0)" }
                ?? presence.tty
                ?? "\(presence.sessionLogPath ?? "unknown")|\(presence.pid ?? -1)")

            return LegacyMappedRow(
                id: stableID,
                source: presence.source,
                title: title,
                liveState: liveState,
                lastSeenAt: presence.lastSeenAt,
                repo: repo,
                date: date,
                focusURL: presence.revealURL,
                itermSessionId: presence.terminal?.itermSessionId,
                tty: presence.tty,
                termProgram: presence.terminal?.termProgram,
                tabTitle: presence.terminal?.tabTitle,
                resolvedSessionID: session?.id,
                sessionID: Self.authoritativeSessionID(for: presence, resolvedSession: session),
                logPath: presence.sessionLogPath,
                workingDirectory: session?.cwd ?? presence.workspaceRoot,
                lastActivityAt: lastActivityAt,
                idleReason: idleReason
            )
        }
```

**Note:** The `compactMap` closure captures `claimedSessionIDs` as a mutable local. Since `compactMap` runs synchronously and sequentially, mutation is safe. However, if the compiler complains about capturing a mutable variable, convert the `compactMap` to a `for` loop that builds the array manually:

```swift
        var claimedSessionIDs: Set<String> = []
        var mappedRows: [LegacyMappedRow] = []
        mappedRows.reserveCapacity(presences.count)
        for presence in presences {
            // ... same body as above, using mappedRows.append(row) instead of return row,
            //     and `continue` instead of `return nil` ...
        }
```

- [ ] **Step 9: Run all tests**

Run: `xcodebuild test -project AgentSessions.xcodeproj -scheme AgentSessionsLogicTests -testLanguage en 2>&1 | tail -20`

Expected: All tests PASS

- [ ] **Step 10: Commit**

```bash
git add AgentSessions/Views/AgentCockpitHUDView.swift
git commit -m "fix: prevent workspace-only resolution from claiming same session for multiple presences

When two Claude processes share the same cwd but neither has a JSONL
file open, both presences resolve via workspace to the same indexed
session. This caused one session to steal the other's title/content.

Now track which session IDs have been claimed by workspace-only matches.
The first presence claims the session; additional presences in the same
directory display as generic 'Active Claude session' rows instead."
```

---

## Verification

- [ ] **Step 11: Manual test**

1. Open two `claude` sessions in the same project directory (different iTerm tabs)
2. Interact with only one session so its JSONL has content
3. Open the Cockpit HUD
4. Verify:
   - Both sessions appear as separate rows within ~6 seconds
   - The active session shows its actual title/content
   - The idle session shows "Active Claude session" (not the other session's content)
   - Both sessions have correct tab titles from iTerm
   - Clicking either row reveals the correct iTerm tab
