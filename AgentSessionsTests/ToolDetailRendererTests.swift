import XCTest
import AppKit
@testable import AgentSessions

/// Task 11: `ToolDetailRenderer` — one invocation as one attributed string: context line, command
/// pane, heredoc pane, generic key/value list, output pane, fold rows, notes and footer facts.
final class ToolDetailRendererTests: XCTestCase {
    private typealias F = TranscriptTestFixtures
    private typealias Block = SessionTranscriptBuilder.LogicalBlock

    private let fontSize: CGFloat = 13
    private let width: CGFloat = 600

    // MARK: - Fixtures

    private func json(_ object: [String: Any]) -> String {
        ToolJSON.string(from: object, pretty: false) ?? "{}"
    }

    /// The invocation of the call at block 1, through the real builder.
    private func built(_ blocks: [Block], source: SessionSource) -> ToolInvocation {
        let stream = F.sequence(blocks)
        let index = ToolInvocationIndex.build(blocks: stream, source: source)
        let id = index.invocationIDByBlock[1] ?? -1
        let ref = index.invocations.first { $0.id == id }
            ?? ToolInvocationRef(id: -1, callBlockIndex: nil, outputBlockIndices: [], status: .unknown)
        return ToolInvocationBuilder.build(ref, blocks: stream, index: index, source: source, duration: nil)
    }

    private func decoded(_ text: String, shape: TextShape = .plain) -> DecodedText {
        let length = (text as NSString).length
        return DecodedText(text: text,
                           sourceMap: length == 0 ? [] : [SourceMapEntry(rendered: NSRange(location: 0, length: length),
                                                                         source: NSRange(location: 0, length: length))],
                           shape: shape)
    }

    /// A shell action whose `plainText` has the builder's form (spec §8): `$ command`, the
    /// `[bracket]` line when given, then the output.
    private func shell(_ command: String, output: String?, shape: TextShape = .plain, status: ToolStatus = .success,
                       facts: [AgentFact] = [], bracket: String? = nil, context: [ToolContextItem] = [],
                       hiddenNotes: [String] = []) -> ToolAction {
        var lines = ["$ " + command]
        if let bracket { lines.append("[" + bracket + "]") }
        if let output, !output.isEmpty { lines.append(output) }
        return ToolAction(category: .shell, verbKey: ToolVerb.ran, object: command, objectIsAgentLabel: false,
                          objectDetail: nil, context: context, command: command, exactCommand: command, heredoc: nil,
                          inputFields: [], output: output.map { decoded($0, shape: shape) }, facts: facts,
                          hiddenNotes: hiddenNotes, status: status, plainText: lines.joined(separator: "\n"))
    }

    private func invocation(_ actions: [ToolAction], status: ToolStatus = .success) -> ToolInvocation {
        ToolInvocation(ref: ToolInvocationRef(id: 0, callBlockIndex: 0, outputBlockIndices: [1], status: status),
                       displayToolName: "shell", actions: actions, scriptSource: nil, scriptOutput: nil,
                       durationSeconds: nil)
    }

    private func render(_ invocation: ToolInvocation, folds: [Int: FoldState] = [:]) -> RenderedToolBody {
        ToolDetailRenderer.render(invocation, fontSize: fontSize, width: width, folds: folds,
                                  appearance: NSAppearance(named: .aqua)!)
    }

    private func numbered(_ range: ClosedRange<Int>, _ make: (Int) -> String = { "line \($0)" }) -> String {
        range.map(make).joined(separator: "\n")
    }

