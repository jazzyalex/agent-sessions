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
        XCTAssertEqual(prompts.count, 2)
        XCTAssertEqual(prompts[1].text, "Now rename everything to lowercase")

        let interrupted = try XCTUnwrap(session.events.first { $0.id.hasSuffix("-i") })
        XCTAssertEqual(interrupted.text, "[interrupted: cancelled]")

        let dangling = session.events.filter { $0.kind == .tool_call }
        XCTAssertEqual(dangling.count, 2)
        XCTAssertEqual(dangling[1].messageID, "call_fixture_002")
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
        XCTAssertEqual(session.eventCount, 2)
        XCTAssertEqual(session.cwd, "/Users/fx-demo/Projects/alpha")
        XCTAssertEqual(session.model, "demo/model-1")
        XCTAssertNotNil(session.startTime)
    }

    private func makeTurn(_ object: [String: Any]) throws -> [SessionEvent] {
        let data = try JSONSerialization.data(withJSONObject: object)
        let turn = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return FxSessionParser.events(forTurn: turn, turnIndex: 0)
    }

    /// Inline base64 images render as `[image]` markers; the payload never
    /// reaches the rendered text.
    func testUserImagesRenderAsMarkers() throws {
        let events = try makeTurn([
            "kind": "assistant",
            "user": ["text": "look", "images": [["width": 10, "height": 10, "base64_data": "QUJD"]]],
            "assistant": "done"
        ])

        XCTAssertEqual(events.first?.kind, .user)
        XCTAssertEqual(events.first?.text, "[image]\nlook")
        XCTAssertFalse(events.first?.text?.contains("QUJD") ?? true)
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
}
