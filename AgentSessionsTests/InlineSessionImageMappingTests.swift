import XCTest
@testable import AgentSessions

final class InlineSessionImageMappingTests: XCTestCase {
    private func makeEvent(id: String, kind: SessionEventKind, text: String? = nil, rawJSON: String) -> SessionEvent {
        SessionEvent(id: id,
                     timestamp: nil,
                     kind: kind,
                     role: nil,
                     text: text,
                     toolName: nil,
                     toolInput: nil,
                     toolOutput: nil,
                     messageID: nil,
                     parentID: nil,
                     isDelta: false,
                     rawJSON: rawJSON)
    }

    private func userPromptIndexForLineIndex(session: Session, lineIndex: Int) -> Int? {
        guard lineIndex >= 0 else { return nil }
        var userIndex: Int? = nil
        var seenUsers = 0
        for (idx, event) in session.events.enumerated() {
            if event.kind == .user {
                if idx <= lineIndex {
                    userIndex = seenUsers
                } else if userIndex == nil {
                    userIndex = seenUsers
                }
                seenUsers += 1
            }
            if idx > lineIndex, userIndex != nil { break }
        }
        return userIndex
    }

    private func writeTempJSONL(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("InlineSessionImageMappingTests-\(UUID().uuidString)")
            .appendingPathExtension("jsonl")
        guard let data = text.data(using: .utf8) else {
            XCTFail("Failed to encode test fixture as UTF-8")
            return url
        }
        try data.write(to: url)
        return url
    }

