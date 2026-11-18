# Transcript: hide tool work by default

Date: 2026-11-08. Status: approved by owner 2026-11-08. Plan: `docs/superpowers/plans/2026-11-08-transcript-hide-tool-work.md`.
Research: `docs/superpowers/specs/2026-11-08-transcript-polish-research.md`.
Backlog: "Transcript polish: code and diff highlighting, better layout" (`docs/backlog.md`).

## 0. Lean v1 (owner decision 2026-11-08) — overrides the sections below

The owner cut scope: this is a simple layout change. Where this section and the rest of the
document disagree, this section wins.

- **Find:** Find counts matches in tool rows and notes even while Tools is off. Typing
  (reset/type-ahead jumps) lands only on visible matches and never changes Tools. Explicit
  navigation (Enter, ⌘G/⇧⌘G, the find-bar ▲▼, and the search-pill jump into a session newly
  opened from the list) onto a hidden match **turns Tools on** and scrolls to it. A Tools-on
  caused by Find is **not saved**: it lasts until the session changes or a chip click; only
  chip clicks persist. No
  per-row reveal state, no re-hide on clear, no reveal re-checks on chip changes. The
  session-list search jump follows the same rule; its raw-text fallback no longer bails when
  Tools is off — it turns Tools on and opens the call. (Replaces §3.4's reveal rules.)
- **Dropped:** the live running-turn exception (§3.1 "A turn still running", presence
  wiring) and the one-time hint popover (§3.5). Notes of a live session hide as new messages
  arrive. Possible follow-ups.
- **Kept:** turn/answer/note split (§3.1 minus the running exception); Tools as an
  independent switch, default off, one-time migration, muted count, tooltip (§3.2–3.3); tool
  groups open by default (§3.2); Agent ▲▼ and the turn badge follow visible rows (§3.2).
- The visibility rule becomes: a note is visible when Agent is shown AND Tools is on.
- **Owner QA 2026-11-09:** Tools is all or nothing. Failed tool calls follow the Tools chip,
  not Errors (6.4 showed them under Errors with Tools off, which left tool blocks in the
  "tools off" view). Errors governs only `.error` blocks outside invocations; with Tools off
  its count and ▲▼ stops skip failed calls. The Context toggle left the toolbar for a
  Settings switch ("Show harness context in Session view", default off). In a narrow window
  the role chips step down through three densities: full, then without the reserved hover
  ▲▼ space, then a dot and count only (label in the tooltip). ⌘G / ⇧⌘G still step.

## 1. Intent

The owner reads a past session for two things: their own prompts, and the agent's answers with
the file links in them. They almost never read tool calls. Tool output still matters sometimes,
because it holds text they search for.

So the Session view (blocks mode) shows, by default, each turn as **prompt → answer**. Tool
calls and the agent's in-between notes are hidden. One click on the existing Tools chip shows
all of them, fully unfolded. Find still reaches hidden text.

User-need research found no user request for transcript styling. Users come to find a session
and resume it. This change serves the reading that follows: scan prompts and answers fast.

## 2. Goals, non-goals, anti-goals

Goals:
- Default view: prompts and answers only, for every agent.
- Tools chip: one click shows tool calls and in-between notes, unfolded.
- Find counts and reaches matches in hidden rows.
- A new or updating user can tell that tools exist and how to show them.

Non-goals (decided against, or later):
- A per-turn "Worked for 2m 57s · 14 tools" line (Codex desktop style). The owner rejected it:
  one extra line per turn is bloat. Hidden-or-shown is the whole model.
- A separate fold/unfold toolbar button. The Tools chip does this job; the toolbar must not grow.
- Diff coloring, syntax highlighting, long-message folding. Separate backlog items.
- Terminal view (`SessionTerminalView`), Plain/JSON modes, Markdown export, the session-list
  search index. No change. (The search pill's jump INTO a session does change; see §3.4.)
- Codex's own `phase: commentary | final_answer` marker on agent messages. v1 uses one rule for
  all agents (§3.1). (Claude's call: no parser or `SessionEvent` change. An external review
  scanned 24 local Codex logs: all 86 completed turns with agent text ended on their
  `final_answer`, so the last-text rule agrees there. Follow-up only if it misreads Codex turns
  in practice.)

Anti-goals (failure even if it works):
- Tools vanish after an update with no visible hint of where they went.
- Find silently misses text that sits in a hidden row.
- Any new row per turn.
- A turn with a real answer shows nothing because the answer was misclassified as a note.

## 3. Behavior

### 3.1 Turns, answers and notes

- A **turn** is the one `TranscriptTurnTiming` already computes (`TranscriptTurnTiming.swift:90`):
  it starts at a block whose `startsTurn` is true (typed prompt or parent task) and ends before
  the next turn start, or right after an interrupt / `turn_aborted` marker. Extract that
  segmentation into one shared helper so the timing badge and note hiding never disagree.
- Blocks outside any turn (before the first prompt, or after an interrupt marker and before the
  next prompt) are not notes: they show as today. (Claude's call: hide only what is clearly a
  note.)
- The turn's **answer** is its last agent text block (`TranscriptRoleFilter.assistant`), even when
  tool calls come after it. A local scan (§6) found that 15–18% of Codex and OpenCode tool turns
  end on a tool call, so "last block before the next prompt" would lose many answers.
- Every other agent text block in the turn is a **note**.
- A turn with no agent text has no answer. It shows only the prompt. No marker row (owner: no
  bloat). Errors (§3.2) still show.
- **A turn still running** shows all its agent text. "Running" means: it is the session's last
  turn AND the live model reports the session as actively working
  (`CodexActiveSessionsModel.isActive`, i.e. `isActiveWorking`). NOT `isLive`: `isLive` is also
  true for an open but idle session, which would keep notes visible after the answer until the
  next prompt. (Claude's call: otherwise a live reader sees each message appear, then vanish when
  the next one lands, and every reclassification turns the append-only live update into a
  reload.)
  - The turn closes, and its notes hide, on any of: a next turn start; an interrupt marker
    (`isInterruptControlMessage`, or the Codex `turn_aborted` `.meta` block, both already
    recognized in `ToolInvocationPairing.swift:91,304`); the session leaving the working state
    (working → idle), even with no new transcript event.
  - Fallback: when live detection is disabled or unsupported for the source, `isActive` is false,
    so every turn is closed (notes hidden). No other heuristic.
  - The turn/answer/note split in the derived state must NOT depend on live state (the snapshot
    key `TranscriptDerivedState.Key` has no live input, and must not get one). Apply the running
    exception at row emission, as an input like `activeRoles`, so a working → idle change
    re-emits rows without a new snapshot.
  - Wiring: `isActive` reads `latestSnapshot`, which SwiftUI observation ignores, so the view
    will not re-render on its own. Subscribe to the model's existing `presenceUpdates` signal
    (`CodexActiveSessionsModel.swift:200`, sent in `apply`). Builder: confirm a working → idle
    change actually bumps `membershipVersion` and fires it; if not, use the signal that does
    (`isActive` reads `liveState`). Do not add polling.
- Approval verdicts (`origin == .approvalVerdict`, Codex guardian sessions) follow the general
  rule: a verdict that is the turn's last agent block is its answer and stays visible. In a
  guardian transcript the verdict is usually the only answer.
- Compute turn and note membership once per snapshot in the derived-state layer
  (`TranscriptDerivedState`, next to `messageGroups`), not per render. See memory
  "Derived-state layer diagnosis": 2026-07 perf bugs came from missing derived data.

### 3.2 The Tools chip

- Keeps its name, place and accent swatch.
- **Tools becomes a plain on/off switch**, outside the focus-then-restore rule
  (`TranscriptPlainView.toggleRoleFilter`). You, Agent and Errors keep that rule among
  themselves, with "all three on" as its base state. Tools on/off does not change their state.
  (Claude's call: under the current rule, from all-on a Tools click focuses to tools only and
  never returns to Tools off; and with the new default not "all on", the other chips would lose
  focus-on-first-click.)
- **Off** hides tool rows (calls, outputs, group headers) **and notes**. **On** shows both,
  unfolded:
  - Every tool group the user has not toggled starts **open**: its header plus one row per
    invocation, each at its L1 summary. This replaces today's seed (`seedOpenState`: groups
    start folded unless they hold a failure).
  - Output bodies (L2) do not open. Failed invocations still open at L2, as today.
  - A group or invocation the user opened or closed by hand keeps that state across Tools
    off/on cycles while the session stays open (today's "never reseed after a user toggle" rule).
  - The per-group fold and its context menu stay. No new expand-all.
- While off, the chip shows the session's tool-call count in muted text, e.g. "Tools 142". This
  extends the rule at `TranscriptPlainView.swift:1441` ("Errors is the only role whose count
  changes the decision to press it"): the count answers "are there tools at all?". No count
  while on. No count when the session has no tool calls (chip dims as today).
- Tooltip names both: "Show tool calls and the agent's working notes" / "Hide …".
- Errors chip on: failed tool invocations still show while Tools is off (existing
  `showsFailedInvocations` path in `TranscriptToolRows`). Keep it.
- Agent chip: governs answers. With Tools off, "show only Agent" shows answers only. With Tools
  on, it shows answers and notes. Notes follow both chips: shown only when Agent and Tools are
  both shown.
- Tools ▲▼ jump: available only while Tools is on (as today for a hidden role).
- **One visibility rule.** A note is visible when Agent is shown AND (Tools is on, OR its turn
  is running (§3.1), OR Find has revealed it (§3.4)). Row emission, Agent ▲▼ stops, the
  chevron's enabled count (`roleOccurrenceCount`) and the turn-timing badge anchor all use this
  one rule, never a copy of it.
- Agent ▲▼ jump: stops only at agent blocks that have a visible row. Today
  `handleRoleJumpIntent` builds Agent stops from the full block stream
  (`TranscriptBlockListView.swift:3724`), so a hidden note would be a stop that `scrollToBlock`
  cannot reach, with the chevron still enabled.
- **Turn timing badge** ("2m 57s · 14 tools", `turnChipText`): today it anchors to the turn's
  first visible agent message (`TranscriptTurnTiming.swift:104`), often a note. It must anchor to
  the turn's first agent block that is visible under the rule above, so with notes hidden it sits
  on the answer. No extra row. A turn with no visible agent block shows no badge, as today.

### 3.3 Default and migration

- New default for `@AppStorage("SessionRoleFilters")`: `user,assistant,errors`.
- Existing users get it once too. Decision (owner delegated it): a one-time migration removes
  `tools` from the saved value. Their other chip choices stay. If the saved value was only
  `tools`, reset to the new default. Guard with a one-time flag so a user who turns Tools back
  on keeps it.
- Why everyone: the tool view shipped in 6.4 only days ago, so few habits exist; mixed defaults
  between old and new installs make support answers depend on install date; the hint (§3.5)
  and What's New explain the change; one click restores.

### 3.4 Find

- Scope: rows hidden **because Tools is off** (tool rows and notes). Rows hidden by the You,
  Agent or Errors chips keep today's behavior (dropped by `matchesUnderActiveRoleFilter`,
  `TranscriptBlockListView.swift:3979`): the user chose that filter on purpose. (Claude's call.)
- Applies to both entry points, ⌘F and the session-list search pill, which share `applyFind`.
  The pill is how most users arrive; with Tools off by default, a search hit in tool output
  must still land on its row. `jumpToRawOnlyToolMatch` (line ~4206) returns early when Tools is
  hidden today; it must work with Tools off and reveal the row it opens.
- **Search-pill landing rule.** The list hands over only a session id
  (`UnifiedSearchState.requestAutoJump`), no target row. Keep today's rule with the wider
  eligibility: land on the first eligible match at or after the viewport top, where eligible now
  includes rows hidden by Tools-off. The raw-text fallback still runs only when there are zero
  eligible matches (`TranscriptBlockListView.swift:3830`). When a query matches an answer and
  also raw-only tool text, landing on the answer is correct; reaching raw-only tool text when
  other matches exist is the existing pre-P3 limitation, not in scope. With zero eligible
  matches, the fallback must open the invocation even when Tools is off and the invocation sits
  in a group that is folded or hidden.
- Find counts matches in those hidden rows in its total.
- Landing on a hidden match reveals that row (its tool group, or its note) until find is
  cleared, using the existing auto-open path (`autoExpandCollapsedMatch`,
  `autoOpenedGroupsByFind`, `recollapseAutoExpandedFindRows`). A row the user toggles by hand
  stays as the user left it.
- The chip state does not change during find.
- **A reveal overrides Tools-off only.** It never overrides You, Agent or Errors. When any chip
  changes while find is active, recheck every revealed row: a note revealed while Agent was on
  hides again when Agent turns off, and its match leaves the count. For a tool match the rule
  applies to the invocation row, as `TranscriptToolRows.showsInvocation` does today: an `.error`
  block paired with an invocation follows that invocation; a standalone error follows the Errors
  chip (`testFindWithErrorsOffKeepsMatchInPairedErrorOfShownInvocation`).
- Revealing a row the filter hides is new work: today's auto-open path only opens folded rows
  that already exist.

### 3.5 Discoverability

- The muted count on the chip (§3.2).
- A one-time hint, the first time a session with tool calls opens after this ships: a small
  popover or inline note anchored to the Tools chip: "Tool calls and working notes are hidden.
  Click Tools to show them." Dismissed for good on close or on any Tools click. Shown once per
  user, not per session. Match existing HIG popover style (`agents.md`).
- A What's New entry and CHANGELOG line in the release that ships this.

## 4. Constraints

- `agents.md`: HIG spacing tokens and design language; Conventional Commits; new Swift files via
  `scripts/xcode_add_file.rb`.
- New localized strings need the xcstrings entry and the pinned key count in
  `scripts/tests/test_validate_localization_catalogs.py`.
- No measurable regression in Session view open time (6.4 bar: Release open time within ±5% of
  main for Codex and Claude).
- Tests that start the app host open the live index (memory "Tests mutate the live index").

## 5. Left to the builder

- Popover vs inline note for the hint, and its storage key name.
- Migration flag name and where it runs (app launch or first Session view load).
- How notes are excluded at row emission (`applyingRoleFilter` vs `TranscriptToolRows.emit`).
- Test shape. Required coverage: turn/answer/note split (answer followed by tools; no answer;
  blocks before first prompt; parent-task turn), migration cases (default, custom, tools-only,
  already migrated), find landing on a hidden tool row and on a hidden note, Tools click never
  changes You/Agent/Errors, Errors-on with Tools-off, and these acceptance cases:
  - Working → idle with no new transcript event re-hides the last turn's notes. Drive it through
    the presence model (a presence emission that flips the session out of working), not by
    passing `false` to the row builder, so the subscription wiring is tested. An interrupt
    marker closes the turn; live detection off means notes hidden.
  - Find reveals a note with Tools off: Agent ▲▼ can reach it and the enabled count includes it;
    clearing Find hides it and drops it from both.
  - Turn timing badge with Tools off sits on the answer; with Tools on it returns to the first
    agent message.
  - Search pill with Tools off: raw-only tool hit inside a hidden group opens that invocation;
    a query matching an answer plus raw-only tool text lands on the answer.
  - First Tools-on click opens every untouched group at L1; a group closed by hand stays closed
    after Tools off → on.
  - Find reveals a note, then Agent turns off: the note hides and the total drops by its matches.
  - Paired error inside a revealed invocation counts; a standalone error with Errors off does not.
  - Guardian session: the verdict that ends a turn stays visible as its answer.
  - Agent ▲▼ with Tools off never targets a hidden note, and its enabled state matches the
    visible stop count.

## 6. Evidence: how often findings sit in a note

Local scan, 2026-11-08, owner's own sessions (counts only; scripts in the session scratchpad).
"Findings mid-turn" = final < 300 chars and an earlier note ≥ 600 chars and ≥ 2× the final.

| | Claude | Codex | OpenCode |
|---|---|---|---|
| Turns with ≥ 2 agent messages | 2,562 | 284 | 156 |
| Findings mid-turn | 5.1% | 1.8% | 1.3% |
| Longest message is a note (≥ 1.5×) | 13% | 6% | 19% |
| Tool turns ending on a tool call | 4.6% | 17.7% | 18.4% |

Examples of "findings mid-turn" were mostly status lines ("Task 10 is running its full test
suite…"). Hiding notes is safe; find and the Tools chip cover the rest.
