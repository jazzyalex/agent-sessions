# Runway Sidebar Handoff PRD

Status: Draft handoff
Date: 2026-06-14
Owner: Product / Agent Cockpit
Scope: Design a compact session-consumption tracker for indie users on fixed 20/100/200 USD-style subscriptions.

## One-Page Summary

This is not token analytics. It is a **plan-relative runway tracker** for an indie developer who wants to protect real 5h and weekly subscription limits.

The existing **Limits Cockpit works because it is clock-first, not interpretive**:

```text
Codex 5h: 91%  >1h35m  ↻3h33m
```

The user immediately compares two clocks:

- Burn-out ETA: `>1h35m`
- Reset ETA: `↻3h33m`

If burn-out comes before reset, the provider is under pressure. Runway should extend that same grammar. It should not introduce vague compact labels like `RISK`, `SAFE`, `WATCH`, `main drain`, or `light burn`.

Runway should answer:

1. Which active session is making the current 5h burn-out clock happen?
2. What would the 5h burn-out clock become if I paused that session?
3. How much runway would I gain by pausing it?
4. Is the top issue a persistent goal session or just short bursts?
5. Which session should I pause first if I need to protect the 5h window?

Core compact grammar:

```text
[session]                  [new 5h deadline if paused]   [runway gained]
GOAL auth-flow             after reset                    +1h58m
GOAL academy repair        >1h52m                         +17m
release notes              no change                      -
+7 bursts                  >1h44m                         +9m
```

This mirrors Limits Cockpit instead of inventing a second language. The numbers carry the interpretation.

## Final Product Shape

### Keep Limits Cockpit Compact

Limits Cockpit remains the always-visible provider status surface:

- Provider.
- 5h usage.
- Burn-out ETA.
- Reset ETA.
- Weekly status/projection where it already fits.

Do not put the top session list into the collapsed Limits Cockpit.

### Add Runway As Pause-Impact Surface

Runway is the compact session-consumption surface adjacent to, or expanded from, Limits Cockpit:

- Show current provider 5h clock as the baseline.
- Show the top sessions by pause impact.
- For each session, show the new 5h deadline if that session were paused.
- Show the gained runway as a compact delta.
- Mark long-running goal sessions with `GOAL`.
- Fold low-impact prompt bursts into `+N bursts`.

The primary question is:

> What happens to the current 5h deadline if I pause this session?

Not:

> What is this session's token rate?

Not:

> Is this session good or bad?

## Final Compact Mockups

### Single Provider

```text
┌────────────────────────────────────────────────┐
│ Runway                                         │
├────────────────────────────────────────────────┤
│ Codex 5h              >1h35m        ↻3h33m     │
│ Pause impact                                   │
│ GOAL auth-flow        after reset   +1h58m     │
│ GOAL academy          >1h52m        +17m       │
│ notes                 no change     -          │
│ +7 bursts             >1h44m        +9m        │
└────────────────────────────────────────────────┘
```

Tighter sidebar version:

```text
┌──────────────────────────────────────┐
│ Runway                               │
├──────────────────────────────────────┤
│ Codex 5h  >1h35m  ↻3h33m             │
│ GOAL auth-flow   after reset  +1h58m │
│ GOAL academy     >1h52m       +17m   │
│ notes            no change     -     │
│ +7 bursts        >1h44m       +9m    │
└──────────────────────────────────────┘
```

Meaning:

- `GOAL auth-flow after reset +1h58m`: if paused, Codex 5h burn-out moves from `>1h35m` to after the reset at `↻3h33m`; this is the session causing the pressure.
- `GOAL academy >1h52m +17m`: long-running goal, but pausing it only gains 17 minutes; not the main cause.
- `notes no change -`: no meaningful current 5h impact.
- `+7 bursts >1h44m +9m`: short sessions together matter a little, but not enough to outrank the main goal.

### Multiple Providers

Group by provider because each provider has its own 5h clock and reset:

```text
┌────────────────────────────────────────────────┐
│ Runway                                         │
├────────────────────────────────────────────────┤
│ Codex 5h             >1h35m         ↻3h33m     │
│ GOAL auth-flow       after reset    +1h58m     │
│ GOAL academy         >1h52m         +17m       │
│ +7 bursts            >1h44m         +9m        │
│                                                │
│ Claude 5h            >2h10m         ↻3h34m     │
│ GOAL docs-agent      >2h51m         +41m       │
│ chat polish          no change      -          │
└────────────────────────────────────────────────┘
```

If space is tight, show providers with active 5h pressure first. Providers with no pressure can be collapsed or omitted from the compact view.

## Compact UI Rules

Do show:

- Current provider 5h burn-out ETA.
- Current provider 5h reset ETA.
- Session name.
- `GOAL` marker.
- New deadline if paused: `after reset`, `>1h52m`, `no change`.
- Runway gained: `+1h58m`, `+17m`, `+9m`.

