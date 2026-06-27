# Claude Code Archived Sessions: Visibility & Restore — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let Agent Sessions show which Claude Code Desktop sessions are archived, filter to archived-only, and (opt-in) restore an archived session so it returns to Claude Desktop's list.

**Architecture:** A read-only **overlay map** (`cliSessionId -> sidecar record`) built once per index cycle from `~/Library/Application Support/Claude/claude-code-sessions/**/local_*.json`, joined to sessions by the already-persisted `codexInternalSessionIDHint`. The pill and filter consult the overlay (no `Session` field, no DB migration). Restore writes `isArchived:false` + `autoArchiveExempt:true` into the sidecar, gated behind an off-by-default Advanced preference so the app stays read-only by default.

**Tech Stack:** Swift, SwiftUI, XCTest. macOS app. Build/test via `scripts/xcode_test_stable.sh`.

## Global Constraints

- **Read-only by default.** Only the restore feature writes, and only when `PreferencesKey.Advanced.allowClaudeArchiveRestore == true` (default `false`). UC1 (tag + filter) never writes.
- **Never alter transcripts.** Restore touches only the sidecar JSON; it preserves all unknown keys and writes atomically (`Data.write(to:options:.atomic)`).
- **No `Session` schema change / no SQLite migration.** Archive state lives in an overlay keyed by `codexInternalSessionIDHint`.
- **Reuse, don't duplicate.** Extend `ClaudeDesktopSessionTitles` for the scan; do not add a parallel scanner.
- **New Swift files** must be registered with `scripts/xcode_add_file.rb` into the `AgentSessions` target, and into `AgentSessionsLogicTests` when unit-tested. Usage: `ruby scripts/xcode_add_file.rb AgentSessions.xcodeproj <TARGET> <FILE> <GROUP>`.
- **Commits:** Conventional Commits, no Claude co-author, no "Generated with" footer. Trailers `Tool:`/`Model:`/`Why:` allowed. Author = repo owner only.
- **Restore-correct write values:** set `isArchived = false` AND `autoArchiveExempt = true` (mirrors the app's own unarchive; the exempt flag stops the `AutoArchiveEngine` re-archiving).

**Test runner:** `bash scripts/xcode_test_stable.sh` runs the full suite (it forwards extra args after `clean test`). Target a class with: `bash scripts/xcode_test_stable.sh -only-testing:AgentSessionsLogicTests/<ClassName>`.

**Deviation from spec (intentional):** unit tests use temp-directory fixtures (the existing `AgentSessionsLogicTests` convention, e.g. `DroidSessionParserLogicTests`) rather than committed `Resources/Fixtures/` files. Same coverage, no new committed fixtures.

---

## File Structure

- `AgentSessions/ClaudeStatus/ClaudeDesktopSessionTitles.swift` — **modify.** Add `ClaudeDesktopSidecarRecord` + `records(root:fileManager:)`; refactor `map(...)` to derive from records. (Task 1)
- `AgentSessions/Services/ClaudeArchiveRestore.swift` — **create.** Gated, atomic sidecar restore. (Task 2)
- `AgentSessions/Views/Preferences/PreferencesConstants.swift` — **modify.** Add `Advanced.allowClaudeArchiveRestore` and `Unified.showArchivedClaudeDesktopOnly`. (Task 3)
- `AgentSessions/Views/Preferences/PreferencesView+General.swift` — **modify.** Advanced-pane toggle + warning. (Task 3)
- `AgentSessions/Services/FilterEngine.swift` — **modify.** `Filters.archivedClaudeDesktopOnly` + `archivedClaudeSessionIDs`; predicate in `sessionMatches`. (Task 4)
- `AgentSessions/Services/UnifiedSessionIndexer.swift` — **modify.** Overlay state, helpers, rebuild hook, filter wiring. (Task 5, Task 7 state)
- `AgentSessions/Views/UnifiedSessionsView.swift` — **modify.** Tag threading (Task 6), filter toggle UI (Task 7), restore context-menu item (Task 8).
- Tests: `AgentSessionsLogicTests/ClaudeDesktopSidecarReaderTests.swift`, `AgentSessionsLogicTests/ClaudeArchiveRestoreTests.swift`, `AgentSessionsLogicTests/ClaudeArchivedFilterTests.swift` — **create.**

---

## Task 1: Sidecar record reader

**Files:**
- Modify: `AgentSessions/ClaudeStatus/ClaudeDesktopSessionTitles.swift`
- Test: `AgentSessionsLogicTests/ClaudeDesktopSidecarReaderTests.swift` (create)

**Interfaces:**
- Produces: `struct ClaudeDesktopSidecarRecord: Equatable { let cliSessionID: String; let title: String?; let isArchived: Bool; let autoArchiveExempt: Bool; let sidecarPath: String; let modifiedAt: Date }`
- Produces: `ClaudeDesktopSessionTitles.records(root: URL?, fileManager: FileManager) -> [String: ClaudeDesktopSidecarRecord]` (keyed by `cliSessionID`, last-writer-wins by `modifiedAt`)
- Preserves: `ClaudeDesktopSessionTitles.map(root:fileManager:) -> [String: String]` (titles only, unchanged behavior for title-bearing records)

- [ ] **Step 1: Create the failing test**

Create `AgentSessionsLogicTests/ClaudeDesktopSidecarReaderTests.swift`:

```swift
import XCTest

final class ClaudeDesktopSidecarReaderTests: XCTestCase {
    private func makeRoot() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ccsess_\(UUID().uuidString)/ws/group", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ obj: [String: Any], named name: String, in dir: URL) {
        let data = try! JSONSerialization.data(withJSONObject: obj)
        try! data.write(to: dir.appendingPathComponent(name))
    }

    func testRecordsReadsArchiveFlagsAndPath() {
        let dir = makeRoot()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent().deletingLastPathComponent()) }
        write(["cliSessionId": "cli-1", "title": "Hello", "isArchived": true, "autoArchiveExempt": false],
              named: "local_aaa.json", in: dir)
        write(["cliSessionId": "cli-2", "title": "World", "isArchived": false],
              named: "local_bbb.json", in: dir)
        write(["title": "ignored: no cli"], named: "local_ccc.json", in: dir)
        write(["cliSessionId": "cli-9"], named: "not_a_sidecar.json", in: dir)

        let recs = ClaudeDesktopSessionTitles.records(root: dir.deletingLastPathComponent().deletingLastPathComponent())

        XCTAssertEqual(recs["cli-1"]?.isArchived, true)
        XCTAssertEqual(recs["cli-1"]?.autoArchiveExempt, false)
        XCTAssertEqual(recs["cli-1"]?.title, "Hello")
        XCTAssertTrue(recs["cli-1"]?.sidecarPath.hasSuffix("local_aaa.json") ?? false)
        XCTAssertEqual(recs["cli-2"]?.isArchived, false)
        XCTAssertNil(recs["cli-9"]) // non-local_ file ignored
        XCTAssertEqual(recs.count, 2)
    }

    func testMapStillReturnsTitles() {
        let dir = makeRoot()
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent().deletingLastPathComponent()) }
        write(["cliSessionId": "cli-1", "title": "Hello"], named: "local_aaa.json", in: dir)
        let titles = ClaudeDesktopSessionTitles.map(root: dir.deletingLastPathComponent().deletingLastPathComponent())
        XCTAssertEqual(titles["cli-1"], "Hello")
    }
}
```

- [ ] **Step 2: Add the test file to the logic test target**

Run:
```bash
ruby scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessionsLogicTests \
  AgentSessionsLogicTests/ClaudeDesktopSidecarReaderTests.swift AgentSessionsLogicTests
```
Also ensure the source under test is visible to the logic target (it may not be yet):
```bash
ruby scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessionsLogicTests \
  AgentSessions/ClaudeStatus/ClaudeDesktopSessionTitles.swift ClaudeStatus
```
(If the file is already a member, the script is a no-op / harmless.)

- [ ] **Step 3: Run the test, verify it fails**

Run: `bash scripts/xcode_test_stable.sh -only-testing:AgentSessionsLogicTests/ClaudeDesktopSidecarReaderTests`
Expected: FAIL — `records` is not a member of `ClaudeDesktopSessionTitles` (compile error).

- [ ] **Step 4: Implement `records` + `ClaudeDesktopSidecarRecord`, refactor `map`**

In `ClaudeDesktopSessionTitles.swift`, add the struct above `enum ClaudeDesktopSessionTitles` and replace the body so `map` derives from `records`:

```swift
struct ClaudeDesktopSidecarRecord: Equatable {
    let cliSessionID: String
    let title: String?
    let isArchived: Bool
    let autoArchiveExempt: Bool
    let sidecarPath: String
    let modifiedAt: Date
}

enum ClaudeDesktopSessionTitles {
    static func defaultRoot() -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions", isDirectory: true)
    }

    /// Map of CLI transcript session id -> full sidecar record. Last-writer-wins by mtime.
    static func records(root: URL? = nil, fileManager: FileManager = .default) -> [String: ClaudeDesktopSidecarRecord] {
        let rootURL = root ?? defaultRoot()
        guard fileManager.fileExists(atPath: rootURL.path),
              let enumerator = fileManager.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
              ) else {
            return [:]
        }

        var out: [String: ClaudeDesktopSidecarRecord] = [:]
        for case let url as URL in enumerator {
            guard url.lastPathComponent.hasPrefix("local_"),
                  url.pathExtension == "json",
                  let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cli = (obj["cliSessionId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !cli.isEmpty else {
                continue
            }
            let modifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if let existing = out[cli], existing.modifiedAt >= modifiedAt { continue }
            let rawTitle = (obj["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            out[cli] = ClaudeDesktopSidecarRecord(
                cliSessionID: cli,
                title: (rawTitle?.isEmpty == false) ? rawTitle : nil,
                isArchived: (obj["isArchived"] as? Bool) ?? false,
                autoArchiveExempt: (obj["autoArchiveExempt"] as? Bool) ?? false,
                sidecarPath: url.path,
                modifiedAt: modifiedAt
            )
        }
        return out
    }

    /// Map of CLI transcript session id -> Desktop title (trimmed, non-empty).
    static func map(root: URL? = nil, fileManager: FileManager = .default) -> [String: String] {
        var titles: [String: String] = [:]
        for (cli, rec) in records(root: root, fileManager: fileManager) {
            if let t = rec.title, !t.isEmpty { titles[cli] = t }
        }
        return titles
    }
}
```

- [ ] **Step 5: Run the test, verify it passes**

Run: `bash scripts/xcode_test_stable.sh -only-testing:AgentSessionsLogicTests/ClaudeDesktopSidecarReaderTests`
Expected: PASS (2 tests).

- [ ] **Step 6: Commit**

```bash
git add AgentSessions/ClaudeStatus/ClaudeDesktopSessionTitles.swift \
        AgentSessionsLogicTests/ClaudeDesktopSidecarReaderTests.swift AgentSessions.xcodeproj
git commit -m "feat: read Claude sidecar archive records

Tool: Claude Code
Why: foundation for showing/restoring archived Claude sessions"
```

---

## Task 2: Restore service (gated, atomic)

**Files:**
- Create: `AgentSessions/Services/ClaudeArchiveRestore.swift`
- Test: `AgentSessionsLogicTests/ClaudeArchiveRestoreTests.swift` (create)

**Interfaces:**
- Produces: `enum ClaudeArchiveRestore` with:
  - `static let allowWritesDefaultsKey = "AllowClaudeArchiveRestore"`
  - `static var isEnabled: Bool`
  - `enum RestoreError: Error { case disabled, sidecarMissing, malformed }`
  - `static func restore(sidecarPath: String, enabled: Bool, fileManager: FileManager = .default) throws`
  - `static func restore(sidecarPath: String, fileManager: FileManager = .default) throws` (uses `isEnabled`)

- [ ] **Step 1: Create the failing test**

Create `AgentSessionsLogicTests/ClaudeArchiveRestoreTests.swift`:

```swift
import XCTest

final class ClaudeArchiveRestoreTests: XCTestCase {
    private func writeSidecar(_ obj: [String: Any]) -> String {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("local_\(UUID().uuidString).json")
        try! JSONSerialization.data(withJSONObject: obj).write(to: url)
        return url.path
    }

    private func read(_ path: String) -> [String: Any] {
        let data = try! Data(contentsOf: URL(fileURLWithPath: path))
        return (try! JSONSerialization.jsonObject(with: data)) as! [String: Any]
    }

    func testDisabledThrowsAndDoesNotWrite() {
        let path = writeSidecar(["cliSessionId": "c", "isArchived": true, "title": "keep"])
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertThrowsError(try ClaudeArchiveRestore.restore(sidecarPath: path, enabled: false)) { err in
            XCTAssertEqual(err as? ClaudeArchiveRestore.RestoreError, .disabled)
        }
        XCTAssertEqual(read(path)["isArchived"] as? Bool, true) // unchanged
    }

    func testEnabledClearsArchiveAndPreservesKeys() throws {
        let path = writeSidecar([
            "cliSessionId": "c", "isArchived": true, "autoArchiveExempt": false,
            "title": "keep", "sessionSettings": ["a": 1]
        ])
        defer { try? FileManager.default.removeItem(atPath: path) }
        try ClaudeArchiveRestore.restore(sidecarPath: path, enabled: true)
        let out = read(path)
        XCTAssertEqual(out["isArchived"] as? Bool, false)
        XCTAssertEqual(out["autoArchiveExempt"] as? Bool, true)
        XCTAssertEqual(out["title"] as? String, "keep")
        XCTAssertEqual((out["sessionSettings"] as? [String: Any])?["a"] as? Int, 1)
    }

    func testMissingSidecarThrows() {
        XCTAssertThrowsError(try ClaudeArchiveRestore.restore(sidecarPath: "/no/such/local_x.json", enabled: true)) { err in
            XCTAssertEqual(err as? ClaudeArchiveRestore.RestoreError, .sidecarMissing)
        }
    }
}
```

- [ ] **Step 2: Run the test, verify it fails**

Run: `bash scripts/xcode_test_stable.sh -only-testing:AgentSessionsLogicTests/ClaudeArchiveRestoreTests`
Expected: FAIL — `ClaudeArchiveRestore` not found (compile error). (The new files aren't added yet — that's Step 4.)

- [ ] **Step 3: Create the service**

Create `AgentSessions/Services/ClaudeArchiveRestore.swift`:

```swift
import Foundation

/// Restores an archived Claude Code Desktop session by editing its metadata sidecar.
/// This is the ONLY write Agent Sessions performs into Claude's data, and only when the
/// user has explicitly enabled it (off by default) — see `allowWritesDefaultsKey`.
enum ClaudeArchiveRestore {
    /// UserDefaults key gating all writes. Mirrored by `PreferencesKey.Advanced.allowClaudeArchiveRestore`.
    static let allowWritesDefaultsKey = "AllowClaudeArchiveRestore"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: allowWritesDefaultsKey)
    }

    enum RestoreError: Error, Equatable {
        case disabled
        case sidecarMissing
        case malformed
    }

    /// Set `isArchived=false` + `autoArchiveExempt=true` in the sidecar, preserving all other keys.
    static func restore(sidecarPath: String, enabled: Bool, fileManager: FileManager = .default) throws {
        guard enabled else { throw RestoreError.disabled }
        guard fileManager.fileExists(atPath: sidecarPath) else { throw RestoreError.sidecarMissing }
        let url = URL(fileURLWithPath: sidecarPath)
        let data = try Data(contentsOf: url)
        guard var obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RestoreError.malformed
        }
        obj["isArchived"] = false
        obj["autoArchiveExempt"] = true
        let out = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        try out.write(to: url, options: .atomic)
    }

    static func restore(sidecarPath: String, fileManager: FileManager = .default) throws {
        try restore(sidecarPath: sidecarPath, enabled: isEnabled, fileManager: fileManager)
    }
}
```

- [ ] **Step 4: Register both files in Xcode**

Run:
```bash
ruby scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessions \
  AgentSessions/Services/ClaudeArchiveRestore.swift Services
ruby scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessionsLogicTests \
  AgentSessions/Services/ClaudeArchiveRestore.swift Services
ruby scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessionsLogicTests \
  AgentSessionsLogicTests/ClaudeArchiveRestoreTests.swift AgentSessionsLogicTests
```

- [ ] **Step 5: Run the test, verify it passes**

Run: `bash scripts/xcode_test_stable.sh -only-testing:AgentSessionsLogicTests/ClaudeArchiveRestoreTests`
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
git add AgentSessions/Services/ClaudeArchiveRestore.swift \
        AgentSessionsLogicTests/ClaudeArchiveRestoreTests.swift AgentSessions.xcodeproj
git commit -m "feat: add gated atomic Claude archive restore service

Tool: Claude Code
Why: restore writes only when explicitly enabled; preserves all sidecar keys"
```

---

## Task 3: Preference keys + Advanced-pane toggle

**Files:**
- Modify: `AgentSessions/Views/Preferences/PreferencesConstants.swift`
- Modify: `AgentSessions/Views/Preferences/PreferencesView+General.swift`

**Interfaces:**
- Produces: `PreferencesKey.Advanced.allowClaudeArchiveRestore` (== `ClaudeArchiveRestore.allowWritesDefaultsKey`)
- Produces: `PreferencesKey.Unified.showArchivedClaudeDesktopOnly` = `"UnifiedShowArchivedClaudeDesktopOnly"`

- [ ] **Step 1: Add preference keys**

In `PreferencesConstants.swift`, inside `enum Advanced`, add (single source of truth = the service key):
```swift
        static let allowClaudeArchiveRestore = ClaudeArchiveRestore.allowWritesDefaultsKey
```
Inside `enum Unified`, add:
```swift
        static let showArchivedClaudeDesktopOnly = "UnifiedShowArchivedClaudeDesktopOnly"
```

- [ ] **Step 2: Add the Advanced-pane toggle**

In `PreferencesView+General.swift`, in the Advanced section (after the existing "Show Git Context button" Toggle, ~line 296), add:
```swift
            sectionHeader("Claude Archived Sessions")
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Allow restoring archived Claude sessions", isOn: Binding(
                    get: { UserDefaults.standard.bool(forKey: PreferencesKey.Advanced.allowClaudeArchiveRestore) },
                    set: { UserDefaults.standard.set($0, forKey: PreferencesKey.Advanced.allowClaudeArchiveRestore) }
                ))
                .help("Agent Sessions is otherwise read-only. Enabling this lets it modify Claude Desktop's session metadata to un-archive a session. Best done while Claude Desktop is quit, since Claude may overwrite the change. Your transcripts are never altered.")
                Text("Off by default. Agent Sessions only writes to Claude's files when this is enabled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
```

- [ ] **Step 3: Build, verify it compiles and the toggle appears**

Run: `xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .deriveddata-manual build`
Expected: BUILD SUCCEEDED.
Manual: launch the app, open Preferences -> Advanced; confirm "Allow restoring archived Claude sessions" appears, is **off**, and toggling it round-trips after reopening Preferences.

- [ ] **Step 4: Commit**

```bash
git add AgentSessions/Views/Preferences/PreferencesConstants.swift \
        AgentSessions/Views/Preferences/PreferencesView+General.swift
git commit -m "feat: add off-by-default Advanced toggle to allow Claude archive restore

Tool: Claude Code
Why: preserve read-only positioning; restore is opt-in"
```

---

## Task 4: Archived-Claude filter predicate

**Files:**
- Modify: `AgentSessions/Services/FilterEngine.swift`
- Test: `AgentSessionsLogicTests/ClaudeArchivedFilterTests.swift` (create)

**Interfaces:**
- Consumes: `Session.codexInternalSessionIDHint` (existing)
- Produces: `Filters.archivedClaudeDesktopOnly: Bool`, `Filters.archivedClaudeSessionIDs: Set<String>`
- Produces: behavior — when `archivedClaudeDesktopOnly` is on, a `.claude` session is hidden unless its `codexInternalSessionIDHint` is in `archivedClaudeSessionIDs`; non-`.claude` sessions are unaffected.

- [ ] **Step 1: Create the failing test**

Create `AgentSessionsLogicTests/ClaudeArchivedFilterTests.swift`:

```swift
import XCTest

final class ClaudeArchivedFilterTests: XCTestCase {
    private func session(_ id: String, source: SessionSource, hint: String?) -> Session {
        Session(id: id, source: source, startTime: nil, endTime: nil, model: nil,
                filePath: "/tmp/\(id).jsonl", eventCount: 0, events: [],
                codexInternalSessionIDHint: hint)
    }

    func testArchivedClaudeOnlyHidesNonArchivedClaudeButKeepsOthers() {
        var f = Filters()
        f.archivedClaudeDesktopOnly = true
        f.archivedClaudeSessionIDs = ["cli-arch"]

        let archived = session("a", source: .claude, hint: "cli-arch")
        let normal = session("b", source: .claude, hint: "cli-norm")
        let codex = session("c", source: .codex, hint: nil)

        XCTAssertTrue(FilterEngine.sessionMatches(archived, filters: f))
        XCTAssertFalse(FilterEngine.sessionMatches(normal, filters: f))
        XCTAssertTrue(FilterEngine.sessionMatches(codex, filters: f))
    }

    func testOffByDefaultShowsAllClaude() {
        let f = Filters()
        let normal = session("b", source: .claude, hint: "cli-norm")
        XCTAssertTrue(FilterEngine.sessionMatches(normal, filters: f))
    }
}
```

- [ ] **Step 2: Add the test to the logic target**

Run:
```bash
ruby scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessionsLogicTests \
  AgentSessionsLogicTests/ClaudeArchivedFilterTests.swift AgentSessionsLogicTests
```

- [ ] **Step 3: Run the test, verify it fails**

Run: `bash scripts/xcode_test_stable.sh -only-testing:AgentSessionsLogicTests/ClaudeArchivedFilterTests`
Expected: FAIL — `archivedClaudeDesktopOnly` is not a member of `Filters` (compile error).

- [ ] **Step 4: Add fields + predicate**

In `FilterEngine.swift`, in `struct Filters`, after `var archivedCodexDesktopOnly: Bool = false`:
```swift
    var archivedClaudeDesktopOnly: Bool = false
    var archivedClaudeSessionIDs: Set<String> = []
```
In `sessionMatches`, immediately after the existing Codex archive line (`if !sideChatsOnly, filters.archivedCodexDesktopOnly, ...`):
```swift
        if !sideChatsOnly, filters.archivedClaudeDesktopOnly, session.source == .claude {
            let isArchived = session.codexInternalSessionIDHint
                .map { filters.archivedClaudeSessionIDs.contains($0) } ?? false
            if !isArchived { return false }
        }
```

- [ ] **Step 5: Run the test, verify it passes**

Run: `bash scripts/xcode_test_stable.sh -only-testing:AgentSessionsLogicTests/ClaudeArchivedFilterTests`
Expected: PASS (2 tests).

- [ ] **Step 6: Commit**

```bash
git add AgentSessions/Services/FilterEngine.swift \
        AgentSessionsLogicTests/ClaudeArchivedFilterTests.swift AgentSessions.xcodeproj
git commit -m "feat: add archived-Claude-only filter predicate

Tool: Claude Code
Why: narrow to archived Claude sessions; other agents stay visible"
```

---

## Task 5: Overlay state, helpers, and filter wiring on UnifiedSessionIndexer

**Files:**
- Modify: `AgentSessions/Services/UnifiedSessionIndexer.swift`

**Interfaces:**
- Consumes: `ClaudeDesktopSessionTitles.records(...)` (Task 1), `Filters.archivedClaudeDesktopOnly`/`archivedClaudeSessionIDs` (Task 4), `PreferencesKey.Unified.showArchivedClaudeDesktopOnly` (Task 3)
- Produces (for views):
  - `@Published var showArchivedClaudeDesktopOnly: Bool`
  - `@Published private(set) var claudeArchive: [String: ClaudeDesktopSidecarRecord]`
  - `func isArchivedClaudeDesktop(_ session: Session) -> Bool`
  - `func claudeArchiveSidecarPath(for session: Session) -> String?`
  - `var archivedClaudeSessionIDs: Set<String>`
  - `func rebuildClaudeArchiveOverlay()`

- [ ] **Step 1: Add published state + helpers**

In `UnifiedSessionIndexer.swift`, next to `showArchivedCodexDesktopOnly` (~line 492), add:
```swift
    @Published var showArchivedClaudeDesktopOnly: Bool = UserDefaults.standard.bool(forKey: PreferencesKey.Unified.showArchivedClaudeDesktopOnly) {
        didSet {
            UserDefaults.standard.set(showArchivedClaudeDesktopOnly, forKey: PreferencesKey.Unified.showArchivedClaudeDesktopOnly)
        }
    }

    /// Read-only overlay of Claude Desktop sidecar records, keyed by cliSessionId
    /// (== a session's codexInternalSessionIDHint for Code-tab transcripts).
    @Published private(set) var claudeArchive: [String: ClaudeDesktopSidecarRecord] = [:]

    func isArchivedClaudeDesktop(_ session: Session) -> Bool {
        guard session.source == .claude, let key = session.codexInternalSessionIDHint else { return false }
        return claudeArchive[key]?.isArchived == true
    }

    func claudeArchiveSidecarPath(for session: Session) -> String? {
        guard session.source == .claude, let key = session.codexInternalSessionIDHint else { return nil }
        return claudeArchive[key]?.sidecarPath
    }

    var archivedClaudeSessionIDs: Set<String> {
        Set(claudeArchive.compactMap { $0.value.isArchived ? $0.key : nil })
    }

    func rebuildClaudeArchiveOverlay() {
        let records = ClaudeDesktopSessionTitles.records()
        if records != claudeArchive { claudeArchive = records }
    }
```

- [ ] **Step 2: Rebuild the overlay when sessions reload + at launch**

After the assignment `self.allSessions = result.sessions` (~line 755), add:
```swift
                    self.rebuildClaudeArchiveOverlay()
```
In `init(codexIndexer:...)` (~line 654), after the stored properties are set up, add a one-time initial build:
```swift
        rebuildClaudeArchiveOverlay()
```
(Place it at the end of `init`, after other setup. It performs a cheap directory scan.)

- [ ] **Step 3: Thread the Claude filter into both Filters construction sites**

At the SearchCoordinator-driven site (~line 980, where `archivedCodexDesktopOnly:` is passed), add the two arguments to that `Filters(...)`:
```swift
                                      archivedClaudeDesktopOnly: self.showArchivedClaudeDesktopOnly,
                                      archivedClaudeSessionIDs: self.archivedClaudeSessionIDs,
```
At the `applyFiltersAndSort` site (~line 2383, the other `Filters(...)`), add:
```swift
                              archivedClaudeDesktopOnly: showArchivedClaudeDesktopOnly,
                              archivedClaudeSessionIDs: archivedClaudeSessionIDs,
```

- [ ] **Step 4: Restart search when the toggle flips**

Find where `showArchivedCodexDesktopOnly` triggers a re-filter (an `onChange`/Combine sink, e.g. `UnifiedSessionsView.swift:537` `onChange(of: unified.showArchivedCodexDesktopOnly)`). In Task 7 we add the matching `onChange(of: unified.showArchivedClaudeDesktopOnly)`. For now, ensure the published var exists so the view can bind it. No code here beyond Steps 1-3.

- [ ] **Step 5: Build**

Run: `xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .deriveddata-manual build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add AgentSessions/Services/UnifiedSessionIndexer.swift
git commit -m "feat: build Claude archive overlay and wire archived-Claude filter

Tool: Claude Code
Why: overlay (no Session field/migration) feeds tag, filter, and restore"
```

---

## Task 6: Archived tag (pill)

**Files:**
- Modify: `AgentSessions/Views/UnifiedSessionsView.swift`

**Interfaces:**
- Consumes: `unified.isArchivedClaudeDesktop(session)` (Task 5)
- Modifies: `surfacePills(for:isClaudeArchived:)` and `claudeDesktopSurfacePill(for:isArchived:)`

- [ ] **Step 1: Thread the flag through the pill builder**

In `UnifiedSessionsView.swift`, change the signature (~line 2401) and the Claude branch:
```swift
    static func surfacePills(for session: Session, isClaudeArchived: Bool = false) -> [CodexSurfacePill] {
        if session.isSideChat {
            return [.standard(label: "desk", accessibilityLabel: "Desktop")]
        }
        if let claudeDesktopPill = claudeDesktopSurfacePill(for: session, isArchived: isClaudeArchived) {
            return [claudeDesktopPill]
        }
        // ...unchanged...
```
And update `claudeDesktopSurfacePill` (~line 2434):
```swift
    private static func claudeDesktopSurfacePill(for session: Session, isArchived: Bool) -> CodexSurfacePill? {
        guard session.source == .claude else { return nil }
        let originator = session.originator?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let originSource = session.originSource?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if originator == "claude desktop" || originSource == "local-agent-mode" || isClaudeDesktopLocalAgentPath(session.filePath) {
            return .desktop(isArchived: isArchived)
        }
        return nil
    }
```

- [ ] **Step 2: Pass the overlay-derived flag at the call site**

At the caller (~line 2351), change:
```swift
        let surfacePills = Self.surfacePills(for: session, isClaudeArchived: unified.isArchivedClaudeDesktop(session))
```
(`unified` is the `UnifiedSessionIndexer` already used throughout this view.)

- [ ] **Step 3: Build + manual verify**

Run: `xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .deriveddata-manual build`
Expected: BUILD SUCCEEDED.
Manual: launch the app. A Claude Desktop session known to be archived (e.g. `cliSessionId f1d39390-...`, sidecar `isArchived:true`) now shows the **archived** desktop pill (italic + archivebox accent) instead of the plain `desk` pill. Non-archived Claude Desktop sessions still show plain `desk`.

- [ ] **Step 4: Commit**

```bash
git add AgentSessions/Views/UnifiedSessionsView.swift
git commit -m "feat: tag archived Claude Desktop sessions with the archived pill

Tool: Claude Code
Why: visibility parity with Codex archived sessions"
```

---

## Task 7: Archived-only filter toggle (UI)

**Files:**
- Modify: `AgentSessions/Views/UnifiedSessionsView.swift`

**Interfaces:**
- Consumes: `unified.showArchivedClaudeDesktopOnly` (Task 5), the existing `restartSearchForActiveQuery()` re-filter hook
- Produces: a toggle control bound to `unified.showArchivedClaudeDesktopOnly`, mirroring the Codex `ArchivedCodexDesktopIconToggle` (~line 3176)

- [ ] **Step 1: Add a Claude archive icon toggle view**

In `UnifiedSessionsView.swift`, directly below the existing `ArchivedCodexDesktopIconToggle` (~line 3176-3208), add this sibling component (same capsule styling; auto-enables Claude when turned on, matching the Codex toggle's `toggle()`):
```swift
private struct ArchivedClaudeDesktopIconToggle: View {
    @Binding var isOn: Bool
    @Binding var includeClaude: Bool

    var body: some View {
        Button(action: toggle) {
            Image(systemName: isOn ? "archivebox.fill" : "archivebox")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isOn ? UnifiedSessionsStyle.selectionAccent : .secondary)
                .frame(minWidth: 14)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(
                    Capsule(style: .continuous)
                        .fill(UnifiedSessionsStyle.agentPillFill)
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(isOn ? UnifiedSessionsStyle.selectionAccent.opacity(0.55) : UnifiedSessionsStyle.agentPillStroke, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Narrow Claude results to archived Desktop sessions; other enabled agents remain visible.")
        .accessibilityLabel(Text("Narrow Claude to archived Desktop sessions"))
        .accessibilityValue(Text(isOn ? "On" : "Off"))
    }

    private func toggle() {
        let nextValue = !isOn
        if nextValue, !includeClaude { includeClaude = true }
        isOn = nextValue
    }
}
```

- [ ] **Step 2: Render the toggle inside the Claude agent control block**

In the `if claudeAgentEnabled {` block (~line 1472), after the existing Claude `AgentTabToggle`, add:
```swift
                if claudeAgentEnabled {
                    AgentTabToggle(title: "Claude", color: Color.agentClaude, isMonochrome: stripMonochrome, isOn: $unified.includeClaude)
                        .help("Show or hide Claude sessions in the list (⌘2)")
                        .keyboardShortcut("2", modifiers: .command)
                    ArchivedClaudeDesktopIconToggle(
                        isOn: $unified.showArchivedClaudeDesktopOnly,
                        includeClaude: $unified.includeClaude
                    )
                }
```

- [ ] **Step 3: Re-run the search when the Claude toggle flips**

Next to the existing `.onChange(of: unified.showArchivedCodexDesktopOnly) { _, _ in restartSearchForActiveQuery() }` (~line 537), add:
```swift
            .onChange(of: unified.showArchivedClaudeDesktopOnly) { _, _ in restartSearchForActiveQuery() }
```

- [ ] **Step 4: Build + manual verify**

Run: `xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .deriveddata-manual build`
Expected: BUILD SUCCEEDED.
Manual: launch the app, toggle the Claude archivebox on -> Claude list narrows to archived Claude sessions; other agents remain visible; toggling off restores the full list. State persists across relaunch.

- [ ] **Step 5: Commit**

```bash
git add AgentSessions/Views/UnifiedSessionsView.swift
git commit -m "feat: add archived-only filter toggle for Claude sessions

Tool: Claude Code
Why: give the archived list Claude Desktop omits"
```

---

## Task 8: Restore action (UI, gated)

**Single entry point:** the session-list right-click context menu. (A transcript-detail-header button
was considered but dropped: `TranscriptPlainView` has no `UnifiedSessionIndexer` reference, so it
can't read the overlay/optimistic state without uncertain environment plumbing. The context menu
fully delivers per-session restore; the header button can be a later follow-up if wanted.)

**Files:**
- Modify: `AgentSessions/Views/UnifiedSessionsView.swift` (context menu, confirm dialog, restore handler)
- Modify: `AgentSessions/Services/UnifiedSessionIndexer.swift` (optimistic mutator)

**Interfaces:**
- Consumes: `ClaudeArchiveRestore.restore(sidecarPath:)` + `.isEnabled` (Task 2), `unified.isArchivedClaudeDesktop`, `unified.claudeArchiveSidecarPath`, `unified.claudeArchive` (Task 5), `PreferencesKey.Advanced.allowClaudeArchiveRestore` (Task 3)

- [ ] **Step 1: Add a restore handler + confirm state on the view**

In `UnifiedSessionsView.swift`, add state near the other `@State` of the sessions view:
```swift
    @State private var restoreCandidate: Session? = nil
```
And a handler method on the view:
```swift
    private func restoreFromArchive(_ session: Session) {
        guard let path = unified.claudeArchiveSidecarPath(for: session) else { return }
        do {
            try ClaudeArchiveRestore.restore(sidecarPath: path) // reads the gate via isEnabled
            // Optimistic overlay mutation: clear the archived flag in place.
            if let key = session.codexInternalSessionIDHint, var rec = unified.claudeArchive[key] {
                rec = ClaudeDesktopSidecarRecord(cliSessionID: rec.cliSessionID, title: rec.title,
                                                 isArchived: false, autoArchiveExempt: true,
                                                 sidecarPath: rec.sidecarPath, modifiedAt: rec.modifiedAt)
                unified.applyOptimisticClaudeArchive(rec, for: key)
            }
        } catch {
            NSLog("Claude archive restore failed: \(error)")
        }
    }
```
Because `claudeArchive` is `private(set)`, add a tiny mutator to `UnifiedSessionIndexer.swift` (Task 5 file):
```swift
    func applyOptimisticClaudeArchive(_ record: ClaudeDesktopSidecarRecord, for key: String) {
        claudeArchive[key] = record
    }
```

- [ ] **Step 2: Add the gated context-menu item**

In the single-selection context menu block (`UnifiedSessionsView.swift:938`, the `if ids.count == 1 ...` branch), add for archived Claude sessions:
```swift
                if unified.isArchivedClaudeDesktop(s) {
                    let canRestore = UserDefaults.standard.bool(forKey: PreferencesKey.Advanced.allowClaudeArchiveRestore)
                    Button("Restore from Archive") { restoreCandidate = s }
                        .disabled(!canRestore)
                        .help(canRestore
                              ? "Set this Claude session back to active in Claude Desktop"
                              : "Enable 'Allow restoring archived Claude sessions' in Preferences -> Advanced")
                    Divider()
                }
```

- [ ] **Step 3: Add the confirm dialog**

Attach to the table/container in `UnifiedSessionsView` (near other `.confirmationDialog`/`.alert` modifiers):
```swift
        .confirmationDialog(
            "Restore this session in Claude Desktop?",
            isPresented: Binding(get: { restoreCandidate != nil }, set: { if !$0 { restoreCandidate = nil } }),
            presenting: restoreCandidate
        ) { session in
            Button("Restore") { restoreFromArchive(session); restoreCandidate = nil }
            Button("Cancel", role: .cancel) { restoreCandidate = nil }
        } message: { _ in
            Text("If the session is open in Claude it may overwrite this change immediately; otherwise quit and reopen Claude to see it back in the list. Your transcript is not modified.")
        }
```

- [ ] **Step 4: Build + manual verify (both gate states)**

Run: `xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .deriveddata-manual build`
Expected: BUILD SUCCEEDED.
Manual, gate OFF (default): right-click an archived Claude session -> "Restore from Archive" is present but **disabled** with the "enable in Preferences" help. No file is written.
Manual, gate ON (Preferences -> Advanced -> enable): **quit Claude Desktop first.** Restore the session -> confirm dialog -> on Restore, the pill clears immediately (optimistic), and the sidecar JSON now has `isArchived:false`, `autoArchiveExempt:true` (verify with a JSON read). Reopen Claude Desktop -> session is back in its list.

- [ ] **Step 5: Commit**

```bash
git add AgentSessions/Views/UnifiedSessionsView.swift \
        AgentSessions/Services/UnifiedSessionIndexer.swift
git commit -m "feat: add gated Restore from Archive action for Claude sessions

Tool: Claude Code
Why: restore archived sessions Claude Desktop offers no UI to recover"
```

---

## Final verification

- [ ] **Run the full logic test suite**

Run: `bash scripts/xcode_test_stable.sh -only-testing:AgentSessionsLogicTests`
Expected: PASS, including the three new classes (`ClaudeDesktopSidecarReaderTests`, `ClaudeArchiveRestoreTests`, `ClaudeArchivedFilterTests`).

- [ ] **Run the full suite once**

Run: `bash scripts/xcode_test_stable.sh`
Expected: PASS (no regressions in existing tests).

- [ ] **Read-only sanity check**

With the Advanced toggle OFF (default), exercise UC1 (tag + filter) and confirm no writes occur to `~/Library/Application Support/Claude/` (e.g. record sidecar mtimes before/after). Agent Sessions must remain strictly read-only by default.
