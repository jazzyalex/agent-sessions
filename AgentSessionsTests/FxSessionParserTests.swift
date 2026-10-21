import XCTest
@testable import AgentSessions

/// Parser coverage for fx checkpoint transcripts, against the committed stage0
/// fixture plus synthetic turns for shapes the fixture does not carry (images,
/// truncated tool output).
final class FxSessionParserTests: XCTestCase {
    private func fixtureURL(_ name: String, file: StaticString = #filePath) -> URL {
        FixturePaths.stage0FixtureURL("agents/fx/\(name)", file: file)
    }

    private func session(forCheckpoint name: String) throws -> Session {
        let url = fixtureURL(name)
        return try XCTUnwrap(FxSessionParser.parseFileFull(at: url, allowLargeFile: true),
                             "fixture must parse")
    }

    /// The full fixture transcript renders in reading order: user prompt, then
    /// per-step narration and keyed calls/results, then the final reply.
    func testFixtureRendersTurnsInReadingOrder() throws {
        let session = try session(forCheckpoint: "small/checkpoint.json")

        // The id is the session directory name, not the checkpoint's session_id field.
        XCTAssertEqual(session.id, "small")
        XCTAssertEqual(session.source, .fx)
        XCTAssertEqual(session.cwd, "/Users/fx-demo/Projects/alpha")
        XCTAssertEqual(session.repoName, "alpha")
        XCTAssertEqual(session.model, "demo/model-1")
        XCTAssertEqual(session.reasoningEffort, "auto")
        XCTAssertEqual(session.startTime, Date(timeIntervalSince1970: 1_787_261_000))
        XCTAssertEqual(session.endTime, Date(timeIntervalSince1970: 1_787_261_400))

        let kinds = session.events.map(\.kind)
        XCTAssertEqual(kinds.first, .user)
        XCTAssertTrue(kinds.contains(.assistant))
        // Turn two ends cancelled, so the transcript closes on its marker.
        XCTAssertEqual(kinds.last, .meta)
        XCTAssertTrue(kinds.contains(.tool_call))
        XCTAssertTrue(kinds.contains(.tool_result))
        XCTAssertEqual(session.nonMetaCount, kinds.filter { $0 != .meta }.count)
    }

    /// Tool results key back to their call by id, and `arguments_json` is a
    /// JSON *string* on the wire — passed through verbatim, not re-encoded.
    func testToolCallsAndResultsKeyByCallID() throws {
        let session = try session(forCheckpoint: "small/checkpoint.json")

        let call = try XCTUnwrap(session.events.first { $0.kind == .tool_call })
        XCTAssertEqual(call.toolName, "list_files")
        XCTAssertEqual(call.toolInput, "{\"path\":\".\"}")
        XCTAssertEqual(call.messageID, "call_fixture_001")

        let result = try XCTUnwrap(session.events.first { $0.kind == .tool_result })
        XCTAssertEqual(result.messageID, "call_fixture_001")
        XCTAssertEqual(result.toolOutput, "README.md\nsrc/\n")
        XCTAssertEqual(result.timestamp, Date(timeIntervalSince1970: 1_787_261_100))
    }

    /// An interrupted turn keeps its user prompt, marks the dangling call, and
    /// records the terminal reason as meta.
    func testInterruptedTurnKeepsPromptAndMarksReason() throws {
        let session = try session(forCheckpoint: "small/checkpoint.json")

        let prompts = session.events.filter { $0.kind == .user }
        XCTAssertEqual(prompts.count, 4)
        XCTAssertEqual(prompts[1].text, "Now rename everything to lowercase")

        let interrupted = try XCTUnwrap(session.events.first { $0.id.hasSuffix("-i") })
        XCTAssertEqual(interrupted.text, "[interrupted: cancelled]")

        let dangling = session.events.filter { $0.id.hasSuffix("-t") }
        XCTAssertEqual(dangling.count, 2)
        XCTAssertEqual(dangling[0].messageID, "call_fixture_002")
    }

    /// An interrupted turn that got far enough to run tools and stream a
    /// partial reply renders all of it — completed steps first, then the
    /// partial answer, then the call that never got its result.
    func testInterruptedTurnRendersCompletedStepsAndPartialReply() throws {
        let session = try session(forCheckpoint: "small/checkpoint.json")

        let turn = session.events.filter { $0.id.hasPrefix("4-") }
        XCTAssertEqual(turn.map(\.kind),
                       [.user, .assistant, .tool_call, .tool_result, .assistant, .tool_call, .meta])
        XCTAssertEqual(turn[0].text, "Summarize the src folder next")
        XCTAssertEqual(turn[1].text, "Checking what is inside src.")
        XCTAssertEqual(turn[2].messageID, "call_fixture_004")
        XCTAssertEqual(turn[3].toolOutput, "main.swift\nutil.swift\n")
        XCTAssertEqual(turn[4].kind, .assistant)
        XCTAssertTrue(turn[4].text?.hasPrefix("The src folder holds") ?? false)
        XCTAssertEqual(turn[5].messageID, "call_fixture_005")
        XCTAssertEqual(turn[6].text, "[interrupted: cancelled]")
    }

