# Claude Workflow-Subagent Browser Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Agent Sessions correctly recognize Claude Code "Workflow"-spawned subagent transcripts (which live in a *nested* `subagents/workflows/wf_<id>/` layout) so they nest under their parent session instead of polluting the list as orphan top-level rows.

**Architecture:** The root cause is a single over-specific path check in `ClaudeSessionParser.detectSubagentInfo(from:)` that only recognizes the *flat* subagent layout (`<parentUUID>/subagents/agent-*.jsonl`). We generalize it to find the last `subagents` path component — which works for both flat and nested layouts — exactly as the runway scanner already does. Fixing detection makes workflow agents carry a non-nil `parentSessionID`, which transitively fixes the hierarchy builder's parent-resolution (no production change needed there) because workflow agents stop slipping past its "don't register hints from subagents" guard. Secondary fixes stop the discovery walker from ingesting `journal.jsonl`/sidecar files and align the resume ID helpers with the same nested layout. Two optional UI touches add a concise "workflow" badge and suppress the redundant Resume action on workflow rows. The layout, sidecar set, and field values below were validated against a real workflow run in this repo (parent `48a26fd3-…`, 2026-06-26, 8 workflow agents) — see Global Constraints.

**Tech Stack:** Swift 5 / SwiftUI, macOS app target `AgentSessions`, XCTest target `AgentSessionsTests` (uses `@testable import AgentSessions`), Xcode project `AgentSessions.xcodeproj`, `xcodebuild` CLI.

## Global Constraints

- **Build:** `xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug build`
- **Test (stable, isolated DerivedData to avoid code-sign flakes):**
  `xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "$PWD/.deriveddata-tests" -parallel-testing-enabled NO clean test`
  (the wrapper `./scripts/xcode_test_stable.sh` runs the equivalent). Add `-only-testing:AgentSessionsTests/ClaudeWorkflowSubagentTests` to scope to this plan's tests.
- **New Swift files must be registered in the Xcode project** via `LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 ./scripts/xcode_add_file.rb AgentSessions.xcodeproj <TARGET> <FILE> <GROUP>` (the UTF-8 locale exports avoid an "invalid byte sequence in US-ASCII" error from the `xcodeproj` gem). A correct single registration produces **4** raw occurrences of the filename in `project.pbxproj` (one `PBXBuildFile` def, one `PBXFileReference` def, one group-child entry, one Sources-phase entry) — not 2. Verify there is no duplicate with: `grep -c "isa = PBXFileReference.*<File>.swift" project.pbxproj` and `grep -c "isa = PBXBuildFile.*<File>.swift" project.pbxproj`, each of which must print exactly `1`.
- **Preserve existing flat-subagent behavior.** The flat layout `<parentUUID>/subagents/agent-*.jsonl` must keep resolving exactly as it does today. Every detection/helper change ships with a flat-layout regression test.
- **Do not rely on `session.events`.** Sessions are usually parsed in *lightweight* mode where `events == []`. Path-based helpers (`detectSubagentInfo`, `deriveSessionID`, `projectRoot`) must work with empty events.
- **Workflow agent shape — validated against a real run** (`<projectHash> = -Users-alexm-Repository-Codex-History`, `<parentUUID> = 48a26fd3-3a7f-4b7a-8bb7-8b836427f892`, run of 2026-06-26):

  ```
  ~/.claude/projects/<projectHash>/
  ├── <parentUUID>.jsonl                       ← parent transcript (root session; the nesting target)
  └── <parentUUID>/
      ├── subagents/workflows/wf_<id>/
      │   ├── agent-<hex17>.jsonl              ← workflow subagent transcripts (8 in this run)
      │   ├── agent-<hex17>.meta.json          ← {"agentType":"workflow-subagent","spawnDepth":1}
      │   └── journal.jsonl                    ← {"type":"started"|"result",...,"agentId":...} run log
      ├── workflows/                           ← SIBLING of subagents/, not under it
      │   ├── scripts/<name>-wf_<id>.js        ← workflow script
      │   └── wf_<id>.json                     ← workflow definition
      └── tool-results/<id>.txt                ← tool output spill files
  ```

  Verified facts: the agent transcript internally carries `sessionId` = the **parent** UUID, `isSidechain: true`, `parentUuid: null`, and a real `cwd`/`gitBranch`. The `<hex17>` agent id (e.g. `a0a3e832029606953`) is **not** a UUID, so it never trips `SubagentHierarchyBuilder`'s `fileName.count == 36` filename-UUID path. **Only** `agent-*.jsonl` and the parent `<parentUUID>.jsonl` are real transcripts; everything else (`journal.jsonl`, `*.meta.json`, `*.js`, `*.json`, `*.txt`) must be kept out of discovery — `journal.jsonl` by name, the rest by extension.
- **Commits:** Conventional Commits with body trailers `Tool: Claude`, `Model: claude-opus-4-8`, `Why: <1 line>`. **No** "Generated with Claude Code" footer and **no** `Co-Authored-By` trailer. Only run `git commit` when executing this plan under explicit user authorization; the per-task commit steps below are the unit-of-work boundaries for that authorized run.

---

## File Structure

| File | Responsibility | Change |
| --- | --- | --- |
| `AgentSessions/Services/ClaudeSessionParser.swift` | Parse Claude transcripts; detect subagent parent/type from path | **Modify** `detectSubagentInfo(from:)` (currently `:1172-1189`) to key off the last `subagents` path component |
| `AgentSessions/Services/SubagentHierarchyBuilder.swift` | Flatten sessions into parent→child rows | **No change for the core fix** (regression tests only — the detection fix makes workflow agents carry non-nil `parentSessionID`, so the existing guard at `:55` already excludes them from hint registration). **Optional (Task 6):** add a derived `hasWorkflowChildren` flag to `SubagentRowMeta` |
| `AgentSessions/Services/SessionDiscovery.swift` | Enumerate Claude transcript files | **Modify** `collectSessionFiles(in:fileCap:)` (`:599-623`) to skip `journal.jsonl`/non-transcript sidecars before they consume the visit cap; relax visibility to `internal` for testing |
| `AgentSessions/ClaudeResume/ClaudeSessionIDHelper.swift` | Derive resume session ID + project root from a session | **Modify** `deriveSessionID(from:)` (`:17-22`) and `projectRoot(for:settings:)` (`:45-48`) to handle the nested layout |
| `AgentSessions/Model/Session.swift` | Session model | **Modify** (optional, Task 5) add `isClaudeWorkflowSubagent` computed property |
| `AgentSessions/Views/UnifiedSessionsView.swift` | Session list rows + resume gating | **Modify** (optional, Tasks 4–6) concise child badge label + resume suppression + subtle parent workflow marker |
| `AgentSessionsTests/ClaudeWorkflowSubagentTests.swift` | All new tests for this plan | **Create** + register in `AgentSessionsTests` target |

---

## Task 1: Generalize `detectSubagentInfo` for the nested workflow layout (MUST-FIX)

This is the core fix. It makes workflow agents resolve a non-nil `parentSessionID`, which (a) stops them rendering as orphan top-level rows and (b) transitively repairs `SubagentHierarchyBuilder` parent resolution by excluding them from hint registration.

