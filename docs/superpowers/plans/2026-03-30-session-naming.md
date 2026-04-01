# Show Claude Session Names — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Display Claude Code's `/rename` custom session names in Agent Sessions instead of derived first-message titles.

**Architecture:** Add a `customTitle` field to the `Session` model. Extract it from `custom-title` and `agent-name` JSONL records during parsing. Persist it in a new `custom_title` DB column. The existing `Session.title` computed property gains a highest-priority branch that returns `customTitle` when present.

**Tech Stack:** Swift, SQLite (raw C API via `sqlite3`), JSONL parsing

---

### Task 1: Add `customTitle` to Session model

**Files:**
- Modify: `AgentSessions/Model/Session.swift:1-124`

- [ ] **Step 1: Add the stored property**

After line 22 (`public let lightweightTitle: String?`), add:

```swift
public let customTitle: String?
```

- [ ] **Step 2: Add to full-session initializer**

In the init starting at line 34, add `customTitle: String? = nil` parameter after `subagentType`, and assign `self.customTitle = customTitle`. Also set it in the existing body alongside the other nil assignments:

```swift
// Default initializer for full sessions
public init(id: String,
            source: SessionSource = .codex,
            startTime: Date?,
            endTime: Date?,
            model: String?,
            filePath: String,
            fileSizeBytes: Int? = nil,
            eventCount: Int,
            events: [SessionEvent],
            isHousekeeping: Bool = false,
            codexInternalSessionIDHint: String? = nil,
            parentSessionID: String? = nil,
            subagentType: String? = nil,
            customTitle: String? = nil) {
    self.id = id
    self.source = source
    self.startTime = startTime
    self.endTime = endTime
    self.model = model
    self.filePath = filePath
    self.fileSizeBytes = fileSizeBytes
    self.eventCount = eventCount
    self.events = events
    self.isHousekeeping = isHousekeeping
    self.lightweightCwd = nil
    self.lightweightRepoName = nil
    self.lightweightTitle = nil
    self.codexInternalSessionIDHint = codexInternalSessionIDHint
    self.lightweightCommands = nil
    self.parentSessionID = parentSessionID
    self.subagentType = subagentType
    self.customTitle = customTitle
    self.isFavorite = false
}
```

- [ ] **Step 3: Add to lightweight-session initializer**

In the init starting at line 68, add `customTitle: String? = nil` parameter after `subagentType`, and assign it:

```swift
// Lightweight session initializer
public init(id: String,
            source: SessionSource = .codex,
            startTime: Date?,
            endTime: Date?,
            model: String?,
            filePath: String,
            fileSizeBytes: Int? = nil,
            eventCount: Int,
            events: [SessionEvent],
            cwd: String?,
            repoName: String?,
            lightweightTitle: String?,
            lightweightCommands: Int? = nil,
            isHousekeeping: Bool = false,
            codexInternalSessionIDHint: String? = nil,
            parentSessionID: String? = nil,
            subagentType: String? = nil,
            customTitle: String? = nil) {
    self.id = id
    self.source = source
    self.startTime = startTime
    self.endTime = endTime
    self.model = model
    self.filePath = filePath
    self.fileSizeBytes = fileSizeBytes
    self.eventCount = eventCount
    self.events = events
    self.isHousekeeping = isHousekeeping
    self.lightweightCwd = cwd
    self.lightweightRepoName = repoName
    self.lightweightTitle = lightweightTitle
    self.codexInternalSessionIDHint = codexInternalSessionIDHint
    self.lightweightCommands = lightweightCommands
    self.parentSessionID = parentSessionID
    self.subagentType = subagentType
    self.customTitle = customTitle
    self.isFavorite = false
}
```

- [ ] **Step 4: Add to CodingKeys**

Add `customTitle` to the `CodingKeys` enum (after `subagentType`, line 121):

