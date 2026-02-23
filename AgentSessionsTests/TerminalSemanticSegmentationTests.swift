import XCTest
@testable import AgentSessions

final class TerminalSemanticSegmentationTests: XCTestCase {
    func testAssistantPlanAndCodeBecomeSeparateSemanticGroups() {
        let text = """
        Intro text
        <proposed_plan>
        # Rich Transcript Plan
        - Step one
        </proposed_plan>
        ```swift
        print(\"hello\")
        ```
        Tail text
        """

        let session = makeSession(source: .codex, events: [
            makeEvent(id: "a1", kind: .assistant, text: text)
        ])

        let lines = TerminalBuilder.buildLines(for: session, showMeta: false)
        XCTAssertTrue(lines.contains(where: { $0.semanticKind == .plan }))
        XCTAssertTrue(lines.contains(where: { $0.semanticKind == .code }))
        XCTAssertTrue(lines.contains(where: { $0.semanticKind == nil }))
        XCTAssertFalse(lines.contains(where: { $0.text.contains("<proposed_plan>") }))

        let uniqueGroups = Set(lines.map(\.decorationGroupID))
        XCTAssertGreaterThan(uniqueGroups.count, 1)
    }

    func testAssistantReviewJSONMapsToReviewSummary() {
        let reviewJSON = """
        {
          "findings": [],
          "overall_correctness": "correct",
          "overall_explanation": "Looks good.",
          "overall_confidence_score": 0.88
        }
        """

        let session = makeSession(source: .codex, events: [
            makeEvent(id: "a1", kind: .assistant, text: reviewJSON)
        ])

        let lines = TerminalBuilder.buildLines(for: session, showMeta: false)
        XCTAssertFalse(lines.isEmpty)
        XCTAssertTrue(lines.allSatisfy { $0.semanticKind == .reviewSummary })
        XCTAssertTrue(lines.contains(where: { $0.text == "Review" }))
    }

    func testAssistantFencedReviewJSONMapsToReviewSummary() {
        let reviewJSON = """
        Here is the review payload:
        ```json
        {
          "findings": [],
          "overall_correctness": "correct",
          "overall_explanation": "Looks good.",
          "overall_confidence_score": 0.91
        }
        ```
        """

        let session = makeSession(source: .codex, events: [
            makeEvent(id: "a-fenced-review", kind: .assistant, text: reviewJSON)
        ])

        let lines = TerminalBuilder.buildLines(for: session, showMeta: false)
        XCTAssertTrue(lines.contains(where: { $0.semanticKind == .reviewSummary }))
        XCTAssertTrue(lines.contains(where: { $0.text == "Correctness: correct" }))
    }

    func testReviewCardParserSkipsInvalidCandidateAndUsesLaterValidCandidate() {
        let payload = """
        ```json
        {
          "findings": [],
          "overall_correctness": "incorrect",
          "overall_explanation": "invalid candidate",
          "overall_confidence_score": 0.10,
          "extra_key": "not-allowlisted"
        }
        ```

        ```json
        {
          "findings": [],
          "overall_correctness": "correct",
          "overall_explanation": "valid candidate",
          "overall_confidence_score": 0.93
        }
        ```
        """

        guard let review = InternalPayloadFormatter.parseReviewCard(rawText: payload, source: .codex) else {
            XCTFail("Expected valid review candidate to be parsed")
            return
        }

        XCTAssertEqual(review.correctness, "correct")
        XCTAssertEqual(review.explanation, "valid candidate")
        XCTAssertEqual(review.confidenceScore, 0.93, accuracy: 0.0001)
    }

    func testReviewCardToggleDisabledPreservesRawReviewPayload() {
        let reviewPayload = """
        <user_action>
          <action>review</action>
          <results>{"status":"ok"}</results>
        </user_action>
        """

        let session = makeSession(source: .codex, events: [
            makeEvent(id: "u-review", kind: .user, text: reviewPayload)
        ])

        let lines = TerminalBuilder.buildLines(for: session, showMeta: false, enableReviewCards: false)
        XCTAssertTrue(lines.contains(where: { $0.role == .user && $0.text.contains("<user_action>") }))
        XCTAssertFalse(lines.contains(where: { $0.semanticKind == .reviewSummary }))
    }