**Files:**
- Create: `AgentSessionsTests/ClaudeWorkflowSubagentTests.swift`
- Modify: `AgentSessions/Services/ClaudeSessionParser.swift:1172-1189`

**Interfaces:**
- Consumes: `ClaudeSessionIDHelper.looksLikeUUID(_:) -> Bool` (existing, internal).
- Produces:
  - `ClaudeSessionParser.detectSubagentInfo(from url: URL) -> (parentSessionID: String?, subagentType: String?)` — unchanged signature, generalized behavior.
  - Test helper in the new file: `private func makeUniqueTempDir() throws -> URL` (creates a fresh `FileManager.default.temporaryDirectory/UUID()` and registers teardown). Re-declared verbatim wherever later tasks reuse it.

- [ ] **Step 1: Create the test file with the fixture helper and the first failing test**

Create `AgentSessionsTests/ClaudeWorkflowSubagentTests.swift`:

```swift
import XCTest
@testable import AgentSessions

final class ClaudeWorkflowSubagentTests: XCTestCase {

    // MARK: - Fixture helpers

    private var createdDirs: [URL] = []

    override func tearDownWithError() throws {
        for dir in createdDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        createdDirs.removeAll()
        try super.tearDownWithError()
    }

    /// Returns a fresh, unique temp directory that is removed in tearDown.
    private func makeUniqueTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeWorkflowSubagentTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        createdDirs.append(dir)
        return dir
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try text.data(using: .utf8)!.write(to: url)
    }

    private let parentUUID = "11111111-2222-4333-8444-555555555555"

    // MARK: - detectSubagentInfo: nested workflow layout

    func test_detectSubagentInfo_nestedWorkflowLayout_returnsParentAndAgentType() throws {
        let root = try makeUniqueTempDir()
        // .../<projectHash>/<parentUUID>/subagents/workflows/wf_abc/agent-<id>.jsonl
        let agentDir = root
            .appendingPathComponent("projecthash", isDirectory: true)
            .appendingPathComponent(parentUUID, isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
            .appendingPathComponent("workflows", isDirectory: true)
            .appendingPathComponent("wf_abc", isDirectory: true)
        let agentFile = agentDir.appendingPathComponent("agent-deadbeef.jsonl")
        try write("{}\n", to: agentFile)
        try write(#"{"agentType":"workflow-subagent","spawnDepth":1}"#,
                  to: agentDir.appendingPathComponent("agent-deadbeef.meta.json"))

        let (parent, type) = ClaudeSessionParser.detectSubagentInfo(from: agentFile)

        XCTAssertEqual(parent, parentUUID)
        XCTAssertEqual(type, "workflow-subagent")
    }
}
```

- [ ] **Step 2: Register the new test file in the Xcode project**

Run (UTF-8 locale exports prevent an `xcodeproj`-gem encoding crash):
```bash
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 ./scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessionsTests \
  AgentSessionsTests/ClaudeWorkflowSubagentTests.swift \
  AgentSessionsTests
```
Expected: `✓ Added AgentSessionsTests/ClaudeWorkflowSubagentTests.swift to AgentSessionsTests`
Then verify exactly one of each reference type (a correct single registration shows 4 total raw occurrences — build-file def, file-ref def, group child, Sources-phase entry):
```bash
grep -c "isa = PBXFileReference.*ClaudeWorkflowSubagentTests.swift" AgentSessions.xcodeproj/project.pbxproj   # expect 1
grep -c "isa = PBXBuildFile.*ClaudeWorkflowSubagentTests.swift" AgentSessions.xcodeproj/project.pbxproj       # expect 1
```
If either prints more than `1`, open the pbxproj and remove the duplicate references before continuing.

- [ ] **Step 3: Run the test to verify it fails**

Run:
```bash
xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$PWD/.deriveddata-tests" \
  -parallel-testing-enabled NO \
  -only-testing:AgentSessionsTests/ClaudeWorkflowSubagentTests/test_detectSubagentInfo_nestedWorkflowLayout_returnsParentAndAgentType \
  test
```
Expected: **FAIL** — `XCTAssertEqual("nil", "11111111-2222-4333-8444-555555555555")` because the current guard `parentDir.lastPathComponent == "subagents"` sees `wf_abc` and returns `(nil, nil)`.

- [ ] **Step 4: Implement the generalized detection**

In `AgentSessions/Services/ClaudeSessionParser.swift`, replace the entire `detectSubagentInfo(from:)` function (currently `:1169-1189`) with:

```swift
    /// Detect a Claude subagent session from its file-path layout and read its
    /// agent type from the adjacent meta sidecar.
    ///
    /// Two layouts exist:
    ///   Flat (Task-tool subagents):
    ///     .../<parentUUID>/subagents/agent-<id>.jsonl
    ///   Nested (Workflow-spawned subagents):
    ///     .../<parentUUID>/subagents/workflows/wf_<id>/agent-<id>.jsonl
    ///
    /// In BOTH layouts the parent session UUID is the path component immediately
    /// before the LAST `subagents` component, so we key off that rather than the
    /// transcript's direct parent directory (which is `wf_<id>` for workflows).
    /// This matches ClaudeRunwayRecentSessionScanner's `pathComponents.contains("subagents")`.
    /// The agent-type sidecar (`<basename>.meta.json`) always lives next to the
    /// transcript, so it is read from the transcript's own directory.
    static func detectSubagentInfo(from url: URL) -> (parentSessionID: String?, subagentType: String?) {
        let components = url.pathComponents
        guard let subagentsIndex = components.lastIndex(of: "subagents"),
              subagentsIndex > 0 else {
            return (nil, nil)
        }
        let parentSessionName = components[subagentsIndex - 1]
        guard ClaudeSessionIDHelper.looksLikeUUID(parentSessionName) else { return (nil, nil) }

        // agentType lives in the sidecar adjacent to the transcript, regardless of
        // flat vs nested layout (e.g. {"agentType":"workflow-subagent","spawnDepth":1}).
        let agentDir = url.deletingLastPathComponent()
        let baseName = url.deletingPathExtension().lastPathComponent
        let metaFile = agentDir.appendingPathComponent("\(baseName).meta.json")
        var agentType: String?
        if let metaData = try? Data(contentsOf: metaFile),
           let metaObj = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any] {
            agentType = metaObj["agentType"] as? String
        }

        return (parentSessionName, agentType)
    }
```

- [ ] **Step 5: Run the test to verify it passes**

Run the same command as Step 3. Expected: **PASS**.

- [ ] **Step 6: Add flat-layout regression + safety tests**

Append to `ClaudeWorkflowSubagentTests`:

