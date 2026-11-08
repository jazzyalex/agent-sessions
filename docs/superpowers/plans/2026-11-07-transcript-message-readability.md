# Transcript Message Readability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every non-tool row in the Session view shows who it came from and reads as prose: only what the person typed is "You", injected context is hidden behind a Context toggle, harness events are one-line rows, and structured agent output is decoded.

**Architecture:** Parsers record provenance on `SessionEvent.messageOrigin` (Codex `content_item_kinds`, Claude `origin`/`isMeta`/`isCompactSummary`). `SessionTranscriptBuilder.coalesce` runs `MessageOriginClassifier` on every user and assistant block and stores a `MessagePresentation` (origin, body, one-line summary) on the block. The raw `LogicalBlock.text` never changes, so the Terminal view, search index and titles are untouched; only the Session view reads `presentation`.

**Tech Stack:** Swift, AppKit (`NSTableView`, TextKit 1), SwiftUI toolbar, XCTest.

**Spec:** `docs/superpowers/specs/2026-11-07-transcript-message-readability-design.md`

## Global Constraints

- `LogicalBlock.text` stays the raw text. New data goes in new fields only. The Terminal view, `SessionSearchTextBuilder`, titles and housekeeping must not change behavior.
- Never show `gAAAAA` ciphertext. Encrypted content reads "content encrypted in the log".
- Every new user-facing string uses `String(localized:comment:)`, is added to `AgentSessions/Resources/Localizable.xcstrings` with a zh-Hans translation, and the key count/SHA in `scripts/validate_localization_catalogs.py` (`EXPECTED_LOCALIZABLE_KEY_COUNT`, `EXPECTED_LOCALIZABLE_KEY_SHA256`) and the pin in `scripts/tests/test_validate_localization_catalogs.py:163` are updated in the same task. `python3 scripts/validate_localization_catalogs.py` exits 0.
- New Swift files are added with `scripts/xcode_add_file.rb` (exactly 4 pbxproj lines per target). `MessageOrigin.swift` joins both the app target and `AgentSessionsLogicTests` (build phase `C6E1291792690ED83FE18F6D`), like `ToolEventFields.swift`.
- Owner decisions: injected context is hidden, with a Context toggle that is off by default and remembered; sub-sessions stay their own rows in the session list.
- Classifier cost: heuristic/schema inspection uses at most 64 KiB of prefix/suffix data. Exact Codex citation normalization is an exception: one linear literal-tag pass over the full assistant text, never pairing edges across an uninspected gap. Release open time (the 6.4 gate method in `RepoHandover.md`) for Codex 78 MB and Claude 45 MB stays within 1.05x of `main` 4d8e36b9.
- Work happens in the current checkout and branch, as explicitly authorized by the owner. No branch/worktree creation or automatic commits. A later owner-requested commit uses Conventional Commits and the repository-required Tool, Model and Why trailers.
- Focused tests per task; a full stable suite and active-scheme build before completion. Inspect XCResult totals and explain test-name inventory changes. Xcode cache access requires approved execution up front.

## Review Focus

1. A Codex user message whose content items mix `user.text` with context items: only the `user.text` items show, as "You" (test in Task 2).
2. A person's message that starts with an HTML-like tag (`<div>hi</div>`, `<details>`) stays "You" (test in Task 4).
3. Older Codex logs with no `content_item_kinds`: `<environment_context>`, `# AGENTS.md instructions for` and `<user_instructions>` blocks are context, and the first real prompt stays "You" (test in Task 4).
4. With Context off, Find counts no match inside hidden context, and the You ▲▼ never stops on a non-typed row; turning Context on shows the rows and Find recounts (test in Task 7).
5. A live session that appends an injected block shows no "You" row for it at any point (test in Task 6).

---

## Review corrections accepted for execution (2026-11-07)

