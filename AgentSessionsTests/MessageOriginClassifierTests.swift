import XCTest
@testable import AgentSessions

final class MessageOriginClassifierTests: XCTestCase {
    private func event(_ text: String, kind: SessionEventKind = .user) -> SessionEvent {
        SessionEvent(id: UUID().uuidString, timestamp: nil, kind: kind, role: nil, text: text,
                     toolName: nil, toolInput: nil, toolOutput: nil, messageID: nil,
                     parentID: nil, isDelta: false, rawJSON: "{}")
    }
    private func blocks(_ events: [SessionEvent], context: Bool = false) -> [SessionTranscriptBuilder.LogicalBlock] {
        let session = Session(id: UUID().uuidString, startTime: nil, endTime: nil, model: nil,
                              filePath: "/tmp/message-test", eventCount: events.count, events: events)
        return SessionTranscriptBuilder.coalescedBlocks(for: session, includeMeta: false, includeMessageContext: context)
    }
    func testUserBlockDefaultsToTyped() {
        let block = blocks([event("hello")])[0]
        XCTAssertEqual(block.presentation, MessagePresentation(origin: .typed, body: "hello", summary: nil))
    }
    func testCoalesceCopiesProvenanceAndSetsPresentation() {
        var e = event("raw")
        e.messageOrigin = .context(kinds: ["x"])
        e.messageDisplayText = "display"
        e.messageHasEncryptedContent = true
        let b = blocks([e])[0]
        XCTAssertEqual(b.messageOrigin, e.messageOrigin)
        XCTAssertEqual(b.presentation?.body, "display")
        XCTAssertEqual(b.messageHasEncryptedContent, true)
        XCTAssertEqual(b.text, "raw")
    }
    func testTurnAbortedSplitKeepsProvenance() {
        var e = event("hi<turn_aborted>x</turn_aborted>")
        e.messageOrigin = .typed
        e.messageDisplayText = "hi<turn_aborted>x</turn_aborted>"
        let b = blocks([e]).first { $0.kind == .user }!
        XCTAssertEqual(b.messageOrigin, .typed)
        XCTAssertEqual(b.presentation?.body, "hi")
    }
    func testSplitPreservesDisplayBodyWhenNoticeShapesDiffer() {
        var e = event("before<turn_aborted>x</turn_aborted>after")
        e.messageOrigin = .typed
        e.messageDisplayText = "decoded body"
        let userBlocks = blocks([e]).filter { $0.kind == .user }
        XCTAssertEqual(userBlocks.map { $0.presentation?.body ?? "" }.joined(), "decoded body")
        XCTAssertEqual(userBlocks.map(\.text), ["before", "after"])
    }
    func testNoticeOnlySplitKeepsDecodedDisplayText() {
        var e = event("<turn_aborted>x</turn_aborted>")
        e.messageDisplayText = "decoded body"
        let result = blocks([e])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].messageDisplayText, "decoded body")
        XCTAssertTrue(result[0].text.contains("Turn Aborted"))
    }
    func testToolBlocksHaveNoPresentation() {
        XCTAssertNil(blocks([event("output", kind: .tool_result)])[0].presentation)
    }
    func testRowStyles() {
        func style(_ origin: MessageOrigin?, _ body: String = "x") -> MessageRowStyle {
            MessagePresentation(origin: origin, body: body, summary: nil).rowStyle
        }
        XCTAssertEqual(style(.typed), .card)
        XCTAssertEqual(style(nil), .card)
        XCTAssertEqual(style(.context(kinds: [])), .line)
        XCTAssertEqual(style(.placeholder), .none)
        for origin in [MessageOrigin.parentTask, .approvalRequest, .approvalVerdict(outcome: "ok"), .command(name: "run")] {
            XCTAssertEqual(style(origin), .card)
        }
        for origin in [MessageOrigin.notification(kind: "x"), .compaction, .skill(name: "x"), .scheduled(kind: "x"), .harnessRetry] {
            XCTAssertEqual(style(origin), .line)
        }
        XCTAssertEqual(style(.peer(from: "a")), .card)
        XCTAssertEqual(style(.peer(from: "a"), ""), .line)
        XCTAssertTrue(MessageOrigin.context(kinds: []).isHiddenContext)
        XCTAssertTrue(MessageOrigin.skill(name: "x").isHiddenContext)
        XCTAssertTrue(MessageOrigin.harnessRetry.isHiddenContext)
        XCTAssertFalse(MessageOrigin.notification(kind: "x").isHiddenContext)
    }
    func testSessionProjectionAndCacheIsolation() {
        var peer = event("raw peer", kind: .meta)
        peer.messageOrigin = .peer(from: "worker")
        peer.messageDisplayText = "peer body"
        var context = event("raw context", kind: .meta)
        context.messageOrigin = .context(kinds: ["environment"])
        let s = Session(id: UUID().uuidString, startTime: nil, endTime: nil, model: nil,
                        filePath: "/tmp/projections", eventCount: 3, events: [peer, context, event("task")])
        let raw = SessionTranscriptBuilder.coalescedBlocks(for: s, includeMeta: false)
        let projected = SessionTranscriptBuilder.coalescedBlocks(for: s, includeMeta: false, includeMessageContext: true)
        XCTAssertEqual(raw.count, 1)
        XCTAssertEqual(projected.count, 3)
        XCTAssertEqual(projected[0].kind, .user)
        XCTAssertEqual(projected[0].text, "raw peer")
        XCTAssertEqual(projected[0].presentation?.body, "peer body")
        XCTAssertEqual(projected[1].presentation?.origin, context.messageOrigin)
        XCTAssertEqual(SessionTranscriptBuilder.coalescedBlocks(for: s, includeMeta: false), raw)
        XCTAssertEqual(s.events[0].kind, .meta)
        XCTAssertEqual(s.events[0].text, "raw peer")
    }
    func testRawTerminalOutputIsUnaffectedByPresentationMetadata() {
        let raw = event("literal <environment_context>quoted</environment_context>")
        var enriched = raw
        enriched.messageOrigin = .typed
        enriched.messageDisplayText = "a different display body"
        enriched.messageHasEncryptedContent = true
        let filters: TranscriptFilters = .current(showTimestamps: false, showMeta: false)
        let before = SessionTranscriptBuilder.buildPlainTerminalTranscript(events: [raw], source: .codex, filters: filters)
        let after = SessionTranscriptBuilder.buildPlainTerminalTranscript(events: [enriched], source: .codex, filters: filters)
        XCTAssertEqual(after, before)
        XCTAssertTrue(after.contains("quoted"))
    }
    func testCodableFieldsAreOptionalAndRoundTrip() throws {
        var enriched = event("raw")
        enriched.messageOrigin = .approvalVerdict(outcome: "approved")
        enriched.messageDisplayText = "display"
        enriched.messageHasEncryptedContent = true
        let data = try JSONEncoder().encode(enriched)
        XCTAssertEqual(try JSONDecoder().decode(SessionEvent.self, from: data), enriched)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "messageOrigin")
        legacy.removeValue(forKey: "messageDisplayText")
        legacy.removeValue(forKey: "messageHasEncryptedContent")
        let decoded = try JSONDecoder().decode(SessionEvent.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(decoded.messageOrigin)
        XCTAssertNil(decoded.messageDisplayText)
        XCTAssertNil(decoded.messageHasEncryptedContent)
    }
    func testTypedMetaIsSessionUserAndLiteralTagsRemainTyped() {
        var e = event("<system>quoted</system>", kind: .meta)
        e.messageOrigin = .typed
        let projected = blocks([e], context: true)
        XCTAssertEqual(projected[0].kind, .user)
        XCTAssertEqual(projected[0].presentation?.origin, .typed)
        XCTAssertEqual(projected[0].presentation?.body, e.text)
        XCTAssertTrue(blocks([e]).isEmpty)
    }
    func testMergedDisplayTextPreservesRawText() {
        var a = event("rawA", kind: .assistant)
        var b = event("rawB", kind: .assistant)
        a = SessionEvent(id: a.id, timestamp: nil, kind: .assistant, role: nil, text: a.text, toolName: nil, toolInput: nil, toolOutput: nil, messageID: "chain", parentID: nil, isDelta: true, rawJSON: "{}")
        b = SessionEvent(id: b.id, timestamp: nil, kind: .assistant, role: nil, text: b.text, toolName: nil, toolInput: nil, toolOutput: nil, messageID: "chain", parentID: nil, isDelta: true, rawJSON: "{}")
        a.messageDisplayText = "displayA"
        let merged = blocks([a,b])[0]
        XCTAssertEqual(merged.text, "rawArawB")
        XCTAssertEqual(merged.presentation?.body, "displayArawB")
    }
    private func classify(_ text: String, _ source: SessionSource = .codex, origin: MessageOrigin? = nil, assistant: Bool = false, encrypted: Bool = false) -> MessagePresentation {
        var e = event(text, kind: assistant ? .assistant : .user)
        e.messageOrigin = origin
        e.messageHasEncryptedContent = encrypted
        return MessageOriginClassifier.presentation(for: blocks([e])[0], context: .init(source: source, isFirstUserBlock: false))!
    }
    func testInterruptMarkerIsNotificationUnlessExplicitlyTyped() {
        let text = "[Request interrupted by user for tool use]"
        let notice = classify(text, .claude)
        XCTAssertEqual(notice.origin, .notification(kind: "interruption"))
        XCTAssertEqual(notice.summary, "Request interrupted")
        XCTAssertEqual(notice.body, text)
        XCTAssertEqual(classify(text, .claude, origin: .typed).origin, .typed)
        XCTAssertEqual(classify("Please explain " + text, .claude).origin, .typed)
    }

    func testClaudeLeadingReminderPreservesHumanTailAndRawBlock() {
        let tail = "Please explain café.\n\n  Keep trailing whitespace.  \n"
        let raw = " \n<system-reminder>harness</system-reminder>\n\t" + tail
        let e = event(raw)
        let session = Session(id: UUID().uuidString, source: .claude, startTime: nil, endTime: nil,
                              model: nil, filePath: "/tmp/reminder", eventCount: 1, events: [e])
        let b = SessionTranscriptBuilder.coalescedBlocks(for: session, includeMeta: false)[0]
        XCTAssertEqual(b.presentation?.origin, .typed)
        XCTAssertEqual(b.presentation?.body, tail)
        XCTAssertEqual(b.text, raw)
        XCTAssertNil(b.messageOrigin)
        XCTAssertEqual(session.events[0].text, raw)
        XCTAssertEqual(session.events[0].rawJSON, e.rawJSON)
    }
    func testClaudeRepeatedLeadingRemindersPreserveHugeTail() {
        let tail = "Human " + String(repeating: "é", count: 80_000) + "  \n"
        let prefix = "<system-reminder>one</system-reminder>\n<system-reminder>two</system-reminder>\n"
        let p = classify(prefix + tail, .claude)
        XCTAssertEqual(p.origin, .typed)
        XCTAssertEqual(p.body, tail)
    }
    func testClaudeReminderRemovalPreservesExplicitProvenanceAndOtherMarkup() {
        for raw in ["<custom-context>x</custom-context>\nHuman", "<div>x</div>\nHuman"] {
            XCTAssertEqual(classify(raw, .claude, origin: .typed).body, raw)
            XCTAssertEqual(classify(raw, .claude, origin: .typed).origin, .typed)
        }
        let raw = "<system-reminder>x</system-reminder>\nHuman"
        XCTAssertEqual(classify(raw, .codex).body, raw)
        XCTAssertEqual(classify(raw, .claude, origin: .context(kinds: ["claude.meta"])).body, raw)
        for tail in ["<div>Human</div>", "<custom-context>Human</custom-context>"] {
            let p = classify("<system-reminder>x</system-reminder>\n" + tail, .claude)
            XCTAssertEqual(p.origin, .typed)
            XCTAssertEqual(p.body, tail)
        }
    }
    func testExplicitHumanReminderPrefixShowsOnlyTheTypedTail() {
        let raw = "<system-reminder>a</system-reminder>\n<system-reminder>b</system-reminder>\n\nPlease fix it."
        let p = classify(raw, .claude, origin: .typed)
        XCTAssertEqual(p.origin, .typed)
        XCTAssertEqual(p.body, "Please fix it.")
        // Same safety rules: an unproven prefix keeps the whole text, and a reminder-only
        // message never loses its text.
        for kept in ["<system-reminder>unclosed Please", "<system-reminder>x</system-reminder>"] {
            XCTAssertEqual(classify(kept, .claude, origin: .typed).body, kept)
            XCTAssertEqual(classify(kept, .claude, origin: .typed).origin, .typed)
        }
    }
    func testExplicitHumanPasteShowsLabeledBlock() {
        let raw = "\n\n<pasted_content id=\"36e2\">\nTask: build it.\n- step one\n</pasted_content id=\"36e2\">\n\nuse opus please"
        let p = classify(raw, .claude, origin: .typed)
        XCTAssertEqual(p.origin, .typed)
        XCTAssertEqual(p.body, "*Pasted text*\n\n```\nTask: build it.\n- step one\n```\n\nuse opus please")
        let unclosed = "see <pasted_content id=\"1\">half"
        XCTAssertEqual(classify(unclosed, .claude, origin: .typed).body, unclosed)
        XCTAssertEqual(classify(raw, .codex, origin: .typed).body, raw)
    }
    func testCrossSessionMessageIsPeerCard() {
        let encoded = "<cross-session-message from=\"local_9377\" name=\"FABLE - orchestration\" encoded=\"1\">\nRedirect: ship it.\n</cross-session-message>"
        let human = classify(encoded, .claude, origin: .typed)
        XCTAssertEqual(human.origin, .peer(from: "FABLE - orchestration"))
        XCTAssertEqual(human.body, "Redirect: ship it.")
        XCTAssertEqual(human.rowStyle, .card)
        let reminded = "<system-reminder>\nLinked sessions now\n</system-reminder>\n\n<cross-session-message from=\"uds:/tmp/x.sock\" from-session=\"local_1\" from-name=\"Admin &amp; spec\" from-mode=\"prompting\">\nPlease resume.\n</cross-session-message>"
        let inferred = classify(reminded, .claude)
        XCTAssertEqual(inferred.origin, .peer(from: "Admin & spec"))
        XCTAssertEqual(inferred.body, "Please resume.")
        XCTAssertEqual(classify(encoded, .claude, origin: .peer(from: "another session")).origin, .peer(from: "FABLE - orchestration"))
        let cipher = classify("<cross-session-message from=\"x\" encoded=\"1\">gAAAAABcipher</cross-session-message>", .claude, origin: .typed)
        XCTAssertFalse(cipher.body.contains("gAAAAA"))
        XCTAssertEqual(cipher.summary, "Message from another session · content encrypted in the log")
    }
    func testContextSummaryUsesReadableLabels() {
        let kinds = ["agents_md.instructions", "agents_md.other", "environments.environment_context", "environment_context",
                     "additional_content.codex_apps_selected_page_part_2", "goal.internal_context", "some_new.kind_id"]
        XCTAssertEqual(MessageOriginText.summary(.context(kinds: kinds), body: "", scanned: "", encrypted: false),
                       "Context · AGENTS.md, environment, selected page, goal, some new kind id")
        XCTAssertEqual(MessageOriginText.summary(.context(kinds: ["claude.meta"]), body: "", scanned: "", encrypted: false), "Context · harness note")
        let task = "<task-notification><summary>Build</summary><status>killed</status></task-notification>"
        XCTAssertEqual(MessageOriginText.summary(.notification(kind: "task"), body: "", scanned: task, encrypted: false), "Background task stopped · Build")
        let odd = "<task-notification><summary>Build</summary><status>paused</status></task-notification>"
        XCTAssertEqual(MessageOriginText.summary(.notification(kind: "task"), body: "", scanned: odd, encrypted: false), "Background task paused · Build")
    }
    func testClaudeAmbiguousReminderPrefixesStayUnchanged() {
        let complete = "<system-reminder>x</system-reminder>"
        for raw in ["<system-reminder>unclosed Human", complete + "<system-reminder>unclosed Human",
                    "<system-reminder>outer<system-reminder>nested</system-reminder>Human",
                    "<system-reminder>" + String(repeating: "x", count: 70_000) + "</system-reminder>Human",
                    complete + String(repeating: " ", count: 70_000) + "Human",
                    complete + "<system-reminder attribute=\"x\">unproven</system-reminder>Human"] {
            XCTAssertEqual(classify(raw, .claude).body, raw)
        }
        XCTAssertEqual(classify(complete + "\n", .claude).origin, .context(kinds: ["system-reminder"]))
    }
    func testClaudeReminderHumanTailRemainsParentTaskInChild() {
        let raw = "<system-reminder>harness</system-reminder>\nDo the task.  \n"
        let session = Session(id: UUID().uuidString, source: .claude, startTime: nil, endTime: nil,
                              model: nil, filePath: "/tmp/reminder-child", eventCount: 1,
                              events: [event(raw)], parentSessionID: "parent")
        let b = SessionTranscriptBuilder.coalescedBlocks(for: session, includeMeta: false)[0]
        XCTAssertEqual(b.presentation?.origin, .parentTask)
        XCTAssertEqual(b.presentation?.body, "Do the task.  \n")
        XCTAssertEqual(b.text, raw)
    }

    func testSourceRuleTable() {
        let rows: [(SessionSource, String, MessageOrigin)] = [
            (.codex, "<system-reminder>x</system-reminder>", .context(kinds: ["system-reminder"])),
            (.codex, "<environment_context>x</environment_context>", .context(kinds: ["codex.preamble"])),
            (.claude, "<task-notification><summary>done</summary><status>ok</status></task-notification>", .notification(kind: "task")),
            (.claude, "Another Claude session sent a message:\nhello", .peer(from: "another session")),
            (.claude, "The coordinator sent a message while you were working:\nhello", .peer(from: "coordinator")),
            (.claude, "<command-name>/x</command-name><command-args>hello</command-args>", .command(name: "/x")),
            (.kimi, "<bash-input>ls</bash-input>", .command(name: "!")),
            (.claude, "<local-command-caveat>x</local-command-caveat>", .context(kinds: ["claude.caveat"])),
            (.grok, "<user_query>hello</user_query>", .typed),
            (.grok, "<user_info>x</user_info><rules>x</rules>", .context(kinds: ["grok.context"])),
            (.cline, "<user_input mode=\"act\">hello</user_input>", .typed),
            (.cursor, "<timestamp>now</timestamp>hello", .typed),
            (.hermes, "[SYSTEM: You are running as a scheduled cron job]", .scheduled(kind: "cron")),
            (.hermes, "You just executed tool calls but returned an empty response", .harnessRetry),
            (.openclaw, "[OpenClaw heartbeat poll]", .scheduled(kind: "heartbeat")),
            (.openclaw, "[cron: x]", .scheduled(kind: "cron")),
            (.openclaw, "Conversation info (untrusted metadata): x", .context(kinds: ["openclaw.metadata"])),
            (.pi, "<custom-context>x</custom-context>", .context(kinds: ["custom-context"]))]
        for (source, text, origin) in rows { XCTAssertEqual(classify(text, source).origin, origin, text) }
    }
    func testHTMLLikeTypedTextStaysTyped() {
        for text in ["<div>hi</div>", "<details>x</details>"] { XCTAssertEqual(classify(text).origin, .typed) }
    }
    func testExplicitTypedMarkupStaysTyped() {
        for text in ["<custom-context>x</custom-context>", "<environment_context>x</environment_context>", "<system-reminder>x</system-reminder>"] {
            XCTAssertEqual(classify(text, origin: .typed).origin, .typed)
        }
    }
    func testEnvelopeDecodingWithProvenance() {
        XCTAssertEqual(classify("<user_query>hello</user_query>", .grok, origin: .typed).body, "hello")
        XCTAssertEqual(classify("<bash-input>ls</bash-input>", .kimi).body, "```\nls\n```")
    }
    func testQuestionRepliesAndMalformedJSON() {
        let reply = "<send_user_message_question_reply>[{\"question\":\"Why?\",\"answer\":\"\"}]</send_user_message_question_reply>"
        XCTAssertEqual(classify(reply, origin: .typed).body, "**Question:** Why?\n\n**Answer:** No answer")
        let malformed = "<send_user_message_question_reply>bad</send_user_message_question_reply>"
        XCTAssertEqual(classify(malformed).body, malformed)
    }
    func testOldCodexPreambleIsContextFirstPromptTyped() {
        XCTAssertEqual(classify("# AGENTS.md instructions for /x\nhi").origin, .context(kinds: ["codex.preamble"]))
        XCTAssertEqual(classify("fix the bug").origin, .typed)
    }
    func testCitationsStripped() {
        let p = classify("answer<oai-mem-citation><citation_entries>x</citation_entries></oai-mem-citation>", assistant: true)
        XCTAssertEqual(p.body, "answer\n\n*Memory citations: 1*")
        XCTAssertEqual(classify("<oai-mem-citation>x</oai-mem-citation>", assistant: true).origin, .placeholder)
    }
    func testJSONAgentMessageAsFencedJSONBlock() {
        XCTAssertEqual(classify("{\"z\":1,\"a\":{\"b\":[1,\"x,y\"],\"e\":{}},\"u\":\"a/b\"}", assistant: true).body,
                       "```json\n{\n  \"z\": 1,\n  \"a\": {\n    \"b\": [\n      1,\n      \"x,y\"\n    ],\n    \"e\": {}\n  },\n  \"u\": \"a/b\"\n}\n```")
        let written = "{\n    \"b\": 1,\n    \"a\": 2\n}"
        XCTAssertEqual(classify(written, assistant: true).body, "```json\n" + written + "\n```")
    }
    func testPlaceholders() {
        for text in ["", " ", "(empty)", "[REDACTED]"] { XCTAssertEqual(classify(text, assistant: true).origin, .placeholder) }
    }
    func testNoCiphertextInAnyBody() {
        let p = classify("header gAAAAA" + String(repeating: "x", count: 40), origin: .peer(from: "worker"), encrypted: true)
        XCTAssertFalse(p.body.contains("gAAAAA"))
        XCTAssertTrue(p.summary?.contains("encrypted") == true)
        XCTAssertFalse(classify("", origin: .peer(from: "worker")).summary?.contains("encrypted") == true)
    }
    func testLargeMessagesPreserveProseAndBoundStructuredFallback() {
        let prose = String(repeating: "hello ", count: 20000)
        XCTAssertEqual(classify(prose).body, prose)
        XCTAssertFalse(classify("{\"a\":\"" + prose + "\"}", assistant: true).body.isEmpty)
    }
    func testEmptySlashCommandRetainsCommandName() {
        XCTAssertEqual(classify("<command-name>/compact</command-name>", .claude).body, "```\n/compact\n```")
    }
    func testEncryptedPeerRetainsReadablePartialBody() {
        XCTAssertTrue(classify("partial", origin: .peer(from: "worker"), encrypted: true).body.hasPrefix("partial\n\nAdditional content encrypted"))
        XCTAssertEqual(classify("Message Type: peer", origin: .peer(from: "worker"), encrypted: true).body, "")
    }
    func testEveryLineOriginHasNonemptySummary() {
        for origin in [MessageOrigin.context(kinds: []), .skill(name: "x"), .compaction, .scheduled(kind: "cron"), .harnessRetry, .notification(kind: "task"), .peer(from: "worker")] {
            let p = classify("", origin: origin)
            XCTAssertEqual(p.rowStyle, .line)
            XCTAssertFalse(p.summary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
    }
    func testRemainingSourcePrefixesAndShellOutput() {
        for tag in ["local-command-stdout", "bash-stdout", "bash-stderr"] {
            XCTAssertEqual(classify("<\(tag)>output</\(tag)>", .claude).body, "```\noutput\n```")
        }
        for text in ["<task-notification>bad", "[SYSTEM NOTIFICATION - NOT USER INPUT]", "<side-sessions-event>bad"] {
            XCTAssertEqual(classify(text, .claude).origin, .notification(kind: "task"))
        }
        XCTAssertEqual(classify("System: [2026-11-07]", .openclaw).origin, .scheduled(kind: "cron"))
        XCTAssertEqual(classify("Read HEARTBEAT.md if exists", .openclaw).origin, .scheduled(kind: "heartbeat"))
        XCTAssertEqual(classify("[IMPORTANT: You are running as a scheduled cron job]", .hermes).origin, .scheduled(kind: "cron"))
    }
    // Review fix 1: a coordinator message labelled `isMeta` (hidden context) stays a visible peer.
    func testCoordinatorWithMetaContextLabelIsVisiblePeer() {
        let text = "The coordinator sent a message while you were working:\nStop after Task 3."
        let p = classify(text, .claude, origin: .context(kinds: ["claude.meta"]))
        XCTAssertEqual(p.origin, .peer(from: "coordinator"))
        XCTAssertEqual(p.body, "Stop after Task 3.")
        XCTAssertFalse(p.origin?.isHiddenContext ?? true)
    }

    // Review fix 2: Codex labels turn_aborted messages `generic.turn_aborted`; the notice stays visible.
    func testCodexTurnAbortedKindKeepsVisibleNotice() {
        var e = event("<turn_aborted>\nThe user interrupted the turn.\n</turn_aborted>")
        e.messageOrigin = .context(kinds: ["generic.turn_aborted"])
        let notice = blocks([e], context: true).first { $0.kind == .meta }
        XCTAssertNotNil(notice)
        XCTAssertEqual(notice?.presentation?.origin, .notification(kind: "interruption"))
    }

    // Review fix 3: a side chat's first prompt is the person's, not a parent task.
    func testSideChatFirstPromptStaysTyped() {
        let session = Session(id: UUID().uuidString, source: .codex, startTime: nil, endTime: nil, model: nil,
                              filePath: "/tmp/side-chat", eventCount: 1, events: [event("What does this do?")],
                              parentSessionID: "parent", relationshipKind: .sideChat)
        let b = SessionTranscriptBuilder.coalescedBlocks(for: session, includeMeta: false)[0]
        XCTAssertEqual(b.presentation?.origin, .typed)
        XCTAssertTrue(b.isTypedUserMessage)
    }

    // Review fix 4: current Claude slash-command records lead with <command-message>.
    func testCurrentClaudeSlashCommandShape() {
        let text = "<command-message>handover</command-message>\n<command-name>/handover</command-name>"
        XCTAssertEqual(classify(text, .claude).origin, .command(name: "/handover"))
        XCTAssertEqual(classify(text, .claude, origin: .typed).origin, .command(name: "/handover"))
        XCTAssertEqual(classify(text, .claude, origin: .context(kinds: ["claude.meta"])).origin, .command(name: "/handover"))
        XCTAssertFalse(classify(text, .claude, origin: .typed).body.contains("<command-message>"))
    }

    // Review fix 5: a sub-session's parent task starts a turn, so it gets timing and a first-prompt anchor.
    func testParentTaskStartsTurn() {
        let session = Session(id: UUID().uuidString, source: .claude, startTime: nil, endTime: nil, model: nil,
                              filePath: "/tmp/subagent", eventCount: 2,
                              events: [event("Do the task."), event("Done.", kind: .assistant)],
                              parentSessionID: "parent", subagentType: "Explore")
        let b = SessionTranscriptBuilder.coalescedBlocks(for: session, includeMeta: false)[0]
        XCTAssertEqual(b.presentation?.origin, .parentTask)
        XCTAssertTrue(b.startsTurn)
        XCTAssertFalse(b.isTypedUserMessage, "a parent task is not a You row")
    }

    func testExplicitNonhumanOriginIsPreservedDuringDecoding() {
        let origin = MessageOrigin.context(kinds: ["provider"])
        let p = classify("<user_query>hello</user_query>", .grok, origin: origin)
        XCTAssertEqual(p.origin, origin)
        XCTAssertEqual(p.body, "hello")
    }
    func testFix1PeerBudgetBoundaries() {
        for prefix in [String(repeating: "a", count: 65530), String(repeating: "a", count: 65536), String(repeating: "é", count: 32767)] {
            let p = classify(prefix + "gAAAAAsecret", origin: .peer(from: "worker"), encrypted: true)
            XCTAssertFalse(p.body.contains("secret"))
            XCTAssertFalse(p.body.contains("gAAAAA"))
            XCTAssertTrue(p.body.contains("omitted"))
            XCTAssertEqual(p.rowStyle, .card)
        }
    }
    func testFix1MalformedQuestionRepliesStayVisible() {
        for inner in ["bad", "[]", "[1]", "[{\"unexpected\":true}]"] {
            let raw = "<send_user_message_question_reply>" + inner + "</send_user_message_question_reply>"
            let p = classify(raw)
            XCTAssertEqual(p.origin, .typed)
            XCTAssertEqual(p.rowStyle, .card)
            XCTAssertEqual(p.body, raw)
        }
    }
    func testFix1LongPlaceholderPrefixesPreserveRealTail() {
        for prefix in ["", "(empty)", "[REDACTED]"] {
            let raw = prefix + String(repeating: " ", count: 65536) + "actual response"
            let p = classify(raw, assistant: true)
            XCTAssertEqual(p.body, raw)
            XCTAssertEqual(p.rowStyle, .card)
        }
    }
    func testFix1EmptyDecodedContentHasMeaningfulPresentation() {
        for (raw,source,assistant) in [("{}",SessionSource.codex,true),("<user_query></user_query>",.grok,false),("<user_input mode=\"act\"></user_input>",.cline,false)] {
            let p = classify(raw, source, assistant: assistant)
            XCTAssertFalse(p.body.isEmpty)
            XCTAssertFalse(p.body.contains(raw))
            XCTAssertEqual(p.rowStyle, .card)
        }
    }
    func testFix1MalformedCommandArgumentsPreserved() {
        let raw = "<command-name>/x</command-name><command-args>important unfinished input"
        let p = classify(raw, .claude)
        XCTAssertEqual(p.origin, .command(name: "/x"))
        XCTAssertEqual(p.body, raw)
        XCTAssertEqual(p.rowStyle, .card)
    }
    func testFix1PeerPayloadAndCardEncryptionNotice() {
        for encrypted in [false,true] {
            let p = classify("Message Type: MESSAGE\nPayload:\nactual readable reply", origin: .peer(from: "worker"), encrypted: encrypted)
            XCTAssertTrue(p.body.contains("actual readable reply"))
            XCTAssertEqual(p.rowStyle, .card)
            XCTAssertEqual(p.body.contains("encrypted"), encrypted)
        }
        XCTAssertEqual(classify("  Another Claude session sent a message:\nhello", .claude).body, "hello")
    }
    func testFix1LargeCitationWindows() {
        let citation = "<oai-mem-citation>x</oai-mem-citation>"
        for raw in [citation + String(repeating: "a", count: 70000), String(repeating: "a", count: 65530) + citation, String(repeating: "a", count: 70000) + citation] {
            let p = classify(raw, assistant: true)
            XCTAssertFalse(p.body.contains("<oai-mem-citation>"))
            XCTAssertTrue(p.body.hasSuffix("*Memory citations: 1*"))
            XCTAssertEqual(p.rowStyle, .card)
        }
    }
    func testFix1LargeKnownEnvelopesDecode() {
        for size in [65500,65536,70000] {
            let content = String(repeating: "é", count: size)
            for origin in [nil,MessageOrigin.typed] {
                XCTAssertEqual(classify("<user_query>" + content + "</user_query>", .grok, origin: origin).body, content)
                XCTAssertEqual(classify("<user_input mode=\"act\">" + content + "</user_input>", .cline, origin: origin).body, content)
                XCTAssertEqual(classify("<bash-stdout>" + content + "</bash-stdout>", .kimi, origin: origin).body, "```\n" + content + "\n```")
            }
        }
    }
    func testFix1MalformedLargeEnvelopeHasExplicitFallback() {
        let raw = "<bash-stdout>" + String(repeating: "a", count: 70000)
        let p = classify(raw, .kimi)
        XCTAssertEqual(p.origin, .command(name: "output"))
        XCTAssertEqual(p.rowStyle, .card)
        XCTAssertTrue(p.body.contains("shown without envelope decoding"))
        XCTAssertTrue(p.body.contains(raw))
    }
    func testFix2DistinctCitationsPreserveMiddleAnswer() {
        let answer = String(repeating: "REAL ANSWER ", count: 7000)
        let raw = String(repeating: "a", count: 32740) + "<oai-mem-citation>" + String(repeating: "x", count: 100) + "</oai-mem-citation>" + answer + "<oai-mem-citation>last</oai-mem-citation>"
        let p = classify(raw, assistant: true)
        XCTAssertTrue(p.body.contains(answer))
        XCTAssertTrue(p.body.hasSuffix("*Memory citations: 2*"))
        XCTAssertEqual(p.rowStyle, .card)
    }
    func testFix2CitationsAtAllInspectionBoundaries() {
        for position in [32740,32760,32780,65520,65530,65550,100000] {
            let raw = String(repeating: "a", count: position) + "<oai-mem-citation>x</oai-mem-citation>" + String(repeating: "b", count: 70000)
            let p = classify(raw, assistant: true)
            XCTAssertFalse(p.body.contains("<oai-mem-citation>"))
            XCTAssertTrue(p.body.hasPrefix(String(repeating: "a", count: position)))
            XCTAssertTrue(p.body.contains(String(repeating: "b", count: 70000)))
        }
    }
    func testFix2UnmatchedCitationsDoNotSwallowAnswer() {
        for raw in ["answer<oai-mem-citation>unfinished", "answer</oai-mem-citation>tail", "answer<oai-mem-citation>broken<oai-mem-citation>x</oai-mem-citation>tail"] {
            let p = classify(raw, assistant: true)
            XCTAssertTrue(p.body.contains("answer"))
            XCTAssertTrue(p.body.contains(raw.hasSuffix("tail") ? "tail" : "unfinished"))
            XCTAssertEqual(p.rowStyle, .card)
        }
    }
    func testFix2LargeCursorAndSlashCommands() {
        for origin in [nil,MessageOrigin.typed] {
            let prompt = "actual prompt"
            let cursor = classify("<timestamp>" + String(repeating: "a", count: 70000) + "</timestamp>" + prompt, .cursor, origin: origin)
            XCTAssertEqual(cursor.origin, .typed)
            XCTAssertTrue(cursor.body.contains(prompt))
            XCTAssertTrue(cursor.body.contains("shown without envelope decoding"))
            XCTAssertEqual(cursor.rowStyle, .card)
            let args = String(repeating: "argument ", count: 10000)
            let command = classify("<command-name>/x</command-name><command-args>" + args + "</command-args>", .claude, origin: origin)
            XCTAssertFalse(command.body.contains("<command-args>"))
            XCTAssertTrue(command.body.contains(args))
            XCTAssertEqual(command.rowStyle, .card)
            let broken = classify("<timestamp>" + args, .cursor, origin: origin)
            XCTAssertTrue(broken.body.contains("shown without envelope decoding"))
            XCTAssertEqual(broken.rowStyle, .card)
        }
    }
    func testFix2EmptyDecodedLabelsRemoveRawSyntax() {
        let object = classify("{}", assistant: true)
        XCTAssertFalse(object.body.contains("{}"))
        XCTAssertEqual(object.rowStyle, .card)
        for (raw,source) in [("<user_query></user_query>",SessionSource.grok),("<user_input mode=\"act\"></user_input>",.cline)] {
            let p = classify(raw,source)
            XCTAssertEqual(p.origin, .typed)
            XCTAssertEqual(p.rowStyle, .card)
            XCTAssertFalse(p.body.contains("<"))
            XCTAssertFalse(p.body.isEmpty)
        }
    }
    func testFix3CursorQuotedCloserCannotDeletePrompt() {
        let prompt = String(repeating: "p", count: 70000) + "Please explain </timestamp> today"
        let raw = "<timestamp>" + String(repeating: "a", count: 40000) + "</timestamp>" + prompt
        for origin in [nil, MessageOrigin.typed] {
            let p = classify(raw, .cursor, origin: origin)
            XCTAssertEqual(p.origin, .typed)
            XCTAssertEqual(p.rowStyle, .card)
            XCTAssertTrue(p.body.contains(prompt))
            XCTAssertTrue(p.body.contains(raw))
            XCTAssertTrue(p.body.contains("shown without envelope decoding"))
        }
    }
    private func guardian(_ text: String, assistant: Bool = false, source: SessionSource = .codex, meta: Bool = false) -> MessagePresentation {
        var e = event(text, kind: assistant ? .assistant : (meta ? .meta : .user))
        if meta { e.messageOrigin = .context(kinds: ["codex.preamble"]) }
        return MessageOriginClassifier.presentation(for: blocks([e], context: meta)[0], context: .init(source: source, subagentType: "guardian", isFirstUserBlock: true))!
    }
    private func approval(_ command: [String]) -> String {
        let object: [String: Any] = ["command": command, "cwd": "/tmp/work", "tool": "exec_command", "justification": "Build app", "sandbox_permissions": "require_escalated", "environment_id": "e", "tty": false]
        let json = String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
        return ">>> APPROVAL REQUEST START\nPlanned action JSON:\n" + json + "\n>>> APPROVAL REQUEST END"
    }
    func testGuardianRequestCard() {
        let script = "python3 - <<'PY'\nprint(1)\nPY"
        let result = guardian(approval(["/bin/zsh", "-lc", script]))
        XCTAssertEqual(result.origin, .approvalRequest)
        XCTAssertTrue(result.body.contains("```sh\n" + script))
        XCTAssertTrue(result.body.contains("**Justification:** Build app"))
    }
    func testGuardianHistoryIsContext() { XCTAssertEqual(guardian("history").origin, .context(kinds: ["guardian.history"])) }
    func testGuardianVerdictCard() {
        let result = guardian(#"{"risk_level":"low","user_authorization":"high","outcome":"allow","rationale":"r"}"#, assistant: true)
        XCTAssertEqual(result.origin, .approvalVerdict(outcome: "allow"))
        XCTAssertTrue(result.body.hasPrefix("**Allowed** · risk low"))
    }
    func testGuardianBadJSONFallsBackToFence() {
        let result = guardian(">>> APPROVAL REQUEST START\nPlanned action JSON:\n{bad}\n>>> APPROVAL REQUEST END")
        XCTAssertEqual(result.origin, .approvalRequest)
        XCTAssertTrue(result.body.contains("```\nPlanned action JSON:\n{bad}\n```"))
    }
    func testGuardianTailMetaAndAdaptiveFence() {
        let script = "cat <<'EOF'\n```\nEOF"
        let result = guardian(String(repeating: "history ", count: 10000) + approval(["sh", "-c", script]), meta: true)
        XCTAssertEqual(result.origin, .approvalRequest)
        XCTAssertTrue(result.body.contains("````sh\n" + script + "\n````"))
        XCTAssertFalse(result.body.contains("history"))
    }
    func testGuardianArgvQuotesAndSourceScope() {
        let request = approval(["echo", "a b", "it's"])
        XCTAssertTrue(guardian(request).body.contains("'echo' 'a b' 'it'\"'\"'s'"))
        XCTAssertNotEqual(guardian(request, source: .claude).origin, .approvalRequest)
    }
    func testGuardianMalformedSchemaIsRaw() {
        let request = ">>> APPROVAL REQUEST START\nPlanned action JSON:\n{\"command\":\"echo hi\"}\n>>> APPROVAL REQUEST END"
        XCTAssertTrue(guardian(request).body.contains("```\nPlanned action JSON:"))
    }
    func testSubagentFirstUserBlockIsParentTask() {
        let session = Session(id: UUID().uuidString, source: .claude, startTime: nil, endTime: nil, model: nil, filePath: "/tmp/child", eventCount: 3, events: [event("<system-reminder>context</system-reminder>"), event("task"), event("later")], parentSessionID: "parent")
        let result = SessionTranscriptBuilder.coalescedBlocks(for: session, includeMeta: false, includeMessageContext: true)
        XCTAssertEqual(result[0].presentation?.origin, .context(kinds: ["system-reminder"]))
        XCTAssertEqual(result[1].presentation?.origin, .parentTask)
        XCTAssertEqual(result[2].presentation?.origin, .typed)
        XCTAssertEqual(result[1].text, "task")
    }
    func testClassifierContextChangesInvalidateCoalesceCache() {
        let id = UUID().uuidString
        let events = [event("task")]
        func session(_ source: SessionSource = .codex, parent: String? = nil, type: String? = nil) -> Session {
            Session(id: id, source: source, startTime: nil, endTime: nil, model: nil, filePath: "/tmp/cache-child", fileSizeBytes: 100, eventCount: 1, events: events, parentSessionID: parent, subagentType: type)
        }
        XCTAssertEqual(SessionTranscriptBuilder.coalescedBlocks(for: session(), includeMeta: false)[0].presentation?.origin, .typed)
        XCTAssertEqual(SessionTranscriptBuilder.coalescedBlocks(for: session(parent: "parent"), includeMeta: false)[0].presentation?.origin, .parentTask)
        XCTAssertEqual(SessionTranscriptBuilder.coalescedBlocks(for: session(type: "guardian"), includeMeta: false)[0].presentation?.origin, .context(kinds: ["guardian.history"]))
        XCTAssertEqual(SessionTranscriptBuilder.coalescedBlocks(for: session(.claude, type: "guardian"), includeMeta: false)[0].presentation?.origin, .parentTask)
    }

}