Do not show in compact UI:

- `RISK`
- `SAFE`
- `WATCH`
- `STEADY`
- `main drain`
- `minor`
- `light burn`
- Raw token rates.
- Percent of active burn.
- Sampling windows such as `last 10m` or `last 30m`.

Those can exist internally or in hover/detail, but the compact UI should remain clock-first.

## Mockups Tried And Lessons

### Tried: Session Consumption Table

```text
┌────────────────────────────────────────────────────────────┐
│ Session Consumption                         Window: last 10m│
├────────────────────────────────────────────────────────────┤
│ 1. refactor-auth-flow      -10m 5h   -18m wk   Risk        │
│    AS / Codex              62% of active burn   mixed       │
│                                                            │
│ 2. academy data repair     -3m 5h    -5m wk    Safe        │
│    TAM / Codex             21% of active burn   direct      │
│                                                            │
│ 3. release notes polish    flat      flat      Waiting     │
│    CH / Codex              no quota movement yet            │
│                                                            │
│ Others                     -2m 5h    -3m wk                 │
└────────────────────────────────────────────────────────────┘
```

What was useful:

- Ranking the top sessions.
- Showing `mixed` attribution.
- Separating 5h and weekly impact.
- Summarizing others.

What was wrong:

- Too much table density.
- `62% of active burn` is noisy unless total burn is dangerous.
- `-10m 5h` alone does not express how it changes the clock.
- `Window: last 10m` exposes instrumentation instead of user value.
- Verdict labels duplicate what the clock already explains.

### Tried: Label-Based Runway

```text
┌────────────────────────────────────────────┐
│ Runway                         2h check    │
├────────────────────────────────────────────┤
│ GOAL  refactor-auth-flow      RISK 74m     │
│       burns 5h fast           main drain   │
│                                            │
│ GOAL  academy data repair     SAFE 2h      │
│       light burn              minor        │
│                                            │
│       release notes polish    IDLE         │
│       no current burn         short        │
│                                            │
│ +7 short bursts               14m 5h today │
└────────────────────────────────────────────┘
```

What was useful:

- `GOAL` marker is important.
- Top 3 plus short-burst summary feels right.
- Time-based display is better than tokens.

What was wrong:

- `2h check` was just a lunch example and should not become the product frame.
- `RISK`, `SAFE`, `WATCH`, `main drain`, and `minor` add interpretation noise.
- `Safe 2h` requires the user to ask "safe for what horizon?"
- The compact row should show how pausing changes the current clock.

### Tried: Expanded Detail

```text
┌────────────────────────────────────────────────────────────┐
│ Codex runway                                                │
├────────────────────────────────────────────────────────────┤
│ Now:        1h14m 5h quota left, resets 3:42 PM             │
│ Leave-run:  Risk, empty in about 74m                        │
│ Weekly:     OK, projected 55% left                          │
│                                                            │
│ Top consumers                                               │
│ 1. AS    refactor-auth-flow          -10m/2m   mixed        │
│ 2. TAM   academy data repair          -3m/8m   direct       │
│ 3. CH    release notes polish         flat      waiting      │
│                                                            │
│ Others: 2 active sessions, about -2m combined               │
│ Action: pause refactor-auth-flow first                      │
└────────────────────────────────────────────────────────────┘
```

What remains useful for detail:

- Explaining attribution.
- Showing the recent sample window.
- Showing raw 5h movement.
- Showing weekly projection.
- Explaining "pausing this likely moves burn-out from X to Y."

What should not remain in compact:

- The label-based verdict.
- The heavy table.
- The sampling window.

## Core Calculation

Use the existing all-session 5h burn projection as baseline.

```text
currentOut =
  remaining5hQuota / totalActiveBurnRate

withoutThisSessionOut =
  remaining5hQuota / (totalActiveBurnRate - sessionAttributedBurnRate)

impact =
  withoutThisSessionOut - currentOut
```

Display cap:

```text
if withoutThisSessionOut >= resetTime:
    show "after reset"
else:
    show formatted burn-out ETA, e.g. ">1h52m"
```

Then show `impact` as the gained runway:

```text
after reset  +1h58m
>1h52m       +17m
no change    -
```

Edge cases:

- If sessionAttributedBurnRate is zero or too small to matter, show `no change`.
- If removing the session makes totalActiveBurnRate zero, show `after reset`.
- If attribution is mixed, compact can still show the pause-impact estimate, while detail labels it `mixed`.
- If data is stale or unsupported, show `--` or omit the provider/session; never imply zero.

## Ranking Rule

Rank sessions by:

```text
how much pausing this session extends the current 5h burn-out deadline
```

Do not rank by:

- Raw tokens.
- Percent of active burn.
- Total historical usage.
- Goal status alone.

