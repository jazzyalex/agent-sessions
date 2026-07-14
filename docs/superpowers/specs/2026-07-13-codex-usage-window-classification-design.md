# Codex usage: length-based window classification + drift guardrail

Date: 2026-07-13
Status: Design — awaiting review before implementation

## Problem

The Codex usage strip/menu-bar shows a mislabeled 5h line with a ~7‑day reset
("5h: 91% ▶1h 35m ↻ 6d 2h") and an empty weekly line ("Wk: 0% ↻ —"). The `▶`
runway is projecting a weekly burn against a hardcoded 5‑hour horizon.

## Root cause (evidence)

OpenAI temporarily dropped the 5‑hour rate-limit window. The live
`rate_limits` payload changed shape:

| field | Normal (7,527 log lines) | Now (last ~2 days) |
|---|---|---|
| `primary.window_minutes` | **300** (5h) | **10080** (7‑day) |
| `secondary` | `{ window_minutes: 10080 }` | **`null`** |

Every Codex parser maps the two rate-limit slots by **position**
(`primary → 5h`, `secondary → weekly`). With the weekly window now sitting in
`primary` and `secondary` null, the weekly data is painted as "5h" (hence the
6‑day reset) and the weekly slot is never populated.

Affected parse sites (all positional):
- `CodexStatusService.makeRateLimitSummary` — JSONL, the primary source
- `CodexCLIRPCProbe.parseRateLimitsResponseData` — CLI app-server RPC
- `CodexOAuthUsageFetcher.normalizeResponse` — chatgpt.com usage API
- `CodexRunwayRateLimitParser.parseRawLine` — feeds the `▶` runway/burn

Presentation gap: `UsageStripView` and `StatusItemController` render both the
"5h" and "Wk" meters unconditionally (the `has*RateLimit` flags live only on the
snapshot, not on the published model), so an absent 5h window shows a dead meter.

## Decisions (locked)

1. **Runway is kept, re-pointed onto the weekly window.** When the 5h window is
   gone, running sessions still show and still burn the bar — the bar is now the
   weekly cap. The m/h figure keeps its familiar "5h yardstick" reading.
2. **Guardrail = neutral "unavailable" + marker.** On genuinely uninterpretable
   data, blank the number, show a subtle marker + tooltip, never a guessed value,
   and recover automatically when a known shape returns.
3. **Split at 1440 min (1 day); lenient routing + precise guardrail.** Route by
   coarse window length; alarm only on uninterpretable data, not on merely
   unusual-but-sane windows.

## Architecture

One shared classifier, `CodexRateLimitWindowClassifier`, is the single home for
window→slot routing and the health verdict. All four parse sites call it instead
of assuming slot position. Presentation and runway read the normalized slots +
flags. Rationale: the guardrail rule and the classification logic must live in
exactly one place, or they drift across four call sites.

### Window class

```
enum CodexRateLimitWindowClass { case short, long }   // short = "5h", long = "weekly"

classify(windowMinutes: Int?, resetDistance: TimeInterval?) -> CodexRateLimitWindowClass?
```

- `windowMinutes` present: `< 1440` → `.short`; `>= 1440` → `.long`; `<= 0` or
  `> 62 days` → unclassifiable. (JSONL `RateLimitWindowInfo` already carries
  `windowMinutes`; OAuth derives it from `limitWindowSeconds / 60`; the CLI-RPC
  probe reads it if the app-server provides it under any of a few candidate
  keys — field name unconfirmed.)
- **When NO window in a response declares a length**, `route` falls back to the
  historical **positional** mapping (`primary → 5h`, `secondary → weekly`) so
  length-less legacy sources keep working exactly as before. Reset distance is
  **not** used to classify — a nearly-exhausted weekly window and a fresh 5h
  window overlap there, so guessing from it would risk showing wrong data. (This
  replaced an earlier reset-distance idea, which would have mis-flagged the
  existing length-less CLI-RPC test fixtures as suspect.)
- A window is `suspect` (not placed) when: its declared length is unclassifiable,
  its percentage is out of `[0,100]`, or two windows classify to the same class.
- Returns routing with `fiveHour?`, `weekly?`, and `suspect`.

Each parse site builds its raw windows, classifies each, and assigns to the
5h/weekly slot **by class**. Position is irrelevant. When `primary.window_minutes`
returns to 300, it lands back in the 5h slot automatically — no code change, no
migration.

### Guardrail — `usageFormatSuspect`

