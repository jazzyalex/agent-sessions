# Backlog

Deferred, non-urgent work items. Each entry: what, where, why deferred, and the
decision if one was made. Newest on top.

## How to read this file

Every entry carries a stamp line directly under its heading:

```
  > **open** · sev: med · urg: low · verified 2026-08-14
```
(indented here only so this example does not show up in the index grep below.)

- **Status** — `open` (nothing shipped) · `partial` (some instances closed, the class is
  still live) · `done` (shipped — collapsed to a two-line tombstone) · `won't-do`.
- **sev** (severity) — what breaks while this stays unfixed:
  - `high` — wrong data shown, data loss, or a user-visible break with no workaround.
  - `med` — a feature is silently absent or degraded, or recovery needs a workaround the
    user would not guess.
  - `low` — cosmetic, latent/unwired, dead code, or a fixture/test gap.
- **urg** (urgency) — time pressure, which is *not* severity. A med-severity bug that a
  relaunch clears is low urgency; anything with a date attached (a contributor waiting, a
  vendor deprecation, a release) is high urgency even at low severity.
- **verified** — when the entry was last checked against the code. `—` means it has not
  been re-checked since it was filed. Entries rot: on 2026-08-14 two were found stale —
  one already fixed in full, one describing a bypass that had since landed. Re-verify
  before acting on an old date.

**Finding the hot ones.** There is deliberately no hand-maintained index here — that is the
same drift class the *Agent Source Plumbing* entry below is about. Derive it instead:

```bash
grep -n -B2 '^> \*\*\(open\|partial\|done\|won.t-do\)\*\*' docs/backlog.md
```

**Writing an entry.** Body fields, used as they apply: **What** · **Where** (file:line
links) · **Fix shape** · **Why deferred** · **Risk if wrong** · **To close**. Keep **Why
deferred** and **Risk if wrong** — they are what makes an old entry trustworthy months
later.

**Closing an entry.** Do not move it to another file. Collapse it to a two-line tombstone
(date, commit, test name) and delete the rest, or delete it outright when GitHub or the
CHANGELOG already records it. The `##` sections are areas of the codebase, not priorities.

---

## Cross-Surface Session Storage

### Cursor Desktop conversations are never discovered
> **open** · sev: med · urg: low · verified 2026-08-18

- **What:** the Cursor reader covers `~/.cursor/projects/**/agent-transcripts/**/*.jsonl`
  and `~/.cursor/chats/**/store.db`. Cursor Desktop also stores conversations in
  VS Code-style `state.vscdb` databases under
  `~/Library/Application Support/Cursor/User/` — `globalStorage/state.vscdb` plus one per
  workspace under `workspaceStorage/*/`. Nothing in the codebase mentions `vscdb`, so
  none of it is discovered. This is missing data, not a wrong label: sessions the user
  has that the app cannot show at all.
- **Measured 2026-08-18:** `globalStorage/state.vscdb` on the owner's machine holds
  **183 `composerData%` rows** in `cursorDiskKV`, alongside an `ItemTable`, with further
  per-workspace databases untouched. `grep -rn vscdb AgentSessions/` returns nothing.
- **Why this is not just "add a reader":** some modern Cursor Desktop agent windows may
  also write the `~/.cursor` stores, so path alone cannot say which surface produced a
  conversation. Assigning every `state.vscdb` record to "Desktop" would repeat the
  mistake already sitting in the Codex side-chat reader (see its own entry).
- **Investigation first:** run controlled Cursor sessions — one Desktop chat, one Desktop
  agent window, one IDE-pane session — recording every file created or changed *before*
  interpreting any schema. Establish which modes write `state.vscdb`, which write the
  `~/.cursor` pair, and whether an ID joins the two families.
- **Then:** document the `ItemTable` / `cursorDiskKV` records needed to reconstruct a
  conversation, add discovery and parsing for the proven families, and deduplicate
  deterministically against any matching `~/.cursor` session. Database access stays
  read-only and bounded; never depend on vendor UI state or a network call.
- **Risk if wrong:** double-counted sessions if the join is guessed, or a silent Desktop
  label on IDE-produced records.
- **To close:** sanitized fixtures per artifact family (including duplicate-ID and
  missing-companion cases), discovery tests proving each root is found independently,
  parser tests for joins and deduplication, and a coverage report listing discovered vs
  unparsed families so a new vendor path cannot disappear silently.

### Claude cross-root joins and deduplication were never certified
> **open** · sev: low · urg: low · verified 2026-08-18

- **What:** Claude writes to three roots — standard transcripts under
  `~/.claude/projects`, Desktop Code metadata under
  `~/Library/Application Support/Claude/claude-code-sessions`, and Cowork/local-agent
  transcripts in nested `.claude/projects` trees under
  `~/Library/Application Support/Claude/local-agent-mode-sessions`. All three are
  scanned. What has never been certified is the contract *between* them: whether a
  transcript plus its Desktop sidecar reliably becomes one session, what happens when
  the sidecar is missing, and whether a Cowork session stays independently discoverable
  when the standard root is absent.
- **Where:** `ClaudeSessionIndexer` already repairs surface and originator for sessions
  that arrive without them
  ([:671](../AgentSessions/Services/ClaudeSessionIndexer.swift:671)), which is the
  join working case-by-case rather than by a stated rule. `Session.claudeArchiveJoinKey`
  is the filename-UUID join used for the archive sidecar.
- **Why it matters less than the Cursor gap:** nothing is known to be missing or
  mislabelled today. The risk is a duplicate row or a dropped sidecar under
  combinations nobody has exercised — a correctness question without a reported symptom.
- **Investigation:** test standard CLI, Desktop Code and Cowork independently with the
  same task. Verify the transcript-to-sidecar join, missing-sidecar behavior, duplicate
  discovery across roots, surface-specific record types, and project/task attribution.
- **To close:** fixtures for each root including a missing-companion and a duplicate-ID
  case; tests proving one session results from a transcript plus sidecar, and that a
  Cowork session survives with no standard-root counterpart.

### CLI discovery cannot see a shell whose rc file requires a terminal
> **open** · sev: low · urg: low · verified 2026-08-18

- **What:** `CLIProbeEnvironment.discover()` asks the user's login shell for their PATH via
  `$SHELL -lic` with pipes for stdio. The child's stdin is therefore not a terminal, so an
  rc file guarded on `[ -t 0 ]` returns before loading its version manager. nvm-installed
  Node and any CLI installed under it stay invisible. (`[[ $- == *i* ]]` guards are fine —
  `-i` satisfies them; this is specific to the tty test.)
- **Verified:** `zsh -lic '[ -t 0 ] && echo yes || echo no' </dev/null` → `no`.
- **Mitigated, not fixed (2026-08-18):** `versionManagerPrefixes` now reads nvm's
  `~/.nvm/alias/default` and fnm's `aliases/default/bin` straight from disk, so the common
  installs are covered without a shell. Anything else those rc files would have added is
  still lost.
- **The real fix:** run the discovery shell on a pseudo-terminal (`openpty`) so `[ -t 0 ]`
  holds. Costs a pty pair per probe and needs the output drained off-thread; not worth it
  until someone reports a case the alias files miss.

### Codex `source: "vscode"` is not proof of VS Code
> **open** · sev: med · urg: low · verified 2026-08-18

- **What:** from cli_version ~0.126 Codex pins `originator` to "Codex Desktop" in every
  rollout regardless of surface, so the real surface has to come from `source`. That is
  now trusted for `cli` and `exec` — but **not** for `vscode`, because Codex Desktop
  writes that value too.