    /// A background command shares the ordinary turn body (prompt, steps,
    /// reply) and adds one marker recording where its output went.
    func testBackgroundCommandSharesAssistantBodyPlusMarker() throws {
        let session = try session(forCheckpoint: "small/checkpoint.json")

        let turn = session.events.filter { $0.id.hasPrefix("2-") }
        XCTAssertEqual(turn.map(\.kind), [.user, .meta, .assistant, .tool_call, .tool_result, .assistant])
        XCTAssertEqual(turn[0].text, "Run the test suite in the background")
        XCTAssertTrue(turn[1].text?.hasPrefix("[background command — log /Users/fx-demo/Projects/alpha/.fx/background/bg-001.log") ?? false)
        XCTAssertEqual(turn.last?.text, "The suite passed with no failures.")
    }

    /// A compacted-summary turn renders the summary and what it replaced, so
    /// an auto-compacted session never reads like one that started over.
    func testCompactedSummaryExplainsTheGap() throws {
        let session = try session(forCheckpoint: "small/checkpoint.json")

        let turn = session.events.filter { $0.id.hasPrefix("3-") }
        XCTAssertEqual(turn.count, 1)
        XCTAssertEqual(turn[0].kind, .meta)
        let text = try XCTUnwrap(turn[0].text)
        XCTAssertTrue(text.contains("[context compacted: 3 earlier turns removed (compaction #1)]"))
        XCTAssertTrue(text.contains("The user asked for a directory listing"))
        XCTAssertTrue(text.contains("- List the files in the current directory"))
    }

    /// The display.json title wins over the first user prompt.
    func testDisplayTitleIsAuthoritative() throws {
        let session = try session(forCheckpoint: "small/checkpoint.json")
        XCTAssertEqual(session.lightweightTitle, "List the files in the current directory")
    }

    /// A malformed checkpoint degrades to a metadata-free lightweight row
    /// instead of throwing away identity, cwd, title and timestamps.
    func testMalformedCheckpointKeepsSidecarFacts() throws {
        let session = try XCTUnwrap(
            FxSessionParser.parseFileFull(at: fixtureURL("unsupported/checkpoint.json"), allowLargeFile: true))

        XCTAssertNotNil(session)
        XCTAssertEqual(session.events.count, 0)
        // The sidecar still answers.
        XCTAssertEqual(session.cwd, "/Users/fx-demo/Projects/beta")
        XCTAssertEqual(session.id, "unsupported")
    }

    /// Lightweight parsing reads only the sidecars: no events, but identity,
    /// workspace, model and fx's own turn count all come through.
    func testLightweightParseReadsSidecarsOnly() throws {
        let session = try XCTUnwrap(FxSessionParser.parseFile(at: fixtureURL("small/checkpoint.json")))

        XCTAssertEqual(session.events.count, 0)
        XCTAssertEqual(session.eventCount, 5)
        XCTAssertEqual(session.cwd, "/Users/fx-demo/Projects/alpha")
        XCTAssertEqual(session.model, "demo/model-1")
        XCTAssertNotNil(session.startTime)
    }

    private func makeTurn(_ object: [String: Any]) throws -> [SessionEvent] {
        let data = try JSONSerialization.data(withJSONObject: object)
        let turn = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return FxSessionParser.events(forTurn: turn, turnIndex: 0)
    }

    /// Image references render as `[image]` markers; the referenced file's
    /// name and path never reach the rendered text. fx writes `{id, path,
    /// media_type, snapshot_path, snapshot_sha256}` records — the bytes are
    /// files under the session directory, not payloads in the checkpoint.
    func testUserImagesRenderAsMarkers() throws {
        let events = try makeTurn([
            "kind": "assistant",
            "user": ["text": "look", "images": [[
                "id": 1,
                "path": "/Users/fx-demo/Downloads/paste.png",
                "media_type": "image/png",
                "snapshot_path": "images/0001-paste.png",
                "snapshot_sha256": "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
            ]]],
            "assistant": "done"
        ])

        XCTAssertEqual(events.first?.kind, .user)
        XCTAssertEqual(events.first?.text, "[image]\nlook")
        XCTAssertFalse(events.first?.text?.contains("paste.png") ?? true)
    }

