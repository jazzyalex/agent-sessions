# Universal click-to-focus — take me to that session

Status: spec, awaiting approval. No code written.
Branch: `feat/universal-click-to-focus`.

## The rule

**Clicking a session row takes you to that session's home.**

| Where the session lives | Click lands you |
| --- | --- |
| iTerm2 | The exact tab (existing behavior, unchanged) |
| Terminal.app, Ghostty, Warp, WezTerm, Kitty, Alacritty, anything else | That terminal app, frontmost |
| Codex desktop, Claude Desktop | That app, frontmost |
| Nowhere — session has ended, only its log survives | Its transcript in the main Agent Sessions window |

One rule, no exceptions, no dead rows. Everything below follows from it.

Exact-tab precision for non-iTerm terminals is **out of scope** — it needs AppleScript plus
Automation consent. App-level focus is the accepted outcome there.

## Why the rule is shaped this way

The Quota Meter is a glanceable readout with one verb — *take me there* — not a control
surface. Users park it always-on-top and work somewhere else. The nearest mental model is a
notification banner or a menu bar extra: you click the status thing and it deposits you where
the work is.

That framing resolves a constraint that otherwise forces awkward special-casing.

**The constraint:** clicking the QM while Agent Sessions is in the background activates the app
and raises its window layer. This is OS-level app activation — it happens before the event
reaches any view, so no click handler can prevent it. The only way to suppress it is converting
the widget to a non-activating panel (see Follow-up).

Under a live-rows-only design that constraint is a defect: clicking a row that can't be focused
does nothing useful *and* leaves the main window sitting on your screen. Under the unified rule
the `.transcript` branch turns it into the correct outcome — a log-only row's home *is* the main
window, so there the activation is precisely what the click meant.

**Be honest about the other three branches.** For live rows the activation is not intended, only
*masked*: Agent Sessions activates, then the destination app activates over it. Two residues
survive, and both are accepted knowingly rather than solved here:

- **Z-order.** The main window ends up raised behind the destination. If it was already open it
  simply moved up the stack; the end state is correct (destination frontmost) but AS now sits
  above apps it was previously below.
- **Flicker on repeat.** Clicking a row whose destination is *already* frontmost still
  ping-pongs — AS activates, the destination re-activates — for a brief visible flash.

Only the non-activating panel conversion (see Follow-up) removes these. What the unified rule
buys is narrower but real: it removes every case where activation produces a *wrong* outcome,
which is what made the live-rows-only design untenable.

This is why there is no error state anywhere in this spec. No click is dead, so there is
nothing to report. The product test for any click is not "did it activate the app" but
**"is the thing now in front the thing the user meant?"**

## Verified findings

Checked against a live machine on 2026-07-20 with Codex desktop and Claude Desktop running.

### 1. Desktop sessions are not detected today

The premise that desktop sessions are already discovered and merely unfocusable is **false**.
Both die at a tty gate, at different ones.

**Gate A — `AgentSessions/Services/PresenceEngine.swift:1053`** (also `:1063` opencode,
`:1073` antigravity): `guard info.tty != nil`. `ps` reports `??` for GUI-parented processes and
`parsePSCommandListOutput` maps `??` to `nil`
(`AgentSessions/Services/CodexActiveSessionsModel.swift:3274`). The five live Claude Desktop
`claude` processes never reach `lsof`.

**Gate B — `AgentSessions/Services/CodexActiveSessionsModel.swift:3151`**: final filter
`v.tty != nil && (v.sessionLogPath != nil || v.cwd != nil)`. Applies to every source including
Codex, which has no ps prefilter. Codex's app-server (PID 26196 at time of check) has fd 0/1/2
as `unix` sockets rather than `CHR` devices, so the stdio heuristic at `:3111` never sets
`info.tty` and the row is dropped.

**Correlation works once the gates are relaxed:**

- Codex desktop holds open rollout handles under `~/.codex/sessions/` (2 files on PID 26196).
- Claude Desktop holds **zero** session-log handles — normal, because Claude is correlated by
  cwd plus recency at `PresenceEngine.swift:1173-1180`. All five PIDs reported real project cwds.

### 2. Bundle identifiers — path correction

There is no `/Applications/Codex.app`. Codex desktop ships inside **`/Applications/ChatGPT.app`**,
`CFBundleIdentifier` = `com.openai.codex`. Claude Desktop is `/Applications/Claude.app` →
`com.anthropic.claudefordesktop`. Both verified with `defaults read`. The bundle ids match
CodexBar's mapping; only the path assumption was wrong. **Resolve by bundle id, never by path.**

