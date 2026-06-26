# Antigravity CLI JSONL Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore Antigravity support after `agy` moved session storage from markdown brain artifacts to JSONL transcripts, in both the macOS app and the format monitor.

**Architecture:** Add an isolated JSONL parser (`AntigravityTranscriptParser`) that `GeminiSessionParser` delegates to by file extension; extend `GeminiSessionDiscovery` to scan both the legacy markdown root and the new `antigravity-cli` JSONL root; update resume ID extraction for the deeper path; and repoint the monitor (config + prebump driver + capture) at the new JSONL store, reusing the existing generic `jsonl_newest` machinery.

**Tech Stack:** Swift (AppKit/Foundation, XCTest), Python 3 (agent_watch monitor), JSONL fixtures, Xcode project via `scripts/xcode_add_file.rb`.

## Global Constraints

- New Swift files MUST be registered in the Xcode project with `ruby scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessions <path> <group>`.
- Existing Antigravity code uses the `Gemini*` prefix — keep that naming.
- Legacy markdown discovery/parsing behavior MUST remain unchanged (dual support).
- New CLI store: `~/.gemini/antigravity-cli/brain/<id>/.system_generated/logs/transcript.jsonl`.
- JSONL discriminator is the top-level `type` field.
- Stage0 fixtures resolve from the repo working tree (`Resources/Fixtures/stage0/...`), not the app bundle — no bundle membership needed for fixtures.
- Fixtures follow the redaction guardrails: short placeholder text, keep schema shape, no secrets.
- Do NOT commit or push unless the user explicitly says so (repo policy); the `git commit` steps below are staged for the user's go-ahead.
- Verified version bump target: antigravity `1.0.9` → `1.0.12`, only after a fresh `agy -p` prebump matches the new baseline.
- `SessionEvent` init: `SessionEvent(id:timestamp:kind:role:text:toolName:toolInput:toolOutput:messageID:parentID:isDelta:rawJSON:)`.
- `Session` init: `Session(id:source:startTime:endTime:model:filePath:fileSizeBytes:eventCount:events:cwd:repoName:lightweightTitle:)`.
- `SessionEventKind` cases: `.user .assistant .tool_call .tool_result .error .meta`.

---

### Task 1: `AntigravityTranscriptParser` — JSONL → Session

**Files:**
- Create: `AgentSessions/Services/AntigravityTranscriptParser.swift`
- Test: `AgentSessionsTests/AntigravityTranscriptParserTests.swift`

**Interfaces:**
- Produces:
  - `enum AntigravityTranscriptParser`
  - `static func parse(at url: URL, forcedID: String?, includeEvents: Bool) -> Session?`
  - `static func unwrapUserRequest(_ content: String) -> String` (strips `<USER_REQUEST>…</USER_REQUEST>`, drops `<ADDITIONAL_METADATA>`/`<USER_SETTINGS_CHANGE>` blocks)
  - `static func modelName(fromUserInput content: String) -> String?` (parses the `USER_SETTINGS_CHANGE` "Model Selection … to <name>" phrase)

- [ ] **Step 1: Write the failing test**