```swift
    func test_detectSubagentInfo_flatLayout_stillResolvesParentAndAgentType() throws {
        let root = try makeUniqueTempDir()
        // .../<projectHash>/<parentUUID>/subagents/agent-<id>.jsonl
        let subagentsDir = root
            .appendingPathComponent("projecthash", isDirectory: true)
            .appendingPathComponent(parentUUID, isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
        let agentFile = subagentsDir.appendingPathComponent("agent-cafef00d.jsonl")
        try write("{}\n", to: agentFile)
        try write(#"{"agentType":"Explore"}"#,
                  to: subagentsDir.appendingPathComponent("agent-cafef00d.meta.json"))

        let (parent, type) = ClaudeSessionParser.detectSubagentInfo(from: agentFile)

        XCTAssertEqual(parent, parentUUID)
        XCTAssertEqual(type, "Explore")
    }

    func test_detectSubagentInfo_nonUUIDParent_returnsNil() throws {
        let root = try makeUniqueTempDir()
        // A user folder literally named "subagents" must not be mistaken for a parent.
        let agentFile = root
            .appendingPathComponent("not-a-uuid", isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
            .appendingPathComponent("agent-x.jsonl")
        try write("{}\n", to: agentFile)

        let (parent, type) = ClaudeSessionParser.detectSubagentInfo(from: agentFile)

        XCTAssertNil(parent)
        XCTAssertNil(type)
    }

    func test_detectSubagentInfo_topLevelSession_returnsNil() throws {
        let root = try makeUniqueTempDir()
        let topLevel = root
            .appendingPathComponent("projecthash", isDirectory: true)
            .appendingPathComponent("\(parentUUID).jsonl")
        try write("{}\n", to: topLevel)

        let (parent, type) = ClaudeSessionParser.detectSubagentInfo(from: topLevel)

        XCTAssertNil(parent)
        XCTAssertNil(type)
    }
```

- [ ] **Step 7: Add hierarchy regression tests proving end-to-end nesting + no hint collision**

These build `Session` values directly (no production change in `SubagentHierarchyBuilder`) and assert the user-visible outcome. Append to `ClaudeWorkflowSubagentTests`:

```swift
    // MARK: - Hierarchy nesting (consequence of the detection fix)

    private func claudeSession(id: String,
                               filePath: String,
                               parentSessionID: String?,
                               subagentType: String?,
                               hint: String?) -> Session {
        Session(
            id: id,
            source: .claude,
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            endTime: Date(timeIntervalSince1970: 1_700_000_100),
            model: "claude-opus-4-8",
            filePath: filePath,
            eventCount: 1,
            events: [],
            isHousekeeping: false,
            codexInternalSessionIDHint: hint,
            parentSessionID: parentSessionID,
            subagentType: subagentType
        )
    }

    func test_hierarchy_workflowSubagentNestsUnderParent() {
        let parent = claudeSession(
            id: "PARENT_ID",
            filePath: "/p/projecthash/\(parentUUID).jsonl",
            parentSessionID: nil,
            subagentType: nil,
            hint: parentUUID)
        let workflowChild = claudeSession(
            id: "CHILD_ID",
            filePath: "/p/projecthash/\(parentUUID)/subagents/workflows/wf_abc/agent-1.jsonl",
            parentSessionID: parentUUID,           // produced by the Task 1 fix
            subagentType: "workflow-subagent",
            hint: parentUUID)                       // carries the PARENT's sessionId

        let result = SubagentHierarchyBuilder.build(
            sessions: [parent, workflowChild],
            hierarchyEnabled: true)

        XCTAssertEqual(result.sessions.map(\.id), ["PARENT_ID", "CHILD_ID"])
        XCTAssertEqual(result.rowMeta["PARENT_ID"]?.childCount, 1)
        XCTAssertEqual(result.rowMeta["PARENT_ID"]?.hasChildren, true)
        XCTAssertEqual(result.rowMeta["CHILD_ID"]?.depth, 1)
    }

    func test_hierarchy_workflowSubagentHint_doesNotStealSiblingResolution() {
        // Regression for the hint-collision risk: the workflow child carries the
        // parent's sessionId as its hint. If it were (pre-fix) treated as a root
        // (parentSessionID == nil), it would register parentKeyToID[parentUUID] =
        // CHILD and steal a real flat sibling. With parentSessionID set, the
        // builder's guard skips its hint and BOTH children resolve to the parent.
        let parent = claudeSession(
            id: "PARENT_ID",
            filePath: "/p/projecthash/\(parentUUID).jsonl",
            parentSessionID: nil, subagentType: nil, hint: parentUUID)
        let workflowChild = claudeSession(
            id: "WF_CHILD_ID",
            filePath: "/p/projecthash/\(parentUUID)/subagents/workflows/wf_abc/agent-1.jsonl",
            parentSessionID: parentUUID, subagentType: "workflow-subagent", hint: parentUUID)
        let flatChild = claudeSession(
            id: "FLAT_CHILD_ID",
            filePath: "/p/projecthash/\(parentUUID)/subagents/agent-2.jsonl",
            parentSessionID: parentUUID, subagentType: "Explore", hint: parentUUID)

        let result = SubagentHierarchyBuilder.build(
            sessions: [parent, workflowChild, flatChild],
            hierarchyEnabled: true)

        // Both children fold under the real parent — not under each other.
        XCTAssertEqual(result.rowMeta["PARENT_ID"]?.childCount, 2)
        XCTAssertEqual(result.rowMeta["WF_CHILD_ID"]?.depth, 1)
        XCTAssertEqual(result.rowMeta["FLAT_CHILD_ID"]?.depth, 1)
        XCTAssertEqual(result.sessions.first?.id, "PARENT_ID")
    }
```

- [ ] **Step 8: Run the whole class to verify all green**

Run:
```bash
xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$PWD/.deriveddata-tests" \
  -parallel-testing-enabled NO \
  -only-testing:AgentSessionsTests/ClaudeWorkflowSubagentTests test
```
Expected: **PASS** (6 tests).

- [ ] **Step 9: Commit**

```bash
git add AgentSessions/Services/ClaudeSessionParser.swift AgentSessionsTests/ClaudeWorkflowSubagentTests.swift AgentSessions.xcodeproj/project.pbxproj
git commit -m "fix: detect nested Claude workflow subagents so they nest under their parent

Tool: Claude
Model: claude-opus-4-8
Why: detectSubagentInfo only matched the flat subagents/ layout, so workflow agents (subagents/workflows/wf_<id>/) became orphan top-level rows and could corrupt parent resolution"
```

---

## Task 2: Stop Claude discovery from ingesting `journal.jsonl` and sidecars (SHOULD-FIX)

The recursive walker accepts any `.jsonl`/`.ndjson` file, so it ingests each workflow's `journal.jsonl` (a run-control log, not a transcript) as a junk session, and lets the surrounding sidecars consume the per-project visit cap (`fileCapPerProject: 800`), risking real transcripts being dropped. The real run confirms the sidecar set is sizeable: per workflow run there are `*.meta.json` (one per agent), a `journal.jsonl`, a sibling `workflows/scripts/*.js`, a `workflows/wf_<id>.json`, and `tool-results/*.txt`. Only `journal.jsonl` shares the `.jsonl` extension and so needs an explicit name-skip; the rest are excluded by the extension guard — but all of them must stop counting toward the cap.

**Files:**
- Modify: `AgentSessions/Services/SessionDiscovery.swift:599-623`
- Test: `AgentSessionsTests/ClaudeWorkflowSubagentTests.swift`

**Interfaces:**
- Consumes: `ClaudeSessionDiscovery.init(customRoot:includeDesktopRoots:desktopLocalAgentRoot:)`, `discoverSessionFiles() -> [URL]` (existing).
- Produces: `ClaudeSessionDiscovery.collectSessionFiles(in: URL, fileCap: Int) -> (files: [URL], hitCap: Bool)` — visibility relaxed from `private` to `internal` so the cap behavior is unit-testable. Behavior: returns only transcript files (`.jsonl`/`.ndjson`, excluding `journal.jsonl`); only those count toward `fileCap`.