### 3. Target surfaces — QM and the main session list only

**The Agent Cockpit is being deprecated** (owner, 2026-07-20). It is not a target of this work.
No Cockpit-only code, strings, or affordances are to be added, extended, or fixed here.

Two surfaces matter:

**Quota Meter** — the `.limits` mode of the HUD window (`AgentSessionsApp.swift:641`; mode enum
`AgentCockpitHUDView.swift:201`). Session rows are Runway drawer rows,
`HUDRunwayPanel.runwayRow` (`AgentCockpitHUDView.swift:5315`) — pure `Text` plus a load bar,
with **no click handling of any kind**. The QM has never had focus-in-iTerm2 or any other focus
affordance. Everything it gets here is new.

**Main session list** — `UnifiedSessionsView`, which has a working focus path today
(`focusActiveTerminal`, `:3040`) gated on iTerm2.

Not targets: the Cockpit's `.full` / `.compact` modes and their `AgentCockpitHUDRowView`
button rows, which die with the Cockpit.

**Already dead: `AgentSessions/Views/CockpitView.swift`.** `CockpitView(` is never constructed
anywhere in the app. The 719-line file compiles into the target and survives only because tests
call one static helper (`shouldHideUnresolvedPresencePlaceholder`,
`AgentSessionsTests/CodexActiveSessionsRegistryTests.swift:1883`). It is not a call site for
anything and should be deleted as separate cleanup, not here.

### 4. Runway rows are not presences — and that is fine

`RunwayPauseImpactRow.id` equals `RunwaySessionIdentity.id`
(`CodexStatus/CodexRunwayModel.swift:340`, `:224`), and the identity carries `logPaths: [String]`.

Identities come from several producers including disk scanners such as
`ClaudeStatus/ClaudeRunwayRecentSessionScanner.swift:96`, so a row can exist with no live
presence. Under the unified rule that is not a failure mode — it is the log-only branch.

**Both destinations are reachable from `logPaths`:**

- Live presence → match against presence `sessionLogPath` / `openSessionLogPaths` → focus.
- No presence → `SessionLookupIndexes.byLogPath` (`AgentCockpitHUDView.swift:303`, keyed by
  `CodexActiveSessionsModel.logLookupKey(source:normalizedPath:)`) → `Session` → existing
  transcript navigation.

The transcript path is **already built**: `goToSession` (`AgentCockpitHUDView.swift:2259`) stores
a `PendingCockpitNavigationRequest` via `CockpitNavigationBridge` and calls
`AppWindowRouter.showAgentSessionsWindow()`. The log-only branch is wiring, not new machinery.

### 5. The drag constraint

The QM is dragged by its background (`AgentCockpitHUDWindow.swift:244`,
`isMovableByWindowBackground = true`); rationale documented at
`CodexStatus/UsageDisplayMode.swift:104-117`. It is a plain `NSWindow` — not a panel, not
non-activating (`.statusBar` level when pinned, `hidesOnDeactivate = false`).

A view that implements `mouseDown` reports `mouseDownCanMoveWindow == false`, which is what
kills background dragging over that view — see the explicit warning on `RightClickView`
(`AgentCockpitHUDView.swift:3729-3731`). Since the unified rule makes **every** row clickable,
every row claims the mouse-down, so preserving the drag requires the shim:

```
mouseDown    -> store event, record origin, didDrag = false, take no action
mouseDragged -> if hypot(dx, dy) > ~4pt { didDrag = true; window?.performDrag(with: stored) }
mouseUp      -> if !didDrag { activate(row) }
```

`performDrag(with:)` hands the drag to the window mid-gesture, preserving drag-from-anywhere.

This is the main technical cost of the product simplification, and it is accepted deliberately.
Two things bound the risk:

- **Contained blast radius.** If the shim is imperfect you lose drag-*from-a-row* and keep
  drag-from-background. That is far softer than "QM unmovable".
- **Different failure mode from the prior rollbacks.** Those were geometry-changing-under-the-
  cursor problems (hover-resize, hover-expansion moving the drag target mid-grab). The shim
  changes no geometry at all — it is purely event routing, and drag-from-a-row is directly
  testable.

If drag-from-a-row cannot be preserved, **stop and report** rather than shipping a regression.

## Design

### FocusCapability