- Preserve raw event kinds/text, block text and Terminal/search/title behavior. Add display text and encrypted-content metadata separately. Include parser-meta context/peer records only in the Session projection; key the coalescing cache by that projection.
- Oversized JSON may use an explicit localized code presentation; oversized peer transport uses an explicit bounded preview, never an uninspected potentially encrypted tail. Ordinary user/agent prose remains complete.
- Typed provenance wins over text heuristics, including quoted environment/system tags. Envelope decoding is independent of selecting origin. Unknown mixed provenance never becomes a typed row.
- Child detection uses parent identity, not only an optional type, and selects the first eligible task after context.
- Timing and tool pairing share a typed-turn boundary. Duplicate groups retain all member targets.
- Corpus rules accept typed custom tags and summary-only line rows. Gallery names include a finding id and appearance to avoid overwrites.
- Session Find has a presentation text space and Context-aware cache key; raw/Terminal matching remains raw.

### Task 1: Origin model and plumbing

**Files:**
- Create: `AgentSessions/Model/MessageOrigin.swift` (app + `AgentSessionsLogicTests`)
- Create: `AgentSessions/Services/MessageOriginClassifier.swift` (app)
- Modify: `AgentSessions/Model/SessionEvent.swift:12-37`, `AgentSessions/Services/SessionTranscriptBuilder.swift:288-343` (`LogicalBlock`, `block(from:)`), `:541-590` (`coalesce`), `:630-641` (`splitTurnAbortedBlocks.makeBlock`)
- Test: `AgentSessionsTests/MessageOriginClassifierTests.swift` (new)

**Interfaces:**
- Produces:
  ```swift
  enum MessageOrigin: Codable, Equatable, Sendable {   // Codable: SessionEvent is Codable
      case typed
      case context(kinds: [String])
      case notification(kind: String)
      case peer(from: String)
      case compaction
      case skill(name: String)
      case command(name: String)
      case scheduled(kind: String)
      case harnessRetry
      case parentTask
      case approvalRequest
      case approvalVerdict(outcome: String)
      case placeholder
      /// context, skill, harnessRetry: hidden unless the Context toggle is on.
      var isHiddenContext: Bool { get }
  }
  enum MessageRowStyle: Equatable, Sendable { case card, line, none }
  struct MessagePresentation: Equatable, Sendable {
      var origin: MessageOrigin?   // nil on an assistant block = the agent's own message
      var body: String             // what the Session view draws, copies and searches
      var summary: String?         // the one-line text of a `.line` row
      /// The row style the Session view uses (depends on origin and body).
      var rowStyle: MessageRowStyle { get }
  }
  // SessionEvent:   var messageOrigin: MessageOrigin? = nil   (parser provenance)
  //                 var messageDisplayText: String? = nil
  //                 var messageHasEncryptedContent: Bool? = nil
  // LogicalBlock:   var messageOrigin: MessageOrigin? = nil   (copied from the event)
  //                 var presentation: MessagePresentation? = nil
  enum MessageOriginClassifier {
      struct Context { var source: SessionSource; var subagentType: String?; var parentSessionID: String?; var isFirstUserBlock: Bool }
      static func presentation(for block: SessionTranscriptBuilder.LogicalBlock,
                               context: Context) -> MessagePresentation?
  }
  ```
- `rowStyle`: `.card` for origin nil (agent), typed, peer with a non-empty body, parentTask, approvalRequest, approvalVerdict, command; `.line` for context, notification, peer with an empty body, compaction, skill, scheduled, harnessRetry; `.none` for placeholder.
- In Task 1 `presentation(for:context:)` returns `nil` for tool kinds; for `.user` it returns `messageOrigin ?? .typed` with `body = text`; for `.assistant`, origin nil and `body = text`. Later tasks add the rules.

- [x] **Step 1: Write the failing tests** in `MessageOriginClassifierTests`:
  - `testUserBlockDefaultsToTyped`: a `.user` block "hello" → `presentation?.origin == .typed`, `body == "hello"`, `summary == nil`.
  - `testCoalesceCopiesProvenanceAndSetsPresentation`: a session with one `.user` event whose `messageOrigin = .context(kinds: ["x"])` → `coalescedBlocks(...)[0].messageOrigin == .context(kinds: ["x"])` and `.presentation?.origin == .context(kinds: ["x"])`.
  - `testTurnAbortedSplitKeepsProvenance`: a user event with `messageOrigin = .typed` and text "hi<turn_aborted>x</turn_aborted>" → the remaining `.user` block keeps `.typed`.
  - `testToolBlocksHaveNoPresentation`.
  - `testRowStyles`: presentations with origin `.typed` → `.card`, `nil` → `.card`, `.context(kinds: [])` → `.line`, `.placeholder` → `.none`, `.peer(from: "a")` with body "x" → `.card` and with body "" → `.line`; `isHiddenContext` is true for context, skill and harnessRetry and false for notification.
