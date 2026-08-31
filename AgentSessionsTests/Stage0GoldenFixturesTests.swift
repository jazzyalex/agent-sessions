import XCTest
@testable import AgentSessions

final class Stage0GoldenFixturesTests: XCTestCase {
    func testCodexSmallPreviewAndFull() throws {
        let url = FixturePaths.stage0FixtureURL("agents/codex/small.jsonl")
        let idx = SessionIndexer()

        guard let preview = idx.parseFile(at: url) else { return XCTFail("preview parse returned nil") }
        XCTAssertEqual(preview.source, .codex)
        XCTAssertTrue(preview.events.isEmpty)
        XCTAssertGreaterThan(preview.eventCount, 0)
        XCTAssertEqual(preview.cwd, "/tmp/repo")
        XCTAssertFalse(preview.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        guard let full = idx.parseFileFull(at: url) else { return XCTFail("full parse returned nil") }
        XCTAssertEqual(full.source, .codex)
        XCTAssertFalse(full.events.isEmpty)
        XCTAssertTrue(full.events.contains(where: { $0.kind == .tool_call }))
        XCTAssertTrue(full.events.contains(where: { $0.kind == .tool_result }))
    }

    func testCodexLargeAndSchemaDriftParses() throws {
        let idx = SessionIndexer()

        for name in ["agents/codex/large.jsonl", "agents/codex/schema_drift.jsonl"] {
            let url = FixturePaths.stage0FixtureURL(name)
            guard let preview = idx.parseFile(at: url) else { return XCTFail("preview parse returned nil: \(name)") }
            XCTAssertTrue(preview.events.isEmpty, "preview should stay lightweight: \(name)")
            XCTAssertGreaterThan(preview.eventCount, 0)

            guard let full = idx.parseFileFull(at: url) else { return XCTFail("full parse returned nil: \(name)") }
            XCTAssertFalse(full.events.isEmpty, "full parse should have events: \(name)")
        }
    }

    func testCodexSchemaDriftWorldStateEventSurvivesParsing() throws {
        // Codex 0.144.x adds a `world_state` context-snapshot event; the payload has no
        // role/type, so it resolves to `.meta` (non-breaking). Codex rawJSON is stored
        // plain (not base64 like Claude), so assert against the raw line directly.
        let url = FixturePaths.stage0FixtureURL("agents/codex/schema_drift.jsonl")
        let idx = SessionIndexer()
        guard let full = idx.parseFileFull(at: url) else { return XCTFail("full parse returned nil") }
        let worldState = full.events.filter { $0.kind == .meta && $0.rawJSON.contains("\"type\":\"world_state\"") }
        XCTAssertFalse(worldState.isEmpty, "world_state event should survive parsing as .meta")
    }

    func testClaudeSmallPreviewAndFull() throws {
        let url = FixturePaths.stage0FixtureURL("agents/claude/small.jsonl")
        guard let preview = ClaudeSessionParser.parseFile(at: url) else { return XCTFail("preview parse returned nil") }
        XCTAssertEqual(preview.source, .claude)
        XCTAssertTrue(preview.events.isEmpty)
        XCTAssertGreaterThan(preview.eventCount, 0)

        guard let full = ClaudeSessionParser.parseFileFull(at: url) else { return XCTFail("full parse returned nil") }
        XCTAssertEqual(full.source, .claude)
        XCTAssertFalse(full.events.isEmpty)
        XCTAssertTrue(full.events.contains(where: { $0.kind == .tool_call }))
        XCTAssertTrue(full.events.contains(where: { $0.kind == .tool_result }))
        XCTAssertTrue(full.events.contains(where: { $0.kind == .meta }))
    }

    func testClaudeAITitleIsRowTitleFallback() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("AgentSessions-Claude-AITitle-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("session.jsonl")
        try """
        {"type":"system","sessionId":"ses_ai_title","uuid":"s1","timestamp":"2026-04-29T21:00:00.000Z","cwd":"/tmp","version":"2.1.123"}
        {"type":"agent-name","sessionId":"ses_ai_title","agentName":"Claude Code"}
        {"type":"ai-title","sessionId":"ses_ai_title","aiTitle":"Generated concise title"}
        {"type":"user","sessionId":"ses_ai_title","uuid":"u1","timestamp":"2026-04-29T21:00:01.000Z","message":{"role":"user","content":"This is a much longer prompt"}}
        {"type":"assistant","sessionId":"ses_ai_title","uuid":"a1","timestamp":"2026-04-29T21:00:02.000Z","message":{"role":"assistant","content":"Done."}}
        """.write(to: url, atomically: true, encoding: .utf8)

        guard let preview = ClaudeSessionParser.parseFile(at: url) else { return XCTFail("preview parse returned nil") }
        XCTAssertEqual(preview.listTitle, "Generated concise title")
        XCTAssertNil(preview.customTitle)

        guard let full = ClaudeSessionParser.parseFileFull(at: url) else { return XCTFail("full parse returned nil") }
        XCTAssertEqual(full.listTitle, "Generated concise title")
        XCTAssertNil(full.customTitle)
    }

    func testClaudeLargeAndSchemaDriftParses() throws {
        for name in ["agents/claude/large.jsonl", "agents/claude/schema_drift.jsonl"] {
            let url = FixturePaths.stage0FixtureURL(name)
            guard let preview = ClaudeSessionParser.parseFile(at: url) else { return XCTFail("preview parse returned nil: \(name)") }
            XCTAssertTrue(preview.events.isEmpty)
            XCTAssertGreaterThan(preview.eventCount, 0)

            guard let full = ClaudeSessionParser.parseFileFull(at: url) else { return XCTFail("full parse returned nil: \(name)") }
            XCTAssertFalse(full.events.isEmpty)
        }
    }

    func testClaudeSchemaDriftAttachmentEventSurvivesParsing() throws {
        let url = FixturePaths.stage0FixtureURL("agents/claude/schema_drift.jsonl")
        guard let full = ClaudeSessionParser.parseFileFull(at: url) else { return XCTFail("full parse returned nil") }
        XCTAssertFalse(metaEvents(withType: "attachment", in: full.events).isEmpty,
                       "attachment event should survive parsing as .meta")
    }

    func testClaudeSchemaDriftPermissionModeEventSurvivesParsing() throws {
        let url = FixturePaths.stage0FixtureURL("agents/claude/schema_drift.jsonl")
        guard let full = ClaudeSessionParser.parseFileFull(at: url) else { return XCTFail("full parse returned nil") }
        XCTAssertFalse(metaEvents(withType: "permission-mode", in: full.events).isEmpty,
                       "permission-mode event should survive parsing as .meta")
    }

    // Claude 2.1.211 emits a session-level `mode` marker alongside `permission-mode`.
    // It carries no content, so it reaches .meta via the SessionEventKind.from fallback
    // rather than a named case; this pins that it is never surfaced as a blank event.
    func testClaudeSchemaDriftModeEventSurvivesParsing() throws {
        let url = FixturePaths.stage0FixtureURL("agents/claude/schema_drift.jsonl")
        guard let full = ClaudeSessionParser.parseFileFull(at: url) else { return XCTFail("full parse returned nil") }
        XCTAssertFalse(metaEvents(withType: "mode", in: full.events).isEmpty,
                       "mode event should survive parsing as .meta")
    }

    func testClaudeSchemaDriftStopHookSummaryEventSurvivesParsing() throws {
        let url = FixturePaths.stage0FixtureURL("agents/claude/schema_drift.jsonl")
        guard let full = ClaudeSessionParser.parseFileFull(at: url) else { return XCTFail("full parse returned nil") }
        XCTAssertFalse(metaEvents(containing: "\"subtype\":\"stop_hook_summary\"", in: full.events).isEmpty,
                       "stop_hook_summary system event should survive parsing as .meta")
    }

    func testClaudeSubagentFixtureDetectsParent() throws {
        // Authentic subagent transcript at .../<parentUUID>/subagents/agent-<id>.jsonl.
        // Exercises the otherwise-untested ClaudeSessionParser.detectSubagentInfo
        // path-detection, and pins the additive agentId/attributionAgent keys that
        // Claude subagent transcripts carry (where they actually occur, vs the main
        // session fixture).
        let child = "agents/claude/subagent/0a1b2c3d-4e5f-4061-8071-2a3b4c5d6e7f/subagents/agent-a0ad4f44468bdf20d.jsonl"
        let url = FixturePaths.stage0FixtureURL(child)
        guard let full = ClaudeSessionParser.parseFileFull(at: url) else { return XCTFail("full parse returned nil") }
        XCTAssertEqual(full.source, .claude)
        XCTAssertFalse(full.events.isEmpty)
        // Path-based parent detection + agent type from the adjacent .meta.json sidecar.
        XCTAssertEqual(full.parentSessionID, "0a1b2c3d-4e5f-4061-8071-2a3b4c5d6e7f")
        XCTAssertEqual(full.subagentType, "general-purpose")
        // Additive subagent keys survive parsing (Claude stores rawJSON base64-encoded).
        func rawContains(_ needle: String) -> Bool {
            full.events.contains { event in
                guard let data = Data(base64Encoded: event.rawJSON),
                      let decoded = String(data: data, encoding: .utf8) else { return false }
                return decoded.contains(needle)
            }
        }
        XCTAssertTrue(rawContains("attributionAgent"), "attributionAgent key should survive parsing")
        XCTAssertTrue(rawContains("a0ad4f44468bdf20d"), "agentId value should survive parsing")
    }

    func testCopilotSmallPreviewAndFull() throws {
        let url = FixturePaths.stage0FixtureURL("agents/copilot/small.jsonl")
        guard let preview = CopilotSessionParser.parseFile(at: url) else { return XCTFail("preview parse returned nil") }
        XCTAssertEqual(preview.source, .copilot)
        XCTAssertTrue(preview.events.isEmpty)
        XCTAssertGreaterThan(preview.eventCount, 0)
        XCTAssertEqual(preview.id, "copilot_stage0_small")
        XCTAssertEqual(preview.model, "gpt-5-mini")
        XCTAssertEqual(preview.cwd, "/tmp/repo")

        guard let full = CopilotSessionParser.parseFileFull(at: url) else { return XCTFail("full parse returned nil") }
        XCTAssertEqual(full.source, .copilot)
        XCTAssertFalse(full.events.isEmpty)
        XCTAssertTrue(full.events.contains(where: { $0.kind == .tool_call }))
        XCTAssertTrue(full.events.contains(where: { $0.kind == .tool_result }))
    }

    func testCopilotLargeAndSchemaDriftParses() throws {
        for name in ["agents/copilot/large.jsonl", "agents/copilot/schema_drift.jsonl"] {
            let url = FixturePaths.stage0FixtureURL(name)
            guard let preview = CopilotSessionParser.parseFile(at: url) else { return XCTFail("preview parse returned nil: \(name)") }
            XCTAssertTrue(preview.events.isEmpty)
            XCTAssertGreaterThan(preview.eventCount, 0)

            guard let full = CopilotSessionParser.parseFileFull(at: url) else { return XCTFail("full parse returned nil: \(name)") }
            XCTAssertFalse(full.events.isEmpty)
        }
    }

    func testCopilotSchemaDriftShutdownEventSurvivesParsing() throws {
        let url = FixturePaths.stage0FixtureURL("agents/copilot/schema_drift.jsonl")
        guard let full = CopilotSessionParser.parseFileFull(at: url) else { return XCTFail("full parse returned nil") }
        XCTAssertFalse(metaEvents(withType: "session.shutdown", in: full.events).isEmpty,
                       "session.shutdown event should survive parsing as .meta")
    }

    func testCopilotAutoModeAndUsageCheckpointEventsSurviveParsing() throws {
        // Copilot 1.0.65 emits two additive session-level event types:
        // session.auto_mode_resolved (auto model selection) and
        // session.usage_checkpoint (running AIU/premium-request usage). Both use
        // the standard {type,id,parentId,timestamp,data} envelope and carry no
        // renderable content, so the parser's default branch preserves them as
        // .meta. Non-breaking, same as session.shutdown before them.
        let url = FixturePaths.stage0FixtureURL("agents/copilot/schema_drift.jsonl")
        guard let full = CopilotSessionParser.parseFileFull(at: url) else { return XCTFail("full parse returned nil") }
        XCTAssertFalse(metaEvents(withType: "session.auto_mode_resolved", in: full.events).isEmpty,
                       "session.auto_mode_resolved event should survive parsing as .meta")
        XCTAssertFalse(metaEvents(withType: "session.usage_checkpoint", in: full.events).isEmpty,
                       "session.usage_checkpoint event should survive parsing as .meta")
    }

    func testCopilotSubdirLayoutV1Parses() throws {
        // Exercises the v1.0.11+ storage layout: <uuid>/events.jsonl
        let name = "agents/copilot/subdir_v1/aaaabbbb-1111-2222-3333-ccccddddeeee/events.jsonl"
        let url = FixturePaths.stage0FixtureURL(name)
        guard let preview = CopilotSessionParser.parseFile(at: url) else { return XCTFail("preview parse returned nil") }
        XCTAssertEqual(preview.source, .copilot)
        // Session ID should be the UUID directory name, not "events"
        XCTAssertEqual(preview.id, "aaaabbbb-1111-2222-3333-ccccddddeeee")
        XCTAssertGreaterThan(preview.eventCount, 0)

        guard let full = CopilotSessionParser.parseFileFull(at: url) else { return XCTFail("full parse returned nil") }
        XCTAssertEqual(full.source, .copilot)
        XCTAssertFalse(full.events.isEmpty)
    }

    func testDroidSessionStoreAndStreamJSONFixturesParse() throws {
        let paths = [
            "agents/droid/session_store_small.jsonl",
            "agents/droid/session_store_schema_drift.jsonl",
            "agents/droid/session_store_large.jsonl",
            "agents/droid/stream_json_small.jsonl",
            "agents/droid/stream_json_schema_drift.jsonl",
            "agents/droid/stream_json_large.jsonl"
        ]

        for name in paths {
            let url = FixturePaths.stage0FixtureURL(name)
            guard let preview = DroidSessionParser.parseFile(at: url) else { return XCTFail("preview parse returned nil: \(name)") }
            XCTAssertEqual(preview.source, .droid)
            XCTAssertTrue(preview.events.isEmpty)
            XCTAssertGreaterThan(preview.eventCount, 0)

            guard let full = DroidSessionParser.parseFileFull(at: url) else { return XCTFail("full parse returned nil: \(name)") }
            XCTAssertEqual(full.source, .droid)
            XCTAssertFalse(full.events.isEmpty)
        }
    }

    func testHermesFixturesParse() throws {
        for name in ["agents/hermes/small.json", "agents/hermes/large.json", "agents/hermes/schema_drift.json"] {
            let url = FixturePaths.stage0FixtureURL(name)
            guard let preview = HermesSessionParser.parseFile(at: url) else { return XCTFail("preview parse returned nil: \(name)") }
            XCTAssertEqual(preview.source, .hermes)
            XCTAssertTrue(preview.events.isEmpty)
            XCTAssertGreaterThan(preview.eventCount, 0)

            guard let full = HermesSessionParser.parseFileFull(at: url) else { return XCTFail("full parse returned nil: \(name)") }
            XCTAssertEqual(full.source, .hermes)
            XCTAssertFalse(full.events.isEmpty)
        }
    }

    func testCursorFixturesParse() throws {
        for name in ["agents/cursor/small.jsonl", "agents/cursor/large.jsonl", "agents/cursor/schema_drift.jsonl"] {
            let url = FixturePaths.stage0FixtureURL(name)
            guard let preview = CursorSessionParser.parseFile(at: url) else { return XCTFail("preview parse returned nil: \(name)") }
            XCTAssertEqual(preview.source, .cursor)
            XCTAssertTrue(preview.events.isEmpty)
            XCTAssertGreaterThan(preview.eventCount, 0)

            guard let full = CursorSessionParser.parseFileFull(at: url) else { return XCTFail("full parse returned nil: \(name)") }
            XCTAssertEqual(full.source, .cursor)
            XCTAssertFalse(full.events.isEmpty)
        }
    }

    func testCursorSchemaDriftBlocksMapToExpectedEvents() throws {
        let url = FixturePaths.stage0FixtureURL("agents/cursor/schema_drift.jsonl")
        guard let full = CursorSessionParser.parseFileFull(at: url) else {
            return XCTFail("full parse returned nil")
        }

        XCTAssertTrue(full.events.contains { $0.kind == .meta && ($0.text ?? "").contains("inspect the build log") })
        XCTAssertTrue(full.events.contains { $0.kind == .tool_call && $0.toolName == "read_file" && ($0.toolInput ?? "").contains("build.log") })
        XCTAssertTrue(full.events.contains { $0.kind == .tool_result && $0.toolName == "read_file" && ($0.toolOutput ?? "").contains("Example.swift:42") })
        XCTAssertTrue(full.events.contains { $0.kind == .assistant && ($0.text ?? "").contains("unknown block with visible text") })
    }

    /// The `agents/gemini/*` fixtures are kept ONLY as negative-test inputs for this
    /// guard — Gemini CLI support was removed 2026-06-24. Do not delete them as dead
    /// weight: real Gemini sessions still sit under `~/.gemini/tmp/*/chats/`, the same
    /// tree Antigravity discovers from (`~/.gemini/antigravity-cli/brain`), so this
    /// proves a discovery widening cannot silently start parsing them as Antigravity.
    /// `scripts/scan_tool_formats.py`'s `agent == "gemini"` skip is what keeps these
    /// same files out of the format scanner.
    func testGeminiFixturesAreIgnoredAfterAntigravityMigration() throws {
        for name in ["agents/gemini/small.json", "agents/gemini/schema_drift.json", "agents/gemini/large.json", "agents/gemini/jsonl_v040.jsonl"] {
            let url = FixturePaths.stage0FixtureURL(name)
            XCTAssertNil(AntigravitySessionParser.parseFile(at: url), name)
            XCTAssertNil(AntigravitySessionParser.parseFileFull(at: url), name)
        }
    }

    func testAntigravityCLITranscriptFixtureParses() throws {
        let url = FixturePaths.stage0FixtureURL("agents/antigravity/cli_small.jsonl")
        guard let preview = AntigravitySessionParser.parseFile(at: url) else { return XCTFail("preview nil") }
        XCTAssertEqual(preview.source, .antigravity)
        XCTAssertTrue(preview.events.isEmpty)
        XCTAssertGreaterThan(preview.eventCount, 0)

        guard let full = AntigravitySessionParser.parseFileFull(at: url) else { return XCTFail("full nil") }
        XCTAssertEqual(full.source, .antigravity)
        XCTAssertTrue(full.events.contains { $0.kind == .user })
        XCTAssertTrue(full.events.contains { $0.kind == .tool_call && $0.toolName == "list_dir" })
        XCTAssertTrue(full.events.contains { $0.kind == .tool_result })
        XCTAssertEqual(full.model, "Gemini 3.5 Flash (Medium)")
        // The model's actual answer (PLANNER_RESPONSE.content) is surfaced, not just thinking.
        XCTAssertTrue(full.events.contains { $0.kind == .assistant && ($0.text ?? "").contains("The directory contains a.txt and b.txt.") })

        // Legacy markdown still parses.
        let md = FixturePaths.stage0FixtureURL("agents/antigravity/small.md")
        XCTAssertNotNil(AntigravitySessionParser.parseFileFull(at: md))
    }

    func testOpenCodeFixturesParse() throws {
        // v2 fixtures
        for name in ["agents/opencode/storage_v2/session/proj_test/ses_s_stage0_small.json",
                     "agents/opencode/storage_v2/session/proj_test/ses_s_stage0_large.json"] {
            let url = FixturePaths.stage0FixtureURL(name)
            guard let preview = OpenCodeSessionParser.parseFile(at: url) else { return XCTFail("preview parse returned nil: \(name)") }
            XCTAssertEqual(preview.source, .opencode)
            XCTAssertTrue(preview.events.isEmpty)
            XCTAssertGreaterThan(preview.eventCount, 0)
            XCTAssertNotNil(preview.model)

            guard let full = OpenCodeSessionParser.parseFileFull(at: url) else { return XCTFail("full parse returned nil: \(name)") }
            XCTAssertEqual(full.source, .opencode)
            XCTAssertFalse(full.events.isEmpty)
            XCTAssertTrue(full.events.contains(where: { $0.kind == .tool_call }) || full.events.contains(where: { $0.kind == .assistant }))
        }

        // legacy fixtures (schema drift)
        do {
            let url = FixturePaths.stage0FixtureURL("agents/opencode/storage_legacy/session/proj_test/ses_s_stage0_drift.json")
            guard let preview = OpenCodeSessionParser.parseFile(at: url) else { return XCTFail("preview parse returned nil") }
            XCTAssertEqual(preview.source, .opencode)
            XCTAssertTrue(preview.events.isEmpty)
            XCTAssertGreaterThan(preview.eventCount, 0)

            guard let full = OpenCodeSessionParser.parseFileFull(at: url) else { return XCTFail("full parse returned nil") }
            XCTAssertEqual(full.source, .opencode)
            XCTAssertFalse(full.events.isEmpty)
        }
    }

    func testOpenClawFixturesParse() throws {
        let smallURL = FixturePaths.stage0FixtureURL("agents/openclaw/small.jsonl")
        guard let smallPreview = OpenClawSessionParser.parseFile(at: smallURL) else { return XCTFail("preview parse returned nil") }
        XCTAssertEqual(smallPreview.source, .openclaw)
        XCTAssertTrue(smallPreview.events.isEmpty)
        XCTAssertGreaterThan(smallPreview.eventCount, 0)
        XCTAssertEqual(smallPreview.model, "openclaw-small")

        guard let smallFull = OpenClawSessionParser.parseFileFull(at: smallURL) else { return XCTFail("full parse returned nil") }
        XCTAssertEqual(smallFull.source, .openclaw)
        XCTAssertFalse(smallFull.events.isEmpty)
        XCTAssertTrue(smallFull.events.contains(where: { $0.kind == .tool_call }))
        XCTAssertTrue(smallFull.events.contains(where: { $0.kind == .tool_result }))

        for name in ["agents/openclaw/large.jsonl", "agents/openclaw/schema_drift.jsonl"] {
            let url = FixturePaths.stage0FixtureURL(name)
            guard let preview = OpenClawSessionParser.parseFile(at: url) else { return XCTFail("preview parse returned nil: \(name)") }
            XCTAssertEqual(preview.source, .openclaw)
            XCTAssertTrue(preview.events.isEmpty)
            XCTAssertGreaterThan(preview.eventCount, 0)

            guard let full = OpenClawSessionParser.parseFileFull(at: url) else { return XCTFail("full parse returned nil: \(name)") }
            XCTAssertEqual(full.source, .openclaw)
            XCTAssertFalse(full.events.isEmpty)
            XCTAssertTrue(full.events.contains { $0.kind == .tool_call || $0.kind == .assistant })
        }
    }

    func testOpenClawParserHandlesCaseAndSnakeCaseVariants() throws {
        let jsonl = """
        {"type":"session","id":"openclaw-variant","version":3,"timestamp":"2026-02-24T13:00:00Z","cwd":"/tmp"}
        {"type":"message","id":"m1","timestamp":"2026-02-24T13:00:01Z","message":{"role":"user","content":[{"type":"text","text":"Run shell status"}]}}
        {"type":"message","id":"m2","timestamp":"2026-02-24T13:00:02Z","message":{"role":"assistant","content":[{"type":"TOOL_CALL","id":"tc1","name":"shell","arguments":{"command":"pwd"}}]}}
        {"type":"message","id":"m3","timestamp":"2026-02-24T13:00:03Z","message":{"role":"tool_result","tool_call_id":"tc1","tool_name":"shell","content":"ok","isError":false}}
        {"type":"message","id":"m4","timestamp":"2026-02-24T13:00:04Z","message":{"role":"tool_result","tool_call_id":"tc2","tool_name":"shell","content":"failed","is_error":true}}
        """

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        try (jsonl + "\n").write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        guard let full = OpenClawSessionParser.parseFileFull(at: url) else { return XCTFail("openclaw variant parse nil") }
        let toolCalls = full.events.filter { $0.kind == .tool_call }
        let toolResults = full.events.filter { $0.kind == .tool_result }
        let errors = full.events.filter { $0.kind == .error }
        XCTAssertEqual(toolCalls.count, 1)
        XCTAssertEqual(toolResults.count, 1)
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(toolCalls.first?.toolName, "shell")
        XCTAssertEqual(toolResults.first?.toolName, "shell")
        XCTAssertEqual(errors.first?.toolName, "shell")
    }

    // MARK: - Helpers

    // MARK: - 2026-08-30 format sweep

    // Claude 2.1.251 writes `artifact-autoreact-ledger` / `artifact-comment-monitor`
    // records. They carry no role and no content, so they reach `.meta` through the
    // SessionEventKind.from fallback rather than a named case.
    func testClaudeArtifactLedgerRecordsSurviveParsing() throws {
        let url = FixturePaths.stage0FixtureURL("agents/claude/small.jsonl")
        guard let full = ClaudeSessionParser.parseFileFull(at: url) else {
            return XCTFail("full parse returned nil")
        }
        for type in ["artifact-autoreact-ledger", "artifact-comment-monitor"] {
            XCTAssertFalse(metaEvents(withType: type, in: full.events).isEmpty,
                           "\(type) should survive parsing as .meta")
        }
    }

    // Codex 0.151 nests subagent lifecycle under `item_completed`. The payload exposes no
    // role/type at its top level, so it resolves to `.meta` (non-breaking). Codex rawJSON
    // is stored plain, not base64 like Claude's.
    func testCodexItemCompletedSubAgentActivitySurvivesParsing() throws {
        let url = FixturePaths.stage0FixtureURL("agents/codex/small.jsonl")
        let idx = SessionIndexer()
        guard let full = idx.parseFileFull(at: url) else {
            return XCTFail("full parse returned nil")
        }
        let items = full.events.filter {
            $0.kind == .meta && $0.rawJSON.contains("\"type\":\"item_completed\"")
        }
        XCTAssertFalse(items.isEmpty, "item_completed event should survive parsing as .meta")
    }

    /// The invariant that matters most about these fixtures: they are committed, public
    /// artifacts, so no identifier may ever appear as a dict KEY in one.
    ///
    /// `rebuild_stage0_baseline._redact` blanks string *values* but never dict *keys*, so
    /// a map keyed by an id serialises its real ids into the fixture as if they were
    /// schema. That is what `_NESTED_OPAQUE_KEYS` prevents. On 2026-08-30 Claude's
    /// `artifacts` map — keyed by artifact UUID — was one emit away from doing exactly
    /// this; it is opaque-listed now and lands as an empty dict. This test is the
    /// forcing function, so the next unlisted id-keyed map fails here rather than
    /// shipping and making every future id read as schema drift.
    func testCommittedFixturesCarryNoIdentifierShapedDictKeys() throws {
        let uuidish = try NSRegularExpression(
            pattern: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
        var offenders: [String] = []

        func scan(_ value: Any, path: String, fixture: String) {
            if let dict = value as? [String: Any] {
                for (key, child) in dict {
                    let range = NSRange(key.startIndex..., in: key)
                    if uuidish.firstMatch(in: key, range: range) != nil {
                        offenders.append("\(fixture): \(path).\(key)")
                    }
                    scan(child, path: "\(path).\(key)", fixture: fixture)
                }
            } else if let list = value as? [Any] {
                for item in list { scan(item, path: "\(path)[]", fixture: fixture) }
            }
        }

        let root = FixturePaths.stage0FixtureURL("agents")
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return XCTFail("could not enumerate \(root.path)")
        }
        var scanned = 0
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            scanned += 1
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let name = url.lastPathComponent
            for line in text.split(separator: "\n") {
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) else { continue }
                scan(obj, path: "", fixture: name)
            }
        }
        XCTAssertGreaterThan(scanned, 0, "no fixtures were scanned — the walk found nothing")
        XCTAssertTrue(offenders.isEmpty,
                      "identifier-shaped dict keys in committed fixtures: \(offenders.prefix(10))")
    }

    private func metaEvents(withType type: String, in events: [SessionEvent]) -> [SessionEvent] {
        metaEvents(containing: "\"type\":\"\(type)\"", in: events)
    }

    private func metaEvents(containing needle: String, in events: [SessionEvent]) -> [SessionEvent] {
        events.filter { event in
            guard event.kind == .meta, let data = Data(base64Encoded: event.rawJSON),
                  let decoded = String(data: data, encoding: .utf8) else { return false }
            return decoded.contains(needle)
        }
    }
}