- **Evidence (owner's corpus, 1,735 rollouts, 2026-08-18):** 511 rollouts carry
  `source: "vscode"`, and **76 of them sit in Codex Desktop's own generated
  `~/Documents/Codex/<ISO-date>/<name>` chat workspaces** — the shape
  `CodexDesktopProjectClassifier.isGeneratedDesktopChatWorkspace` already treats as
  Desktop's signature. So `vscode` covers at least two surfaces. The remaining 435 have
  ordinary cwds and cannot be attributed either way from the file alone.
- **Why it is parked rather than "fixed":** promoting `source` for `vscode` the way it
  was promoted for `cli`/`exec` would relabel those 76 real Desktop sessions as VS Code
  *and* strip them from the "Codex Desktop Chats" grouping — one wrong answer swapped
  for another. `classifyCodexSurface` says this inline; do not "finish the reorder"
  without reading it.
- **Settled already (2026-08-18):** `cli` and `exec` sources now win over the pinned
  originator, correcting 161 sessions that showed as Desktop. Pinned by
  `CodexSurfaceClassificationTests`, including a test asserting that `vscode` does *not*
  get the same treatment.
- **The experiment that would close it:** run one Codex Desktop session and one VS Code
  extension session against the same ordinary repository folder, then diff the two
  rollout headers. Any field that differs is the discriminator. Record every file
  created or changed before interpreting schemas.
- **To close:** a field that separates Desktop from VS Code, or a documented finding that
  none exists and `.other`/`.unknown` is the honest classification for ambiguous rows.

---

## Marketing Surfaces

### Session-Bench needs an in-app surface, and it is not a changelog entry
> **open** · sev: low · urg: low · verified —

- **Where:** currently only the public pages — `docs/bench/` and the launch post. Nothing
  in the app references it.
- **What:** Session-Bench is a separate research/accountability project, **not an Agent
  Sessions feature.** It was briefly listed under "Improvements" in the 4.8 changelog
  (the v0.3 poster); that framing was wrong and the entry was removed. Release notes
  describe what changed in the app, and the poster changed a website.
- **Decision:** surface it in-app as a **chip**, not as a release-note line and not as a
  feature panel row. Design it deliberately rather than bolting it onto the next release.
- **Why deferred:** wants its own design pass on placement and wording; there is no
  deadline pressure and shipping it inside a release note would repeat the category error.

---

## Agent Source Coverage

### Codex 0.151 moved subagent identity off `agent_role` and 28% of badges went blank
> **open** · sev: med · urg: low · verified 2026-08-30

- **What:** in `session_meta.payload.source.subagent.thread_spawn`, Codex 0.151 leaves
  `agent_role` null and carries the identity in new siblings `agent_path`
  (`/root/git_migration_audit`) and `agent_nickname` (`Bernoulli`), alongside `depth`.
  **Measured 2026-08-30** over the 400 most-recently-modified rollouts: 287 `thread_spawn`
  subagents, **`agent_role` null on 80 of them (27.9%)**; `agent_nickname` present on
  **287/287**, `agent_path` on 79 of the 80. Surviving `agent_role` values are `explorer`
  (161), `worker` (26), `default` (20). Those 80 sessions nest correctly and render
  **unlabeled**.
- **Where:** `subagentType` is set only from `agent_role` at
  [SessionIndexer.swift:2040](../AgentSessions/Services/SessionIndexer.swift:2040),
  duplicated at [:2320](../AgentSessions/Services/SessionIndexer.swift:2320); the badge is
  gated on it at
  [UnifiedSessionsView.swift:4295-4303](../AgentSessions/Views/UnifiedSessionsView.swift:4295).
  `agent_path`, `subagent_history_start_ordinal`, `thread_source`, `multi_agent_version`
  and `forked_from_id` appear nowhere in `AgentSessions/`. **`agent_nickname` has exactly
  one reader —
  [CodexRunwayModel.swift:1899](../AgentSessions/CodexStatus/CodexRunwayModel.swift:1899) —
  so the Runway HUD names these subagents while the session list beside it shows them
  blank.**
- **Not the problem — do not build this:** the hierarchy already works. Children carry
  `source.subagent.thread_spawn.parent_thread_id`, already read at
  [SessionIndexer.swift:2039](../AgentSessions/Services/SessionIndexer.swift:2039) into
  `Session.parentSessionID` and nested by
  [SubagentHierarchyBuilder](../AgentSessions/Services/SubagentHierarchyBuilder.swift:57).
  The new `agent_thread_id` on `SubAgentActivity` items does resolve — 27 of 27 (100%)
  against real rollouts across 1782 files — but it is a redundant second path to a link
  the app already has.
- **Fix shape:** fall `subagentType` back to the last component of `agent_path`, then
  `agent_nickname`, when `agent_role` is null. Codex's `source.subagent` is decoded in
  **three** hand-maintained copies —
  [SessionIndexer.swift:2034](../AgentSessions/Services/SessionIndexer.swift:2034),
  [:2313](../AgentSessions/Services/SessionIndexer.swift:2313), and
  [CodexRunwayModel.swift:1980](../AgentSessions/CodexStatus/CodexRunwayModel.swift:1980),
  whose comment says it is *"Kept identical to SessionIndexer's two parse blocks"* — so
  extract one decoder and fix it once rather than patching three.
- **Risk if wrong:** `agent_thread_id` is **not** a child pointer. A child's transcript
  contains `SubAgentActivity` items naming its **parent** (`agent_path: "/root"`) — 11 of
  53 observed. Deriving edges from it without checking `agent_path` depth against the
  file's own thread id inverts those. Separately, `payload.session_id` on a child is the
  **parent's** uuid while `payload.id` is its own; that trap is already guarded at
  [Session.swift:758-763](../AgentSessions/Model/Session.swift:758) and must not be
  reintroduced. `agent_path` is absent pre-0.151, so it must be a fallback, never a
  requirement.
- **Why deferred:** the labeling fix is small but sits behind the three-way duplication,
  which is the actual work. The `SubAgentActivity` transcript-rendering half belongs with
  *Codex `item_completed` describes shell calls the transcript still renders raw* below —
  same event family, same `.meta` fall-through — and is low volume besides: 78 lines in 20
  of 1782 sessions. (The 2026-08-30 sweep first reported ~1561 lines in 70 of 119; that
  was a substring count of `agent_thread_id`, not a count of items. Corrected here.)
- **To close:** a 0.151 subagent row shows a name derived from `agent_path` /
  `agent_nickname` when `agent_role` is null; a pre-0.151 subagent still shows its
  `agent_role`; one decoder serves all three callsites. Fixture covers both the
  `agent_role: null` + `agent_path` form and the legacy form.

### Watch list from the 2026-08-21 format sweep
> **open** · sev: low · urg: low · verified 2026-08-30

- **Added by the 2026-08-30 sweep** (codex 0.151.0, claude 2.1.251) — all ruled *watch*,
  none earning a surface yet:
  - **Codex `world_state.payload.state.context_window_guidance`** — empty string in every
    observation, 11 of 119 sessions. The name suggests context-budget advice; promote if
    it ever carries text.
  - **Codex `persistent_mode` / `managed_developer_instructions`** — both empty `{}`, 11
    and 24 of 119 sessions. They surfaced as `unknown_types` only because an empty dict
    creates a fingerprint bucket with no keys; they are not new event types.
  - **Codex `subagent_history_start_ordinal`** — the parent-history position a child
    forked from, 10 of 119 sessions. Same family as the `ordinal` already parked here;
    only becomes interesting if a subagent transcript is ever rendered with its inherited
    prefix trimmed.
  - **Claude `attachment:deferred_tools_delta.failedMcpServers`** — would name which MCP
    servers failed to load, which a user would want. Empty `[]` in all 29 observations, so
    there is nothing to show yet. Promote on the first non-empty sighting.
  - **Claude `queue-operation.reason`** — single observed value `absorbed_mid_turn`, 56
    lines across 11 of 212 sessions. `queue-operation` already renders as `.meta`.
- **Settled 2026-08-30, do not re-open:** Codex
  `inter_agent_communication_metadata.ordinal` is the same `ordinal` already logged below,
  now appearing on one more record type — noise, not a second sighting worth promoting.
  Codex `agent_thread_id` was investigated as a hierarchy source and rejected: the app
  already reads `parent_thread_id`, so it is a redundant path (see the 0.151 badge entry
  above). Claude `user.queueSkipAttachments` is a plumbing bool, always `true`, 19
  observations — noise.
- **What:** fields upstream started emitting that are real but do not yet earn a surface.
  Recorded so they are not re-litigated at every sweep, and so a second sighting can
  promote one:
  - **Codex `results`** — web-search items with `title`, `url`, `snippet`, `domain`,
    `thumbnail_url`. Search results render anonymously today; promote if search turns
    become common.
  - **Codex `active_permission_profile`** — seen as `{id: ":danger-full-access"}` on
    `turn_context`. A permission state the UI hides; promote if it varies within a
    session.
  - **Codex `ordinal`** — now on every record (915 of 915 in the sample). A monotonic
    sequence number is a stronger ordering key than a timestamp; reach for it if
    transcript ordering ever proves unstable.
  - **OpenCode `part.patch`** — a `hash` plus the `files` a turn changed, but only 16 of
    ~8,900 parts. Too rare to build on; count again before promoting.
  - **Claude `user.turnCompanion`** — 6 records across 60 sessions, on skill-invocation
    turns. Too rare to read anything into.
- **Settled this sweep, do not re-open:** Antigravity's `truncated_fields` is **already
  handled** —
  [AntigravityTranscriptParser.swift:43](../AgentSessions/Services/AntigravityTranscriptParser.swift:43)
  reads it and marks the clipped text. It is a JSON array in all 39 records across 28
  local transcripts, so the existing `as? [Any]` cast is right. It surfaced as drift only
  because the baseline fixture lacks the key — a fixture refresh, not work. Noted because
  it read like a UI gap on first pass.
- **Noise, deliberately not filed:** Claude `atis-latch` (275 records, `atis` always
  empty), `batching_reminder_sent`, `silent_turn_reminder`, `total_tokens_reminder` — all
  harness nudges; Codex `internal_chat_message_metadata_passthrough.create_time`; Kimi
  `runtime.set_binding`.
- **To close:** each line is either promoted to its own entry on a second sighting, or
  deleted as settled noise.

### Grok session sidecars are neither watched nor read
> **open** · sev: low · urg: low · verified 2026-08-17

- **What:** a Grok session is a directory, and beyond `chat_history.jsonl` +
  `summary.json` it also holds `rewind_points.jsonl`, `events.jsonl`, `updates.jsonl`,
  `prompt_context.json`, `resources_state.json`, `signals.json` and `system_prompt.txt`.
  No fixture covers any of them, the schema fingerprint ignores them, and no Swift reads
  them — so upstream could restructure any one without the weekly scan noticing.
  Surfaced 2026-08-17 from a kept prebump sandbox.
- **Where:** [GrokSessionParser.swift](../AgentSessions/Services/GrokSessionParser.swift)
  and [GrokSessionDiscovery.swift](../AgentSessions/Services/GrokSessionDiscovery.swift)
  read the transcript and `summary.json` only; the weekly `local_schema` glob is
  `*/*/chat_history.jsonl`.
- **Two separate jobs, do not conflate:** (a) *monitoring* — decide which sidecars are
  load-bearing and add them to the fingerprint or to `required_companion_files`, the way
  `summary.json` already is; (b) *product* — `rewind_points.jsonl` is the interesting one,
  since it records the session's rewind history and nothing in the app exposes that.
- **Related, still open from 2026-08-13:** `subagents/<childId>/meta.json` (the only place
  `parent_session_id` / `subagent_type` appear, so the hierarchy feature depends on it)
  and the `compaction/` subtree.
- **To close:** each sidecar is classified as watched, deliberately ignored, or a feature
  candidate — with the ruling written down so this is not re-derived a third time.

### Image extraction for Kimi, Pi, Hermes and Cursor is wired but inert
> **open** · sev: low · urg: low · verified 2026-08-14

- **Where:** the per-source gates in
  [CodexSessionImagePayload.swift](../AgentSessions/Utilities/CodexSessionImagePayload.swift)
  and [ImageBrowserIndexCache.swift](../AgentSessions/Utilities/ImageBrowserIndexCache.swift),
  shipped in `da428bf3`.
- **What:** those four providers were pointed at the generic
  `Base64ImageDataURLScanner` alongside Grok, but nothing confirms they ever emit an
  inline image. Verified 2026-08-14: **zero** occurrences of `data:image/` across every
  local session tree for them — `~/.kimi-code` (26 files), `~/.pi` (5), `~/.hermes`
  (2,973 + 3 SQLite), `~/.cursor` (255 incl. 20 `store.db`) — text and binary alike.
  Independently, they take the conservative `isLikelyImageURLContext` filter, whose regex
  requires an unescaped `"image_url":` immediately before `"data:image`; the real Grok
  payload uses a bare `"url"` key, so even a Grok-shaped URI would be filtered out for
  these four.
- **Why deferred:** additive and harmless while inert, and there is nothing to verify
  against without a real session. If one of them references images by path or https URL
  instead of a data URI, it needs its own reader — the generic scanner will never find it.
- **Note:** the 4.8 changelog says the scanner is *extended* to them, deliberately
  avoiding a promise that images appear. Keep that wording honest if this is revisited.

---

## Transcript UI

### Copilot 1.0.82 emits reasoning blocks and the transcript shows none of them
> **open** · sev: med · urg: low · verified 2026-08-31

- **What:** Copilot 1.0.82 added `assistant.message.data.reasoningBlocks`, a
  `{provider, blocks[]}` object whose blocks are `{type: "thinking", thinking, signature}`.
  That is the model's reasoning text, delivered as first-class structured data on the
  assistant record. Nothing in `AgentSessions/` reads it, so the transcript renders the
  reply and silently drops the thinking that produced it — while Claude's equivalent
  thinking blocks *are* rendered, so the same user sees reasoning for one agent and not
  the other.
- **Where:** `reasoningBlocks` appears nowhere in `AgentSessions/`. It arrives on the
  `assistant.message` record that the Copilot path already parses for `data.content`, so
  this is an additional read on a record already being decoded, not a new discovery path.
- **Fix shape:** decode `blocks[]` where `type == "thinking"` and render it the way Claude
  thinking blocks are rendered today — collapsed by default, same styling — rather than
  inventing a Copilot-specific presentation. `provider` names which backend produced the
  reasoning and is worth showing on the block header when it is not the session's main
  model.
- **Risk if wrong:** `signature` is an opaque cryptographic attestation, not text — it
  must never be rendered. Reasoning content is also the most sensitive part of a
  transcript to surface by accident, so it should follow whatever collapse/redaction
  default the Claude thinking path already uses, not a looser one.
- **Why deferred / measure first:** only **2 records across the 13 local Copilot
  sessions**, because reasoning is model- and mode-dependent. That is thin evidence for a
  render path. Count again on a machine that uses Copilot heavily before building it —
  the `budget_usd` lesson.
- **To close:** a Copilot session carrying `reasoningBlocks` shows its thinking with the
  same affordance as a Claude session; `signature` never reaches the view; a session
  without the field is unchanged. Fixture covers a `thinking` block and an assistant
  record with no `reasoningBlocks` at all.

### Codex `content_item_kinds` states what the app currently guesses by string-matching
> **open** · sev: low · urg: low · verified 2026-08-30

- **What:** Codex now stamps `internal_chat_message_metadata_passthrough.content_item_kinds`
  — an array naming what a synthetic message actually contains — on
  `response_item.payload:message` and on each `compacted.payload.replacement_history`
  entry. **Measured 2026-08-30** across 1188 rollouts: 923 `message` records carry it, in
  29 files. Observed kinds include `agents_md.instructions` (34), `host_skills.instructions`
  (45), `environments.environment_context` (39), `collaboration_mode.instructions` (30),
  `permissions.instructions` (29), `multi_agent.mode_instructions` (29), plus `user.text`
  (149) and `unknown` (619) for ordinary turns. The app classifies these same blobs today
  by matching English strings.
- **Where:** `content_item_kinds` and `internal_chat_message_metadata_passthrough` appear
  nowhere in `AgentSessions/`. `role: "developer"` is absent from the role switch at
  [SessionEvent.swift:52-59](../AgentSessions/Model/SessionEvent.swift:52) so it reaches
  `return .meta` at [:61](../AgentSessions/Model/SessionEvent.swift:61) — the right answer
  by accident. `role: "user"` maps to `.user` at
  [:54](../AgentSessions/Model/SessionEvent.swift:54), and the only thing reclassifying a
  synthetic user blob is a literal sniff for `<environment_context>` at
  [SessionIndexer.swift:2504](../AgentSessions/Services/SessionIndexer.swift:2504). Title
  derivation runs a second, larger sniff —
  [`Session.looksLikeAgentsPreamble`](../AgentSessions/Model/Session.swift:610), ~15
  hardcoded anchors, called from six sites — while
  [`Session.listTitle`](../AgentSessions/Model/Session.swift:460) documents that it
  deliberately skips those heuristics.
- **Honest impact today: small.** Of the 34 `role: "user"` records carrying an
  `*.instructions` kind, **6** escape the `<environment_context>` sniff (2.7K–32K chars).
  Those 6 begin `# AGENTS.md instructions` / `<INSTRUCTIONS>`, which
  `looksLikeAgentsPreamble` *does* anchor on — so the second heuristic almost certainly
  catches them and little is visibly broken right now.
- **Fix shape:** the value is not fixing 6 titles, it is replacing ~15 hardcoded English
  anchors with a field upstream now states outright — before those anchors silently stop
  matching. Read `content_item_kinds`, use it to reclassify an instruction-bearing message
  to `.meta` regardless of `role`, and demote `looksLikeAgentsPreamble` to a pre-0.151
  fallback. Optionally give the collapsed meta block a real heading from its kinds instead
  of a dim JSON wall.
- **Risk if wrong:** the field is new, so every older session lacks it — it must
  *strengthen* the heuristics, never replace them, or older sessions lose preamble
  suppression entirely. Reclassifying too aggressively is the worse failure: `user.text`
  and `unknown` are the majority (768 of 923) and a message mixing `user.text` with an
  instruction kind contains real user words, so demoting it to `.meta` hides a prompt
  behind a toggle. Leave mixed messages on the `.user` path.
- **Not the noise call:** the watch list parks
  `internal_chat_message_metadata_passthrough.create_time` as deliberately-not-filed noise.
  This is different in kind — `create_time` duplicates a timestamp the app already has,
  whereas `content_item_kinds` is the only machine-readable signal for a classification the
  app currently performs with string matches that upstream can invalidate without notice.
- **To close:** a Codex session whose head carries `generic.developer_instructions` shows a
  labeled collapsed block; a `["user.text"]` message stays a user turn; a session predating
  the field still suppresses its preamble via the existing heuristics.

### Codex `memory_citation` names the prior sessions a turn cited
> **open** · sev: low · urg: low · verified 2026-08-21

- **What:** Codex 0.149's `item_completed` items can carry `memory_citation`, holding
  `entries` (`path`, `lineStart`, `lineEnd`, and a human `note`) and `rolloutIds` — the
  ids of the *other rollout sessions* this turn drew on. That is a session-to-session
  edge, and a session browser is the one surface positioned to render it; nothing else
  has both sessions on hand.
- **Where:** found 2026-08-21 in the weekly sweep. `memory_citation` and `rolloutIds`
  appear nowhere in `AgentSessions/`; the events arrive on the `event_msg` path and fall
  to `.meta`, so both survive in `rawJSON` unread.
- **Fix shape:** resolve `rolloutIds` against the session index and offer them as links
  from the citing turn — the index already keys sessions by id.
- **Why deferred:** only observed on 0.149+, so the corpus is one session deep. Confirm
  it appears in ordinary use before building navigation on it.
- **Risk if wrong:** an id that resolves to an unindexed or deleted rollout must degrade
  to plain text; a dead-end link is worse than no link.
- **To close:** a Codex turn that cited prior sessions offers navigation to them, and a
  fixture covers a citation whose `rolloutIds` are absent from the index.

### Codex `item_completed` describes shell calls the transcript still renders raw
> **open** · sev: low · urg: low · verified 2026-08-21

- **What:** Codex 0.149 added an `item_completed` event family — 264 records in the first
  local session that had it — whose items carry `parsed_cmd`, a structured read of the
  command (`{type: read, name: "SKILL.md", path: …}`), plus a per-call `duration`
  (`secs`/`nanos`). Tool rows show the raw command string and derive timing from
  timestamps.
- **Where:** `parsed_cmd`, `duration` and `item_completed` appear nowhere in
  `AgentSessions/`. The canonical stream is unaffected — `response_item.custom_tool_call`
  is still emitted (135 in the same session) and still maps to `.tool_call` at
  [SessionEvent.swift:32](../AgentSessions/Model/SessionEvent.swift:32) — so this is
  additive detail, not a parse break.
- **Fix shape:** label a tool row from `parsed_cmd.type` + `name` ("Read SKILL.md") with
  the raw command still reachable; feed `duration` to
  [TranscriptTurnTiming.swift](../AgentSessions/Services/TranscriptTurnTiming.swift).
  That is the same source-reported-vs-derived question as the Kimi `turn.ended` entry
  under *Kimi Code* — decide it once for both.
- **Risk if wrong:** `item_completed` is 0.149-only, so every older Codex session lacks
  it. The label must enhance the raw command, never replace it and leave older rows bare.
- **To close:** Codex tool rows show a parsed label where one exists and fall back
  cleanly where it does not.

### OpenCode parent sessions are unsearchable for their own subagent reports
> **open** · sev: low · urg: low · verified 2026-08-21

- **What:** an OpenCode `task` tool result carries the subagent's full report (8–12 KB
  each; 7 of them in one Triada session). `SessionSearchTextBuilder.build` caps a
  session's search text at 48 000 chars and walks events in order, so the parent's budget
  is spent on prompts/reasoning/`read` output before the task outputs are reached. A search
  for a phrase from the report hits only the child session, never the parent that
  commissioned it.