```swift
private enum CodingKeys: String, CodingKey {
    case id
    case source
    case startTime
    case endTime
    case model
    case filePath
    case fileSizeBytes
    case eventCount
    case events
    case lightweightCwd
    case lightweightRepoName
    case lightweightTitle
    case lightweightCommands
    case codexInternalSessionIDHint
    case parentSessionID
    case subagentType
    case customTitle
    // isFavorite intentionally excluded (runtime only)
    // isHousekeeping intentionally excluded (derived at parse/index time)
}
```

- [ ] **Step 5: Add custom title priority in `title` computed property**

Insert a new highest-priority branch at the top of `var title: String` (line 133), before the `let defaults` line:

```swift
public var title: String {
    // Custom title from /rename takes absolute precedence
    if let custom = customTitle, !custom.isEmpty {
        return custom
    }

    let defaults = UserDefaults.standard
    // ... rest unchanged ...
```

- [ ] **Step 6: Build to verify no compile errors**

Run: `xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 7: Commit**

```bash
git add AgentSessions/Model/Session.swift
git commit -m "feat(model): add customTitle property to Session for /rename support"
```

---

### Task 2: Extract custom title in ClaudeSessionParser

**Files:**
- Modify: `AgentSessions/Services/ClaudeSessionParser.swift:32-121` (full parser)
- Modify: `AgentSessions/Services/ClaudeSessionParser.swift:637-789` (lightweight parser)

- [ ] **Step 1: Extract in full parser (`parseFileFull`)**

In `parseFileFull` (starting line 32), add a `var customTitle: String?` alongside the other metadata vars (after `var tmax: Date?` at line 43). Then inside the `forEachLine` closure, after the timestamp extraction block (~line 85), add detection:

```swift
var customTitle: String?
```

Inside the closure, after the timestamp extraction (after line 85):

```swift
// Extract custom title from /rename records (last one wins)
if let t = obj["type"] as? String {
    if t == "custom-title", let ct = obj["customTitle"] as? String, !ct.isEmpty {
        customTitle = ct
    } else if t == "agent-name", let an = obj["agentName"] as? String, !an.isEmpty {
        customTitle = an
    }
}
```

Then in the Session constructor at line 103, pass `customTitle`:

```swift
return Session(
    id: fileID,
    source: .claude,
    startTime: tmin,
    endTime: tmax,
    model: llmModel ?? model,
    filePath: url.path,
    fileSizeBytes: size >= 0 ? size : nil,
    eventCount: nonMetaCount,
    events: events,
    cwd: cwd,
    repoName: nil,
    lightweightTitle: nil,
    isHousekeeping: isHousekeeping,
    codexInternalSessionIDHint: sessionID,
    parentSessionID: parentSessionID,
    subagentType: subagentType,
    customTitle: customTitle
)
```

- [ ] **Step 2: Extract in lightweight parser (`lightweightSession`)**

In the `build(headBytes:)` closure inside `lightweightSession` (line 655), add `var customTitle: String?` alongside the other vars (after `var sampleEvents: [SessionEvent] = []` at line 691).

In the `ingest` closure (line 693), after the timestamp extraction block (~line 724), add:

```swift
// Extract custom title from /rename records (last one wins)
if let t = obj["type"] as? String {
    if t == "custom-title", let ct = obj["customTitle"] as? String, !ct.isEmpty {
        customTitle = ct
    } else if t == "agent-name", let an = obj["agentName"] as? String, !an.isEmpty {
        customTitle = an
    }
}
```

Then pass `customTitle` to both Session constructors in `build()`.

For the temp session at line 744 (used only for title derivation), no change needed — it doesn't use customTitle.

For the final lightweight session at line 763:

```swift
return Session(id: hash(path: url.path),
               source: .claude,
               startTime: tmin ?? mtime,
               endTime: tmax ?? mtime,
               model: effectiveModel,
               filePath: url.path,
               fileSizeBytes: size,
               eventCount: estEvents,
               events: [],
               cwd: cwd,
               repoName: nil,
               lightweightTitle: title,
               isHousekeeping: tempIsHousekeeping || title == "No prompt",
               codexInternalSessionIDHint: sessionID,
               parentSessionID: parentSessionID,
               subagentType: subagentType,
               customTitle: customTitle)