A new per-provider flag on `CodexUsageSnapshot` (and published on the model).
It trips when:
- a window is present but unclassifiable (no length **and** no sane reset), or
- a remaining/used percentage is out of `[0, 100]`, or
- two windows classify to the **same** class (can't disambiguate), or
- the payload carries rate-limit data but **zero** windows can be placed.

When it trips, the affected surface shows a neutral `—` + small warning glyph +
tooltip ("Codex changed its usage format — can't verify"), and no numeric value.
It clears on the next snapshot that parses cleanly.

Structural note: because routing is by length, a window can never again land in
the wrong slot — the original bug class is eliminated independently of the flag.
The flag is the last-resort net for data we cannot interpret at all.

Surfacing on a zero-window response: the OAuth and CLI-RPC parse sites emit their
snapshot when `hasData || usageFormatSuspect`, so a *fully* uninterpretable
authoritative response reaches the UI as the suspect state (and the merge, which
replaces missing windows, clears both lines and shows "can't verify") rather than
vanishing into stale data.

Clearing a dropped window: because the apply layer keys presentation off the
`has*RateLimit` flags, it must be able to *lower* them, not only raise them. A
complete authoritative fetch (`mergeRateLimitSnapshot(replacesMissingWindows:
true)`) clears a window it no longer reports; the JSONL fallback clears a window
it owns when the latest parse lacks it. Fragment sources (tmux `/status`) stay
additive. Without this, a 5h window that appears and then drops within one app
run would freeze as a ghost "5h X%" instead of "no limit".

## Presentation

Publish `hasFiveHourRateLimit`, `hasWeekRateLimit`, and `usageFormatSuspect` on
`CodexUsageModel`. A window slot has three presentation states:

1. **Present** — normal percent + reset.
2. **Recognized absence** (no short window classified, but the weekly window is
   present and clean) — show an explicit, calm **"5h: no limit"** state (not a
   hidden line). This makes the missing 5h line legibly *intentional* (OpenAI
   paused it), never mistakable for an AgentSessions bug or a load failure. No
   warning glyph.
3. **Suspect** (`usageFormatSuspect`, uninterpretable data) — neutral `—` + small
   warning glyph + tooltip ("Codex changed its usage format — can't verify"), no
   numeric value.

Also:
- Wk meter renders the real weekly numbers.
- Zero placeable windows → the provider's strip shows the suspect/unavailable
  state rather than default `0%`.

The "no limit" (state 2) and "can't verify" (state 3) copies are deliberately
distinct: absence is calm and explanatory, suspect is a soft alarm.

Surfaces and treatment:
- **Prominent** — `UsageStripView` (the menu-bar footer strip) and the
  `StatusItemController` dropdown: full 3-state with the explicit "no limit" /
  "can't verify format" copy.
- **Compact cockpit meters** — `CockpitFooterView` and the `AgentCockpitHUDView`
  limits/rows/hover panels: an absent or suspect window renders the existing
  compact "--" idiom (fixed-width cells can't fit "no limit"), and — critically —
  is **excluded from the bottleneck/critical math**. Without this an absent 5h
  window (0% remaining → 100% used) would become the bottleneck and paint a false
  red "critical" state. `QuotaData` and `HUDLimitsProviderEntry` carry the
  `hasFiveHourRateLimit`/`hasWeekRateLimit` flags (default true, so Claude is
  unchanged); `bottleneckIs5h` and the `*Unavailable` gates honor them.

## Runway re-point

When 5h is absent, build the Codex `RunwayProviderBaseline` from the weekly
window: `remainingPercent` = weekly remaining, `resetAt` = weekly reset,
`currentRunoutAt` = weekly projection ?? weekly reset.

Keep the m/h yardstick by generalizing the quota conversion:

```
// before: percentPerSecond * 3 * 3600      (3 = 300 min / 100%)
// after:  percentPerSecond * (windowMinutes / 100) * 3600
```

Add `windowMinutes: Int` to `RunwayProviderBaseline` (default `300`, so Claude —
which still has its 5h window — is untouched). Because m/h is an *absolute*
quota-minutes quantity, the same physical burn yields the same m/h number whether
it draws down a 5h or a 7‑day bucket — i.e. the "5h yardstick" the user asked for.
"Gained by pausing" and the `▸` runout naturally use the weekly horizon.

The 5h projection tracker (`UsageLimitProjectionTracker`) is fed from the active
window; when 5h is absent it consumes the weekly remaining/reset and projects the
weekly run-out.

`formatUsageProjectionLabel` renders days (`▸3d 4h`) once a run-out is > 24h,
rather than `▸76h`.

Known limitation (weekly projection precision): the projection tracker measures
burn from the *integer* remaining-percent. On the weekly window 1% ≈ 100 minutes,
so consecutive polls rarely cross an integer boundary and the fresh projection
usually doesn't fire — the baseline then falls back to the weekly reset horizon,
which caps a fast session's displayed m/h toward the even-pace-to-reset rate
(conservative, not wrong-direction). The per-session rows still render (the direct
per-session rate-limit burn parser is independent). A full fix is to thread an
exact-Double remaining-percent through the snapshot to the tracker; deferred as a
fast-follow.

## Testing

Extends `CodexUsageParserTests`:
- Live broken shape `primary=weekly(10080)/secondary=null` → weekly populated, 5h
  absent (`hasFiveHourRateLimit == false`), `usageFormatSuspect == false`.
- 5h restored `primary=300/secondary=10080` → both slots populated (auto-recovery).
- Garbage shape (no length + no reset, or %-out-of-range, or duplicate class) →
  `usageFormatSuspect == true`, no numbers surfaced.
- Runway: weekly baseline yields the same m/h for a given burn as the old 5h path
  did (window-invariance of the quota-minutes conversion).

## Scope / blast radius

Touched: the 4 parse sites, the new classifier, `CodexUsageSnapshot` +
`CodexUsageModel` (new flags), `UsageStripView`, `StatusItemController`, cockpit
footer/HUD, `CodexRunwayModel` (`quotaMinutesPerHour`, `RunwayProviderBaseline`),
`AgentCockpitHUDView` (Codex baseline builder), `UsageDisplayFormatter`
(projection label days). This is the honest cost of "classify by length
everywhere," not scope creep.

## Out of scope

- Relabeling the "5h"/"Wk" chips to a window's exact duration (the reset time
  already carries the truth).
- Persisting last-known-good window layout across launches.
- Supporting a hypothetical third (e.g. daily) window — today's model has two
  slots; a third window is a separate design.
- Claude-side changes — Claude still exposes its 5h window; the default keeps it
  on the existing path.