- [ ] **Step 1: Write the failing discovery exclusion test**

Append to `ClaudeWorkflowSubagentTests` (reuses `makeUniqueTempDir`/`write` from Task 1):

```swift
    // MARK: - Discovery excludes workflow journal + sidecars

    func test_discovery_excludesWorkflowJournalAndSidecars() throws {
        let root = try makeUniqueTempDir()
        let project = root.appendingPathComponent("projecthash", isDirectory: true)
        let parentFile = project.appendingPathComponent("\(parentUUID).jsonl")
        let parentDir = project.appendingPathComponent(parentUUID, isDirectory: true)
        let wfDir = parentDir
            .appendingPathComponent("subagents", isDirectory: true)
            .appendingPathComponent("workflows", isDirectory: true)
            .appendingPathComponent("wf_abc", isDirectory: true)
        let agentFile = wfDir.appendingPathComponent("agent-a0a3e832029606953.jsonl")
        // Real transcripts:
        try write(#"{"sessionId":"\#(parentUUID)","isSidechain":true}"#, to: parentFile)
        try write("{}\n", to: agentFile)
        // Sidecars from a real run — none may be ingested:
        try write(#"{"type":"started","agentId":"a0a3e832029606953"}"#, to: wfDir.appendingPathComponent("journal.jsonl"))
        try write(#"{"agentType":"workflow-subagent","spawnDepth":1}"#, to: wfDir.appendingPathComponent("agent-a0a3e832029606953.meta.json"))
        try write("// workflow script\n", to: parentDir.appendingPathComponent("workflows/scripts/migration-wf_abc.js"))
        try write("{}", to: parentDir.appendingPathComponent("workflows/wf_abc.json"))
        try write("tool output spill", to: parentDir.appendingPathComponent("tool-results/bj5l1z0m6.txt"))

        let discovery = ClaudeSessionDiscovery(customRoot: root.path, includeDesktopRoots: false)
        let names = Set(discovery.discoverSessionFiles().map(\.lastPathComponent))

        XCTAssertEqual(names, ["\(parentUUID).jsonl", "agent-a0a3e832029606953.jsonl"],
                       "only the parent + agent transcripts may be discovered")
        XCTAssertFalse(names.contains("journal.jsonl"), "workflow journal must not be ingested as a session")
    }
```

- [ ] **Step 2: Run it to verify it fails**

Run:
```bash
xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$PWD/.deriveddata-tests" \
  -parallel-testing-enabled NO \
  -only-testing:AgentSessionsTests/ClaudeWorkflowSubagentTests/test_discovery_excludesWorkflowJournalAndSidecars test
```
Expected: **FAIL** on the `journal.jsonl` assertion (current code includes any `.jsonl`).

- [ ] **Step 3: Implement the sidecar/journal filter and expose the method**

In `AgentSessions/Services/SessionDiscovery.swift`, replace `collectSessionFiles` (`:599-623`) with:

```swift
    // internal (not private) so the visit-cap behavior is unit-testable.
    func collectSessionFiles(in root: URL, fileCap: Int) -> (files: [URL], hitCap: Bool) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root,
                                             includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                                             options: [.skipsHiddenFiles]) else {
            return ([], false)
        }
        var out: [URL] = []
        var visited = 0
        var hitCap = false
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }

            // Only transcript files are candidates. Skipping sidecars (.meta.json,
            // .js) and the workflow run-control log (journal.jsonl) BEFORE counting
            // toward the cap keeps the budget for real transcripts and stops the
            // journal from being parsed as a junk session.
            let ext = file.pathExtension.lowercased()
            guard ext == "jsonl" || ext == "ndjson" else { continue }
            if file.lastPathComponent == "journal.jsonl" { continue }

            visited += 1
            if visited > fileCap {
                hitCap = true
                break
            }
            out.append(file)
        }
        return (out, hitCap)
    }
```

- [ ] **Step 4: Run the exclusion test to verify it passes**

Re-run the Step 2 command. Expected: **PASS**.

- [ ] **Step 5: Write the cap-starvation test (now that the method is internal)**

Append to `ClaudeWorkflowSubagentTests`:

```swift
    func test_collectSessionFiles_sidecarsDoNotStarveVisitCap() throws {
        let root = try makeUniqueTempDir()
        let wfDir = root
            .appendingPathComponent("projecthash", isDirectory: true)
            .appendingPathComponent(parentUUID, isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
            .appendingPathComponent("workflows", isDirectory: true)
            .appendingPathComponent("wf_abc", isDirectory: true)
        // 2 transcripts surrounded by many sidecars that previously burned the cap.
        try write("{}\n", to: wfDir.appendingPathComponent("agent-1.jsonl"))
        try write("{}\n", to: wfDir.appendingPathComponent("agent-2.jsonl"))
        try write(#"{"type":"started"}"#, to: wfDir.appendingPathComponent("journal.jsonl"))
        for i in 0..<10 {
            try write("{}", to: wfDir.appendingPathComponent("agent-\(i).meta.json"))
        }

        let discovery = ClaudeSessionDiscovery(customRoot: root.path, includeDesktopRoots: false)
        let (files, hitCap) = discovery.collectSessionFiles(in: root, fileCap: 2)

        // Both transcripts fit in a cap of 2 because sidecars/journal no longer count.
        XCTAssertEqual(Set(files.map(\.lastPathComponent)), ["agent-1.jsonl", "agent-2.jsonl"])
        XCTAssertFalse(hitCap)
    }
```

- [ ] **Step 6: Run the full class to verify all green**

Run:
```bash
xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$PWD/.deriveddata-tests" \
  -parallel-testing-enabled NO \
  -only-testing:AgentSessionsTests/ClaudeWorkflowSubagentTests test
```
Expected: **PASS** (8 tests).

- [ ] **Step 7: Commit**

```bash
git add AgentSessions/Services/SessionDiscovery.swift AgentSessionsTests/ClaudeWorkflowSubagentTests.swift
git commit -m "fix: skip workflow journal/sidecars in Claude discovery so they neither ingest nor starve the visit cap

Tool: Claude
Model: claude-opus-4-8
Why: collectSessionFiles ingested journal.jsonl as a junk session and let .meta.json/.js sidecars consume the per-project file cap"
```

---

## Task 3: Align resume ID helpers with the nested layout (SHOULD-FIX)

Now that workflow rows are correctly identified as subagents, users can interact with them (copy session ID, copy resume command, open dir). Those paths call `ClaudeSessionIDHelper.deriveSessionID`/`projectRoot`, which today only understand the flat layout. For a workflow agent, `deriveSessionID` falls through to scanning `session.events` — which is **empty** under lightweight parsing — and returns `nil`; `projectRoot` looks for `sessions-index.json` in `wf_<id>/` and misses the real project root. Generalize both to the same "last `subagents` component" logic.

**Files:**
- Modify: `AgentSessions/ClaudeResume/ClaudeSessionIDHelper.swift:10-63`
- Test: `AgentSessionsTests/ClaudeWorkflowSubagentTests.swift`

**Interfaces:**
- Consumes: `ClaudeSessionIDHelper.looksLikeUUID(_:)` (existing).
- Produces: unchanged signatures `deriveSessionID(from: Session) -> String?` and `projectRoot(for: Session, settings: ClaudeResumeSettings?) -> URL?`, generalized to the nested layout.