```

- [ ] **Step 3: Build to verify no compile errors**

Run: `xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add AgentSessions/Services/ClaudeSessionParser.swift
git commit -m "feat(parser): extract customTitle from custom-title/agent-name JSONL records"
```

---

### Task 3: Add `custom_title` column to DB and thread through persistence

**Files:**
- Modify: `AgentSessions/Indexing/DB.swift:75-155` (schema + migration)
- Modify: `AgentSessions/Indexing/DB.swift:480-518` (fetchSessionMeta)
- Modify: `AgentSessions/Indexing/DB.swift:1153-1183` (upsertSessionMeta)
- Modify: `AgentSessions/Indexing/DB.swift:1622-1640` (SessionMetaRow)
- Modify: `AgentSessions/Indexing/SessionMetaRepository.swift:1-82`
- Modify: `AgentSessions/Indexing/AnalyticsIndexer.swift:234-252`

- [ ] **Step 1: Add `customTitle` to `SessionMetaRow`**

In `SessionMetaRow` (DB.swift line 1622), add after `subagentType`:

```swift
struct SessionMetaRow {
    let sessionID: String
    let source: String
    let path: String
    let mtime: Int64
    let size: Int64
    let startTS: Int64
    let endTS: Int64
    let model: String?
    let cwd: String?
    let repo: String?
    let title: String?
    let codexInternalSessionID: String?
    let isHousekeeping: Bool
    let messages: Int
    let commands: Int
    let parentSessionID: String?
    let subagentType: String?
    let customTitle: String?
}
```

- [ ] **Step 2: Add column migration in schema setup**

After the `subagent_type` migration block (DB.swift ~line 141), add:

```swift
if !tableHasColumn(db, table: "session_meta", column: "custom_title") {
    do {
        try exec(db, "ALTER TABLE session_meta ADD COLUMN custom_title TEXT;")
    } catch {
        if !isDuplicateColumnError(error) { throw error }
    }
}
```

Also add a schema migration key to trigger reindex so existing sessions get their custom titles extracted. Find the existing migration key pattern (around line 301) and add a new one after the last migration block:

```swift
let customTitleMigrationKey = "custom_title_reindex_v1"
if !migrationApplied(db, key: customTitleMigrationKey) {
    try exec(db, "DELETE FROM files;")
    try exec(db, "DELETE FROM session_meta;")
    try exec(db, "DELETE FROM session_search;")
    try exec(db, "DELETE FROM session_tool_io;")
    try exec(db, "DELETE FROM session_days;")
    try exec(db, "DELETE FROM rollups_daily;")
    try execBind(db, "INSERT OR IGNORE INTO schema_migrations(key) VALUES(?);", customTitleMigrationKey)
}
```

- [ ] **Step 3: Update `fetchSessionMeta` to read `custom_title`**

In `fetchSessionMeta` (DB.swift line 480), add `custom_title` to the SELECT list (after `subagent_type`):

```swift
let sql = """
SELECT session_id, source, path, mtime, size, start_ts, end_ts, model, cwd, repo, title, codex_internal_session_id, is_housekeeping, messages, commands, parent_session_id, subagent_type, custom_title
FROM session_meta
WHERE source = ?
ORDER BY COALESCE(end_ts, mtime) DESC
"""
```

And add the column read to the `SessionMetaRow` construction (index 17, after `subagentType` at index 16):

```swift
subagentType: sqlite3_column_type(stmt, 16) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 16)),
customTitle: sqlite3_column_type(stmt, 17) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 17))
```

- [ ] **Step 4: Update `upsertSessionMeta` to write `custom_title`**

In `upsertSessionMeta` (DB.swift line 1153), add `custom_title` to the INSERT column list, the VALUES placeholders (18th `?`), and the ON CONFLICT SET clause:

```swift
func upsertSessionMeta(_ m: SessionMetaRow) throws {
    let sql = """
    INSERT INTO session_meta(session_id, source, path, mtime, size, start_ts, end_ts, model, cwd, repo, title, codex_internal_session_id, is_housekeeping, messages, commands, parent_session_id, subagent_type, custom_title)
    VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
    ON CONFLICT(session_id) DO UPDATE SET
      source=excluded.source, path=excluded.path, mtime=excluded.mtime, size=excluded.size,
      start_ts=excluded.start_ts, end_ts=excluded.end_ts, model=excluded.model, cwd=excluded.cwd,
      repo=excluded.repo, title=excluded.title, codex_internal_session_id=excluded.codex_internal_session_id,
      is_housekeeping=excluded.is_housekeeping, messages=excluded.messages, commands=excluded.commands,
      parent_session_id=excluded.parent_session_id, subagent_type=excluded.subagent_type,
      custom_title=excluded.custom_title;
    """
    let stmt = try prepare(sql)
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_text(stmt, 1, m.sessionID, -1, SQLITE_TRANSIENT)
    sqlite3_bind_text(stmt, 2, m.source, -1, SQLITE_TRANSIENT)
    sqlite3_bind_text(stmt, 3, m.path, -1, SQLITE_TRANSIENT)
    sqlite3_bind_int64(stmt, 4, m.mtime)
    sqlite3_bind_int64(stmt, 5, m.size)
    sqlite3_bind_int64(stmt, 6, m.startTS)
    sqlite3_bind_int64(stmt, 7, m.endTS)
    if let model = m.model { sqlite3_bind_text(stmt, 8, model, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 8) }
    if let cwd = m.cwd { sqlite3_bind_text(stmt, 9, cwd, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 9) }
    if let repo = m.repo { sqlite3_bind_text(stmt, 10, repo, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 10) }
    if let title = m.title { sqlite3_bind_text(stmt, 11, title, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 11) }
    if let codexInternal = m.codexInternalSessionID { sqlite3_bind_text(stmt, 12, codexInternal, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 12) }
    sqlite3_bind_int64(stmt, 13, m.isHousekeeping ? 1 : 0)
    sqlite3_bind_int64(stmt, 14, Int64(m.messages))
    sqlite3_bind_int64(stmt, 15, Int64(m.commands))
    if let pid = m.parentSessionID { sqlite3_bind_text(stmt, 16, pid, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 16) }
    if let sat = m.subagentType { sqlite3_bind_text(stmt, 17, sat, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 17) }
    if let ct = m.customTitle { sqlite3_bind_text(stmt, 18, ct, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, 18) }
    if sqlite3_step(stmt) != SQLITE_DONE { throw DBError.execFailed("upsert session_meta") }
}
```

- [ ] **Step 5: Update `AnalyticsIndexer` to pass `customTitle`**

In `AnalyticsIndexer.swift` line 234, add `customTitle` to the `SessionMetaRow` construction:

```swift
let meta = SessionMetaRow(
    sessionID: session.id,
    source: source,
    path: session.filePath,
    mtime: mtime,
    size: size,
    startTS: Int64(start.timeIntervalSince1970),
    endTS: Int64(end.timeIntervalSince1970),
    model: session.model,
    cwd: session.cwd,
    repo: session.repoName,
    title: session.title,
    codexInternalSessionID: session.codexInternalSessionID ?? session.codexInternalSessionIDHint,
    isHousekeeping: session.isHousekeeping || (session.title == "No prompt" && (session.source == .codex || session.source == .claude)),
    messages: messages,
    commands: commands,
    parentSessionID: session.parentSessionID,
    subagentType: session.subagentType,
    customTitle: session.customTitle
)
```

- [ ] **Step 6: Update `SessionMetaRepository` to pass `customTitle` through**

In `SessionMetaRepository.swift`, thread `r.customTitle` through all three Session constructor calls. The key change is adding `customTitle: r.customTitle` to each call. The final construction (line 62) becomes:

```swift
out.append(Session(id: enriched.id,
                   source: enriched.source,
                   startTime: enriched.startTime,
                   endTime: enriched.endTime,
                   model: enriched.model,
                   filePath: enriched.filePath,
                   fileSizeBytes: enriched.fileSizeBytes,
                   eventCount: enriched.eventCount,
                   events: enriched.events,
                   cwd: enriched.lightweightCwd,
                   repoName: r.repo,
                   lightweightTitle: enriched.lightweightTitle,
                   lightweightCommands: r.commands,
                   isHousekeeping: r.isHousekeeping || (r.title == "No prompt" && (source == .codex || source == .claude)),
                   codexInternalSessionIDHint: enriched.codexInternalSessionIDHint,
                   parentSessionID: enriched.parentSessionID,
                   subagentType: enriched.subagentType,
                   customTitle: r.customTitle))