- [x] **Step 2: Run** `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/MessageOriginClassifierTests`. Expected: compile failure (types missing).
- [x] **Step 3: Implement** the types and fields. `coalesce(session:)` passes `session.subagentType` and `session.parentSessionID`; `coalesce(events:source:subagentType:includeMeta:)` sets `presentation` for `.user`/`.assistant` blocks after merging (a merged assistant chain is classified once, on its final text, in the index-assignment pass). `isFirstUserBlock` is true for the first eligible non-context user task. A Session-only `includeMessageContext` projection retains provenance-carrying `.meta` records; its cache key includes that option. Default raw/Terminal coalescing still drops the same meta records as before.
- [x] **Step 4: Run** the same command. Expected: PASS. Full-suite validation runs at final integration.
- [x] **Step 5: Checkpoint** changes and validation in the execution ledger; no commit without owner instruction. Suggested later subject: `feat(transcript): message origin model on transcript blocks`.

### Task 2: Codex provenance

**Files:**
- Modify: `AgentSessions/Services/SessionIndexer.swift:3074` (`parseLine`), `:3134-3148` (text from `content[]`), `:3239` (kind)
- Test: `AgentSessionsTests/MessageOriginParserTests.swift` (new; Codex part)

**Interfaces:**
- Consumes: `MessageOrigin` (Task 1).
- Produces: Codex `SessionEvent.messageOrigin` for `response_item` `message` (user role) and `agent_message`.