```swift
// AgentSessionsTests/AntigravityTranscriptParserTests.swift
import XCTest
@testable import AgentSessions

final class AntigravityTranscriptParserTests: XCTestCase {
    private func writeTranscript(_ lines: [String]) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("conv-1/.system_generated/logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("transcript.jsonl")
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testParsesUserAssistantToolEvents() throws {
        let url = writeTranscript([
            #"{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-06-26T21:16:16Z","content":"<USER_REQUEST>\nlist the files\n</USER_REQUEST>\n<USER_SETTINGS_CHANGE>\nThe user changed setting `Model Selection` from None to Gemini 3.5 Flash (Medium).\n</USER_SETTINGS_CHANGE>"}"#,
            #"{"step_index":1,"source":"SYSTEM","type":"CONVERSATION_HISTORY","status":"DONE","created_at":"2026-06-26T21:16:16Z"}"#,
            #"{"step_index":2,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-06-26T21:16:17Z","thinking":"I will list the directory.","tool_calls":[{"name":"list_dir","args":{"DirectoryPath":"\"/tmp/repo\""}}]}"#,
            #"{"step_index":3,"source":"MODEL","type":"RUN_COMMAND","status":"DONE","created_at":"2026-06-26T21:16:18Z","content":"a.txt\nb.txt\n"}"#,
            #"{"step_index":4,"source":"SYSTEM","type":"CHECKPOINT","status":"DONE","created_at":"2026-06-26T21:16:19Z","content":"# Resuming from a compaction"}"#,
        ])

        guard let s = AntigravityTranscriptParser.parse(at: url, forcedID: nil, includeEvents: true) else {
            return XCTFail("parse returned nil")
        }
        XCTAssertEqual(s.source, .antigravity)
        XCTAssertEqual(s.id, "conv-1")
        XCTAssertTrue(s.events.contains { $0.kind == .user && ($0.text ?? "").contains("list the files") })
        XCTAssertTrue(s.events.contains { $0.kind == .assistant })
        XCTAssertTrue(s.events.contains { $0.kind == .tool_call && $0.toolName == "list_dir" })
        XCTAssertTrue(s.events.contains { $0.kind == .tool_result && ($0.toolOutput ?? "").contains("a.txt") })
        XCTAssertEqual(s.model, "Gemini 3.5 Flash (Medium)")
        XCTAssertEqual(s.lightweightTitle, "list the files")
        XCTAssertFalse(s.events.contains { ($0.text ?? "").contains("<USER_REQUEST>") })
    }

    func testPreviewParseHasEmptyEventsButCount() throws {
        let url = writeTranscript([
            #"{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-06-26T21:16:16Z","content":"<USER_REQUEST>\nhi\n</USER_REQUEST>"}"#,
        ])
        guard let s = AntigravityTranscriptParser.parse(at: url, forcedID: nil, includeEvents: false) else {
            return XCTFail("preview parse returned nil")
        }
        XCTAssertTrue(s.events.isEmpty)
        XCTAssertGreaterThan(s.eventCount, 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/AntigravityTranscriptParserTests`
Expected: FAIL/compile error — `AntigravityTranscriptParser` undefined.

- [ ] **Step 3: Write minimal implementation**