- [ ] **Step 1: Write the failing `deriveSessionID` test**

Append to `ClaudeWorkflowSubagentTests`:

```swift
    // MARK: - Resume ID helpers (nested layout)

    func test_deriveSessionID_nestedWorkflowAgent_returnsParentUUID() {
        // events == [] on purpose: lightweight parse must not be relied on.
        let session = claudeSession(
            id: "CHILD_ID",
            filePath: "/p/projecthash/\(parentUUID)/subagents/workflows/wf_abc/agent-1.jsonl",
            parentSessionID: parentUUID, subagentType: "workflow-subagent", hint: parentUUID)

        XCTAssertEqual(ClaudeSessionIDHelper.deriveSessionID(from: session), parentUUID)
    }
```

- [ ] **Step 2: Run it to verify it fails**

Run:
```bash
xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$PWD/.deriveddata-tests" \
  -parallel-testing-enabled NO \
  -only-testing:AgentSessionsTests/ClaudeWorkflowSubagentTests/test_deriveSessionID_nestedWorkflowAgent_returnsParentUUID test
```
Expected: **FAIL** — returns `nil` (flat check misses `wf_abc`; event-scan fallback finds nothing because `events == []`).

- [ ] **Step 3: Generalize `deriveSessionID`**

In `AgentSessions/ClaudeResume/ClaudeSessionIDHelper.swift`, replace the subagent branch (`:17-22`) so the function reads:

```swift
    static func deriveSessionID(from session: Session) -> String? {
        let url = URL(fileURLWithPath: session.filePath)
        let base = url.deletingPathExtension().lastPathComponent

        // Direct session: filename IS the UUID
        if looksLikeUUID(base) { return base }

        // Subagent session (flat OR nested workflow layout): the parent UUID is the
        // component immediately before the last `subagents` component. The CLI
        // resumes the PARENT, so that's the ID we want.
        let components = url.pathComponents
        if let subagentsIndex = components.lastIndex(of: "subagents"), subagentsIndex > 0 {
            let parentSessionName = components[subagentsIndex - 1]
            if looksLikeUUID(parentSessionName) { return parentSessionName }
        }

        // Fallback: scan events for a sessionId field
        let limit = min(session.events.count, 2000)
        for e in session.events.prefix(limit) {
            let raw = e.rawJSON
            if let data = Data(base64Encoded: raw),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let sid = json["sessionId"] as? String, looksLikeUUID(sid) {
                return sid
            }
        }
        return nil
    }
```

- [ ] **Step 4: Run the `deriveSessionID` test to verify it passes**

Re-run the Step 2 command. Expected: **PASS**.

- [ ] **Step 5: Write the failing `projectRoot` test**

Append to `ClaudeWorkflowSubagentTests`:

```swift
    @MainActor
    func test_projectRoot_nestedWorkflowAgent_readsProjectSessionsIndex() throws {
        let root = try makeUniqueTempDir()
        let project = root.appendingPathComponent("projecthash", isDirectory: true)
        try write(#"{"originalPath":"/Users/me/code/widgets"}"#,
                  to: project.appendingPathComponent("sessions-index.json"))
        let agentPath = project
            .appendingPathComponent(parentUUID, isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
            .appendingPathComponent("workflows", isDirectory: true)
            .appendingPathComponent("wf_abc", isDirectory: true)
            .appendingPathComponent("agent-1.jsonl").path
        let session = claudeSession(
            id: "CHILD_ID", filePath: agentPath,
            parentSessionID: parentUUID, subagentType: "workflow-subagent", hint: parentUUID)

        let resolved = ClaudeSessionIDHelper.projectRoot(for: session)

        XCTAssertEqual(resolved?.path, "/Users/me/code/widgets")
    }
```

- [ ] **Step 6: Run it to verify it fails**

Run:
```bash
xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$PWD/.deriveddata-tests" \
  -parallel-testing-enabled NO \
  -only-testing:AgentSessionsTests/ClaudeWorkflowSubagentTests/test_projectRoot_nestedWorkflowAgent_readsProjectSessionsIndex test
```
Expected: **FAIL** — current code looks for `sessions-index.json` under `wf_abc/`, misses it, and falls back to `session.cwd` (nil here).

- [ ] **Step 7: Generalize `projectRoot`**

In `AgentSessions/ClaudeResume/ClaudeSessionIDHelper.swift`, replace the subagent-stripping branch (`:45-48`) so the leading portion of `projectRoot(for:settings:)` reads:

```swift
    @MainActor
    static func projectRoot(for session: Session, settings: ClaudeResumeSettings? = nil) -> URL? {
        let settings = settings ?? .shared
        let url = URL(fileURLWithPath: session.filePath)
        var projectDir = url.deletingLastPathComponent()
        // Strip subagent nesting to reach <projectHash>. The project dir is the
        // component just before <parentUUID>, i.e. two before the last `subagents`.
        // Works for both flat (.../<parentUUID>/subagents/agent.jsonl) and nested
        // (.../<parentUUID>/subagents/workflows/wf_<id>/agent.jsonl) layouts.
        let components = url.pathComponents
        if let subagentsIndex = components.lastIndex(of: "subagents"), subagentsIndex >= 1 {
            let projectComponents = Array(components[0..<(subagentsIndex - 1)])
            projectDir = URL(fileURLWithPath: NSString.path(withComponents: projectComponents))
        }
        let indexFile = projectDir.appendingPathComponent("sessions-index.json")
        if let data = try? Data(contentsOf: indexFile),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let original = json["originalPath"] as? String, !original.isEmpty {
            return URL(fileURLWithPath: original)
        }
        // Fallback chain matching effectiveWorkingDirectory behavior
        if let cwd = session.cwd, !cwd.isEmpty {
            return URL(fileURLWithPath: cwd)
        }
        if !settings.defaultWorkingDirectory.isEmpty {
            return URL(fileURLWithPath: settings.defaultWorkingDirectory)
        }
        return nil
    }
```

- [ ] **Step 8: Run the full class to verify all green**

Run:
```bash
xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$PWD/.deriveddata-tests" \
  -parallel-testing-enabled NO \
  -only-testing:AgentSessionsTests/ClaudeWorkflowSubagentTests test
```
Expected: **PASS** (10 tests).

- [ ] **Step 9: Commit**

```bash
git add AgentSessions/ClaudeResume/ClaudeSessionIDHelper.swift AgentSessionsTests/ClaudeWorkflowSubagentTests.swift
git commit -m "fix: resolve resume session ID and project root for nested Claude workflow agents

Tool: Claude
Model: claude-opus-4-8
Why: deriveSessionID/projectRoot only understood the flat subagents/ layout and returned nil/wrong dir for workflow agents under lightweight parsing"
```

---

## Task 4: Concise "workflow" badge (OPTIONAL / nice-to-have)

After Task 1, a nested workflow row shows its `subagentType` badge verbatim — `workflow-subagent` — which is long and clips. Map it to a concise `workflow` label via a tiny testable helper. This does not change any logic; it only shortens the displayed string. (The pre-existing badge rendering at `UnifiedSessionsView.swift:3577-3588` only appears when hierarchy nesting is active, so the parent must be present — which it is after Task 1.)

