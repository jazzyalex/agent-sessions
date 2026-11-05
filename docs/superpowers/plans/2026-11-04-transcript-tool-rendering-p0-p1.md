# Transcript Tool Rendering (P0 + P1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every tool call in the Session view decoded, paired and readable, for all 17 agents. P0 is a set of small fixes for the next point release. P1 adds the new invocation model and three-level UI, with a shell renderer and a generic renderer.

**Architecture:**
- Parsers gain typed tool fields (call id, namespace, original output value, sidecar, disposition), which flow into `LogicalBlock`.
- A new pure layer in `AgentSessions/ToolRendering/` turns blocks into `ToolInvocation`s:
  - pairing by call id;
  - a cheap status probe;
  - decoders, size budgets and an attributed renderer with a source map.
- `BlockTableController` emits one group-header row plus one row per invocation, using two new cell classes. Find, the role filters and the jump buttons move to invocation rows and decoded text.

**Tech Stack:** Swift 5, AppKit (NSTableView, TextKit 1 NSTextView), SwiftUI header views hosted in NSHostingView, XCTest. macOS 14.

**Spec:** `docs/superpowers/specs/2026-11-04-transcript-tool-rendering-design.md` (read it in full first; section numbers below refer to it). Mockup: `docs/mockups/transcript-tool-rendering-mockup.html`.

## Global Constraints

- macOS deployment floor stays 14.0. No new package dependencies.
- 4.2 decisions stay binding: one unified style, no new toolbar controls, no token or cost badges, no live pulse, no secret masking, Session/Text/JSON stay. JSON mode is unchanged.
- Card chrome is unchanged: 3 pt accent bar, 6% tint, 6 pt corner radius, `LayoutTokens` spacing. Tool accent is `NSColor.systemPurple`; failure is `NSColor.systemRed` on the row icon and exit chip only. Only dynamic colors are used.
- L1 row height is 24 pt. The verb uses the system font, 11.5 pt semibold, `secondaryLabelColor`. The object uses SF Mono 12 pt, `labelColor`, and the system font when it is an agent label (spec §14 Q1). Chips use SF Mono 10.5 pt, `tertiaryLabelColor`. The L2 pane font is the transcript font size − 0.5 pt.
- Budgets (spec §6.5):
  - Output pane: head 12 visual lines and tail 4. Error output shows the last 18 lines first.
  - Long line: cut after 4 visual lines.
  - "Show 500 more" steps by 500 lines. "Show all" stops at 20,000 lines or 2 MB.
  - Command input: shown in full up to 12 visual lines.
  - Minified JSON output: pretty-printed when it is ≤ 256 KB.
  - `toolOutputValue`: kept only when the output is ≤ 256 KB.
- Perf (spec §10.5):
  - Opening the largest local session takes main's time ±5%.
  - Opening an L2 row never blocks the main thread for more than 50 ms.
  - Pairing is one pass over the blocks.
- Every user-facing string is in `AgentSessions/Resources/Localizable.xcstrings`.
- New Swift files: `./scripts/xcode_add_file.rb AgentSessions.xcodeproj <Target> <file> <group>`. A file in an existing group adds exactly 4 pbxproj lines.
- Tests live in `AgentSessionsTests`. Run one class: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/<Class>`. Run the full suite at the end of each phase. The branch baseline is 3942 executed tests, 0 failures (measured on this worktree before Task 1); the executed count only grows and failures stay 0. Do not edit `tools/release/test-count-baseline.txt` (release flow only).
- Test seams: one Codex line parses through `SessionIndexer.parseLine(_:eventID:)` (see `SessionParserTests`). Claude has no single-line seam: write the lines to a temp `.jsonl` and call `ClaudeSessionParser.parseFileFull(at:)`. Tests that call `SessionTranscriptBuilder.coalescedBlocks` reset its cache in `setUp` (`SessionTranscriptBuilder._testResetCoalesceCache()`) or give each session a unique id, because the cache key is `id|events.count|fileSize|includeMeta`.
- Only one `xcodebuild` runs at a time (repo rule). Task implementers run sequentially, never in parallel, so each implementer runs the tests its task names.
- Git:
  - Owner approved (2026-11-04): branch `feature/transcript-tool-rendering` in a worktree, and local per-task commits. No push, no merge.
  - Commit with `git commit -- <paths>`. Use Conventional Commits with a `Why:` trailer. No `Tool:`/`Model:` trailers and no AI co-author (harness rule: no attribution lines).
- Never print, log or render the ciphertext of Codex `collaboration::*` messages (values starting `gAAAAA`).

## Review Focus

1. **Parallel outputs merged into one block.** `SessionTranscriptBuilder.canMerge` merges consecutive `.toolOut` blocks that share `messageID`. Claude puts the line `uuid` in `messageID`, so several `tool_result` items in one line fuse. (Parsers that put the call id in `messageID` cannot fuse different calls.) Expect two outputs with different call ids to stay two blocks. Test: Task 4, `testOutputsWithDifferentCallIDsNeverMerge`.
2. **A code-mode script whose printed text does not match its child calls** (`text(\`---${i}---\n${r.output}\`)` over `Promise.all`). Expect the decoded items under the script, child rows with commands only, and no chunk given to the wrong command. Test: Task 8, `testPromiseAllWithCustomPrintingDoesNotAssignChunks`.
3. **Live tail while a group is open.** New calls append to the last group while the user reads it. Expect the group to stay open, new rows to append without a full reload, and the scroll position to hold. Test: Task 12, `testAppendingCallToOpenGroupIsAppendOnly`.
4. **A Find query typed before the background decode finishes.** Expect results on raw text first, then one re-run on decoded text, with the find bar's "Searching tool output…" state between. Test: Task 15, `testFindRerunsOnceWhenDecodePassCompletes`.
5. **Narrow window, very wide CJK or emoji output.** Visual-line budgets must use real advances (CJK counts 2 columns), so a folded pane never exceeds its budget. Test: Task 10, `testWideCharactersCountTwoColumns`.

---

# P0 — quick fixes (next point release)

### Task 1: Tool JSON without escaped slashes

**Files:**
- Create: `AgentSessions/Utilities/ToolJSON.swift`
- Modify (route display serialization through `ToolJSON`): `AgentSessions/Utilities/PrettyJSON.swift:8`, `AgentSessions/Services/SessionTranscriptBuilder.swift:753`, `AgentSessions/Services/ToolTextBlockNormalizer.swift:985,1657,1666`, `AgentSessions/Services/SessionIndexer.swift` (its `stringifyJSON`), and each parser's tool input/output stringify: `ClaudeSessionParser.swift:1263,1274`, `OpenCodeSessionParser.swift:995`, `ClineSessionParser.swift:401`, `KimiSessionParser.swift:310`, `GrokSessionParser.swift:347`, `CursorSessionParser.swift:561`, `DevinSessionParser.swift:125`, `HermesSessionParser.swift:333`, `CopilotSessionParser.swift:379`, `QwenSessionParser.swift:792`, `DroidSessionParser.swift:921`, `OpenClawSessionParser.swift:804`, `DeepSeekHarness/DeepSeekHarnessSessionParser.swift:773`; also `FxSessionParser.swift` (`jsonEncode`, ~810) and `AntigravityTranscriptParser.swift` (~78) when they feed `toolInput`/`toolOutput`. Pi has no such site.
- Do not touch: any `rawJSON` / `rawJSONBase64` / `boundedRaw` encoder (`ClaudeSessionParser.swift:1306`, `CopilotSessionParser.swift:386`, `CursorSessionParser.swift:595`, `DroidSessionParser.swift:929`, `OpenClawSessionParser.swift:794`, `HermesSessionParser.swift:696`, `DeepSeekHarnessSessionParser.swift:790`; `DeepSeekHarnessSessionParserTests` asserts rawJSON keeps `\/`), pricing, OAuth, telemetry, archive serialization.
- Test: `AgentSessionsTests/ToolJSONTests.swift`

**Interfaces:**
- Produces: `enum ToolJSON { static func string(from object: Any, pretty: Bool) -> String? }`. It always uses `.withoutEscapingSlashes` and `.sortedKeys`, plus `.prettyPrinted` when `pretty`.

- [ ] **Step 1: Write failing tests**

```swift
func testSlashesAreNotEscaped() {
    XCTAssertEqual(ToolJSON.string(from: ["command": "cd /Users/a && ls"], pretty: false),
                   #"{"command":"cd /Users/a && ls"}"#)
}
func testClaudeBashInputHasNoEscapedSlash() throws {
    // Claude tool_use line with input {"command":"cat /etc/hosts"} parsed through ClaudeSessionParser
    let event = try XCTUnwrap(parseClaudeLine(#"{"type":"assistant","uuid":"u1","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"cat /etc/hosts"}}]}}"#).first)
    XCTAssertFalse(event.toolInput!.contains(#"\/"#))
}
func testCallLabelHasNoEscapedSlash() {
    // SessionTranscriptBuilder block text for a tool_call whose input has a path
    XCTAssertFalse(blockText(toolName: "Read", input: #"{"file_path":"/tmp/a.txt"}"#).contains(#"\/"#))
}
```

`parseClaudeLine` and `blockText` are small private helpers in the test file. `parseClaudeLine` writes the line to a temp `.jsonl` and calls `ClaudeSessionParser.parseFileFull(at:)` (see Global Constraints → Test seams). `blockText` calls `SessionTranscriptBuilder.coalescedBlocks` with a unique session id.