```swift
// AgentSessions/Services/AntigravityTranscriptParser.swift
import Foundation
import CryptoKit

/// Parser for Antigravity CLI JSONL transcripts.
/// Layout: ~/.gemini/antigravity-cli/brain/<id>/.system_generated/logs/transcript.jsonl
enum AntigravityTranscriptParser {
    static func parse(at url: URL, forcedID: String?, includeEvents: Bool) -> Session? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard !lines.isEmpty else { return nil }

        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let size = (attrs[.size] as? NSNumber)?.intValue ?? -1
        let mtime = (attrs[.modificationDate] as? Date) ?? Date()
        let ctime = (attrs[.creationDate] as? Date) ?? mtime
        let sid = forcedID ?? conversationID(for: url) ?? sha256(path: url.path)

        let iso = ISO8601DateFormatter()
        var events: [SessionEvent] = []
        var firstUserText: String? = nil
        var model: String? = nil
        var lastToolName: String? = nil
        var firstDate: Date? = nil
        var lastDate: Date? = nil
        var count = 0

        for (idx, line) in lines.enumerated() {
            guard let data = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let type = obj["type"] as? String else { continue }
            count += 1
            let ts = (obj["created_at"] as? String).flatMap { iso.date(from: $0) }
            if let ts { if firstDate == nil { firstDate = ts }; lastDate = ts }
            let content = obj["content"] as? String
            let raw = line

            switch type {
            case "USER_INPUT":
                let unwrapped = unwrapUserRequest(content ?? "")
                if firstUserText == nil { firstUserText = unwrapped }
                if model == nil { model = modelName(fromUserInput: content ?? "") }
                if includeEvents {
                    events.append(makeEvent(sid, idx, ts, .user, "user", unwrapped, nil, nil, nil, raw))
                }
            case "PLANNER_RESPONSE":
                if includeEvents {
                    let thinking = obj["thinking"] as? String
                    let assistantText = thinking ?? ""
                    events.append(makeEvent(sid, idx, ts, .assistant, "assistant", assistantText, nil, nil, nil, raw))
                    if let calls = obj["tool_calls"] as? [[String: Any]] {
                        for (ci, call) in calls.enumerated() {
                            let name = call["name"] as? String
                            lastToolName = name
                            let input = (call["args"] as? [String: Any]).map {
                                (try? JSONSerialization.data(withJSONObject: $0)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                            }
                            events.append(makeEvent(sid, idx * 100 + ci, ts, .tool_call, "assistant", nil, name, input, nil, raw))
                        }
                    }
                }
            case "RUN_COMMAND", "VIEW_FILE", "LIST_DIRECTORY":
                if includeEvents {
                    events.append(makeEvent(sid, idx, ts, .tool_result, "tool", nil, lastToolName, nil, content, raw))
                }
            default: // CHECKPOINT, CONVERSATION_HISTORY, unknown
                if includeEvents {
                    events.append(makeEvent(sid, idx, ts, .meta, "system", content, nil, nil, nil, raw))
                }
            }
        }

        let title = firstUserText?.split(separator: "\n").first.map(String.init)
            ?? url.deletingLastPathComponent().lastPathComponent

        return Session(id: sid,
                       source: .antigravity,
                       startTime: firstDate ?? ctime,
                       endTime: lastDate ?? mtime,
                       model: model,
                       filePath: url.path,
                       fileSizeBytes: size >= 0 ? size : nil,
                       eventCount: count,
                       events: includeEvents ? events : [],
                       cwd: nil,
                       repoName: nil,
                       lightweightTitle: title)
    }

    static func unwrapUserRequest(_ content: String) -> String {
        // Prefer the inside of <USER_REQUEST>…</USER_REQUEST>.
        if let r = content.range(of: "<USER_REQUEST>"),
           let e = content.range(of: "</USER_REQUEST>") {
            return String(content[r.upperBound..<e.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Otherwise drop any metadata blocks and return the remainder.
        var out = content
        for tag in ["<ADDITIONAL_METADATA>", "<USER_SETTINGS_CHANGE>"] {
            if let r = out.range(of: tag) { out = String(out[..<r.lowerBound]) }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func modelName(fromUserInput content: String) -> String? {
        guard let r = content.range(of: "from None to "),
              let line = content[r.upperBound...].split(separator: "\n").first else { return nil }
        var name = String(line).trimmingCharacters(in: .whitespaces)
        if name.hasSuffix(".") { name.removeLast() }
        return name.isEmpty ? nil : name
    }

    static func conversationID(for url: URL) -> String? {
        // .../brain/<id>/.system_generated/logs/transcript.jsonl  → <id>
        let comps = url.pathComponents
        if let i = comps.firstIndex(of: "brain"), i + 1 < comps.count {
            return comps[i + 1]
        }
        return nil
    }

    private static func makeEvent(_ sid: String, _ idx: Int, _ ts: Date?, _ kind: SessionEventKind,
                                  _ role: String, _ text: String?, _ tool: String?, _ input: String?,
                                  _ output: String?, _ raw: String) -> SessionEvent {
        SessionEvent(id: "\(sid)-\(String(format: "%04d", idx))", timestamp: ts, kind: kind, role: role,
                     text: text, toolName: tool, toolInput: input, toolOutput: output,
                     messageID: nil, parentID: nil, isDelta: false, rawJSON: raw)
    }

    private static func sha256(path: String) -> String {
        SHA256.hash(data: Data(path.utf8)).compactMap { String(format: "%02x", $0) }.joined()
    }
}
```

- [ ] **Step 4: Register the file in Xcode and run the test**

Run:
```bash
ruby scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessions AgentSessions/Services/AntigravityTranscriptParser.swift Services
ruby scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessionsTests AgentSessionsTests/AntigravityTranscriptParserTests.swift AgentSessionsTests
./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/AntigravityTranscriptParserTests
```
Expected: PASS (both tests).

- [ ] **Step 5: Commit** (await user go-ahead per repo policy)

```bash
git add AgentSessions/Services/AntigravityTranscriptParser.swift AgentSessionsTests/AntigravityTranscriptParserTests.swift AgentSessions.xcodeproj/project.pbxproj
git commit -m "feat(antigravity): parse antigravity-cli JSONL transcripts"
```

---

### Task 2: Dispatch in `GeminiSessionParser` by file type

**Files:**
- Modify: `AgentSessions/Services/GeminiSessionParser.swift:7-16`
- Test: `AgentSessionsTests/AntigravityTranscriptParserTests.swift` (add a dispatch case)

**Interfaces:**
- Consumes: `AntigravityTranscriptParser.parse(at:forcedID:includeEvents:)`
- Produces: `GeminiSessionParser.parseFile(at:forcedID:)` / `parseFileFull(at:forcedID:)` now accept `.jsonl` transcripts as well as `.md`.

