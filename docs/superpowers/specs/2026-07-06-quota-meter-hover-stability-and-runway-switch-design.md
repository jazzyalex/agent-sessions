# Quota Meter Hover Stability + Claude Runway Click-to-Switch — Design

**Date:** 2026-07-06
**Status:** Approved (brainstormed with owner)
**Scope:** Quota Meter (QM) window behavior + Claude runway row interaction. No model/pipeline changes expected.

## Part 1 — QM hover stability (content-anchored resize)

### Problem

When the QM window reveals hover content (toolbar, Codex credits line) or the runway
drawer changes rows, the window resizes via `applyLimitsDefaultSize` /
`shouldGrowLimitsWindowDown` (AgentCockpitHUDWindow.swift), which picks a growth
direction from *available room*, preferring down. Result: the window shifts up or
down under the cursor, rows move while the user is aiming, and clicks miss.

### Behavior (Option A — content-anchored resize, + F1 fallback)

Stop pinning an edge. Pin the **resting meter rows** and grow the window on both
sides by exactly the height of content revealed on each side:

- **Toolbar reveal (always laid out on top):** the window's **top edge moves up**
  by the toolbar height. Rows stay screen-fixed; the toolbar fades into the new
  space above them.
- **Content below/between rows** (credits line, runway drawer rows, always-on
  drawer changes): the window's **bottom edge moves down** by that amount. Rows
  above the insertion stay screen-fixed.
- Collapse mirrors expansion (top edge returns down, bottom edge returns up).

Visual order never changes: toolbar stays on top in every placement.

**Clamp fallback (F1):** when the window is flush against the top of the visible
screen area and there is no room above for the toolbar, keep the toolbar on top
and grow **down** instead — rows nudge down by the toolbar height once, at
hover-entry, then everything is stable until hover exit. Mirrored clamp at the
bottom screen edge for bottom-growth (rare: bottom growth flips up).

Room checks use the window's screen `visibleFrame` (same source as the current
`shouldGrowLimitsWindowDown`).

### What this replaces

- `shouldGrowLimitsWindowDown` room-preference heuristic → replaced by the
  anchored two-sided growth computation.
- `HUDWindowExpansionDirectionReader` / `HUDExpansionDirection` usages that pick
  a single direction for QM growth are superseded for the QM window path (the
  main-window limits-strip overlay panel keeps its own up/down overlay logic —
  out of scope).

### Implementation sketch

- The QM content view reports **two heights** instead of one: height of
  top-side chrome currently revealed (toolbar) and height of the anchored
  content (rows + interleaved reveals). A preference key change alongside
  `LimitsContentHeightKey` in AgentCockpitHUDView.swift.
- `applyLimitsDefaultSize` computes the new frame as:
  `maxY += deltaTop` (clamped to `visibleFrame.maxY`, overflow redirected to
  bottom growth), `minY -= deltaBottom` (clamped to `visibleFrame.minY`,
  overflow redirected to top growth).
- Resize stays instant (no animation) except the existing animated toolbar
  toggle path.

### Non-goals

- No change to what content is revealed on hover, or when the runway drawer
  shows (Auto/On/Off semantics unchanged).
- No change to the main-window bottom limits strip or its expanded overlay.

## Part 2 — Meter button becomes an inline segmented selector

### Problem

The cockpit view switcher (`cockpitModePicker`, AgentCockpitHUDView.swift:1357)
is a popover. Window resize/movement on hover displaces or dismisses the
popover, so in QM mode the user often cannot pick Full/Compact.

### Behavior

Replace the popover button with an **inline segmented control** in the toolbar —
`Full | Compact | Meter` — styled like the runway drawer's Auto/On/Off segmented
picker (`HUDRunwayVisibilityPopover` style: `.segmented`, `.controlSize(.small)`).
One click switches mode; no popover. `HUDCockpitModePopover` is removed once no
callers remain. Selection persists to the same `hudDisplayModeRaw` AppStorage and
goes through `setHUDDisplayMode` with the existing animation.

Trade-off (accepted): the selector is wider than the current "Meter ⌄" button.

## Part 3 — Claude runway click-to-switch

### Problem

Claude runway rows (QM drawer + HUD) show burning sessions but are inert. The
owner wants a `/pet`-style quick switch: click a row → jump to that session.

### Behavior

Rows become clickable, target resolved automatically by session origin:

- **CLI session with a live terminal** (maps to a HUD row with
  `itermSessionId`/`tty`): click → focus the existing iTerm2 tab via
  `CodexActiveSessionsModel.tryFocusITerm2` — identical to cockpit's
  "Focus in iTerm2" (AgentCockpitHUDView.swift:1967). Not a new `--resume`.
- **Desktop session** (row's CLI session id has a sidecar record from
  `ClaudeDesktopSessionTitles.records()`): click →
  `NSWorkspace.shared.open("claude://resume?session=<uuid>")`. Verified: Claude
  Desktop registers the `claude` scheme and ships a `claude://resume?session=`
  handler that imports/opens the exact CLI session, with its own error toasts
  (auth expired / transcript missing / network).
- **Neither** (stale recent-scan row, aggregated "+N sessions" summary row): not
  clickable, no hover affordance — never a dead click.

Hover affordance on clickable rows: background tint + pointing-hand cursor + a
small trailing destination glyph (terminal vs. Claude Desktop) + tooltip
("Switch to iTerm2 tab" / "Open in Claude Desktop").

Precedence when both targets exist: live iTerm2 tab wins (the session is
actively running there); Desktop is the fallback.

Scope: Claude runway rows only. Codex runway rows keep current behavior.

### Implementation approach (A — view-layer lookup)

Runway row `id` derives from the root session ID
(`HUDRunwayIdentityReducer.rootSessionID`). At render time resolve each row's
target by looking up (1) live HUD rows for `itermSessionId`/`tty`, (2) cached
sidecar records for a Desktop match. No changes to
`RunwayPauseImpactRow`/`RunwaySessionIdentity` or the snapshot loaders.

**Verification gate before building on this:** confirm `RunwaySessionIdentity.id`
is the raw session UUID (not a synthetic key) for both live-HUD-derived and
recent-scan-derived rows. If the mapping is lossy, fall back to approach B:
thread a `SwitchTarget` enum (`.iterm(sessionId:tty:)`, `.desktop(sessionId:)`,
`.none`) through identity → row in the snapshot pipeline.

### Error handling

- iTerm focus failure (`tryFocusITerm2` returns false): fall through to the
  Desktop deep link if a sidecar exists; otherwise no-op (row should not have
  been clickable — defensive).
- Deep link failure surfaces inside Claude Desktop (its own toasts); Agent
  Sessions does not add error UI.

## Testing

- Unit: frame-computation math for anchored growth (deltaTop/deltaBottom +
  clamps) extracted into a pure helper, table-driven tests incl. top-edge and
  bottom-edge clamps.
- Unit: runway row target resolution (iTerm vs Desktop vs none; precedence;
  summary row excluded).
- Owner QA (per repo workflow, batched at feature-complete): hover QM parked at
  top edge / bottom edge / mid-screen; switch modes via segmented selector in QM
  mode; click a CLI-burning row (iTerm tab focuses); click a Desktop session row
  (Desktop opens exact session).
