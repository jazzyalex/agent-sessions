# Transcript tool rendering — design

**Date:** 2026-11-04 · **Status:** Design complete; owner review of §13 calls pending · **Mockup:** [docs/mockups/transcript-tool-rendering-mockup.html](../../mockups/transcript-tool-rendering-mockup.html)

## 1. Intent

The owner's goal: every tool call in the Session view is formatted and easy to read. This applies to every block, every agent and every edge case.

Today a tool card can show escaped JSON three layers deep, a command cut at 120 characters, and an output labelled "Tool call" with no link to its call. The 4.2 redesign gave prose real formatting. Tool calls kept the raw-string path. This design gives tool calls the same care.

The measure of success: a person reads a turn and understands, without effort, what the agent did, what failed, and what each step returned. They see the exact bytes only when they ask for them.

## 2. Diagnosis (code as of `555fbfdd`)

| # | Defect | Where | Effect |
|---|--------|-------|--------|
| D1 | The Session view does not use the tool normalizer. | `BlockCardCellView.expandedToolBodyText` (`TranscriptBlockListView.swift:3845`) prints `block.text`. Text mode and Markdown export (`TranscriptPlainView.swift:199`), search (`SessionSearchTextBuilder.swift:273`) and the old Terminal path use `ToolTextBlockNormalizer` (1,707 lines). | Years of readability work (stdout/stderr split, exit codes, file-op lines, plan lines, accessibility-tree clean-up) do not reach the default view. |
| D2 | The call text is lossy. | `renderToolCallLabel` (`SessionTranscriptBuilder.swift:740`): name + one-line JSON, cut at 120 chars + "…". | The full command is not visible anywhere in the card. Non-JSON inputs (Codex `exec` JavaScript) lose their line breaks. |
| D3 | Structured output becomes a string at parse time. | `SessionIndexer.swift:3192`: `stringifyJSON(output, pretty: true)`. Events are parsed again from the session file on every open (`parseFileFull`) and are not stored, so a parser fix needs no re-index. Only the FTS search text is stored. | Content-item arrays show as `"text" : "…"` with literal `\n`. Codex code-mode output adds JSON lines inside those strings, and command output inside those, so the view shows three escape layers. |
| D4 | The output has no identity. | Codex `custom_tool_call_output` and Claude `tool_result` carry no `name`. `TranscriptToolSummary.summary` falls back to "Tool call". | The reader cannot tell which call an output belongs to. |
| D5 | The call/output pairing is wrong for parallel calls. | `TranscriptTurnTiming.compute` pairs with a stack (LIFO). | `call1 call2 call3 out1 out2 out3` pairs out1 with call3. Durations are wrong, and any future pairing built on this is wrong too. Call ids exist in the raw events and are not used. |
| D6 | The group count is wrong. | `configureToolCard`: `"\(toolBlocks.count) tool calls"`. | A call and its output are two blocks. One command shows as "2 tool calls". The screenshot's "12 tool calls" was 6 calls. |
| D7 | The line limit counts `\n`, not visual lines, and applies to the whole group. | `toolRowHeightState`, `CardMetrics.toolBodyTruncationLineLimit = 20`. | A 10,000-character line counts as 1 line and wraps into a wall of text. In a 12-call group, 20 lines cover the first call or two. "Show all" then dumps everything. |
| D8 | No per-call disclosure inside a group. | `expandedToolBodyText` doc: "one expansion level — no per-call collapse". | The approved 4.2 mockup had per-tool rows. The build dropped them. |
| D9 | No typographic hierarchy. | Tool body = one monospaced `NSTextView` string at body size. | Commands, outputs, labels and separators all look the same. The only separator is a "•" line. |
| D10 | Slashes show as `\/`. | `JSONSerialization` without `.withoutEscapingSlashes` in `compactJSONOneLine`, `stringifyJSON` (indexer) and `ClaudeSessionParser` input stringify. | Every Claude call label reads `Bash {"command":"cd \/Users\/…`. Keys are also sorted, so `command` sorts before `description` and the readable description is cut off. This is a one-line fix and can ship before everything else. |
| D11 | Identity is dropped at parse time. | Codex `namespace` is ignored, so MCP calls become bare `js`, `click`, `send_message`. `web_search_call` has no `name` and its query sits in `action.query`, so the label is `?`. `call_id` / `tool_use_id` are not stored in `SessionEvent`. | 4,900 Codex MCP calls and 1,167 web searches have no meaningful label. Pairing must re-read `rawJSON`. |
| D12 | Claude dispositions lose data. | `ClaudeSessionParser`: runtime errors become `.error` with text only (no tool name, no output split). User rejections become `.meta` (hidden by default). `toolUseResult` is read for its string form, `stdout`/`stderr`, `is_error` and file type (`ClaudeSessionParser.swift:740–760`), but stdout and stderr are joined. `structuredPatch`, `persistedOutputPath` and Agent `toolStats` are ignored. Claude `rawJSON` is a re-encoded copy in which every string over 8,192 bytes becomes `[OMITTED bytes=N]` (`ClaudeSessionParser.swift:8`, `:1286`), and all tool blocks from one line share it. | 3,666 failed results lose their tool name. Rejections disappear. stdout and stderr have no labels. The real Edit diff is not used. Large Claude payloads cannot be recovered from `rawJSON`. |

D1–D3 and D10 together explain almost all of the screenshot. D4–D9 explain why the card is still hard to scan after the bytes are decoded. D11–D12 are parser losses. Because events are parsed fresh on every open (D3), the fix for D11–D12 belongs in the parsers (§7, "Parser fields").

**Scale (full local corpus, survey 2026-11-04).** Codex: 119,817 calls in 928 files. `exec` (code mode) is 40.0% and `exec_command` 36.7%. About 65% of shell work now runs inside `exec` JavaScript, and 12.1% of `exec` calls run several commands. 98.8% of `exec` outputs are content-item arrays; 36.9% contain JSON lines inside; 28% have a line over 500 characters. Claude Code: 140,478 calls in 2,703 files. `Bash` is 59.5%, `Read` 8.4%, `Edit` 8.4%, web tools 8.3%, browser MCP 5.1%. 34% of Claude results and 35.7% of Codex results exceed 20 lines. Pairing by id works for 99.98% (Codex) and 99.99% (Claude) of calls. Shell plus code mode alone covers about 80% of all local tool calls, which is why P1 (§11) starts there.

## 3. Goals

