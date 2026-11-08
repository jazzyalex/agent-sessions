# Transcript message readability — findings and design

Status: implemented and validated locally in the current checkout, 2026-11-07; owner gallery acceptance remains pending. Execution corrections below preserve raw transcript behavior.

## Why

The 6.4 tool view fixed tool calls only. The original request was wider: every block in the
Session view, for every agent, must be readable. The owner's screenshots after 6.4 show the gap:

- A Codex Desktop session shows two "You" messages the owner never typed:
  `<external_codex_apps_open_page>{"page_id":null}</external_codex_apps_open_page>` and a
  "Companion Page snapshot". Codex Desktop itself does not show them.
- A Codex guardian sub-session shows a raw approval request (a Python heredoc with `\n`
  escapes, flowed as prose with stray links) and a raw JSON verdict as the agent's message.

The P0/P1 spec audited tool blocks only. Message blocks (user, agent, error) were never audited.

## Audit

Method: a gated, read-only pass over the newest local sessions of every agent, through the
app's own parsers and `SessionTranscriptBuilder.coalescedBlocks(includeMeta: false)` — the
exact block stream the Session view draws. 919 sessions, 15 agents (Devin and fx have no local
sessions). Output: `scripts/probe_scan_output/message_audit/audit.json` (git-ignored).

### Root causes