    func testImageSpanInToolResultMapsToMostRecentUserPrompt() throws {
        let jsonl = """
        {"type":"user","text":"make a screenshot"}
        {"type":"tool_result","output":"data:image/png;base64,QUJDRA=="}
        {"type":"assistant","text":"here you go"}
        {"type":"user","text":"next task data:image/png;base64,QUJDRA=="}
        """
        let url = try writeTempJSONL(jsonl + "\n")
        defer { try? FileManager.default.removeItem(at: url) }

        let events: [SessionEvent] = [
            makeEvent(id: "e0", kind: .user, text: "make a screenshot", rawJSON: #"{"type":"user"}"#),
            makeEvent(id: "e1", kind: .tool_result, text: nil, rawJSON: #"{"type":"tool_result"}"#),
            makeEvent(id: "e2", kind: .assistant, text: "here you go", rawJSON: #"{"type":"assistant"}"#),
            makeEvent(id: "e3", kind: .user, text: "next task", rawJSON: #"{"type":"user"}"#)
        ]
        let session = Session(id: "s1",
                              source: .codex,
                              startTime: nil,
                              endTime: nil,
                              model: nil,
                              filePath: url.path,
                              eventCount: events.count,
                              events: events)

        let located = try Base64ImageDataURLScanner.scanFileWithLineIndexes(at: url, maxMatches: 20)
        XCTAssertEqual(located.count, 2)

        let mapped = located.map { item -> (Int, Int?) in
            (item.lineIndex, userPromptIndexForLineIndex(session: session, lineIndex: item.lineIndex))
        }
        .sorted(by: { $0.0 < $1.0 })

        XCTAssertEqual(mapped.map(\.0), [1, 3])
        XCTAssertEqual(mapped.map(\.1), [0, 1])
    }

    func testNoUserEventsReturnsNil() {
        let session = Session(id: "s2",
                              source: .codex,
                              startTime: nil,
                              endTime: nil,
                              model: nil,
                              filePath: "/tmp/none.jsonl",
                              eventCount: 2,
                              events: [
                                makeEvent(id: "e0", kind: .assistant, text: "hi", rawJSON: "{}"),
                                makeEvent(id: "e1", kind: .tool_result, text: nil, rawJSON: "{}")
                              ])
        XCTAssertNil(userPromptIndexForLineIndex(session: session, lineIndex: 0))
        XCTAssertNil(userPromptIndexForLineIndex(session: session, lineIndex: 10))
    }

    // MARK: - Grok: line index vs event index

    /// Stages a Grok transcript in the real on-disk layout (`<bucket>/<sessionID>/`)
    /// so the parser exercises its own session-id derivation and the mapper scans the
    /// same file the parser read. The session id is fresh per call because
    /// `SessionTranscriptBuilder.coalescedBlocks` caches blocks under it.
    private func stageGrokTranscript(_ transcript: String) throws -> URL {
        let sessionID = UUID().uuidString
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("InlineSessionImageMappingTests-\(sessionID)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let sessionDir = root
            .appendingPathComponent("sessions", isDirectory: true)
            // Grok percent-encodes the working directory into the bucket name.
            .appendingPathComponent("%2Ftmp%2Fas-agent-lab%2Fgrok%2Fproject", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let url = sessionDir.appendingPathComponent("chat_history.jsonl")
        try transcript.write(to: url, atomically: true, encoding: .utf8)
        try #"{"info":{"id":"\#(sessionID)","cwd":"/tmp/as-agent-lab/grok/project"}}"#
            .write(to: sessionDir.appendingPathComponent("summary.json"), atomically: true, encoding: .utf8)
        return url
    }

    /// A Grok image has to land under the prompt it actually followed, even after the
    /// event stream has run ahead of the line numbering.
    ///
    /// The scanner reports a *physical line index*; the shared mapper otherwise
    /// compares that against positions in `session.events`. Line 1 below is one
    /// record that yields three events (assistant text plus two tool calls), so by
    /// the time the second prompt is read it sits at event index 5 while living on
    /// line 3. The image is on line 4: "last user event index <= 4" then picks the
    /// *first* prompt, and the screenshot renders under the wrong turn.
    func testGrokImageMapsToTheLaterPromptWhenEventsOutrunLines() throws {
        let transcript = """
        {"type":"user","content":[{"type":"text","text":"first prompt"}],"prompt_index":0}
        {"type":"assistant","content":"Reading both files.","tool_calls":[{"id":"call-1","name":"read_file","arguments":"{}"},{"id":"call-2","name":"read_file","arguments":"{}"}]}
        {"type":"tool_result","content":"first file","tool_call_id":"call-1"}
        {"type":"user","content":[{"type":"text","text":"second prompt"}],"prompt_index":1}
        {"type":"tool_result","content":"screenshot","tool_call_id":"call-2","images":["data:image/png;base64,QUJDRA=="]}
        """
        let url = try stageGrokTranscript(transcript)
        let session = try XCTUnwrap(GrokSessionParser.parseFileFull(at: url))

        // Guard the premise: if a future parser change stops emitting several events
        // per record, this fixture no longer reproduces the drift and the assertions
        // below would pass for the wrong reason.
        XCTAssertEqual(session.events.map(\.id),
                       ["0-u", "1-a", "1-t0", "1-t1", "2-r", "3-u", "4-r"])
        let userEventIndices: [Int] = session.events.enumerated().compactMap { (idx, ev) in
            ev.kind == .user ? idx : nil
        }
        XCTAssertEqual(userEventIndices, [0, 5],
                       "guard: the second prompt must sit at an event index (5) past its line index (3)")

        let located = try Base64ImageDataURLScanner.scanFileWithLineIndexes(at: url, maxMatches: 20)
        XCTAssertEqual(located.map(\.lineIndex), [4], "guard: the image must be on transcript line 4")

        let mapped = SessionInlineImageMapper.imagesByUserBlockIndex(for: session)

        // "3-u" is the second prompt; it coalesces into block 5 (one block per event,
        // nothing merges here). Block 0 is the first prompt — where the image landed
        // before the line/event spaces were reconciled.
        XCTAssertEqual(mapped.keys.sorted(), [5])
        XCTAssertNil(mapped[0], "the image must not fall back onto the first prompt")
        XCTAssertEqual(mapped[5]?.count, 1)
        XCTAssertEqual(mapped[5]?.first?.imageEventID, "3-u")
        XCTAssertEqual(mapped[5]?.first?.userPromptIndex, 1)
        XCTAssertEqual(mapped[5]?.first?.payload.mediaType, "image/png")
    }

    /// The same defect on the second surface: the Image Browser labels each image
    /// with the prompt it followed, and `ImageBrowserViewModel.buildItems` fed the
    /// stored *physical line index* into its own copy of the nearest-user rule, which
    /// compares against positions in `session.events`.
    ///
    /// Goes through the real `ImageBrowserIndexCache` rather than a hand-built index
    /// so the fixture also has to survive the browser's `base64PayloadLength >= 64 /
    /// approxBytes >= 32` floor, which the inline path does not apply.
    @MainActor
    func testGrokImageBrowserLabelsTheLaterPromptWhenEventsOutrunLines() async throws {
        let base64 = String(repeating: "A", count: 160)
        let transcript = """
        {"type":"user","content":[{"type":"text","text":"first prompt"}],"prompt_index":0}
        {"type":"assistant","content":"Reading both files.","tool_calls":[{"id":"call-1","name":"read_file","arguments":"{}"},{"id":"call-2","name":"read_file","arguments":"{}"}]}
        {"type":"tool_result","content":"first file","tool_call_id":"call-1"}
        {"type":"user","content":[{"type":"text","text":"second prompt"}],"prompt_index":1}
        {"type":"tool_result","content":"screenshot","tool_call_id":"call-2","images":["data:image/png;base64,\(base64)"]}
        """
        let url = try stageGrokTranscript(transcript)
        let session = try XCTUnwrap(GrokSessionParser.parseFileFull(at: url))
        XCTAssertEqual(session.events.map(\.id),
                       ["0-u", "1-a", "1-t0", "1-t1", "2-r", "3-u", "4-r"],
                       "guard: the second prompt must sit at event index 5 while living on line 3")

        let cacheRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ImageBrowserCache-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: cacheRoot) }
        let cache = ImageBrowserIndexCache(cacheRootOverride: cacheRoot)
        let index = await cache.getOrBuildIndex(for: session, maxMatches: 10)
        XCTAssertEqual(index.spans.map(\.lineIndex), [4],
                       "guard: the stored span must record the image on transcript line 4")

        // Same overridden cache root on the view model so its background indexing
        // cannot write into the user's real Caches directory.
        let viewModel = ImageBrowserViewModel(indexCache: cache)
        viewModel.updateSessions(allSessions: [session], seedSession: session)
        viewModel.cancelBackgroundWork()

        let items = viewModel.buildItems(for: session, index: index)
        XCTAssertEqual(items.count, 1)
        let item = try XCTUnwrap(items.first)

        // Before the fix all three landed on the first prompt: eventID "0-u",
        // userPromptIndex 0, lineIndex 0.
        XCTAssertEqual(item.eventID, "3-u")
        XCTAssertEqual(item.userPromptIndex, 1)
        // `Item.lineIndex` is misnamed: it holds the resolved *event* index, which is
        // what `loadedUserPromptText` indexes into `session.events`.
        XCTAssertEqual(item.lineIndex, 5)
        XCTAssertEqual(viewModel.loadedUserPromptText(for: item), "second prompt")
    }

    /// The transcript half of the preamble-preference pin. Its counterpart below covers
    /// the Image Browser, and both now run through the same `ImageUserTurnResolver` — so
    /// this pair is what makes a change to that shared rule fail on both surfaces rather
    /// than only the one that happens to have coverage.
    ///
    /// The transcript has had this preference since `843bf476` with nothing asserting it;
    /// that gap is why the browser's copy could lose it and stay quiet.
    ///
    /// Uses Codex rather than Claude because the transcript path picks its scanner per
    /// provider and Claude's wants Claude's own record shape, while Codex takes the
    /// generic data-URI scanner a synthetic fixture can satisfy. The preference itself is
    /// gated identically for both, and the browser counterpart below covers Claude.
    func testTranscriptSkipsAMidSessionPreambleTurn() throws {
        let jsonl = """
        {"type":"user","text":"explain this repo"}
        {"type":"assistant","text":"sure"}
        {"type":"user","text":"<system-reminder>the user opened a new file</system-reminder>"}
        {"type":"tool_result","output":{"image_url":"data:image/png;base64,QUJDRA=="}}
        """
        let url = try writeTempJSONL(jsonl + "\n")
        defer { try? FileManager.default.removeItem(at: url) }

        let events: [SessionEvent] = [
            makeEvent(id: "e0", kind: .user, text: "explain this repo", rawJSON: #"{"type":"user"}"#),
            makeEvent(id: "e1", kind: .assistant, text: "sure", rawJSON: #"{"type":"assistant"}"#),
            makeEvent(id: "e2",
                      kind: .user,
                      text: "<system-reminder>the user opened a new file</system-reminder>",
                      rawJSON: #"{"type":"user"}"#),
            makeEvent(id: "e3", kind: .tool_result, text: nil, rawJSON: #"{"type":"tool_result"}"#)
        ]
        let session = Session(id: "codex-preamble-transcript",
                              source: .codex,
                              startTime: nil,
                              endTime: nil,
                              model: nil,
                              filePath: url.path,
                              eventCount: events.count,
                              events: events)

        XCTAssertTrue(Session.isAgentsPreambleText(events[2].text ?? ""),
                      "guard: event 2 must classify as scaffolding, or this test proves nothing")

        let mapped = SessionInlineImageMapper.imagesByUserBlockIndex(for: session)
        let placed = mapped.values.flatMap { $0 }
        XCTAssertEqual(placed.count, 1)
        // Without the preference this resolves to "e2" — the `<system-reminder>`.
        XCTAssertEqual(placed.first?.imageEventID, "e0")
        XCTAssertEqual(placed.first?.userPromptIndex, 0)
    }

    /// Pins the Image Browser to the same preamble preference the transcript mapper
    /// uses. The two used to carry separate copies of the nearest-user rule and this
    /// is exactly where they had drifted: the browser's copy was the older one and
    /// took the literal nearest user record, so an image whose nearest preceding turn
    /// was injected scaffolding got labelled with the scaffolding here while the
    /// transcript labelled it with the real prompt — the same image, two answers.
    ///
    /// Claude is the live case: it injects `<system-reminder>` blocks into user
    /// records mid-session, so the scaffolding turn is not merely the first record
    /// (which is why a Codex-shaped fixture would not discriminate — its preamble is
    /// the opening record, and every rule resolves past it identically).
    ///
    /// Events map 1:1 to lines here on purpose, to isolate the preamble behaviour
    /// from the line/event drift the Grok tests above cover.
    @MainActor
    func testImageBrowserSkipsAMidSessionPreambleTurnLikeTheTranscriptDoes() throws {
        let events: [SessionEvent] = [
            makeEvent(id: "e0", kind: .user, text: "explain this repo", rawJSON: #"{"type":"user"}"#),
            makeEvent(id: "e1", kind: .assistant, text: "sure", rawJSON: #"{"type":"assistant"}"#),
            makeEvent(id: "e2",
                      kind: .user,
                      text: "<system-reminder>the user opened a new file</system-reminder>",
                      rawJSON: #"{"type":"user"}"#),
            makeEvent(id: "e3", kind: .tool_result, text: nil, rawJSON: #"{"type":"tool_result"}"#)
        ]
        let session = Session(id: "claude-preamble",
                              source: .claude,
                              startTime: nil,
                              endTime: nil,
                              model: nil,
                              filePath: "/tmp/does-not-need-to-exist.jsonl",
                              eventCount: events.count,
                              events: events)

        XCTAssertTrue(Session.isAgentsPreambleText(events[2].text ?? ""),
                      "guard: event 2 must classify as scaffolding, or this test proves nothing")

        let signature = ImageBrowserFileSignature(filePath: session.filePath,
                                                  fileSizeBytes: 1,
                                                  modifiedAtUnixSeconds: 1)
        let index = ImageBrowserStoredIndex(
            signature: signature,
            spans: [ImageBrowserStoredSpan(startOffset: 0,
                                           endOffset: 200,
                                           mediaType: "image/png",
                                           base64PayloadOffset: 40,
                                           base64PayloadLength: 160,
                                           approxBytes: 120,
                                           lineIndex: 3)],
            openCodeImages: nil,
            copilotAttachments: nil,
            antigravityImages: nil,
            createdAtUnixSeconds: 1
        )

        let viewModel = ImageBrowserViewModel()
        viewModel.cancelBackgroundWork()
        let items = viewModel.buildItems(for: session, index: index)

        XCTAssertEqual(items.count, 1)
        let item = try XCTUnwrap(items.first)
        // Before the alignment this resolved to event 2 — the `<system-reminder>` —
        // giving eventID "e2" and userPromptIndex 1.
        XCTAssertEqual(item.eventID, "e0")
        XCTAssertEqual(item.userPromptIndex, 0)
        XCTAssertEqual(item.lineIndex, 0)
    }

    /// Pins the Grok event-id format, which is a cross-file contract and not an
    /// implementation detail: `SessionInlineImageMapper` reads the transcript line
    /// back out of the id to place inline images, and a rename that only touched
    /// `GrokSessionParser` would silently return images to the wrong prompt rather
    /// than fail anything. Every record type is present so no suffix can drift
    /// unnoticed.
    func testGrokEventIDsEncodeTheirTranscriptLine() throws {
        let transcript = """
        {"type":"system","content":"You are Grok."}
        {"type":"user","content":[{"type":"text","text":"hi"}],"prompt_index":0}
        {"type":"reasoning","summary":[{"text":"Considering the request."}]}
        {"type":"assistant","content":"On it.","tool_calls":[{"id":"call-1","name":"read_file","arguments":"{}"}]}
        {"type":"tool_result","content":"file body","tool_call_id":"call-1"}
        {"type":"backend_tool_call","kind":{"tool_type":"web_search","action":{"query":"grok"}}}
        {"type":"assistant","content":""}
        {"type":"some_future_record"}
        """
        let url = try stageGrokTranscript(transcript)
        let session = try XCTUnwrap(GrokSessionParser.parseFileFull(at: url))

        XCTAssertEqual(session.events.map(\.id),
                       ["0-s", "1-u", "2-think", "3-a", "3-t0", "4-r", "5-b", "6-m", "7-m"])

        let expectedLines: [Int?] = [0, 1, 2, 3, 3, 4, 5, 6, 7]
        XCTAssertEqual(session.events.map { GrokSessionParser.sourceLineIndex(forEventID: $0.id) },
                       expectedLines)

        XCTAssertEqual(GrokSessionParser.eventID(lineIndex: 41, suffix: "t2"), "41-t2")
        XCTAssertEqual(GrokSessionParser.sourceLineIndex(forEventID: "41-t2"), 41)
        // Anything that does not lead with a line number decodes to nil so the mapper
        // falls back instead of inventing a position.
        XCTAssertNil(GrokSessionParser.sourceLineIndex(forEventID: "abc-000042"))
        XCTAssertNil(GrokSessionParser.sourceLineIndex(forEventID: "12"))
    }

    func testCodexInlineImageMarkersRenderAsBracketedToken() {
        let events: [SessionEvent] = [
            makeEvent(id: "e0",
                      kind: .user,
                      text: "<image name=[Image #1]></image>[Image #1] hello",
                      rawJSON: #"{"type":"user"}"#)
        ]
        let session = Session(id: "s3",
                              source: .codex,
                              startTime: nil,
                              endTime: nil,
                              model: nil,
                              filePath: "/tmp/none.jsonl",
                              eventCount: events.count,
                              events: events)

        let txt = SessionTranscriptBuilder.buildPlainTerminalTranscript(session: session,
                                                                        filters: .current(showTimestamps: false, showMeta: false))
        XCTAssertTrue(txt.contains("[Image #1]"))
        XCTAssertFalse(txt.contains("<image"))
        XCTAssertFalse(txt.contains("</image>"))
    }
}