    /// Same color in light and dark (dynamic colors are new instances on every access).
    private func sameColor(_ a: Any?, _ b: NSColor, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        guard let a = a as? NSColor else { return false }
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            var ra: NSColor?
            var rb: NSColor?
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                ra = a.usingColorSpace(.sRGB)
                rb = b.usingColorSpace(.sRGB)
            }
            guard let ra, let rb else { return false }
            let delta = abs(ra.redComponent - rb.redComponent) + abs(ra.greenComponent - rb.greenComponent)
                + abs(ra.blueComponent - rb.blueComponent) + abs(ra.alphaComponent - rb.alphaComponent)
            if delta > 0.004 { return false }
        }
        return true
    }

    private func weight(_ font: NSFont?) -> CGFloat {
        let traits = font?.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
        return (traits?[.weight] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
    }

    // MARK: - Brief tests

    func testCommandAndOutputPanes() {
        let body = render(invocation([shell("make", output: "built 3 targets\nok")]))
        let s = body.attributed.string as NSString
        let prompt = s.range(of: "$ make")
        XCTAssertNotEqual(prompt.location, NSNotFound, body.attributed.string)
        XCTAssertTrue(body.attributed.string.contains("built 3 targets\nok"))
        guard prompt.location != NSNotFound else { return }

        let commandAt = prompt.location + 2
        XCTAssertTrue(sameColor(body.attributed.attribute(.backgroundColor, at: commandAt, effectiveRange: nil),
                                MarkdownStyle.codeBlockBackground), "command pane uses the 4.2 code card fill")
        XCTAssertNotNil(body.attributed.attribute(.markdownCodeBlockBg, at: commandAt, effectiveRange: nil),
                        "the fill is restorable after a find highlight")
        let font = body.attributed.attribute(.font, at: commandAt, effectiveRange: nil) as? NSFont
        XCTAssertEqual(font?.pointSize, fontSize - 0.5)
        XCTAssertEqual(font?.isFixedPitch, true)
        XCTAssertEqual(body.attributed.attribute(.foregroundColor, at: prompt.location, effectiveRange: nil) as? NSColor,
                       .tertiaryLabelColor, "the $ prompt is tertiary")

        let outputAt = s.range(of: "built 3 targets").location
        XCTAssertTrue(sameColor(body.attributed.attribute(.backgroundColor, at: outputAt, effectiveRange: nil),
                                MarkdownStyle.codeBlockBackground), "output pane uses the same fill")
        XCTAssertEqual(body.plainCopyText, "$ make\nbuilt 3 targets\nok")
    }

    func testFoldRowHasLink() {
        let output = numbered(1...100)
        let body = render(invocation([shell("seq 100", output: output)]))
        let showAll = body.foldLinks.filter { $0.action == .showAll(action: 0) }
        XCTAssertEqual(showAll.count, 1)
        guard let link = showAll.first else { return }
        let url = body.attributed.attribute(.link, at: link.range.location, effectiveRange: nil) as? URL
        XCTAssertEqual(url?.absoluteString, "toolfold:showAll:0:0")
        XCTAssertEqual(url.flatMap(ToolFoldLink.init(url:)), .showAll(action: 0))
        XCTAssertEqual((body.attributed.string as NSString).substring(with: link.range), "Show all")
        XCTAssertTrue(body.attributed.string.contains("⋯ 84 more lines"), body.attributed.string)
        XCTAssertTrue(body.foldLinks.contains { $0.action == .copyOutput(action: 0) })
        XCTAssertFalse(body.foldLinks.contains { $0.action == .showMore(action: 0) },
                       "84 hidden lines: Show 500 more would be the same as Show all")
        XCTAssertEqual(body.plainCopyText, "$ seq 100\n" + numbered(1...12) + "\n" + numbered(97...100),
                       "copy has the shown lines only, no fold row")

        let long = render(invocation([shell("seq 1000", output: numbered(1...1000))]))
        let more = long.foldLinks.first { $0.action == .showMore(action: 0) }
        XCTAssertNotNil(more)
        if let more {
            XCTAssertEqual((long.attributed.string as NSString).substring(with: more.range), "Show 500 more")
        }
        var state = FoldState()
        state.extraLinesShown = 500
        let opened = render(invocation([shell("seq 1000", output: numbered(1...1000))]), folds: [0: state])
        XCTAssertTrue(opened.attributed.string.contains("line 512\n"))
        XCTAssertFalse(opened.attributed.string.contains("line 513\n"))
    }

    func testCopyTextExcludesGutter() {
        let read = "     1→let a = 1\n     2→let b = 2\n     3→let c = 3"
        let invocation = built([
            F.block(.user, text: "go"),
            F.block(.toolCall, id: "t1", toolName: "Read", toolInput: json(["file_path": "/tmp/a.swift"])),
            F.block(.toolOut, id: "t1", text: read, toolName: "Read"),
        ], source: .claude)
        guard case .lineNumbered = invocation.actions.first?.output?.shape else {
            return XCTFail("fixture must decode as line-numbered: \(String(describing: invocation.actions.first?.output))")
        }
        let body = render(invocation)
        XCTAssertTrue(body.plainCopyText.contains("let a = 1\nlet b = 2\nlet c = 3"), body.plainCopyText)
        for line in body.plainCopyText.components(separatedBy: "\n") where line.contains("let ") {
            XCTAssertTrue(line.hasPrefix("let "), "no leading number: \(line.debugDescription)")
        }

        let s = body.attributed.string as NSString
        let content = s.range(of: "let b = 2")
        let lineStart = s.lineRange(for: NSRange(location: content.location, length: 0)).location
        let gutter = NSRange(location: lineStart, length: content.location - lineStart)
        XCTAssertEqual(s.substring(with: gutter).trimmingCharacters(in: .whitespaces), "2")
        var gutterFlags: [Bool] = []
        body.attributed.enumerateAttribute(.toolGutter, in: gutter) { value, _, _ in
            gutterFlags.append((value as? Bool) == true)
        }
        XCTAssertEqual(gutterFlags, [true], "the whole gutter cell carries .toolGutter")
        XCTAssertNil(body.attributed.attribute(.toolGutter, at: content.location, effectiveRange: nil))
        let number = s.range(of: "2", options: [], range: gutter)
        XCTAssertEqual(body.attributed.attribute(.foregroundColor, at: number.location, effectiveRange: nil) as? NSColor,
                       .tertiaryLabelColor)
    }

    func testSourceMapCoversOutput() {
        let output = numbered(1...40) { "row \($0) ✓ done" }
        let action = shell("seq 40", output: output,
                           facts: [AgentFact(kind: .exitCode(0)), AgentFact(kind: .wallTime(1.2))],
                           bracket: "exit 0 · 1.2s")
        let body = render(invocation([action]))
        let rendered = body.attributed.string as NSString
        let plain = action.plainText as NSString
        XCTAssertFalse(body.sourceMap.isEmpty)
        for entry in body.sourceMap {
            XCTAssertEqual(entry.actionIndex, 0)
            XCTAssertEqual(rendered.substring(with: entry.rendered), plain.substring(with: entry.source),
                           "every entry maps equal text")
        }
        let outputBase = plain.length - (output as NSString).length
        for n in Array(1...12) + Array(37...40) {
            let needle = "row \(n) ✓ done"
            let r = rendered.range(of: needle + (n == 40 ? "" : "\n"))
            XCTAssertNotEqual(r.location, NSNotFound, needle)
            let line = NSRange(location: r.location, length: (needle as NSString).length)
            guard let entry = body.sourceMap.first(where: { NSIntersectionRange($0.rendered, line).length == line.length })
            else { XCTFail("line \(n) is not covered"); continue }
            let mapped = entry.source.location + (line.location - entry.rendered.location)
            XCTAssertGreaterThanOrEqual(mapped, outputBase, "maps into the output part of plainText")
            XCTAssertEqual(plain.substring(with: NSRange(location: mapped, length: line.length)), needle)
        }
        XCTAssertTrue(body.sourceMap.contains { rendered.substring(with: $0.rendered) == "$ " }, "the prompt maps")
        XCTAssertTrue(body.sourceMap.contains { rendered.substring(with: $0.rendered) == "exit 0" },
                      "a footer chip that is in the plain bracket maps")
        let fold = rendered.range(of: "more lines")
        XCTAssertFalse(body.sourceMap.contains { NSIntersectionRange($0.rendered, fold).length > 0 },
                       "fold rows map to nothing")
    }

    func testFailedExitIsRed() {
        let action = shell("make", output: "error: boom", status: .failed(exitCode: 2),
                           facts: [AgentFact(kind: .exitCode(2))], bracket: "exit 2")
        let body = render(invocation([action], status: .failed(exitCode: 2)))
        let s = body.attributed.string as NSString
        let r = s.range(of: "exit 2")
        XCTAssertNotEqual(r.location, NSNotFound, body.attributed.string)
        guard r.location != NSNotFound else { return }
        XCTAssertEqual(body.attributed.attribute(.foregroundColor, at: r.location, effectiveRange: nil) as? NSColor,
                       .systemRed)
        XCTAssertGreaterThan(weight(body.attributed.attribute(.font, at: r.location, effectiveRange: nil) as? NSFont), 0.2,
                             "semibold")

        let ok = render(invocation([shell("true", output: "", facts: [AgentFact(kind: .exitCode(0))], bracket: "exit 0")]))
        let zero = (ok.attributed.string as NSString).range(of: "exit 0")
        XCTAssertNotEqual(zero.location, NSNotFound)
        guard zero.location != NSNotFound else { return }
        XCTAssertEqual(ok.attributed.attribute(.foregroundColor, at: zero.location, effectiveRange: nil) as? NSColor,
                       .tertiaryLabelColor, "exit 0 is a plain footer fact")
    }

    func testGenericFieldsListed() {
        let invocation = built([
            F.block(.user, text: "go"),
            F.block(.toolCall, id: "t1", toolName: "mcp__github__create_pull_request",
                    toolInput: json(["owner": "a", "draft": true])),
            F.block(.toolOut, id: "t1", text: "ok", toolName: "mcp__github__create_pull_request"),
        ], source: .claude)
        let body = render(invocation)
        let lines = body.attributed.string.components(separatedBy: "\n")
        XCTAssertTrue(lines.contains("owner  a"), "\(lines)")
        XCTAssertTrue(lines.contains("draft  true"), "\(lines)")
        XCTAssertTrue(lines.contains("ok"))
        let rendered = body.attributed.string as NSString
        let plain = invocation.actions[0].plainText as NSString
        for entry in body.sourceMap {
            XCTAssertEqual(rendered.substring(with: entry.rendered), plain.substring(with: entry.source))
        }
        let value = rendered.range(of: "true")
        XCTAssertTrue(body.sourceMap.contains { NSIntersectionRange($0.rendered, value).length == value.length },
                      "field values map into plainText")
    }

    func testGenericValuesKeepNewlinesAndCutNestedJSON() {
        let labels = (1...40).map { "label-\($0)" }
        let invocation = built([
            F.block(.user, text: "go"),
            F.block(.toolCall, id: "t1", toolName: "mcp__github__create_pull_request",
                    toolInput: json(["body": "line 1\nline 2", "labels": labels])),
            F.block(.toolOut, id: "t1", text: "ok", toolName: "mcp__github__create_pull_request"),
        ], source: .claude)
        let body = render(invocation)
        let rows = body.attributed.string.components(separatedBy: "\n")
        XCTAssertTrue(rows.contains("body    line 1"), "keys align to the longest key: \(rows)")
        XCTAssertTrue(rows.contains("line 2"), "a multi-line string keeps its newline; the indent is a paragraph inset")

        let compact = ToolInvocationBuilder.plainValue(.array(labels.map { .string($0) }))
        XCTAssertGreaterThan(compact.count, 200)
        let cut = "… +\(compact.count - 200) chars"
        guard let row = rows.first(where: { $0.hasPrefix("labels  ") }) else { return XCTFail("\(rows)") }
        XCTAssertEqual(row, "labels  " + String(compact.prefix(200)) + "\u{2028}" + cut, "compact one-line JSON cut at 200")
        XCTAssertTrue(body.plainCopyText.contains("labels  " + String(compact.prefix(200)) + "\n"), body.plainCopyText)
        XCTAssertFalse(body.plainCopyText.contains(cut))

        let rendered = body.attributed.string as NSString
        let plain = invocation.actions[0].plainText as NSString
        let shown = rendered.range(of: String(compact.prefix(200)))
        let entry = body.sourceMap.first { NSIntersectionRange($0.rendered, shown).length == shown.length }
        XCTAssertEqual(entry.map { plain.substring(with: $0.source) }, String(compact.prefix(200)))
    }

    func testHeredocPaneHasGutter() {
        let lines = numbered(1...14) { "echo \($0)" }
        let invocation = built([
            F.block(.user, text: "go"),
            F.block(.toolCall, id: "t1", toolName: "Bash", toolInput: json(["command": "cat > f.sh <<'EOF'\n\(lines)\nEOF"])),
            F.block(.toolOut, id: "t1", text: "", toolName: "Bash"),
        ], source: .claude)
        XCTAssertEqual(invocation.actions.first?.heredoc?.text, lines)
        let body = render(invocation)
        let text = body.attributed.string
        XCTAssertTrue(text.contains("$ cat > f.sh <<'EOF'"), text)
        XCTAssertTrue(text.contains("echo 12"))
        XCTAssertFalse(text.contains("echo 13"), "folded after 12 visual lines")

        let s = text as NSString
        let first = s.range(of: "echo 1\n")
        let lineStart = s.lineRange(for: NSRange(location: first.location, length: 0)).location
        let gutter = NSRange(location: lineStart, length: first.location - lineStart)
        XCTAssertEqual(s.substring(with: gutter).trimmingCharacters(in: .whitespaces), "1", "numbered pane")
        XCTAssertEqual(body.attributed.attribute(.toolGutter, at: lineStart, effectiveRange: nil) as? Bool, true)

        let rows = text.components(separatedBy: "\n")
        let foldIndex = rows.firstIndex { $0.contains("2 more lines") }
        let terminatorIndex = rows.firstIndex { $0.trimmingCharacters(in: .whitespaces) == "EOF" }
        XCTAssertNotNil(foldIndex, "\(rows)")
        XCTAssertNotNil(terminatorIndex, "\(rows)")
        if let foldIndex, let terminatorIndex { XCTAssertLessThan(foldIndex, terminatorIndex) }
        XCTAssertTrue(body.foldLinks.contains { $0.action == .showFullCommand(action: 0) })

        var state = FoldState()
        state.commandShowAll = true
        let open = render(invocation, folds: [0: state])
        XCTAssertTrue(open.attributed.string.contains("echo 14\n"))
        XCTAssertFalse(open.foldLinks.contains { $0.action == .showFullCommand(action: 0) })
        XCTAssertTrue(open.plainCopyText.contains("echo 1\necho 2\n"), "copy skips the gutter: \(open.plainCopyText)")
        XCTAssertTrue(open.plainCopyText.hasSuffix("echo 14\nEOF"), open.plainCopyText)
    }

    func testRenderIsFastForHugeOutput() {
        let output = (0..<20_000).map { "line \($0): Compiling AgentSessionsCore SessionEvent.swift" }.joined(separator: "\n")
        let invocation = invocation([shell("swift test", output: output)])
        var state = FoldState()
        state.showAll = true
        _ = render(invocation, folds: [0: state])
        let start = CFAbsoluteTimeGetCurrent()
        let body = render(invocation, folds: [0: state])
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        print("ToolDetailRenderer huge output (20,000 lines, \(output.utf8.count) bytes, showAll): \(Int(elapsed * 1000)) ms")
        XCTAssertTrue(body.attributed.string.trimmingCharacters(in: .newlines)
            .hasSuffix("line 19999: Compiling AgentSessionsCore SessionEvent.swift"))
        XCTAssertTrue(body.foldLinks.isEmpty, "everything is shown")
        XCTAssertLessThan(elapsed, 0.1, "50 ms release budget × 2 in Debug")

        // Numbered variant: a gutter cell before every line.
        let numberedText = (0..<20_000).map { "    let value\($0) = compute(\($0))" }.joined(separator: "\n")
        let numberedOutput = DecodedText(text: numberedText,
                                         sourceMap: [SourceMapEntry(rendered: NSRange(location: 0, length: (numberedText as NSString).length),
                                                                    source: NSRange(location: 0, length: (numberedText as NSString).length))],
                                         shape: .lineNumbered(gutter: Array(1...20_000)))
        var numberedAction = shell("cat big.swift", output: numberedText)
        numberedAction.output = numberedOutput
        let numbered = self.invocation([numberedAction])
        _ = render(numbered, folds: [0: state])
        let numberedStart = CFAbsoluteTimeGetCurrent()
        let numberedBody = render(numbered, folds: [0: state])
        let numberedElapsed = CFAbsoluteTimeGetCurrent() - numberedStart
        print("ToolDetailRenderer huge numbered output (20,000 lines, \(numberedText.utf8.count) bytes, showAll): \(Int(numberedElapsed * 1000)) ms")
        XCTAssertTrue(numberedBody.attributed.string.contains("\t20000\t    let value19999 = compute(19999)"))
        XCTAssertEqual(numberedBody.sourceMap.count, 20_002, "the prompt, the command, and one entry per numbered line")
        XCTAssertFalse(numberedBody.plainCopyText.contains("\t20000\t"), "copy skips the gutter")
        XCTAssertTrue(numberedBody.plainCopyText.hasSuffix("    let value19999 = compute(19999)"))
        XCTAssertLessThan(numberedElapsed, 0.1, "numbered panes stay inside the same budget")
    }

    func testHugeHeredocWithCommandShowAllIsCapped() {
        let body = (1...30_000).map { "echo \($0)" }.joined(separator: "\n")
        let command = "cat > big.sh <<'EOF'"
        var action = shell(command, output: nil)
        action.exactCommand = command + "\n" + body + "\nEOF"
        action.heredoc = decoded(body)
        action.plainText = "$ " + action.exactCommand!
        var state = FoldState()
        state.commandShowAll = true
        let rendered = render(invocation([action]), folds: [0: state])
        let text = rendered.attributed.string
        XCTAssertTrue(text.contains("\techo 20000\n"), "Show all shows 20,000 lines")
        XCTAssertFalse(text.contains("echo 20001"), "and stops at the cap")
        XCTAssertTrue(text.contains("10,000 more lines past the display limit") || text.contains("10000 more lines past the display limit"),
                      "the rest is a capped fold")
        XCTAssertFalse(rendered.foldLinks.contains { $0.action == .showFullCommand(action: 0) },
                       "nothing more to open in place")
        let rows = text.components(separatedBy: "\n")
        XCTAssertEqual(rows.last(where: { !$0.isEmpty })?.trimmingCharacters(in: .whitespaces), "EOF",
                       "the terminator still closes the pane")
    }

    // MARK: - Beyond the brief

    func testFoldLinkRoundTrip() {
        let links: [ToolFoldLink] = [.showMore(action: 3), .showAll(action: 0), .openLongLine(action: 2, line: 41),
                                     .showFullCommand(action: 1), .showScript, .copyOutput(action: 5)]
        for link in links {
            XCTAssertEqual(ToolFoldLink(url: link.url), link, link.url.absoluteString)
        }
        XCTAssertEqual(ToolFoldLink.openLongLine(action: 2, line: 41).url.absoluteString, "toolfold:openLongLine:2:41")
        XCTAssertEqual(ToolFoldLink.showMore(action: 3).url.absoluteString, "toolfold:showMore:3:0")
        XCTAssertEqual(ToolFoldLink.showScript.url.absoluteString, "toolfold:showScript:0:0")
        XCTAssertNil(ToolFoldLink(url: URL(string: "https://example.com/a:b")!))
        XCTAssertNil(ToolFoldLink(url: URL(string: "toolfold:explode:1:2")!))
        XCTAssertNil(ToolFoldLink(url: URL(string: "toolfold:showAll:x:0")!))
        XCTAssertNil(ToolFoldLink(url: URL(string: "toolfold:showAll:1")!))
    }

    func testLongLineCutUsesBudgetPrefix() {
        // 1,600 columns (~21 visual lines): opened, it still counts as 4 in the budget and stays visible.
        let wide = String(repeating: "中文", count: 400)
        let ascii = String(repeating: "abcdefghij", count: 200)
        let output = "short\n" + wide + "\nmiddle\n" + ascii + "\nend"
        let action = shell("cat x", output: output)
        let body = render(invocation([action]))
        let s = body.attributed.string as NSString
        let plain = action.plainText as NSString

        for (line, source) in [(1, wide), (3, ascii)] {
            guard let link = body.foldLinks.first(where: { $0.action == .openLongLine(action: 0, line: line) }) else {
                XCTFail("line \(line) has no open link: \(body.foldLinks.map(\.action))")
                continue
            }
            let linkText = s.substring(with: link.range)
            XCTAssertTrue(linkText.hasPrefix("… +") && linkText.hasSuffix(" chars"), linkText)
            let hidden = Int(linkText.filter(\.isNumber)) ?? -1
            let lineStart = s.paragraphRange(for: NSRange(location: link.range.location, length: 0)).location
            let shown = s.substring(with: NSRange(location: lineStart, length: link.range.location - lineStart))
            XCTAssertTrue(shown.hasSuffix("\u{2028}"), "the control starts its own visual line")
            let kept = String(shown.dropLast())
            XCTAssertTrue(source.hasPrefix(kept), "the shown text is the line's prefix")
            XCTAssertEqual(kept.count + hidden, source.count, "shown prefix and hiddenChars agree")
            XCTAssertGreaterThan(kept.count, 0)

            let keptRange = NSRange(location: lineStart, length: (kept as NSString).length)
            let entry = body.sourceMap.first { NSIntersectionRange($0.rendered, keptRange).length == keptRange.length }
            XCTAssertEqual(entry.map { plain.substring(with: $0.source) }, kept, "the kept prefix maps")
            XCTAssertFalse(body.sourceMap.contains { NSIntersectionRange($0.rendered, link.range).length > 0 })
            XCTAssertFalse(body.plainCopyText.contains(linkText), "the control is not copied")
        }

        var state = FoldState()
        state.openedLongLines = [1]
        let opened = render(invocation([action]), folds: [0: state])
        XCTAssertTrue(opened.attributed.string.contains(wide))
        XCTAssertFalse(opened.foldLinks.contains { $0.action == .openLongLine(action: 0, line: 1) })
        XCTAssertTrue(opened.foldLinks.contains { $0.action == .openLongLine(action: 0, line: 3) })
    }

    func testScriptOutputAndShowScript() {
        var invocation = invocation([shell("ls", output: "a.txt"), shell("pwd", output: "/tmp")])
        invocation.scriptSource = "const a = await tools.exec_command({cmd: \"ls\"});"
        invocation.scriptOutput = decoded("summary printed by the script")
        let body = render(invocation)
        let s = body.attributed.string as NSString
        let script = s.range(of: "summary printed by the script")
        XCTAssertNotEqual(script.location, NSNotFound)
        XCTAssertGreaterThan(script.location, s.range(of: "/tmp").location, "after all actions")
        let link = body.foldLinks.first { $0.action == .showScript }
        XCTAssertNotNil(link)
        if let link {
            XCTAssertGreaterThan(link.range.location, script.location)
            XCTAssertEqual(s.substring(with: link.range), "Show script")
        }
        let entry = body.sourceMap.first { NSIntersectionRange($0.rendered, script).length == script.length }
        XCTAssertEqual(entry?.actionIndex, 2, "script output maps with actionIndex == actions.count")
        XCTAssertEqual(entry?.source, NSRange(location: 0, length: script.length))
        XCTAssertTrue(body.sourceMap.contains { $0.actionIndex == 1 && s.substring(with: $0.rendered) == "/tmp" })
        XCTAssertFalse(body.plainCopyText.contains("Show script"))
        XCTAssertTrue(body.plainCopyText.contains("a.txt\n\n$ pwd"), "a blank line between actions: \(body.plainCopyText)")
    }

    func testShowScriptLinkReadsHideScriptWhileShown() {
        var invocation = invocation([shell("ls", output: "a.txt")])
        invocation.scriptSource = "const a = await tools.exec_command({cmd: \"ls\"});"
        invocation.scriptOutput = decoded("summary")
        let shown = ToolDetailRenderer.render(invocation, fontSize: fontSize, width: width, folds: [:],
                                              appearance: NSAppearance(named: .aqua)!, scriptShown: true)
        let text = shown.attributed.string as NSString
        let link = shown.foldLinks.first { $0.action == .showScript }
        XCTAssertEqual(link.map { text.substring(with: $0.range) }, "Hide script")
        XCTAssertEqual(render(invocation).foldLinks.first { $0.action == .showScript }
            .map { (render(invocation).attributed.string as NSString).substring(with: $0.range) }, "Show script")
    }

    func testScriptPaneCopyLinkReadsCopyScript() {
        let long = (1...200).map { "line \($0)" }.joined(separator: "\n")
        var invocation = invocation([shell("ls", output: long)])
        invocation.scriptSource = (1...200).map { "const v\($0) = \($0);" }.joined(separator: "\n")
        let presentation = ToolPresentationRenderer.render(invocation, folds: [:], scriptShown: true,
                                                           fontSize: fontSize, width: width)
        let attributed = presentation.attributed
        var titles: [Int: [String]] = [:]
        attributed.enumerateAttribute(.link, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            guard let url = value as? URL, case .copyOutput(let key)? = ToolFoldLink(url: url) else { return }
            titles[key, default: []].append((attributed.string as NSString).substring(with: range))
        }
        XCTAssertEqual(titles[0], ["Copy output"], "the action's output pane keeps Copy output")
        XCTAssertEqual(titles[ToolPresentationRenderer.scriptFoldKey(invocation)], ["Copy script"],
                       "the script pane's copy link names what it copies")
    }

    func testIncreaseContrastStrengthensPaneFill() {
        let source = invocation([shell("make", output: "built")])
        let normal = render(source)
        let contrast = ToolDetailRenderer.render(source, fontSize: fontSize, width: width, folds: [:],
                                                 appearance: NSAppearance(named: .aqua)!, increaseContrast: true)
        XCTAssertEqual(normal.attributed.string, contrast.attributed.string, "only the colors change")
        let at = (normal.attributed.string as NSString).range(of: "built").location
        let normalFill = normal.attributed.attribute(.backgroundColor, at: at, effectiveRange: nil) as? NSColor
        let contrastFill = contrast.attributed.attribute(.backgroundColor, at: at, effectiveRange: nil) as? NSColor
        XCTAssertNotNil(contrastFill)
        XCTAssertFalse(sameColor(contrastFill, normalFill ?? .clear), "the pane fill is stronger")
        // Strength: farther from the page background (white in light, black in dark) than before.
        for (name, page) in [(NSAppearance.Name.aqua, CGFloat(1)), (.darkAqua, CGFloat(0))] {
            var normalGray: CGFloat = 0
            var contrastGray: CGFloat = 0
            NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
                normalGray = normalFill?.usingColorSpace(.deviceGray)?.whiteComponent ?? -1
                contrastGray = contrastFill?.usingColorSpace(.deviceGray)?.whiteComponent ?? -1
            }
            XCTAssertGreaterThan(abs(contrastGray - page), abs(normalGray - page), "\(name.rawValue)")
        }
        XCTAssertTrue(sameColor(contrast.attributed.attribute(.markdownCodeBlockBg, at: at, effectiveRange: nil),
                                contrastFill ?? .clear), "the find-restore marker keeps the same fill")
    }

    func testErrorOutputShowsTailFirst() {
        let action = shell("make", output: numbered(1...100), status: .failed(exitCode: 2),
                           facts: [AgentFact(kind: .exitCode(2))], bracket: "exit 2")
        let body = render(invocation([action], status: .failed(exitCode: 2)))
        let s = body.attributed.string as NSString
        let fold = s.range(of: "⋯ 82 more lines")
        XCTAssertNotEqual(fold.location, NSNotFound, body.attributed.string)
        XCTAssertLessThan(fold.location, s.range(of: "line 83\n").location, "the fold sits above the tail")
        XCTAssertFalse(body.attributed.string.contains("line 1\n"))
        XCTAssertTrue(body.plainCopyText.hasPrefix("$ make\nline 83\n"), body.plainCopyText)
    }

    func testShowAllCapOffersCopyOutput() {
        let output = (0..<20_010).map { "r\($0)" }.joined(separator: "\n")
        var state = FoldState()
        state.showAll = true
        let body = render(invocation([shell("yes", output: output)]), folds: [0: state])
        XCTAssertTrue(body.attributed.string.contains("r19999\n"))
        XCTAssertFalse(body.attributed.string.contains("r20000"))
        XCTAssertTrue(body.attributed.string.contains("10 more lines"), "the rest is a fold")
        XCTAssertTrue(body.foldLinks.contains { $0.action == .copyOutput(action: 0) })
        XCTAssertFalse(body.foldLinks.contains { $0.action == .showAll(action: 0) || $0.action == .showMore(action: 0) },
                       "past the cap there is nothing more to show")
    }

    func testContextNotesAndFooterFacts() {
        let action = shell("swift build", output: "Build complete!", status: .failed(exitCode: 1),
                           facts: [AgentFact(kind: .exitCode(1)), AgentFact(kind: .wallTime(2)),
                                   AgentFact(kind: .truncated(agent: "Codex", originalTokens: 9000, totalLines: 842)),
                                   AgentFact(kind: .persisted(path: "/tmp/out.txt", bytes: 38_400)),
                                   AgentFact(kind: .note("aborted by user after 2s"))],
                           bracket: "exit 1 · 2.0s",
                           context: [ToolContextItem(key: "cwd", value: "~/Repository/Codex-History"),
                                     ToolContextItem(key: "shell", value: "zsh -lc")],
                           hiddenNotes: ["<system-reminder>be careful</system-reminder>"])
        let body = render(invocation([action], status: .failed(exitCode: 1)))
        let text = body.attributed.string
        let rows = text.components(separatedBy: "\n")
        XCTAssertEqual(rows.first, "cwd ~/Repository/Codex-History   shell zsh -lc", "\(rows)")
        let s = text as NSString
        let context = s.range(of: "~/Repository/Codex-History")
        let contextFont = body.attributed.attribute(.font, at: context.location, effectiveRange: nil) as? NSFont
        XCTAssertEqual(contextFont?.pointSize, 10.5)
        XCTAssertEqual(body.attributed.attribute(.foregroundColor, at: context.location, effectiveRange: nil) as? NSColor,
                       .tertiaryLabelColor)

        XCTAssertTrue(rows.contains("system note"), "\(rows)")
        XCTAssertFalse(text.contains("be careful"), "the note stays collapsed")

        guard let footer = rows.last else { return XCTFail() }
        XCTAssertTrue(footer.hasPrefix("exit 1 · 2.0s · cut by Codex · 842 lines · output saved to a file ("), footer)
        XCTAssertTrue(footer.hasSuffix(") · aborted by user after 2s"), footer)
        let cut = s.range(of: "cut by Codex · 842 lines")
        XCTAssertEqual(body.attributed.attribute(.foregroundColor, at: cut.location, effectiveRange: nil) as? NSColor,
                       .systemOrange)
        let saved = s.range(of: "output saved to a file")
        XCTAssertEqual(body.attributed.attribute(.foregroundColor, at: saved.location, effectiveRange: nil) as? NSColor,
                       .tertiaryLabelColor)
        XCTAssertTrue(sameColor(body.attributed.attribute(.foregroundColor, at: s.range(of: "exit 1").location,
                                                          effectiveRange: nil), .systemRed))
    }

    func testRendersOffTheMainThread() {
        let invocation = invocation([shell("ls", output: numbered(1...30))])
        let appearance = NSAppearance(named: .darkAqua)!
        let done = expectation(description: "rendered")
        let fontSize = self.fontSize, width = self.width
        DispatchQueue.global(qos: .utility).async {
            let body = ToolDetailRenderer.render(invocation, fontSize: fontSize, width: width, folds: [:],
                                                 appearance: appearance)
            XCTAssertTrue(body.attributed.string.contains("line 30"))
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
    }
}
