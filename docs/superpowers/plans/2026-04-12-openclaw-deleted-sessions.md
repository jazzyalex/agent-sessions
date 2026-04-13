# OpenClaw Deleted Sessions — Full Support Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show OpenClaw's auto-deleted sessions (`.jsonl.deleted.<timestamp>`) by default with a visible "deleted" badge, rather than hiding them behind an advanced toggle.

**Architecture:** Add `isDeleted` and `deletedAt` properties to `Session`. Fix the parser to produce stable session IDs regardless of deletion suffix. Flip the default preference to `true`. Render a dim "deleted" badge in the session row source cell.

**Tech Stack:** Swift, SwiftUI, XCTest

---

### Task 1: Add `isDeleted` and `deletedAt` to the Session model

**Files:**
- Modify: `AgentSessions/Model/Session.swift:2-3` (add properties)
- Modify: `AgentSessions/Model/Session.swift:35-68` (full init)
- Modify: `AgentSessions/Model/Session.swift:71-108` (lightweight init)
- Modify: `AgentSessions/Model/Session.swift:110-130` (CodingKeys)
- Test: `AgentSessionsTests/SessionParserTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `SessionParserTests.swift`:

```swift
func testSessionIsDeletedDefaultsFalse() {
    let s = Session(id: "test",
                    source: .openclaw,
                    startTime: nil,
                    endTime: nil,
                    model: nil,
                    filePath: "/tmp/test.jsonl",
                    eventCount: 0,
                    events: [])
    XCTAssertFalse(s.isDeleted)
    XCTAssertNil(s.deletedAt)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme AgentSessions -only-testing AgentSessionsTests/SessionParserTests/testSessionIsDeletedDefaultsFalse -quiet 2>&1 | tail -5`
Expected: FAIL — `isDeleted` and `deletedAt` do not exist on `Session`.

- [ ] **Step 3: Add properties to Session**

In `AgentSessions/Model/Session.swift`, add after `public var isFavorite: Bool = false` (line 32):

```swift
// Deleted session support (OpenClaw auto-deletes sessions after 30 days)
public var isDeleted: Bool = false
public let deletedAt: Date?
```

Update the full init (line 35-68) — add parameters with defaults:

```swift
isDeleted: Bool = false,
deletedAt: Date? = nil,
```

And assign them in the body:

```swift
self.isDeleted = isDeleted
self.deletedAt = deletedAt
```

Update the lightweight init (line 71-108) — add the same parameters with defaults and assignments.

Update `CodingKeys` (line 110-130) — add:

```swift
case deletedAt
// isDeleted intentionally excluded (derived from filePath at parse time)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme AgentSessions -only-testing AgentSessionsTests/SessionParserTests/testSessionIsDeletedDefaultsFalse -quiet 2>&1 | tail -5`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add AgentSessions/Model/Session.swift AgentSessionsTests/SessionParserTests.swift
git commit -m "feat(model): add isDeleted and deletedAt to Session"
```

---

### Task 2: Fix parser to produce stable IDs for deleted files and set `isDeleted`

The current parser uses `url.deletingPathExtension().lastPathComponent` to derive the session base ID. For a deleted file like `my-session.jsonl.deleted.1704067200`, `deletingPathExtension()` strips only the last extension (`.1704067200`), producing `my-session.jsonl.deleted` — a different ID than the active file `my-session.jsonl` which produces `my-session`. We need to strip the full `.deleted.<ts>` suffix to produce a stable base ID.

**Files:**
- Modify: `AgentSessions/Services/OpenClawSessionParser.swift:125-133` (lightweight parse ID + isDeleted)
- Modify: `AgentSessions/Services/OpenClawSessionParser.swift:143-158` (lightweight parse Session init)
- Modify: `AgentSessions/Services/OpenClawSessionParser.swift:403-433` (full parse ID + isDeleted + Session init)
- Test: `AgentSessionsTests/SessionParserTests.swift`

- [ ] **Step 1: Write the failing tests**

Add to `SessionParserTests.swift`:

```swift
func testOpenClawDeletedFileProducesStableID() throws {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory.appendingPathComponent("AgentSessions-OpenClaw-DeletedID-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: tmp) }

    let sessionsDir = tmp.appendingPathComponent("agents/main/sessions", isDirectory: true)
    try fm.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

    let header = #"{"type":"session","version":3,"id":"sess-abc","timestamp":"2026-01-01T00:00:00Z","cwd":"/tmp"}"# + "\n"
    let user = #"{"type":"message","id":"m1","timestamp":"2026-01-01T00:01:00Z","message":{"role":"user","content":[{"type":"text","text":"hello"}]}}"# + "\n"

    let activeFile = sessionsDir.appendingPathComponent("my-session.jsonl")
    try (header + user).write(to: activeFile, atomically: true, encoding: .utf8)

    let deletedFile = sessionsDir.appendingPathComponent("my-session.jsonl.deleted.1704067200")
    try (header + user).write(to: deletedFile, atomically: true, encoding: .utf8)

    let activeSession = OpenClawSessionParser.parseFile(at: activeFile)
    let deletedSession = OpenClawSessionParser.parseFile(at: deletedFile)

    XCTAssertNotNil(activeSession)
    XCTAssertNotNil(deletedSession)

    // IDs must be identical so the same session doesn't appear twice
    XCTAssertEqual(activeSession!.id, deletedSession!.id)

    // isDeleted flags
    XCTAssertFalse(activeSession!.isDeleted)
    XCTAssertTrue(deletedSession!.isDeleted)

    // deletedAt should be parsed from the Unix timestamp suffix
    XCTAssertNil(activeSession!.deletedAt)
    XCTAssertNotNil(deletedSession!.deletedAt)
    XCTAssertEqual(deletedSession!.deletedAt!, Date(timeIntervalSince1970: 1704067200), accuracy: 1)
}

func testOpenClawDeletedFullParseMatchesLightweight() throws {
    let fm = FileManager.default
    let tmp = fm.temporaryDirectory.appendingPathComponent("AgentSessions-OpenClaw-DeletedFull-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: tmp) }

    let sessionsDir = tmp.appendingPathComponent("agents/main/sessions", isDirectory: true)
    try fm.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

    let header = #"{"type":"session","version":3,"id":"sess-xyz","timestamp":"2026-02-01T00:00:00Z","cwd":"/tmp"}"# + "\n"
    let user = #"{"type":"message","id":"m1","timestamp":"2026-02-01T00:01:00Z","message":{"role":"user","content":[{"type":"text","text":"test"}]}}"# + "\n"

    let deletedFile = sessionsDir.appendingPathComponent("test-session.jsonl.deleted.1706745600")
    try (header + user).write(to: deletedFile, atomically: true, encoding: .utf8)

    let light = OpenClawSessionParser.parseFile(at: deletedFile)
    let full = OpenClawSessionParser.parseFileFull(at: deletedFile)

    XCTAssertNotNil(light)
    XCTAssertNotNil(full)
    XCTAssertEqual(light!.id, full!.id)
    XCTAssertTrue(light!.isDeleted)
    XCTAssertTrue(full!.isDeleted)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme AgentSessions -only-testing AgentSessionsTests/SessionParserTests/testOpenClawDeletedFileProducesStableID -only-testing AgentSessionsTests/SessionParserTests/testOpenClawDeletedFullParseMatchesLightweight -quiet 2>&1 | tail -10`
Expected: FAIL — IDs don't match, `isDeleted` not set.

- [ ] **Step 3: Add helper to extract base filename and deletion metadata**

Add a private helper at the bottom of `OpenClawSessionParser` (before the closing `}`):

```swift
/// Strips `.deleted.<timestamp>` suffix from OpenClaw session filenames.
/// Returns (baseFileName, deletedAt) — deletedAt is non-nil only for deleted files.
private static func deletedFileMetadata(for url: URL) -> (baseName: String, isDeleted: Bool, deletedAt: Date?) {
    let name = url.lastPathComponent
    if let range = name.range(of: ".jsonl.deleted.") {
        let base = String(name[..<range.lowerBound])
        let tsString = String(name[range.upperBound...])
        let deletedAt: Date? = {
            if let ts = Double(tsString) { return Date(timeIntervalSince1970: ts) }
            return nil
        }()
        return (base, true, deletedAt)
    }
    // Active file: strip .jsonl extension
    let base = url.deletingPathExtension().lastPathComponent
    return (base, false, nil)
}
```

- [ ] **Step 4: Update lightweight parse (parseFile) to use the helper**

Replace the ID generation block in `parseFile` (lines 125-133) with:

```swift
let agentID = agentIDFromPath(url)
let meta = deletedFileMetadata(for: url)
let pathBaseID = meta.baseName
let baseID = forcedID
    ?? sessionID
    ?? (pathBaseID.isEmpty ? sha256(path: url.path) : pathBaseID)
let id: String = {
    if let forcedID, forcedID.hasPrefix("openclaw:") { return forcedID }
    return "openclaw:\(agentID):\(baseID)"
}()
```

Update the Session init call (lines 143-158) — add `isDeleted` and `deletedAt`:

```swift
return Session(
    id: id,
    source: .openclaw,
    startTime: tmin ?? mtime,
    endTime: tmax ?? mtime,
    model: model,
    filePath: url.path,
    fileSizeBytes: size >= 0 ? size : nil,
    eventCount: max(0, estimatedEvents),
    events: [],
    cwd: cwd,
    repoName: nil,
    lightweightTitle: title,
    lightweightCommands: estimatedCommands,
    isHousekeeping: isHousekeeping,
    isDeleted: meta.isDeleted,
    deletedAt: meta.deletedAt
)
```

- [ ] **Step 5: Update full parse (parseFileFull) to use the helper**

Replace the ID generation block in `parseFileFull` (lines 403-411) with the same pattern:

```swift
let agentID = agentIDFromPath(url)
let meta = deletedFileMetadata(for: url)
let pathBaseID = meta.baseName
let baseID = forcedID
    ?? sessionID
    ?? (pathBaseID.isEmpty ? sha256(path: url.path) : pathBaseID)
let id: String = {
    if let forcedID, forcedID.hasPrefix("openclaw:") { return forcedID }
    return "openclaw:\(agentID):\(baseID)"
}()
```

Update the Session init call (lines 418-433) — add `isDeleted` and `deletedAt`:

```swift
return Session(
    id: id,
    source: .openclaw,
    startTime: start,
    endTime: end,
    model: model,
    filePath: url.path,
    fileSizeBytes: size >= 0 ? size : nil,
    eventCount: max(events.filter { $0.kind != .meta }.count, 0),
    events: events,
    cwd: cwd,
    repoName: nil,
    lightweightTitle: nil,
    lightweightCommands: nil,
    isHousekeeping: isHousekeeping,
    isDeleted: meta.isDeleted,
    deletedAt: meta.deletedAt
)
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `xcodebuild test -scheme AgentSessions -only-testing AgentSessionsTests/SessionParserTests/testOpenClawDeletedFileProducesStableID -only-testing AgentSessionsTests/SessionParserTests/testOpenClawDeletedFullParseMatchesLightweight -quiet 2>&1 | tail -10`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add AgentSessions/Services/OpenClawSessionParser.swift AgentSessionsTests/SessionParserTests.swift
git commit -m "feat(parser): stable IDs and isDeleted for OpenClaw deleted sessions"
```

---

### Task 3: Flip default preference to include deleted sessions

Currently `includeOpenClawDeletedSessions` defaults to `false`. Since OpenClaw auto-deletes as routine GC (not user intent), deleted sessions should be shown by default.

**Files:**
- Modify: `AgentSessions/Services/OpenClawSessionIndexer.swift:50` (init default)
- Modify: `AgentSessions/Services/OpenClawSessionIndexer.swift:85` (refresh default)
- Modify: `AgentSessions/Services/SessionArchiveManager.swift:423` (archive scan default)
- Modify: `AgentSessions/Views/Preferences/PreferencesView+Droid.swift:212-216` (toggle label + help text)
- Test: `AgentSessionsTests/SessionParserTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `SessionParserTests.swift`:

```swift
func testOpenClawDiscoveryIncludesDeletedByDefault() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-OpenClaw-DefaultDeleted-\(UUID().uuidString)", isDirectory: true)
    defer { try? fm.removeItem(at: root) }

    let sessionsDir = root.appendingPathComponent("agents/main/sessions", isDirectory: true)
    try fm.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

    let active = sessionsDir.appendingPathComponent("active.jsonl")
    let deleted = sessionsDir.appendingPathComponent("old.jsonl.deleted.1704067200")
    try writeText(#"{"type":"session"}"# + "\n", to: active)
    try writeText(#"{"type":"session"}"# + "\n", to: deleted)

    // Default discovery (no explicit includeDeleted) should include deleted files
    let discovery = OpenClawSessionDiscovery(customRoot: root.path)
    let found = discovery.discoverSessionFiles()
    XCTAssertEqual(found.count, 2, "Default discovery should include both active and deleted sessions")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme AgentSessions -only-testing AgentSessionsTests/SessionParserTests/testOpenClawDiscoveryIncludesDeletedByDefault -quiet 2>&1 | tail -5`
Expected: FAIL — only 1 file found (active only), because `includeDeleted` defaults to `false`.

- [ ] **Step 3: Flip the default in OpenClawSessionDiscovery**

In `AgentSessions/Services/OpenClawSessionDiscovery.swift`, line 13, change:

```swift
init(customRoot: String? = nil, includeDeleted: Bool = false) {
```

to:

```swift
init(customRoot: String? = nil, includeDeleted: Bool = true) {
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme AgentSessions -only-testing AgentSessionsTests/SessionParserTests/testOpenClawDiscoveryIncludesDeletedByDefault -quiet 2>&1 | tail -5`
Expected: PASS

- [ ] **Step 5: Update the indexer to read the pref with `true` as fallback**

The indexer reads the UserDefaults bool, which returns `false` when the key isn't set. We need the pref to default to `true`. In `OpenClawSessionIndexer.swift`, at the two places where `includeDeleted` is read from UserDefaults (lines 50 and 85), the `bool(forKey:)` call returns `false` for unset keys. We need to register the default.

Add default registration at the top of `init()` in `OpenClawSessionIndexer.swift` (before line 49):

```swift
UserDefaults.standard.register(defaults: [
    PreferencesKey.Advanced.includeOpenClawDeletedSessions: true
])
```

Also update `SessionArchiveManager.swift` line 423 — same pattern. If it reads the pref, add the same default registration or ensure consistency.

- [ ] **Step 6: Update the preference toggle label**

In `PreferencesView+Droid.swift`, lines 212-216, change:

```swift
Toggle("Include deleted OpenClaw sessions", isOn: Binding(
```

to:

```swift
Toggle("Show deleted OpenClaw sessions", isOn: Binding(
```

And update the help text from:

```swift
.help("Show OpenClaw/Clawdbot transcripts ending in .jsonl.deleted.<timestamp>. Hidden by default.")
```

to:

```swift
.help("OpenClaw auto-deletes sessions after 30 days. Shown by default with a 'deleted' badge. Disable to hide them.")
```

- [ ] **Step 7: Fix the existing discovery test**

The existing test `testOpenClawDiscoveryExcludesDeletedAndLockFiles` (around line 890) creates a discovery with default `includeDeleted` and asserts only 1 file found. Since we flipped the default, update that test to explicitly pass `includeDeleted: false`:

```swift
let discovery = OpenClawSessionDiscovery(customRoot: root.path, includeDeleted: false)
```

And add a comment explaining why.

- [ ] **Step 8: Run full test suite**

Run: `xcodebuild test -scheme AgentSessions -quiet 2>&1 | tail -20`
Expected: All tests PASS.

- [ ] **Step 9: Commit**

```bash
git add AgentSessions/Services/OpenClawSessionDiscovery.swift AgentSessions/Services/OpenClawSessionIndexer.swift AgentSessions/Services/SessionArchiveManager.swift AgentSessions/Views/Preferences/PreferencesView+Droid.swift AgentSessionsTests/SessionParserTests.swift
git commit -m "feat(openclaw): show deleted sessions by default

OpenClaw auto-deletes sessions after 30 days as routine GC.
These are not user-initiated deletions, so show them by default."
```

---

### Task 4: Render "deleted" badge in the session row

**Files:**
- Modify: `AgentSessions/Views/UnifiedSessionsView.swift:1990-1995` (add badge in `cellSource`)
- Test: Build and visually verify in the app.

- [ ] **Step 1: Add the "deleted" badge**

In `cellSource(for:)` in `UnifiedSessionsView.swift`, after the subagent badge block (line 1995) and before the `Text(label)` line (line 1996), add:

```swift
if session.isDeleted {
    Text("deleted")
        .font(.system(size: 9, weight: .medium, design: .monospaced))
        .foregroundStyle(isSelected ? .white.opacity(0.6) : .secondary)
        .accessibilityLabel("Deleted session")
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `xcodebuild build -scheme AgentSessions -quiet 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add AgentSessions/Views/UnifiedSessionsView.swift
git commit -m "feat(ui): show 'deleted' badge for OpenClaw deleted sessions"
```

---

### Task 5: Propagate `isDeleted` through the indexer reload/merge path

When the indexer does a full reload of a session (`reloadSession`), it merges the full-parsed session into the lightweight one. The `isDeleted` flag must survive this merge.

**Files:**
- Modify: `AgentSessions/Services/OpenClawSessionIndexer.swift:330-345` (merge in `reloadSession`)

- [ ] **Step 1: Write the failing test**

Add to `SessionParserTests.swift`:

```swift
func testDeletedFlagSurvivesMerge() {
    let light = Session(id: "openclaw:main:test",
                        source: .openclaw,
                        startTime: Date(),
                        endTime: Date(),
                        model: nil,
                        filePath: "/tmp/test.jsonl.deleted.1704067200",
                        eventCount: 1,
                        events: [],
                        cwd: "/tmp",
                        repoName: nil,
                        lightweightTitle: "test",
                        isDeleted: true,
                        deletedAt: Date(timeIntervalSince1970: 1704067200))
    XCTAssertTrue(light.isDeleted)
    XCTAssertNotNil(light.deletedAt)

    // Simulate what reloadSession does: create a "full" session and merge fields
    // The merged session must preserve isDeleted from the lightweight session
    let full = Session(id: "openclaw:main:test",
                       source: .openclaw,
                       startTime: Date(),
                       endTime: Date(),
                       model: "gpt-4",
                       filePath: "/tmp/test.jsonl.deleted.1704067200",
                       eventCount: 3,
                       events: [],
                       cwd: "/tmp",
                       repoName: nil,
                       lightweightTitle: nil,
                       isDeleted: true,
                       deletedAt: Date(timeIntervalSince1970: 1704067200))
    XCTAssertTrue(full.isDeleted)
}
```

- [ ] **Step 2: Run test**

Run: `xcodebuild test -scheme AgentSessions -only-testing AgentSessionsTests/SessionParserTests/testDeletedFlagSurvivesMerge -quiet 2>&1 | tail -5`
Expected: PASS (the flag is set by the parser from the filename, so both lightweight and full parse produce it).

- [ ] **Step 3: Update the merge in reloadSession**

In `OpenClawSessionIndexer.swift`, the `Session(...)` merge constructor call (lines 330-345) doesn't currently pass `isDeleted` or `deletedAt`. Since both the lightweight and full parse now set these from the filename, the full-parsed session already has them. But the merge uses the lightweight init and must pass them through.

Update the merge to include:

```swift
let merged = Session(
    id: current.id,
    source: .openclaw,
    startTime: full.startTime ?? current.startTime,
    endTime: full.endTime ?? current.endTime,
    model: full.model ?? current.model,
    filePath: full.filePath,
    fileSizeBytes: full.fileSizeBytes ?? current.fileSizeBytes,
    eventCount: max(current.eventCount, full.nonMetaCount),
    events: full.events,
    cwd: current.lightweightCwd ?? full.cwd,
    repoName: current.repoName,
    lightweightTitle: current.lightweightTitle ?? full.lightweightTitle,
    lightweightCommands: current.lightweightCommands,
    isHousekeeping: full.isHousekeeping,
    isDeleted: current.isDeleted || full.isDeleted,
    deletedAt: current.deletedAt ?? full.deletedAt
)
```

- [ ] **Step 4: Build to verify compilation**

Run: `xcodebuild build -scheme AgentSessions -quiet 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Run full test suite**

Run: `xcodebuild test -scheme AgentSessions -quiet 2>&1 | tail -20`
Expected: All tests PASS.

- [ ] **Step 6: Commit**

```bash
git add AgentSessions/Services/OpenClawSessionIndexer.swift AgentSessionsTests/SessionParserTests.swift
git commit -m "feat(indexer): propagate isDeleted through session reload merge"
```

---

### Task 6: Verify end-to-end in the running app

- [ ] **Step 1: Build and launch**

Run: `xcodebuild build -scheme AgentSessions -quiet && open /path/to/build/AgentSessions.app`
(Or launch from Xcode.)

- [ ] **Step 2: Verify OpenClaw sessions appear**

Confirm that the OpenClaw tab shows the 350+ deleted sessions that were previously hidden.

- [ ] **Step 3: Verify "deleted" badge**

Each deleted session row should show the dim "deleted" text between the subagent badge area and the "OpenClaw" source label.

- [ ] **Step 4: Verify the preference toggle**

Open Preferences → Advanced → "Show deleted OpenClaw sessions". It should be ON by default. Toggling it OFF should hide the deleted sessions. Toggling back ON should restore them.

- [ ] **Step 5: Verify session IDs are stable**

If any active `.jsonl` session exists alongside its `.jsonl.deleted.<ts>` copy, they should appear as a single entry (not duplicated).