Replace the iTerm-only gate with a resolver returning the best achievable destination:

```
.itermTab(guid)         // existing exact-tab path, unchanged. Best case.
.desktopApp(bundleID)   // no tty, source maps to a desktop app
.terminalApp(bundleID)  // owning GUI terminal resolved from tty/pid or TERM_PROGRAM
.transcript(sessionID)  // no live presence — open it in the main window
```

There is no `.none`. Resolution order: `.itermTab`, `.desktopApp`, `.terminalApp`, then
`.transcript` as the universal floor. A row that resolves to nothing at all (no presence, no
indexed session) is not rendered as a session row in the first place.

Execution:

- `.itermTab` — existing `tryFocusITerm2`, untouched.
- `.desktopApp` / `.terminalApp` — `NSRunningApplication` matched by bundle id, then `activate()`.
- `.transcript` — existing `goToSession` path.

Nothing may block on or trigger a consent dialog. Any path that would need Automation consent
drops silently to app-level focus.

### Graceful degradation

**Any focus failure, for any reason, falls through to `.transcript`.** A session that died
between render and click, a destination app that has since quit, a bundle id that resolves to
nothing running — all take the same path. No error UI; the row's live dot corrects itself on
the next refresh. This follows the house preference for explicit honest status over ambiguous
states.

**Never launch a destination app that is not running.** Launching is slow, surprising, and if
the app is gone the session is not live anyway — the transcript is the honest destination.

### Spaces and multiple displays

The QM is pinned across all Spaces (`canJoinAllSpaces`, `AgentCockpitHUDWindow.swift:144`); its
destinations are not. A click can therefore switch Spaces — including the `.transcript` branch,
which raises the main window on whatever Space it last occupied.

This is **intended**, not a defect: "take me there" means going there. It is also not new
behavior, only newly generalized — the existing iTerm2 path already crosses Spaces. It is
recorded here because it is the widget's single most disorienting moment and should be a known
at QA time rather than a surprise.

### TerminalKind

`AgentSessions/Services/TerminalKind.swift` maps iterm2 / warp / warpPreview / terminalApp /
unknown. It needs:

- **A universal fallback** — the only part actually required: if `__CFBundleIdentifier` names a
  running GUI app, activate it. This is what makes the feature "any terminal" rather than "six
  terminals", and it subsumes every named case below.
- Named cases for Ghostty, WezTerm, Kitty, Alacritty are **optional** and justified only where a
  human-readable `displayName` is shown in UI. They buy nothing for focus itself — the fallback
  already handles them. Add them only if a display string demands it. Resolution precedence
  stays `__CFBundleIdentifier` first, `TERM_PROGRAM` fallback (`TerminalKind.swift:12-27`).

### Hover affordance

Rows get a pointing-hand cursor and a faint background tint on hover, via `NSTrackingArea`.
Identical frame in both states — no padding change, no reveal, no expansion. This is consistent
with the QM doctrine, which forbids *resizing* on passive pointer movement, not tinting.

Destinations are **not** visually distinguished in v1. The row's existing `CodexLiveStatusDot`
already signals live vs. not, so users can predict whether a click leaves the app or opens a
transcript without any new visual language.

### The aggregate row

`+N sessions` (`HUDRunwayPanel.summaryRow`, `AgentCockpitHUDView.swift:5338`) aggregates
overflow sessions. Clicking it means "show me those sessions" — a labeled, countable thing that
does nothing when clicked reads as broken.

The rule already answers it: that row's home is the fuller view where those sessions are listed.
**Click opens the fuller view.** No second verb, no exception to the rule.

Unfold-in-place was considered and rejected: it is click-driven geometry change on the one
window carrying two geometry-related rollbacks, and it invents a second interaction vocabulary
for the sake of one row. Pure no-op is also rejected — a labeled, countable thing that does
nothing reads as broken.

### Detection prerequisite (desktop sessions)

Relax the two tty gates so a no-tty process survives when it has a concrete session log or
usable cwd:

- Gate A: allow no-tty PIDs through the ps prefilter for desktop-app command paths.
- Gate B: `(v.tty != nil && (v.sessionLogPath != nil || v.cwd != nil)) || v.sessionLogPath != nil`.

Load-bearing risks to respect:

- `coalescePresencesByTTY` (`CodexActiveSessionsModel.swift:741`) keys dedup on tty and routes
  tty-less presences to a separate bucket. More tty-less rows means more traffic through the
  weaker `coalesceIdentity` path.