    func testAssistantUnifiedDiffMapsToDiffSemanticKind() {
        let diff = """
        diff --git a/Foo.swift b/Foo.swift
        --- a/Foo.swift
        +++ b/Foo.swift
        @@ -1,2 +1,2 @@
        -old
        +new
        """

        let session = makeSession(source: .codex, events: [
            makeEvent(id: "a1", kind: .assistant, text: diff)
        ])

        let lines = TerminalBuilder.buildLines(for: session, showMeta: false)
        XCTAssertTrue(lines.contains(where: { $0.semanticKind == .diff }))
    }

    func testToolOutputUnifiedDiffMapsToDiffSemanticKind() {
        let diff = """
        diff --git a/Foo.swift b/Foo.swift
        --- a/Foo.swift
        +++ b/Foo.swift
        @@ -1,2 +1,2 @@
        -old
        +new
        """

        let session = makeSession(source: .codex, events: [
            makeToolResultEvent(id: "t1", toolName: "bash", output: diff)
        ])

        let lines = TerminalBuilder.buildLines(for: session, showMeta: false)
        XCTAssertTrue(lines.contains(where: { $0.role == .toolOutput }))
        XCTAssertTrue(lines.contains(where: { $0.semanticKind == .diff }))
    }

    func testReadToolOutputMapsToCodeSemanticKind() {
        let output = """
             219→        // Check exit code
             220→        let exitCode = process.terminationStatus
        """

        let session = makeSession(source: .claude, events: [
            makeToolResultEvent(id: "t2", toolName: "read_file", output: output)
        ])

        let lines = TerminalBuilder.buildLines(for: session, showMeta: false)
        XCTAssertTrue(lines.contains(where: { $0.role == .toolOutput }))
        XCTAssertTrue(lines.contains(where: { $0.semanticKind == .code }))
    }

    func testCodeFenceParserRequiresFenceDelimiterForClosingFence() {
        let text = """
        ```swift
        let marker = "``` inside code"
        print(marker)
        ```
        trailing text
        """

        let session = makeSession(source: .codex, events: [
            makeEvent(id: "a-fence", kind: .assistant, text: text)
        ])

        let lines = TerminalBuilder.buildLines(for: session, showMeta: false)
        XCTAssertTrue(lines.contains(where: { $0.semanticKind == .code && $0.text.contains("print(marker)") }))
        XCTAssertTrue(lines.contains(where: { $0.semanticKind == nil && $0.text.contains("trailing text") }))
    }

    func testCodeFenceParserIgnoresInlineBackticksForOpeningFence() {
        let text = """
        Use ```foo``` here before a real fenced block.
        ```swift
        print("hello")
        ```
        """

        guard let fenced = CodeFenceParser.firstFence(in: text, from: text.startIndex) else {
            XCTFail("Expected fenced code block")
            return
        }

        XCTAssertEqual(fenced.model.language, "swift")
        XCTAssertEqual(fenced.model.body.trimmingCharacters(in: .whitespacesAndNewlines), #"print("hello")"#)
    }

    func testTranscriptLinkifierFindsCommonPatterns() {
        let input = "See Foo.swift (line 56), src/App.swift:10:2, and lib/A.swift#L3-L5"
        let matches = TranscriptLinkifier.matches(in: input)
        XCTAssertGreaterThanOrEqual(matches.count, 3)
        XCTAssertTrue(matches.contains(where: { $0.path == "Foo.swift" && $0.line == 56 }))
        XCTAssertTrue(matches.contains(where: { $0.path == "src/App.swift" && $0.line == 10 && $0.column == 2 }))
        XCTAssertTrue(matches.contains(where: { $0.path == "lib/A.swift" && $0.line == 3 }))
    }

    func testTranscriptLinkifierPathLineColumnDoesNotCreateLineOnlyDuplicate() {
        let input = "See Foo.swift:10:3"
        let matches = TranscriptLinkifier.matches(in: input)
        let fooMatches = matches.filter { $0.path == "Foo.swift" && $0.line == 10 }

        XCTAssertEqual(fooMatches.count, 1)
        XCTAssertEqual(fooMatches.first?.column, 3)
    }

    func testTranscriptLinkifierSupportsSpacedAndExtensionlessNames() {
        let input = "See My File.swift:10 and README:4"
        let matches = TranscriptLinkifier.matches(in: input)
        XCTAssertTrue(matches.contains(where: { $0.path == "My File.swift" && $0.line == 10 }))
        XCTAssertTrue(matches.contains(where: { $0.path == "README" && $0.line == 4 }))
    }

    func testTranscriptLinkifierResolveRelativePathFromCwd() throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentsessions-linkifier-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let fileURL = tempRoot.appendingPathComponent("Foo.swift")
        try "print(1)\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let resolved = TranscriptLinkifier.resolve(path: "Foo.swift", sessionCwd: tempRoot.path, repoRoot: nil)
        XCTAssertEqual(resolved, fileURL.path)
    }

