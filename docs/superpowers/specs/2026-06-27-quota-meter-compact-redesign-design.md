# Quota Meter compact redesign — design

- Date: 2026-06-27
- Status: approved (approach "compact fix"), pending user review then implementation
- Scope: the compact, always-on Quota Meter (the `AgentCockpit` window in compact mode)

## Problem

The compact Quota Meter (tucked in a screen corner, always on) has three issues:

1. **Standard font window too wide.** A regression from making the limit-column
   widths constant/Enlarged-sized (commit `08e9c1a5`). Per-mode compact sizing was lost,
   so the Standard layout is loose with empty space between columns.
2. **Right-edge dead space.** The window can be tucked wider than its content, leaving
   an empty band on the right.
3. **Empty burn slot.** When an agent has no fresh 5h run-out projection (idle/stale),
   the reserved projection column renders blank — a hole. Collapsing it instead would
   resize the window whenever burn starts/stops (bad for a tucked, fixed widget).

## Goal

A compact, neat, always-on widget whose width is fixed within a font mode. A slightly
wider window for the Enlarged font is acceptable (the setting is rarely toggled).

## Approach — "compact fix"

Three changes, all scoped to the compact limits row and its window.

### 1. Restore per-mode compact column widths

Re-apply `columnScale` (Standard ×1.0, Enlarged ×13/12) to the compact limit columns,
with base widths sized so normal content fits at the Standard font without
shrinking/trimming:

| column | base width | fits worst-case normal content |
| --- | --- | --- |
| 5h % | 53 | `5h: 94%` (transient `100%` shaves via minimumScaleFactor — accepted) |
| 5h run-out slot | 60 | `▸4h 59m` (worst hour-format) |
| 5h reset | 60 | `↻ 4h 59m` |
| separator | 5 | `|` |
| Wk % | 53 | `Wk: 89%` (transient `100%` shaves — accepted) |
| Wk reset | 104 | `↻ Wed 12:00 PM` (2-digit hour) |

Footprint ≈ 400px Standard, ≈ 432px Enlarged.

### 2. Fill the run-out slot with a neutral marker

The 5h run-out column is always rendered on both provider rows, keeping the row width
fixed regardless of burn state:

- Fresh projection → `▸Xh Ym` (amber, exactly as today).
- No fresh projection (idle/stale) → a single muted `·`, centered in the slot.

Implementation note: show `·` exactly when the existing `fiveHourProjectionLabel` is
`nil` — no new threshold or classification logic; only the empty/placeholder case is
replaced by the neutral marker.

No steady/idle distinction, no new thresholds, no legend. The 3-state `▸ / ✓ / ‖`
model was explicitly rejected as over-engineered (ambiguous glyphs, redundant with the
runway rows below).

### 3. Hug-content window (compact mode only)

The compact `AgentCockpit` window sizes to its content width (the limits row),
eliminating trailing dead space and keeping the footprint stable. The hover-revealed
compact toolbar stays an overlay and does not affect resting width
(`showsCompactToolbar = !isCompact || isCompactWindowHovered`, AgentCockpitHUDView.swift:737).
The non-compact cockpit view is unaffected. Toggling Enlarged resizes the window once
(~400 ↔ 432px) — acceptable.

## Weekly side

Unchanged: `Wk: NN% ↻ reset`.

## Out of scope / rejected

- Three-state semantic burn indicator (`▸ / ✓ / ‖`) — over-engineered; `✓` reads as
  "done", `‖` needs a legend; the active/idle distinction is already visible in the
  runway rows.
- Justify-to-fill layout while keeping the window resizable — unnecessary once the
  window hugs content.
- Detail panel changes — a separate surface, not the reported issue.

## Files

- `AgentSessions/Views/AgentCockpitHUDView.swift`
  - `HUDLimitsColumnLayout` — compact base widths above.
  - `QuotaMeterTextMetrics` — reinstate `columnScale(enlarged:)`.
  - `alignedContent` — re-apply `* scale`; always render the run-out slot.
  - `HUDLimitsProjectionToken` — render a centered muted `·` when projection is nil.
- `AgentSessions/AgentSessionsApp.swift` — content-hug sizing for the compact
  `AgentCockpit` window (exact mechanism decided in the plan: `windowResizability(.contentSize)`
  vs. NSWindow content sizing, gated to compact mode).

## Risks / to verify during planning

- Content-sizing must apply only to compact mode and must not break the full cockpit
  view, the runway panel, or the hover toolbar.
- Confirm the limits row is the widest resting element (runway rows have a flexible bar
  and a truncating title, so they should be ≤ the limits row width).

## Verification

- Toggle Standard ↔ Enlarged: Standard is compact (~400px), Enlarged slightly wider;
  hour-format projections and 2-digit-hour resets never trim.
- An idle agent shows `·`, not a blank hole; the width does not change when burn
  starts or stops.
- No right-edge dead space; the window stays put and stable when tucked in a corner.
