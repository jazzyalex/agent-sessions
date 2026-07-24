# Kimi Code Tier-2 Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Kimi Code (`kimi`) as the 11th `SessionSource` in Agent Sessions at tier-2 scope — local JSONL transcript discovery, browsing, search, Preferences controls, colors, resume/copy-resume, and weekly session-format monitoring.

**Architecture:** Kimi Code persists each session as a directory under `~/.kimi-code/sessions/<workdir-bucket>/<sessionId>/`, containing a `state.json` sidecar (title, archived flag, workDir) and one JSONL journal per agent at `agents/<agentId>/wire.jsonl`. We discover `agents/main/wire.jsonl` files, treat the grandparent directory name as the session ID, join `state.json` for title/archive/cwd, and parse the `wire.jsonl` op-log into `SessionEvent`s. This mirrors the existing Pi (JSONL transcript) and Claude (sidecar-join + encoded workdir bucket) patterns already in the codebase — no new subsystems.

**Tech Stack:** Swift 6 / SwiftUI / Combine, XCTest, existing `SessionDiscovery` + `SessionIndexingEngine` + `SessionIndexerProtocol` contracts.

## Global Constraints

- Source rawValue is `kimi`; display name is `Kimi Code`. Never `kimi-code`, never `Kimi`.
- Tier-2 scope only. Do **not** add live status, analytics, usage/quota tracking, or Runway integration for Kimi. Kimi Code plan quota UI is explicitly out of scope.
- `SessionSource.versionIntroduced` for `.kimi` is `"4.7"`.
- Kimi Desktop is **not** a separate source. It is an Electron thin client over the same daemon and the same `~/.kimi-code/` home, so it lands in the same corpus with a per-session `SessionSurface` label. Do not add a `kimiDesktop` case.
- New Swift files MUST be registered in the Xcode project via `scripts/xcode_add_file.rb` (see `agents.md` → "Adding New Swift Files to Xcode Project"). A missing `PBXFileReference`/`PBXBuildFile` breaks the build with "Cannot find … in scope".
- Follow Conventional Commits with `Tool`/`Model`/`Why` trailers. No "Generated with Claude Code" footer, no `Co-Authored-By: Claude`.
- Do NOT run `git push`. Commit only; the owner pushes.
- Commit only intended paths: use `git commit -- <paths>`, never a bare `git commit` (it sweeps the whole staged index).

## Verified Format Facts (source of truth)

These were read from the MIT-licensed `MoonshotAI/kimi-code` source at CLI version `0.29.1`. Do not re-derive them; do not trust blog posts over this section.

On-disk layout under `~/.kimi-code/` (overridable by `KIMI_CODE_HOME`):

```
~/.kimi-code/
  session_index.jsonl              # {"sessionId","sessionDir","workDir"} | {"sessionId","deleted":true}
  sessions/
    wd_<slug>_<sha256hex[0:12]>/   # one bucket per working directory
      <sessionId>/
        state.json                 # {archived?, customTitle?, isCustomTitle?, lastPrompt?, title?, workDir?}
        agents/
          main/wire.jsonl          # main transcript
          <agentId>/wire.jsonl     # subagent transcripts
```

`wire.jsonl` line 1 is always the journal envelope:

```json
{"type":"metadata","protocol_version":"1.5","created_at":1750000000000}
```

Every later line is a flattened op: `{"type": <opType>, ...payload, "time": <epoch ms>}`.

Message lines carry the conversation:

```json
{"type":"context.append_message","message":{"role":"user","content":[{"type":"text","text":"…"}],"toolCalls":[]},"time":1750000000001}
```

- `role` is one of `system` | `user` | `assistant` | `tool`.
- `content` is an array of parts: `{"type":"text","text":…}`, `{"type":"think","think":…}`, `{"type":"image_url","imageUrl":{"url":…}}`, plus `audio_url` / `video_url`.
- Assistant tool calls: `toolCalls: [{"type":"function","id":…,"name":…,"arguments":<string|null>}]`.
- Tool results are `role:"tool"` messages carrying `toolCallId`.

Other op types observed in the schema: `turn.prompt`, `turn.steer`, `turn.cancel`, `config.update`, `permission.set_mode`, `permission.record_approval_result`, `plan_mode.enter|cancel|exit`, `swarm_mode.enter|exit`, `full_compaction.begin|cancel|complete`, `micro_compaction.apply`, `context.append_loop_event`, `context.update_token_count`, `context.clear`, `context.undo`, `context.apply_compaction`, `tools.*`, `goal.*`, `usage.record`, `llm.request`, `llm.tools_snapshot`, `mcp.tools_discovered`, `forked`.

Everything not explicitly mapped resolves to `.meta`, matching how every other AS parser absorbs additive drift.

**Deliberately not used:** `packages/minidb` is a bespoke binary Bitcask-style KV store, but it is gated behind flag `persistence_minidb_readmodel` (`default: false`) and is only "a derived read model". `wire.jsonl` is the source of truth. Do not write a minidb reader.

## File Structure

**Create:**
- `AgentSessions/Services/KimiSessionDiscovery.swift` — locate `agents/main/wire.jsonl` under the sessions root; validate the metadata envelope.
- `AgentSessions/Services/KimiSessionParser.swift` — `wire.jsonl` + `state.json` → `Session`; lightweight and full modes.
- `AgentSessions/Services/KimiSessionIndexer.swift` — `SessionIndexerProtocol` conformance; mirrors `PiSessionIndexer`.
- `AgentSessions/Kimi/KimiCLIEnvironment.swift` — binary lookup + `KIMI_CODE_HOME` resolution.
- `AgentSessions/KimiResume/KimiResumeCommandBuilder.swift` — build the `cd <workdir> && kimi -c` invocation.
- `Resources/Fixtures/stage0/agents/kimi/small.jsonl` — captured main wire journal.
- `Resources/Fixtures/stage0/agents/kimi/state.json` — captured sidecar.
- `AgentSessionsTests/KimiSessionParserTests.swift`
- `AgentSessionsTests/KimiSessionDiscoveryTests.swift`

**Modify:**
- `AgentSessions/Model/SessionSource.swift` — add `.kimi` + its four switch arms.
- `AgentSessions/Views/Preferences/PreferencesConstants.swift` — three new keys.
- `AgentSessions/Services/AgentEnablement.swift` — six switch sites.
- `AgentSessions/Services/UnifiedSessionIndexer.swift` — the heavy one; ~35 touchpoints.
- `AgentSessions/Services/TranscriptColorSystem.swift`, `AgentSessions/Analytics/Utilities/AnalyticsColors.swift`, `AgentSessions/Onboarding/Components/OnboardingPalette.swift` — colors.
- `AgentSessions/Views/PreferencesView.swift`, `AgentSessions/Views/UnifiedSessionsView.swift`, `AgentSessions/Views/SessionTerminalView.swift`, `AgentSessions/Onboarding/Components/OnboardingComponents.swift`, `AgentSessions/Onboarding/Views/FirstRunSetupView.swift` — UI arms.
- `AgentSessions/Search/SearchIngestService.swift`, `AgentSessions/Services/SessionArchiveManager.swift`, `AgentSessions/Services/AgentUpdateService.swift` — remaining exhaustive switches.
- `docs/agent-support/agent-support-matrix.yml`, `docs/agent-support/agent-support-ledger.yml`, `docs/agent-support/public-agents.json`, `docs/agent-support/agent-watch-config.json`, `docs/agent-json-tracking.md`, `README.md`.