- **Where:** [SessionSearchTextBuilder.swift:164](../AgentSessions/Search/SessionSearchTextBuilder.swift)
  (the cap); task outputs are already unwrapped at parse time by
  `OpenCodeSessionParser.unwrapTaskOutput` (2026-08-21).
- **Fix shape:** give `task` results priority inside the budget (emit them first, or
  reserve a slice), or index them into `session_tool_io` for the parent.
- **Note:** search ingest is keyed on file mtime/size with no parser-version stamp, so the
  2026-08-21 unwrap fixes (OpenCode `task`, Qwen `{"output"}`, Hermes `delegate_task`)
  improve search text only for sessions (re)indexed after the change.
- **Why deferred:** recall gap only — the child session is searchable and nests under
  the parent in the list. Decided 2026-08-21 with the task-envelope fix.
- **Not doing:** exempting `task` cards from the 20-line "Show all" fold — one click,
  consistent with every other tool card; not worth four edit sites in
  `TranscriptBlockListView`.
- **To close:** searching a phrase that appears only in a subagent's report matches the
  parent session.

### MCP tool calls render anonymously though Codex now names the connector
> **open** · sev: low · urg: low · verified 2026-08-17

- **What:** Codex `mcp_tool_call_end` events gained `app_name`, `connector_id`,
  `action_name` and `link_id` (found 2026-08-17 sweeping 1209 local sessions). Every MCP
  tool row in the transcript currently shows the raw tool name with no indication of
  which connector ran it, even though the record now says.
- **Where:** the Codex tool-event path in
  [SessionTranscriptBuilder.swift](../AgentSessions/Services/SessionTranscriptBuilder.swift);
  none of the four keys appear anywhere in `AgentSessions/`.
- **Fix shape:** surface `app_name` (or `connector_id` when the friendly name is absent)
  as a label or subtitle on MCP tool rows.
- **Risk if wrong:** the keys are new, so older sessions lack them — the label must be
  optional, never a layout requirement.
- **To close:** an MCP tool row shows its originating connector, and a fixture covers a
  record both with and without the keys.

### Qwen reports its context window size and nothing shows it
> **open** · sev: low · urg: low · verified 2026-08-17

- **What:** Qwen assistant records carry `contextWindowSize`. There is no context-fullness
  indicator anywhere in the app, and this is the only source that states the window
  directly rather than requiring a per-model lookup table.