1. **G1 — Decode everything.** No escaped JSON, no `\n` literals, no content-item wrappers, and no base64 reaches the screen, unless the original payload really is that text.
2. **G2 — One action, one row.** The unit on screen is an invocation: a call paired with its output. A batch call (Codex code mode, parallel shell) splits into one row per action.
3. **G3 — Read as sentences.** Each row says verb + object + result: "Read `RepoHandover.md` L1–160 · 412 lines", "Ran `xcodebuild test …` · exit 65 · 48s".
4. **G4 — Quiet success, loud failure.** Failures are colored, counted in the group header and open automatically. Success uses neutral grey text.
5. **G5 — Render by category.** About twelve category renderers (§6) draw every agent's tools. Agent adapters translate payloads. They never draw.
6. **G6 — Bounded size.** No pane is taller than its visual-line budget until the user asks. No line is wider than its character limit until the user asks. No action can lay out megabytes at once.
7. **G7 — Nothing is hidden for good.** Every fold opens. Every row has Copy and Show Raw Event. Find reaches text inside folds. Show Raw Event shows the event as the app stored it. For Claude, strings over 8 KB are shortened in that copy (D12), and the raw view says so. The decoded output is still complete, because it comes from the parser fields. Byte-exact raw display for large Claude payloads would need a file re-read with per-event offsets. That is out of scope.
8. **G8 — One model, every surface.** The Session view, Text mode, Copy, Markdown export and the search index use one presentation model, so they always agree.
9. **G9 — Provable.** A corpus check runs every local session through the model and fails on readability invariants (§10). "All agents, all cases" becomes a test, not a hope.

## 4. Non-goals

- Syntax highlighting of code in reads, writes and diffs (the 4.2 decision stands). The design leaves a hook for it.
- ANSI color rendering. v1 removes ANSI codes. Mapping them to colors is a follow-up.
- Changes to JSON mode. It stays the raw view.
- New toolbar controls. The design adds no global settings and no view modes (4.2 decision: one unified style).
- Token or cost badges on tool rows (4.2 decision).
- A live "running" pulse. The energy concern from 4.2 Phase 3 still applies.
- Secret masking in the display. The owner decided against it on 2026-07-06.

## 5. Anti-goals (a failure even if it works)

- **A1 — Rewriting what the agent did.** Read and Searched labels are a reading aid. The exact command is one click away, never changed, and it is what Copy Command returns.
- **A2 — A beautiful view that drops data.** If the decoder cannot parse a payload, the payload shows as clean text. It never becomes empty or shows "(unsupported)".
- **A3 — A slower transcript.** Opening a large session must not get slower. The normalizer was 88% of the build cost on large sessions (see `normalizeCache` doc). Presentation work must be lazy and cached.
- **A4 — Per-agent visual dialects.** A Read looks the same for every agent. Agent identity shows only as a small badge where it helps.
- **A5 — Breaking Find, selection or copy.** These are the 4.2 parity gates, and they still apply.

## 6. The design

### 6.1 Three levels of disclosure

| Level | Shows | Default |
|-------|-------|---------|
| **L0** group header | `N tool calls` + a verb summary ("Read 2 files · Searched 2 · Edited 1 file") + a red `N failed` pill + total duration. | Closed for success-only groups. |
| **L1** action row (24 pt) | Category icon · verb · object (monospace, truncated at the tail) · result chips (exit code, line count, +/−, "no matches", "cut by Codex") · duration. Copy and Raw buttons show on hover. | Shown when the group is open. A group with a failure opens to L1, and the failed row opens to L2. |
| **L2** detail | The category renderer (§6.3): context line (cwd, shell, timeout, "exec script · command 1 of 2"), input pane, output pane(s), footer facts. | Closed, except for failed rows and Find hits. |

- A lone invocation has no group. Its L1 row is the card header, and the card opens straight to L2.
- Option-click on a chevron opens or closes every row in the group (Finder behavior).
- The group header counts **calls** as the agent made them. The verb summary counts **actions**.
- The verb summary lists up to three verbs, sorted by count, then "…". The words come from the category table (§6.3) and are localized.

### 6.2 Presentation model (new, pure, no UI)

```
ToolInvocation
  id                // the call's globalBlockIndex, or the output's when there is no call
  calls: [CallRef], outputBlocks[]    // source blocks, kept for Find, Raw and Copy;
                                      // 0 calls = orphan output; >1 only for a collapsed poll run (P2)
  agent: SessionSource
  toolName: String                    // as the agent named it
  actions: [ToolAction]               // >= 1; a batch call gives one action per child call
  status: success | failed(exitCode?) | rejected | interrupted | noResult | pending | unknown
          // unknown = the source never records results (Cursor); shows nothing
  duration: TimeInterval?
  agentTruncation: AgentTruncation?   // "Codex cut this output at N tokens / M lines"

ToolAction
  category: shell | read | write | edit | search | list | web | plan | subagent | ask | image | structured
  verb: LocalizedStringKey            // "Ran", "Read", "Edited", "Searched", ...
  object: String                      // path / pattern / URL / command (single line)
  objectDetail: String?               // "L1–160", "in AgentSessions · *.swift"
  context: [(key, value)]             // cwd, shell, timeout, workdir, "exec script · 1 of 2"
  input: InputPresentation            // .command(String) | .fields([Field]) | .diff([FileDiff]) | .file(path, content, language?) | .prose(markdown) | .checklist([Item]) | .none
  output: OutputPresentation          // .text(DecodedText) | .lines(gutter: [Int?], text) | .matches([FileMatches]) | .markdown(String) | .fields | .table | .images([InlineImage]) | .empty | .binary(bytes)
  resultChips: [Chip]                 // "exit 65", "412 lines", "+14 −2", "no matches"
  plainText: String                   // the Text-mode / Copy / export / search form (§8)
```

Built by `ToolInvocationBuilder` in two passes:

1. **Pairing (cheap, whole session, on `apply`).** Read call ids from `rawJSON` (`call_id`, `tool_use_id`, `toolCallId`, `id`, per adapter). Pair by id. Without ids, pair in order (FIFO) inside the same assistant message or turn. Use the stack match only as the last fallback. The result replaces the LIFO match in `TranscriptTurnTiming`, so tool durations become correct too (fixes D5). This pass reads ids only and decodes no payloads.
2. **Presentation (lazy, per visible row, cached).** L1 needs category, verb, object and status. It parses the input and reads the exit code. It does not decode the output body, except for agents whose status lives inside the output text (Codex code mode). L2 decodes the output when the row opens or when Find needs it. Cache key: (eventIDs, text byte length, adapter version), in an `NSCacheMemo` like `normalizeCache`, or in the generic `LRUCache` that backs `TranscriptCache`. The builder picks one.

### 6.3 Category renderers