    func testIDEOpenerCursorCallReturnsQuicklyWhenCLIIsSlow() {
        IDEOpener.resetTestingHooks()
        defer { IDEOpener.resetTestingHooks() }

        let fallbackOpen = expectation(description: "System fallback should not open on CLI success")
        fallbackOpen.isInverted = true

        IDEOpener.cliLaunchQueue = DispatchQueue(label: "IDEOpenerTests.slowCLI")
        IDEOpener.openURLHandler = { _ in
            fallbackOpen.fulfill()
        }
        IDEOpener.cliRunner = { _, _, _ in
            Thread.sleep(forTimeInterval: 0.15)
            return true
        }

        let start = CFAbsoluteTimeGetCurrent()
        IDEOpener.open(path: "/tmp/Foo.swift", line: 10, column: 3, target: .cursor)
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        XCTAssertLessThan(elapsed, 0.10)
        wait(for: [fallbackOpen], timeout: 0.05)
    }

    func testIDEOpenerFallsBackToSystemDefaultWhenCLIFails() {
        IDEOpener.resetTestingHooks()
        defer { IDEOpener.resetTestingHooks() }

        let fallbackOpen = expectation(description: "System fallback should open")
        IDEOpener.cliLaunchQueue = DispatchQueue(label: "IDEOpenerTests.failCLI")
        IDEOpener.cliRunner = { _, _, _ in false }
        IDEOpener.openURLHandler = { url in
            XCTAssertEqual(url.path, "/tmp/Foo.swift")
            fallbackOpen.fulfill()
        }

        IDEOpener.open(path: "/tmp/Foo.swift", line: 10, column: 3, target: .vscode)
        wait(for: [fallbackOpen], timeout: 1.0)
    }

    func testIDEOpenerRunsMultipleCLILaunchesConcurrently() {
        IDEOpener.resetTestingHooks()
        defer { IDEOpener.resetTestingHooks() }

        let noFallbackOpen = expectation(description: "System fallback should not open")
        noFallbackOpen.isInverted = true
        IDEOpener.openURLHandler = { _ in
            noFallbackOpen.fulfill()
        }

        let runnerCalled = expectation(description: "Runner should be called for each open")
        runnerCalled.expectedFulfillmentCount = 4
        let lock = NSLock()
        var activeRuns = 0
        var maxConcurrentRuns = 0

        IDEOpener.cliRunner = { _, _, _ in
            lock.lock()
            activeRuns += 1
            maxConcurrentRuns = max(maxConcurrentRuns, activeRuns)
            lock.unlock()

            Thread.sleep(forTimeInterval: 0.15)

            lock.lock()
            activeRuns -= 1
            lock.unlock()
            runnerCalled.fulfill()
            return true
        }

        for i in 1...4 {
            IDEOpener.open(path: "/tmp/Foo\(i).swift", line: i, column: i, target: .cursor)
        }

        wait(for: [runnerCalled, noFallbackOpen], timeout: 2.0)
        XCTAssertGreaterThan(maxConcurrentRuns, 1)
    }

    private func makeSession(source: SessionSource, events: [SessionEvent]) -> Session {
        Session(id: "s-semantic",
                source: source,
                startTime: nil,
                endTime: nil,
                model: "test-model",
                filePath: "/tmp/s-semantic.jsonl",
                fileSizeBytes: nil,
                eventCount: events.count,
                events: events)
    }

    private func makeEvent(id: String, kind: SessionEventKind, text: String) -> SessionEvent {
        SessionEvent(id: id,
                     timestamp: nil,
                     kind: kind,
                     role: kind == .assistant ? "assistant" : "user",
                     text: text,
                     toolName: nil,
                     toolInput: nil,
                     toolOutput: nil,
                     messageID: id,
                     parentID: nil,
                     isDelta: false,
                     rawJSON: "{}")
    }

    private func makeToolResultEvent(id: String, toolName: String, output: String) -> SessionEvent {
        SessionEvent(id: id,
                     timestamp: nil,
                     kind: .tool_result,
                     role: "tool",
                     text: nil,
                     toolName: toolName,
                     toolInput: nil,
                     toolOutput: output,
                     messageID: id,
                     parentID: nil,
                     isDelta: false,
                     rawJSON: "{}")
    }
}