- **Where:** [QwenSessionParser.swift](../AgentSessions/Services/QwenSessionParser.swift);
  `contextWindowSize` appears nowhere in `AgentSessions/`.
- **Why deferred:** only useful next to a token count, so it naturally follows the Qwen
  usage entry under *Usage Tracking*. Do that one first.
- **To close:** context usage is displayable for at least one source without hardcoding
  per-model window sizes.

### Inline images lost their right-click menu everywhere
> **open** · sev: low · urg: low · verified 2026-08-13

- **Where:** the inline image row in the transcript —
  [InlineImageThumbnailGridView.swift](../AgentSessions/Views/InlineImageThumbnailGridView.swift)
  and its host [TranscriptBlockListView.swift](../AgentSessions/Views/TranscriptBlockListView.swift).
- **What:** inline image thumbnails no longer offer a right-click context menu in any
  provider's transcript. Click-to-open still works and is the preferred primary
  interaction, so this is about the secondary actions the menu carried (copy, reveal,
  open externally), not about changing how a plain click behaves.
- **Why deferred:** reported 2026-08-13 while verifying Grok inline images; explicitly
  deferred by the owner rather than fixed in that pass. Not caused by the Grok inline
  image work, which only widened the per-source gating in
  `SessionInlineImageMapper` / `refreshRichInlineImages` and touched no gesture or menu
  code — so the loss predates it and needs its own bisect.
- **Note:** any fix should keep click-to-open as the primary gesture; the menu is
  additive, not a replacement.

---

## Agent Source Plumbing

### Newest-5 sampling gives a thin-store agent a verdict about nothing
> **open** · sev: med · urg: low · verified 2026-08-31

- **What:** `_LOCAL_SCHEMA_SAMPLE_COUNT = 5`
  ([agent_watch.py:562](../scripts/agent_watch.py:562)) is a global constant, and the
  weekly unions the **newest** five sessions. For an agent whose store is mostly tiny
  sessions that window can miss every informative transcript it has. **Measured
  2026-08-31 for antigravity:** 31 transcripts on disk, **29 of them under 10 lines**;
  the newest five total **19 events at 0.308 coverage**, which trips
  `blocked_thin_sample`. The only two substantial transcripts — **60 and 81 lines** — are
  from 07-21 and 06-24 and are excluded purely by age. The agent is therefore reported as
  un-evidenced while the evidence sits on disk, unread.
