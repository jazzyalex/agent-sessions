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
            ##"{"step_index":4,"source":"SYSTEM","type":"CHECKPOINT","status":"DONE","created_at":"2026-06-26T21:16:19Z","content":"# Resuming from a compaction"}"##,
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

    func testAntigravityParserDispatchesJSONLAndMarkdown() throws {
        let jsonl = writeTranscript([
            #"{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-06-26T21:16:16Z","content":"<USER_REQUEST>\nhello\n</USER_REQUEST>"}"#,
        ])
        XCTAssertNotNil(AntigravitySessionParser.parseFileFull(at: jsonl))

        let mdDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "/conv-md", isDirectory: true)
        try? FileManager.default.createDirectory(at: mdDir, withIntermediateDirectories: true)
        let md = mdDir.appendingPathComponent("task.md")
        try "# Title\n\nbody".write(to: md, atomically: true, encoding: .utf8)
        XCTAssertNotNil(AntigravitySessionParser.parseFileFull(at: md))
    }

    func testDiscoveryFindsNewCLITranscripts() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let cliRoot = home.appendingPathComponent(".gemini/antigravity-cli/brain", isDirectory: true)
        let logs = cliRoot.appendingPathComponent("c1/.system_generated/logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let t = logs.appendingPathComponent("transcript.jsonl")
        try #"{"type":"USER_INPUT","content":"<USER_REQUEST>\nhi\n</USER_REQUEST>"}"#.write(to: t, atomically: true, encoding: .utf8)

        let disco = AntigravitySessionDiscovery(cliRoot: cliRoot.path)
        XCTAssertTrue(disco.discoverSessionFiles().contains { $0.lastPathComponent == "transcript.jsonl" })
    }

    func testEventIDsAreUniqueInLongSessionWithToolCalls() throws {
        // Regression: tool-call ids must not collide with a later line's id. A tool call
        // on line 1 previously got id "<sid>-0100" (1*100+0), colliding with line 100.
        var lines: [String] = [
            #"{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-06-26T21:16:16Z","content":"<USER_REQUEST>\ngo\n</USER_REQUEST>"}"#,
            #"{"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-06-26T21:16:17Z","thinking":"t","tool_calls":[{"name":"list_dir","args":{"DirectoryPath":"\"/tmp\""}}]}"#,
        ]
        for i in 2..<160 {
            lines.append("{\"step_index\":\(i),\"source\":\"MODEL\",\"type\":\"RUN_COMMAND\",\"status\":\"DONE\",\"created_at\":\"2026-06-26T21:16:18Z\",\"content\":\"out\"}")
        }
        let url = writeTranscript(lines)
        guard let full = AntigravityTranscriptParser.parse(at: url, forcedID: "conv-x", includeEvents: true) else {
            return XCTFail("parse returned nil")
        }
        let ids = full.events.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "event IDs must be unique across line events and tool calls")
    }

    func testCodeActionAndSearchWebRenderAsToolResultsNotMeta() throws {
        // Both carry the same MODEL result envelope as RUN_COMMAND/VIEW_FILE, so they
        // must render as tool work. They previously fell through to `default:` and
        // showed up as system meta noise.
        let url = writeTranscript([
            #"{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-06-26T21:16:16Z","content":"<USER_REQUEST>\ngo\n</USER_REQUEST>"}"#,
            #"{"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-06-26T21:16:17Z","thinking":"t","tool_calls":[{"name":"write_file","args":{"TargetFile":"\"/tmp/repo/notes.md\""}}]}"#,
            #"{"step_index":2,"source":"MODEL","type":"CODE_ACTION","status":"DONE","created_at":"2026-06-26T21:16:18Z","content":"Created file file:///tmp/repo/notes.md with requested content."}"#,
            #"{"step_index":3,"source":"MODEL","type":"SEARCH_WEB","status":"DONE","created_at":"2026-06-26T21:16:19Z","content":"The search returned a summary."}"#,
            #"{"step_index":4,"source":"SYSTEM","type":"SYSTEM_MESSAGE","status":"DONE","created_at":"2026-06-26T21:16:20Z","content":"system note"}"#,
        ])
        guard let s = AntigravityTranscriptParser.parse(at: url, forcedID: "conv-1", includeEvents: true) else {
            return XCTFail("parse returned nil")
        }
        XCTAssertTrue(s.events.contains { $0.kind == .tool_result && ($0.toolOutput ?? "").contains("Created file") },
                      "CODE_ACTION must be a tool_result")
        XCTAssertTrue(s.events.contains { $0.kind == .tool_result && ($0.toolOutput ?? "").contains("search returned") },
                      "SEARCH_WEB must be a tool_result")
        // SYSTEM_MESSAGE is genuinely system-sourced, so it stays meta.
        XCTAssertTrue(s.events.contains { $0.kind == .meta && ($0.text ?? "").contains("system note") })
        XCTAssertFalse(s.events.contains { $0.kind == .meta && ($0.text ?? "").contains("Created file") })
    }

    func testTruncatedFieldsIsSurfacedRatherThanSilentlyDropped() throws {
        // The CLI clips content upstream; without a marker a partial transcript reads
        // as complete.
        let url = writeTranscript([
            #"{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-06-26T21:16:16Z","content":"<USER_REQUEST>\ngo\n</USER_REQUEST>"}"#,
            #"{"step_index":1,"source":"MODEL","type":"SEARCH_WEB","status":"DONE","created_at":"2026-06-26T21:16:17Z","content":"partial summary","truncated_fields":["content"]}"#,
            #"{"step_index":2,"source":"MODEL","type":"VIEW_FILE","status":"DONE","created_at":"2026-06-26T21:16:18Z","content":"whole file"}"#,
        ])
        guard let s = AntigravityTranscriptParser.parse(at: url, forcedID: "conv-1", includeEvents: true) else {
            return XCTFail("parse returned nil")
        }
        XCTAssertTrue(s.events.contains { ($0.toolOutput ?? "").contains("partial summary")
            && ($0.toolOutput ?? "").contains(AntigravityTranscriptParser.truncationMarker) })
        // An untruncated event must not be marked.
        XCTAssertTrue(s.events.contains { ($0.toolOutput ?? "") == "whole file" })
    }

    func testModelNameCapturesChangeNotJustInitialSelection() throws {
        let content = "<USER_REQUEST>\nhi\n</USER_REQUEST>\n<USER_SETTINGS_CHANGE>\nThe user changed setting `Model Selection` from Gemini 3.5 Flash to Gemini 4.0 Pro.\n</USER_SETTINGS_CHANGE>"
        XCTAssertEqual(AntigravityTranscriptParser.modelName(fromUserInput: content), "Gemini 4.0 Pro")
    }

    func testModelNameStopsAtTheEndOfTheSentence() {
        let content = "<USER_SETTINGS_CHANGE>\nThe user changed setting `Model Selection` from None to Gemini 3.5 Flash (Medium). No need to comment on this change if the user doesn't ask about it. If reporting what model you are, please use a human readable name instead of the exact string\n</USER_SETTINGS_CHANGE>"
        XCTAssertEqual(AntigravityTranscriptParser.modelName(fromUserInput: content),
                       "Gemini 3.5 Flash (Medium)")
    }

    func testModelNameKeepsVersionDotsAndHandlesClosingTag() {
        // The selection is read only from a <USER_SETTINGS_CHANGE> block.
        XCTAssertEqual(AntigravityTranscriptParser.modelName(
            fromUserInput: "<USER_SETTINGS_CHANGE>`Model Selection` from Gemini 3.5 Flash (Low) to Claude Sonnet 4.6 (Thinking).\n</USER_SETTINGS_CHANGE>"),
                       "Claude Sonnet 4.6 (Thinking)")
        XCTAssertEqual(AntigravityTranscriptParser.modelName(
            fromUserInput: "<USER_SETTINGS_CHANGE>`Model Selection` from None to Gemini 3.7 Flash (High)</USER_SETTINGS_CHANGE>"),
                       "Gemini 3.7 Flash (High)")
        XCTAssertNil(AntigravityTranscriptParser.modelName(fromUserInput: "<USER_REQUEST>hi</USER_REQUEST>"))
    }

    func testSessionModelIsTheLastSelectedModel() throws {
        let url = writeTranscript([
            #"{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-10-04T20:21:00Z","content":"<USER_REQUEST>\nGo.\n</USER_REQUEST>\n<USER_SETTINGS_CHANGE>\nThe user changed setting `Model Selection` from None to Gemini 3.5 Flash (Medium).\n</USER_SETTINGS_CHANGE>"}"#,
            #"{"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-10-04T20:21:10Z","content":"Done."}"#,
            #"{"step_index":2,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-10-04T20:22:00Z","content":"<USER_REQUEST>\nAgain.\n</USER_REQUEST>\n<USER_SETTINGS_CHANGE>\nThe user changed setting `Model Selection` from Gemini 3.5 Flash (Medium) to Claude Sonnet 4.6 (Thinking).\n</USER_SETTINGS_CHANGE>"}"#,
            #"{"step_index":3,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-10-04T20:23:00Z","content":"<USER_REQUEST>\nNo setting change here.\n</USER_REQUEST>"}"#,
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        guard let session = AntigravityTranscriptParser.parse(at: url, forcedID: nil, includeEvents: false) else {
            return XCTFail("parse returned nil")
        }
        XCTAssertEqual(session.model, "Claude Sonnet 4.6 (Thinking)")
    }

    /// User prose comes first in USER_INPUT content, so an unscoped match picks up a
    /// "Model Selection … to …" sentence the user typed instead of the real setting.
    func testModelNameIgnoresModelSelectionProseInTheUserRequest() {
        let content = "<USER_REQUEST>\nI moved Model Selection from Gemini 3.5 Flash (Medium) to Claude Sonnet 4.6 (Thinking). Please check the code.\n</USER_REQUEST>\n<USER_SETTINGS_CHANGE>\nThe user changed setting `Model Selection` from None to Gemini 3.5 Flash (Low).\n</USER_SETTINGS_CHANGE>"
        XCTAssertEqual(AntigravityTranscriptParser.modelName(fromUserInput: content), "Gemini 3.5 Flash (Low)")

        XCTAssertNil(AntigravityTranscriptParser.modelName(
            fromUserInput: "Fix the Model Selection from the dropdown to use the new API."))
        XCTAssertNil(AntigravityTranscriptParser.modelName(
            fromUserInput: "<USER_REQUEST>\nFix the Model Selection from the dropdown to use the new API.\n</USER_REQUEST>"))
    }

    func testModelNameStopsAtANewline() {
        let content = "<USER_SETTINGS_CHANGE>\nThe user changed setting `Model Selection` from None to Gemini 3.5 Flash (Medium)\nNo need to comment on this change if the user doesn't ask about it.\n</USER_SETTINGS_CHANGE>"
        XCTAssertEqual(AntigravityTranscriptParser.modelName(fromUserInput: content), "Gemini 3.5 Flash (Medium)")
    }

    func testModelNameReadsTheLastSettingsBlockAndAnUnclosedBlock() {
        let twoBlocks = "<USER_SETTINGS_CHANGE>\nThe user changed setting `Model Selection` from None to Gemini 3.5 Flash (Medium).\n</USER_SETTINGS_CHANGE>\n<USER_REQUEST>\nGo.\n</USER_REQUEST>\n<USER_SETTINGS_CHANGE>\nThe user changed setting `Model Selection` from Gemini 3.5 Flash (Medium) to Claude Sonnet 4.6 (Thinking).\n</USER_SETTINGS_CHANGE>"
        XCTAssertEqual(AntigravityTranscriptParser.modelName(fromUserInput: twoBlocks), "Claude Sonnet 4.6 (Thinking)")

        let unclosed = "<USER_REQUEST>\nGo.\n</USER_REQUEST>\n<USER_SETTINGS_CHANGE>\nThe user changed setting `Model Selection` from None to Gemini 3.7 Flash (High)."
        XCTAssertEqual(AntigravityTranscriptParser.modelName(fromUserInput: unclosed), "Gemini 3.7 Flash (High)")

        // The block must name the backticked setting.
        XCTAssertNil(AntigravityTranscriptParser.modelName(
            fromUserInput: "<USER_SETTINGS_CHANGE>\nThe user changed setting `Theme` from Light to Dark.\n</USER_SETTINGS_CHANGE>"))
    }

    func testSessionModelIsNotOverwrittenByModelSelectionProse() throws {
        let url = writeTranscript([
            #"{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-10-04T20:21:00Z","content":"<USER_REQUEST>\nGo.\n</USER_REQUEST>\n<USER_SETTINGS_CHANGE>\nThe user changed setting `Model Selection` from None to Gemini 3.5 Flash (Low).\n</USER_SETTINGS_CHANGE>"}"#,
            #"{"step_index":1,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-10-04T20:22:00Z","content":"<USER_REQUEST>\nFix the Model Selection from the dropdown to use the new API.\n</USER_REQUEST>"}"#,
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        guard let session = AntigravityTranscriptParser.parse(at: url, forcedID: nil, includeEvents: false) else {
            return XCTFail("parse returned nil")
        }
        XCTAssertEqual(session.model, "Gemini 3.5 Flash (Low)")
    }

    // MARK: - Desktop app (2.25.0+) transcripts under ~/.gemini/antigravity/brain

    private func makeHome() -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("AntigravityDesktop.\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return home
    }

    @discardableResult
    private func writeBrainTranscript(root: URL, conversation: String, from fixture: String = "agents/antigravity/desktop_small.jsonl",
                                      mtime: Date? = nil) throws -> URL {
        let logs = root.appendingPathComponent("\(conversation)/.system_generated/logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let url = logs.appendingPathComponent("transcript.jsonl")
        try Data(contentsOf: FixturePaths.stage0FixtureURL(fixture)).write(to: url)
        if let mtime {
            try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        }
        return url
    }

    /// The desktop app writes the CLI's transcript layout into the desktop brain root,
    /// with no markdown artifact beside it. The markdown-only scan of that root never
    /// looked inside `.system_generated`, so desktop sessions were not listed at all.
    func testDesktopBrainTranscriptWithoutArtifactsIsDiscovered() throws {
        let home = makeHome()
        let desktopRoot = home.appendingPathComponent(".gemini/antigravity/brain", isDirectory: true)
        let transcript = try writeBrainTranscript(root: desktopRoot, conversation: "107fd67f-desktop")
        let absentCLI = home.appendingPathComponent(".gemini/antigravity-cli/brain").path

        let snapshot = AntigravitySessionDiscovery(customRoot: desktopRoot.path, cliRoot: absentCLI).discoverSnapshot()

        XCTAssertEqual(snapshot.files.map { $0.resolvingSymlinksInPath().path },
                       [transcript.resolvingSymlinksInPath().path])
        XCTAssertTrue(snapshot.isAuthoritative(path: transcript.path))
    }

    /// A conversation with both a transcript and markdown artifacts is one session:
    /// the transcript holds the whole conversation, so the artifacts are not listed
    /// beside it. A conversation with artifacts only still lists them.
    func testDesktopTranscriptReplacesMarkdownArtifactsOfTheSameConversation() throws {
        let home = makeHome()
        let desktopRoot = home.appendingPathComponent(".gemini/antigravity/brain", isDirectory: true)
        try writeBrainTranscript(root: desktopRoot, conversation: "conv-both")
        let both = desktopRoot.appendingPathComponent("conv-both", isDirectory: true)
        try "# Task\n".write(to: both.appendingPathComponent("task.md"), atomically: true, encoding: .utf8)
        let mdOnly = desktopRoot.appendingPathComponent("conv-md-only", isDirectory: true)
        try FileManager.default.createDirectory(at: mdOnly, withIntermediateDirectories: true)
        try "# Walkthrough\n".write(to: mdOnly.appendingPathComponent("walkthrough.md"), atomically: true, encoding: .utf8)
        let absentCLI = home.appendingPathComponent(".gemini/antigravity-cli/brain").path

        let files = AntigravitySessionDiscovery(customRoot: desktopRoot.path, cliRoot: absentCLI).discoverSessionFiles()
        let names = files.map { "\($0.pathComponents.first { $0.hasPrefix("conv-") } ?? "?")/\($0.lastPathComponent)" }.sorted()

        XCTAssertEqual(names, ["conv-both/transcript.jsonl", "conv-md-only/walkthrough.md"])
    }

    /// Transcripts use the bare conversation id as the session id, so the same
    /// conversation in both brain roots must list once (the newer file), never as two
    /// sessions sharing one id.
    func testSameConversationInBothBrainRootsIsListedOnceNewestWins() throws {
        let home = makeHome()
        let desktopRoot = home.appendingPathComponent(".gemini/antigravity/brain", isDirectory: true)
        let cliRoot = home.appendingPathComponent(".gemini/antigravity-cli/brain", isDirectory: true)
        try writeBrainTranscript(root: desktopRoot, conversation: "shared-id", mtime: Date(timeIntervalSince1970: 1_000))
        let newer = try writeBrainTranscript(root: cliRoot, conversation: "shared-id", from: "agents/antigravity/cli_small.jsonl",
                                             mtime: Date(timeIntervalSince1970: 2_000))
        try writeBrainTranscript(root: cliRoot, conversation: "cli-only")

        let files = AntigravitySessionDiscovery(customRoot: desktopRoot.path, cliRoot: cliRoot.path).discoverSessionFiles()
        let shared = files.filter { $0.pathComponents.contains("shared-id") }

        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(shared.map { $0.resolvingSymlinksInPath().path }, [newer.resolvingSymlinksInPath().path])
    }

    /// Desktop tool results are `GENERIC` records (so are most CLI ones: run_command,
    /// view_file, replace_file_content). They rendered as system meta, so a tool-using
    /// session showed calls with no results. Each result is paired with its own call.
    func testDesktopFixtureParsesGenericToolResultsPairedWithTheirCalls() throws {
        let url = FixturePaths.stage0FixtureURL("agents/antigravity/desktop_small.jsonl")
        guard let s = AntigravityTranscriptParser.parse(at: url, forcedID: "desk-1", includeEvents: true) else {
            return XCTFail("parse returned nil")
        }
        XCTAssertEqual(s.model, "Gemini 3.8 Flash (High)")
        XCTAssertEqual(s.lightweightTitle,
                       "Use your tools to list the files in /tmp/desk-probe, then read a.txt there and say what it contains in one line.")
        XCTAssertEqual(s.eventCount, 6)
        XCTAssertEqual(s.events.filter { $0.kind == .tool_call }.map(\.toolName), ["run_command", "read_file"])
        let results = s.events.filter { $0.kind == .tool_result }
        XCTAssertEqual(results.map(\.toolName), ["run_command", "read_file"])
        XCTAssertTrue((results.last?.toolOutput ?? "").contains("probe file for agent session format check"))
        XCTAssertFalse(s.events.contains { $0.kind == .meta }, "no record in this session is system meta")
        XCTAssertTrue(s.events.contains { $0.kind == .assistant && ($0.text ?? "").contains("The directory contains") })
    }

    func testToolResultsPairWithCallsInOrderAndSystemRecordsStayMeta() throws {
        let url = writeTranscript([
            #"{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-10-21T18:36:32Z","content":"<USER_REQUEST>\ngo\n</USER_REQUEST>"}"#,
            #"{"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-10-21T18:36:33Z","tool_calls":[{"name":"grep_search","args":{}},{"name":"run_command","args":{}}]}"#,
            #"{"step_index":2,"source":"MODEL","type":"GREP_SEARCH","status":"DONE","created_at":"2026-10-21T18:36:34Z","content":"grep out"}"#,
            #"{"step_index":3,"source":"MODEL","type":"GENERIC","status":"ERROR","created_at":"2026-10-21T18:36:35Z","content":"Encountered error in step execution: denied","error":"denied"}"#,
            #"{"step_index":4,"source":"MODEL","type":"BROWSER_NAVIGATE","status":"DONE","created_at":"2026-10-21T18:36:36Z","content":"opened page"}"#,
            #"{"step_index":5,"source":"SYSTEM","type":"CHECKPOINT","status":"DONE","created_at":"2026-10-21T18:36:37Z","content":"checkpoint"}"#,
            #"{"step_index":6,"source":"SYSTEM","type":"FUTURE_SYSTEM_NOTE","status":"DONE","created_at":"2026-10-21T18:36:38Z","content":"note"}"#,
        ])
        guard let s = AntigravityTranscriptParser.parse(at: url, forcedID: "conv-1", includeEvents: true) else {
            return XCTFail("parse returned nil")
        }
        let results = s.events.filter { $0.kind == .tool_result }
        XCTAssertEqual(results.map(\.toolOutput), ["grep out", "Encountered error in step execution: denied", "opened page"])
        XCTAssertEqual(results.map(\.toolName), ["grep_search", "run_command", "run_command"],
                       "results pair with calls in order; an unmatched MODEL result keeps the last call name")
        XCTAssertEqual(s.events.filter { $0.kind == .meta }.map(\.text), ["checkpoint", "note"])
    }
}