    /// fx's durable-bytes encoder writes non-UTF-8 fields as
    /// `{"encoding": "base64", "data": …}` objects. Every text-bearing read
    /// decodes that form, and a result still keys back to its call when both
    /// ids went through it.
    func testBase64DurableBytesFieldsDecodeToText() throws {
        let encoded = ["encoding": "base64", "data": "aGlkZGVuIHByb21wdA=="]
        let callID = ["encoding": "base64", "data": "Y2FsbF9iNjQ="]
        let events = try makeTurn([
            "kind": "assistant",
            "user": ["text": encoded],
            "assistant": encoded,
            "execution": [
                "tool_steps": [[
                    "assistant": encoded,
                    "tool_calls": [["id": callID, "name": encoded, "arguments_json":
                        ["encoding": "base64", "data": "eyJwYXRoIjoiLiJ9"]]],
                    "tool_results": [[
                        "tool_call_id": callID,
                        "tool_name": encoded,
                        "status": "success",
                        "output": encoded,
                        "created_at_ms": 1787261100000
                    ]]
                ]]
            ]
        ])

        XCTAssertEqual(events.first?.text, "hidden prompt")
        XCTAssertEqual(events.filter { $0.kind == .assistant }.compactMap(\.text),
                       Array(repeating: "hidden prompt", count: 2))
        let call = try XCTUnwrap(events.first { $0.kind == .tool_call })
        XCTAssertEqual(call.toolName, "hidden prompt")
        XCTAssertEqual(call.toolInput, "{\"path\":\".\"}")
        XCTAssertEqual(call.messageID, "call_b64")

        let result = try XCTUnwrap(events.first { $0.kind == .tool_result })
        XCTAssertEqual(result.toolOutput, "hidden prompt")
        XCTAssertEqual(result.messageID, "call_b64")
    }

    /// Bytes that are not text at all render as an honest marker instead of
    /// silently dropping the field.
    func testNonUTF8ToolOutputRendersBinaryMarker() throws {
        let events = try makeTurn([
            "kind": "assistant",
            "user": ["text": "go"],
            "execution": [
                "tool_steps": [[
                    "assistant": "",
                    "tool_calls": [["id": "c1", "name": "run", "arguments_json": "{}"]],
                    "tool_results": [[
                        "tool_call_id": "c1",
                        "tool_name": "run",
                        "status": "success",
                        "output": ["encoding": "base64", "data": "//4="],
                        "created_at_ms": 1787261100000
                    ]]
                ]]
            ]
        ])

        let result = try XCTUnwrap(events.first { $0.kind == .tool_result })
        XCTAssertEqual(result.toolOutput, "[binary output]")
    }

    /// Truncated tool output is marked rather than silently clipped.
    func testTruncatedToolOutputIsMarked() throws {
        let events = try makeTurn([
            "kind": "assistant",
            "user": ["text": "go"],
            "execution": [
                "tool_steps": [[
                    "assistant": "",
                    "tool_calls": [["id": "c1", "name": "read_file", "arguments_json": "{}"]],
                    "tool_results": [[
                        "tool_call_id": "c1",
                        "tool_name": "read_file",
                        "status": "success",
                        "output": "partial",
                        "truncated": true,
                        "created_at_ms": 1787261100000
                    ]]
                ]]
            ]
        ])

        let result = try XCTUnwrap(events.first { $0.kind == .tool_result })
        XCTAssertEqual(result.toolOutput, "partial\n[truncated]")
    }

    /// An interrupted turn whose steps were never persisted still names the
    /// tools that completed — the only surviving evidence of the work.
    func testInterruptedWithoutExecutionNamesCompletedTools() throws {
        let events = try makeTurn([
            "kind": "interrupted",
            "user": ["text": "stop"],
            "assistant": NSNull(),
            "tool_call": NSNull(),
            "completed_tool_names": ["list_files", "read_file"],
            "terminal_reason": "failed"
        ])

        XCTAssertEqual(events.map(\.kind), [.user, .meta])
        XCTAssertEqual(events[1].text, "[interrupted: failed — completed: list_files, read_file]")
    }

    /// The legacy background shape (no `assistant`/`execution` yet) still
    /// renders its prompt and its marker instead of an empty record.
    func testLegacyBackgroundCommandKeepsPromptAndMarker() throws {
        let events = try makeTurn([
            "kind": "background_command",
            "user": ["text": "run"],
            "log_path": "/tmp/log",
            "expect_url": false,
            "url": NSNull(),
            "background_record_id": NSNull()
        ])

        XCTAssertEqual(events.map(\.kind), [.user, .meta])
        XCTAssertEqual(events[1].text, "[background command — log /tmp/log]")
    }