- [ ] **Step 1: Write the failing test** (append to `AntigravityTranscriptParserTests`)

```swift
    func testGeminiParserDispatchesJSONLAndMarkdown() throws {
        let jsonl = writeTranscript([
            #"{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-06-26T21:16:16Z","content":"<USER_REQUEST>\nhello\n</USER_REQUEST>"}"#,
        ])
        XCTAssertNotNil(GeminiSessionParser.parseFileFull(at: jsonl))

        let mdDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "/conv-md", isDirectory: true)
        try? FileManager.default.createDirectory(at: mdDir, withIntermediateDirectories: true)
        let md = mdDir.appendingPathComponent("task.md")
        try "# Title\n\nbody".write(to: md, atomically: true, encoding: .utf8)
        XCTAssertNotNil(GeminiSessionParser.parseFileFull(at: md))
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/AntigravityTranscriptParserTests/testGeminiParserDispatchesJSONLAndMarkdown`
Expected: FAIL — JSONL returns nil (current guard rejects non-`.md`).

- [ ] **Step 3: Implement the dispatch** — replace lines 7-16 of `GeminiSessionParser.swift`

```swift
    /// Preview-only parse for list indexing. Builds a lightweight session with empty events.
    static func parseFile(at url: URL, forcedID: String? = nil) -> Session? {
        switch url.pathExtension.lowercased() {
        case "md":
            return parseAntigravityMarkdown(at: url, forcedID: forcedID, includeEvents: false)
        case "jsonl":
            return AntigravityTranscriptParser.parse(at: url, forcedID: forcedID, includeEvents: false)
        default:
            return nil
        }
    }

    /// Full parse that normalizes an Antigravity artifact into transcript events.
    static func parseFileFull(at url: URL, forcedID: String? = nil) -> Session? {
        switch url.pathExtension.lowercased() {
        case "md":
            return parseAntigravityMarkdown(at: url, forcedID: forcedID, includeEvents: true)
        case "jsonl":
            return AntigravityTranscriptParser.parse(at: url, forcedID: forcedID, includeEvents: true)
        default:
            return nil
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/AntigravityTranscriptParserTests`
Expected: PASS (all tests).

- [ ] **Step 5: Commit** (await user go-ahead)

```bash
git add AgentSessions/Services/GeminiSessionParser.swift AgentSessionsTests/AntigravityTranscriptParserTests.swift
git commit -m "feat(antigravity): dispatch parser by file type (jsonl + md)"
```

---

### Task 3: Dual-root discovery in `GeminiSessionDiscovery`

**Files:**
- Modify: `AgentSessions/Services/GeminiSessionDiscovery.swift`
- Test: `AgentSessionsTests/AntigravityTranscriptParserTests.swift` (discovery case)

**Interfaces:**
- Produces: `GeminiSessionDiscovery.discoverSessionFiles()` returns both legacy `*.md` and new `transcript.jsonl` URLs, sorted by mtime desc.

- [ ] **Step 1: Write the failing test**

```swift
    func testDiscoveryFindsNewCLITranscripts() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cliRoot = home.appendingPathComponent(".gemini/antigravity-cli/brain", isDirectory: true)
        let logs = cliRoot.appendingPathComponent("c1/.system_generated/logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let t = logs.appendingPathComponent("transcript.jsonl")
        try #"{"type":"USER_INPUT","content":"<USER_REQUEST>\nhi\n</USER_REQUEST>"}"#.write(to: t, atomically: true, encoding: .utf8)

        let disco = GeminiSessionDiscovery(cliRoot: cliRoot.path)
        XCTAssertTrue(disco.discoverSessionFiles().contains { $0.lastPathComponent == "transcript.jsonl" })
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/AntigravityTranscriptParserTests/testDiscoveryFindsNewCLITranscripts`
Expected: FAIL — `GeminiSessionDiscovery` has no `cliRoot:` init and never scans the JSONL root.

- [ ] **Step 3: Implement dual-root scanning** — modify `GeminiSessionDiscovery.swift`

Add a CLI root and merge results. Change the initializer and `discoverSessionFiles()`:

```swift
final class GeminiSessionDiscovery: SessionDiscovery {
    private let customRoot: String?
    private let cliRoot: String?

    init(customRoot: String? = nil, cliRoot: String? = nil) {
        self.customRoot = customRoot
        self.cliRoot = cliRoot
    }

    func sessionsRoot() -> URL {
        if let custom = customRoot, !custom.isEmpty { return URL(fileURLWithPath: custom) }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".gemini/antigravity/brain")
    }

    private func cliSessionsRoot() -> URL {
        if let c = cliRoot, !c.isEmpty { return URL(fileURLWithPath: c) }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".gemini/antigravity-cli/brain")
    }

    func discoverSessionFiles() -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        out.append(contentsOf: scanMarkdown(root: sessionsRoot(), fm: fm))
        out.append(contentsOf: scanCLITranscripts(root: cliSessionsRoot(), fm: fm))
        out.sort { mtime($0) > mtime($1) }
        return out
    }

    private func mtime(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private func scanMarkdown(root: URL, fm: FileManager) -> [URL] {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue,
              let conversations = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        var out: [URL] = []
        for conversation in conversations {
            guard (try? conversation.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let files = try? fm.contentsOfDirectory(at: conversation, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { continue }
            out.append(contentsOf: files.filter { $0.pathExtension.lowercased() == "md" })
        }
        return out
    }

    private func scanCLITranscripts(root: URL, fm: FileManager) -> [URL] {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue,
              let conversations = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        var out: [URL] = []
        for conversation in conversations {
            guard (try? conversation.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let t = conversation.appendingPathComponent(".system_generated/logs/transcript.jsonl")
            if fm.fileExists(atPath: t.path) { out.append(t) }
        }
        return out
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/AntigravityTranscriptParserTests`
Expected: PASS.

- [ ] **Step 5: Update prefs copy + commit** (await user go-ahead)

In `AgentSessions/Views/Preferences/PreferencesView+CLI.swift:468`, update the help text from `Default: ~/.gemini/antigravity/brain` to mention both roots (`~/.gemini/antigravity/brain` and `~/.gemini/antigravity-cli/brain`). No new picker required.

```bash
git add AgentSessions/Services/GeminiSessionDiscovery.swift AgentSessions/Views/Preferences/PreferencesView+CLI.swift AgentSessionsTests/AntigravityTranscriptParserTests.swift
git commit -m "feat(antigravity): discover antigravity-cli JSONL transcripts alongside legacy markdown"
```

---

### Task 4: Resume ID extraction for the nested path

**Files:**
- Modify: `AgentSessions/GeminiResume/GeminiResumeTypes.swift:32-35`
- Test: `AgentSessionsTests/GeminiResumeTypesTests.swift` (create)

**Interfaces:**
- Consumes: nothing new.
- Produces: `GeminiSessionIDHelper.conversationID(fromArtifactURL:)` returns `<id>` for both `brain/<id>/x.md` and `brain/<id>/.system_generated/logs/transcript.jsonl`.

- [ ] **Step 1: Write the failing test**

```swift
// AgentSessionsTests/GeminiResumeTypesTests.swift
import XCTest
@testable import AgentSessions

final class GeminiResumeTypesTests: XCTestCase {
    func testConversationIDFromNewNestedPath() {
        let url = URL(fileURLWithPath: "/h/.gemini/antigravity-cli/brain/abc-123/.system_generated/logs/transcript.jsonl")
        XCTAssertEqual(GeminiSessionIDHelper.conversationID(fromArtifactURL: url), "abc-123")
    }
    func testConversationIDFromLegacyMarkdownPath() {
        let url = URL(fileURLWithPath: "/h/.gemini/antigravity/brain/def-456/task.md")
        XCTAssertEqual(GeminiSessionIDHelper.conversationID(fromArtifactURL: url), "def-456")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ruby scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessionsTests AgentSessionsTests/GeminiResumeTypesTests.swift AgentSessionsTests && ./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/GeminiResumeTypesTests`
Expected: FAIL — nested path returns `logs`, not `abc-123`.

- [ ] **Step 3: Implement path-aware extraction** — replace `conversationID(fromArtifactURL:)`

```swift
    static func conversationID(fromArtifactURL url: URL) -> String? {
        let comps = url.pathComponents
        if let i = comps.firstIndex(of: "brain"), i + 1 < comps.count {
            let id = comps[i + 1].trimmingCharacters(in: .whitespacesAndNewlines)
            return id.isEmpty ? nil : id
        }
        let id = url.deletingLastPathComponent().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/GeminiResumeTypesTests`