Rules:
- `internal_chat_message_metadata_passthrough.content_item_kinds` (strings; the kind is the part before `" | "`). When present on a user message: every kind `user.text` → `.typed`. No `user.text` → `.context(kinds:)` (unique kinds, in order). Mixed provenance aligned to content items (including non-text items) → `.typed`, with a separate display-text field joining only typed text parts. Raw event/block text never changes. If alignment cannot be proven, use hidden `.context(kinds: ["codex.mixed.unresolved"])`; never label the combined text as typed. Test both valid non-text alignment and mismatches.
- `response_item` with `payload.type == "agent_message"` → preserve raw event kind `.meta`, set `messageOrigin = .peer(from: author)` where `author` is `payload.author` with the leading `/root/` removed (`"/root"` stays `"root"`); display text = the `input_text` payload parts only, with encrypted-content presence retained explicitly and the transport header removed. Preserve raw event text. The Session-only projection includes this record as a peer message; the raw/Terminal projection stays unchanged. `event_msg` `agent_message` stays `.meta` (older Codex mirrors the agent's reply there).
- Developer-role messages stay `.meta`.

- [x] **Step 1: Write the failing tests** (`parseCodexLine` helper as in `ToolEventFieldsParserTests.swift:14`):
  - `testCodexTypedUserText`: kinds `["user.text | x"]`, text "hi" → `.user`, `.typed`, text "hi".
  - `testCodexOpenPageIsContext`: kinds `["additional_content.codex_apps_open_page | …"]` → `.context(kinds: ["additional_content.codex_apps_open_page"])`.
  - `testCodexMixedKeepsOnlyTypedParts` (Review Focus 1): two text parts, kinds `["agents_md.instructions", "user.text"]`, texts "# AGENTS.md…", "do it" → `.typed`, display text "do it", raw text unchanged; also compare Terminal/search output before and after attaching provenance.
  - `testCodexAgentMessageIsPeer`: `{"type":"response_item","payload":{"type":"agent_message","author":"/root/history_competitors","recipient":"/root","content":[{"type":"input_text","text":"Message Type: MESSAGE\nSender: /root/history_competitors\nPayload:\n"},{"type":"encrypted_content","encrypted_content":"gAAAAA…"}]}}` → raw kind `.meta`, `.peer(from: "history_competitors")`, display body has no `gAAAAA` and the Session row explicitly labels encrypted content; raw text unchanged.
  - `testCodexEventMsgAgentMessageStaysMeta`.
  - `testCodexNoKindsLeavesOriginNil`. Add full parser-to-Session tests for older environment context, explicitly typed text quoting that tag, and raw/Session projection isolation.
- [x] **Step 2: Run** `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/MessageOriginParserTests`. Expected: FAIL.
- [x] **Step 3: Implement** in `parseLine`.
- [x] **Step 4: Run** the same command, with full-suite validation at final integration. Expected: PASS.
- [x] **Step 5: Checkpoint** changes and validation in the execution ledger; no commit without owner instruction. Suggested later subject: `feat(codex): read message provenance from content_item_kinds`.

### Task 3: Claude provenance

**Files:**
- Modify: `AgentSessions/Services/ClaudeSessionParser.swift:395` (`parseLineEvents`), `:529-566` (`flushTextIfNeeded`), `:714-732` (string content)
- Test: `AgentSessionsTests/MessageOriginParserTests.swift` (Claude part)

Rules (top-level fields of the `type:"user"` record; tool_result records untouched):
- `isCompactSummary == true` → `.compaction`.
- `origin.kind == "task-notification"` → `.notification(kind: "task")`.
- `origin.kind == "peer"` → `.peer(from: "another session")` (`origin.from` is an opaque id; the label names no id).
- `isMeta == true` and text starts with "Base directory for this skill:" → `.skill(name:)`, the name being the last path component of that line.
- other `isMeta == true` → `.context(kinds: ["claude.meta"])`.
- `origin.kind == "human"` → `.typed`.
- No field → `nil` (the classifier decides).

- [x] **Step 1: Write the failing tests** (`parseClaudeLines` helper, `ToolEventFieldsParserTests.swift:26`): one test per rule above, each asserting the event's `messageOrigin`; plus `testClaudeToolResultHasNoOrigin`.
- [x] **Step 2: Run** the Claude tests. Expected: FAIL.
- [x] **Step 3: Implement**; every event split from one record carries the record's origin.
- [x] **Step 4: Run** them, with full-suite validation at final integration. Expected: PASS.
- [x] **Step 5: Checkpoint** changes and validation in the execution ledger; no commit without owner instruction. Suggested later subject: `feat(claude): read message provenance from origin and isMeta`.

### Task 4: Classifier rules for every agent

**Files:**
- Modify: `AgentSessions/Services/MessageOriginClassifier.swift`
- Test: `AgentSessionsTests/MessageOriginClassifierTests.swift`

Order: guardian specialization, then explicit provenance, then source-specific fallback rules, then the generic rule. Explicit `.typed` provenance stays typed even when it quotes system/environment tags. Display-envelope decoding runs independently of origin selection; it must not be skipped merely because provenance exists. A rule that removes an envelope sets `body` to the inner text.

User blocks:

| Source | Text | Result |
|---|---|---|
| any | known short user-interrupt control marker, without explicit typed provenance | `.notification(kind: "interruption")`, summary "Request interrupted"; actual cancellation remains effective |
| any | only `<system-reminder>…</system-reminder>` elements | `.context(["system-reminder"])` |
| Codex | starts `<environment_context>`, `<user_instructions>`, `# AGENTS.md instructions for`, `<INSTRUCTIONS>` | `.context(["codex.preamble"])` |
| Codex | `<send_user_message_question_reply>[…]</…>` | `.typed`, body: for each item `**Question:** {question}\n\n**Answer:** {answer}` (no answer → "No answer") |
| Claude | starts `<task-notification>` or `[SYSTEM NOTIFICATION - NOT USER INPUT]` or `<side-sessions-event>` | `.notification(kind: "task")`, summary from `<summary>` and `<status>`: "Background task {status} · {summary}"; missing fields → "Background task update" |
| Claude | starts "Another Claude session sent a message:" / "The coordinator sent a message while you were working:" | `.peer(from: "another session")` / `.peer(from: "coordinator")`, body without that first line |
| Claude | `<command-name>/x</command-name>…` | `.command(name: "/x")`, body: the command name plus `<command-args>` text in a readable code fence; a command with empty args still identifies itself |
| Claude, Kimi | `<local-command-stdout>`, `<bash-input>`, `<bash-stdout>`, `<bash-stderr>` | `.command(name: "!")` or `.command(name: "output")`, body in a ```` ``` ```` fence |
| Claude | `<local-command-caveat>`, "Caveat: The messages below were generated" | `.context(["claude.caveat"])` |
| Grok | contains `<user_query>…</user_query>` | `.typed`, body = the query; no query and only `<user_info>`/`<rules>`/`<git_status>`/`<always_applied_workspace_rules>`/`<skills_referenced>` elements → `.context(["grok.context"])` |
| Cline | `<user_input mode="…">…</user_input>` | `.typed`, body = inner text |
| Cursor | starts `<timestamp>…</timestamp>` | `.typed`, body = the rest |
| Hermes | starts `[SYSTEM: You are running as a scheduled cron job` or `[IMPORTANT: You are running as a scheduled cron job` | `.scheduled(kind: "cron")` |
| Hermes | starts "You just executed tool calls but returned an empty response" | `.harnessRetry` |
| OpenClaw | starts `[OpenClaw heartbeat poll]` or "Read HEARTBEAT.md if exists" | `.scheduled(kind: "heartbeat")` |
| OpenClaw | starts `[cron:` or matches `^System: \[\d{4}-\d{2}-\d{2}` | `.scheduled(kind: "cron")` |
| OpenClaw | starts "Conversation info (untrusted metadata):" | `.context(["openclaw.metadata"])` |
| no provenance | the whole text is one or more elements whose tag names contain `_` or `-` and are not HTML names | `.context(kinds: [first tag])` |

Agent blocks:
- Empty after trimming, "(empty)" or "[REDACTED]" → `.placeholder`.
- Codex `<oai-mem-citation>…</oai-mem-citation>` and `<citation_entries>` removed from the body; when any were removed the body ends with `\n\n*Memory citations: N*`.
- The whole text parses as a JSON object → body is a list `- **key:** value`, nested values as one-line JSON.

`summary` for `.line` rows: context "Context · {kinds joined by ", "}", skill "Skill loaded · {name}", compaction "Conversation compacted", scheduled "Scheduled prompt · {kind} · {first line, 80 chars}", harnessRetry "Harness asked the agent to continue", peer with empty body "Message from {from} · content encrypted in the log". Strings live in `enum MessageOriginText` in the classifier file and are localized.

- [x] **Step 1: Write the failing tests**, one per table row (input text, source, expected origin, body or summary), plus:
  - `testHTMLLikeTypedTextStaysTyped` (Review Focus 2): `<div>hi</div>` and `<details>x</details>` with no provenance → `.typed`.
  - `testOldCodexPreambleIsContextFirstPromptTyped` (Review Focus 3): Codex blocks "<environment_context>…</environment_context>", "# AGENTS.md instructions for /x\n…", "fix the bug" with no provenance → context, context, typed.
  - `testCitationsStripped`, `testJSONAgentMessageAsFieldList`, `testPlaceholders`.
  - `testNoCiphertextInAnyBody`: a peer text with `gAAAAA` + 40 chars → body has no `gAAAAA`.
- [x] **Step 2: Run** `MessageOriginClassifierTests`. Expected: FAIL.
- [x] **Step 3: Implement**; add the strings to the catalog with zh-Hans and update both count pins.
- [x] **Step 4: Run** the tests, the validator, with full-suite validation at final integration. Expected: PASS, validator exit 0.
- [x] **Step 5: Checkpoint** changes and validation in the execution ledger; no commit without owner instruction. Suggested later subject: `feat(transcript): classify injected and harness messages for every agent`.

### Task 5: Sub-sessions and the Codex guardian

**Files:**
- Modify: `AgentSessions/Services/MessageOriginClassifier.swift`
- Test: `AgentSessionsTests/MessageOriginClassifierTests.swift`

Rules (`context.subagentType` plus `context.parentSessionID`):
- `"guardian"`, user block containing `>>> APPROVAL REQUEST START` → `.approvalRequest`. The planned action is the JSON after the line `Planned action JSON:` and before `>>> APPROVAL REQUEST END`. Body:
  ```
  **{tool}** · `{cwd}`

  ```sh
  {script}
  ```

  **Justification:** {justification}
  Sandbox: {sandbox_permissions}
  ```
  `script`: when the argv has exactly three items, `command[0]` ends with `sh` and `command[1]` is `-c` or `-lc`, `command[2]`; otherwise the arguments joined with POSIX quoting. Unparsable JSON → the raw text between the markers in a fence.
- `"guardian"`, any other user block → `.context(kinds: ["guardian.history"])`.
- `"guardian"`, agent block that parses as JSON with an `outcome` key → `.approvalVerdict(outcome:)`, body `**{Allowed|Denied|outcome}** · risk {risk_level} · user authorization {user_authorization}\n\n{rationale}`.
- Any other child session, detected from `parentSessionID` OR `subagentType`, first eligible non-context user task → `.parentTask`. An earlier context block does not consume the first-task position. Test a Claude child with no sidecar/type.

- [x] **Step 1: Write the failing tests** with the real marker layout (items joined): `testGuardianRequestCard` (asserts the body contains "```sh", "python3 - <<'PY'" with real line breaks, "**Justification:**"), `testGuardianHistoryIsContext`, `testGuardianVerdictCard` (`{"risk_level":"low","user_authorization":"high","outcome":"allow","rationale":"r"}` → `.approvalVerdict(outcome: "allow")`, body starts "**Allowed** · risk low"), `testGuardianBadJSONFallsBackToFence`, `testSubagentFirstUserBlockIsParentTask`.
- [x] **Step 2–4:** run (FAIL), implement with catalog strings, run the tests, validator and full suite (PASS).
- [x] **Step 5: Checkpoint** changes and validation in the execution ledger; no commit without owner instruction. Suggested later subject: `feat(transcript): readable guardian requests and verdicts`.

### Task 6: Row emission and turn timing

**Files:**
- Modify: `AgentSessions/ToolRendering/TranscriptToolRows.swift:111-150` (`emit`), `AgentSessions/Views/TranscriptBlockListView.swift:13-27` (`TranscriptRoleFilter.governing`), `:39-110` (`BlockRowModel`), `AgentSessions/Services/TranscriptTurnTiming.swift:54-103`, `AgentSessions/ToolRendering/ToolInvocationPairing.swift` (shared typed-turn boundary)
- Test: `AgentSessionsTests/TranscriptToolRowsTests.swift`, `AgentSessionsTests/TranscriptTurnTimingTests.swift`

**Interfaces:**
- Produces: `emit(..., showsContext: Bool)` (new parameter, default `false`); `BlockRowModel.repeatCount: Int` (default 1) and the complete represented block-index list; `static func governing(_ block: LogicalBlock) -> TranscriptRoleFilter?` (typed user → `.user`; agent and `approvalVerdict` → `.assistant`; `.error` → `.errors`; tools → `.tools`; every other origin → `nil`, always shown).

Rules:
- `.placeholder` blocks emit no row.
- `isHiddenContext` blocks emit a row only when `showsContext`.
- Adjacent message rows with equal `presentation` (origin and body) and no other row between them become one row with `repeatCount` = their number.
- A turn starts only at a `.typed` user block. Share the predicate with `ToolInvocationIndex`; injected context/peer/notification blocks must not clear pending parallel calls. Test two calls without IDs, an injected notice, then two outputs (FIFO associations retained). The duration chip never anchors on a user row: it anchors on the turn's first agent row, and a turn with no agent row has no chip.

- [x] **Step 1: Write the failing tests:**
  - `testPlaceholderEmitsNoRow`, `testHiddenContextFollowsToggle` (rows with `showsContext` false vs true), `testAdjacentDuplicatesCollapse` (3 equal user rows → 1 row, `repeatCount == 3`), `testDuplicatesAcrossToolGroupStaySeparate` (user, tool group, same user → 2 message rows).
  - `testUserFilterHidesOnlyTypedRows`: with `.user` off, a `.notification` row still shows.
  - `testLiveAppendOfInjectedBlockNeverShowsYou` (Review Focus 5): the `TranscriptToolCellsTests` harness `replace(_:)` appends a Codex block with `messageOrigin = .context(...)`; no row with origin `.typed` exists for it.
  - Timing: `testContextBlocksDoNotStartTurns`, `testNoChipOnUserRows`.
- [x] **Step 2–4:** run (FAIL), implement, run the targeted tests and reserve the full suite for final integration. Existing role-filter, windowing and timing tests stay green; update an expectation only where the spec changes it, and say which in the commit body.
- [x] **Step 5: Checkpoint** changes and validation in the execution ledger; no commit without owner instruction. Suggested later subject: `feat(transcript): hide context, collapse repeats, typed-only turns`.

### Task 7: Session view: labels, line rows, Context toggle, Find and jumps

**Files:**
- Modify: `AgentSessions/Views/TranscriptBlockListView.swift` (`BlockCardHeader` :5564, `BlockCardCellView.configure` :4978, `renderedBody(for:)` :2304, `measuredHeight` :2067, `apply(...)` :1321, `handleRoleJumpIntent` :3619, `matchesUnderActiveRoleFilter` :3873), `AgentSessions/Services/TranscriptDerivedState.swift:424-460` (Find over `presentation.body`), `AgentSessions/Views/TranscriptPlainView.swift:627-628, 1313-1325, 1598-1610, 1533-1536`
- Create: `AgentSessions/Views/TranscriptOriginLineCell.swift` (app)
- Test: `AgentSessionsTests/TranscriptBlockWindowingTests.swift`, `AgentSessionsTests/TranscriptDerivedStateTests.swift`, `AgentSessionsTests/TranscriptToolCellsTests.swift`

**Interfaces:**
- Consumes: `presentation`, `rowStyle`, `emit(showsContext:)`, `repeatCount`, `governing(_:)`.
- Produces: `TranscriptBlockListView(showsContext: Bool)`; `@AppStorage("SessionShowContext") var showsContext = false` in `TranscriptPlainView`; `final class TranscriptOriginLineCell: NSTableCellView, TranscriptRowCell`.

Behavior:
- Card header label by origin: typed "You", agent "Agent", peer "Message from {from}", parentTask "Task from parent session", approvalRequest "Approval request", approvalVerdict "Guardian verdict", command "Command". `repeatCount > 1` adds "×N". User rows show no duration. The card draws `presentation.body` through `MarkdownBodyRenderer`; copy uses the body.
- `.line` rows: one line, secondary color, a disclosure chevron when the body is not empty; click opens the body below the line (rendered as Markdown, same width as cards); state kept per block index like invocation open state. Height: 22 pt closed.
- The Context chip sits after the role chips in `toolbarTopRow`, a plain toggle (not part of the focus-then-restore-all role behavior), help text "Show text the agent's harness added: instructions, environment, skill files".
- Find searches `presentation.body ?? text`, skips `.placeholder`, and skips hidden context when the toggle is off. Toggling recomputes matches.
- Every represented duplicate block maps to the surviving row for Find, highlights, role jumps and external jumps. Define counts over shown rows and test duplicate navigation and window edges. Find opens a closed origin-line body containing its navigated match and maps presentation-source UTF-16 ranges through the Markdown renderer.
- The You ▲▼ stops only on `.typed` rows that are shown.
- The user role filter's count (`roleOccurrenceCount`) counts typed rows only.

- [x] **Step 1: Write the failing tests:**
  - `testHeaderLabelsByOrigin` (configure a cell per origin, read the header label), `testRepeatBadge`, `testUserRowHasNoDurationChip`.
  - `testLineRowOpensBody` (harness: click the chevron, the row height grows and the body text is in the cell).
  - `testFindSkipsHiddenContextUntilToggled` and `testYouJumpSkipsNonTyped` (Review Focus 4), plus duplicate-member Find/jump resolution, closed-line Find reveal, presentation UTF-16 highlighting, and raw/Terminal matching parity.
  - `testCopyUsesPresentationBody` (Cline block copies the inner text, not `<user_input>`).
- [x] **Step 2–4:** run (FAIL), implement with catalog strings, run targeted tests, validator and full suite (PASS).
- [x] **Step 5: Checkpoint** changes and validation in the execution ledger; no commit without owner instruction. Suggested later subject: `feat(transcript): origin labels, one-line harness rows and a Context toggle`.

### Task 8: Message corpus check

**Files:**
- Modify: `AgentSessionsTests/TranscriptToolCorpusCheckTests.swift` (replace the uncommitted `testMessageCorpusAudit` extension with the committed check)

**Interfaces:**
- Consumes: everything above; the file's own discovery (`candidates`, `maxSessionsPerSource`).
- Produces: `testMessageCorpusReadability()` gated by `AS_TOOL_CORPUS_CHECK=1`, report `scripts/probe_scan_output/message_corpus/report.json` (counts, source, file or id, block index, invariant; never message text).

Invariants on the rows `emit` produces with default filters and `showsContext == false`, failing per source:
- M1 no row with origin `.typed` whose block has non-nil provenance other than `.typed`;
- M2 no shown harness-origin row retains a known undecoded transport envelope; explicitly typed custom XML/HTML is permitted;
- M3 no shown agent row whose body parses as a JSON object;
- M4 cards have nonempty bodies; line rows have nonempty summaries (encrypted peers may have an empty body);
- M5 no two adjacent message rows with equal presentation;
- M6 (report only) every Codex `content_item_kinds` value and Claude `origin.kind` seen, with counts, and those the classifier does not name explicitly.

- [x] **Step 1: Write the check** and run `AS_TOOL_CORPUS_CHECK=1 ./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/TranscriptToolCorpusCheckTests/testMessageCorpusReadability`. Expected: PASS with 0 in M1–M5 across all sources with local sessions. Fix a failure in the task that owns the rule, and re-run until it passes.
- [x] **Step 2: Run** the tool corpus check too (`testToolCorpusReadability`). Expected: still 0 violations.
- [x] **Step 3: Checkpoint** changes and validation in the execution ledger; no commit without owner instruction. Suggested later subject: `test(transcript): message readability corpus check`.

### Task 9: Render gallery, performance gate, docs

**Files:**
- Modify: `AgentSessionsTests/TranscriptToolCorpusCheckTests.swift` (add `testMessageRenderGallery`, same gate)
- Modify: `docs/CHANGELOG.md` (`[Unreleased]`), `docs/summaries/2026-11.md`, `RepoHandover.md`, the spec's Decisions section

- [x] **Step 1: Gallery.** For each spec finding row, take the first matching block from the local corpus, build its window with the `TranscriptToolCellsTests` harness pattern (`BlockTableController`, offscreen `NSWindow`, width 900), and write the visible rect as PNG to `scripts/probe_scan_output/message_gallery/<finding-id>-<agent>-<origin>-<appearance>.png`, light and dark. Run it; expected: one pair of PNGs per finding row with local data, listed in `index.txt`.
- [x] **Step 2: Performance.** Release open time for Codex 78 MB and Claude 45 MB against `main` 4d8e36b9, the 6.4 method in `RepoHandover.md`. Expected: end-to-end ratio ≤ 1.05 for both.
- [x] **Step 3: Docs.** CHANGELOG `[Unreleased]` Highlights: one entry ("Only what you typed is 'You'…"). Bug Fixes: only defects present in 6.4 (fake "You" messages, raw XML and JSON, empty agent rows, `0.0s` on user rows). Handover entry with state, numbers and the gallery path for owner review.
- [x] **Step 4: Checkpoint** changes and validation in the execution ledger; no commit without owner instruction. Suggested later subject: `docs(transcript): message readability changelog and handover`.

Task 9 final evidence (2026-11-07): final gallery 1/1, 72 real PNGs covering all 23 base findings; two additional duplicate subcases have scoped no-local-data. Native Release ratios against 4d8e36b9: Codex 0.927394, Claude 1.001546, both <=1.05. Final full suite: 4,484 total /4,475 passed /9 skipped /0 failed, exact bundle `.deriveddata-tests/Logs/Test/Run-AgentSessions-2026.11.07_22-32-52--0800.xcresult`, exported `.superpowers/sdd/2026-11-07-transcript-message-readability/final-full-suite-summary.json`. Declaration inventory adds 129 methods and removes none; three additional opt-in skips explain the total/pass delta. Builds, localization validator (1,640 app +6 InfoPlist keys, zh-Hans coverage), 27 Python checks and diff check passed. Owner gallery acceptance remains pending; no commit/merge/release was requested.