    /// A compacted-summary turn with only the required fields still explains
    /// itself; `root_user_messages` are optional on the wire.
    func testMinimalCompactedSummaryStillExplainsItself() throws {
        let events = try makeTurn([
            "kind": "compacted_summary",
            "summary": "kept context",
            "removed_turn_count": 2,
            "compaction_count": 1
        ])

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].text,
                       "[context compacted: 2 earlier turns removed (compaction #1)]\nkept context")
    }
}

// MARK: - Schema 4 (fx 0.0.8+: session.json schema 4 + conversation events.jsonl)

/// The `schema4` fixture follows the upstream writer byte for byte
/// (vercel-labs/fx v0.0.14, `session_codec.zig` `encodeSessionMetadata` and
/// `session_event.zig` `encodeConversationFrame`): a compact schema-4
/// manifest, one `{schema_version, seq, timestamp_ms, event: {<kind>: …}}`
/// frame per line, full tool output under `tool-results/<artifact_ref>`, and a
/// `recovery.json` holding a turn fx has not committed yet.
extension FxSessionParserTests {
    private func schema4Session(file: StaticString = #filePath) throws -> Session {
        try XCTUnwrap(FxSessionParser.parseFileFull(at: fixtureURL("schema4/events.jsonl", file: file),
                                                    allowLargeFile: true),
                      "schema-4 fixture must parse")
    }

    /// A temporary schema-4 session directory. `frames` are written one per
    /// line; `manifest` overrides keys of a minimal valid manifest.
    private func stageSchema4(frames: [[String: Any]],
                              manifest: [String: Any] = [:],
                              rawTail: String? = nil,
                              recovery: [String: Any]? = nil,
                              artifacts: [String: String] = [:]) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("fx-schema4-\(UUID().uuidString)", isDirectory: true)
        let dir = root.appendingPathComponent("Fx4StagedAAA", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        var sidecar: [String: Any] = [
            "schema_version": 4, "id": "Fx4StagedAAA",
            "origin_workspace_root": "/Users/fx-demo/Projects/delta",
            "workspace_root": "/Users/fx-demo/Projects/delta",
            "created_at_ms": 1_789_100_000_000, "updated_at_ms": 1_789_100_060_000,
            "conversation_language": "en", "provider": "gateway", "model": "demo/model-3",
            "effort": "high", "fast_mode": false, "subagent_child": false
        ]
        for (key, value) in manifest { sidecar[key] = value }
        try JSONSerialization.data(withJSONObject: sidecar)
            .write(to: dir.appendingPathComponent("session.json"))

        var body = ""
        for frame in frames {
            let data = try JSONSerialization.data(withJSONObject: frame, options: [.sortedKeys])
            body += String(decoding: data, as: UTF8.self) + "\n"
        }
        if let rawTail { body += rawTail }
        try Data(body.utf8).write(to: dir.appendingPathComponent("events.jsonl"))

        if let recovery {
            try JSONSerialization.data(withJSONObject: recovery)
                .write(to: dir.appendingPathComponent("recovery.json"))
        }
        if !artifacts.isEmpty {
            let results = dir.appendingPathComponent("tool-results", isDirectory: true)
            try FileManager.default.createDirectory(at: results, withIntermediateDirectories: true)
            for (name, text) in artifacts {
                try Data(text.utf8).write(to: results.appendingPathComponent(name))
            }
        }
        return dir.appendingPathComponent("events.jsonl")
    }

    private func frame(_ seq: Int, _ kind: String, _ payload: [String: Any], at ms: Int64 = 1_789_100_030_000) -> [String: Any] {
        ["schema_version": 3, "seq": seq, "timestamp_ms": ms, "event": [kind: payload]]
    }

    private func toolResultPayload(callID: String,
                                   preview: Any,
                                   artifactRef: String,
                                   storedBytes: Int,
                                   completeness: String = "complete") -> [String: Any] {
        ["call_id": callID, "tool_name": "shell", "status": "success", "artifact_ref": artifactRef,
         "tool_image_handle": NSNull(), "output_bytes": storedBytes, "stored_bytes": storedBytes,
         "completeness": completeness, "preview": preview, "provider_native": false,
         "created_at_ms": 1_789_100_020_000, "permission_feedback": [],
         "committed_file_presentation": NSNull(), "command_replay_ref": NSNull(),
         "command_replay_bytes": NSNull(), "command_process_presentation": NSNull(),
         "terminal_action_presentation": NSNull()]
    }