- The pipeline feeds QM, Runway, and Cockpit and has a documented history of perf regressions.
  Relaxing the prefilter queries `lsof` for more PIDs per refresh.
- Loosening the claude needle admits the Electron main process
  (`/Applications/Claude.app/Contents/MacOS/Claude` → basename `claude`). It carries no session
  log so it should fall out later, but this needs an explicit test.

### Codex desktop holds several sessions per process

Codex desktop is **one** app-server process holding **N** sessions' rollout files (2 observed).
The presence model assumes 1 PID → 1 session — lowest-FD wins
(`CodexActiveSessionsModel.swift:3136`). Claude Desktop is one process per session and has no
such problem.

**Option A — one row per open rollout file.** Emit a presence per entry in `openSessionLogPaths`
(field exists, already populated for subagents). Most honest; each desktop session gets its own
row and focus target. Costs: changes row counts in QM and Cockpit; needs dedup against hydrated
rows; needs a stale-handle rule — the two observed files were dated June 1 and June 2, so the
process holds handles well past a session's active life.

**Option B — keep the lowest-FD single row.** Status quo heuristic, one row per process. No
row-count change, minimal diff. Costs: which session the row names is arbitrary, and given the
stale-handle observation it may name a session last touched weeks ago. For *focus* the
distinction is harmless — both activate the same app — but the label would be misleading.

**DECIDED: Option B.** Owner call, 2026-07-20. Option A is deferred to its own change.

Rationale — for *focus* the two
are indistinguishable — both activate the same app, as noted above. Option A is a session-roster
redesign (row counts, dedup against hydrated rows, a stale-handle recency rule) that would ride
into a click-behavior feature without being reviewed on its own terms. The misleading label is
real and worth fixing, but it is a labeling bug, not a blocker for this work.

Option A gated on handle recency remains the right eventual shape if the label is judged bad
enough to fix now. Owner decides.

### Call sites

`canAttemptITerm2Focus` (`CodexActiveSessionsModel.swift:1730`) is the current gate. It has four
callers; **only one is in scope.**

| Caller | Status |
| --- | --- |
| `UnifiedSessionsView.swift:3027` (`terminalFocusAvailability`), focus fn `:3040` | **In scope** |
| `AgentCockpitHUDView.swift:2252` (`canFocus`), focus fn `:2193` | Cockpit-only — dies with the Cockpit, not touched |
| `CockpitView.swift:175` and `:477` | Already dead code, not touched |

The QM is not on this list because it has no focus path today — step B builds one from scratch
against the resolver directly, never through this gate.

`canAttemptITerm2Focus` keeps its name and behavior — it is genuinely about iTerm — and becomes
one branch inside the resolver. Not renamed, so the out-of-scope callers keep compiling
untouched until the Cockpit is removed.

`revealURL` (`CodexActiveSessionsModel.swift:61-66`) only ever synthesizes an `iterm2://` URL,
so the `|| revealURL != nil` escape hatch in that gate is iTerm-only in practice and widens
nothing today.

**One user-facing string changes**: `UnifiedSessionsView.swift:3033`, "Focus the existing iTerm2
tab/window", becomes capability-dependent. The Cockpit's two equivalents are left alone.

## Out of scope

- Exact-tab precision for non-iTerm terminals.
- Anything Cockpit — its `.full` / `.compact` modes, `AgentCockpitHUDRowView`, its focus gate,
  and its "Focus in iTerm2" strings. Deprecated; not extended, not fixed, not migrated.
- Deleting `CockpitView.swift` (already dead) — separate cleanup.
- Hover-revealed buttons or any hover-driven geometry change.
- Converting the QM to a non-activating panel (see Follow-up).

## Follow-up, deliberately separate

Converting the QM to a non-activating `NSPanel` would remove app activation from *every* QM
interaction at once. It is not a flag flip: panel-ness is class-level, so the window must be
built in AppKit and host the SwiftUI view rather than come from the scene.

**The Cockpit deprecation makes this materially easier.** The main objection was that the window
is shared with the full Cockpit mode (search field, filters, toolbar), which would be dragged
into non-activating behavior too. Once the Cockpit is gone that window hosts only the QM — a
small pinned readout, exactly the thing a non-activating panel is *for*. This follow-up should
be re-evaluated the moment the deprecation lands, and is best sequenced right after it.