**Files:**
- Modify: `AgentSessions/Views/UnifiedSessionsView.swift` (add internal helper enum + use it at `:3579-3588`)
- Test: `AgentSessionsTests/ClaudeWorkflowSubagentTests.swift`

**Interfaces:**
- Produces: `enum WorkflowSubagentBadge { static func displayLabel(for agentType: String) -> String }` — returns `"workflow"` for `"workflow-subagent"`, otherwise the input unchanged. Declared `internal` (no new file) so `@testable` tests can reach it.

- [ ] **Step 1: Write the failing badge-label test**

Append to `ClaudeWorkflowSubagentTests`:

```swift
    // MARK: - Workflow badge label

    func test_workflowBadgeLabel_mapsWorkflowSubagentToWorkflow() {
        XCTAssertEqual(WorkflowSubagentBadge.displayLabel(for: "workflow-subagent"), "workflow")
    }

    func test_workflowBadgeLabel_passesThroughOtherTypes() {
        XCTAssertEqual(WorkflowSubagentBadge.displayLabel(for: "Explore"), "Explore")
        XCTAssertEqual(WorkflowSubagentBadge.displayLabel(for: "general"), "general")
    }
```

- [ ] **Step 2: Run them to verify they fail**

Run:
```bash
xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$PWD/.deriveddata-tests" \
  -parallel-testing-enabled NO \
  -only-testing:AgentSessionsTests/ClaudeWorkflowSubagentTests/test_workflowBadgeLabel_mapsWorkflowSubagentToWorkflow test
```
Expected: **FAIL** to compile — `WorkflowSubagentBadge` is undefined.

- [ ] **Step 3: Add the helper and use it in the badge**

In `AgentSessions/Views/UnifiedSessionsView.swift`, add this `internal` enum near the top of the file (after the imports, before `struct UnifiedSessionsView`):

```swift
/// Display mapping for subagent-type badges. Keeps long internal type names
/// (e.g. "workflow-subagent") short in the session list.
enum WorkflowSubagentBadge {
    static func displayLabel(for agentType: String) -> String {
        agentType == "workflow-subagent" ? "workflow" : agentType
    }
}
```

Then, in `SessionTitleCell.body`, change the subagent-type badge (`:3579-3588`) from:

```swift
                if let agentType = session.subagentType, !agentType.isEmpty {
                    Text(agentType)
```

to:

```swift
                if let agentType = session.subagentType, !agentType.isEmpty {
                    Text(WorkflowSubagentBadge.displayLabel(for: agentType))
```

(Leave the surrounding modifiers — `.font`, padding, purple background, `.help(subagentPillHelp)` — unchanged.)

- [ ] **Step 4: Run the badge tests to verify they pass**

Run:
```bash
xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$PWD/.deriveddata-tests" \
  -parallel-testing-enabled NO \
  -only-testing:AgentSessionsTests/ClaudeWorkflowSubagentTests test
```
Expected: **PASS** (12 tests).

- [ ] **Step 5: Build the app target (SwiftUI view changed)**

Run:
```bash
xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug build
```
Expected: **BUILD SUCCEEDED**.

- [ ] **Step 6: Commit**

```bash
git add AgentSessions/Views/UnifiedSessionsView.swift AgentSessionsTests/ClaudeWorkflowSubagentTests.swift
git commit -m "feat: show a concise 'workflow' badge for Claude workflow subagents

Tool: Claude
Model: claude-opus-4-8
Why: the raw 'workflow-subagent' agentType clipped in the session list badge"
```

---

## Task 5: Suppress the Resume action on workflow-subagent rows (OPTIONAL / nice-to-have)

Resuming a Claude subagent resolves to the **parent** session (`deriveSessionID` returns the parent UUID). For workflow agents the parent is already a row in the list, so offering Resume on the child is redundant and confusing. Gate it off for workflow agents specifically. (Scoped narrowly to `workflow-subagent`; flat Task-tool subagents keep their current behavior.)

**Files:**
- Modify: `AgentSessions/Model/Session.swift` (add computed property near `:68`)
- Modify: `AgentSessions/Views/UnifiedSessionsView.swift` (`canResumeSession(_:)` `:2695-2706`; `resume(_:)` `:2712`)
- Test: `AgentSessionsTests/ClaudeWorkflowSubagentTests.swift`

**Interfaces:**
- Produces: `Session.isClaudeWorkflowSubagent: Bool` — `true` iff `source == .claude && subagentType == "workflow-subagent"`.
- Consumes: `canResumeSession(_:antigravityCLISessionID:)` and `resume(_:)` (existing private methods in `UnifiedSessionsView`).

- [ ] **Step 1: Write the failing resume-gating test**

Append to `ClaudeWorkflowSubagentTests`. `canResumeSession` is a private view method, so we test the underlying model predicate that drives it:

```swift
    // MARK: - Resume gating for workflow subagents

    func test_isClaudeWorkflowSubagent_trueForWorkflowAgent() {
        let wf = claudeSession(
            id: "CHILD_ID",
            filePath: "/p/projecthash/\(parentUUID)/subagents/workflows/wf_abc/agent-1.jsonl",
            parentSessionID: parentUUID, subagentType: "workflow-subagent", hint: parentUUID)
        XCTAssertTrue(wf.isClaudeWorkflowSubagent)
    }

    func test_isClaudeWorkflowSubagent_falseForFlatSubagent() {
        let flat = claudeSession(
            id: "FLAT_ID",
            filePath: "/p/projecthash/\(parentUUID)/subagents/agent-2.jsonl",
            parentSessionID: parentUUID, subagentType: "Explore", hint: parentUUID)
        XCTAssertFalse(flat.isClaudeWorkflowSubagent)
    }
```

- [ ] **Step 2: Run them to verify they fail**

Run:
```bash
xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$PWD/.deriveddata-tests" \
  -parallel-testing-enabled NO \
  -only-testing:AgentSessionsTests/ClaudeWorkflowSubagentTests/test_isClaudeWorkflowSubagent_trueForWorkflowAgent test
```
Expected: **FAIL** to compile — `isClaudeWorkflowSubagent` is undefined.

- [ ] **Step 3: Add the model predicate**

In `AgentSessions/Model/Session.swift`, immediately after the `isSideChat` computed property (`:69`), add:

```swift
    /// A Claude subagent spawned by a Workflow run (nested
    /// subagents/workflows/wf_<id>/ layout, agentType == "workflow-subagent").
    /// Resuming one resolves to the parent, which is already its own row, so the
    /// UI suppresses Resume for these.
    public var isClaudeWorkflowSubagent: Bool {
        source == .claude && subagentType == "workflow-subagent"
    }
```

- [ ] **Step 4: Gate the resume affordances**

In `AgentSessions/Views/UnifiedSessionsView.swift`, split the `.claude` case in `canResumeSession(_:antigravityCLISessionID:)` (`:2699-2700`) so it reads:

```swift
        case .claude:
            return !s.isClaudeWorkflowSubagent
        case .opencode, .hermes, .copilot, .cursor, .pi:
            return true
```

Then, as a defensive backstop for any direct caller, add an early guard at the top of `resume(_ s: Session)` (`:2712`), before the `switch s.source`:

```swift
    private func resume(_ s: Session) {
        guard !s.isClaudeWorkflowSubagent else { return }
        switch s.source {
```