    /// The whole fixture renders in log order: committed turns, the
    /// compaction marker, the interrupted turn, then the uncommitted turn from
    /// `recovery.json`. `turn_completed` frames carry no visible content.
    func testSchema4FixtureRendersEventLogInOrder() throws {
        let session = try schema4Session()

        XCTAssertEqual(session.id, "schema4")
        XCTAssertEqual(session.source, .fx)
        XCTAssertEqual(session.cwd, "/Users/fx-demo/Projects/gamma")
        XCTAssertEqual(session.repoName, "gamma")
        XCTAssertEqual(session.model, "demo/model-2")
        XCTAssertEqual(session.reasoningEffort, "auto")
        XCTAssertEqual(session.startTime, Date(timeIntervalSince1970: 1_789_000_000))
        XCTAssertEqual(session.endTime, Date(timeIntervalSince1970: 1_789_000_200))
        XCTAssertEqual(session.lightweightTitle, "List the files and fix the README typo")

        XCTAssertEqual(session.events.map(\.kind), [
            .user, .assistant, .tool_call, .tool_result, .assistant,
            .user, .tool_call, .tool_result, .user, .tool_call, .tool_result, .assistant,
            .meta,
            .user, .tool_call, .meta,
            .user, .assistant, .tool_call, .tool_result, .meta
        ])
        XCTAssertEqual(session.nonMetaCount, 18)
        XCTAssertEqual(session.lightweightCommands, 5)
        XCTAssertEqual(Set(session.events.map(\.id)).count, session.events.count, "event ids must be unique")
        XCTAssertEqual(session.events.first?.text, "[image]\nList the files in this project")
    }

    /// Calls and results key by `call_id`; `arguments_json` is a JSON string
    /// passed through verbatim; a result carries its own `created_at_ms`.
    func testSchema4ToolCallsAndResultsKeyByCallID() throws {
        let session = try schema4Session()

        let call = try XCTUnwrap(session.events.first { $0.kind == .tool_call })
        XCTAssertEqual(call.toolName, "glob_files")
        XCTAssertEqual(call.toolInput, "{\"pattern\":\"**/*\"}")
        XCTAssertEqual(call.messageID, "call_fx4_glob_001")

        let result = try XCTUnwrap(session.events.first { $0.kind == .tool_result })
        XCTAssertEqual(result.toolName, "glob_files")
        XCTAssertEqual(result.messageID, "call_fx4_glob_001")
        XCTAssertEqual(result.toolOutput, "README.md\nsrc/main.zig\n")
        XCTAssertEqual(result.timestamp, Date(timeIntervalSince1970: 1_789_000_012))

        let shell = try XCTUnwrap(session.events.first { $0.kind == .tool_result && $0.messageID == "call_fx4_shell_003" })
        XCTAssertEqual(shell.toolOutput, " README.md | 2 +-\n 1 file changed, 1 insertion(+), 1 deletion(-)\n")
    }

    /// fx stamps every frame of a turn with the commit time. The user prompt
    /// takes the turn's `turn_summary.started_at_ms` instead, so it does not
    /// appear to arrive after its own answer.
    func testSchema4PromptTakesTurnStartTime() throws {
        let session = try schema4Session()

        let prompts = session.events.filter { $0.kind == .user }
        XCTAssertEqual(prompts.first?.timestamp, Date(timeIntervalSince1970: 1_789_000_005))
        let narration = try XCTUnwrap(session.events.first { $0.kind == .assistant })
        XCTAssertEqual(narration.timestamp, Date(timeIntervalSince1970: 1_789_000_020))
    }

    /// Steering is text the user typed while a turn was running. It renders as
    /// a user message, but never becomes the title.
    func testSchema4SteeringRendersAsUserMessage() throws {
        let session = try schema4Session()

        let steering = try XCTUnwrap(session.events.first { $0.id == "10-s" })
        XCTAssertEqual(steering.kind, .user)
        XCTAssertEqual(steering.role, "user")
        XCTAssertEqual(steering.text, "Also show me the diff stat")
    }

    /// Compaction appends a `context_checkpoint` frame and keeps the earlier
    /// frames, so the marker sits between the turns it summarizes and the next.
    /// An interrupted turn closes on its reason.
    func testSchema4CompactionAndInterruptionMarkers() throws {
        let session = try schema4Session()

        let checkpoint = try XCTUnwrap(session.events.first { $0.id == "15-c" })
        XCTAssertEqual(checkpoint.kind, .meta)
        XCTAssertEqual(checkpoint.text,
                       "[context compacted through event 14]\nThe user asked for a file listing and a README typo fix; both are done.")

        let interrupted = try XCTUnwrap(session.events.first { $0.id == "18-i" })
        XCTAssertEqual(interrupted.text, "[interrupted: cancelled]")
        let dangling = try XCTUnwrap(session.events.first { $0.id == "17-t" })
        XCTAssertEqual(dangling.messageID, "call_fx4_shell_004")
    }