```

The intermediate `session` construction (line 25) and `enriched` construction (line 46) also need `customTitle: r.customTitle`.

- [ ] **Step 7: Build to verify no compile errors**

Run: `xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 8: Commit**

```bash
git add AgentSessions/Indexing/DB.swift AgentSessions/Indexing/SessionMetaRepository.swift AgentSessions/Indexing/AnalyticsIndexer.swift
git commit -m "feat(db): add custom_title column and thread through persistence layer"
```

---

### Task 4: Thread `customTitle` through SessionIndexer merge paths

**Files:**
- Modify: `AgentSessions/Services/SessionIndexer.swift` (search for `lightweightTitle` — every Session constructor call that threads lightweight fields needs `customTitle` added)

- [ ] **Step 1: Find all Session constructor calls in SessionIndexer**

Run: `grep -n 'lightweightTitle' AgentSessions/Services/SessionIndexer.swift`

Each hit is a Session constructor that needs `customTitle` added. The pattern is always the same: add `customTitle: session.customTitle` (or `customTitle: current.customTitle ?? session.customTitle` for merge paths) after the `subagentType` parameter.

For merge paths where two sessions are combined (e.g., `current` and `session`), prefer the freshest custom title: `customTitle: session.customTitle ?? current.customTitle`.

- [ ] **Step 2: Update each constructor call**