- [ ] **Step 5: Run the model tests to verify they pass**

Run:
```bash
xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$PWD/.deriveddata-tests" \
  -parallel-testing-enabled NO \
  -only-testing:AgentSessionsTests/ClaudeWorkflowSubagentTests test
```
Expected: **PASS** (14 tests).

- [ ] **Step 6: Build the app target**

Run:
```bash
xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug build
```
Expected: **BUILD SUCCEEDED**.

- [ ] **Step 7: Commit**

```bash
git add AgentSessions/Model/Session.swift AgentSessions/Views/UnifiedSessionsView.swift AgentSessionsTests/ClaudeWorkflowSubagentTests.swift
git commit -m "feat: suppress Resume on Claude workflow subagent rows

Tool: Claude
Model: claude-opus-4-8
Why: resuming a workflow subagent resolves to the parent (already its own row), making the action redundant"
```

---

## Task 6: Subtle workflow marker on parent rows (OPTIONAL / nice-to-have)

The parent that spawned a workflow is a **normal session** — it just happens to have called the Workflow tool — so it must not be mislabeled as "a workflow." But when collapsed, its generic `(N)` child count can't tell you a workflow run is inside. Add a small, secondary-colored fan-out glyph next to the count, shown only when at least one resolved child is a workflow agent, deriving the flag from the children (not from the parent transcript). No colored pill, no "workflow" text on the parent's title.

**Files:**
- Modify: `AgentSessions/Services/SubagentHierarchyBuilder.swift:4-8` (struct) and `:112` (parent row construction)
- Modify: `AgentSessions/Views/UnifiedSessionsView.swift:3535-3547` (`SessionTitleCell` chevron/count block)
- Test: `AgentSessionsTests/ClaudeWorkflowSubagentTests.swift`

**Interfaces:**
- Consumes: `Session.isClaudeWorkflowSubagent` (from Task 5). **If Task 5 is not being implemented, add that property first** (Task 5 Step 3 — a one-line model property), or inline the equivalent `$0.source == .claude && $0.subagentType == "workflow-subagent"` in Step 3 below.
- Produces: `SubagentRowMeta.hasWorkflowChildren: Bool` (`true` on a parent row when ≥1 resolved child is a Claude workflow agent). Add it via an **explicit initializer** that defaults the new parameter — a `let` with an inline default value is omitted from the synthesized memberwise init, so the parent callsite could not pass it. The explicit default keeps the other two `SubagentRowMeta(...)` callsites compiling unchanged.

- [ ] **Step 1: Write the failing flag tests**

Append to `ClaudeWorkflowSubagentTests` (reuses `claudeSession(...)` from Task 1):

```swift
    // MARK: - Parent workflow marker

    func test_hierarchy_parentWithWorkflowChild_flagsHasWorkflowChildren() {
        let parent = claudeSession(
            id: "PARENT_ID",
            filePath: "/p/projecthash/\(parentUUID).jsonl",
            parentSessionID: nil, subagentType: nil, hint: parentUUID)
        let workflowChild = claudeSession(
            id: "WF_CHILD_ID",
            filePath: "/p/projecthash/\(parentUUID)/subagents/workflows/wf_abc/agent-1.jsonl",
            parentSessionID: parentUUID, subagentType: "workflow-subagent", hint: parentUUID)

        let result = SubagentHierarchyBuilder.build(
            sessions: [parent, workflowChild], hierarchyEnabled: true)

        XCTAssertEqual(result.rowMeta["PARENT_ID"]?.hasWorkflowChildren, true)
        // The child itself is not a parent — never flagged.
        XCTAssertEqual(result.rowMeta["WF_CHILD_ID"]?.hasWorkflowChildren, false)
    }

    func test_hierarchy_parentWithOnlyFlatSubagents_doesNotFlagWorkflow() {
        let parent = claudeSession(
            id: "PARENT_ID",
            filePath: "/p/projecthash/\(parentUUID).jsonl",
            parentSessionID: nil, subagentType: nil, hint: parentUUID)
        let flatChild = claudeSession(
            id: "FLAT_CHILD_ID",
            filePath: "/p/projecthash/\(parentUUID)/subagents/agent-2.jsonl",
            parentSessionID: parentUUID, subagentType: "Explore", hint: parentUUID)

        let result = SubagentHierarchyBuilder.build(
            sessions: [parent, flatChild], hierarchyEnabled: true)

        XCTAssertEqual(result.rowMeta["PARENT_ID"]?.hasWorkflowChildren, false)
    }
```

- [ ] **Step 2: Run them to verify they fail**

Run:
```bash
xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$PWD/.deriveddata-tests" \
  -parallel-testing-enabled NO \
  -only-testing:AgentSessionsTests/ClaudeWorkflowSubagentTests/test_hierarchy_parentWithWorkflowChild_flagsHasWorkflowChildren test
```
Expected: **FAIL** to compile — `SubagentRowMeta` has no member `hasWorkflowChildren`.

- [ ] **Step 3: Add the derived flag**

In `AgentSessions/Services/SubagentHierarchyBuilder.swift`, extend the struct (`:4-8`) with an explicit initializer that defaults the new parameter (an inline `let … = false` would be dropped from the memberwise init and could not be passed at the parent callsite):

```swift
/// Row metadata for hierarchical session display.
struct SubagentRowMeta {
    let depth: Int            // 0 = top-level, 1 = subagent child
    let hasChildren: Bool     // true if this session has resolved subagent children
    let childCount: Int       // number of resolved subagent children (0 for non-parents)
    let hasWorkflowChildren: Bool  // true when ≥1 resolved child is a Claude workflow agent

    init(depth: Int, hasChildren: Bool, childCount: Int, hasWorkflowChildren: Bool = false) {
        self.depth = depth
        self.hasChildren = hasChildren
        self.childCount = childCount
        self.hasWorkflowChildren = hasWorkflowChildren
    }
}
```

Then, in `build(...)`, set it at the parent-row construction site (`:111-112`):

```swift
            flatSessions.append(s)
            rowMeta[s.id] = SubagentRowMeta(
                depth: 0,
                hasChildren: hasChildren,
                childCount: children.count,
                hasWorkflowChildren: children.contains { $0.isClaudeWorkflowSubagent }
            )
```

(Leave the child-row site at `:117` and the `flatResult` site at `:130` unchanged — they correctly default to `false`.)

- [ ] **Step 4: Run the flag tests to verify they pass**

Re-run the Step 2 command, then the negative case:
```bash
xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$PWD/.deriveddata-tests" \
  -parallel-testing-enabled NO \
  -only-testing:AgentSessionsTests/ClaudeWorkflowSubagentTests/test_hierarchy_parentWithOnlyFlatSubagents_doesNotFlagWorkflow test
```
Expected: both **PASS**.

- [ ] **Step 5: Confirm no other `SubagentRowMeta` constructor was missed**

Per the project rule to grep all callsites after an interface change:
```bash
grep -rn "SubagentRowMeta(" --include="*.swift" AgentSessions
```
Expected: only the three construction sites in `SubagentHierarchyBuilder.swift` (`:112`, `:117`, `:130`). The defaulted property means any other callsite would still compile with `false`; verify there are none that *should* compute the flag.

- [ ] **Step 6: Render the marker in the row**