---

### Task 1: Capture real Kimi Code evidence

No parser may be written against guessed bytes. This task installs the CLI, authenticates with a Kimi Platform API key (no subscription required), runs one scripted session in a controlled scratch directory so the capture is deterministic, and checks in the fixture.

**Files:**
- Create: `Resources/Fixtures/stage0/agents/kimi/small.jsonl`
- Create: `Resources/Fixtures/stage0/agents/kimi/state.json`

**Interfaces:**
- Consumes: nothing.
- Produces: two fixture files at the paths above. Task 4's tests assert against them. The scratch workDir is exactly `/tmp/as-agent-lab/kimi/project` and the scripted prompt is exactly `Read hello.py and summarize what it prints without editing files.` — later tasks depend on both strings verbatim.

- [ ] **Step 1: Create the scratch project**

```bash
mkdir -p /tmp/as-agent-lab/kimi/project && printf 'print("hello from the kimi fixture")\n' > /tmp/as-agent-lab/kimi/project/hello.py
```

- [ ] **Step 2: Install the CLI**

```bash
curl -fsSL https://code.kimi.com/kimi-code/install.sh | bash
```

Expected: `kimi` on PATH. Verify with `kimi --version`; record the printed version, it becomes `max_verified_version` in Task 9.

- [ ] **Step 3: Authenticate with a Platform API key**

Launch `kimi` inside the scratch project, run `/login`, and choose **Kimi Platform API key**. The key comes from platform.kimi.com. This is pay-as-you-go per token — a subscription is NOT required, and the Kimi Code plan is not needed for anything in this plan.

If no API key is available, STOP and report the blocker. Do not fabricate a fixture.

- [ ] **Step 4: Run the scripted session**

Inside `kimi`, launched with cwd `/tmp/as-agent-lab/kimi/project`, send exactly:

```text
Read hello.py and summarize what it prints without editing files.
```

Let the turn finish, then exit. This produces at least one user message, one assistant message, and one tool call (a file read).

- [ ] **Step 5: Locate and copy the capture**

```bash
find ~/.kimi-code/sessions -name wire.jsonl -newermt '-15 minutes' -path '*agents/main*'
```

Copy the newest match and its sidecar into the repo:

```bash
mkdir -p Resources/Fixtures/stage0/agents/kimi
```

Then copy the discovered `agents/main/wire.jsonl` to `Resources/Fixtures/stage0/agents/kimi/small.jsonl` and its `../../state.json` to `Resources/Fixtures/stage0/agents/kimi/state.json`.

- [ ] **Step 6: Verify the fixture matches the documented schema**

```bash
head -1 Resources/Fixtures/stage0/agents/kimi/small.jsonl | python3 -m json.tool
```

Expected: an object with `"type": "metadata"`, a string `protocol_version`, and a numeric `created_at`.

```bash
grep -c '"type":"context.append_message"' Resources/Fixtures/stage0/agents/kimi/small.jsonl
```

Expected: at least `2`.

If the first line is not `metadata`, or no `context.append_message` lines exist, STOP — the format has drifted from this plan's Verified Format Facts and the plan needs revision before any code is written.

- [ ] **Step 7: Scrub secrets**

Inspect the fixture for the API key, OAuth tokens, absolute home paths, and machine identifiers:

```bash
grep -nEi 'sk-|bearer|authorization|token|/Users/' Resources/Fixtures/stage0/agents/kimi/small.jsonl Resources/Fixtures/stage0/agents/kimi/state.json
```

Expected: no matches other than the `/tmp/as-agent-lab/kimi/project` workDir. Redact anything else in place before committing.

- [ ] **Step 8: Commit**

```bash
git add Resources/Fixtures/stage0/agents/kimi/small.jsonl Resources/Fixtures/stage0/agents/kimi/state.json && git commit -- Resources/Fixtures/stage0/agents/kimi -m "test(kimi): add captured Kimi Code wire.jsonl and state.json fixtures"
```

---

### Task 2: Register the `kimi` source

**Files:**
- Modify: `AgentSessions/Model/SessionSource.swift`
- Modify: `AgentSessions/Views/Preferences/PreferencesConstants.swift:82,98,155`
- Test: `AgentSessionsTests/KimiSessionDiscoveryTests.swift` (created here, extended in Task 3)

**Interfaces:**
- Consumes: nothing.
- Produces: `SessionSource.kimi` (rawValue `"kimi"`); `PreferencesKey.kimiCLIAvailable` = `"KimiCLIAvailable"`, `PreferencesKey.Agents.kimiEnabled` = `"AgentEnabledKimi"`, `PreferencesKey.Paths.kimiSessionsRootOverride` = `"KimiSessionsRootOverride"`. Every later task uses these exact identifiers.

- [ ] **Step 1: Write the failing test**

Create `AgentSessionsTests/KimiSessionDiscoveryTests.swift`:

```swift
import XCTest
@testable import AgentSessions

final class KimiSessionDiscoveryTests: XCTestCase {
    func testKimiSourceIdentity() {
        XCTAssertEqual(SessionSource.kimi.rawValue, "kimi")
        XCTAssertEqual(SessionSource.kimi.displayName, "Kimi Code")
        XCTAssertEqual(SessionSource.kimi.versionIntroduced, "4.7")
        XCTAssertTrue(SessionSource.allCases.contains(.kimi))
    }
}
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/KimiSessionDiscoveryTests`
Expected: compile failure — `type 'SessionSource' has no member 'kimi'`.

- [ ] **Step 3: Add the enum case and its four switch arms**

In `AgentSessions/Model/SessionSource.swift`, add after `case pi = "pi"`:

```swift
    case kimi = "kimi"
```

Then add one arm to each of the four switches:

```swift
        case .kimi: return "Kimi Code"
```
```swift
        case .kimi: return "k.circle"
```
```swift
        case .kimi:             return "4.7"
```
```swift
        case .kimi:     return "Browse your Kimi Code sessions"
```

- [ ] **Step 4: Add the three preference keys**

In `AgentSessions/Views/Preferences/PreferencesConstants.swift`, add next to their Pi counterparts:

```swift
    static let kimiCLIAvailable = "KimiCLIAvailable"
```
```swift
        static let kimiEnabled = "AgentEnabledKimi"
```
```swift
        static let kimiSessionsRootOverride = "KimiSessionsRootOverride"
```