For each Session constructor call found in Step 1, add `customTitle` parameter. Follow the same merge precedence pattern used for `lightweightTitle`:
- Where it says `lightweightTitle: session.lightweightTitle ?? existing.lightweightTitle`, add `customTitle: session.customTitle ?? existing.customTitle`
- Where it says `lightweightTitle: current.lightweightTitle`, add `customTitle: current.customTitle`

- [ ] **Step 3: Build to verify no compile errors**

Run: `xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add AgentSessions/Services/SessionIndexer.swift
git commit -m "feat(indexer): thread customTitle through session merge paths"
```

---

### Task 5: Verify end-to-end with a real renamed session

- [ ] **Step 1: Build and run the app**

Run: `xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 2: Verify the DB reindex fires**

After launching, the `custom_title_reindex_v1` migration should trigger a full reindex. Check the app's session list for any sessions you've renamed via `/rename` in Claude Code — they should now show the custom name instead of the first user message.

Known test session: session ID `bab08d7e-3c56-4e0b-8f33-1189ffa94163` in project `-Users-alexm-Repository-Codex-History` was renamed to `"session-naming-feature"`. It should display that name.

Other named sessions from `~/.claude/sessions/*.json`:
- `f7456a46-...` → `"calendar-event-links-badges"`
- `871bc779-...` → `"marketing-launch-3-4"`
- `bdb83666-...` → `"agent-version-bump-updates"`

- [ ] **Step 3: Verify un-renamed sessions are unchanged**

Sessions without a `/rename` should display exactly as before (first user message or derived title).

- [ ] **Step 4: Commit all remaining changes (if any fixups needed)**

```bash
git add -A
git commit -m "feat: show Claude session names from /rename command

Closes jazzyalex/agent-sessions#26"
```