- **Not the diagnosis it first looked like.** This was initially written up as
  self-inflicted: real-home prebumps dropping stub sessions into the newest-5 window
  (§1a's documented degradation). Prebumps did contribute — three of the five sampled are
  from prebump runs — but **two of the five are pre-existing 3-line sessions from 08-18**,
  so the window would have been thin with zero prebumps. The root cause is the sampling
  rule meeting a thin store, not the prebump.
- **Fix shape:** make the sample width adaptive rather than a fixed count — keep taking
  the next-newest session until the union clears the thin-sample floor (or a hard cap is
  hit), instead of stopping at exactly five. A per-agent override in
  `agent-watch-config.json` would also work and is smaller, but it needs a human to
  notice and set it, which is the drift class the entry below this one is about.
- **Risk if wrong:** do **not** just raise the constant. §5a explains what the count is
  for — one session must not decide the verdict — and widening it globally pulls
  progressively staler sessions into every agent's union, which is how a long-retired
  event family starts re-reporting as present. Any change must keep the newest session
  dominant and be pinned by the existing
  `test_thin_prebump_does_not_override_rich_weekly_union`.
- **Why deferred:** it changes the sampling rule for all 14 agents to fix one, and the
  affected agent is low-traffic. Antigravity recovers on its own the moment the maintainer
  uses it for real work.
- **To close:** antigravity reports a real verdict from its existing 60/81-line
  transcripts rather than `blocked_thin_sample`, and no other agent's union changes shape.


### `rebuild_stage0_baseline.py` is blind to `db_roots`, so it sweeps the wrong OpenCode store
> **open** · sev: med · urg: low · verified 2026-08-21

- **What:** the rebuild tool reported "opencode: fixture already covers every bucket/key
  on disk" while the same day's weekly reported `part.patch` as drift. Both ran; only one
  looked at the live data. `_all_sessions()` builds its file list from
  `weekly.local_schema.roots` + `glob` and never consults `db_roots`, so for OpenCode it
  swept the stale legacy `storage/session` directory — **1 session** — instead of
  `opencode.db`, which holds ~8,900 parts. The tool then reports full coverage, which is
  the most dangerous possible answer: a false clean from an instrument aimed at the wrong
  corpus.
- **Where:** [rebuild_stage0_baseline.py:104](../scripts/rebuild_stage0_baseline.py:104)
  (`_all_sessions`); OpenCode's `db_roots` is declared in
  [agent-watch-config.json](../docs/agent-support/agent-watch-config.json) under
  `agents.opencode.weekly.local_schema`. Weekly reads it via the
  `opencode_latest_session` fingerprint kind; the rebuild tool has no equivalent branch.
- **Fix shape:** teach `_all_sessions` to fall back to the DB path when `db_roots` is set,
  reusing the weekly fingerprinter. Note the emit side is the harder half — OpenCode
  fixtures are a multi-file `storage_v2` tree, not JSONL lines, so a DB-sourced record has
  to be written out as `part/<messageID>/NNN.json` **and** registered in the matrix's
  `evidence_fixtures` before it counts.
- **Why deferred:** the 2026-08-21 gap was closed by hand, so nothing is currently
  mis-stated in the fixtures. The risk is the next sweep trusting the tool again.
- **Risk if wrong:** silent. This class of bug never errors — it returns "all clear" and
  the drift stays invisible until something downstream breaks.
- **To close:** running the tool for OpenCode reports the same missing pairs the weekly
  does, or it refuses to answer for agents whose corpus it cannot read.

### Hand-maintained per-source lists drift every time an agent is added
> **done** 2026-08-16

Closed by the Session Source Registry program (Tasks 0-9, `main` at `760382ed`):
descriptors, `SessionSourceRegistry` and `SessionProviderCatalog` replaced the hand lists,
and the four silent `default:` holes named in SPEC §6.C (`resume(_:)`,
`Session.computeIsHousekeeping`, the two inner `ImageBrowserIndexCache` switches) became
exhaustive along with several others. Two hand-maintained lists
survive on purpose, both test-enforced: `SessionSourceRegistry.ordered` and
`PreferencesTab.sidebarAgentSources` (frozen sidebar order, so it cannot be registry-derived).
Spec: [2026-08-14-session-source-registry-SPEC.md](superpowers/plans/2026-08-14-session-source-registry-SPEC.md).
The remaining cost of a new source, and the PR #56 dry-run that measured it, are in
[adding-a-session-source.md](adding-a-session-source.md).
Tests: `testRegistryOrderEqualsSessionSourceAllCases`,
`testSidebarAgentSourcesAreEveryRegistrySourceExceptTheHiddenOnes`.

### Registry program follow-ups (final whole-branch review, 2026-08-16)
> **partial** · sev: low · urg: low · verified 2026-08-28

- **Closed 2026-08-28** (four of the original six):
  - **2. Stale header comment** — found already correct on re-check;
    [SessionSourceRegistry.swift:21](../AgentSessions/Model/SessionSourceRegistry.swift:21)
    names the sidebar ordering as the second hand-maintained list. The entry had rotted.
  - **3. Dead `?? same-key` double-reads** — deleted at `PresenceEngine.swift` in
    `claudeSessionsRoots`, `claudeSessionScanRoots` and `opencodeSessionsRoots`. Each read
    the same key twice, so the second read could never contribute.
  - **4. `AvailabilityContext.live()`** — still zero callers, so it is now
    `@available(*, unavailable)` with the reason
    ([SessionSourceDescriptor.swift:125](../AgentSessions/Model/SessionSourceDescriptor.swift:125)).
    Fenced rather than deleted: two comments elsewhere cite it by name as the uncached
    detector, and a compile error stops a hot-path adopter better than a comment does.
  - **6. `@AppStorage` enablement-default islands** — all three views now take their
    defaults from `AgentEnablement.isEnabled`. **The filed paths were wrong**: the views
    are [AnalyticsView.swift](../AgentSessions/Analytics/Views/AnalyticsView.swift) and
    [FirstRunSetupView.swift](../AgentSessions/Onboarding/Views/FirstRunSetupView.swift),
    and the third island is not `PreferencesView+General` but the properties it renders,
    declared at [PreferencesView.swift:77](../AgentSessions/Views/PreferencesView.swift:77).
    Worse than filed, too: `hermes` and `cursor` were literal `true` and `openclaw`
    literal `false`, but all three are `.whenAvailable` sources, so the literals disagreed
    with the canonical default in *both* directions. Analytics gates its per-source rows on
    these, so an installed OpenClaw could be counted in the main window and silently
    excluded from Analytics.
- **Still open (two):**
  1. **Guide-rot sentinel:** [adding-a-session-source.md](adding-a-session-source.md) §6 is a
     hand snapshot; two review rounds each found omissions in it. Fix shape: a test that
     brace-matches exhaustive `SessionSource` switches in `AgentSessions/` against a
     pinned file list, failing when a new switch appears unlisted.
  5. `testAllowedSearchSourcesIsEnabledAndIncluded` needs a non-emptiness pin + one
     unconditional positive-membership assertion (two legs are tautological).
- **Why the rest were deferred:** none affected a fresh install; the program's correctness
  bar was behavior preservation, and each was cleanup beyond it.
- **Risk if wrong:** low — the two survivors are a doc-rot sentinel and a test-strength gap;
  neither corrupts data or search.
- **To close:** each remaining item is a short self-contained task.

### Three per-source behaviors the registry refactor deliberately preserved
> **partial** · sev: low · urg: low · verified 2026-08-28

- **Where / what:** SPEC §8 items 6–8, each found during the refactor and left as-is so the
  program stayed behavior-preserving —
  - `UnifiedSessionIndexer.triggerRefresh` drops `mode` / `trigger` / `executionProfile`
    for OpenCode only (now inside that source's `ProviderHandle` wrapper,
    [OpenCodeSourceDescriptor.swift:88](../AgentSessions/OpenCode/OpenCodeSourceDescriptor.swift:88)).
    **Open.**
  - **RULED 2026-08-28 — Droid's hidden pane stays hidden.** Owner: Droid is not a supported
    source and will not be until a steward takes it on; there is no subscription here to test
    sessions against, so shipping a configuration pane would advertise support that has never
    been exercised. `PreferencesTab.sidebarHiddenSources = [.droid]` is therefore correct, at
    [PreferencesView.swift:1322](../AgentSessions/Views/PreferencesView.swift:1322) (the filed
    line 1232 had drifted). Verified the same day that this strands nothing: Settings → General
    builds its agent rows from `SessionSourceRegistry.ordered`
    ([PreferencesView+General.swift:80](../AgentSessions/Views/Preferences/PreferencesView+General.swift:80)),
    not from `sidebarAgentSources`, so Droid still has a reachable on/off toggle — only the
    per-agent paths pane is hidden.
  - `effectiveWorkingDirectoryURL(for:)` has no kimi/grok arm, so both fall to the generic
    `session.cwd` via its `default:`. **Open.**
- **Why deferred:** each is an owner decision, not a defect — the refactor's whole
  correctness argument was bit-for-bit preservation, so changing any of them there would
  have been unreviewable.
- **Risk if wrong:** low — both survivors are the pre-refactor behaviors, unchanged; the risk
  is only that they stay unexamined (OpenCode refresh triggers stay coarser than the other
  fourteen) because nothing but this entry tracks them.
- **To close:** an owner ruling on the two that remain. Neither is user-visible.
- **Follow-on, RULED and shipped 2026-08-28:** Droid was `defaultEnabled: .always`, so it was
  on for every user including those with no Droid install. Now `.whenAvailable`
  ([DroidSourceDescriptor.swift:43](../AgentSessions/Droid/DroidSourceDescriptor.swift:43)).
  The `.always` was never a product call — only a mirror of pre-refactor runtime behavior
  (K7). Scope was narrower than it looks: `seedIfNeeded` writes every source's key from
  availability on first run, so only installs seeded *before* droid joined the registry ever
  reached the default, leaving upgraders as the one affected cohort. Explicit choices are
  untouched — `isEnabled` reads a stored preference first. Four pinning sites updated
  (`SessionSourceRegistryTests.testDefaultEnablementSemanticsPreserved`, and three in
  `NewProviderDiscoverabilityTests` including `testIsEnabled_droidIsOffByDefaultWhenItIsNotAvailable`,
  rewritten to carry the ruling). The registry SPEC/PLAN still describe K7 as preserved; they
  are the historical record of that program and were deliberately not rewritten.

---

## Kimi Code

### `agentId` now attributes every event to an agent and nothing reads it
> **open** · sev: low · urg: low · verified 2026-08-21

- **What:** Kimi 0.38.0 stamps `agentId` on 13 wire event types — `turn.prompt`,
  `turn.ended`, `llm.request`, `usage.record`, `context.append_message`,
  `permission.set_mode` among them — and `profile.bind` gained a `subagents` list. Kimi
  events are currently anonymous as to which agent produced them.
- **Where:** found in the 2026-08-21 prebump (`kimi_prompt` driver, fresh 0.38.0
  session). `agentId` occurs in `AgentSessions/` only in unrelated Cursor and OpenClaw
  path contexts, never in
  [KimiSessionParser.swift](../AgentSessions/Services/KimiSessionParser.swift).
- **Fix shape:** the app already models subagent reports for other sources; this is the
  per-event key that would let Kimi join that model instead of staying a flat stream.
- **Why deferred:** the evidence is one thin prebump session of 24 events. Confirm
  `agentId` actually varies inside a real multi-agent Kimi session first.
- **Risk if wrong:** if it is always the main agent in ordinary use, an attribution UI
  adds a column that never changes.
- **To close:** `agentId` is confirmed to vary in a real session and Kimi subagent events
  become attributable — or it is recorded here as constant and dropped.

### `turn.ended` carries per-turn duration that nothing reads
> **open** · sev: low · urg: low · verified 2026-08-17

- **What:** Kimi's `turn.ended` wire event carries `durationMs` and `reason`, present in
  every session. The 2026-08-13 ledger entry already named this "the natural source of a
  per-turn duration UI" and it has sat unused since — filed here so it stops living as an
  aside in a ledger note.
- **Where:** [KimiSessionParser.swift](../AgentSessions/Services/KimiSessionParser.swift) —
  `turn.ended` falls through the `default:` branch to `.meta`, so both fields survive in
  `rawJSON` and are never read. `durationMs` appears nowhere in `AgentSessions/`.
- **Fix shape:** per-turn timing already has a home in
  [TranscriptTurnTiming.swift](../AgentSessions/Services/TranscriptTurnTiming.swift),
  which currently derives timing from timestamps; a source-reported duration is more
  accurate where it exists.
- **Risk if wrong:** only Kimi reports this, so any UI must degrade cleanly for the other
  eleven sources rather than showing a gap.
- **To close:** Kimi turns show a source-reported duration, or the field is explicitly
  declared redundant against derived timing.

### Fixture does not cover image / audio / video content parts
> **open** · sev: low · urg: low · verified —

- **Where:** `KimiSessionParser.textContent(from:)` —
  [KimiSessionParser.swift](../AgentSessions/Services/KimiSessionParser.swift), the
  `image_url` / `audio_url` / `video_url` arms that render `[image]` / `[audio]` /
  `[video]` placeholders. Fixtures:
  `Resources/Fixtures/stage0/agents/kimi/{small,assistant_tools,subagent_agent-0}.jsonl`.
- **What:** Kimi's `ContentPart` union is `text | think | image_url | audio_url |
  video_url` (kosong `message.ts`), but every checked-in capture contains only `text`
  and `think`. The three media branches are written and unexercised — the same shape of
  gap that hid the loop-event defect, where an unexercised branch looked correct for a
  week because no fixture reached it.
- **Why deferred:** needs a capture that actually attaches media. `ReadMediaFile` is in
  Kimi's tool list, so an image round-trip is reachable — it just was not part of the
  command set run on 2026-08-01.
- **Risk if wrong:** low severity, bounded blast radius. A mis-mapped media part
  degrades one event's text; it cannot break discovery, counting, or the other ten
  agents. Contrast with the loop-event defect, which silently emptied whole transcripts.
- **To close:** in a scratch dir, have Kimi read an image (e.g. `ReadMediaFile` on a PNG),
  capture the resulting journal, add it beside the existing fixtures, and assert the
  placeholder rendering plus `.meta`/`.assistant` classification.

### No `agent_watch` prebump driver for kimi
> **done** 2026-08-14 (`15a7f21b`) — found stale 2026-08-30

Shipped in `15a7f21b`, which added `KimiPromptDriver` (`DRIVERS["kimi_prompt"]`,
[agent_watch_prebump_drivers.py:1085](../scripts/agent_watch_prebump_drivers.py:1085)) and
the `agents.kimi.prebump` config block. No test pins driver *existence* — the config gate
(exit 4 for an agent with no `prebump` block) is the enforcement;
`test_every_monitored_agent_is_registered_in_the_rebuild_tool` pins matrix-key wiring, not
this. The entry sat `verified —` and read as open work for two weeks.

---

## Codex Usage Meter

### Transient-failure cooldowns lock out both live sources with no reachable bypass
> **open** · sev: med · urg: low · verified 2026-08-14

- **What:** After a failed usage fetch, `CodexOAuthUsageFetcher` sets a 30-minute
  failure cooldown, and the CLI-RPC probe it falls through to sets a **60-minute**
  one. A single offline launch or network blip therefore locks out both authoritative
  sources — the RPC probe for a full hour — while the ~3-minute poll keeps being
  rejected by the gate.
- **Where:** the cooldown gates — **two** in the OAuth fetcher, one per API:
  [`fetchUsage`:126](../AgentSessions/CodexStatus/CodexOAuth/CodexOAuthUsageFetcher.swift:126)
  and [`fetchUsageResult`:177](../AgentSessions/CodexStatus/CodexOAuth/CodexOAuthUsageFetcher.swift:177)
  (the live polling path), sharing actor state; plus
  [CodexCLIRPCProbe.swift:47](../AgentSessions/CodexStatus/CodexCLIRPCProbe.swift:47);
  the fallthrough at
  [CodexStatusService.swift:2511](../AgentSessions/CodexStatus/CodexStatusService.swift:2511);
  `refreshNow` in `CodexStatusService.swift` and its only user-facing caller,
  [PreferencesView+Usage.swift:77](../AgentSessions/Views/Preferences/PreferencesView+Usage.swift:77).

#### Re-verified 2026-08-14 — the original entry was partly stale and partly understated
- **A bypass has since landed, but it does not cover this case.**
  `resetForUserRecheck()`
  ([:95](../AgentSessions/CodexStatus/CodexOAuth/CodexOAuthUsageFetcher.swift:95))
  clears `lastFetchAt` / `lastFetchFailed` / `rateLimitedUntil`, reached via
  `recheckAuthNow`. But it sits behind `AuthRemediationBanner`, which only replaces
  the meter when the auth verdict is **alarming**. A transient network failure is not
  alarming, so the user gets `FooterRetryChip` instead — a spinning "Codex —
  reconnecting…" with **no Button and no gesture**
  ([CockpitFooterView.swift:390](../AgentSessions/Views/CockpitFooterView.swift:390)).
  The one control a user would actually reach for, Preferences → Usage → "Refresh
  now", routes through `refreshNow` straight into the gate.
- **The recovery path only half-clears.** `recheckAuthNow` calls
  `resetForUserRecheck()` on the OAuth fetcher but passes the RPC probe merely
  `cooldownSuccess: 0`
  ([:2145](../AgentSessions/CodexStatus/CodexStatusService.swift:2145)) —
  `lastProbeFailed` stays set, so the 60-minute *failure* cooldown still rejects it.
  `CodexCLIRPCProbe` has no `resetForUserRecheck` equivalent. The "authoritative
  recovery attempt" therefore cannot recover the source with the longer lockout.
- **The silent auto-recovery does not apply.** `shouldSilentlyRecheckAuth`
  ([:755](../AgentSessions/CodexStatus/CodexStatusService.swift:755)) fires only on
  `.unauthorized`, never on `.transient` — correctly, since retrying a dead network
  immediately is pointless.
- **Severity is lower than first written.** The JSONL fallback still runs (local
  `rate_limits` from `~/.codex/sessions`, no network, no cooldown, honestly labeled as
  a fallback source), so the meter usually still shows something and never shows a
  *wrong* number. All retry state is in-memory actor vars with no `UserDefaults`
  persistence in either file, so **quit-and-reopen clears it instantly**. This is
  recovery latency, not correctness: medium-low severity, low urgency.
  The earlier "largest remaining real defect in Codex cold-start behaviour" framing is
  retracted.
- **Fix shape:** give `CodexCLIRPCProbe` a `resetForUserRecheck()` and call it beside
  the OAuth one; make the retry chip's recovery action reachable during transient
  failures; have `refreshNow` carry a user-initiated flag that bypasses the failure
  gate. NWPathMonitor reset on network-path change is the nice-to-have on top.
- **Why deferred (2026-08-01, re-confirmed 2026-08-14):** the code change is small, but
  the **test burden is not** — that asymmetry is the whole reason this keeps sliding.
  Verification has to cover both cooldown clocks independently, the OAuth/RPC
  fallthrough order, the reachable-vs-alarming branch that decides which footer chip
  renders, and the interaction with the `.idle` promotion below (which shares this code
  path and should be fixed in the same change). Several states are only reachable by
  seeding retry state — `seedRetryStateForTesting`
  ([:103](../AgentSessions/CodexStatus/CodexOAuth/CodexOAuthUsageFetcher.swift:103))
  exists for the OAuth half; the RPC probe has no equivalent yet, so the fix likely has
  to add one before it can be tested at all. Do not ship this as a one-line bypass
  without that suite.

### `.idle` can mislabel a cold-start transient failure
> **open** · sev: low · urg: low · verified —

- **What:** `CodexUsageModel.handleAuthFetchResult` promotes `.ok` → `.idle`
  ("No active Codex session") when a completed fetch returned nothing and nothing
  has ever been applied. `CodexUsageFetchResult.transient` covers offline, 5xx AND
  429 alike, so a cold launch during a rate-limit window reads "no active session"
  when the truth is "rate limited, retrying — no session needed".
- **Where:** `AgentSessions/CodexStatus/CodexStatusService.swift` (the promotion
  before `applyAuthState`), `QuotaData.codex(from:)` in
  `AgentSessions/Views/CockpitFooterView.swift:159-176` (passes neither
  `dataIsStale` nor `transientReason`, unlike `claude(from:)`).
- **Fix shape:** carry a reason on `.transient`, plus a latch — follow-up ticks
  return `.skippedCooldown`, which would otherwise flip the caption back — then make
  the promotion reason-aware. Best done together with the cooldown item above.
- **Why deferred (2026-08-01):** requires a three-way conjunction (cold launch AND
  no rollout from today/yesterday AND a transient first fetch), self-heals on the
  next success, and **no 429 has ever been observed on the Codex endpoint** (the
  documented 429 storms were Claude's edge). Also strictly better than the infinite
  "reconnecting…" spinner it replaced. Revisit only if a Codex-side 429 is actually
  seen.

### Two smaller findings from the same review
> **open** · sev: low · urg: low · verified —

- `.idle` does not reset `AuthStatusNotifier`'s one-shot episode where `.ok` did
  (`AgentSessions/Shared/AuthStatusNotifier.swift:43-46`), so a second genuine
  sign-out within one run could go unnotified.
- `UsageMenuBar` renders a moon glyph for Codex idle, but the dropdown's idle
  explainer is Claude-only (Codex rows go through `codexResetMenuTitle`), so the
  glyph has no explanation anywhere in the menu.

---

## Claude Cloud Sessions

### `bridge-session` carries the local↔bridge join key the dedup rule only assumes
> **open** · sev: low · urg: low · verified 2026-08-21

- **What:** Claude transcripts now carry a `bridge-session` record — 569 of them across
  13 of 60 recent sessions — holding `sessionId`, `bridgeSessionId` (`cse_…`),
  `lastSequenceNum`, and owner account/org uuids.
- **Where:** `bridge-session` and `bridgeSessionId` appear nowhere in `AgentSessions/`.
  [ClaudeCloudSessionCatalog.swift:20](../AgentSessions/ClaudeCloud/ClaudeCloudSessionCatalog.swift:20)
  already drops bridge rows from the cloud list on the stated grounds that "the local
  indexer already surfaces them, so including them would double-render rows" — 168 of the
  177 rows measured. Nothing has ever joined a bridge row to the local session it
  supposedly duplicates, so that exclusion has been unverifiable. This record is the join
  key.
- **Fix shape:** use it first to *verify* the exclusion — does every dropped bridge row
  have a local transcript? — and only then consider badging a local session as
  bridge-run.
- **Why deferred:** it corrects an assumption rather than adding a surface, which makes
  it worth doing before any bridge-facing UI rather than after.
- **Risk if wrong:** this does **not** soften the finding that cloud sessions leave no
  local trace. Sessions with `environment_kind == anthropic_cloud` still leave none;
  bridge sessions are the ones running against a local device, which is why they have a
  transcript at all. Conflating the two would re-open a question already settled.
- **To close:** the bridge exclusion is verified against local sessions instead of
  assumed, and the answer is recorded here.

### Reconsider the surface: presence badge instead of runway rows
> **open** · sev: low · urg: low · verified —

- **What:** Cloud sessions currently render as rows inside the Quota Meter's runway
  block, with the literal "Cloud" where a rate would be. **The owner questioned
  whether this belongs there at all, and the question is a good one.** Runway's
  grammar is rate-per-session — every row answers "how fast is this eating my
  budget?" A cloud row answers "unknown", takes a slot in a consumption-ranked list,
  and cannot be acted on (no reveal, no navigation, no resume).
- **Decisive argument:** cloud sessions bill the same account-level quota, so the
  Claude 5h/weekly figures **already include them**. Nothing is missing from the
  measurement. What is missing is only awareness — "something is running over
  there" — which is a presence signal, not a metering one.
- **Evidence it is the wrong container:** the friction during implementation
  (slot competition, an empty progress bar, a pseudo-rate label, three rounds of
  ordering corrections) is what happens when an object is put into a container whose
  language it cannot speak.
- **Proposed shape:** a compact indicator on the Claude provider row — e.g.
  `⛅ 2 cloud · 1 working` — outside the consumption ranking. Keeps the awareness
  value, frees the 4 detail slots for rows that carry real rates, removes the
  pseudo-rate and empty bar, and makes the ordering question disappear.
- **Cost to switch:** small. The endpoint, filter, catalog and live model all stand
  unchanged; only `appendingClaudeCloudRows` and the `RunwayAttributionConfidence
  .cloud` case (~80 lines) would be replaced.
- **Sizing input:** the account has 6 cloud sessions total and 0-2 live at any time,
  which argues for a low-weight affordance rather than rows.
- **Also unresolved if rows are kept:** the pinned window's hard 270pt cap
  (`limitsRowHeight × limitsMaximumRows`) has no scrolling, so a saturated panel
  clips silently; and with 4+ local sessions burning, cloud rows lose every detail
  slot and are not counted in the "+N sessions" summary either, so a live cloud
  session can go invisible on a busy day.
- **Why deferred (2026-08-01):** a design decision, deliberately not made at the end
  of a long session. Nothing shipped is stranded by it.

---

## Usage Tracking

### Weekly quota calibration cannot tell two accounts of the same provider apart
> **open** · sev: med · urg: low · verified 2026-08-30

- **What:** the `Wk` weekly calibration (percentage points per API-equivalent dollar) is
  cached per provider and account, but Claude's normalized snapshot carries no account or
  org id, so every Claude account persists to the literal scope `unscoped`. Two Claude
  accounts on one machine share one carry-over slot: whichever reaches the larger weekly
  percentage wins it, and the other account is then served a conversion learned from a
  plan it is not on. Codex has the same shape latently — it *does* expose an account id
  and is scoped by its hash, so it is correct today, but that only holds while one account
  is in use at a time.
- **Where:** `WeeklyQuotaCalibrationStore.bootstrapKey`
  ([:519](../AgentSessions/CodexStatus/WeeklyQuotaCalibration.swift:519)) and
  `bestBootstrapKey` ([:533](../AgentSessions/CodexStatus/WeeklyQuotaCalibration.swift:533))
  fall back to `"unscoped"` when `accountHash` is nil; the Claude caller passes
  `accountHash: nil` with the reason inline
  ([ClaudeUsageModel.swift:616](../AgentSessions/ClaudeStatus/ClaudeUsageModel.swift:616)).
  `WeeklyQuotaCalibrationScope.isPersistable` already refuses to persist an unscoped LIVE
  tracker for exactly this reason — the bootstrap cache is the surface that does not.
- **Why deferred (owner decision 2026-08-30):** the honest fix is not a better cache key.
  It is **multi-account support for Claude and Codex** — knowing which account a session,
  a usage poll and a stored calibration each belong to, and letting the user see and switch
  between them. That is a separate job and is not planned soon. Scoping the calibration
  alone would produce a key nothing else in the app understands.
- **Mitigations already in place:** an account switch clears the provider's in-memory
  bootstraps, tracker, ledger and scan bookkeeping; a scan that completes after a switch is
  discarded via its scope generation; and a bootstrap is stamped with the price revision and
  limit shape it was measured under, so a plan change invalidates it. None of these help
  when both accounts report the same shape under the same `unscoped` key.
- **Risk if wrong:** a wrong `%/h` for the account that did not win the slot, silently — the
  row looks identical to a correct one. The reset anchor discriminates in practice (it is an
  account's own reset instant at second precision), so a collision needs two Claude accounts
  whose weekly windows align within 120s.
- **To close:** an account identity for Claude that survives a restart; calibration keyed by
  it; and a test proving two accounts on one machine keep separate carry-over slots.
  Blocked on the multi-account work above.

### Storage rollup in Analytics: bytes per source and S4-eligible waste
> **open** · sev: low · urg: low · verified 2026-08-23

- **What:** a read-only Analytics surface showing bytes per source, the largest
  sessions, and where bench gate S4 applies — "N MB reclaimable by rule X —
  upstream issue Y". Flagged-but-untouchable items (Hermes' credential-bearing
  pre-update snapshot) are shown with the reason nothing touches them.
- **Where:** new surface; aggregation over `Session.fileSizeBytes` for the
  file-backed sources (Codex: [SessionIndexer.swift:2100](../AgentSessions/Services/SessionIndexer.swift),
  Claude: [ClaudeSessionParser.swift:133](../AgentSessions/Services/ClaudeSessionParser.swift)) —
  but NOT the shared-database ones: Devin sets it `nil` unconditionally
  ([DevinSqliteReader.swift:328](../AgentSessions/Devin/DevinSqliteReader.swift)), and
  Hermes/Cursor nil it on placeholder paths, so shared-DB sources need a
  per-source store-size rule (report the shared db's size whole or apportioned)
  before the rollup can claim per-source coverage —
  plus the S4 collapse-rule definitions in
  [measure.py](../scripts/session_bench/measure.py) and the seeded numbers in
  [measurements-2026-08-04.json](../scripts/session_bench/measurements-2026-08-04.json).
- **Why deferred:** owner sequenced it after S4 landed in the bench so the
  product side reuses one definition instead of inventing a second
  ([discussion #54](https://github.com/jazzyalex/agent-sessions/discussions/54#discussioncomment-18121398)).
  Reclamation in any form was declined outright — same thread.
- **Risk if wrong:** a second, divergent definition of "superseded bytes"
  between the bench and the product.
- **To close:** Analytics shows per-source byte totals, largest sessions, and
  per-source reclaimable-by-rule figures traceable to the bench manifest.

### Kimi reports measured token counts per turn and nothing reads them
> **open** · sev: low · urg: low · verified 2026-08-21

- **What:** Kimi 0.38.0 added `token_counting.measured` and
  `token_counting.turn_recorded`, carrying `tokens`, `length`, `turnId` and `time`. This
  is source-measured accounting, not an estimate derived from a per-model table.
- **Where:** `token_counting` appears nowhere in `AgentSessions/`; both types fall to
  `.meta` in [KimiSessionParser.swift](../AgentSessions/Services/KimiSessionParser.swift).
- **Fix shape:** the same shape as the Qwen entry below — a source that states its own
  usage. Build one path that serves both rather than two single-source paths.
- **Why deferred:** pairs with the Qwen usage entry; neither justifies a bespoke surface
  alone.
- **To close:** at least one source's self-reported token usage is displayed, covering
  Kimi and Qwen through the same path.

### Qwen already reports its own token usage and we discard it
> **open** · sev: med · urg: low · verified 2026-08-17

- **What:** every Qwen transcript carries complete per-call token accounting that nothing
  reads. The records are `type: system` / `subtype: ui_telemetry`, and
  `systemPayload.uiEvent` holds `input_token_count`, `output_token_count`,
  `cached_content_token_count`, `thoughts_token_count`, `tool_token_count`,
  `total_token_count`, `duration_ms`, and `model`. Values are real and dense — one
  ordinary local session carries **53** such records (e.g. 18022 in / 362 out / 12125
  cached / 35 thinking, 11392 ms).
- **Where:** [QwenSessionParser.swift](../AgentSessions/Services/QwenSessionParser.swift)
  maps every `type: system` record straight to `.meta`, so telemetry is retained in
  `rawJSON` and never extracted. `usageMetadata` on assistant records is touched only to
  carry it across fragment merges — the numbers are never read out.
- **Why this is mis-filed today:** `agent-support-matrix.yml` lists "usage/rate-limit
  tracking" under Qwen's *unsupported surfaces*, which reads as "the data isn't there."
  The data is there; nobody opened it. Fix the matrix wording as part of this.
- **Fix shape:** extract the `uiEvent` counters into the existing usage/analytics path.
  Per-call `duration_ms` + tokens is also enough for a burn-rate view without a price
  table, which is strictly better evidence than estimating from a table that goes stale.
- **Risk if wrong:** double-counting. `usageMetadata` and `uiEvent` may describe the same
  call from two places; confirm which is authoritative on real records before summing.
- **To close:** Qwen sessions show token usage in Analytics, and the matrix no longer
  claims the surface is unavailable.

### Verify the Claude Web API usage source actually works
> **open** · sev: low · urg: low · verified —

- **What:** The Web API fallback (`claudeWebApiEnabled`; "Web API only" mode) is
  implemented — `ClaudeWebUsageClient.swift` + `ClaudeWebCookieResolver.swift`
  (reads the Safari claude.ai session cookie) — but has **never been observed
  serving data at runtime**. The source diagnostic has only ever shown OAuth;
  the CLI OAuth path recovers first and masks it.
- **How to prove:** set Claude Data source → "Web API only" (forces the path),
  reload, confirm the source flips to a web source and serves numbers, then
  restore Auto.
- **Caveats:** needs Safari signed into claude.ai; Full Disk Access is per-binary
  (the grant is on the production build, not the `.deriveddata-run` debug build) —
  so test from the production build, or grant FDA to the test binary.
- **Why deferred (2026-07-10):** owner skipped the live test; normal (OAuth) auth
  is fixed and sufficient for now.

---

## Transcript (Session view)

### Semantic filters (Plan / Code / Diff / Review) in the Session view
> **open** · sev: low · urg: low · verified —

- **First, validate demand — do NOT build on assumption.** The old Terminal view
  had semantic toggles alongside the role toggles; when Terminal was retired only
  the role filters (You/Agent/Tools/Errors) were restored (2026-07-06). Before
  porting semantic filters, confirm they're actually used/wanted — check whether
  anyone relied on "show only code / only diffs / only plans / only reviews", vs.
  role filters + ⌘F covering the real need. If demand is thin, close as WON'T-DO.
- **Where:** filter bar lives in
  [TranscriptPlainView.swift](../AgentSessions/Views/TranscriptPlainView.swift)
  (`sessionRoleFilterBar`); block filtering in
  [TranscriptBlockListView.swift](../AgentSessions/Views/TranscriptBlockListView.swift)
  (`TranscriptRoleFilter`, `applyingRoleFilter`, `matchesUnderActiveRoleFilter`).
  Terminal reference: `SessionTerminalView.swift` `SemanticKind` +
  `semanticFilteredLines` (per-LINE `line.semanticKind`).
- **Why deferred / why it's harder than roles:** roles map 1:1 to
  `LogicalBlock.Kind`, so filtering is a clean block-level predicate. Semantic
  kinds were computed **per line** in Terminal (a single assistant block mixes
  prose + code fences + diffs). Blocks carry no per-block semantic label, so this
  needs either (a) a new per-block semantic classification pass, or (b) sub-block
  (per-run) filtering — both materially larger and with more regression surface in
  the perf-sensitive windowed list. Est. 3–5× the role-filter work.
- **Decision (2026-07-06):** deferred; owner asked to backlog AND to verify need
  before committing to the port. Related: [[project_transcript_redesign_phase01_state]].

---

## QM / Runway

### OpenAI long-context pricing is unreachable from the Codex CLI — do not implement
> **won't-do** · sev: low · urg: low · verified 2026-08-30

Recorded so the next price sweep does not re-investigate it. OpenAI publishes a second
price column for long context — for `gpt-5.6-sol` $8.00/$0.80/$10.00/$30.00 against the
short-context $4.00/$0.40/$5.00/$20.00 the table ships; input, cached input and cache
write double, output goes 1.5x. Only `gpt-5.6-sol`, `-terra` and `-luna` have the tier;
`gpt-5.5` and `gpt-5.4` are labelled `(<272K context length)` and cannot reach it.

**The threshold is 272,000 *input* tokens**, and it is stated only inside a column-header
tooltip on <https://developers.openai.com/api/docs/pricing> — the rendered prose does not
mention it, so a plain read of that page reports "no threshold stated". Fetched and
extracted from the raw page 2026-08-30; re-derive rather than trusting this line if the
page is redesigned.

**Why it cannot fire:** every Codex session reports
`payload.info.model_context_window` = **258,400** — uniformly across `gpt-5.6-sol`,
`-terra`, `-luna`, `gpt-5.5` and `codex-auto-review`, in all 29,402 local observations.
258,400 < 272,000. Max observed per-turn `input_tokens` is 245,726; turns over 272K:
**zero**. Claude has no long-context tier at all (4.6+ ships the full 1M window at
standard rates), so this is OpenAI-only and currently unreachable.

**Reopen if** `model_context_window` rises above 272,000. At that point the work is real:
the runway prices *cumulative deltas* from `total_token_usage`
([CodexRunwayModel.swift:2401](../AgentSessions/CodexStatus/CodexRunwayModel.swift:2401)),
which has no per-turn structure, so it would have to read
`payload.info.last_token_usage.input_tokens` per turn and classify each turn
individually. Testing the *cumulative* input against 272,000 would flip nearly every long
session to double rates after a few turns — a large, confident overstatement.

### Runway overflow "+X sessions" undercount (`withPendingRows`)
> **done** 2026-07-09

Shipped with the single-orphan promotion: `withPendingRows` now merges
`burnSummary.count + pendingIdentities.count`, burn summary keeping rate/deadline.
Test: `testRunwayPendingOverflowMergesWithBurnSummaryCount`.

### Runway "pause impact" projection is modeled but never displayed
> **open** · sev: low · urg: low · verified —

- **Where:** [CodexRunwayModel.swift](../AgentSessions/CodexStatus/CodexRunwayModel.swift) —
  `RunwayPauseImpactRow.deadline` / `.gainedSeconds`, the `RunwayDeadline` enum
  ([:11](../AgentSessions/CodexStatus/CodexRunwayModel.swift:11)), `deadline()`
  ([:512](../AgentSessions/CodexStatus/CodexRunwayModel.swift:512)), `gainedSeconds()`
  ([:521](../AgentSessions/CodexStatus/CodexRunwayModel.swift:521)),
  `minimumDisplayedGain`.
- **What:** The model computes, per session, "if you paused this, your quota would run
  out at X instead of Y — you'd gain N minutes" (`.afterReset` / `.runout(Date)` /
  `.noChange`). No view reads `.deadline` or `.gainedSeconds`; `runwayRow` renders only
  name + burn rate + load bar. The sole live consumer is the pressure-branch sort key
  `gainedSeconds` ([:447](../AgentSessions/CodexStatus/CodexRunwayModel.swift:447)); the
  values themselves are never shown.
- **Nature:** latent designed-but-unwired feature, **not a bug**. Cheap to leave.
- **Options:** (a) **surface** it — a small "→ reset" / "+Nm" badge in the row (answers
  "which session do I pause to survive to reset?"); (b) **trim** it — switch the sort to
  `normalizedRate` (already used by the after-reset branch) and delete
  deadline/gainedSeconds/`RunwayDeadline`/`minimumDisplayedGain`; (c) leave as-is.
- **Decision:** open — pending product call on whether the impact number is worth showing.

---

## QM / Runway (Claude)

### Every Claude cache write is billed at the 5-minute rate, but they are all 1-hour
> **done** 2026-08-31 (`c1dcb058`)

Filed and fixed same-day. The `$` view had understated Claude cost by 16.6% (182.9M local
cache-creation tokens, 100% 1-hour, billed at the 1.25x 5m rate instead of 2x). Now priced
by TTL from the `cache_creation` sub-object. Tests:
`testOneHourCacheWritesPriceAtDoubleInput`, `testFiveMinuteCacheWritesPriceAtTheFiveMinuteRate`,
`testFlatCacheCreationStillPricesWhenSubObjectAbsent`,
`testCacheCreationSubObjectReplacesFlatTotalRatherThanAddingToIt`, and
`testServedManifestMatchesTheBundledTable` — which pins the two-copy trap this entry warned
about, and failed for real before `RunwayPriceTable.bundledJSON` was advanced to match
`docs/prices.json`.

### Fast mode doubles Opus rates and nothing reads `usage.speed`
> **done** 2026-08-31 (`c1dcb058`)

Filed latent (no local record ever carried `speed: "fast"`) and implemented same-day, so
the 2x on Opus 5 / Opus 4.8 is priced before anyone meets it on a bill. Reads the observed
`usage.speed` rather than the model name — the trap this entry flagged, since Opus 4.6
accepts `speed:"fast"` and then bills standard. Tests:
`testFastModePricesAtTheFastRateSet`, `testStandardSpeedIsUnchangedByFastModeSupport`,
`testBurstStraddlingASpeedSwitchPricesEachHalf`,
`testFastSpeedOnAModelWithoutFastRatesIsUnpriceable`, plus
`testCrossSessionClampPreservesTheSpeedTier` / `testPerPathClampPreservesTheSpeedTier` for
the clamp-rescaling paths. **Still unverified:** that Claude Code's `/fast` writes
`speed:"fast"` into the JSONL — the pricing is right either way, but nothing has yet
observed a real fast session locally.

### Model-scoped weekly limit is read and shown, but never picked as the bottleneck
> **partial** · sev: low · urg: low · verified 2026-08-28

- **Shipped 2026-08-28 (`0d99ee99`):** the `limits[]` array is decoded tolerantly, and the
  model-scoped weekly window reaches two surfaces — the menu-bar dropdown always names it
  under the Claude meters, and the Quota Meter shows it as an on-demand line under the
  Claude provider row once **70% or less remains**
  ([`ScopedWeeklyWindowVisibility`](../AgentSessions/Views/AgentCockpitHUDView.swift:3377),
  threshold pinned by `ScopedWeeklyWindowVisibilityTests` because "70% remaining" and
  "70% used" are opposite readings that both compile). Selection prefers the server's
  `is_active` flag and falls back to the most-consumed window
  ([ClaudeUsageNormalizer.swift:55](../AgentSessions/ClaudeStatus/ClaudeOAuth/ClaudeUsageNormalizer.swift:55));
  `seven_day_opus` remains the fallback for older payloads. Covered by 8 normalizer tests
  incl. live-shape fixtures with a `weekly_scoped` entry.
- **What is still open:** the compact HUD's bottleneck pick still compares only the two
  original windows —
  [AgentCockpitHUDView.swift:4707](../AgentSessions/Views/AgentCockpitHUDView.swift:4707),
  `entry.fiveHourLeft <= entry.weekLeft` — so a scoped window that is the *binding* one
  (server `is_active`, or lowest remaining) never becomes the headline figure. `Wk:` stays
  the all-models number at all times, by design for now.
- **Residual risk:** narrower than when this was filed. A user on a scoped cap now sees the
  number in the dropdown and, below 70% remaining, in the QM detail line — but the compact
  meter can still read comfortable while the scoped window is the one throttling them.
  Visible-but-not-headline, hence sev dropped med → low.
- **UI decision (owner, 2026-08-28)** supersedes the 2026-08-22 ruling for the compact HUD:
  no scoped row in the compact meter, no `Wk Fable: 10%` substitution, no setting. The
  2026-08-22 idea of swapping the compact figure when the scoped window binds is *not*
  currently wanted — reopen that only with fresh owner intent, not from this entry.
- **To close:** either (a) owner decides the compact meter should defer to `is_active` and
  the bottleneck pick learns about scoped windows, with a test proving a binding scoped
  window wins over both originals; or (b) owner confirms the current split is final and
  this collapses to a tombstone.

### Claude runway rows intermittently show tokens/hour instead of weekly-share in Weekly mode
> **open** · sev: med · urg: low · verified 2026-08-16

- **Reported by owner (2026-08-16):** with the runway presentation set to Weekly, Claude
  session rows sometimes render raw token throughput instead of the weekly-average-burn
  share; Codex rows are correct in the same mode. **Update same day:** owner then observed
  Weekly mode showing the correct burn-rate for Claude too, with no code change in
  between — so this is **intermittent, not a permanent fallback.** That rules out "Claude's
  weekly data is structurally unmeasurable on this account" as the sole cause and points
  instead at something timing- or state-dependent: a stale/zero usage snapshot on first
  render before the weekly fetch lands, a refresh race between the 5h and weekly polls, or
  the `weeklyMeasurable` guard tripping only during a specific window (e.g. right after an
  app relaunch or a weekly-window rollover). Needs reproduction with logging, not a fix,
  before anything below is trusted as the actual cause.
- **Where:** the presentation resolves to `.tokensPerHour` instead of
  `.weeklyPercentPerHour` whenever `weeklyMeasurable` is false —
  [`effectivePresentation`](../AgentSessions/Views/AgentCockpitHUDView.swift:3152) (the
  `.weekly` case), fed by `weeklyRunout` computed via `RunwayBaselineMath.averageBurnRunout`
  in both [`request`](../AgentSessions/Views/AgentCockpitHUDView.swift:3223) (Codex) and
  [`claudeRequest`](../AgentSessions/Views/AgentCockpitHUDView.swift:3318). Same fallback
  also lives one layer down in
  [`CodexRunwayCalculator.weeklySnapshot`](../AgentSessions/CodexStatus/CodexRunwayModel.swift:947),
  which returns `nil` (→ token snapshot) whenever `remainingPercent <= 0` or the computed
  run-out yields `seconds <= 0`.
- **Not yet root-caused:** the call sites for Claude
  ([claudeRequest](../AgentSessions/Views/AgentCockpitHUDView.swift:3708)) and Codex
  ([codexRunwayRequest](../AgentSessions/Views/AgentCockpitHUDView.swift:3685)) look
  structurally identical, and `weekAllModelsRemainingPercent` /
  `weekAllModelsResetText` populate the same way Codex's week fields do
  (`ClaudeStatusService.swift:1261`, `ClaudeUsageModel.swift:530-535`). The divergence is
  therefore either in the *values* Claude's weekly usage source actually returns (e.g.
  `weekAllModelsRemainingPercent` reading 0% used / no run-out on this account) or in
  something not yet traced — a live snapshot comparison (Claude vs. Codex, same account,
  Weekly mode) is needed, not more static reading.
- **To close:** since it's intermittent, a single breakpoint won't catch it — add
  temporary logging of `claudeRunwayRequest`'s `resolved.rateUnit`,
  `weekRemainingPercent`/`weekResetText`, and `weeklyRunout` on every HUD refresh cycle,
  then correlate the tokens-mode ticks against app lifecycle (launch, wake, weekly-window
  rollover) and against `ClaudeUsageModel`'s fetch/refresh timing to catch it live.
- **Risk if wrong:** low blast radius — display-only, wrong unit label on a runway row,
  no data loss. Confusing enough to mislead pacing decisions, hence med severity.

---

## Resume / Terminal Launch

### `runAppleScript` blocks the main thread for the Terminal / iTerm path
> **open** · sev: low · urg: low · verified 2026-08-04

- **Where:** [AgentTerminalLauncher.swift:189](../AgentSessions/Resume/AgentTerminalLauncher.swift:189)
  (`process.waitForExit()`) → [BoundedProcessWait.swift:9](../AgentSessions/Utilities/BoundedProcessWait.swift:9).
- **What:** `waitForExit` is a busy-poll — `while isRunning { Thread.sleep(0.1) }` on the
  *calling* thread, up to a 10 s deadline, then SIGTERM + 0.5 s grace + SIGKILL +
  `waitUntilExit()`. `runAppleScript` is `private static` inside the `@MainActor enum
  AgentTerminalLauncher`, so it inherits `@MainActor` and every Terminal.app / iTerm2
  resume runs that poll on the main thread. Typical osascript round-trip is under a
  second, so it is invisible in normal use; the visible case is the **first-ever
  Automation consent prompt** for Terminal.app, where osascript sits waiting on the user
  and the UI is pinned for up to the full 10.5 s.
- **Verified 2026-08-04:** read both functions; the `@MainActor` inheritance and the
  `Thread.sleep` loop are both real. Confirmed **pre-existing** — untouched by the async
  launcher change, which only altered the Warp path.
- **Secondary hazard in the same function:** `standardOutput`/`standardError` are set to
  `Pipe()`s that are only drained *after* `waitForExit` returns (stderr) or never at all
  (stdout). An osascript that wrote more than the ~64 KB pipe buffer would block on write
  while we block on exit — a deadlock that only breaks when the 10 s timeout kills it.
  Not reachable with the current fixed scripts, which emit nothing; it becomes reachable
  the moment someone adds a script that prints.
- **Why it is newly cheap:** the `*TerminalLaunching` chain became `async throws` in
  `d4280354` (so the Warp cold start could be awaited and reported). The Terminal/iTerm
  wrappers are now `async` functions that happen to contain no suspension point, so
  hopping the osascript run off the main actor is a local change — no signature churn.
- **To close:** wrap the `Process` run in `await Task.detached { … }.value` the way
  `CodexResumeCoordinator` already does for CLI probes, and drain both pipes concurrently
  with the wait (or set them to `FileHandle.nullDevice` if the output is genuinely
  unwanted).
- **Risk if wrong:** low blast radius, and the failure mode is the current one — a stalled
  UI, not incorrect behavior. The one thing to preserve is that the throw still carries
  osascript's stderr, which is what surfaces "Terminal got an error…" to the user.

### Dead code: `CodexResumeSheet.launch(session:)`
> **open** · sev: low · urg: low · verified 2026-08-04

- **Where:** [CodexResumeSheet.swift:374](../AgentSessions/Resume/CodexResumeSheet.swift:374).
- **What:** A ~30-line `@MainActor private func launch(session:)` that switches over
  `settings.launchMode` and calls the four Codex launcher entry points. A project-wide
  search across the app and test targets finds **no callers**.
- **Verified 2026-08-04:** grepped `launch(session` across `AgentSessions/` and
  `AgentSessionsTests/`; the only hit is the declaration. Swift is statically dispatched
  here, so there is no dynamic-reference escape hatch.
- **Why it is still there:** it was carried through the `async throws` launcher change in
  `d4280354` (annotated in place) rather than deleted, to keep a commit about launcher
  signatures from also containing an unrelated deletion.
- **To close:** delete it, or re-wire it if the resume sheet is meant to have its own
  launch action distinct from `UnifiedSessionsView.resume(_:)`. Deleting it also strands
  two more methods — checked each one:
  - `CodexResumeLauncher.launchInWarp` / `.launchInWarpPreview` — **would become dead.**
    The sheet is their only caller; `CodexResumeCoordinator` reaches Warp through the
    static `AgentTerminalLauncher.launchInWarp` instead
    ([CodexResumeCoordinator.swift:77](../AgentSessions/Resume/CodexResumeCoordinator.swift:77)),
    not through the launcher instance. Delete all three together.
  - `CodexResumeLauncher.launchInITerm` — **survives.** Live caller at
    [CodexResumeCoordinator.swift:75](../AgentSessions/Resume/CodexResumeCoordinator.swift:75),
    on the real `quickLaunchInTerminal` path.
  - `CodexResumeLauncher.launchInTerminal` — **survives.** It is the
    `CodexTerminalLaunching` protocol requirement.
- **Risk if wrong:** none to runtime behavior; the only cost of getting it wrong is
  deleting a hook someone intended to wire up later.