- [ ] **Step 5: Register the new test file with Xcode**

```bash
ruby scripts/xcode_add_file.rb AgentSessionsTests/KimiSessionDiscoveryTests.swift
```

- [ ] **Step 6: Build and run the test**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/KimiSessionDiscoveryTests`
Expected: PASS.

The build will now surface non-exhaustive-switch errors across the app. That is expected and intentional — it is the compiler enumerating the integration surface. Tasks 3–8 close them; do not silence any of them with a `default:` arm.

- [ ] **Step 7: Commit**

```bash
git commit -- AgentSessions/Model/SessionSource.swift AgentSessions/Views/Preferences/PreferencesConstants.swift AgentSessionsTests/KimiSessionDiscoveryTests.swift AgentSessions.xcodeproj -m "feat(kimi): add kimi SessionSource case and preference keys"
```

---

### Task 3: Kimi session discovery

**Files:**
- Create: `AgentSessions/Services/KimiSessionDiscovery.swift`
- Test: `AgentSessionsTests/KimiSessionDiscoveryTests.swift`

**Interfaces:**
- Consumes: `SessionSource.kimi`, `PreferencesKey.Paths.kimiSessionsRootOverride` from Task 2.
- Produces: `final class KimiSessionDiscovery: SessionDiscovery` with `init(customRoot: String? = nil)`, `func sessionsRoot() -> URL`, `func discoverSessionFiles() -> [URL]`, and `static func sessionID(forWireFile url: URL) -> String?`. Task 4 and Task 5 both call these.

- [ ] **Step 1: Write the failing tests**

Append to `AgentSessionsTests/KimiSessionDiscoveryTests.swift`:

```swift
    private func makeTree() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kimi-disc-\(UUID().uuidString)", isDirectory: true)
        let main = root.appendingPathComponent("sessions/wd_project_0123456789ab/sess-1/agents/main", isDirectory: true)
        let sub = root.appendingPathComponent("sessions/wd_project_0123456789ab/sess-1/agents/agent-7/", isDirectory: true)
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let envelope = #"{"type":"metadata","protocol_version":"1.5","created_at":1750000000000}"#
        try (envelope + "\n").write(to: main.appendingPathComponent("wire.jsonl"), atomically: true, encoding: .utf8)
        try (envelope + "\n").write(to: sub.appendingPathComponent("wire.jsonl"), atomically: true, encoding: .utf8)
        return root
    }

    func testDiscoversOnlyMainWireFiles() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }

        let files = KimiSessionDiscovery(customRoot: root.path).discoverSessionFiles()

        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files[0].path.hasSuffix("sess-1/agents/main/wire.jsonl"))
    }

    func testSessionIDIsTheSessionDirectoryName() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }

        let file = KimiSessionDiscovery(customRoot: root.path).discoverSessionFiles()[0]

        XCTAssertEqual(KimiSessionDiscovery.sessionID(forWireFile: file), "sess-1")
    }

    func testRejectsFileWithoutMetadataEnvelope() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let main = root.appendingPathComponent("sessions/wd_project_0123456789ab/sess-1/agents/main/wire.jsonl")
        try #"{"type":"context.append_message"}"# .write(to: main, atomically: true, encoding: .utf8)

        XCTAssertTrue(KimiSessionDiscovery(customRoot: root.path).discoverSessionFiles().isEmpty)
    }

    func testDefaultRootIsKimiCodeSessions() {
        let root = KimiSessionDiscovery().sessionsRoot()
        XCTAssertTrue(root.path.hasSuffix("/.kimi-code/sessions"))
    }
```

- [ ] **Step 2: Run and confirm failure**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/KimiSessionDiscoveryTests`
Expected: compile failure — `cannot find 'KimiSessionDiscovery' in scope`.

- [ ] **Step 3: Implement discovery**

Create `AgentSessions/Services/KimiSessionDiscovery.swift`:

```swift
import Foundation

/// Discovery for Kimi Code main-agent journals under ~/.kimi-code/sessions.
///
/// Layout: sessions/<wd_slug_hash>/<sessionId>/agents/<agentId>/wire.jsonl.
/// Only `agents/main` is a top-level session; sibling agent directories are
/// subagent journals and are excluded from the session list.
final class KimiSessionDiscovery: SessionDiscovery {
    private let customRoot: String?

    init(customRoot: String? = nil) {
        self.customRoot = customRoot
    }

    func sessionsRoot() -> URL {
        if let customRoot, !customRoot.isEmpty {
            let expanded = (customRoot as NSString).expandingTildeInPath
            return normalizedSessionsRoot(URL(fileURLWithPath: expanded, isDirectory: true))
        }
        if let home = ProcessInfo.processInfo.environment["KIMI_CODE_HOME"], !home.isEmpty {
            let expanded = (home as NSString).expandingTildeInPath
            return normalizedSessionsRoot(URL(fileURLWithPath: expanded, isDirectory: true))
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kimi-code", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    /// The session id is the directory two levels above `agents/<id>/wire.jsonl`.
    static func sessionID(forWireFile url: URL) -> String? {
        let agentDir = url.deletingLastPathComponent()          // agents/<agentId>
        let agentsDir = agentDir.deletingLastPathComponent()    // agents
        guard agentsDir.lastPathComponent == "agents" else { return nil }
        let sessionDir = agentsDir.deletingLastPathComponent()  // <sessionId>
        let id = sessionDir.lastPathComponent
        return id.isEmpty ? nil : id
    }

    /// `state.json` sits beside the `agents/` directory.
    static func stateFile(forWireFile url: URL) -> URL {
        url.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("state.json", isDirectory: false)
    }

    func discoverSessionFiles() -> [URL] {
        let root = sessionsRoot()
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }

        guard let enumerator = fm.enumerator(at: root,
                                             includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return []
        }

        var files: [URL] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent == "wire.jsonl" else { continue }
            guard url.deletingLastPathComponent().lastPathComponent == "main" else { continue }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            guard Self.sessionID(forWireFile: url) != nil else { continue }
            guard hasMetadataEnvelope(url) else { continue }
            files.append(url)
        }

        return files.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if a != b { return a > b }
            return $0.path > $1.path
        }
    }

    private func normalizedSessionsRoot(_ root: URL) -> URL {
        let fm = FileManager.default
        let candidates = [root.appendingPathComponent("sessions", isDirectory: true), root]
        for candidate in candidates {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                return candidate
            }
        }
        return root
    }

    private func hasMetadataEnvelope(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }

        let data = handle.readData(ofLength: 64 * 1024)
        guard let prefix = String(data: data, encoding: .utf8),
              let line = prefix.split(separator: "\n", omittingEmptySubsequences: true).first,
              let lineData = String(line).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
            return false
        }
        return object["type"] as? String == "metadata" && object["protocol_version"] is String
    }
}
```