In `AgentSessions/Views/UnifiedSessionsView.swift`, inside `SessionTitleCell.body`, update the chevron/count block (`:3535-3547`) to insert the glyph between the chevron button and the count:

```swift
            if let meta = rowMeta, meta.hasChildren {
                Button(action: { onToggleExpand?(session.id) }) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .medium))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(.easeInOut(duration: 0.15), value: isExpanded)
                }
                .buttonStyle(.plain)
                .frame(width: 16)
                .foregroundStyle(.secondary)
                if meta.hasWorkflowChildren {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .help("Spawned a workflow · \(meta.childCount) agents")
                        .accessibilityLabel("Spawned a workflow")
                }
                Text("(\(meta.childCount))")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            } else if isNestedSubagent {
                Spacer().frame(width: 20)
            }
```

- [ ] **Step 7: Build the app target (SwiftUI view changed)**

Run:
```bash
xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug build
```
Expected: **BUILD SUCCEEDED**.

- [ ] **Step 8: Run the full class to verify all green**

Run:
```bash
xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$PWD/.deriveddata-tests" \
  -parallel-testing-enabled NO \
  -only-testing:AgentSessionsTests/ClaudeWorkflowSubagentTests test
```
Expected: **PASS** (16 tests).

- [ ] **Step 9: Commit**

```bash
git add AgentSessions/Services/SubagentHierarchyBuilder.swift AgentSessions/Views/UnifiedSessionsView.swift AgentSessionsTests/ClaudeWorkflowSubagentTests.swift
git commit -m "feat: mark parent rows that spawned a Claude workflow with a subtle fan-out glyph

Tool: Claude
Model: claude-opus-4-8
Why: a collapsed parent's generic (N) count cannot reveal a workflow run; derive the marker from children so a general session is never mislabeled as a workflow"
```

---

## Task 7: Force-reindex migration for existing installs (MUST-FIX)

The parser/discovery fixes only change *how* files parse — they do not re-parse sessions already in the SQLite index (`session_meta`). On an existing install the 9 workflow agents keep their stale pre-fix rows (`parent_session_id = NULL`, `subagent_type = NULL`) and the `journal.jsonl` row persists, so the run never nests. The app's "Advanced re-index" is delta-based (skips unchanged files), so it does not help. The established mechanism (`DB.swift:378,390,420`) is a one-shot migration key that deletes the source's rows so they rebuild on next launch.

**Files:**
- Modify: `AgentSessions/Indexing/DB.swift` — add a migration in `bootstrap(...)`, right after the `codex_surface_reindex_v1` block, before `COMMIT`.

```swift
        // Force a full reindex of Claude sessions so nested Workflow subagents
        // (.../subagents/workflows/wf_<id>/agent-*.jsonl) get parent_session_id and
        // subagent_type populated by the generalized detectSubagentInfo, and stale
        // journal.jsonl rows (no longer discovered) are dropped.
        let claudeWorkflowReindex = "claude_workflow_subagent_reindex_v1"
        if !migrationApplied(db, key: claudeWorkflowReindex) {
            try exec(db, "DELETE FROM files WHERE source = 'claude';")
            try exec(db, "DELETE FROM session_meta WHERE source = 'claude';")
            try exec(db, "DELETE FROM session_search WHERE source = 'claude';")
            try exec(db, "DELETE FROM session_tool_io WHERE source = 'claude';")
            try exec(db, "DELETE FROM session_days WHERE source = 'claude';")
            try exec(db, "DELETE FROM rollups_daily WHERE source = 'claude';")
            try exec(db, "DELETE FROM index_state WHERE key LIKE 'analytics_backfill_done:claude:%';")
            try execBind(db, "INSERT OR IGNORE INTO schema_migrations(key) VALUES(?);", claudeWorkflowReindex)
        }
```

On the next app launch, `bootstrap()` runs once, drops the cached Claude rows, and the indexer re-parses Claude transcripts with the new code → the workflow run nests, journal/sidecar rows disappear.

> **Verification note (learned the hard way):** verify this by **building and running in Xcode**, not via `xcodebuild -derivedDataPath … + open`. An isolated-derived-data bundle launched with `open` (especially after `kill -9` cycles) can come up with no menu-bar/Dock UI even though the process is healthy — a launch artifact, unrelated to this code. `bootstrap()` (and thus the migration) only runs when the index DB initializes, which happens when the **Sessions window opens**.

---

## Final Verification

- [ ] **Run the full test suite (stable wrapper) to confirm no regressions across targets:**

```bash
./scripts/xcode_test_stable.sh
```
or the equivalent direct command from Global Constraints. Expected: all tests pass, including the existing `SessionParserTests`, `ClaudeRunwayParserTests`, and the new `ClaudeWorkflowSubagentTests`.

- [ ] **Manual smoke (optional, requires a real workflow transcript):** With a `~/.claude/projects/<hash>/<parentUUID>/subagents/workflows/wf_*/agent-*.jsonl` present, launch the app and confirm: the workflow agent appears nested under its parent (chevron + child count on the parent), shows a `workflow` badge, the parent row shows the fan-out glyph next to its child count (Task 6), no `journal.jsonl` orphan row exists, and the parent's other (flat) subagents still resolve correctly.

---

## Self-Review

**Spec coverage:**
- Must-fix bug (orphan rows + flat-only guard) → **Task 1** generalizes `detectSubagentInfo`.
- Bug (b) hint-collision in `SubagentHierarchyBuilder` → fixed *transitively* by Task 1 (workflow agents gain non-nil `parentSessionID`, so the `:55` guard excludes them); proven by `test_hierarchy_workflowSubagentHint_doesNotStealSiblingResolution` (no production change in the builder, per the File Structure note).
- Bug (c) discovery ingesting `journal.jsonl` + cap starvation from `.meta.json`/`.js` → **Task 2**.
- "Align detectSubagentInfo to the looser check" like the runway scanner → Task 1 mirrors `pathComponents` matching.
- Nice-to-have Workflow badge → **Task 4** (optional). Nice-to-have "Resume not offered on workflow agents" → **Task 5** (optional). Helper alignment that the optional resume relies on → **Task 3**. Subtle parent marker so a collapsed workflow run is still discoverable → **Task 6** (optional, depends on Task 5's `isClaudeWorkflowSubagent`).

**Placeholder scan:** No `TBD`/`handle edge cases`/"write tests for the above" — every code and test step contains complete content.

**Type consistency:** `detectSubagentInfo(from:) -> (parentSessionID:String?, subagentType:String?)`, `collectSessionFiles(in:fileCap:) -> (files:[URL], hitCap:Bool)`, `WorkflowSubagentBadge.displayLabel(for:) -> String`, and `Session.isClaudeWorkflowSubagent -> Bool` are referenced with identical names/signatures across their producing and consuming tasks. The shared test helpers `makeUniqueTempDir()`/`write(_:to:)`/`claudeSession(...)` are defined once in Task 1 and reused by name in Tasks 2–5 (same file).

---

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-06-27-claude-workflow-subagent-browser-support.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

**Which approach?**

Tasks 1–3 are the must-fix/should-fix core; Tasks 4–6 are optional polish that can be dropped or deferred without affecting the fix (Task 6 depends on Task 5's `isClaudeWorkflowSubagent`).