    /// `recovery.json` holds the turn fx was running when it last saved. When
    /// its `conversation_seq` matches the log and the log has no open turn, it
    /// renders once, after the log, with a marker saying it is not saved yet.
    func testSchema4UncommittedRecoveryTurnRendersOnce() throws {
        let session = try schema4Session()

        let recovered = session.events.filter { $0.id.hasPrefix("recovery-") }
        XCTAssertEqual(recovered.map(\.kind), [.user, .assistant, .tool_call, .tool_result, .meta])
        XCTAssertEqual(recovered[0].text, "Try the tests again with a summary")
        XCTAssertEqual(recovered[1].text, "Running the tests again.")
        XCTAssertEqual(recovered[2].messageID, "call_fx4_shell_005")
        XCTAssertEqual(recovered[3].toolOutput, "Build Summary: 3/3 steps succeeded\n")
        XCTAssertEqual(recovered[4].text, "[unsaved turn: network_interrupted]")
        XCTAssertEqual(session.events.filter { $0.text == "Try the tests again with a summary" }.count, 1)
    }

    /// A recovery file older than the log (its turn was committed and the
    /// cleanup did not run) is ignored, as fx itself ignores it.
    func testSchema4StaleRecoveryIsIgnored() throws {
        let url = try stageSchema4(
            frames: [
                frame(1, "user", ["text": "hello", "images": [], "work_id": NSNull()]),
                frame(2, "assistant", ["text": "hi", "provider_replay": NSNull(), "standalone_response": false]),
                frame(3, "turn_completed", ["files": [], "turn_summary": NSNull()])
            ],
            recovery: ["conversation_seq": 1,
                       "checkpoint": ["version": 2, "turn_id": 1, "user": ["text": "hello", "images": []],
                                      "assistant_source": "", "cause": "network_interrupted"]])

        let session = try XCTUnwrap(FxSessionParser.parseFileFull(at: url, allowLargeFile: true))
        XCTAssertEqual(session.events.map(\.kind), [.user, .assistant])
        XCTAssertFalse(session.events.contains { $0.id.hasPrefix("recovery-") })
    }

    /// When the log already holds the start of the open turn, the recovery
    /// turn would repeat it. Only the marker renders then.
    func testSchema4RecoveryOverOpenTurnDoesNotDuplicatePrompt() throws {
        let url = try stageSchema4(
            frames: [
                frame(1, "user", ["text": "build it", "images": [], "work_id": NSNull()]),
                frame(2, "tool_call", ["call_id": "c1", "tool_name": "shell", "arguments_json": "{}",
                                       "argument_integrity": "valid", "provisional_id": NSNull(),
                                       "provider_result": NSNull(), "final_identity": "valid",
                                       "provenance": "fx_local"])
            ],
            recovery: ["conversation_seq": 2,
                       "checkpoint": ["version": 2, "turn_id": 1, "user": ["text": "build it", "images": []],
                                      "assistant_source": "", "cause": "response_interrupted"]])

        let session = try XCTUnwrap(FxSessionParser.parseFileFull(at: url, allowLargeFile: true))
        XCTAssertEqual(session.events.map(\.kind), [.user, .tool_call, .meta])
        XCTAssertEqual(session.events.filter { $0.text == "build it" }.count, 1)
        XCTAssertEqual(session.events.last?.text, "[unsaved turn: response_interrupted]")
    }

    /// `preview` holds at most 4 KiB. When the stored output is longer, the
    /// full text comes from `tool-results/<artifact_ref>`; when that file is
    /// gone the preview renders with a truncation marker; a `partial` result
    /// is marked even when its artifact is read in full.
    func testSchema4LongToolOutputReadsTheStoredArtifact() throws {
        let full = String(repeating: "x", count: 5_000)
        let url = try stageSchema4(
            frames: [
                frame(1, "user", ["text": "dump", "images": [], "work_id": NSNull()]),
                frame(2, "tool_call", ["call_id": "c1", "tool_name": "shell", "arguments_json": "{}"]),
                frame(3, "tool_result", toolResultPayload(callID: "c1", preview: String(full.prefix(4_096)),
                                                          artifactRef: "result-shell-aaaa-bbbb.txt",
                                                          storedBytes: 5_000)),
                frame(4, "tool_call", ["call_id": "c2", "tool_name": "shell", "arguments_json": "{}"]),
                frame(5, "tool_result", toolResultPayload(callID: "c2", preview: "head",
                                                          artifactRef: "result-shell-cccc-dddd.txt",
                                                          storedBytes: 5_000)),
                frame(6, "tool_call", ["call_id": "c3", "tool_name": "shell", "arguments_json": "{}"]),
                frame(7, "tool_result", toolResultPayload(callID: "c3", preview: "part",
                                                          artifactRef: "result-shell-eeee-ffff.txt",
                                                          storedBytes: 4, completeness: "partial")),
                frame(8, "turn_completed", ["files": [], "turn_summary": NSNull()])
            ],
            artifacts: ["result-shell-aaaa-bbbb.txt": full, "result-shell-eeee-ffff.txt": "part"])

        let session = try XCTUnwrap(FxSessionParser.parseFileFull(at: url, allowLargeFile: true))
        let results = session.events.filter { $0.kind == .tool_result }
        XCTAssertEqual(results.map(\.messageID), ["c1", "c2", "c3"])
        XCTAssertEqual(results[0].toolOutput, full)
        XCTAssertEqual(results[1].toolOutput, "head\n[truncated]")
        XCTAssertEqual(results[2].toolOutput, "part\n[truncated]")
    }