- [ ] **Step 4: Register the file and run the tests**

```bash
ruby scripts/xcode_add_file.rb AgentSessions/Services/KimiSessionDiscovery.swift
```

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/KimiSessionDiscoveryTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git commit -- AgentSessions/Services/KimiSessionDiscovery.swift AgentSessionsTests/KimiSessionDiscoveryTests.swift AgentSessions.xcodeproj -m "feat(kimi): discover Kimi Code main-agent wire journals"
```

---

### Task 4: Kimi session parser

**Files:**
- Create: `AgentSessions/Services/KimiSessionParser.swift`
- Create: `AgentSessionsTests/KimiSessionParserTests.swift`

**Interfaces:**
- Consumes: `KimiSessionDiscovery.sessionID(forWireFile:)` and `.stateFile(forWireFile:)` from Task 3; the fixtures from Task 1.
- Produces: `enum KimiSessionParser` with `static func parseFile(at: URL) -> Session?`, `static func parseFileFull(at: URL, allowLargeFile: Bool = false) -> Session?`, and `static let defaultFullParseMaxBytes: Int`. Task 5 calls both parse functions.

- [ ] **Step 1: Write the failing tests**

Create `AgentSessionsTests/KimiSessionParserTests.swift`:

```swift
import XCTest
@testable import AgentSessions