| Category | Verb (L1) | Object | Input (L2) | Output (L2) | Result chips |
|---|---|---|---|---|---|
| shell | Ran (Polled / Sent input for process polls; Ran script for script tools) | the command, first line | `$ command`, full text, wrapped with a hanging indent. Wrappers (`bash -lc`, `zsh -lc`) and a leading `cd X &&` move to the context line. A heredoc body becomes a file pane. | Decoded text. stderr in red when the agent separates it. Head/tail fold. | `exit N` (red when not 0), line count, duration |
| read | Read | file name | (none) — the command or path is in the context line | Code with a line gutter. The parser detects every line-number form seen: `cat -n` arrows (`     1→`), `nl -ba` and Kimi tabs (`N\t`), `N:` (OpenCode, DSH, Antigravity), `N|` (Hermes), `N | ` (Cline), `N→` (Grok). File wrappers (`<path>…</path><type>file</type><content>…</content>`, `(End of file - total N lines)`) become the file header and footer. | line range, line count |
| write | Created / Wrote | path | (none) | File pane with a gutter, closed by default | `+N` |
| edit | Edited | file name, or "N files" | Unified diff per file: hunk headers, +/− lines tinted green/red, old and new line numbers when known. Parses `*** Begin Patch`, unified diff, `old_string`/`new_string`, `edits[]`. | Hidden when it only confirms success. Shown when it is an error. | `+N −M` |
| search | Searched | pattern | scope ("in path · glob") | Matches grouped by file, with line numbers and the term highlighted. Path lists show as a list. | `N matches · M files`, or "no matches" |
| list | Listed | directory | (none) | Tree or list, folded | `N files` |
| web | Fetched / Searched the web | URL (link) / query | (none) | Markdown in a pane with a height limit / result list (title + domain) | size, result count |
| plan | Updated plan | "2 of 5 done" | explanation as prose | Checklist (done / in progress / pending) | (none) |
| subagent | Subagent | description | prompt as prose, folded | result rendered as an agent message (markdown); footer link to the subagent session when indexed | model, call count, duration |
| ask | Asked | question | options | chosen answer marked | (none) |
| image | Screenshot / Image | caption or file name | (none) | Thumbnail through the existing inline-image grid; click opens | size |
| structured (MCP, unknown) | `server › tool` or the tool name | first string field | Key/value list: strings unescaped, multi-line strings kept, nested objects folded, arrays of same-key objects shown as a table, URLs as links | Same decoding; content-item arrays unwrapped; text that looks like markdown rendered as markdown | `ok` / `error` |

**Command intent.** A shell command whose whole effect is a read or a search gets the read or search verb: `cat`, `sed -n 'a,bp'`, `nl -ba`, `head`, `tail` give Read; `rg`, `grep`, `ag`, `fd`, `find -name` give Searched; `ls`, `tree` give Listed. Chains (`;`, `&&`, `|`) qualify only when every part is read-only and one part is the main read or search (for example, `nl -ba f | sed -n '1,80p'` is a Read). Anything else is "Ran". This is a label only (A1). Prior art (checked 2026-11-04): Codex classifies commands as `ParsedCommand { Read, ListFiles, Search, Unknown }` in `openai/codex` `codex-rs/shell-command/src/parse_command.rs`, and its TUI groups them as "Explored" in `codex-rs/tui/src/exec_cell/render.rs`. Port the rules, not the code. Where a Codex rollout already records the parsed command for an exec, use the agent's own classification.

**"No matches" rule.** For grep-family commands, exit 1 with empty stdout is "no matches" in grey, not a failure.

### 6.4 Decoding pipeline (shared, all agents)

The decoders run in this order, and each layer is optional:

1. **Start from the original value.** Use `toolOutputValue` (§7, "Parser fields"), not the stringified `toolOutput`. This fixes D3 at the source.
2. **Unwrap content items.** `[{type: text|input_text|output_text, text}]` becomes the joined text. `{type: image, …}` / `input_image` / base64 data URLs become image items.
3. **Decode JSON-in-string.** If a whole string parses as a JSON object or array, decode it, up to depth 3. This applies only to the whole string; a JSON fragment inside prose stays text.
4. **Split JSON lines.** If every non-empty line parses as an object and the objects share keys, treat the text as records. Agent-specific record schemas (Codex `chunk_id/exit_code/output`) map to actions (§7). Unknown records render as JSON lines, one compact object per line.
5. **Lift agent envelopes into facts.** "Script completed / Wall time N seconds / Output:", "Warning: truncated output (original token count: N) / Total output lines: N", Claude `<persisted-output>` pointers and `<system-reminder>` tails, and "Process exited with code N" lines become footer facts or a muted note. They are not printed as body text. The full per-agent list is in §7.3 (for example Antigravity `Created At/Completed At`, Copilot `<shellId: …>`, Grok `<workspace_result>` and `exit: N`, OpenCode's synthetic `Exit Code: N`). An envelope is lifted only when it matches its agent's exact pattern at the start or end of the output. The same words in the middle of real output stay.
6. **Normalize text.** CRLF becomes LF. ANSI codes are removed. Tabs keep 4-column stops. Trailing blank lines are trimmed.
7. **Detect shape.** Line-numbered, diff, search matches, markdown, tabular or plain. This picks the output presentation.

Every step keeps a **source map** from rendered ranges back to the raw text, like `RenderedBody` does for markdown. Find, selection and Copy depend on it.

### 6.5 Size budgets (fixes D7)

- **Visual lines, not newlines.** Output is monospace, so columns per line = floor(paneWidth / advance(fontSize)). The fold budget counts wrapped lines exactly, with no layout pass.
- **Output pane:** the first 12 visual lines + the last 4, with a fold bar between: "⋯ N more lines · Show 500 more · Show all · Copy output". Error output shows the **last** 18 lines first, because errors are at the end.
- **Long line:** after 4 visual lines, a line stops with "… +N chars", which opens it in place.
- **Show all** stops at 20,000 lines or 2 MB. Past that limit, the pane offers Copy output and Show Raw Event.
- **Command input:** shown in full up to 12 visual lines, then folded. A heredoc body moves to its own file pane.
- **Group:** no total budget. Each row has its own.

### 6.6 Visual rules

- Keep the 4.2 card: 3 pt accent bar, 6% tint, 6 pt corner radius, `LayoutTokens` spacing. Tool cards keep `systemPurple`. A failed row's icon and exit chip use `systemRed`. The card does not turn red.
- L1: SF Symbols (`terminal`, `doc.text`, `pencil`, `doc.badge.plus`, `magnifyingglass`, `folder`, `globe`, `checklist`, `person.2`, `puzzlepiece.extension`, `photo`, `questionmark.bubble`, `curlybraces`). The verb is in system font, 11.5 pt semibold, secondary label color. The object is in SF Mono 12 pt, label color. Chips are in SF Mono 10.5 pt, tertiary color.
- L2 panes: an inset `quaternaryLabel`-strength fill with a hairline border and a 5 pt radius, the same family as the 4.2 code card (`MarkdownStyle.codeBlockBackground`). The pane font is the transcript size minus 0.5 pt. The gutter uses tertiary color and is excluded from selection and copy.
- Diff: `systemGreen` at 14% and `systemRed` at 11% behind the line. The +/− glyph stays in the text so the diff still reads in monochrome and in VoiceOver.
- Light and dark from dynamic colors only. Respect Increase Contrast. Tints get stronger, and borders become `separatorColor`.
- VoiceOver: a row reads "Ran command, `xcodebuild test`, failed, exit 65, 48 seconds". Chevrons are disclosure buttons with expanded state.

### 6.7 Rendering architecture (recommendation; the builder decides)

- **One table row per invocation** inside the existing `NSTableView`, plus a light group-header row. Joined card chrome (rounded first and last rows, flat middle) makes the group look like one card. This keeps virtualization, windowing and Find scrolling at row level. Groups with 200 calls and open outputs do not become one huge cell. Row id = call block `globalBlockIndex`. Header row id = a derived id, like `telemetryMarkerRowID`. Check `prependDiff`/`classifyChange` and the `globalBlockIndex == array position` invariant.
- **L2 is one `NSAttributedString` in one `NSTextView`** per row. Panes are paragraph runs with background fill and paragraph insets, as `MarkdownBodyRenderer` already does for code cards. One text storage keeps Find, selection, copy and the source map simple. The gutter is a separate column view, not text, so copy never includes line numbers.
- Heights stay deterministic: `measuredHeight(of:width:)` on the attributed string, plus fixed chrome. That is today's pattern.

### 6.8 Find, filters and jumps (decided)

- **Find matches what the user can see or open.** It searches the decoded `plainText` of each action plus its footer facts, not raw `block.text`. A query typed from the screen (`"`, `/`) must match. Text that the design removes for good does not match: lifted envelope text that has become a fact matches only as the fact's words, and base64, ciphertext and constant success sentences never match. Folded content matches, and Find opens the fold, the row and the group, then closes them on Esc (extends `autoExpandedByFind`). JSON mode stays the place to search raw bytes.
- **Cost rule.** After first paint, decode `plainText` for every tool block in the session off the main thread at utility priority, in block order from the viewport outward. Store it in the presentation cache. Opening the session waits for none of it (A3). A Find query that starts before this pass ends searches the decoded text where it is ready and the raw text elsewhere. It shows "Searching tool output…" in the find bar until the pass ends, then re-runs once. Match ranges are UTF-16 offsets into `plainText`. The source map (§6.4) maps them to the rendered attributed string.
- **Unified search jump.** Until P3 moves the search index to `plainText`, a jump from search can land on a block where decoded Find finds 0 matches. In that case, flash the row (existing `flashRow`) and open it to L2.
- **Errors filter.** A failed invocation counts under Errors, as do today's `.error` blocks. Status for every invocation therefore comes from the cheap pass in §6.2 (ids, exit codes and error flags). For Codex code mode, the status uses a substring scan of the output for `"exit_code":` values and the `Script failed` header. No full decode is needed.
- **Tools filter and ▲▼ jump** step per invocation row, not per block. When batch calls flatten into several actions, the jump steps per action row (P2; P1 steps once per invocation row).
- **Role filter "Tools" off** hides group headers and rows together.

## 7. Agent adapters

An adapter maps parsed events to `ToolInvocation` inputs: call id, tool name, input fields, output value, status and agent envelopes. It also maps agent tool names to categories. Shared decoders do the rest.

**Parser fields (decided).** The parsers keep what they drop today, at parse time, where the full values exist. `rawJSON` is not a reliable source: Claude's copy shortens strings over 8 KB, and Codex image lines over 100 KB or 5 MB are stubbed. Add these optional fields to `SessionEvent`:

- `toolCallID` — Codex `call_id`, Claude `tool_use_id`, and each agent's id from §7.3.
- `toolNamespace` — Codex `namespace`.
- `toolOutputValue` — the original output value (string, array or object) before stringifying, held as a small typed enum, not `Any`.
- `toolSidecar` — a typed struct with the optional structured extras listed in §7.1 item 7. Examples: Claude `stdout`/`stderr`/`interrupted`/`structuredPatch`/`persistedOutputPath`/`toolStats`; OpenCode `metadata.diff`/`exit`/`title`.
- `toolDisposition` — `rejected` / `runtimeError` / nil (fixes D12 without changing `kind` semantics that the Errors filter depends on, see §6.8).

The existing `toolOutput` string stays for every current consumer until P3 moves Text mode, export and search. Memory cost: the new fields hold references to values the parser already builds, and outputs over 256 KB keep only the string form.

### 7.1 Adapter contract

Every adapter provides the following. The survey (§7.3) shows why each item is needed.

1. **Pairing key.** The call id field. Antigravity pairs by position (a queue per planner step). Cursor transcripts store no results.
2. **Result tool name.** Grok, Hermes (91% of rows), Devin and Kimi results carry no tool name. Pairing fills it.
3. **Status.** Exit code and error flag from wherever the agent puts them (§7.3, "Status" column). The adapter normalizes them to `success | failed(exitCode?)`. Text-only error forms ("Error: Command failed (exit code: 1)", "exit: 1", "Command exited with code 1.") are parsed and then removed from the body as envelope facts.
4. **Field decoding.** Argument values that are themselves JSON strings (Antigravity: `"CommandLine":"\"date\""`, booleans as `"false"`) are decoded per field before rendering.
5. **Envelopes to lift** (§6.4 step 5). These are agent text that is about the call, not part of its output.
6. **Batch expansion.** One call can hold several actions: Codex and OpenClaw `exec` (JavaScript `tools.exec_command`), Cline `run_commands` / `read_files` / `search_codebase` arrays, OpenCode v2 `execute`. The adapter emits one `ToolAction` per child.
7. **Structured sidecars.** Many agents record the real diff, line metadata or exit code next to the text. When a sidecar exists, the adapter must prefer it over parsing the text: OpenCode `state.metadata.diff` / `filediff` / `exit`, Hermes `patch.diff`, fx `committed_file_presentation` / `command_process_presentation`, DSH `data.meta` (`lines[]`, `matches`, `diffs`), Copilot `shellExecution.exitCode` / `detailedContent`, Qwen `toolCallResult.resultDisplay`, Pi `details`, Kimi `display`.
8. **Agent labels.** Antigravity `toolSummary`, OpenCode `state.title`, Copilot `toolTitle`, Kimi `display`, and the `description` input key (Claude, OpenCode, Grok, Hermes, Cursor, DSH). The row uses them as described in §14 Q1.
9. **Results-never-recorded flag.** For a source that never stores results (Cursor `agent-transcripts`), a call without output has status `unknown` and shows no "no result" chip. Otherwise every Cursor row would carry a false warning.

### 7.2 Category map (tool name → category)

| Category | Tool names seen (bold = in local data) |
|---|---|
| shell | Codex **exec_command**, **shell**, **local_shell_call**, code-mode **exec** · Claude **Bash**, BashOutput · Antigravity **run_command** · OpenCode **bash**, **shell**, **execute** (JS) · Hermes **terminal**, **execute_code** (Python), process · Copilot **bash**, shell · Droid **Execute** · OpenClaw **bash**, **exec** (JS) · Cursor **Shell** · Pi **bash**, bashExecution · Kimi **Bash** · Grok **run_terminal_command** · Qwen run_shell_command · fx **shell**, run_command · Cline **run_commands** · DSH **bash**, job_output |
| read | Claude **Read** · Antigravity **view_file**, **read_file** · OpenCode **read** · Hermes **read_file**, skill_view · Copilot **view** · Droid **Read** · Cursor **Read** · Kimi **Read**, ReadMediaFile · Grok **read_file** · Qwen **read_file** · Devin read_file · Cline **read_files** · DSH **read** |
| list | Antigravity **list_dir** · OpenCode **list**, **glob** (paths) · Droid **LS**, **Glob** · OpenClaw **ls** · Grok **list_dir** · Qwen **list_directory**, **glob** · fx list_files, glob_files |
| edit | Codex **apply_patch** · Claude **Edit**, MultiEdit · Antigravity **replace_file_content** · OpenCode **edit** · Hermes **patch** · OpenClaw **apply_patch** (paths only) · Cursor **StrReplace**, ApplyPatch · Grok **search_replace** · fx **edit_file** · Cline **editor** · DSH **edit** |
| write | Claude **Write** · Antigravity **write_file**, **write_to_file** · OpenCode **write** · Hermes **write_file** · Cursor **Write** · Kimi **Write** · Grok **write**, search_replace with empty `old_string` · DSH **write** |
| search | Claude **Grep**, **Glob** · Antigravity **grep_search** · OpenCode **grep**, codesearch · Hermes **search_files**, session_search · Cursor **Grep**, **Glob** · Kimi **Grep**, **Glob** · Grok **grep** · Qwen **grep_search** · Cline **search_codebase** · DSH **grep**, **glob** · OpenClaw memory_search |
| web | Codex **web_search_call** · Claude **WebFetch**, **WebSearch** · Antigravity **search_web** · OpenCode **webfetch**, **websearch** · Hermes web_search, browser_navigate · OpenClaw **web_fetch** · Grok **web_fetch**, backend **web_search**, **x_search** |
| plan | Codex **update_plan** · Claude **TodoWrite**, ExitPlanMode · OpenCode **todowrite** · Hermes **todo** · Droid **ExitSpecMode** · Kimi **ExitPlanMode**, TodoList · Grok **todo_write** · DSH **todo_write** |
| subagent | Claude **Task**/Agent · OpenCode **task**, subagent · Hermes **delegate_task** · Kimi **Agent**, AgentSwarm · Grok **spawn_subagent**, **get_command_or_subagent_output** · Qwen **agent** · DSH **subagent**, send_message, list_agents |
| ask | Claude AskUserQuestion · OpenCode **question** · Hermes **clarify** · Kimi AskUserQuestion · DSH **ask_user_question** |
| image | Codex view_image · Claude screenshot results · Grok result `images[]` · Devin tool `images[]` · Kimi ReadMediaFile |
| structured | all `mcp__*`, Cursor **CallMcpTool** (real tool nested in `{server, toolName, arguments}`), and every name not listed above |

The map is data in the adapter, with a test that fails when the corpus check (§10) finds a tool family more than N times with no category.

### 7.3 Per-agent facts (survey 2026-11-04)

| Agent | Local data | Pair by | Result has name | Status lives in | Envelopes / wrappers to lift | Worst shape today |
|---|---|---|---|---|---|---|
| Antigravity | 62 sessions | position | guessed | text "Command exited with code N."; top-level `error` (ignored today) | `Created At/Completed At` header on every result; `[content truncated by Antigravity CLI]` at ~4,000 chars | every argument double-encoded |
| OpenCode | 448 sessions (v1+v2) | `callID` | yes | `state.metadata.exit` (app appends "Exit Code: N" as text) | `<path><type><content>` + `N:` lines; `<task …><task_result>` | `edit` output is "Edit applied successfully."; diff unused in metadata |
| Hermes | 136 sessions + JSON files | `tool_call_id` | 9% | `exit_code` inside JSON-in-string output | JSON-in-string on 89% of results; `{"error":…,"success":false}` | JSON-in-string everywhere; `N|` reads inside JSON |
| Copilot | 28 sessions | `toolCallId` | back-filled | `shellExecution.exitCode`; text trailer | `<shellId: N completed with exit code N>`; `[OUTPUT_OMITTED bytes=N]` | thin data; mostly fine |
| Droid | 42 sessions | `tool_use_id` | back-filled | text only ("Error: Command failed (exit code: N)", "[Process exited with code N]"); `is_error` not read | those two trailers | `Execute` risk prose pushes the command out of the label |
| OpenClaw | 34 sessions (SQLite, part zstd) | `toolCallId` | yes | `isError` only | two result wrapper dialects; `exec` output = Codex content items serialized into a string | `exec` = Codex code mode, wrapped once more |
| Cursor | 34 transcripts | none | — | none | — | **0 results for 143 calls**: calls only |
| Pi | 2 sessions | `toolCallId` | yes | `isError`, `bashExecution.exitCode` | content items | output moved to `text` on error |
| Kimi | fixtures only | `toolCallId` | no | `result.isError` | `{"output":…,"note":…}`; `N\t` reads | `display` metadata unused |
| Grok | 11 sessions | `tool_call_id` | no | first line `exit: N` | `<workspace_result …>`; `[... truncated (N chars total)]`; `N→` reads | 55% of results line-numbered, up to 52 KB |
| Qwen | 2 sessions | `id` | yes | `toolCallResult.status` / `.error` | `{"output":…}` / `{"error":…}` | subagent results of 16 KB + 18.8 KB `resultDisplay` |
| Devin | fixture only | `tool_call_id` | no | none | `[OMITTED large JSON payload bytes=N]`; `[image]` | tool names unknown (no local data) |
| fx | fixtures only | call id | yes | `command_process_presentation.exit_code` (unused) | `\n[truncated]`; base64 text objects | ready diff in `committed_file_presentation` unused |
| Cline | 27 sessions | `tool_use_id` | yes | `is_error` + per-item `success` | results = arrays of `{query, result, success}`, or the same as a JSON string; `N | ` reads; fenced diffs | batch inputs and outputs |
| DSH | 12 sessions | `callId` | back-filled | nested `isError` | content nested twice; `…[truncated N chars]`; 50,000-char tool cuts | `data.meta` (structured lines, matches, diffs) unused |

Codex and Claude Code rows: §7.4.

### 7.4 Codex and Claude Code

These two agents hold about 90% of local tool calls, so they get exact per-family rules.

**Codex** (dispatch key: `(payload.type, namespace, name)`; pair by `payload.call_id`)

| Family | Share | Input → L1 / L2 | Output handling | Status |
|---|---|---|---|---|
| `custom_tool_call` `exec` (code mode) | 40.0% | JavaScript. A tolerant reader finds `tools.<name>({…})` calls: unquoted keys, JSON-style strings with `\"`, template strings, `Promise.all([...])`. Each child becomes an action (`exec_command` → shell, with command intent; `apply_patch` → edit; `write_stdin` → poll; `mcp__…` → structured; `web__run` → web). 202 calls with no `tools.*` and every parse failure → "Ran script" with the JavaScript as a code pane. | Content items. Item 0 header `Script completed\|failed\|running with cell ID N / Wall time X seconds / Output:` → status + duration facts. Later items: optional truncation header (fact), then JSON-line chunks `{chunk_id, wall_time_seconds, exit_code, original_token_count, output}` matched to child actions **in order**. A chunk's `output` can carry a second truncation header (fact). 328 items are JSON-encoded strings that need one more unescape. When chunks and children do not match one to one (the script prints its own text with `text(...)`), show the decoded items under the script as a whole and give children no per-command output. | per-chunk `exit_code`; header "failed" / "aborted by user after Ns" |
| `function_call` `exec_command` | 36.7% | `arguments.cmd` (+ `workdir` → cwd context; `justification` → muted note) | Plain string with a 5-line header (`Chunk ID`, `Wall time`, `Process exited with code N`, `Original token count`, `Output:`) → facts; body = the rest. `Process running with session ID N` → status `pending (session N)`. | header code |
| `write_stdin` (6.5%), `wait` (0.6%) | 7.1% | A poll of a running process or code-mode cell. L1: "Polled `npm run dev`", where the command is found through the session or cell id in an earlier output. Empty `chars` = a pure poll; otherwise "Sent input". | Same header forms. From P2, consecutive polls of one session in a group collapse into one row "Polled ×6 · finished, exit 0". In P1 each poll is its own row. | header code |
| `apply_patch` | 3.9% | `*** Begin Patch` envelope → diff renderer (Add / Update / Delete / Move). 503 patches touch several files. | Three eras: JSON string `{"output","metadata":{"exit_code"}}`; `Exit code: N / Wall time / Output:` text; failure "apply_patch verification failed: …" (3.4%), shown as the error body. Success text "Success. Updated the following files" is hidden. | `metadata.exit_code` or header |
| `collaboration::*`, `multi_agent_v1::*`, `spawn_agent` / `wait_agent` / `list_agents` / `followup_task` | ~5% | subagent category. `message` values that start with `gAAAAA` are encrypted in the log: show "message encrypted in the log (N chars)", never the ciphertext. | Mostly empty (3,633 outputs): no pane. `wait_agent` / `list_agents` JSON strings → fields. | — |
| `mcp__cua_repl::js`, `mcp__node_repl::js`, `mcp__computer_use::*` | ~4% | Label `server › tool`; `title` field (when present) is the object; `code` → code pane. | `Wall time: … / Output:` header → fact. Accessibility trees (up to 5,747 lines) → folded text with tabs kept. `input_image` items → thumbnails. Node-inspect text inside JSON strings → decoded once, then shown as text. | error text only ("Computer Use server error …") → failed |
| `web_search_call` | 1.0% | "Searched the web" + `action.query` / `queries[]`; `open_page` → "Opened" + URL; `find_in_page` → "Found in page". | **No output record exists.** Status `success` with no pane. | `status` field |
| `update_plan` | 0.4% | checklist from `plan[] {step, status}`; `explanation` as prose | "Plan updated" hidden | — |
| `view_image` | 0.2% | "Viewed image" + path | image item → thumbnail; "unable to process image" → error body | — |
| `clock::sleep`, `codex_app::*`, `image_gen`, `request_user_input`, `tool_search_call` | <1% | sleep → "Waited 45s" (muted). `request_user_input` → ask. Others → structured. `tool_search_call` stays hidden as today. | — | — |
| Older fixtures: `shell` with argv arrays, `local_shell_call`, `event_msg` `exec_command_end` / `mcp_tool_call_end` / `patch_apply_end` | — | argv → command string with wrappers lifted. | `patch_apply_end.changes[path].unified_diff` is a ready diff. | — |

Sidecar to evaluate for Codex: `event_msg/item_completed` carries structured `CommandExecution`, `FileChange` and `McpToolCall` items (aggregated output, status, exit code). It is hidden today. If it covers code-mode children one to one, it is a cleaner source than parsing JSON-line chunks. This evaluation is a P2 item (§11); P1 parses the chunks.

**Claude Code** (dispatch key: `name`, MCP grouped as `mcp__<server>__*`; pair by `tool_use_id`)

| Family | Share | Input → L1 / L2 | Output handling | Status |
|---|---|---|---|---|
| `Bash`, `Monitor` | 59.5% | `command` (30% multi-line, 14% heredocs); `description` (83% of calls) is the agent label (§14 Q1); `timeout`, `run_in_background` → context | Prefer `toolUseResult {stdout, stderr, interrupted}` when present (36%): stderr in red, labelled. Otherwise the content string. `Exit code N` first line → fact. `Shell cwd was reset to …` trailer → muted note. `<persisted-output>` → "Output saved to a file (38.4 KB)" + the 2 KB preview + an Open link when the file exists. Background launch text → "Started in background · id". | `is_error`; `Exit code N`; `interrupted` |
| `Read` | 8.4% | file name + `offset`/`limit` as the line range | `N\t` numbering (older `N→`) → gutter. Image blocks (509) → thumbnail. `<system-reminder>` tail → muted note. `[Truncated: PARTIAL view …]` → fact. | `is_error`, `<tool_use_error>` |
| `Edit`, `MultiEdit`, `Write` | 11.4% | Edit: `toolUseResult.structuredPatch` (real hunks with line numbers) when present (46%), else a diff made from `old_string`/`new_string` with no line numbers. Write: file pane (to 101 KB), folded. | Success sentences hidden. `<tool_use_error>String to replace not found…</tool_use_error>` → error body. | `is_error` |
| `WebFetch`, `WebSearch` | 8.3% | URL (+ prompt as a muted note) / query | WebFetch: markdown. WebSearch: the `Links: [ {title,url} … ]` JSON line → a result list (title + domain); the rest → markdown. | `is_error` |
| `mcp__claude-in-chrome__*`, `mcp__Claude_Browser__*`, `mcp__computer-use__*` | 5.1% | action as the verb ("Screenshot", "Clicked", "Navigated to …"); `browser_batch` → one action per item | Image block → thumbnail (newer builds store `[Image: source: …jpg]` paths → load the file when it exists). `Screenshot size: …` and `Tab Context: …` → one muted context line. The `<system-reminder>` advert → hidden note. Page text / accessibility trees → folded text. | `is_error`; "not connected" boilerplate → error body, first line only until opened |
| `mcp__ccd_turn__*` | 2.0% | `update_plan` → checklist; `wrap_up` → recap as prose | Boilerplate output hidden | — |
| `Agent` (Task) | 1.3% | description + `subagent_type` / `model` chips; prompt as prose, folded | "Async agent launched" → status line with the output-file path. Hand-back frame (`[Subagent hand-back] … The report follows:` + indented lines) → frame removed, indent removed, rendered as markdown. `toolUseResult.toolStats` / `totalDurationMs` → chips (call count, duration). Token counts stay out (non-goal). | `is_error` |
| `ToolSearch` | 0.9% | query | `tool_reference` blocks → "Loaded tools: TaskCreate, Monitor" | — |
| `AskUserQuestion` | 0.15% | `questions[].options[]` → ask renderer | "Your questions have been answered: \"Q\"=\"A\"" → the chosen option is marked | — |
| `TaskOutput`, `TaskStop`, `SendMessage`, `Skill`, `StructuredOutput`, `SubagentHandback`, others | <1% each | structured fallback; `Skill` → "Loaded skill …" | `TaskOutput` XML-ish tags (`<status>`, `<exit_code>`, `<output>`) → facts + body. `SendMessage` JSON string → fields. Constant success strings hidden. | per tag |

Claude disposition rules (fixes D12): a runtime error stays a tool output with `failed` status and keeps its tool name. A user rejection becomes status `rejected` ("Rejected by you", grey). It shows as a row, not a hidden meta event. Resumed and forked files repeat 17% of calls by id. Pairing works per file, so duplicates are not merged across files.

Image bytes: the full Codex parse keeps base64 only on lines of 100 KB or less. Larger lines get `[IMG_OMITTED]`/`[IMG]`, and lines over 5 MB with an image become a stub event that loses the `call_id` and the output (`SessionIndexer.swift:2389`, `:3365–3420`). Claude raw lines hold 258 MB of base64 in total. Rules: the parser records an image reference (file path + byte range, or the `tool-results/` path Claude points to) instead of bytes. Thumbnails decode lazily off the main thread from that reference. A stubbed 5 MB line shows as "Large event (N MB) not loaded" with its tool name when the stub can keep `call_id`. Making the stub keep `call_id` is part of P1.

## 8. One model, every surface

`ToolAction.plainText` is the single plain form:

```
$ xcodebuild test -scheme AgentSessions … | tail -40
[exit 65 · 48s]
<decoded output, folds open, no gutter>
```

- **Text mode** prints it (replaces `ToolTextBlockNormalizer.displayLines`).
- **Copy / Copy Block** returns it for the selected rows. Copy Command and Copy Output return the parts.
- **Markdown export** wraps it in a fenced block, with the verb line as a heading line.
- **Search index** indexes it (replaces `ToolTextBlockNormalizer.displayText`), so search matches what the user sees.
- `ToolTextBlockNormalizer`'s knowledge moves into the adapters and decoders. Its file can go once Text mode, search and export use the new model. Until then it stays, so nothing regresses.

## 9. Edge cases (each needs a fixture)

| Case | Behaviour |
|---|---|
| Parallel calls, outputs in order | Pair by id. Without ids, FIFO inside the message. |
| Nested calls (subagent inside a call) | Pair by id. The stack match only as the last fallback. |
| Call with no output, later events exist | `interrupted` when a turn_aborted or interrupt event follows. Otherwise `noResult`. Grey chip. |
| User rejected the call (Claude: 57 in the corpus) | Status `rejected`, "Rejected by you" in grey. Shown as a row. Today it is a hidden meta event. |
| Encrypted payloads (Codex `collaboration::*` messages starting `gAAAAA`) | "message encrypted in the log (N chars)". The ciphertext never shows. |
| Process polls (`write_stdin`, `wait`) | Linked to the command that started the session or cell. Consecutive polls of one session collapse into one row with a count. |
| Code-mode script that prints its own text (chunks do not match child calls) | The decoded items show under the script as one output. Child rows show their commands only. |
| Call with no output at the session end (live) | `pending`, shown as a static "no result yet". No pulse. |
| Output whose call is outside the loaded window | Pairing is whole-session. The row sits at the output's position and reads the call from the full block array, so it is complete. No "Load call" control is needed (plan decision, 2026-11-04). |
| Output with no call at all | An "Output" row with the decoded body. |
| Source that never records results (Cursor) | Status `unknown`: no chip, no warning. The row shows the call only. |
| Positional pairing (Antigravity) | Pair by the planner step's queue. When the counts do not match, leave the rest unpaired rather than guess. |
| Tool-side truncation (Antigravity ~4,000 chars, DSH 50,000 chars, Grok `[... truncated (N chars total)]`) | Footer fact naming the agent, like Codex truncation. |
| Script tools (Hermes `execute_code` Python, OpenCode v2 `execute` JS) | "Ran script" with the script as a code pane (language noted) and the decoded output. No child-call parsing unless the API is known (Codex/OpenClaw `tools.exec_command`). |
| Empty output | "no output" chip, no pane. |
| Exit ≠ 0 | Red chip, row opens, the group counts it. Grep-family exit 1 with no output is "no matches". |
| `is_error: true` without an exit code | `failed` with no code; the chip says "error". |
| Agent truncation markers | Footer fact (orange), not body text. |
| Output > 2 MB / > 20k lines | Head/tail only. Show all is capped. Copy and Raw are offered. |
| A single line > limit | "… +N chars" in place. |
| Minified JSON output | Pretty-printed when ≤ 256 KB. Above that, shown as text with the long-line limit. |
| Base64 / binary | Image when the type is known. Otherwise "binary data (N KB)". |
| ANSI codes, CRLF, tabs | Removed / normalized / 4-column stops. |
| `<system-reminder>` and other agent tags inside output | Folded into a muted "system note" line. |
| Heredoc writes | Created + a file pane. |
| `apply_patch` through the shell | Detected and drawn as a diff. |
| Unicode, emoji, wide CJK characters | Visual-line math uses the font's real advance. CJK counts as 2 columns. |
| Same command repeated (not a process poll) | No merging. A general "×N" collapse is P4. |
| Redacted text (`[REDACTED]` from the provider) | Shown as is (owner decision). |
| Find hit inside a fold, a long-line cut or a closed row | Find opens the fold, row and group, and closes them on Esc. This extends `autoExpandedByFind`. |
| Font size change, width change, light/dark switch | Re-measure from cached presentations. No re-decode. |

## 10. Verification

1. **Unit tests per decoder and adapter**, with real excerpts as fixtures. Redact secrets. Never use the owner's personal session content in committed fixtures.
2. **Corpus readability check** (`scripts/transcript_readability_check`, or an XCTest gated by an env flag like the perf gate). It runs every local session of every agent through `ToolInvocationBuilder` and fails when:
   - a rendered line contains `\n`, `\"` or `\\` escape sequences that were not in the decoded source text;
   - a rendered body starts with `[{"type"` or `{"text"`;
   - an output row has no tool name while its call exists in the session;
   - a call id exists and the pairing does not use it;
   - a pane exceeds its budget while folded;
   - a fallback ("Tool call", raw JSON pane) is used for a tool family more than N times. This reports the families still missing an adapter.
   It prints counts per agent and per family, so "all agents, all cases" has a number.
3. **Golden snapshots.** Render about 40 fixture invocations (every category × light/dark × 2 widths) to PNG through `NSView.cacheDisplay` in a test, and diff them against goldens. Brand-color goldens depend on the OS (see the memory note on `systemTeal`), so pin the OS or compare structure, not pixels.
4. **Parity gates from 4.2:** Find with highlight and next/prev, cross-block selection and copy, follow-tail, export unchanged except for the improved tool text, and the perf suites stay green (TranscriptWindowedBuildTests, Stage0PerfHarnessTests and the others listed in the 4.2 handover).
5. **Perf budget:** opening the largest local session takes no more time than on `main` (±5%). Pairing adds at most one pass over the block ids. Expanding an L2 row with 20k lines does not block the main thread for more than 50 ms (build off-main and cache).

## 11. Phasing

| Phase | Scope | Fixes | Ships alone? |
|---|---|---|---|
| **P0** | Quick fixes with no new UI: `.withoutEscapingSlashes` everywhere tool JSON is serialized; the call label is the tool name plus its primary argument (`command`/`cmd`, then path, pattern, query, url, description; other keys leave the label and appear in P1's L2); label `web_search_call` from `action.query`; keep the Codex `namespace` in the tool name; count calls, not blocks, in the group header. Added by the plan: Codex `exec` labels show the script's first command; Codex content-item outputs become plain text at parse time; outputs of different call ids never merge (`canMerge`). | D6, D10, part of D3/D11 | Yes, in the next point release. |
| **P1** | Parser fields (§7) for all 17 sources (ids at least; Codex and Claude in full). Pairing by id for all sources (also fixes timing). `ToolInvocation`, L0/L1/L2 chrome **for every agent and every tool**. Two renderers: shell (Codex `exec` / `exec_command` / `write_stdin`, Claude `Bash`, and every agent's shell tool from §7.2) and the **generic fallback** (§6.3 "structured": key/value input, decoded output with decoders 1–6). Size budgets, status chips, Find on `plainText` (§6.8), plain-text form for Copy, corpus check (local run). No mixed old/new cards at any point. | D2–D5, D7–D10, the screenshot | Yes. Shell is about 80% of local calls; every other tool is already decoded and paired, only less specialised. |
| **P2** | read / edit / write / search / list renderers, command intent, diff renderer (apply_patch, structuredPatch, old/new, sidecar diffs), Claude dispositions (`rejected` as a shown row; P1 already pairs runtime-error blocks that carry a call id as failed outputs), process-poll collapse (needs `ToolInvocation.calls: [CallRef]`, one row for N poll calls, with Copy/Raw/Find covering all of them), ▲▼ stops per action inside a flattened batch row (P1 stops once per invocation row), the Codex `event_msg/item_completed` sidecar evaluation (§7.4), and the `<persisted-output>` Open link (P1 shows the fact without the link). | D12 | Yes |
| **P3** | plan / subagent / web / ask / image / structured-table renderers. Agent-specific envelope and sidecar rules for the other 15 sources. Text mode, export and search move to the new model (D1 closed). Corpus check in CI. | D1, D11 | Yes |
| **P4 (optional)** | ANSI colors, shell syntax tint, general "×N" repeat collapse, syntax highlighting in file panes. | — | — |

## 12. Decided by the owner (locked)

- From 4.2 and still binding: one unified style, no new toolbar controls, no token or cost badges, AS visual identity, no live pulse, no secret masking, Session/Text/JSON stay.

## 13. Calls made in this draft (owner to check)

- Batch calls (Codex code mode) **flatten** into one row per action. The script stays visible from any of its rows ("exec script · command 1 of 2" + Show script).
- Read-only shell commands get Read/Searched/Listed verbs (label only).
- grep-family exit 1 with no output is "no matches", not a failure.
- Failed rows open automatically; groups with failures open to L1.
- Error output shows its tail first.
- Agent truncation is a footer fact in orange, not a failure.
- One table row per invocation (recommended to the builder, not locked).
- User rejections show as grey rows (today they are hidden meta events).
- Consecutive polls of one process collapse into one row with a count (P2). This is the only merge before P4.
- P1 ships new chrome for every agent with a generic fallback renderer, so old and new cards never mix.
- Find matches decoded text (§6.8). Failed invocations count under the Errors filter.
- Encrypted Codex collaboration messages show a placeholder, never the ciphertext.
- Agent token counts from `toolUseResult` stay out (4.2 non-goal). Subagent call count and duration are shown.

## 14. Open questions for the owner

**Q1 — Row text when the agent wrote its own label.** 83% of Claude `Bash` calls carry a `description` ("Show job outcomes for the failed CI runs"). OpenCode, Grok, Hermes, Cursor and DSH send one too, and Antigravity, OpenCode, Copilot and Kimi send ready-made titles. Codex sends none. What does the L1 row show for a "Ran" action?
- (a) The command. The description goes to the tooltip and the L2 context line.
- (b) The description when there is one. The command is on the L2 first line and in the tooltip. This is the draft's recommendation.
- (c) The command, with the description as muted text after it when there is room.

Rows with intent verbs (Read, Searched, Edited…) are not affected: their object is the file or pattern. The answer changes the most common row, the VoiceOver string, `plainText`, and the golden snapshots.

_Answer (owner, 2026-11-04):_ **(b) Description.** For a "Ran" action with an agent label, the L1 object is the label, in the system font (prose, not monospace). The exact command is the first line of L2 and the row tooltip. Without a label (Codex, most others), the row shows the command in monospace. Intent-verb rows keep their file or pattern object. `plainText`, Copy Command and VoiceOver always include the command. The description is extra text and never replaces the command there. Precedence when several labels exist: the agent's `description` input key, then the ready-made title (`toolSummary`, `state.title`, `toolTitle`, `display`), then the command.