    /// The lightweight pass reads the manifest and the head of the log (never
    /// `recovery.json` or `tool-results/`): no events kept, but a real non-meta
    /// count for the committed log, the title and the metadata.
    func testSchema4LightweightParse() throws {
        let session = try XCTUnwrap(FxSessionParser.parseFile(at: fixtureURL("schema4/events.jsonl")))

        XCTAssertEqual(session.events.count, 0)
        XCTAssertEqual(session.eventCount, 14)
        XCTAssertEqual(session.lightweightTitle, "List the files and fix the README typo")
        XCTAssertEqual(session.cwd, "/Users/fx-demo/Projects/gamma")
        XCTAssertEqual(session.model, "demo/model-2")
        XCTAssertEqual(session.startTime, Date(timeIntervalSince1970: 1_789_000_000))
    }

    /// `title` is optional in the manifest (fx writes it after the first turn).
    /// Without it the first user prompt names the session — never steering.
    func testSchema4TitleFallsBackToFirstPrompt() throws {
        let url = try stageSchema4(frames: [
            frame(1, "user", ["text": "Explain the build", "images": [], "work_id": NSNull()]),
            frame(2, "steering", ["text": "shorter please"]),
            frame(3, "assistant", ["text": "It uses zig build.", "provider_replay": NSNull(), "standalone_response": false]),
            frame(4, "turn_completed", ["files": [], "turn_summary": NSNull()])
        ])

        XCTAssertEqual(FxSessionParser.parseFile(at: url)?.lightweightTitle, "Explain the build")
        XCTAssertEqual(FxSessionParser.parseFileFull(at: url, allowLargeFile: true)?.lightweightTitle,
                       "Explain the build")
    }

    /// An `events.jsonl` next to a manifest that is not schema 4 is the old
    /// event-log infrastructure, not a transcript: the parser refuses it.
    func testSchema4ParserRefusesAnOlderManifest() throws {
        let url = try stageSchema4(
            frames: [["schema_version": 1, "seq": 1, "timestamp_ms": 10, "kind": "session_started", "payload": [:]]],
            manifest: ["schema_version": 3, "storage_format": "event_log_v1"])

        XCTAssertNil(FxSessionParser.parseFileFull(at: url, allowLargeFile: true))
        XCTAssertNil(FxSessionParser.parseFile(at: url))
    }

    /// Lines that are not conversation frames (old `kind`/`payload` records, a
    /// torn last line) are skipped; an unknown event kind is kept as metadata
    /// so a future fx kind is visible rather than silently lost.
    func testSchema4SkipsForeignLinesAndKeepsUnknownKindsAsMeta() throws {
        let url = try stageSchema4(
            frames: [
                ["schema_version": 1, "seq": 1, "timestamp_ms": 10, "kind": "session_started", "payload": [:]],
                frame(1, "user", ["text": "hi", "images": [], "work_id": NSNull()]),
                frame(2, "brand_new_kind", ["detail": "x"]),
                frame(3, "assistant", ["text": "hello", "provider_replay": NSNull(), "standalone_response": false])
            ],
            rawTail: "{\"schema_version\":3,\"seq\":4,\"timestamp_ms\":1,\"event\":{\"turn_comp")

        let session = try XCTUnwrap(FxSessionParser.parseFileFull(at: url, allowLargeFile: true))
        XCTAssertEqual(session.events.map(\.kind), [.user, .meta, .assistant])
        XCTAssertEqual(session.events[1].role, "brand_new_kind")
    }

    /// The aggregate-token telemetry reader is audited for schema-3 manifests
    /// only; a schema-4 session reports none rather than guessing.
    func testSchema4SessionHasNoAuditedTelemetryYet() throws {
        let session = try schema4Session()
        XCTAssertFalse(FxTelemetryReader.isSupported(session))
        XCTAssertNil(FxTelemetryReader.loadTelemetry(for: session))
    }