final class KimiSessionParserTests: XCTestCase {
    /// Stages the checked-in fixture into the real on-disk layout so the parser
    /// exercises its sidecar join and session-id derivation.
    private func stagedFixture() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("kimi-fixture-\(UUID().uuidString)", isDirectory: true)
        let sessionDir = root.appendingPathComponent("sessions/wd_project_0123456789ab/sess-fixture", isDirectory: true)
        let mainDir = sessionDir.appendingPathComponent("agents/main", isDirectory: true)
        try FileManager.default.createDirectory(at: mainDir, withIntermediateDirectories: true)

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let wire = repoRoot.appendingPathComponent("Resources/Fixtures/stage0/agents/kimi/small.jsonl")
        let state = repoRoot.appendingPathComponent("Resources/Fixtures/stage0/agents/kimi/state.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: wire.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: state.path))

        try FileManager.default.copyItem(at: wire, to: mainDir.appendingPathComponent("wire.jsonl"))
        try FileManager.default.copyItem(at: state, to: sessionDir.appendingPathComponent("state.json"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return mainDir.appendingPathComponent("wire.jsonl")
    }

    func testParseFileReadsHeaderAndSidecar() throws {
        let session = try XCTUnwrap(KimiSessionParser.parseFile(at: stagedFixture()))

        XCTAssertEqual(session.id, "sess-fixture")
        XCTAssertEqual(session.source, .kimi)
        XCTAssertEqual(session.surface, .cli)
        XCTAssertEqual(session.lightweightCwd, "/tmp/as-agent-lab/kimi/project")
        XCTAssertNotNil(session.startTime)
        XCTAssertTrue(session.events.isEmpty)
    }

    func testParseFileFullBuildsUserAssistantAndToolEvents() throws {
        let session = try XCTUnwrap(KimiSessionParser.parseFileFull(at: stagedFixture()))

        XCTAssertGreaterThanOrEqual(session.events.filter { $0.kind == .user }.count, 1)
        XCTAssertGreaterThanOrEqual(session.events.filter { $0.kind == .assistant }.count, 1)
        XCTAssertTrue(session.events.contains { $0.text?.contains("hello.py") == true })
    }

    func testUnknownOpTypesSurviveAsMeta() throws {
        let wire = try stagedFixture()
        let handle = try FileHandle(forWritingTo: wire)
        try handle.seekToEnd()
        let drift = #"{"type":"kimi.future_event","somethingNew":{"a":1},"time":1750000009999}"# + "\n"
        try handle.write(contentsOf: Data(drift.utf8))
        try handle.close()

        let session = try XCTUnwrap(KimiSessionParser.parseFileFull(at: wire))

        XCTAssertTrue(session.events.contains { $0.rawJSON.contains("kimi.future_event") })
        XCTAssertTrue(session.events.contains { $0.rawJSON.contains("kimi.future_event") && $0.kind == .meta })
    }

    func testParseFileFullSkipsOversizedFileUnlessExplicitlyAllowed() throws {
        let wire = try stagedFixture()
        let handle = try FileHandle(forWritingTo: wire)
        try handle.truncate(atOffset: UInt64(KimiSessionParser.defaultFullParseMaxBytes + 1))
        try handle.close()

        XCTAssertNil(KimiSessionParser.parseFileFull(at: wire))
        XCTAssertEqual(KimiSessionParser.parseFileFull(at: wire, allowLargeFile: true)?.id, "sess-fixture")
    }
}
```

- [ ] **Step 2: Run and confirm failure**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/KimiSessionParserTests`
Expected: compile failure — `cannot find 'KimiSessionParser' in scope`.

- [ ] **Step 3: Implement the parser**

Create `AgentSessions/Services/KimiSessionParser.swift`:

```swift
import Foundation

/// Parses Kimi Code `wire.jsonl` op-journals into `Session` values.
///
/// Line 1 is the journal envelope (`type: "metadata"`). Every later line is a
/// flattened op: `{type, ...payload, time}`. Conversation content arrives as
/// `context.append_message` ops carrying a kosong `Message`.
enum KimiSessionParser {
    static let defaultFullParseMaxBytes = 50 * 1024 * 1024
    private static let previewLineLimit = 200

    private struct Sidecar: Decodable {
        let archived: Bool?
        let customTitle: String?
        let isCustomTitle: Bool?
        let lastPrompt: String?
        let title: String?
        let workDir: String?
    }

    static func parseFile(at url: URL) -> Session? {
        build(url: url, lineLimit: previewLineLimit, includeEvents: false, allowLargeFile: true)
    }

    static func parseFileFull(at url: URL, allowLargeFile: Bool = false) -> Session? {
        build(url: url, lineLimit: nil, includeEvents: true, allowLargeFile: allowLargeFile)
    }

    private static func build(url: URL, lineLimit: Int?, includeEvents: Bool, allowLargeFile: Bool) -> Session? {
        guard let id = KimiSessionDiscovery.sessionID(forWireFile: url) else { return nil }

        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if !allowLargeFile, size > defaultFullParseMaxBytes { return nil }

        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var lines = contents.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        if let lineLimit, lines.count > lineLimit { lines = Array(lines.prefix(lineLimit)) }

        var events: [SessionEvent] = []
        var startTime: Date?
        var endTime: Date?
        var model: String?
        var firstUserText: String?
        var nonMetaCount = 0

        for (index, line) in lines.enumerated() {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String else { continue }

            let time = timestamp(from: object)
            if let time {
                if startTime == nil || time < startTime! { startTime = time }
                if endTime == nil || time > endTime! { endTime = time }
            }

            if type == "config.update", let m = modelIdentifier(from: object) { model = m }

            let built = makeEvents(type: type, object: object, time: time, line: line, index: index)
            nonMetaCount += built.filter { $0.kind != .meta }.count
            if firstUserText == nil {
                firstUserText = built.first(where: { $0.kind == .user })?.text
            }
            if includeEvents { events.append(contentsOf: built) }
        }

        let sidecar = readSidecar(for: url)
        let cwd = sidecar?.workDir
        let title = sidecar?.title ?? sidecar?.lastPrompt ?? firstUserText
        let customTitle = (sidecar?.isCustomTitle == true) ? sidecar?.customTitle : nil

        return Session(id: id,
                       source: .kimi,
                       startTime: startTime,
                       endTime: endTime,
                       model: model,
                       filePath: url.path,
                       fileSizeBytes: size,
                       eventCount: nonMetaCount,
                       events: events,
                       cwd: cwd,
                       repoName: cwd.map { URL(fileURLWithPath: $0).lastPathComponent },
                       lightweightTitle: title,
                       customTitle: customTitle,
                       surface: .cli)
    }

    private static func readSidecar(for url: URL) -> Sidecar? {
        let path = KimiSessionDiscovery.stateFile(forWireFile: url)
        guard let data = try? Data(contentsOf: path) else { return nil }
        return try? JSONDecoder().decode(Sidecar.self, from: data)
    }

    /// `time` and `created_at` are both epoch milliseconds.
    private static func timestamp(from object: [String: Any]) -> Date? {
        if let ms = object["time"] as? Double { return Date(timeIntervalSince1970: ms / 1000) }
        if let ms = object["created_at"] as? Double { return Date(timeIntervalSince1970: ms / 1000) }
        return nil
    }

    private static func modelIdentifier(from object: [String: Any]) -> String? {
        if let m = object["model"] as? String, !m.isEmpty { return m }
        if let config = object["config"] as? [String: Any], let m = config["model"] as? String, !m.isEmpty { return m }
        return nil
    }

    private static func makeEvents(type: String,
                                   object: [String: Any],
                                   time: Date?,
                                   line: String,
                                   index: Int) -> [SessionEvent] {
        guard type == "context.append_message",
              let message = object["message"] as? [String: Any],
              let role = message["role"] as? String else {
            return [SessionEvent(id: "\(index)", timestamp: time, kind: .meta, role: nil, text: nil,
                                 toolName: nil, toolInput: nil, toolOutput: nil,
                                 messageID: nil, parentID: nil, isDelta: false, rawJSON: line)]
        }

        var out: [SessionEvent] = []
        let text = textContent(from: message["content"])

        switch role {
        case "user":
            out.append(SessionEvent(id: "\(index)-u", timestamp: time, kind: .user, role: role, text: text,
                                    toolName: nil, toolInput: nil, toolOutput: nil,
                                    messageID: nil, parentID: nil, isDelta: false, rawJSON: line))
        case "assistant":
            if let text, !text.isEmpty {
                out.append(SessionEvent(id: "\(index)-a", timestamp: time, kind: .assistant, role: role, text: text,
                                        toolName: nil, toolInput: nil, toolOutput: nil,
                                        messageID: nil, parentID: nil, isDelta: false, rawJSON: line))
            }
            let calls = message["toolCalls"] as? [[String: Any]] ?? []
            for (callIndex, call) in calls.enumerated() {
                out.append(SessionEvent(id: "\(index)-t\(callIndex)", timestamp: time, kind: .tool_call, role: role, text: nil,
                                        toolName: call["name"] as? String,
                                        toolInput: call["arguments"] as? String,
                                        toolOutput: nil,
                                        messageID: call["id"] as? String, parentID: nil, isDelta: false, rawJSON: line))
            }
        case "tool":
            let isError = (message["isError"] as? Bool) == true
            out.append(SessionEvent(id: "\(index)-r", timestamp: time, kind: isError ? .error : .tool_result, role: role, text: nil,
                                    toolName: nil, toolInput: nil, toolOutput: text,
                                    messageID: message["toolCallId"] as? String, parentID: nil, isDelta: false, rawJSON: line))
        default:
            out.append(SessionEvent(id: "\(index)-m", timestamp: time, kind: .meta, role: role, text: text,
                                    toolName: nil, toolInput: nil, toolOutput: nil,
                                    messageID: nil, parentID: nil, isDelta: false, rawJSON: line))
        }

        if out.isEmpty {
            out.append(SessionEvent(id: "\(index)-m", timestamp: time, kind: .meta, role: role, text: nil,
                                    toolName: nil, toolInput: nil, toolOutput: nil,
                                    messageID: nil, parentID: nil, isDelta: false, rawJSON: line))
        }
        return out
    }

    /// Flattens kosong ContentParts. `think` parts are reasoning, not answer
    /// text, so they are dropped from the rendered body.
    private static func textContent(from content: Any?) -> String? {
        guard let parts = content as? [[String: Any]] else { return nil }
        let chunks: [String] = parts.compactMap { part in
            switch part["type"] as? String {
            case "text": return part["text"] as? String
            case "image_url": return "[image]"
            case "audio_url": return "[audio]"
            case "video_url": return "[video]"
            default: return nil
            }
        }
        let joined = chunks.joined(separator: "\n")
        return joined.isEmpty ? nil : joined
    }
}
```

- [ ] **Step 4: Register and run**

```bash
ruby scripts/xcode_add_file.rb AgentSessions/Services/KimiSessionParser.swift && ruby scripts/xcode_add_file.rb AgentSessionsTests/KimiSessionParserTests.swift
```

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/KimiSessionParserTests`
Expected: PASS (4 tests).

If `testParseFileFullBuildsUserAssistantAndToolEvents` fails on the `hello.py` assertion, read the captured fixture and adjust the asserted substring to text that actually appears in the capture — do not weaken the assertion to `isEmpty == false`.

- [ ] **Step 5: Commit**

```bash
git commit -- AgentSessions/Services/KimiSessionParser.swift AgentSessionsTests/KimiSessionParserTests.swift AgentSessions.xcodeproj -m "feat(kimi): parse wire.jsonl op journals into sessions"
```

---

### Task 5: Kimi session indexer

**Files:**
- Create: `AgentSessions/Services/KimiSessionIndexer.swift`
- Modify: `AgentSessions/Services/AgentEnablement.swift`

**Interfaces:**
- Consumes: `KimiSessionDiscovery`, `KimiSessionParser` from Tasks 3–4.
- Produces: `final class KimiSessionIndexer: ObservableObject, SessionIndexerProtocol, @unchecked Sendable` with `enum ReloadReason { case selection, focusedSessionMonitor, manualRefresh }` and `func reloadSession(id: String, force: Bool, reason: ReloadReason)`. Task 6 wires this into `UnifiedSessionIndexer`.

- [ ] **Step 1: Close the six `AgentEnablement` switches**

In `AgentSessions/Services/AgentEnablement.swift`:

`isEnabled(_:defaults:)` — add before `default:`:

```swift
        case .kimi:
            return isAvailable(.kimi, defaults: defaults)
```

`enablementKey(for:)`:

```swift
        case .kimi:     return PreferencesKey.Agents.kimiEnabled
```

`seedIfNeeded` — in the legacy-prefs branch, after the `.pi` line:

```swift
            setEnabledInternal(.kimi, enabled: isAvailable(.kimi, defaults: defaults), defaults: defaults)
```

and in the cold-start branch, after `let pi = …`:

```swift
            let kimi = isAvailable(.kimi, defaults: defaults)
```

then after the `.pi` setter:

```swift
            setEnabledInternal(.kimi, enabled: kimi, defaults: defaults)
```

`isAvailable(_:defaults:)`:

```swift
        case .kimi:
            let custom = defaults.string(forKey: PreferencesKey.Paths.kimiSessionsRootOverride) ?? ""
            root = KimiSessionDiscovery(customRoot: custom.isEmpty ? nil : custom).sessionsRoot()
```

`binaryInstalled(for:)`:

```swift
        case .kimi:
            return binaryDetectedCached("kimi")
```

`storedBinaryPresence(for:defaults:)`:

```swift
        case .kimi:
            return defaults.object(forKey: PreferencesKey.kimiCLIAvailable) as? Bool
```

- [ ] **Step 2: Implement the indexer**

Create `AgentSessions/Services/KimiSessionIndexer.swift` as a copy of `AgentSessions/Services/PiSessionIndexer.swift` with these substitutions and no other behavioural change:

- `PiSessionIndexer` → `KimiSessionIndexer`
- `PiSessionDiscovery` → `KimiSessionDiscovery`
- `PiSessionParser` → `KimiSessionParser`
- `PreferencesKey.Paths.piSessionsRootOverride` → `PreferencesKey.Paths.kimiSessionsRootOverride`
- `AgentEnablement.isEnabled(.pi)` → `AgentEnablement.isEnabled(.kimi)`
- `source: .pi` → `source: .kimi`

The `parseLightweight` closure becomes:

```swift
                parseLightweight: { KimiSessionParser.parseFile(at: $0) },
```

and the full reload line becomes:

```swift
            let parsed = KimiSessionParser.parseFileFull(at: url, allowLargeFile: true) ?? existing
```

This duplication is deliberate: it is the established per-agent indexer pattern in this codebase. Do not refactor the ten existing indexers into a generic while adding the eleventh.

- [ ] **Step 3: Register and build**

```bash
ruby scripts/xcode_add_file.rb AgentSessions/Services/KimiSessionIndexer.swift
```

Run: `xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug build`
Expected: the only remaining errors are non-exhaustive switches in `UnifiedSessionIndexer.swift` and the view/service files listed in Task 7. `AgentEnablement.swift` must be clean.

- [ ] **Step 4: Commit**

```bash
git commit -- AgentSessions/Services/KimiSessionIndexer.swift AgentSessions/Services/AgentEnablement.swift AgentSessions.xcodeproj -m "feat(kimi): add Kimi session indexer and enablement detection"
```

---

### Task 6: Unified indexer integration

This is the highest-risk task in the plan. `UnifiedSessionIndexer.swift` has ~35 Pi touchpoints and several `combineLatest` chains already near Combine's arity limits. Work through it mechanically, one Pi reference at a time.

**Files:**
- Modify: `AgentSessions/Services/UnifiedSessionIndexer.swift`

**Interfaces:**
- Consumes: `KimiSessionIndexer` from Task 5.
- Produces: `UnifiedSessionIndexer.init(…, kimiIndexer: KimiSessionIndexer)` — a new trailing parameter. Every call site of this initializer must be updated in this task.

- [ ] **Step 1: Enumerate every site**

```bash
grep -n "\.pi\b\|piIndexer\|piAgentEnabled\|includePi\|piList\|piEnabled" AgentSessions/Services/UnifiedSessionIndexer.swift
```

Expected: ~35 lines. Each one needs a Kimi sibling. Work top to bottom and re-run this grep with `kimi` at the end to confirm parity of counts.

- [ ] **Step 2: Add the stored property, published flags, and init parameter**

Mirror each Pi declaration:

```swift
    private let kimi: KimiSessionIndexer
```
```swift
    @Published var includeKimi: Bool = UserDefaults.standard.object(forKey: "IncludeKimiSessions") as? Bool ?? true {
        didSet { UserDefaults.standard.set(includeKimi, forKey: "IncludeKimiSessions") }
    }
```
```swift
    @Published private(set) var kimiAgentEnabled: Bool = AgentEnablement.isEnabled(.kimi)
```

Add `kimiIndexer: KimiSessionIndexer` as the last init parameter and `self.kimi = kimiIndexer` beside `self.pi = piIndexer`.

- [ ] **Step 3: Extend the switch statements**

Every `switch source` in this file needs a `.kimi` arm mirroring `.pi`:

```swift
        case .kimi: return kimi.allSessions
```
```swift
        case .kimi: return kimiAgentEnabled && !kimi.isIndexing
```
```swift
        case .kimi: kimi.refresh(mode: mode, trigger: trigger, executionProfile: executionProfile)
```
```swift
        case .kimi: return kimi.isIndexing
```
```swift
        case .kimi:
            livePath = kimi.allSessions.first(where: { $0.id == context.sessionID })?.filePath
```

Add the focused-monitor capability entry mirroring `.pi`, using `KimiSessionIndexer.ReloadReason` and `indexer.kimi.reloadSession(...)`, and add `.kimi: defaultFocusedSessionRefreshIntervals` to the interval map.

- [ ] **Step 4: Extend the enablement struct and merge**

Add `let kimi: Bool` to the enablement struct, `kimi: false` to its default instance, `kimi: kimiEnabled` to its construction, and:

```swift
        if work.enablement.kimi { merged.append(contentsOf: work.kimiList) }
```

Add `effectiveKimi` alongside `effectivePi` in the filter predicate, extend the all-enabled short-circuit condition with `&& effectiveKimi`, and add:

```swift
                        (s.source == .kimi && effectiveKimi)
```

- [ ] **Step 5: Extend the Combine chains**

Add `.combineLatest(kimi.$allSessions)`, `.combineLatest(kimi.$isIndexing)`, `.combineLatest(kimi.$filesProcessed)`, `.combineLatest(kimi.$totalFiles)`, `.combineLatest(kimi.$isProcessingTranscripts)`, `.combineLatest(kimi.$indexingError)`, `.combineLatest(kimi.$launchPhase)`, and `.combineLatest($includeKimi)` to the corresponding existing chains, unpacking each new tuple element.

If a chain fails to type-check ("expression too complex" or an arity error), extract the offending chain into a `private func` returning the publisher rather than restructuring the whole pipeline.

Also add:

```swift
            snapshots.append(CoreProviderSnapshot(source: .kimi, enabled: kimiEnabled, indexing: kimiIndexing, processed: kimiProcessed, total: kimiTotal))
```
```swift
        phases[.kimi] = (kimiAgentEnabled && includeKimi) ? kimi.launchPhase : .ready
```
```swift
            .kimi: kimiAgentEnabled
```
```swift
        let c11 = AgentEnablement.isEnabled(.kimi, defaults: defaults)
```
```swift
            kimiAgentEnabled ? .kimi : nil
```

- [ ] **Step 6: Update every construction site**

```bash
grep -rn "UnifiedSessionIndexer(" --include="*.swift" AgentSessions AgentSessionsTests AgentSessionsLogicTests
```

Add `kimiIndexer: KimiSessionIndexer()` (or the test's existing indexer-construction idiom) to each hit.

- [ ] **Step 7: Build**

Run: `xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug build`
Expected: `UnifiedSessionIndexer.swift` compiles clean; remaining errors are only in the Task 7 view/service files.

- [ ] **Step 8: Commit**

```bash
git commit -- AgentSessions/Services/UnifiedSessionIndexer.swift AgentSessions AgentSessionsTests AgentSessionsLogicTests -m "feat(kimi): wire Kimi indexer into the unified session pipeline"
```

---

### Task 7: UI surfaces, colors, and remaining switches

**Files:**
- Modify: `AgentSessions/Services/TranscriptColorSystem.swift`
- Modify: `AgentSessions/Analytics/Utilities/AnalyticsColors.swift`
- Modify: `AgentSessions/Onboarding/Components/OnboardingPalette.swift`
- Modify: `AgentSessions/Onboarding/Components/OnboardingComponents.swift`
- Modify: `AgentSessions/Onboarding/Views/FirstRunSetupView.swift`
- Modify: `AgentSessions/Views/PreferencesView.swift`
- Modify: `AgentSessions/Views/UnifiedSessionsView.swift`
- Modify: `AgentSessions/Views/SessionTerminalView.swift`
- Modify: `AgentSessions/Search/SearchIngestService.swift`
- Modify: `AgentSessions/Services/SessionArchiveManager.swift`
- Modify: `AgentSessions/Services/AgentUpdateService.swift`

**Interfaces:**
- Consumes: `SessionSource.kimi`, `PreferencesKey.Paths.kimiSessionsRootOverride`.
- Produces: nothing new; this task only closes exhaustive switches.

- [ ] **Step 1: Let the compiler drive**

Run: `xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug build 2>&1 | grep -E "switch must be exhaustive|must be exhaustive"`

Expected: one error per file listed above.

- [ ] **Step 2: Close each switch by mirroring the `.pi` arm**

For every reported switch, add a `.kimi` arm that copies the `.pi` arm's shape and substitutes Kimi's identifiers. Per `agents.md`, use the shared spacing tokens already in each view — do not introduce new literals.

For the Preferences path override row in `PreferencesView.swift`, mirror the Pi row using `PreferencesKey.Paths.kimiSessionsRootOverride` and the label `Kimi Code`.

Pick a Kimi accent color distinct from the ten existing sources in all three palette files, and use the same value in all three.

- [ ] **Step 3: Build until clean**

Run: `xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug build`
Expected: BUILD SUCCEEDED, zero warnings introduced.

- [ ] **Step 4: Run the full suite**

Run: `./scripts/xcode_test_stable.sh`
Expected: all tests pass. The baseline as of the 2026-07-21 perf-program merge was 1,183 passing / 0 failing; the new Kimi tests add to that count. Any pre-existing failure must be reported, not silently accepted.

- [ ] **Step 5: Commit**

```bash
git commit -- AgentSessions -m "feat(kimi): add Kimi Code UI surfaces, colors, and preferences"
```

---

### Task 8: Resume support

**Files:**
- Create: `AgentSessions/Kimi/KimiCLIEnvironment.swift`
- Create: `AgentSessions/KimiResume/KimiResumeCommandBuilder.swift`
- Test: `AgentSessionsTests/KimiResumeCommandBuilderTests.swift`

**Interfaces:**
- Consumes: `Session` values produced by Task 4.
- Produces: `enum KimiResumeCommandBuilder` with `static func command(for session: Session) -> String?`.

Kimi Code's documented resume affordances are the `-c` flag (continue the most recent session) and the interactive `/sessions` picker. There is no verified `--resume <id>` flag at CLI 0.29.1, so this task builds a `cd`-then-`kimi -c` command and nothing more.

- [ ] **Step 1: Write the failing test**

Create `AgentSessionsTests/KimiResumeCommandBuilderTests.swift`:

```swift
import XCTest
@testable import AgentSessions

final class KimiResumeCommandBuilderTests: XCTestCase {
    private func session(cwd: String?) -> Session {
        Session(id: "sess-1", source: .kimi, startTime: nil, endTime: nil, model: nil,
                filePath: "/tmp/x/agents/main/wire.jsonl", eventCount: 0, events: [],
                cwd: cwd, repoName: nil, lightweightTitle: nil)
    }

    func testBuildsContinueCommandWithQuotedWorkingDirectory() {
        XCTAssertEqual(KimiResumeCommandBuilder.command(for: session(cwd: "/tmp/as agent/project")),
                       "cd '/tmp/as agent/project' && kimi -c")
    }

    func testReturnsNilWithoutWorkingDirectory() {
        XCTAssertNil(KimiResumeCommandBuilder.command(for: session(cwd: nil)))
    }

    func testEscapesSingleQuotesInPath() {
        XCTAssertEqual(KimiResumeCommandBuilder.command(for: session(cwd: "/tmp/o'brien")),
                       "cd '/tmp/o'\\''brien' && kimi -c")
    }
}
```

- [ ] **Step 2: Run and confirm failure**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/KimiResumeCommandBuilderTests`
Expected: compile failure — `cannot find 'KimiResumeCommandBuilder' in scope`.

- [ ] **Step 3: Implement**

Create `AgentSessions/Kimi/KimiCLIEnvironment.swift`:

```swift
import Foundation

enum KimiCLIEnvironment {
    static let binaryName = "kimi"

    static var isInstalled: Bool {
        AgentEnablement.binaryDetectedInPATH(binaryName)
    }
}
```

Create `AgentSessions/KimiResume/KimiResumeCommandBuilder.swift`:

```swift
import Foundation

/// Builds the shell command that reopens a Kimi Code session.
///
/// Kimi Code resumes by working directory: `kimi -c` continues the most recent
/// session for the current cwd. There is no verified `--resume <id>` flag at
/// CLI 0.29.1, so the session id is not passed through.
enum KimiResumeCommandBuilder {
    static func command(for session: Session) -> String? {
        guard let cwd = session.cwd ?? session.lightweightCwd, !cwd.isEmpty else { return nil }
        return "cd \(shellQuoted(cwd)) && \(KimiCLIEnvironment.binaryName) -c"
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
```

- [ ] **Step 4: Register and run**

```bash
ruby scripts/xcode_add_file.rb AgentSessions/Kimi/KimiCLIEnvironment.swift && ruby scripts/xcode_add_file.rb AgentSessions/KimiResume/KimiResumeCommandBuilder.swift && ruby scripts/xcode_add_file.rb AgentSessionsTests/KimiResumeCommandBuilderTests.swift
```

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/KimiResumeCommandBuilderTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Wire the copy-resume menu item**

In `AgentSessions/Views/SessionTerminalView.swift`, add the `.kimi` arm to the resume-command switch, calling `KimiResumeCommandBuilder.command(for:)` exactly as the `.pi` arm calls its builder.

Run: `xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git commit -- AgentSessions/Kimi AgentSessions/KimiResume AgentSessions/Views/SessionTerminalView.swift AgentSessionsTests/KimiResumeCommandBuilderTests.swift AgentSessions.xcodeproj -m "feat(kimi): add resume and copy-resume command support"
```

---

### Task 9: Monitoring and support documentation

**Files:**
- Modify: `docs/agent-support/agent-support-matrix.yml`
- Modify: `docs/agent-support/agent-support-ledger.yml`
- Modify: `docs/agent-support/public-agents.json`
- Modify: `docs/agent-support/agent-watch-config.json`
- Modify: `docs/agent-json-tracking.md`
- Modify: `README.md`

**Interfaces:**
- Consumes: the CLI version recorded in Task 1 Step 2; the fixtures from Task 1.
- Produces: `kimi_code` entries readable by `scripts/agent_watch.py`.

- [ ] **Step 1: Add the matrix entry**

In `docs/agent-support/agent-support-matrix.yml`, under `agents:`, add:

```yaml
  kimi_code:
    max_verified_version: "<version recorded in Task 1 Step 2>"
    version_field: "not_logged"
    evidence_fixtures:
      - "Resources/Fixtures/stage0/agents/kimi/small.jsonl"
      - "Resources/Fixtures/stage0/agents/kimi/state.json"
```

`version_field` is `not_logged` because `wire.jsonl` records `protocol_version` (the journal protocol, `1.5` at time of writing), not the CLI version. Treat a change in `protocol_version` as the drift signal.

Add a dated note to the `notes:` list recording: the tier-2 scope, the `~/.kimi-code/sessions/**/agents/main/wire.jsonl` layout, the `state.json` sidecar join, that `minidb` is an off-by-default derived read model and deliberately unread, and that Kimi Desktop shares the same home and is a surface label rather than a separate source.

- [ ] **Step 2: Add the ledger entry**

Append a new AS release entry to `docs/agent-support/agent-support-ledger.yml` with:

```yaml
          scope: "tier-2 local JSONL transcript discovery, browsing, search, Preferences controls, colors, resume/copy-resume commands, and weekly session-format monitoring"
```

- [ ] **Step 3: Add to the public agent list**

In `docs/agent-support/public-agents.json`, add to the `agents` array:

```json
    { "id": "kimi", "public_name": "Kimi Code" }
```

- [ ] **Step 4: Add to the watch config**

In `docs/agent-support/agent-watch-config.json`, add under `agents`:

```json
    "kimi": {
      "cadence": { "daily": false, "weekly": true },
      "installed_version_cmd": ["kimi", "--version"],
      "verified_version_source": "docs/agent-support/agent-support-matrix.yml#agents.kimi_code.max_verified_version",
      "upstream": [
        { "kind": "npm_latest", "package": "@moonshot-ai/kimi-code" }
      ],
      "risk_keywords": {
        "schema": ["session", "jsonl", "format", "schema", "transcript", "storage", "migration", "wire", "protocol_version"],
        "usage": ["usage", "token", "tokens", "limit", "quota"]
      },
      "weekly": {
        "local_schema": {
          "kind": "jsonl_newest",
          "roots": ["$KIMI_CODE_HOME", "~/.kimi-code"],
          "glob": "sessions/**/agents/main/wire.jsonl",
          "required_types": ["metadata", "context.append_message"],
          "max_lines": 2500
        },
        "freshness_window_days": 30
      }
    }
```

Note there is **no** `prebump` block. Prebump drivers are Python classes registered in `scripts/agent_watch_prebump_drivers.py` (`DRIVERS[...]`), and Kimi Code has no verified non-interactive one-shot mode at 0.29.1. Kimi is therefore monitored from real local sessions via the weekly `local_schema` contract only — the same posture Hermes and Cursor have held. Do not invent a `kimi_prompt` driver in this task; adding one is a follow-up gated on confirming a headless invocation.

Note also the matrix key is `kimi_code` while the watch-config key and `SessionSource` rawValue are `kimi`. That asymmetry matches the existing `codex_cli` / `codex` and `copilot_cli` / `copilot` pairs — keep it.

- [ ] **Step 5: Verify the weekly scan sees Kimi**

```bash
python3 scripts/agent_watch.py --mode weekly --agent kimi
```

Expected: a report containing a `kimi` entry with `matches_baseline: true`, empty `unknown_types`, and empty `unknown_keys`.

Because the weekly scan reads the real `~/.kimi-code` home, the Task 1 capture satisfies the freshness window. If the run reports `blocked_stale_sample`, re-run the Task 1 session to produce a session inside the 30-day window rather than editing the report or widening the window.

Per the 2026-07-17 finding recorded in the matrix notes, a green prebump is necessary but not sufficient for interactive-only event families — with no prebump at all here, the weekly real-session scan is the *only* drift signal for Kimi. Do not skip it.

- [ ] **Step 6: Update the tracking doc and README**

Add a dated verification record to `docs/agent-json-tracking.md` with the evidence paths and the `agent_watch` report path.

In `README.md`, add Kimi Code to the supported-agents list, labelled to match the tier-2 scope — session browsing and search, no usage/quota tracking.

- [ ] **Step 7: Commit**

```bash
git commit -- docs README.md -m "docs(agent-support): add Kimi Code tier-2 support records and monitoring"
```

---

## Out of Scope

Explicitly not built here, and not to be added opportunistically:

- Kimi Code plan quota/usage tracking (5-hour window, weekly limits, plan exhaustion). Requires a Kimi Code subscription to observe; no evidence is obtainable with an API key.
- Runway, Quota Meter, or Cockpit HUD integration for Kimi.
- Analytics/token accounting for Kimi sessions.
- A `minidb` reader.
- A separate Kimi Desktop source.
- Subagent hierarchy for `agents/<agentId>/wire.jsonl` siblings. Discovery deliberately excludes them; promoting them to a session tree is a follow-up once real multi-agent captures exist.