Expected: PASS.

- [ ] **Step 5: Commit** (await user go-ahead)

```bash
git add AgentSessions/GeminiResume/GeminiResumeTypes.swift AgentSessionsTests/GeminiResumeTypesTests.swift AgentSessions.xcodeproj/project.pbxproj
git commit -m "fix(antigravity): extract conversation id from nested cli transcript path"
```

---

### Task 5: Stage0 fixtures + golden test + matrix evidence

**Files:**
- Create: `Resources/Fixtures/stage0/agents/antigravity/cli_small.jsonl`
- Create: `Resources/Fixtures/stage0/agents/antigravity/cli_schema_drift.jsonl`
- Modify: `AgentSessionsTests/Stage0GoldenFixturesTests.swift`
- Modify: `docs/agent-support/agent-support-matrix.yml` (antigravity `evidence_fixtures`)

**Interfaces:**
- Consumes: `GeminiSessionParser.parseFileFull(at:)`, `FixturePaths.stage0FixtureURL(_:)`.

- [ ] **Step 1: Create the fixtures** (redacted, all observed types)

`Resources/Fixtures/stage0/agents/antigravity/cli_small.jsonl`:
```
{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-06-26T21:16:16Z","content":"<USER_REQUEST>\nList the files.\n</USER_REQUEST>\n<USER_SETTINGS_CHANGE>\nThe user changed setting `Model Selection` from None to Gemini 3.5 Flash (Medium).\n</USER_SETTINGS_CHANGE>"}
{"step_index":1,"source":"SYSTEM","type":"CONVERSATION_HISTORY","status":"DONE","created_at":"2026-06-26T21:16:16Z"}
{"step_index":2,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-06-26T21:16:17Z","thinking":"Listing the directory.","tool_calls":[{"name":"list_dir","args":{"DirectoryPath":"\"/tmp/repo\"","toolSummary":"\"Listing contents\""}}]}
{"step_index":3,"source":"MODEL","type":"LIST_DIRECTORY","status":"DONE","created_at":"2026-06-26T21:16:18Z","content":"{\"name\":\"a.txt\"}\n{\"name\":\"b.txt\"}\n"}
{"step_index":4,"source":"MODEL","type":"VIEW_FILE","status":"DONE","created_at":"2026-06-26T21:16:19Z","content":"File Path: `file:///tmp/repo/a.txt`\n1: hello\n"}
{"step_index":5,"source":"MODEL","type":"RUN_COMMAND","status":"DONE","created_at":"2026-06-26T21:16:20Z","content":"The command completed successfully.\nOutput:\na.txt\nb.txt\n"}
{"step_index":6,"source":"SYSTEM","type":"CHECKPOINT","status":"DONE","created_at":"2026-06-26T21:16:21Z","content":"# Resuming from a compaction"}
```

`Resources/Fixtures/stage0/agents/antigravity/cli_schema_drift.jsonl` (adds a hypothetical new type + key for the drift detector):
```
{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-06-26T21:16:16Z","content":"<USER_REQUEST>\nGo\n</USER_REQUEST>","promptVariant":"experimental"}
{"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-06-26T21:16:17Z","thinking":"...","tool_calls":[],"telemetry":{"latencyMs":12}}
{"step_index":2,"source":"MODEL","type":"BROWSER_NAVIGATE","status":"DONE","created_at":"2026-06-26T21:16:18Z","content":"opened https://example.com"}
```

- [ ] **Step 2: Write the failing golden test** — add to `Stage0GoldenFixturesTests.swift`

```swift
    func testAntigravityCLITranscriptFixtureParses() throws {
        let url = FixturePaths.stage0FixtureURL("agents/antigravity/cli_small.jsonl")
        guard let preview = GeminiSessionParser.parseFile(at: url) else { return XCTFail("preview nil") }
        XCTAssertEqual(preview.source, .antigravity)
        XCTAssertTrue(preview.events.isEmpty)
        XCTAssertGreaterThan(preview.eventCount, 0)

        guard let full = GeminiSessionParser.parseFileFull(at: url) else { return XCTFail("full nil") }
        XCTAssertEqual(full.source, .antigravity)
        XCTAssertTrue(full.events.contains { $0.kind == .user })
        XCTAssertTrue(full.events.contains { $0.kind == .tool_call && $0.toolName == "list_dir" })
        XCTAssertTrue(full.events.contains { $0.kind == .tool_result })
        XCTAssertEqual(full.model, "Gemini 3.5 Flash (Medium)")

        // Legacy markdown still parses.
        let md = FixturePaths.stage0FixtureURL("agents/antigravity/small.md")
        XCTAssertNotNil(GeminiSessionParser.parseFileFull(at: md))
    }
```

- [ ] **Step 3: Run test to verify it fails, then passes**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/Stage0GoldenFixturesTests/testAntigravityCLITranscriptFixtureParses`
Expected: PASS once Tasks 1-2 are merged and the fixtures exist (run before fixtures exist to confirm it fails on missing file).

- [ ] **Step 4: Register fixtures in the matrix** — edit `docs/agent-support/agent-support-matrix.yml` antigravity block

```yaml
  antigravity:
    max_verified_version: "1.0.9"
    version_field: "not_logged"
    evidence_fixtures:
      - "Resources/Fixtures/stage0/agents/antigravity/small.md"
      - "Resources/Fixtures/stage0/agents/antigravity/cli_small.jsonl"
      - "Resources/Fixtures/stage0/agents/antigravity/cli_schema_drift.jsonl"
```

- [ ] **Step 5: Commit** (await user go-ahead)

```bash
git add Resources/Fixtures/stage0/agents/antigravity/cli_small.jsonl Resources/Fixtures/stage0/agents/antigravity/cli_schema_drift.jsonl AgentSessionsTests/Stage0GoldenFixturesTests.swift docs/agent-support/agent-support-matrix.yml
git commit -m "test(antigravity): add cli JSONL fixtures and golden coverage"
```

---

### Task 6: Monitor config → `jsonl_newest` + capture update

**Files:**
- Modify: `docs/agent-support/agent-watch-config.json` (antigravity `weekly.local_schema`, `discovery_path_contract`, `risk_keywords`)
- Modify: `scripts/capture_latest_agent_sessions.py:69-89`

**Interfaces:**
- Consumes: existing `jsonl_newest` kind (`_jsonl_schema_fingerprint`, buckets by `type`).

- [ ] **Step 1: Repoint the weekly discovery** — set antigravity `weekly.local_schema`

```json
"local_schema": {
  "kind": "jsonl_newest",
  "roots": ["~/.gemini/antigravity-cli/brain"],
  "glob": "*/.system_generated/logs/transcript.jsonl",
  "max_lines": 2500
}
```

And update `discovery_path_contract.patterns` to:
```json
["/\\.gemini/antigravity-cli/brain/[^/]+/\\.system_generated/logs/transcript\\.jsonl$"]
```
Add `"transcript.jsonl"` and `"jsonl"` to `risk_keywords.schema`.

- [ ] **Step 2: Update the capture script** — `capture_antigravity` in `scripts/capture_latest_agent_sessions.py`

```python
def capture_antigravity(dest_root: Path) -> list[CaptureResult]:
    brain_root = Path.home() / ".gemini" / "antigravity-cli" / "brain"
    if not brain_root.exists():
        return []
    candidates = [p for p in brain_root.glob("*/.system_generated/logs/transcript.jsonl") if p.is_file()]
    if not candidates:
        return []
    src = max(candidates, key=lambda p: p.stat().st_mtime)
    out_dir = dest_root / "antigravity"
    out_dir.mkdir(parents=True, exist_ok=True)
    dst = out_dir / f"{src.parent.parent.parent.name}.transcript.jsonl"
    shutil.copy2(src, dst)
    return [CaptureResult(agent="antigravity", source=src, destination=dst)]
```

- [ ] **Step 3: Run the weekly scan to verify discovery resolves**

Run: `./scripts/agent_watch.py --mode weekly 2>&1 | grep antigravity`
Expected: antigravity line no longer `blocked_stale_sample` for path reasons; the newest JSONL transcript is fingerprinted (`stale=false` if a fresh `agy` session exists).

- [ ] **Step 4: Commit** (await user go-ahead)

```bash
git add docs/agent-support/agent-watch-config.json scripts/capture_latest_agent_sessions.py
git commit -m "feat(monitor): track antigravity-cli JSONL transcripts via jsonl_newest"
```

---

### Task 7: Prebump driver → JSONL path, verify, bump verified version

**Files:**
- Modify: `scripts/agent_watch_prebump_drivers.py:436-477`
- Modify: `docs/agent-support/agent-watch-config.json` (antigravity `prebump.discover_session`)
- Modify: `docs/agent-support/agent-support-matrix.yml`, `agent-support-ledger.yml`, `docs/agent-json-tracking.md`
- Test: `scripts/tests/test_prebump_driver_antigravity.py`

**Interfaces:**
- Consumes: the updated discovery contract.

- [ ] **Step 1: Update the driver** — `AntigravityPrintDriver.run` in `agent_watch_prebump_drivers.py`

Change the brain root and the artifact glob:
```python
        brain_root = session_home / ".gemini" / "antigravity-cli" / "brain"
        brain_root.mkdir(parents=True, exist_ok=True)
```
```python
        newest = _newest_matching_after_with_text(
            brain_root, ("*/.system_generated/logs/transcript.jsonl",), run_started, marker
        )
```
Update the failure label string from `antigravity_no_brain_artifact` to `antigravity_no_transcript_artifact` (and the matching assertion in `scripts/tests/test_prebump_driver_antigravity.py`).

- [ ] **Step 2: Update prebump discover_session contract** — antigravity `prebump.discover_session`

```json
"discover_session": {
  "kind": "jsonl_newest",
  "roots": [".gemini/antigravity-cli/brain"],
  "globs": ["*/.system_generated/logs/transcript.jsonl"],
  "required_types": []
}
```

- [ ] **Step 3: Run the prebump test, then a live prebump**

Run:
```bash
python3 -m pytest scripts/tests/test_prebump_driver_antigravity.py -q
./scripts/agent_watch.py --mode prebump --agent antigravity --allow-real-home 2>&1 | tail -5
```
Expected: pytest PASS; prebump `antigravity: ... ok=True fresh_matches_baseline=True`.

- [ ] **Step 4: Bump verified version after green prebump**

Set antigravity `max_verified_version` `1.0.9` → `1.0.12` in `agent-support-matrix.yml`; update the antigravity block in the current `agent-support-ledger.yml` entry (version + evidence = the new prebump + weekly report paths); add a 2026-06-26 line under "Upstream Version Check Log" in `docs/agent-json-tracking.md` describing the markdown→JSONL migration, app+monitor changes, and that `agy -p` now produces headless evidence.

- [ ] **Step 5: Final verification + commit** (await user go-ahead)

Run:
```bash
./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/Stage0GoldenFixturesTests
./scripts/agent_watch.py --mode weekly 2>&1 | grep antigravity
```
Expected: golden tests PASS; antigravity weekly verdict `supports_latest` or `supports_installed_only` with `matches_baseline=True`, severity ≤ low.

```bash
git add scripts/agent_watch_prebump_drivers.py scripts/tests/test_prebump_driver_antigravity.py docs/agent-support/agent-watch-config.json docs/agent-support/agent-support-matrix.yml docs/agent-support/agent-support-ledger.yml docs/agent-json-tracking.md
git commit -m "feat(antigravity): verify 1.0.12 via antigravity-cli JSONL prebump"
```

---

## Self-Review Notes

- **Spec coverage:** dual-root discovery (Task 3), structured JSONL parser with the full event-mapping table (Task 1), type dispatch (Task 2), resume ID (Task 4), fixtures + version record (Tasks 5, 7), monitor contract + fingerprint (Task 6, reusing `jsonl_newest`), prebump driver (Task 7), testing across all tasks. Non-goals (SQLite, UI redesign, legacy parser changes) respected.
- **Refinement vs spec:** spec §4 proposed a new `_antigravity_cli_transcript_schema_fingerprint`; the plan reuses the existing generic `jsonl_newest` / `_jsonl_schema_fingerprint` (buckets by `type`) instead — same result, less code (DRY).
- **Type consistency:** `parse(at:forcedID:includeEvents:)`, `conversationID(for:)`/`conversationID(fromArtifactURL:)`, `GeminiSessionDiscovery(customRoot:cliRoot:)`, and the `SessionEvent`/`Session` inits match across tasks.
- **Naming note:** driver failure label renamed `antigravity_no_brain_artifact` → `antigravity_no_transcript_artifact`; its test assertion is updated in the same task (Task 7 Step 1).