- [ ] **Step 2: Run** `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/ToolJSONTests`. Expected: FAIL (`ToolJSON` not defined).
- [ ] **Step 3: Implement `ToolJSON.string(from:pretty:)` and switch every listed site to it.** Keep each site's current pretty/compact choice.
- [ ] **Step 4: Run** `ToolJSONTests`, `TranscriptGoldenFixtureTests`, `ToolTextBlockNormalizerTests`, `ToolTextBlockNormalizerRegressionTests` and every `*SessionParserTests`. Expected: PASS, except golden, normalizer or `*SessionParserTests` expectations on `toolInput`/`toolOutput` that contain `\/` (for example `DevinSessionParserTests` `"path":"\\/tmp\\/a.png"`). Update those expectations, and only the `\/` → `/` difference. Any other diff is a bug. rawJSON expectations stay unchanged.
- [ ] **Step 5: Commit** `fix(transcript): stop escaping slashes in tool JSON`.

### Task 2: Readable call labels and summaries

**Files:**
- Create: `AgentSessions/ToolRendering/CodexExecScript.swift` (group `AgentSessions/ToolRendering`, new; the first file in a new group adds the group lines too)
- Create: `AgentSessions/Model/ToolEventFields.swift` holding `ToolPayloadValue` (Task 4 and Task 5 extend this file)
- Modify: `AgentSessions/Services/SessionTranscriptBuilder.swift:740-748` (`renderToolCallLabel`), `AgentSessions/Services/TranscriptToolSummary.swift`
- Test: `AgentSessionsTests/CodexExecScriptTests.swift`, `AgentSessionsTests/TranscriptToolSummaryTests.swift` (extend)

**Interfaces:**
- Produces:

```swift
struct CodexExecScript: Equatable, Sendable {
    struct Call: Equatable, Sendable {
        var tool: String                      // "exec_command", "apply_patch", "write_stdin", "mcp__node_repl__js", "web__run", …
        var arguments: [String: ToolPayloadValue]
        var sourceRange: Range<String.Index>  // span of `tools.<name>({…})` in the script
    }
    var calls: [Call]
    static func parse(_ source: String) -> CodexExecScript?   // nil when no `tools.<name>(` call is found
}
```

`ToolPayloadValue` (in `ToolEventFields.swift`):

```swift
indirect enum ToolPayloadValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), null
    case array([ToolPayloadValue]), object([String: ToolPayloadValue])
    init?(jsonObject: Any)                // from JSONSerialization output
    var stringValue: String? { get }
}
```

The parser reads JavaScript object literals: unquoted keys, JSON strings with `\"` escapes, single-quoted strings, template literals without `${}`, numbers, booleans, nested objects and arrays. `Promise.all([...])` and several `text(await tools.x({...}))` statements give several calls in source order. A value it cannot read (identifier, `${}` template, function call) is stored as `.string("<expr>")`, and the parse still succeeds.

- Primary-argument rule (used by the call label only): the first non-empty string among the keys `command`, `cmd`, `file_path`, `filePath`, `target_file`, `pattern`, `query`, `url`, `path`, `description` (`pattern` before `path`, so `Grep {pattern, path}` shows the pattern; ruling after the Task 2 review). An argv array (`command: ["bash","-lc","ls"]`) is joined after leading wrapper tokens are dropped (existing rule).
- `TranscriptToolSummary.summary` keeps its current key order (description before file path, spec §14 Q1) and its `lastPathComponent` rule, so `testDescriptionBeatsFilePath` and `testFilePathSummary` stay unchanged. It only gains: `cmd` where it reads `command`, and for `exec` the first call's `cmd`.

- [ ] **Step 1: Write failing tests**

```swift
func testSingleExecCommand() throws {
    let s = try XCTUnwrap(CodexExecScript.parse(#"text(await tools.exec_command({cmd:"pwd; rg -n 'x' AgentSessions","max_output_tokens":2000}));"#))
    XCTAssertEqual(s.calls.map(\.tool), ["exec_command"])
    XCTAssertEqual(s.calls[0].arguments["cmd"], .string("pwd; rg -n 'x' AgentSessions"))
}
func testTwoStatementsInSourceOrder() throws {
    let s = try XCTUnwrap(CodexExecScript.parse(#"text(await tools.exec_command({cmd:"a"}));text(await tools.exec_command({cmd:"b \"q\""}));"#))
    XCTAssertEqual(s.calls.map { $0.arguments["cmd"] }, [.string("a"), .string(#"b "q""#)])
}
func testPromiseAllWithWorkdir() throws {
    let src = "const r = await Promise.all([\n tools.exec_command({cmd:\"npm cache clean\",\"workdir\":\"/x\"}),\n tools.exec_command({cmd:\"brew cleanup\"})\n]);"
    XCTAssertEqual(try XCTUnwrap(CodexExecScript.parse(src)).calls.count, 2)
}
func testScriptWithoutToolsReturnsNil() { XCTAssertNil(CodexExecScript.parse("text('hi')")) }
func testUnreadableValueKeepsParse() throws {
    let s = try XCTUnwrap(CodexExecScript.parse("tools.exec_command({cmd: `ls ${dir}`})"))
    XCTAssertEqual(s.calls.count, 1)
}
// TranscriptToolSummaryTests additions
func testCodexExecCommandUsesCmd() { XCTAssertEqual(TranscriptToolSummary.summary(toolName: "exec_command", toolInput: #"{"cmd":"git status","workdir":"/x"}"#), "git status") }
func testCodexExecScriptUsesFirstCommand() { XCTAssertEqual(TranscriptToolSummary.summary(toolName: "exec", toolInput: #"text(await tools.exec_command({cmd:"pwd; rg x"}));"#), "pwd; rg x") }
func testCallLabelShowsPrimaryArgumentFirst() {
    // block text for a Claude Bash call: description must not hide the command
    XCTAssertEqual(blockText(toolName: "Bash", input: #"{"description":"List","command":"ls -la"}"#), "Bash ls -la")
}
```

- [ ] **Step 2: Run** `CodexExecScriptTests` and `TranscriptToolSummaryTests`. Expected: FAIL.
- [ ] **Step 3: Implement `CodexExecScript.parse`.** Change `renderToolCallLabel` to `name + " " + primaryArgument` (newlines collapsed to spaces, cut at 120 + "…"). When there is no primary argument, the label keeps today's compact JSON. For `exec` with a parsable script, the label is `exec ` + the first call's `cmd`. In `TranscriptToolSummary.summary`, read `cmd` like `command`, and use the first `cmd` for `exec` (existing order otherwise). Decision (spec §11 P0 row updated): the label carries only the primary argument; other keys (`workdir`, `timeout`, …) leave the label. They were already lost to the 120-char compact-JSON cut, and P1 shows them in L2.
- [ ] **Step 4: Run** both classes and `TranscriptBuilderTests`. Expected: PASS.
- [ ] **Step 5: Commit** `fix(transcript): label tool calls by their command or path`.

### Task 3: Group count, Codex namespace and web search label

**Files:**
- Modify: `AgentSessions/Model/SessionEvent.swift` (add `toolNamespace`), `AgentSessions/Services/SessionTranscriptBuilder.swift` (`LogicalBlock.toolNamespace`, `block(from:)`), `AgentSessions/Services/SessionIndexer.swift:~3168-3200` (Codex field parse), `AgentSessions/Services/TranscriptToolSummary.swift`, `AgentSessions/Views/TranscriptBlockListView.swift:~3788-3795` (`configureToolCard` header text)
- Test: `AgentSessionsTests/TranscriptToolSummaryTests.swift`, `AgentSessionsTests/SessionParserTests.swift` (extend)

**Interfaces:**
- Produces: `SessionEvent.toolNamespace: String?` and `LogicalBlock.toolNamespace: String?`. Both are `var` with default `nil`, so every existing initializer call compiles unchanged.
- Produces: `TranscriptToolSummary.displayToolName(name: String?, namespace: String?) -> String?`, which returns `"server › tool"`. The server is the namespace with any `mcp__` prefix and trailing `__` removed, and `::` / `__` separators become ` › `.
- Produces: `TranscriptToolSummary.callCount(in blocks: [LogicalBlock]) -> Int` = count of `.toolCall` blocks, minimum 1.

- [ ] **Step 1: Write failing tests**

```swift
func testGroupHeaderCountsCallsNotBlocks() {
    let blocks = [call("a"), out("a"), call("b"), out("b")]
    XCTAssertEqual(TranscriptToolSummary.callCount(in: blocks), 2)
}
func testOrphanOutputGroupCountsOne() { XCTAssertEqual(TranscriptToolSummary.callCount(in: [out("x"), out("y")]), 1) }
func testNamespaceDisplay() {
    XCTAssertEqual(TranscriptToolSummary.displayToolName(name: "js", namespace: "mcp__node_repl__"), "node_repl › js")
    XCTAssertEqual(TranscriptToolSummary.displayToolName(name: "send_message", namespace: "collaboration"), "collaboration › send_message")
}
func testCodexWebSearchCallGetsQuery() throws {
    let line = #"{"timestamp":"2026-06-01T00:00:00Z","type":"response_item","payload":{"type":"web_search_call","status":"completed","action":{"type":"search","query":"swift textkit"}}}"#
    let e = try XCTUnwrap(parseCodexLine(line))
    XCTAssertEqual(e.toolName, "web_search")
    XCTAssertEqual(TranscriptToolSummary.summary(toolName: e.toolName, toolInput: e.toolInput), "swift textkit")
}
func testCodexNamespaceIsKept() throws {
    let line = #"{"type":"response_item","payload":{"type":"function_call","namespace":"mcp__node_repl__","name":"js","arguments":"{\"code\":\"1\"}","call_id":"c1"}}"#
    XCTAssertEqual(try XCTUnwrap(parseCodexLine(line)).toolNamespace, "mcp__node_repl__")
}
```

- [ ] **Step 2: Run** the two classes. Expected: FAIL.
- [ ] **Step 3: Implement.**
  - Indexer: read `namespace` into `toolNamespace`. For `web_search_call`:
    - `toolName = "web_search"`;
    - `toolInput = ToolJSON` of `{query}`, or `{queries}`, or `{url}` for `open_page` / `find_in_page`, taken from `action`.
  - `configureToolCard`: the group title uses `callCount(in:)`. The single-call header passes `displayToolName` as the tool name.
- [ ] **Step 4: Run** the two classes, `TranscriptBuilderTests` and `TranscriptBlockWindowingTests`. Expected: PASS.
- [ ] **Step 5: Commit** `fix(transcript): count calls, keep MCP namespace, label web searches`.

### Task 4: Codex content-item outputs as text, and outputs that never merge across calls

**Files:**
- Modify: `AgentSessions/Utilities/ToolJSON.swift` (add `joinedContentItemText`)
- Modify: `AgentSessions/Model/SessionEvent.swift` (add `toolCallID`), `AgentSessions/Services/SessionTranscriptBuilder.swift` (`LogicalBlock.toolCallID`, `block(from:)`, `canMerge`, and the merge branch keeps the first block's `toolCallID`), `AgentSessions/Services/SessionIndexer.swift` (Codex `call_id`, output joining)
- Test: `AgentSessionsTests/ToolEventFieldsTests.swift`

**Interfaces:**
- Produces: `SessionEvent.toolCallID: String?` and `LogicalBlock.toolCallID: String?` (`var`, default `nil`).
- Produces: `static func joinedContentItemText(_ value: Any) -> String?` on `ToolJSON`. For an array whose elements are all `{type: text|input_text|output_text, text}` or `{type: input_image|image, …}`, it joins the text parts with no separator, and each image becomes the line `[image]`. Any other shape returns nil.

- [ ] **Step 1: Write failing tests**

```swift
func testCodexContentItemOutputBecomesText() throws {
    let line = #"{"type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"c1","output":[{"type":"input_text","text":"Script completed\nWall time 0.4 seconds\nOutput:\n"},{"type":"input_text","text":"hello\n"}]}}"#
    let e = try XCTUnwrap(parseCodexLine(line))
    XCTAssertEqual(e.toolOutput, "Script completed\nWall time 0.4 seconds\nOutput:\nhello\n")
    XCTAssertEqual(e.toolCallID, "c1")
}
func testOutputsWithDifferentCallIDsNeverMerge() {
    let a = resultEvent(id: "r1", output: "one", messageID: "m", callID: "t1")
    let b = resultEvent(id: "r2", output: "two", messageID: "m", callID: "t2")
    let blocks = SessionTranscriptBuilder.coalescedBlocks(for: session([a, b]), includeMeta: false)
    XCTAssertEqual(blocks.map(\.text), ["one", "two"])
}
func testDeltaOutputsOfOneCallStillMerge() {
    // messageID nil so canMerge reaches its isDelta branch (equal messageIDs return early)
    let a = resultEvent(id: "r1", output: "on", messageID: nil, callID: "t1", isDelta: true)
    let b = resultEvent(id: "r2", output: "e", messageID: nil, callID: "t1", isDelta: true)
    XCTAssertEqual(SessionTranscriptBuilder.coalescedBlocks(for: session([a, b]), includeMeta: false).map(\.text), ["one"])
}
```

- [ ] **Step 2: Run** `ToolEventFieldsTests`. Expected: FAIL.
- [ ] **Step 3: Implement.**
  - Indexer: `toolCallID` = payload `call_id`. When `output` is a content-item array, `toolOutput` = `joinedContentItemText` (instead of pretty JSON).
  - `canMerge`: return false when both blocks have a non-nil `toolCallID` and the ids differ.
- [ ] **Step 4: Run** the full suite (`./scripts/xcode_test_stable.sh`). Expected: 0 failures; executed count = 3942 + the new tests of Tasks 1–4.
- [ ] **Step 5: Docs (agents.md "User-visible changes").** Add P0 bullets under `[Unreleased]` in `docs/CHANGELOG.md` and a note in `docs/summaries/2026-11.md` (create it in that folder's existing format if missing): slashes no longer escaped, calls labelled by command or path, the group counts calls, MCP server names and web-search queries shown, Codex outputs shown as text, parallel outputs no longer fused.
- [ ] **Step 6: Commit** `fix(transcript): show Codex content items as text; never merge outputs of different calls`.

**P0 exit check:** open the screenshot's session (`~/.codex/sessions/2026/11/04/rollout-2026-11-04T11-32-12-01a1a80c-…jsonl`) in a Debug build:
- The group says "6 tool calls".
- Call lines read `exec pwd; rg -n …`.
- Outputs show real line breaks, and no `\/` appears.

The owner runs it (owner QA rule). P0 can ship as a point release.

---

# P1 — invocation model and three-level UI

### Task 5: Parser fields for every source

**Files:**
- Modify: `AgentSessions/Model/ToolEventFields.swift` (add `ToolSidecar`, `ToolDisposition`), `AgentSessions/Model/SessionEvent.swift` (add `toolOutputValue`, `toolSidecar`, `toolDisposition`), `AgentSessions/Services/SessionTranscriptBuilder.swift` (`LogicalBlock` copies them; merge keeps the first non-nil), and the 17 parsers listed below.
- Test: `AgentSessionsTests/ToolEventFieldsParserTests.swift` (one test per source, with inline lines or small temp files modelled on each source's `*SessionParserTests`; only Codex and DeepSeek Harness have `stage0/agents/` fixtures. The four sidecar tests write their lines from the spec §7.3 shapes, because no fixture has those keys yet.)

**Interfaces:**
- Produces:

```swift
struct ToolSidecar: Codable, Equatable, Sendable {   // P1 fields only; P2/P3 add diff, persisted-output, subagent stats, image refs
    var stdout: String?, stderr: String?
    var exitCode: Int?, isError: Bool?, interrupted: Bool?
    var agentLabel: String?               // Antigravity toolSummary (decoded once), OpenCode state.title, Copilot toolTitle, Kimi display summary
}
enum ToolDisposition: String, Codable, Sendable { case runtimeError, rejected }
// SessionEvent / LogicalBlock (all `var`, default nil):
var toolOutputValue: ToolPayloadValue?   // set only when the original output is an array/object and ≤ 256 KB serialized
var toolSidecar: ToolSidecar?
var toolDisposition: ToolDisposition?
```

- Per-source `toolCallID` sources (call and result events both carry it):

| Source | Call id field | Notes |
|---|---|---|
| Codex (`SessionIndexer`) | `call_id` | done in Task 4 for outputs; add to calls; the >5 MB stub keeps `call_id` (`SessionIndexer.swift:3373`) |
| Claude | `tool_use.id` / `tool_result.tool_use_id` | sidecar from `toolUseResult`: stdout, stderr, interrupted, isError; `toolDisposition` from the existing disposition switch (kinds unchanged in P1) |
| OpenCode (+ v2 adapter) | `callID` | sidecar exitCode = `state.metadata.exit`, agentLabel = `state.title` |
| Hermes | `tool_call_id` | — |
| Copilot | `toolCallId` | sidecar exitCode = `shellExecution.exitCode`, agentLabel = `toolTitle` |
| Droid | `tool_use_id` / `toolCallId` | sidecar isError = `is_error` |
| OpenClaw | `toolCallId` | — |
| Cursor | none | leave nil (results never recorded) |
| Pi | `toolCallId` | sidecar exitCode from `bashExecution.exitCode` |
| Kimi | `toolCallId` | agentLabel from `display` |
| Grok | `tool_call_id` | — |
| Qwen | `functionCall.id` / `functionResponse.id` | — |
| Devin | `tool_call_id` | — |
| fx | `tool_call_id` | sidecar exitCode = `command_process_presentation.exit_code` |
| Cline | `tool_use_id` | — |
| DSH | `callId` | — |
| Antigravity | synthesized `"ag:<step_index>:<k>"` | the k-th tool call of a planner step; the result takes the same id through the existing position queue (`pendingToolNames` in `AntigravityTranscriptParser.swift`); agentLabel = `toolSummary` after one JSON-string decode |

- [ ] **Step 1: Write one failing test per source** that parses a fixture or inline line with one call and its result, then asserts `call.toolCallID == result.toolCallID != nil`. Cursor is the exception: its test asserts nil. Add these sidecar tests:

```swift
func testClaudeBashSidecarSplitsStdoutStderr() // toolUseResult {stdout:"a", stderr:"b"} → sidecar.stdout == "a", .stderr == "b"
func testClaudeRejectionRecordsDisposition()   // tool_result with "is_error":true and content "The user doesn't want to proceed with this tool use. …" → toolDisposition == .rejected, kind still .meta
func testClaudeRuntimeErrorKeepsCallID()       // tool_result "is_error":true, content "Error: boom" → toolDisposition == .runtimeError, toolCallID == the tool_use_id
func testOpenCodeBashSidecarHasExitAndTitle()  // state.metadata.exit 2, state.title "List files" → sidecar.exitCode == 2, .agentLabel == "List files"
func testAntigravityToolSummaryDecodedOnce()   // args.toolSummary "\"Run date command\"" → agentLabel "Run date command"
func testCodexOutputValueKeptForArrays()       // content-item array → toolOutputValue is .array; plain string output → toolOutputValue nil
func testLargeOutputValueDropped()             // 300 KB array → toolOutputValue nil, toolOutput still set
```

- [ ] **Step 2: Run** `ToolEventFieldsParserTests`. Expected: FAIL.
- [ ] **Step 3: Implement per parser.** Keep every existing field value byte-identical. Only the new fields are added.
- [ ] **Step 4: Run** `ToolEventFieldsParserTests` and all `*SessionParserTests`, `TranscriptGoldenFixtureTests` and `Stage0PerfHarnessTests`. Expected: PASS with no golden change.
- [ ] **Step 5: Commit** `feat(parsers): record tool call ids, output values and sidecars for all sources`.

### Task 6: Pairing and the cheap status probe

**Files:**
- Create: `AgentSessions/ToolRendering/ToolInvocationPairing.swift`, `AgentSessions/ToolRendering/ToolStatusProbe.swift`
- Modify: `AgentSessions/Services/TranscriptTurnTiming.swift` (tool durations use pairing), `AgentSessions/Services/TranscriptDerivedState.swift` (`Snapshot` gains the index; `errorBlockIndices` stays block-based, and `failedInvocationIDs` is added), `AgentSessions/Views/TranscriptPlainView.swift` (the representable passes the snapshot's index and failed ids to the controller, next to `snapshot.blocks`, ~:857), `AgentSessions/Views/TranscriptBlockListView.swift` (`BlockTableController.apply(...)` gains `invocationIndex: ToolInvocationIndex = .empty` and `failedInvocationIDs: Set<Int> = []`, stored next to `allBlocksCache`; the timing call at ~:1339 passes the stored index)
- Test: `AgentSessionsTests/ToolInvocationPairingTests.swift`, `AgentSessionsTests/ToolStatusProbeTests.swift`, `AgentSessionsTests/TranscriptTurnTimingTests.swift` (extend; rewrite `testNestedToolPairsMatchLIFONearestPrecedingUnmatched`, see Pairing order)

**Interfaces:**
- Produces:

```swift
enum ToolStatus: Equatable, Sendable {
    case success, failed(exitCode: Int?), rejected, interrupted, noResult, pending, unknown
}
struct ToolInvocationRef: Equatable, Sendable {
    var id: Int                         // call block's globalBlockIndex, or the first output's when there is no call
    var callBlockIndex: Int?
    var outputBlockIndices: [Int]
    var status: ToolStatus
}
struct ToolInvocationIndex: Sendable {
    var invocations: [ToolInvocationRef]            // in id order
    var invocationIDByBlock: [Int: Int]             // every tool block → its invocation id
    var processOwnerBySessionID: [String: Int]      // "Process running with session ID N" / "Script running with cell ID N" → invocation id (substring scan)
    static let empty = ToolInvocationIndex(invocations: [], invocationIDByBlock: [:], processOwnerBySessionID: [:])
    static func build(blocks: [SessionTranscriptBuilder.LogicalBlock], source: SessionSource) -> ToolInvocationIndex
}
// TranscriptTurnTiming: compute(blocks:index:) is the real entry; compute(blocks:) stays as a wrapper that builds the index itself (source .codex), so existing callers and tests compile.
enum ToolStatusProbe {
    static func status(call: SessionTranscriptBuilder.LogicalBlock?, outputs: [SessionTranscriptBuilder.LogicalBlock],
                       source: SessionSource, laterBlocksExist: Bool, turnAbortedAfter: Bool) -> ToolStatus
}
// TranscriptDerivedState.Snapshot (defaults keep `Snapshot()` compiling):
var invocationIndex: ToolInvocationIndex = .empty
var failedInvocationIDs: Set<Int> = []
```

- Tool blocks for pairing: `.toolCall`, `.toolOut`, and `.error` blocks that carry a `toolCallID` (Claude runtime errors after Task 5). Such an `.error` block is an output of its call, and the invocation's status is failed (spec §7.4: a runtime error stays a tool output).
- Pairing order:
  1. Pair by equal `toolCallID`.
  2. For blocks without ids, pair FIFO within the same turn: a turn is a user block plus everything up to the next user block (spec §6.2; parallel calls are far more common than nested ones).
  3. Then use the stack match only for what remains (an output with no unmatched call in its own turn takes the nearest preceding unmatched call).
- The existing `testNestedToolPairsMatchLIFONearestPrecedingUnmatched` fixture (one turn, `call call out out`, no ids) is the parallel shape. Rename it `testIDlessCallsInOneTurnPairFIFO` and change its expected durations to the FIFO pairing (out1↔call1, out2↔call2). Update the LIFO wording in `TranscriptTurnTiming.swift`'s header comment.
- Status rules come from spec §6.2 and §9:
  - Exit code first, from the sidecar or from the output's first-line forms: `Exit code N`, `Process exited with code N`, `exit: N`, `Command exited with code N.`, `Error: Command failed (exit code: N)`, `<exit_code>N</exit_code>`.
  - Codex code mode is failed when it has `"exit_code":` with a value other than 0, or a `Script failed` header. Use a substring scan only.
  - Then `isErrorOutput` or `toolDisposition`.
  - grep-family exit 1 with an empty output is `.success`.
  - No output: `interrupted` when a `turn_aborted` user notice follows in the same turn. Otherwise `pending` when it is the session's last turn, or `noResult`. Cursor gives `unknown`.

- [ ] **Step 1: Write failing tests**

```swift
func testParallelCallsPairByID()          // c1 c2 c3 o1 o2 o3 (ids t1..t3) → o1↔c1, o2↔c2, o3↔c3
func testParallelCallsWithoutIDsPairFIFOInTurn() // same shape, ids nil → FIFO
func testOutputWithoutCallInItsTurnFallsBackToStack() // turn 1: c1 · turn 2: c2 o2 o1 (no ids) → o2↔c2 (FIFO in turn 2), o1↔c1 (stack)
func testRuntimeErrorBlockPairsAsFailedOutput()  // c1 (id t1) + .error block (toolCallID t1) → one invocation, status .failed
func testOrphanOutputBecomesOwnInvocation()      // o1 with no call → ref.callBlockIndex == nil, id == o1 index
func testCallWithoutOutputAtSessionEndIsPending()
func testInterruptedByTurnAbortedNotice()
func testCursorCallStatusIsUnknown()
func testCodexExecChunkExitCodeFails()     // output contains {"chunk_id":"a","exit_code":2,...} → .failed(exitCode: 2)
func testRgExitOneEmptyIsSuccess()         // call cmd "rg foo", output "Process exited with code 1\nOutput:\n" → .success
func testToolDurationUsesPairing()         // TranscriptTurnTimingTests: c1 c2 o1 o2 with ids → durations match by id
```

- [ ] **Step 2: Run** the three classes. Expected: FAIL.
- [ ] **Step 3: Implement.** Build the index inside `TranscriptDerivedState.computeSnapshot`, which already runs off the main actor. `TranscriptTurnTiming.compute(blocks:index:)` uses the index instead of its own stack. Thread the index and failed ids from the snapshot through `TranscriptPlainView` into `BlockTableController.apply`.
- [ ] **Step 4: Run** the three classes, plus `TranscriptDerivedStateTests` and `Stage0PerfHarnessTests`. Expected: PASS. The Stage0 snapshot time grows by at most 5%.
- [ ] **Step 5: Commit** `feat(transcript): pair tool calls by id and probe status`.

### Task 7: Decoders and envelopes

**Files:**
- Create: `AgentSessions/ToolRendering/ToolTextDecoding.swift`, `AgentSessions/ToolRendering/ToolEnvelopes.swift`
- Test: `AgentSessionsTests/ToolTextDecodingTests.swift`, `AgentSessionsTests/ToolEnvelopesTests.swift`

**Interfaces:**
- Produces:

```swift
struct SourceMapEntry: Equatable, Sendable { var rendered: NSRange; var source: NSRange }   // UTF-16
enum TextShape: Equatable, Sendable { case plain, lineNumbered(gutter: [Int?]), jsonLines, json, markdown, image, binary(bytes: Int) }
struct DecodedText: Equatable, Sendable {
    var text: String
    var sourceMap: [SourceMapEntry]      // monotone
    var shape: TextShape
}
enum ToolTextDecoding {
    static func decode(value: ToolPayloadValue?, fallback: String?) -> DecodedText   // pipeline steps 2–4, 6–7 of spec §6.4
    static func normalize(_ s: String) -> String          // CRLF→LF, strip ANSI CSI/OSC, trim trailing blank lines (tabs stay; budgets and panes use 4-column stops)
    static func decodeJSONString(_ s: String, maxDepth: Int) -> ToolPayloadValue?   // whole-string only, depth ≤ 3
    static func stripLineNumbers(_ s: String) -> (text: String, gutter: [Int?])?    // forms: "  N→", "N\t", "N:", "N|", "N | "
}
struct AgentFact: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case exitCode(Int), wallTime(Double), truncated(agent: String, originalTokens: Int?, totalLines: Int?), note(String), persisted(path: String, bytes: Int?) }
    var kind: Kind
}
enum ToolEnvelopes {
    static func lift(_ text: String, source: SessionSource, toolName: String?) -> (body: String, facts: [AgentFact], hiddenNotes: [String])
}
```

- Envelope rules in P1 cover Codex, Claude and three generic forms. Each rule is anchored at the start or the end of the output, never the middle:
  - **Codex:**
    - the `Chunk ID / Wall time / Process exited with code N / Original token count / Output:` header;
    - `Exit code: N / Wall time: X seconds / Output:`;
    - the `Script completed|failed|running with cell ID N / Wall time X seconds / Output:` item;
    - `Warning: truncated output (original token count: N)\nTotal output lines: N\n\n`, which can repeat;
    - `Wall time: X seconds\nOutput:` (MCP);
    - `aborted by user after Ns`.
  - **Claude:**
    - a leading `Exit code N\n`;
    - a trailing `Shell cwd was reset to …`;
    - trailing `<system-reminder>…</system-reminder>` blocks, which become `hiddenNotes`;
    - `<persisted-output>` with its "Output too large (S). Full output saved to: P" header, which becomes the `persisted` fact with the preview as the body;
    - `[Truncated: PARTIAL view …]`.
  - **Generic:** `[Process exited with code N]`, `<shellId: N completed with exit code N>`, `Exit Code: N` (OpenCode's appended line).

- [ ] **Step 1: Write failing tests**

```swift
func testContentItemsJoined()                 // .array of input_text items → text joined, shape .plain
func testJSONStringDecodedOnce()              // "\"a\\nb\"" → "a\nb"
func testWholeStringJSONPrettyPrinted()       // "{\"a\":1}" → shape .json, text pretty with no "\/"
func testJSONInsideProseStaysText()           // "result: {\"a\":1}" → .plain unchanged
func testJSONLinesDetected()                  // two lines of objects with same keys → .jsonLines
func testANSIStrippedAndCRLFNormalized()
func testLineNumberFormsAllDetected()         // one test per form listed above → gutter values and stripped text
func testSourceMapRoundTrips()                // every rendered range maps inside the source and is monotone
func testCodexChunkHeaderLifted()             // body excludes header; facts == [.exitCode(0), .wallTime(0.0)]
func testCodexDoubleTruncationBothLifted()
func testClaudeSystemReminderTailHidden()
func testClaudePersistedOutputFact()
func testEnvelopeWordsInMiddleAreKept()       // "x\nProcess exited with code 1\ny" in the middle is body text
func testBase64ImageItemBecomesImageShape()   // {type:"input_image", image_url:"data:image/png;base64,…"} → shape .image, text "[image]", no base64 in text
func testBinaryTextObjectBecomesPlaceholder()  // {"encoding":"base64","data":"…12 KB…"} → shape .binary(bytes: 12288), text "binary data (12 KB)"
```

- [ ] **Step 2: Run** both classes. Expected: FAIL.
- [ ] **Step 3: Implement** the pipeline per spec §6.4. A decode failure at any step returns the input unchanged (anti-goal A2). The content-item join reuses Task 4's rule (text parts joined with no separator, each image item → the line `[image]`) through one shared implementation; do not write a second copy of the join.
- [ ] **Step 4: Run** both classes. Expected: PASS.
- [ ] **Step 5: Commit** `feat(transcript): tool output decoders and envelope facts`.

### Task 8: Codex code-mode output mapping

**Files:**
- Create: `AgentSessions/ToolRendering/CodexExecOutput.swift`
- Test: `AgentSessionsTests/CodexExecOutputTests.swift`

**Interfaces:**
- Consumes: `CodexExecScript` (Task 2), `ToolEnvelopes` (Task 7)
- Produces:

```swift
struct CodexExecOutput: Equatable, Sendable {
    enum ScriptStatus: Equatable, Sendable { case completed, failed, running(cellID: String), aborted(seconds: Double) }
    struct Chunk: Equatable, Sendable { var exitCode: Int?; var wallTimeSeconds: Double?; var originalTokenCount: Int?; var output: DecodedText; var facts: [AgentFact] }
    var status: ScriptStatus?
    var wallTimeSeconds: Double?
    var chunks: [Chunk]                 // JSON-line records in order
    var looseText: DecodedText?         // items that are not chunks (custom text(...) output)
    var facts: [AgentFact]
    static func parse(value: ToolPayloadValue?, fallback: String?) -> CodexExecOutput
    /// chunk i belongs to call i only when chunks.count == script.calls.count and every call is exec_command or write_stdin
    static func assign(_ output: CodexExecOutput, to script: CodexExecScript) -> [Int: Chunk]
}
```

- [ ] **Step 1: Write failing tests**

```swift
func testTwoCommandsTwoChunks()                       // the screenshot shape → assign maps 0→chunk0 (exit 1), 1→chunk1
func testChunkInnerTruncationLifted()                 // chunk output starting "Warning: truncated output…Total output lines: 842" → fact, body starts at line 1
func testPromiseAllWithCustomPrintingDoesNotAssignChunks() // script with 3 calls + text(`---${i}---`) output → assign == [:], looseText non-nil
func testRunningScript()                              // plain string "Script running with cell ID 7\nWall time 11.0 seconds\nOutput:\n" → .running("7")
func testAbortedScript()                              // "aborted by user after 20.4s" → .aborted(20.4)
func testJSONEncodedStringItemUnescaped()             // item text starting with "\"" → unescaped once
```

- [ ] **Step 2: Run** `CodexExecOutputTests`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(transcript): map Codex code-mode output to its commands`.

### Task 9: Invocation builder (categories, actions, labels, plain text)

**Files:**
- Create: `AgentSessions/ToolRendering/ToolCategory.swift`, `AgentSessions/ToolRendering/ToolInvocation.swift`, `AgentSessions/ToolRendering/ToolInvocationBuilder.swift`
- Test: `AgentSessionsTests/ToolCategoryTests.swift`, `AgentSessionsTests/ToolInvocationBuilderTests.swift`

**Interfaces:**
- Consumes: `ToolInvocationRef` (Task 6), `ToolTextDecoding`, `ToolEnvelopes` (Task 7), `CodexExecScript` (Task 2), `CodexExecOutput` (Task 8)
- Produces:

```swift
enum ToolCategory: String, Sendable, CaseIterable { case shell, read, write, edit, search, list, web, plan, subagent, ask, image, structured }
enum ToolCategoryMap {
    static func category(source: SessionSource, toolName: String?, namespace: String?) -> ToolCategory   // spec §7.2 table, as data
    static func symbolName(_ c: ToolCategory) -> String          // spec §6.6 SF Symbols
}
struct ToolContextItem: Equatable, Sendable { var key: String; var value: String }   // keys: "cwd", "shell", "timeout", "script"
struct ToolField: Equatable, Sendable { var key: String; var value: ToolPayloadValue }
struct ToolAction: Equatable, Sendable {
    var category: ToolCategory
    var verbKey: String                  // xcstrings key: "tool.verb.ran", "tool.verb.read", … (P1 uses ran/polled/sentInput/ranScript + the category default verb)
    var object: String                   // single line
    var objectIsAgentLabel: Bool         // spec §14 Q1: system font when true
    var objectDetail: String?
    var context: [ToolContextItem]
    var command: String?                 // exact command text for shell actions (never rewritten); first line only when a heredoc is split off
    var heredoc: DecodedText?            // body of `<<'EOF'` / `<<EOF` / `<<-EOF`, shown as its own pane with a gutter
    var inputFields: [ToolField]         // generic renderer; ordered: primary-argument keys first, then alphabetical
    var output: DecodedText?
    var facts: [AgentFact]
    var hiddenNotes: [String]
    var status: ToolStatus
    var plainText: String                // spec §8 form
}
struct ToolInvocation: Equatable, Sendable {
    var ref: ToolInvocationRef
    var displayToolName: String
    var actions: [ToolAction]            // ≥ 1
    var scriptSource: String?            // Codex exec JS, for "Show script"
    var durationSeconds: Double?
}
enum ToolInvocationBuilder {
    static func build(_ ref: ToolInvocationRef, blocks: [SessionTranscriptBuilder.LogicalBlock],
                      index: ToolInvocationIndex, source: SessionSource, duration: Double?) -> ToolInvocation
    static func rowSummary(_ ref: ToolInvocationRef, blocks: [SessionTranscriptBuilder.LogicalBlock],
                           index: ToolInvocationIndex, source: SessionSource) -> ToolRowSummary   // L1 only; must not decode output bodies
    // `blocks` is always the full session block array (globalBlockIndex == position), never a window slice.
}
struct ToolRowAction: Equatable, Sendable { var category: ToolCategory; var verbKey: String; var object: String; var objectIsAgentLabel: Bool; var objectDetail: String? }
struct ToolRowSummary: Equatable, Sendable {
    var actions: [ToolRowAction]
    var chips: [String]   // pre-formatted: "exit 65", "412 lines", "no output", "cut by Codex", "error"
}
```

- Rules:
  - **Shell actions.** Wrappers `bash|sh|zsh -lc|-c` and a leading `cd X &&` / `cd X;` move to the context. `workdir` gives cwd. The command text is otherwise verbatim.
  - **Q1 precedence for the object.** `description` input key, then `sidecar.agentLabel`, then the command.
  - **Codex `exec` with a parsed script.**
    - Each call becomes an action:
      - `exec_command` → shell;
      - `write_stdin` with empty `chars` → verbKey "tool.verb.polled", and with chars → "tool.verb.sentInput";
      - `apply_patch` → edit, with the generic renderer in P1;
      - anything else → structured.
    - Context gets "exec script · command i of n" when n > 1. Chunks attach per `CodexExecOutput.assign`.
    - No parsed script → one action, verbKey "tool.verb.ranScript", with the script as `command`.
  - **Every other tool** gets one action. The category comes from the map. In P1, non-shell categories use the generic renderer, but keep their own verb and icon.
  - **`plainText`.** `$ <command>` (or `<verb> <object>`), then `[exit N · 1.2s]` when known, then the decoded output with folds open and no gutter. Actions are joined by a blank line.
  - **Ciphertext.** Any string value with prefix `gAAAAA` and length > 40 renders as `message encrypted in the log (N chars)` everywhere: object, fields, `plainText`.

- [ ] **Step 1: Write failing tests**

```swift
func testCategoryMapCoversSurveyNames()        // every bold name in spec §7.2 maps to its row's category
func testUnknownNameIsStructured()
func testClaudeBashUsesDescriptionAsObject()   // input {command:"ls", description:"List files"} → object "List files", objectIsAgentLabel, command "ls"
func testCodexExecCommandObjectIsCommand()     // no description → object "git status", objectIsAgentLabel false
func testWrapperLiftedToContext()              // command ["bash","-lc","cd /x && make"] → command "make", context cwd "/x", shell "bash -lc"
func testCodexScriptFlattensToTwoActions()     // screenshot shape → 2 shell actions, contexts "exec script · command 1 of 2"
func testScriptParseFailureIsRanScript()
func testPollVerb()                            // write_stdin chars "" → verbKey "tool.verb.polled"
func testPollObjectResolvesOriginatingCommand() // session 42437 started by "npm run dev" → poll object "npm run dev", objectDetail "session 42437"
func testHeredocSplitsBody()                   // "cat > f.sh <<'EOF'\n#!/bin/zsh\nls\nEOF" → command "cat > f.sh <<'EOF'", heredoc.text "#!/bin/zsh\nls", verbKey "tool.verb.ran"
func testCiphertextNeverAppears()              // collaboration send_message {message:"gAAAAA…"} → plainText lacks "gAAAAA"
func testPlainTextForm()                       // == "$ make\n[exit 2 · 1.2s]\nboom"
func testRowSummaryDoesNotDecodeOutput()       // rowSummary on a block whose output is 2 MB completes < 5 ms (measure)
```

- [ ] **Step 2: Run** both classes. Expected: FAIL.
- [ ] **Step 3: Implement.** Add each `tool.verb.*` and chip string to `Localizable.xcstrings`: Ran, Polled, Sent input, Ran script, Read, Created, Edited, Searched, Listed, Fetched, Searched the web, Updated plan, Subagent, Asked, Screenshot, Output. Chips: "exit %d", "error", "%d lines", "no output", "no matches", "cut by %@", "rejected by you", "interrupted", "no result recorded", "no result yet". Polls resolve their object through `ToolInvocationIndex.processOwnerBySessionID` (the poll's `session_id` argument → owner invocation → its command). When the owner is a parsed exec script, use the command of the chunk whose output contains that session id, else the script's first command.
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(transcript): tool invocation model with shell and generic adapters`.

### Task 10: Size budgets

**Files:**
- Create: `AgentSessions/ToolRendering/ToolTextBudget.swift`
- Test: `AgentSessionsTests/ToolTextBudgetTests.swift`

**Interfaces:**
- Produces:

```swift
struct FoldState: Equatable, Sendable { var extraLinesShown: Int = 0; var showAll = false; var openedLongLines: Set<Int> = []; var commandShowAll = false }
struct FoldedText: Equatable, Sendable {
    enum Segment: Equatable, Sendable { case lines(Range<Int>), fold(hiddenLines: Int), longLineCut(line: Int, hiddenChars: Int) }
    var segments: [Segment]
    var hitShowAllCap: Bool
}
enum ToolTextBudget {
    static let headLines = 12, tailLines = 4, errorTailLines = 18, longLineVisualLines = 4
    static let showMoreStep = 500, showAllLineCap = 20_000, showAllByteCap = 2 * 1024 * 1024
    static let commandLines = 12                                       // command input / heredoc pane budget (spec §6.5)
    static func columns(width: CGFloat, font: NSFont) -> Int          // floor(width / advance of "0")
    static func visualWidth(of line: Substring) -> Int                 // East Asian Wide/Fullwidth and emoji count 2; a tab advances to the next multiple of 4
    static func fold(_ text: String, columns: Int, isError: Bool, state: FoldState) -> FoldedText
    static func foldCommand(_ text: String, columns: Int, state: FoldState) -> FoldedText   // full up to 12 visual lines, else first 12 + fold (no tail); unfolded when state.commandShowAll
}
```

- A long line is cut to 4 visual lines first; the head/tail budget then counts the cut line as 4 visual lines (what is shown).

- [ ] **Step 1: Write failing tests**

```swift
func testShortTextUnfolded()
func testHeadAndTailFold()                    // 100 lines → lines 0..<12, fold(84), lines 96..<100
func testErrorShowsTail()                     // isError → fold first, last 18 lines visible
func testVisualLinesCountWrappedLines()       // 5 lines of 300 chars at 80 columns (4 visual lines each, 20 total) → lines(0..<3), fold(hiddenLines: 1), lines(4..<5)
func testTabAdvancesToFourColumnStop()        // "a\tb" → visualWidth 5
func testCommandFoldsAfterTwelveVisualLines() // 20-line command → lines(0..<12), fold(hiddenLines: 8); 12-line command unfolded
func testLongLineCut()                        // one 10,000-char line at 80 cols → longLineCut(line:0, hiddenChars: 10000-320)
func testWideCharactersCountTwoColumns()      // 100 CJK chars at 80 cols = 3 visual lines
func testShowMoreAdds500()
func testShowAllCapped()                      // 30,000 lines + showAll → hitShowAllCap, 20,000 lines shown
```

- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(transcript): visual-line budgets for tool output`.

### Task 11: L2 detail renderer

**Files:**
- Create: `AgentSessions/ToolRendering/ToolDetailRenderer.swift`
- Modify: `AgentSessions/Views/MarkdownBodyRenderer.swift:~880` — `private enum MarkdownStyle` becomes internal (drop `private`), so the renderer can use `MarkdownStyle.codeBlockBackground`. No other change there.
- Test: `AgentSessionsTests/ToolDetailRendererTests.swift`

**Interfaces:**
- Consumes: `ToolAction` (Task 9), `ToolTextBudget` (Task 10)
- Produces:

```swift
struct RenderedToolBody {
    var attributed: NSAttributedString
    var plainCopyText: String                   // what Copy returns for the visible state (no gutter)
    var sourceMap: [(rendered: NSRange, actionIndex: Int, source: NSRange)]   // into ToolAction.plainText
    var foldLinks: [(range: NSRange, action: ToolFoldLink)]
}
enum ToolFoldLink: Hashable { case showMore(action: Int), showAll(action: Int), openLongLine(action: Int, line: Int), showFullCommand(action: Int), showScript, copyOutput(action: Int) }
// showFullCommand sets FoldState.commandShowAll for that action (command and heredoc panes).
enum ToolDetailRenderer {
    static func render(_ invocation: ToolInvocation, fontSize: CGFloat, width: CGFloat,
                       folds: [Int: FoldState], appearance: NSAppearance) -> RenderedToolBody
}
```

- Layout, as one attributed string (spec §6.6–6.7):
  - **Context line:** system font 10.5 pt, tertiary.
  - **Command pane:** `$ ` prompt in tertiary; the command in SF Mono at fontSize − 0.5 with a 2-character hanging indent; pane fill = `MarkdownStyle.codeBlockBackground`.
  - **Output pane:** same fill. stderr uses `systemRed` text with a "stderr" section label.
  - **Fold rows:** system font 11 pt, secondary, with `.link` attributes using the `ToolFoldLink` payload, encoded as the string `"toolfold:<kind>:<action>:<line>"`.
  - **Footer facts line:** tertiary. A non-zero exit code is in `systemRed` semibold. Truncation facts are in `systemOrange`.
  - **Generic renderer:** an aligned `key  value` list. String values are unescaped. Nested objects and arrays print as compact one-line JSON, cut at 200 characters with "+N chars".
  - **Gutter (`.lineNumbered` shape):** drawn as right-aligned tertiary numbers in a tab-stopped first column. The numbers carry the attribute `.toolGutter = true`, and both `plainCopyText` and the selection-copy path skip them.

- [ ] **Step 1: Write failing tests**

```swift
func testCommandAndOutputPanes()        // string contains "$ make" and output text; command range has codeBlockBackground
func testFoldRowHasLink()               // 100-line output → one link with payload showAll(action: 0)
func testCopyTextExcludesGutter()       // line-numbered output → plainCopyText has no leading numbers
func testSourceMapCoversOutput()        // every output char's rendered range maps into plainText
func testFailedExitIsRed()              // footer "exit 2" foreground == systemRed
func testGenericFieldsListed()          // MCP input {owner:"a", draft:true} → "owner  a" and "draft  true" lines
func testHeredocPaneHasGutter()         // action.heredoc 14 lines → numbered pane, folded after 12 visual lines, terminator line after it
func testRenderIsFastForHugeOutput()    // 20,000-line output with showAll → render < 50 ms (measure, release config tolerance ×2 in Debug)
```

- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(transcript): render tool details as panes with fold links`.

### Task 12: Row emission (group headers + invocation rows)

**Files:**
- Create: `AgentSessions/ToolRendering/TranscriptToolRows.swift`
- Modify: `AgentSessions/Views/TranscriptBlockListView.swift` — **additive only** (Task 13 switches the live path, so every commit compiles and the app keeps today's tool cards until the new cells exist):
  - `BlockRowModel.Content` gains `.toolGroupHeader(ToolGroupHeaderModel)` and `.toolInvocation(ToolInvocationRowModel)`; `.toolGroup` stays for now;
  - exhaustive switches (`primaryBlock`, `bodyText`, `isToolCard`, `toolBlocks`, `tableView(_:viewFor:)`, `configure`) handle the new cases minimally (no production code emits them yet);
  - `ChangeKind` gains `case appendWithReload(count: Int, reloadRows: IndexSet)`; `classifyChange` returns it when the first `old.count` row ids of `new` equal `old`'s ids, every content-changed row in that prefix is a tool row (header or invocation), and at least one row changed. Any other change keeps today's result. The controller's apply path handles the new case: `insertRows` for the tail, `reloadData(forRowIndexes:)` + `noteHeightOfRows` for `reloadRows`, scroll anchor kept;
  - `rowsWithTelemetry` and `mergeToolRuns` are unchanged in this task.
- Test: `AgentSessionsTests/TranscriptToolRowsTests.swift`; `TranscriptBlockWindowingTests` gains the `classifyChange` cases

**Interfaces:**
- Consumes: `ToolInvocationIndex` (Task 6), `ToolRowSummary` and `ToolInvocationBuilder.rowSummary` (Task 9)
- Produces:

```swift
struct VerbCount: Equatable { var verbKey: String; var count: Int }
struct ToolGroupHeaderModel: Equatable { var groupID: Int; var callCount: Int; var verbDigest: [VerbCount]; var failedCount: Int; var durationSeconds: Double?; var timestamp: Date?; var isOpen: Bool }
struct ToolInvocationRowModel: Equatable { var invocationID: Int; var groupID: Int?; var position: CardPosition; var isOpen: Bool; var contentStamp: Int }   // contentStamp = hash of (member block count, total UTF-16 length of member block texts), so an arriving output changes the row
enum CardPosition: Equatable { case solo, first, middle, last }
enum TranscriptToolRows {
    static func groupHeaderRowID(forGroup groupID: Int) -> Int    // Int.min / 2 + groupID (never collides with block ids or telemetry -i-1 ids)
    static func emit(blocks: ArraySlice<SessionTranscriptBuilder.LogicalBlock>, index: ToolInvocationIndex,
                     rowSummary: (ToolInvocationRef) -> ToolRowSummary,   // controller passes a cached closure over the FULL block array
                     openGroups: Set<Int>, openInvocations: Set<Int>, activeRoles: Set<TranscriptRoleFilter>,
                     failedInvocationIDs: Set<Int>) -> [BlockRowModel]
    static func seedOpenState(newGroups: [ToolGroupHeaderModel], index: ToolInvocationIndex,
                              failedInvocationIDs: Set<Int>) -> (groups: Set<Int>, invocations: Set<Int>)
}
```

- Rules:
  - Header `durationSeconds` = wall span from the group's first to its last block timestamp; nil when fewer than 2 timestamps (a sum would overstate parallel calls). `timestamp` = the first block's.
  - A run is consecutive tool blocks (`.toolCall`, `.toolOut`, and `.error` blocks that belong to an invocation per `index.invocationIDByBlock`).
  - A run with one invocation emits one `.toolInvocation` row with position `.solo` and no header.
  - A run with ≥ 2 invocations emits a header row (`groupID` = the first invocation id). When the group is open, it also emits one row per invocation (`first/middle/last`).
  - Default open: a group with any failed invocation starts open, and its failed invocations start open at L2. The controller seeds `openGroups` and `openInvocations` once per new group id and does not reseed after user toggles.
  - Role filter:
    - An invocation row shows when `.tools` is active, or when `.errors` is active and the invocation failed.
    - A header shows when any of its rows would show.
    - With all roles active, everything shows.
  - A group split by the window edge uses the group id of its first loaded invocation (same as today's re-keying on prepend).
  - An invocation whose call lies before the loaded window is emitted at its first output's position, with id = invocation id. `rowSummary` reads the call from the full block array (`allBlocksCache`), so the row is complete. No "Load call" control is needed (spec §9 already says so).
  - Verb digest: count actions by `verbKey`, sort by count (ties by first appearance), and show at most 3 followed by "…".

- [ ] **Step 1: Write failing tests**

```swift
func testSoloInvocationHasNoHeader()
func testClosedGroupEmitsHeaderOnly()
func testOpenGroupEmitsRowsWithPositions()
func testFailedGroupSeedsOpen()                // seedOpenState(newGroups:…) returns failed group + failed invocation
func testErrorsOnlyFilterShowsFailedInvocations()
func testHeaderRowIDNeverCollides()            // for ids 0…10_000 and telemetry ids
func testAppendingCallToOpenGroupIsAppendOnly() // call+output appended to the last open group → classifyChange == .appendWithReload(count: 1, reloadRows: [header row, previous last row])
func testOutputArrivalReloadsOnlyItsRow()       // output appended to the last invocation → .appendWithReload(count: 0, reloadRows: [that row])
func testNonToolContentChangeStaysWholesale()   // a changed assistant row in the prefix → .wholesale (unchanged behaviour)
func testPrependAcrossGroupBoundaryFallsBackSafely() // prependDiff reports droppedRowIDs for the re-keyed header
func testCallOutsideWindowStillEmitsCompleteRow()    // window starts at the output block → one row, id == call index, summary has the call's command
```

- [ ] **Step 2: Run** `TranscriptToolRowsTests` and `TranscriptBlockWindowingTests`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** both classes plus `TranscriptToolSummaryTests` and `TranscriptTelemetryPresentationTests`. Expected: PASS (the last two unchanged).
- [ ] **Step 5: Commit** `feat(transcript): emit group headers and one row per invocation`.

### Task 13: Cells, toggles, links, context menu, and the switch to the new rows

**Files:**
- Create: `AgentSessions/Views/TranscriptToolCells.swift` (contains `ToolGroupHeaderCellView`, `ToolInvocationCellView`, and the SwiftUI views `ToolGroupHeaderView` and `ToolActionRowHeader`)
- Modify: `AgentSessions/Services/TranscriptToolSummary.swift` (delete `mergeToolRuns` once there are no callers)
- Modify: `AgentSessions/Views/TranscriptBlockListView.swift`:
  - **The switch (moved here from Task 12):** `rowsWithTelemetry` calls `TranscriptToolRows.emit` instead of `TranscriptToolSummary.mergeToolRuns` (it gains the index, the `rowSummary` closure, the open sets and failed ids; the controller supplies them from the state stored in Task 6). Remove `.toolGroup` from `BlockRowModel.Content` and every switch. Update `primaryBlock` (a header row's chrome/timestamp/height come from its first invocation's first block), `isToolCard`, `toolBlocks` and `bodyText`.
  - `rowIndex(forBlock:)` resolves a tool block through `invocationIndex.invocationIDByBlock` to its invocation row; when that row is hidden inside a closed group, it returns the group header row. Find scrolling, `scrollToBlock`, `flashRow` and `autoExpandCollapsedMatch` use it.
  - The controller seeds `openGroups`/`openInvocations` through `TranscriptToolRows.seedOpenState` once per new group id.
  - Extract protocol `TranscriptRowCell` (`bodyText`, `wireSelection`, `applySelectionRange`, `clearFindHighlights`, `setFlashAlpha`) from `BlockCardCellView`, and use it in `forEachVisibleCell`.
  - `tableView(_:viewFor:)` picks the cell by row content.
  - `measuredHeight` gains the new row kinds: header 24 pt + 4 pt gap; invocation = 24 pt × actions + rendered body height when open.
  - Controller state:
    - `openGroups` and `openInvocations` replace `expandedToolRowIDs`;
    - `foldStates: [Int: [Int: FoldState]]`;
    - a presentation cache (an `NSCacheMemo` keyed by invocation id + block text lengths + font bucket + width bucket).
  - `toggleGroup(_:option:)` and `toggleInvocation(_:option:)` recompute rows through `emit` and apply `insertRows` / `removeRows`. Both clear cross-block selection, keep the scroll anchor, and implement Option-click (all rows in the group).
  - `textView(_:clickedOnLink:at:)` handles `toolfold:` payloads.
  - Context menu for invocation rows: Copy, Copy Command, Copy Output, Copy as Markdown, Show Raw Event, Expand All in Group, Speak, Stop Speaking. Show Raw Event opens a popover with the pretty `rawJSON` of the call and its outputs. When the text contains `[OMITTED bytes=`, the popover says "Large strings were shortened when the app stored this event."
- Test: `AgentSessionsTests/TranscriptToolCellsTests.swift`; rewrite the group assertions in `TranscriptToolSummaryTests` (`testMergeConsecutiveToolRuns`, `testLoneToolBlockStaysMessage` → against `emit`), `TranscriptTelemetryPresentationTests` (`.toolGroup` references, `rowsWithTelemetry` calls) and `TranscriptBlockWindowingTests` (`groupRow` helper builds the new rows).

**Interfaces:**
- Consumes: Tasks 6, 9, 11 and 12.
- Produces: `BlockTableController.toggleGroup(groupID: Int, allRows: Bool)`, `toggleInvocation(invocationID: Int, allInGroup: Bool)`, and `handleToolFoldLink(_ link: ToolFoldLink, invocationID: Int)`.
- Row header layout (SwiftUI, fixed 24 pt):
  - chevron;
  - SF Symbol 12 pt, red when failed;
  - verb;
  - object (mono or system per `objectIsAgentLabel`), cut at the tail;
  - chips;
  - duration;
  - hover buttons Copy (`doc.on.doc`) and Raw (`curlybraces`).
- VoiceOver: label `"<verb> <object>, <status>, <chips joined>"`, with the disclosure trait and expanded state.
- Card chrome by `CardPosition`: `solo` = full rounded card; `first` = top corners; `middle` = none; `last` = bottom corners. The accent bar is continuous across rows.
- Increase Contrast (`NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast`): pane borders use `separatorColor`, and the pane fill alpha ×1.5.

- [ ] **Step 1: Write failing tests** (controller-level). No existing test hosts a table: add a test helper that builds `NSWindow` + `NSScrollView` + `NSTableView`, attaches a `BlockTableController`, and calls `apply(...)` with fixture blocks and an index. This helper is part of the task's work.

```swift
func testToggleGroupInsertsRows()            // rows.count grows by invocation count; table.numberOfRows matches
func testRowIndexForOutputBlockFindsInvocationRow() // output block index → its invocation row; inside a closed group → the header row
func testOptionToggleOpensAllInvocations()
func testFoldLinkShowAllGrowsHeight()
func testCopyReturnsPlainText()              // menu Copy on an open invocation → pasteboard == action.plainText
func testShowRawMentionsShortenedStrings()   // rawJSON containing "[OMITTED bytes=9000]" → popover text contains the notice
func testVoiceOverLabel()                    // failed shell row → "Ran make, failed, exit 2"
func testCardPositionsDrawContinuousBar()    // first/middle/last cells: accent bar frames touch (no gap) at 1× scale
```

- [ ] **Step 2: Run** `TranscriptToolCellsTests`. Expected: FAIL.
- [ ] **Step 3: Implement.** Remove the old tool path from `BlockCardCellView` (`configureToolCard`, `expandedToolBodyText`, `ShowAllRow` use for tools) once nothing calls it.
- [ ] **Step 4: Run** `TranscriptToolCellsTests`, `TranscriptToolRowsTests`, `TranscriptToolSummaryTests`, `TranscriptTelemetryPresentationTests`, `TranscriptBlockListLinkifyTests`, `TranscriptBlockListReviewCardTests`, `TranscriptSelectionCoordinatorTests` and `TranscriptBlockWindowingTests`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(transcript): tool group and invocation cells`.

### Task 14: Selection and copy across invocation rows

**Files:**
- Modify: `AgentSessions/Views/TranscriptBlockListView.swift` (`renderedSelectableText`, `isExcludedFromSelection`, `excludedOrdinals`)
- Test: `AgentSessionsTests/TranscriptSelectionCoordinatorTests.swift` (extend)

**Interfaces:**
- Consumes: `RenderedToolBody.plainCopyText` (Task 11).
- Rules:
  - A closed invocation row contributes its L1 line text (`"<verb> <object>"`). Today closed tool rows are excluded. The change makes a drag across closed rows copy their one-line summaries.
  - An open row contributes `plainCopyText`.
  - A group header contributes `"<n> tool calls"`.
  - Gutter text is never copied.

- [ ] **Step 1: Write failing tests**

```swift
func testDragAcrossClosedRowsCopiesSummaries()
func testOpenRowCopiesVisibleTextWithoutGutter()
```

- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the class and `TranscriptBlockListLinkifyTests`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(transcript): copy tool rows as their visible text`.

### Task 15: Find on decoded text

**Files:**
- Create: `AgentSessions/ToolRendering/ToolSearchTextStore.swift`
- Modify: `AgentSessions/Services/TranscriptDerivedState.swift`:
  - `computeFindMatches` searches `ToolSearchTextStore.text(forBlock:)` for tool blocks when it is ready, and `block.text` otherwise;
  - `BlockMatch` gains `space: MatchSpace` (`.raw` or `.decoded`);
  - expose `isDecodingToolText`.
- Modify: `AgentSessions/Views/TranscriptBlockListView.swift`:
  - Map matches into rendered ranges through `RenderedToolBody.sourceMap`.
  - `autoExpandCollapsedMatch` opens the group, the invocation and the fold (`FoldState.showAll` or `openedLongLines`), and records them for Esc.
  - Unified-search jump with 0 local matches → `flashRow` and open the invocation.
- Modify: `AgentSessions/Views/TranscriptPlainView.swift` (find bar shows "Searching tool output…" while `isDecodingToolText` and the query is non-empty; add the string to xcstrings)
- Test: `AgentSessionsTests/ToolSearchTextStoreTests.swift`, `AgentSessionsTests/TranscriptDerivedStateTests.swift` (extend), `AgentSessionsTests/TranscriptFindNavigatorTests.swift` (extend)

**Interfaces:**
- Produces:

```swift
final class ToolSearchTextStore: @unchecked Sendable {   // lock-protected dictionary
    func start(blocks: [SessionTranscriptBuilder.LogicalBlock], index: ToolInvocationIndex, source: SessionSource,
               viewportBlock: Int, onComplete: @escaping @MainActor () -> Void)   // utility QoS, viewport-outward order
    func text(forBlock globalBlockIndex: Int) -> String?    // for the invocation's id block: its actions' plainText joined by a blank line, plus footer facts; "" for the invocation's other member blocks (each match is reported once, at the row that shows it); nil when not decoded yet
    var isComplete: Bool { get }
    func cancel()
}
```

- [ ] **Step 1: Write failing tests**

```swift
func testDecodedTextFindsUnescapedQuery()      // Codex output with \"x\" raw → query "\"x\"" matches in decoded space
func testFindRerunsOnceWhenDecodePassCompletes() // query before completion → raw results; after onComplete → exactly one recompute
func testMatchInFoldOpensAndEscRestores()
func testUnifiedJumpWithNoLocalMatchFlashesRow()
func testOpeningSessionDoesNotWaitForDecodePass() // computeSnapshot returns before store completes (store started after)
```

- [ ] **Step 2: Run** the classes. Expected: FAIL.
- [ ] **Step 3: Implement.** Start the store when a new snapshot lands, and cancel it when the session changes.
- [ ] **Step 4: Run** the classes, plus `TranscriptFindNavigatorTests` and `Stage0PerfHarnessTests`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(transcript): find matches decoded tool text`.

### Task 16: Errors filter and ▲▼ jumps per invocation

**Files:**
- Modify: `AgentSessions/Services/TranscriptDerivedState.swift` (`Snapshot.toolJumpIDs: [Int] = []` = invocation ids in order; `Snapshot.errorJumpIDs: [Int] = []` = `.error` block indices that belong to no invocation, merged with failed invocation ids, sorted), `AgentSessions/Views/TranscriptBlockListView.swift` (`apply` receives both arrays next to the index; `handleRoleJumpIntent` uses them; a jump to an id inside a closed group opens the group), `AgentSessions/Views/TranscriptPlainView.swift` (passes them; `roleOccurrenceCount` uses `toolJumpIDs.count` / `errorJumpIDs.count`, so the ▲▼ enabled state matches the jump list)
- Scope: P1 steps once per invocation row. Per-action stops inside a flattened Codex script row move to P2 with `ToolInvocation.calls` (spec §6.8 and §11 updated).
- Test: `AgentSessionsTests/TranscriptDerivedStateTests.swift` (extend), `AgentSessionsTests/TranscriptToolRowsTests.swift` (extend)

- [ ] **Step 1: Write failing tests**

```swift
func testToolJumpStepsPerInvocation()       // c1 o1 c2 o2 → toolJumpIDs == [c1, c2]
func testErrorJumpIncludesFailedInvocations()
func testRuntimeErrorBlockIsOneErrorStop()   // c1 + paired .error block → errorJumpIDs == [c1], not [c1, errorBlock]
func testJumpIntoClosedGroupOpensIt()
```

- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(transcript): filters and jumps work per tool invocation`.

### Task 17: Corpus readability check

**Files:**
- Create: `AgentSessionsTests/TranscriptToolCorpusCheckTests.swift`
- Test: itself (gated)

**Interfaces:**
- Consumes everything above.
- Gate: `AS_TOOL_CORPUS_CHECK=1` (pass it through `scripts/xcode_test_stable.sh` the way `AS_REAL_SESSION_REPLAY` is passed). The structure follows `RealSessionReplayTests`:
  - a watchdog of 600 s;
  - stdout muted;
  - for each `SessionSource.allCases`, discover sessions newest first, at most 200 per source: through `parseFullByPath` on discovered files, or through `parseFullByIdentity` for identity-only sources (Hermes, Devin), driven by their discovery the way `RealSessionReplayTests` drives OpenCode;
  - sources with no discovery seam are listed under `not_covered` in the report, never skipped silently.
- Output: `scripts/probe_scan_output/tool_corpus/report.json` with counts per source and per tool family.
- Fails when any of these is above 0. Every "rendered" check uses `ToolDetailRenderer` with all folds open:
  1. rendered text contains `\n`, `\"` or `\/` that the decoded source text did not contain;
  2. rendered body starts with `[{"type"` or `{"text"`;
  3. an output action has the "Tool call" fallback label while its call exists;
  4. both blocks have `toolCallID` but are not paired together;
  5. a folded pane exceeds its budget;
  6. `gAAAAA` ciphertext appears in `plainText`.
- Report only: fallback (structured, unknown name) counts per family, with no failure.

- [ ] **Step 1: Write the gated test** with the invariants above as assertions over the collected counts.
- [ ] **Step 2: Run** `AS_TOOL_CORPUS_CHECK=1 ./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/TranscriptToolCorpusCheckTests`. Expected: report written. Fix every invariant failure in the task that owns the code, re-run, and loop until it passes.
- [ ] **Step 3: Run** without the env var. Expected: SKIPPED.
- [ ] **Step 4: Commit** `test(transcript): local corpus readability check for tool rendering`.

### Task 18: Perf gate, full suite, owner QA build

**Files:** none new.

- [ ] **Step 1: Perf.** Run `TEST_RUNNER_AGENTSESSIONS_PERF=1 ./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/Stage0PerfHarnessTests -only-testing:AgentSessionsTests/TranscriptWindowedBuildTests` (the harness reads `AGENTSESSIONS_PERF`; `TranscriptWindowedBuildTests` has no gate). Confirm the perf tests ran, not skipped. Expected: open/snapshot timings within +5% of `main` at the P0 commit (measure both in this step). Record both numbers in the commit body.
- [ ] **Step 2: Full suite.** Run `./scripts/xcode_test_stable.sh`. Expected: 0 failures, and the executed count = 3942 + every new test of this branch.
- [ ] **Step 2b: Docs.** Add P1 bullets under `[Unreleased]` in `docs/CHANGELOG.md` and to `docs/summaries/2026-11.md` (agents.md "User-visible changes").
- [ ] **Step 3: Owner QA build.** Build Debug to a build-only derived-data path (`-derivedDataPath .deriveddata-run`, never the test path). Give the owner this checklist:
  - the screenshot session;
  - a Claude session with parallel Bash calls;
  - one OpenCode, Hermes and Cursor session each;
  - light and dark;
  - narrow and wide windows;
  - Find for a quoted string;
  - the Errors filter.
- [ ] **Step 4: Handover.** Add a `RepoHandover.md` entry with the state, the decisions (link the spec) and next steps (P2).