    // MARK: - I/O failure and long logs

    private func shortConversationFrames() -> [[String: Any]] {
        [
            frame(1, "user", ["text": "hello", "images": [], "work_id": NSNull()]),
            frame(2, "assistant", ["text": "hi", "provider_replay": NSNull(), "standalone_response": false]),
            frame(3, "turn_completed", ["files": [], "turn_summary": NSNull()]),
            frame(4, "user", ["text": "again", "images": [], "work_id": NSNull()]),
            frame(5, "assistant", ["text": "sure", "provider_replay": NSNull(), "standalone_response": false]),
            frame(6, "turn_completed", ["files": [], "turn_summary": NSNull()])
        ]
    }

    /// An `events.jsonl` that cannot be opened is a failed parse, not an empty
    /// session: nil lets the caller keep the last good representation.
    func testSchema4UnreadableEventLogFailsTheParse() throws {
        let url = try stageSchema4(frames: shortConversationFrames())
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        }
        // Positive control: the log really cannot be opened (not true as root).
        XCTAssertThrowsError(try FileHandle(forReadingFrom: url))

        XCTAssertNil(FxSessionParser.parseFileFull(at: url, allowLargeFile: true))
        XCTAssertNil(FxSessionParser.parseFile(at: url))
    }

    /// A read error after the first frames ends the scan with an error, and
    /// the parse fails rather than publishing the frames read so far.
    func testSchema4ReadErrorMidLogFailsTheParse() throws {
        let url = try stageSchema4(frames: shortConversationFrames())
        let body = try Data(contentsOf: url)
        // The first two complete lines (prompt + reply), then an I/O error.
        let newlines = body.indices.filter { body[$0] == 0x0A }
        let prefixBytes = newlines[1] + 1

        func failingReader() -> (FileHandle, Int) throws -> Data {
            var calls = 0
            return { handle, count in
                calls += 1
                guard calls == 1 else { throw NSError(domain: "FxSessionParserTests", code: 5) }
                return try handle.read(upToCount: min(count, prefixBytes)) ?? Data()
            }
        }

        // Positive control: the same seam without the error reads the whole log.
        let intact = try XCTUnwrap(FxSessionParser.parseFileForTesting(at: url, includeEvents: true) { handle, count in
            try handle.read(upToCount: count) ?? Data()
        })
        XCTAssertEqual(intact.nonMetaCount, 4)

        XCTAssertNil(FxSessionParser.parseFileForTesting(at: url, includeEvents: true, readChunk: failingReader()))
        XCTAssertNil(FxSessionParser.parseFileForTesting(at: url, includeEvents: false, readChunk: failingReader()))
    }

    /// The lightweight pass builds events only for the head of the log, but
    /// its count covers the whole log: it equals the full parse's count well
    /// past the preview window.
    func testSchema4LightweightCountCoversTheWholeLog() throws {
        var frames: [[String: Any]] = []
        var seq = 0
        func next(_ kind: String, _ payload: [String: Any]) {
            seq += 1
            frames.append(frame(seq, kind, payload))
        }
        let turns = 120
        for turn in 0..<turns {
            next("user", ["text": "prompt \(turn)", "images": [], "work_id": NSNull()])
            next("tool_call", ["call_id": "c\(turn)", "tool_name": "shell", "arguments_json": "{}"])
            next("tool_result", toolResultPayload(callID: "c\(turn)", preview: "ok",
                                                  artifactRef: "result-shell-\(turn).txt", storedBytes: 2))
            next("assistant", ["text": "done \(turn)", "provider_replay": NSNull(), "standalone_response": false])
            // An empty reply renders nothing and must not be counted by either pass.
            next("assistant", ["text": "", "provider_replay": NSNull(), "standalone_response": false])
            next("turn_completed", ["files": [], "turn_summary": NSNull()])
            if turn % 40 == 39 {
                next("context_checkpoint", ["covers_through_seq": seq, "summary": "so far"])
            }
        }
        next("interrupted", ["reason": "cancelled", "partial_text": "half"])
        XCTAssertGreaterThan(frames.count, 200 * 3, "fixture must run well past the preview window")
        let url = try stageSchema4(frames: frames)

        let full = try XCTUnwrap(FxSessionParser.parseFileFull(at: url, allowLargeFile: true))
        let light = try XCTUnwrap(FxSessionParser.parseFile(at: url))

        XCTAssertEqual(full.nonMetaCount, turns * 4 + 1)
        XCTAssertEqual(light.eventCount, full.nonMetaCount)
        XCTAssertEqual(light.events.count, 0)
        XCTAssertEqual(light.lightweightTitle, "prompt 0")
    }
}