Tie-breakers:

1. Higher gained runway first.
2. Goal sessions before short bursts when impact is similar.
3. Active sessions before recently ended bursts.
4. Sessions with clearer attribution before mixed attribution.

This makes the top row the session that most improves the current `>1h35m` deadline.

## Goal Sessions

Goal sessions matter because they may continue unattended for hours or days.

Show `GOAL` when a session:

- Has an active goal or long-running objective.
- Is a parent/root session coordinating subagents.
- Has persisted long enough that unattended burn matters.
- Has recent quota movement and no obvious stopping point.

`GOAL` is not a warning label. It means "this can keep consuming if left alone."

The numeric impact still decides severity:

```text
GOAL academy repair        >1h52m        +17m
```

This says the goal may continue, but it is not destroying the current 5h window.

```text
GOAL refactor-auth-flow    after reset   +1h58m
```

This says pausing the goal solves the current 5h pressure.

## Short Bursts

Many sessions are short-lived or prompt-burst-driven. Do not let them dominate the UI.

Default display:

```text
+7 bursts                  >1h44m        +9m
```

Only promote an individual burst into the top list when it is:

- Currently active and has meaningful pause impact.
- The biggest contributor to the current burn-out clock.
- Creating a near-term 5h pressure problem.

## Weekly Limits

The compact grammar is centered on the 5h deadline because that is the immediate clock shown in Limits Cockpit.

Weekly should be included when it changes the answer:

- Provider-level weekly prediction can remain in Limits Cockpit if it already fits.
- Runway detail can show weekly impact for the same pause action.
- Compact Runway can add a secondary weekly line only if weekly is the actual constrained window.

Do not make weekly average velocity a primary compact concept unless the weekly limit is under real pressure. Weekly math is harder for users to interpret because normal weekly usage velocity varies by day.

## Attribution Model

Provider rate limits are account-level, so per-session attribution is not always exact.

Confidence labels:

- `direct`: one plausible consuming session with strong log-path/session-id match.
- `mixed`: multiple active sessions could have contributed.
- `waiting`: not enough samples.
- `unsupported`: no proven source.

Compact UI should not foreground these labels. Hover/detail should explain:

```text
Pausing this session would likely move Codex 5h run-out
from >1h35m to after the reset at ↻3h33m.

Attribution: mixed
Recent sample: last 10m
5h movement: 3.3%
```

## Data Sources

MVP:

- Provider-level baseline: existing 5h burn-out ETA and reset ETA from Limits Cockpit data.
- Per-session attribution: Codex first.
- Use local Codex JSONL `rate_limits`.
- Tokens are diagnostics only.
- Do not add provider calls, probes, network requests, or shell commands for measurement.

Later:

- Claude per-session runway only after a proven source exists.
- OpenCode per-session runway only after a proven source exists.

Unsupported providers must show `--`, omit rows, or use `unsupported` in detail. They must never imply zero consumption.

## UI Placement

Recommended:

- Keep compact Limits Cockpit unchanged.
- Add Runway as an expanded detail panel, drawer, or compact sidebar.
- Show top 3 rows by pause impact by default.
- Show top 5 only when space allows.
- Detail on hover/click can reveal exact math, sample window, confidence, and weekly impact.

Do not:

- Add a new full dashboard.
- Put a top-3 session list in the collapsed Limits Cockpit.
- Add heavy controls to the compact UI.
- Force the user to understand sampling windows.
- Use compact verdict labels when time clocks are enough.

## Acceptance Criteria

1. Runway shows the provider's current 5h burn-out ETA and reset ETA.
2. Runway ranks sessions by gained 5h runway if paused.
3. Each compact row shows session name, new deadline if paused, and gained runway.
4. Goal sessions are visibly marked with `GOAL`.
5. Short bursts are folded into a summary row unless one has high pause impact.
6. Compact UI does not use `RISK`, `SAFE`, `WATCH`, `main drain`, `minor`, or `light burn`.
7. Compact UI does not expose raw tokens, percent of active burn, or sampling windows.
8. Hover/detail can explain attribution, sample window, 5h movement, and weekly impact.
9. Unsupported providers do not imply zero consumption.
10. Limits Cockpit remains compact and provider-focused.
11. No provider calls, network operations, new probes, or shell commands are introduced for measurement.

## Handoff Decision

Build this as a **pause-impact Runway surface adjacent to Limits Cockpit**.

Default compact content:

- Provider baseline: `Codex 5h >1h35m ↻3h33m`.
- Top 3 sessions ranked by how much pausing them extends that deadline.
- `GOAL` marker where applicable.
- New deadline if paused: `after reset`, `>1h52m`, `no change`.
- Runway gained: `+1h58m`, `+17m`, `-`.
- Short-burst summary.

Everything interpretive belongs in hover/detail, not the compact row.