1. **Provenance is ignored.** Both main agents label every message's origin, and the parsers
   drop the label:
   - Codex: `internal_chat_message_metadata_passthrough.content_item_kinds`. Only `user.text`
     is typed by the person. Seen with the user role: `environments.environment_context`,
     `agents_md.instructions`, `additional_content.codex_apps_open_page`,
     `additional_content.codex_apps_selected_page_part_N_of_M`, `goal.internal_context`.
     Sub-sessions carry `session_meta.source.subagent` (for example `{"other":"guardian"}`).
   - Claude: `origin.kind` (`human`, `task-notification`, `peer`), `isMeta` (skill loads,
     command caveats, peer messages) and `isCompactSummary` (the "continued from a previous
     conversation" summary).
2. **Text heuristics stand in for provenance.** `Session.looksLikeAgentsPreamble` is a fixed
   list of tags and phrases. Any new injection shows as "You". In the Session view the
   preamble set is used only to find the first prompt; a preamble block still renders as "You".
3. **Envelopes and structured text render as prose.** Wrapper tags, JSON-only agent messages
   and citation tags reach the Markdown renderer unchanged.
4. **Empty and repeated blocks render as rows.**

### Findings by agent

Counts are blocks in the audited sample.

| Agent | What shows today | Count | What it is |
|---|---|---|---|
| Claude | "You" with raw `<task-notification>` XML | 477 | background task finished (`origin.kind = task-notification`) |
| Claude | "You": `[SYSTEM NOTIFICATION - NOT USER INPUT]`, `<system-reminder>` | 170 | harness notices |
| Claude | "You": "Another Claude session sent a message", "The coordinator sent a message" | 172 | peer messages (`origin.kind = peer`) |
| Claude | "You": "This session is being continued from a previous conversation…" | 26 | compaction summary (`isCompactSummary`) |
| Claude | "You": "Base directory for this skill: …" + whole skill body | 28 | skill load (`isMeta`) |
| Claude | "You": `<command-name>`, `<local-command-stdout>`, caveats | 9 | slash command echo |
| Claude | empty agent blocks in the stream (thinking or tool-only turns) | 6,742 | each draws a header-only row: `TranscriptToolRows.emit` does not skip empty text (code reading; the gallery confirms) |
| Codex | "You": `<external_codex_apps_open_page>`, selected-page snapshot | 62 | Codex Desktop page context |
| Codex | "You": `<send_user_message_question_reply>[{"questionItemId":…}]` | 15 | the owner's answer to an agent question, as JSON |
| Codex | agent text with `<oai-mem-citation>`/`<citation_entries>` tags | 76 | memory citations Codex Desktop renders as chips |
| Codex | guardian sub-session: history replay and approval request as "You", JSON verdict as agent | 4+ | auto-approval reviewer |
| Codex | `agent_message` records (messages between agents) | not shown | parsed as `.meta`, so dropped from the view |
| Grok | "You": `<user_query>…</user_query>`, `<user_info>`, rules, `<system-reminder>` | 53 | typed text in an envelope, plus context |
| Cline | "You": `<user_input mode="act">…</user_input>` | 26 | typed text in an envelope |
| Cursor | "You": `<timestamp>Monday, Nov 2…</timestamp>` + text | 29 | typed text with a time prefix |
| Cursor | agent `[REDACTED]`, empty, consecutive duplicates | 70 | reasoning placeholder, noise |
| Droid, Kimi | "You": `<system-reminder>` | 40 | context |
| Kimi | "You": `<bash-input>`, `<bash-stdout>` | 2 | shell escape echo |
| Hermes | agent `(empty)`; "You": "You just executed tool calls but returned an empty response…" | 74 | harness retry nudge |
| Hermes, OpenClaw | "You": cron and heartbeat prompts (`[SYSTEM: You are running as a scheduled cron job`, `[OpenClaw heartbeat poll]`, `Conversation info (untrusted metadata):`) | 160+ | scheduler-sent prompts |
| Antigravity | empty agent blocks in the stream | 134 | each draws a header-only row: `TranscriptToolRows.emit` does not skip empty text (code reading; the gallery confirms) |
| OpenCode, OpenClaw, Hermes | consecutive identical blocks | 50+ | repeated rows |
| All | user rows show a duration (`0.0s`) | — | meaningless on a person's message |

Copilot, DeepSeek harness, Pi and Qwen had no message-level findings beyond the shared ones.

## Design

### 1. Message origin

Every non-tool block gets an origin, set by the parser from provenance first and by envelope
rules second:

| Origin | Shown as |
|---|---|
| `typed` | "You" message, envelope removed (Cline `<user_input>`, Grok `<user_query>`, Cursor `<timestamp>` → the time moves to the header) |
| `context(kinds)` | hidden by default (owner decision, 2026-11-07); with the Context toggle on, one quiet collapsed line, "Context · AGENTS.md, environment, open page", that opens to the raw text |
| `notification(kind)` | one system line from the parsed fields: "Background task completed · Run the full test suite · exit 0" |
| `peer(from)` | a labelled card: "Message from *session*", collapsed past 6 lines |
| `compaction` | one line, "Conversation compacted", that opens to the summary |
| `skill(name)` | one line, "Skill loaded · deploy", that opens to the body |
| `command(name)` | a command row: `/compact` with its output in a pane |
| `scheduled(kind)` | "Scheduled prompt · cron" card, collapsed past 6 lines |
| `harnessRetry` | one dim line: "Harness asked the agent to continue" |

**Context toggle (owner decision: hidden with a toggle).** A "Context" toggle beside the role
filters, off by default. It is its own setting (`SessionShowContext`), not a
`TranscriptRoleFilter` case: the role chips focus one role and restore all on a second click,
and "all" must not turn Context on. It governs
`context`, `skill` and `harnessRetry` blocks: text the harness gave the model, not events of
the session. The choice is remembered across sessions. With it off, these blocks draw no row,
Find skips them, and ▲▼ never stops on them, like any other filtered role. Notifications,
peer messages, compaction, commands and scheduled prompts stay visible: they are events the
reader needs to follow the session. (Which origins the toggle covers is the implementer's
call, recorded here.)

Provenance sources:

- Codex: `content_item_kinds` (`user.text` → `typed`; everything else → `context`, by kind),
  `agent_message` records → `peer`, `<send_user_message_question_reply>` → `typed` drawn as
  question and answer.
- Claude: `origin.kind` (`human` → `typed`, `task-notification` → `notification`,
  `peer` → `peer`), `isCompactSummary` → `compaction`, `isMeta` skill bodies → `skill`,
  command tags → `command`, `<system-reminder>`-only text → `context`.
- Other agents: a per-agent envelope table in the adapter (the registry already owns
  per-agent rules), plus `<system-reminder>`.
- Unknown: a user block containing only XML-style elements whose names contain `_` or `-`,
  are not HTML names, and have no explicit provenance becomes `context`. Explicit typed
  markup and ordinary HTML remain user messages.

### 2. Sub-sessions

A session with `source.subagent` (Codex) or a reviewer/sub-agent launch (Claude) opens with a
"Task from parent session" card instead of a "You" message. The Codex guardian gets a
dedicated view: the request card (action, the command decoded into a code pane, cwd,
justification, sandbox) and the verdict card (outcome badge, risk, user authorization,
rationale). The history replay is context.

### 3. Agent messages

- JSON-only agent message: a field list (key column, value column), never raw JSON. Known
  schemas (guardian verdict) get their own card.
- Codex citation tags are removed from the text; a footer shows "Memory · 3 citations".
- Empty, `(empty)` and `[REDACTED]` blocks draw no row.
- Consecutive identical blocks of one kind draw one row with "×N".

### 4. Header

User rows lose the duration. Agent rows keep it.

## Verification

- Extend the corpus check with message invariants, failing per agent:
  M1 no "You" row whose provenance is not `typed`; M2 no row whose visible text starts with
  an envelope tag; M3 no JSON-only agent text drawn raw; M4 no empty message row; M5 no
  consecutive duplicate rows; M6 no `content_item_kinds`/`origin` value the table does not
  map (report-only, so a new kind is seen the day it ships).
- A render gallery: one PNG per finding row above, drawn from real sessions through the real
  cells, for the owner to review before merge.

## Decisions

1. Injected context: hidden, with a Context toggle (owner, 2026-11-07).
2. Sub-sessions such as the guardian stay as their own rows in the session list, as today.
   Folding them under the parent is a session-list change, out of scope here (implementer's
   call; the owner can reverse it).
3. Plan rulings (2026-11-07, `docs/superpowers/plans/2026-11-07-transcript-message-readability.md`):
   scheduled prompts are one-line rows that open, not 6-line cards; a peer message is a full
   card, and a peer message whose content is encrypted in the log is a one-line row; a guardian
   block that holds an approval request shows only the request (its history part is context);
   Claude peer messages read "Message from another session" because `origin.from` is an opaque
   id.


### Execution corrections after source review (2026-11-07)

- Provenance and display text are separate from raw event text/kind and raw block text. The Session projection alone retains context and peer events that the raw parser classified as meta. Terminal rendering, raw search text, titles and housekeeping retain their existing inputs.
- Mixed Codex provenance aligns to all content items, including non-text items. Only proven typed parts enter the display body. A mismatch is hidden unresolved context, available through the Context toggle, rather than a fabricated You message.
- Explicit typed provenance wins over tag heuristics. Removing a known transport envelope is independent of assigning origin. Typed HTML and custom XML remain user messages.
- Child-session detection uses parent identity or subagent type; an absent Claude sidecar does not erase the parent-task origin. Preamble/context blocks do not consume the first eligible child task.
- Timing and invocation pairing share the typed-turn boundary. Injected notifications and peer messages do not reorder pending parallel outputs.
- Collapsed duplicates retain all block identities; Find and all jumps resolve them to the surviving row. Session Find searches presentation text, opens a navigated collapsed line, and includes Context state in its cache key. Raw/Terminal matching retains its raw text space.
- Corpus checks distinguish message cards from summary-only lines, permit explicitly typed markup, and verify known envelopes by origin. Gallery filenames include finding identity and appearance.

- Oversized structured data: JSON can use an explicitly labelled code presentation beyond the classifier budget. Peer transport uses a labelled bounded preview rather than exposing a potentially encrypted uninspected tail; the complete raw record is retained. Ordinary user and agent prose remains complete.
- Slash-command bodies include the command name as well as arguments, so `/compact` with no arguments remains identifiable.

- Citation cleanup may use a single exact linear literal-tag pass over complete Codex assistant text. Inferring pairs across unseen text can delete answer prose, so the bounded heuristic budget does not apply to that exact normalization; the end-to-end performance gate still applies.

- Corpus-discovered mixed Claude reminders: when original provenance is absent, complete leading `system-reminder` envelopes may be removed only if a nonwhitespace human tail is proven in the existing contiguous inspection window. The remaining tail is preserved verbatim. Explicit typed provenance keeps literal reminder markup; ambiguous or out-of-window prefixes remain unchanged. Reminder-only messages remain context.

- Session preamble membership reuses classified hidden-context origins for user blocks; raw/default snapshots keep the legacy full-text helper. Explicit typed instructions remain eligible for first-prompt navigation. This removed redundant scanning without altering classification, citation normalization or full message-group construction. The final native Release gate passes against pinned 6.4: Codex 0.927394, Claude 1.001546 (`scripts/probe_scan_output/message_perf/20261107-223109-comparison.json`).
- Gallery evidence covers all 23 original findings in 72 real-cell PNGs, with per-window light/dark appearances and context absence/expansion. Additional Cursor/Hermes duplicate subcases have scoped no-local-data under the strict adjacent-pair predicate; repetitions across tool or other structural boundaries do not qualify. Index and source evidence: `scripts/probe_scan_output/message_gallery/index.html` and `index.json`. Owner visual acceptance remains pending.

- Final integration validation passed: 4,484 total tests, 4,475 passed, 9 skipped, zero failures; 129 test declarations added and none removed. Exact result: `.superpowers/sdd/2026-11-07-transcript-message-readability/final-full-suite-summary.json`, from `.deriveddata-tests/Logs/Test/Run-AgentSessions-2026.11.07_22-32-52--0800.xcresult`; log `/tmp/message-readability-final-full-suite.log`. Three new opt-in checks account for the additional skips; the other six retain their recorded reasons. Current standalone Debug build, optimized native Release build-for-testing, localization validation and 27 Python checks passed. No commits or publication were requested.