**Still desirable, sequenced later — not obsoleted.** The unified rule removes the cases where
activation produces a *wrong* outcome, but not the z-order and flicker residues documented
above; only the panel conversion does that. The end state it enables is strictly better than
this design: a non-activating panel that activates Agent Sessions *deliberately*, on the
`.transcript` branch alone, and never on the three live branches.

It is sequenced after this work so it gets QA'd against a QM whose click behavior is already
settled, rather than changing two risky things at once on the window with the rollback history.

## Sequencing

**DECIDED: A → C → B.** 2026-07-20.

Re-confirmed after the Cockpit deprecation changed the premise; the order did not change.

1. **A — Focus service.** Capability resolver plus the universal terminal bundle-id fallback.
   Prerequisite for both B and C. Immediate payoff lands in the main session list. No detection
   work, no gesture work. The only piece that stands alone.
2. **C — Desktop detection.** The two tty gates, Option B for Codex. Delivers the headline
   capability: click a Codex or Claude Desktop session, land in that app. Reviewed on its own
   branch so a presence-pipeline regression stays isolated.
3. **B — QM row interaction.** Drag shim, hover affordance, row-to-destination resolution,
   aggregate row. Drag-from-a-row verified here.

**Why not C first.** Detection alone makes desktop sessions appear in the main session list,
where every neighbouring row is clickable and focuses something. Under today's iTerm-only gate
those rows would be dead clicks sitting beside live ones — the one configuration users would
file as a bug. A-before-C is a dependency, not a preference: the resolver's `.desktopApp` branch
is what makes a detected desktop row *go* somewhere. The QM is not exposed to this hazard, since
its rows are uniformly inert today and C only adds more inert rows to an all-inert surface.

**Why B last — two reasons.**

*It is the only abortable piece.* B carries the drag-shim risk and an explicit stop-and-report
clause. Since C does not depend on B, putting B earlier would gate the P1 capability behind
gesture QA on the riskiest change for no dependency reason. Last means a stall strands nothing.

*C changes the population B must be QA'd against.* C adds rows to the QM — five Claude Desktop
processes were observed on one machine — which changes overflow behavior, and B implements the
aggregate `+N sessions` click. B-before-C would QA the drag shim, hover affordance, and
aggregate row against a row population that C then changes, forcing re-verification. Given the
rollback history, one QA pass against the final row set beats two against a moving one.

**The honest cost.** With the Cockpit gone, this order means the QM — the owner's primary
surface — shows nothing new until B lands. During the C→B gap, newly detected desktop sessions
are visible and clickable only in the main session list. That is a visibility delay in the QM,
not a defect: no click regresses and nothing reads as half-built.

**C must not ship alone.** Rows that appear but do nothing, in a surface where clicking is the
whole interaction model, read as half-built — worse than absence, because absence goes unnoticed
and a dead row does not.

## Visual surface

No new controls. No layout, geometry, spacing, sizing, colour, or typography changes. No new
panels, popovers, or sheets. `AgentCockpitHUDRowView` is not touched. Row frames are identical
in hovered and unhovered states.

Three visible deltas, all deliberate:

1. **Hover affordance (B)** — pointing-hand cursor and a faint background tint on QM rows. The
   only new visual state in the feature. Without it nothing signals that rows became clickable,
   so discoverability would be zero.
2. **String (A)** — one: `UnifiedSessionsView.swift:3033`, "Focus the existing iTerm2
   tab/window", becomes capability-dependent. Not cosmetic — that label would actively lie once
   a click focuses Ghostty or Claude Desktop. The Cockpit's equivalents are left alone to die
   with it.
3. **New rows (C)** — desktop sessions appear where they never did. More data, not new chrome,
   but it is the largest thing a user will notice.

## Open questions

None. Sequencing (A → C → B) and Codex multi-session (Option B) are decided above.

## Acceptance

- A Codex desktop session and a Claude Desktop session each focus their app.
- A Codex or Claude session in Terminal.app or Ghostty focuses that terminal app.
- A terminal not on the enumerated list still focuses via the bundle-id fallback.
- iTerm2 sessions still land on the exact tab.
- A log-only row opens its transcript in the main window.
- A session that dies between render and click falls through to its transcript, no error UI.
- A row whose destination app has quit falls through to its transcript — the app is not launched.
- The aggregate row opens the fuller view rather than doing nothing.
- QM drag unchanged — verified by dragging from **both** a session row and the background.
- App builds; full suite green.
