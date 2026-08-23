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
