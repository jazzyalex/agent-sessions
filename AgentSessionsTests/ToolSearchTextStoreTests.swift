import AppKit
import XCTest
@testable import AgentSessions

/// Holds builds back until a test opens it (a decode pass that is still running).
final class DecodeGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var isOpen = false

    func wait() {
        condition.lock()
        while !isOpen { condition.wait() }
        condition.unlock()
    }

    func open() {
        condition.lock()
        isOpen = true
        condition.broadcast()
        condition.unlock()
    }

    /// The store's real build, after the gate opens.
    var build: ToolSearchTextStore.Build {
        { [self] ref, blocks, index, source, duration in
            wait()
            return ToolInvocationBuilder.build(ref, blocks: blocks, index: index, source: source, duration: duration)
        }
    }
}

/// Task 15: Find searches each tool invocation's decoded plain text (spec §6.8). The store decodes
/// it off the main thread; the find map and fold opening turn a decoded match into rendered ranges.
final class ToolSearchTextStoreTests: XCTestCase {
    private typealias F = TranscriptTestFixtures
    private typealias Block = SessionTranscriptBuilder.LogicalBlock

    private func json(_ object: [String: Any]) -> String {
        ToolJSON.string(from: object, pretty: false) ?? "{}"
    }

    /// 0 user · 1 call · 2 output: a JSON string literal holding escaped quotes and an escaped newline · 3 assistant.
    private var codexEscaped: [Block] {
        F.sequence([
            F.block(.user, text: "go"),
            F.block(.toolCall, id: "c1", toolName: "exec_command", toolInput: json(["cmd": "printf hi"])),
            F.block(.toolOut, id: "c1", text: #""say \"x\"\nline2 done""#, toolName: "exec_command"),
            F.block(.assistant, text: "ok"),
        ])
    }

    /// Starts a pass and runs the main run loop until it completed. `decodedAny` receives the
    /// pass's report.
    @MainActor
    @discardableResult
    private func runPass(_ store: ToolSearchTextStore, _ blocks: [Block], source: SessionSource,
                         viewport: Int? = nil, decodedAny: ((Bool) -> Void)? = nil) -> Int {
        let index = ToolInvocationIndex.build(blocks: blocks, source: source)
        var completions = 0
        store.start(blocks: blocks, index: index, source: source, sessionID: "s", viewportBlock: viewport ?? blocks.count - 1) { any in
            completions += 1
            decodedAny?(any)
        }
        let deadline = Date().addingTimeInterval(10)
        while completions == 0, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return completions
    }

    /// 0 user · 1/2 · 3/4 · 5/6 · 7/8 (Bash call/output, outputs "built stepN") · 9 assistant.
    private var fourBashCalls: [Block] {
        var blocks: [Block] = [F.block(.user, text: "go")]
        for n in 1...4 {
            blocks.append(F.block(.toolCall, id: "t\(n)", toolName: "Bash", toolInput: json(["command": "make step\(n)"])))
            blocks.append(F.block(.toolOut, id: "t\(n)", text: "built step\(n)", toolName: "Bash"))
        }
        blocks.append(F.block(.assistant, text: "done"))
        return F.sequence(blocks)
    }

    // MARK: - Store

    @MainActor
    func testDecodedTextFindsUnescapedQuery() throws {
        let blocks = codexEscaped
        let store = ToolSearchTextStore()
        XCTAssertEqual(runPass(store, blocks, source: .codex), 1)
        XCTAssertTrue(store.isComplete)

        let text = try XCTUnwrap(store.text(forBlock: 1), "the call block holds the invocation's search text")
        XCTAssertTrue(text.contains("say \"x\"\nline2 done"), text)
        XCTAssertEqual(store.text(forBlock: 2), "", "the output block reports nothing: each match is reported once")
        XCTAssertNil(store.text(forBlock: 0), "message blocks keep their own text")

        let quoted = TranscriptDerivedState.computeFindMatches(blocks: blocks, query: "\"x\"", toolText: store.text(forBlock:))
        XCTAssertEqual(quoted.map(\.space), [.decoded])
        XCTAssertEqual(quoted.first?.globalBlockIndex, 1)
        XCTAssertEqual((text as NSString).substring(with: quoted[0].rangeInBlockText), "x")

        // The raw text holds "\nline2" (one token with the escape's "n"); the decoded text a real line.
        XCTAssertTrue(TranscriptDerivedState.computeFindMatches(blocks: blocks, query: "line2").isEmpty,
                      "the raw text misses a word after an escaped newline")
        let line = TranscriptDerivedState.computeFindMatches(blocks: blocks, query: "line2", toolText: store.text(forBlock:))
        XCTAssertEqual(line.map(\.space), [.decoded])
        XCTAssertEqual(line.first?.globalBlockIndex, 1)
    }

    @MainActor
    func testTextIsNilUntilItsInvocationIsDecoded() {
        let gate = DecodeGate()
        defer { gate.open() }
        let store = ToolSearchTextStore(build: gate.build)
        let blocks = codexEscaped
        let index = ToolInvocationIndex.build(blocks: blocks, source: .codex)
        var completions = 0
        store.start(blocks: blocks, index: index, source: .codex, sessionID: "s", viewportBlock: 3) { _ in completions += 1 }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        XCTAssertNil(store.text(forBlock: 1))
        XCTAssertNil(store.text(forBlock: 2))
        XCTAssertFalse(store.isComplete)
        let raw = TranscriptDerivedState.computeFindMatches(blocks: blocks, query: "done", toolText: store.text(forBlock:))
        XCTAssertEqual(raw.map(\.space), [.raw], "not decoded yet: Find falls back to the raw block text")
        XCTAssertEqual(raw.first?.globalBlockIndex, 2)

        gate.open()
        let deadline = Date().addingTimeInterval(10)
        while completions == 0, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertEqual(completions, 1)
        XCTAssertNotNil(store.text(forBlock: 1))
        let decoded = TranscriptDerivedState.computeFindMatches(blocks: blocks, query: "done", toolText: store.text(forBlock:))
        XCTAssertEqual(decoded.map(\.space), [.decoded])
        XCTAssertEqual(decoded.first?.globalBlockIndex, 1)
    }

    @MainActor
    func testPassRunsViewportOutwardAndReusesCachedInvocations() {
        final class Recorder: @unchecked Sendable {
            private let lock = NSLock()
            private var ids: [Int] = []
            func add(_ id: Int) { lock.lock(); ids.append(id); lock.unlock() }
            var order: [Int] { lock.lock(); defer { lock.unlock() }; return ids }
        }
        let recorder = Recorder()
        let build: ToolSearchTextStore.Build = { ref, blocks, index, source, duration in
            recorder.add(ref.id)
            return ToolInvocationBuilder.build(ref, blocks: blocks, index: index, source: source, duration: duration)
        }
        // 0 user · 1/2 · 3/4 · 5/6 · 7/8 · 9 assistant
        var blocks: [Block] = [F.block(.user, text: "go")]
        for n in 1...4 {
            blocks.append(F.block(.toolCall, id: "t\(n)", toolName: "Bash", toolInput: json(["command": "make step\(n)"])))
            blocks.append(F.block(.toolOut, id: "t\(n)", text: "built step\(n)", toolName: "Bash"))
        }
        blocks.append(F.block(.assistant, text: "done"))
        blocks = F.sequence(blocks)

        let cache = NSCacheMemo<ToolInvocation>(countLimit: 64, totalCostLimit: 1_000_000)
        let first = ToolSearchTextStore(invocationCache: cache, build: build)
        XCTAssertEqual(runPass(first, blocks, source: .claude, viewport: 5), 1)
        XCTAssertEqual(recorder.order.first, 5, "the invocation at the viewport decodes first")
        XCTAssertEqual(Set(recorder.order), [1, 3, 5, 7])
        XCTAssertEqual(first.buildCount, 4)

        // A second store over the same cache (the controller's cached invocations) builds nothing.
        let second = ToolSearchTextStore(invocationCache: cache, build: build)
        XCTAssertEqual(runPass(second, blocks, source: .claude), 1)
        XCTAssertEqual(second.buildCount, 0)
        XCTAssertEqual(second.text(forBlock: 3), first.text(forBlock: 3))
        XCTAssertTrue(second.text(forBlock: 3)?.contains("built step2") ?? false)

        // A restart after a live append keeps unchanged invocations and decodes the changed one.
        var appended = blocks
        appended[8].text = "built step4 and more"
        XCTAssertEqual(runPass(second, appended, source: .claude), 1)
        XCTAssertEqual(second.buildCount, 1)
        XCTAssertTrue(second.text(forBlock: 7)?.contains("and more") ?? false)

        second.cancel()
        XCTAssertNil(second.text(forBlock: 3), "a session change drops the decoded text")
        XCTAssertFalse(second.isComplete)
    }

    @MainActor
    func testPassReportsWhetherItDecodedAnything() {
        let store = ToolSearchTextStore()
        var reports: [Bool] = []
        XCTAssertEqual(runPass(store, fourBashCalls, source: .claude, decodedAny: { reports.append($0) }), 1)
        XCTAssertEqual(runPass(store, fourBashCalls, source: .claude, decodedAny: { reports.append($0) }), 1)
        XCTAssertEqual(reports, [true, false], "a pass that found every text in place has nothing new for Find")
    }

    @MainActor
    func testPassCachesOnlyTheInvocationsNearestTheViewport() {
        let blocks = fourBashCalls
        let cache = NSCacheMemo<ToolInvocation>(countLimit: 64, totalCostLimit: 1_000_000)
        let store = ToolSearchTextStore(invocationCache: cache, cacheInsertLimit: 2)
        XCTAssertEqual(runPass(store, blocks, source: .claude, viewport: 5), 1)
        let index = ToolInvocationIndex.build(blocks: blocks, source: .claude)
        let cached = index.invocations.filter { ref in
            cache.contains(ToolSearchTextStore.invocationKey(sessionID: "s", ref: ref, blocks: blocks) as NSString)
        }.map(\.id)
        XCTAssertEqual(cached, [5, 7], "the two nearest the viewport; the others are not pushed into the shared cache")
        for id in [1, 3, 5, 7] {
            XCTAssertNotNil(store.text(forBlock: id), "every invocation keeps its search text (\(id))")
        }
    }

    func testRefreshDropsChangedTextBeforeLandingAndDecodesIt() {
        let blocks = fourBashCalls
        let store = ToolSearchTextStore()
        let index = ToolInvocationIndex.build(blocks: blocks, source: .claude)
        XCTAssertTrue(store.refresh(blocks: blocks, index: index, source: .claude, sessionID: "s", viewportBlock: 9,
                                    decodeLimit: 8, decodeBudget: 1_000_000), "four small invocations decode here")
        XCTAssertTrue(store.isComplete)

        // The last output grows (a live append). Before the new snapshot lands, the old text of
        // that invocation is no longer served; the others stay.
        var grown = blocks
        grown[8].text = "built step4 and more"
        let grownIndex = ToolInvocationIndex.build(blocks: grown, source: .claude)
        XCTAssertFalse(store.refresh(blocks: grown, index: grownIndex, source: .claude, sessionID: "s",
                                     viewportBlock: 9, decodeLimit: 0, decodeBudget: 1_000_000))
        XCTAssertNil(store.text(forBlock: 7), "stale text of a changed invocation")
        XCTAssertTrue(store.text(forBlock: 3)?.contains("built step2") ?? false)
        XCTAssertFalse(store.isComplete)

        // With a decode allowance the changed one decodes in the same call: the landing scan is final.
        XCTAssertTrue(store.refresh(blocks: grown, index: grownIndex, source: .claude, sessionID: "s",
                                    viewportBlock: 9, decodeLimit: 8, decodeBudget: 1_000_000))
        XCTAssertTrue(store.text(forBlock: 7)?.contains("and more") ?? false)
        XCTAssertTrue(store.isComplete)

        // Over the budget: left to the background pass.
        var bigger = grown
        bigger[8].text = String(repeating: "x", count: 2_000)
        let biggerIndex = ToolInvocationIndex.build(blocks: bigger, source: .claude)
        XCTAssertFalse(store.refresh(blocks: bigger, index: biggerIndex, source: .claude, sessionID: "s",
                                     viewportBlock: 9, decodeLimit: 8, decodeBudget: 100))
        XCTAssertNil(store.text(forBlock: 7))
    }

    // MARK: - Search text

    func testSearchTextAddsFooterFactsNotInPlainText() {
        let action = ToolAction(category: .shell, verbKey: ToolVerb.ran, object: "make", objectIsAgentLabel: false,
                                objectDetail: nil, context: [], command: "make", exactCommand: "make", heredoc: nil,
                                inputFields: [], output: decoded("ok"),
                                facts: [AgentFact(kind: .truncated(agent: "Codex", originalTokens: 900, totalLines: 120)),
                                        AgentFact(kind: .note("aborted by user after 3s"))],
                                hiddenNotes: [], status: .success, plainText: "$ make\nok")
        let script = DecodedText(text: "loose", sourceMap: [], shape: .plain)
        let invocation = ToolInvocation(ref: ToolInvocationRef(id: 4, callBlockIndex: 4, outputBlockIndices: [5], status: .success),
                                        displayToolName: "exec", actions: [action, action], scriptSource: nil,
                                        scriptOutput: script, durationSeconds: nil)

        let text = ToolSearchText.text(of: invocation)
        XCTAssertTrue(text.hasPrefix(invocation.plainText), "the plain form comes first")
        XCTAssertTrue(text.contains(ToolChip.cutBy("Codex")), "a fact chip the plain text lacks is searchable")
        XCTAssertTrue(text.contains("aborted by user after 3s"))
        XCTAssertEqual(ToolSearchText.extraFactWords(of: invocation).count, 2, "each word once")

        let segments = ToolSearchText.segments(of: invocation)
        XCTAssertEqual(segments.map(\.actionIndex), [0, 1, 2])
        guard segments.count == 3 else { return }
        let ns = text as NSString
        XCTAssertEqual(ns.substring(with: segments[0].range), "$ make\nok")
        XCTAssertEqual(ns.substring(with: segments[1].range), "$ make\nok")
        XCTAssertEqual(ns.substring(with: segments[2].range), "loose")
    }

    // MARK: - Find map

    private func decoded(_ text: String, shape: TextShape = .plain) -> DecodedText {
        let length = (text as NSString).length
        return DecodedText(text: text, sourceMap: [SourceMapEntry(rendered: NSRange(location: 0, length: length),
                                                                  source: NSRange(location: 0, length: length))],
                           shape: shape)
    }

    private func shell(_ command: String, output: String, shape: TextShape = .plain, bracket: String? = nil,
                       facts: [AgentFact] = [], status: ToolStatus = .success) -> ToolAction {
        var lines = ["$ " + command]
        if let bracket { lines.append("[" + bracket + "]") }
        lines.append(output)
        return ToolAction(category: .shell, verbKey: ToolVerb.ran, object: command, objectIsAgentLabel: false,
                          objectDetail: nil, context: [], command: command, exactCommand: command, heredoc: nil,
                          inputFields: [], output: decoded(output, shape: shape), facts: facts, hiddenNotes: [],
                          status: status, plainText: lines.joined(separator: "\n"))
    }

    private func invocation(_ actions: [ToolAction], status: ToolStatus = .success) -> ToolInvocation {
        ToolInvocation(ref: ToolInvocationRef(id: 1, callBlockIndex: 1, outputBlockIndices: [2], status: status),
                       displayToolName: "shell", actions: actions, scriptSource: nil, scriptOutput: nil,
                       durationSeconds: nil)
    }

    private func render(_ invocation: ToolInvocation, folds: [Int: FoldState] = [:], width: CGFloat = 600) -> RenderedToolBody {
        ToolDetailRenderer.render(invocation, fontSize: 13, width: width, folds: folds,
                                  appearance: NSAppearance(named: .aqua)!)
    }

    private func findMap(_ invocation: ToolInvocation, _ body: RenderedToolBody) -> ToolFindMap {
        ToolFindMap(segments: ToolSearchText.segments(of: invocation), sourceMap: body.sourceMap)
    }

    func testFindMapMapsDecodedRangesToRenderedText() {
        let numbered = shell("cat notes", output: "alpha beta\ngamma", shape: .lineNumbered(gutter: [1, 2]))
        let failing = shell("make", output: "boom", bracket: "exit 2", facts: [AgentFact(kind: .exitCode(2))],
                            status: .failed(exitCode: 2))
        let inv = invocation([numbered, failing], status: .failed(exitCode: 2))
        let body = render(inv)
        let map = findMap(inv, body)
        let search = ToolSearchText.text(of: inv) as NSString
        let rendered = body.attributed.string as NSString

        // Across a numbered line break: one piece per line, the gutter between them is not highlighted.
        let span = search.range(of: "beta\ngamma")
        let pieces = map.renderedRanges(forSearchRange: span)
        XCTAssertEqual(pieces.map { rendered.substring(with: $0) }, ["beta", "gamma"])

        // The second action's output.
        let boom = map.renderedRanges(forSearchRange: search.range(of: "boom"))
        XCTAssertEqual(boom.map { rendered.substring(with: $0) }, ["boom"])

        // The bracket line maps to the footer chip, which renders after the output (not monotone).
        let exit = map.renderedRanges(forSearchRange: search.range(of: "exit 2"))
        XCTAssertEqual(exit.map { rendered.substring(with: $0) }, ["exit 2"])
        XCTAssertGreaterThan(exit.first?.location ?? 0, boom.first?.location ?? .max)
    }

    func testFoldOpeningRevealsHiddenOutputLineThenCutLongLine() throws {
        var lines = (1...200).map { "line \($0)" }
        lines[149] = "needle here"
        let longLine = String(repeating: "abcdefghij", count: 80) + " deepneedle"
        lines[159] = longLine
        let inv = invocation([shell("seq 1 200", output: lines.joined(separator: "\n"))])
        let search = ToolSearchText.text(of: inv) as NSString

        // Folded: line 150 is hidden, so Find opens the pane.
        let folded = render(inv)
        let needle = search.range(of: "needle here")
        XCTAssertTrue(findMap(inv, folded).renderedRanges(forSearchRange: needle).isEmpty)
        let open = try XCTUnwrap(ToolFindFolds.opening(forSearchRange: needle, in: inv, folds: [:],
                                                       foldLinks: folded.foldLinks.map(\.action)))
        XCTAssertEqual(open.key, 0)
        XCTAssertTrue(open.state.showAll)

        // Shown in full, the line is visible; the long line's end is still cut.
        let shown = render(inv, folds: [0: open.state])
        XCTAssertFalse(findMap(inv, shown).renderedRanges(forSearchRange: needle).isEmpty)
        let deep = search.range(of: "deepneedle")
        XCTAssertTrue(findMap(inv, shown).renderedRanges(forSearchRange: deep).isEmpty)
        let cut = try XCTUnwrap(ToolFindFolds.opening(forSearchRange: deep, in: inv, folds: [0: open.state],
                                                      foldLinks: shown.foldLinks.map(\.action)))
        XCTAssertEqual(cut.key, 0)
        XCTAssertTrue(cut.state.showAll)
        XCTAssertEqual(cut.state.openedLongLines, [159], "the cut line opens, the pane stays open")
        let full = render(inv, folds: [0: cut.state])
        XCTAssertFalse(findMap(inv, full).renderedRanges(forSearchRange: deep).isEmpty)

        // Nothing more opens: the match stays counted on the pill.
        XCTAssertNil(ToolFindFolds.opening(forSearchRange: deep, in: inv, folds: [0: cut.state],
                                           foldLinks: full.foldLinks.map(\.action)))
    }

    func testFoldOpeningInCommandOpensTheCommandPane() throws {
        let command = (1...30).map { "echo step\($0)" }.joined(separator: "\n")
        let inv = invocation([shell(command, output: "ok")])
        let search = ToolSearchText.text(of: inv) as NSString
        let hidden = search.range(of: "step25")
        let body = render(inv)
        XCTAssertTrue(findMap(inv, body).renderedRanges(forSearchRange: hidden).isEmpty)
        let open = try XCTUnwrap(ToolFindFolds.opening(forSearchRange: hidden, in: inv, folds: [:],
                                                       foldLinks: body.foldLinks.map(\.action)))
        XCTAssertEqual(open.key, 0)
        XCTAssertTrue(open.state.commandShowAll)
        XCTAssertFalse(findMap(inv, render(inv, folds: [0: open.state])).renderedRanges(forSearchRange: hidden).isEmpty)
        XCTAssertNil(ToolFindFolds.opening(forSearchRange: hidden, in: inv, folds: [0: open.state], foldLinks: []))
    }
}
