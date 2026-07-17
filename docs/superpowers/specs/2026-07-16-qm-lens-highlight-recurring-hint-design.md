# Quota Meter: Recurring Reveal Hint + Active-Lens Underline — Design Spec

> Status: proposed (2026-07-16). Two small, independent UX fixes to the collapsed
> Quota Meter (On Demand chrome). No new controls, no window-resize behavior change.

## Problem

1. **The toolbar is un-re-findable.** Default chrome mode is `.onDemand`: right-click
   reveals the toolbar and a "Right-click for controls" pill fades in on hover. But
   the pill **retires after first use** (`quotaMeterChromeRevealedOnce`), so once you
   learn the gesture there is nothing on screen ever again reminding you how to get
   controls back. Users forget.

2. **You can't tell which runway lens is active.** The Session Runway drawer renders
   per-session burn in one chosen lens (`RunwayPresentation`: 5h / Wk / token / $),
   set by a toolbar toggle that is hidden by default. Rows carry a tiny unit suffix
   (`m/h`, `%/h`, …) that collapses to `flat`/`idle`/`0m/h` when nothing is burning —
   at which point 5h and Wk are indistinguishable. The lens *name* only exists in the
   hidden toolbar pill.

## Decisions (owner)

- **Reveal:** keep right-click; do **not** add a button. Just make the hint recurring —
  it reappears on every hover instead of retiring.
- **Lens:** do **not** add a separate lens label. Instead, in the agent/header row that
  already shows `5h: 71% | Wk: 88%`, **underline** the window (`5h` or `Wk`) that matches
  the active runway toggle. Token/$ lenses underline neither.
- **Highlight style:** thin accent-colored underline under the active label (selected-tab
  cue). Leaves the percentage's status color untouched.

## Design

### 1. Recurring right-click hint

`QuotaMeterChrome` (`UsageDisplayMode.swift`):

- `showsRightClickHint(pointerDwelled:demandRevealed:retired:)` → drop the `retired`
  parameter; return `pointerDwelled && !demandRevealed` for `.onDemand`.
- `armsDwellTimer(hintRetired:)` → drop the `hintRetired` parameter; `.onDemand` returns
  `true` (so the dwell timer keeps arming and `pointerDwelled` can recur on each hover).

`AgentCockpitHUDView.swift`:

- `showsRightClickHint` / `dwellTimerArmed` call sites: stop passing the retired flag.
- `revealChromeOnDemand()`: drop the `quotaMeterChromeRevealedOnce` set.
- Remove the now-dead `@AppStorage(PreferencesKey.quotaMeterChromeRevealedOnce)` and the
  `PreferencesKey.quotaMeterChromeRevealedOnce` definition (verify no other readers).

Invariant preserved: under `.onDemand`, `showsChrome` reads only `demandRevealed`, so
re-arming the dwell timer re-shows **only the hint**, never the toolbar — the window still
never resizes from passive hover, keeping the drag-target promise intact.

### 2. Active-lens underline in the agent row

`HUDLimitsProviderText` (`AgentCockpitHUDView.swift`):

- Add `@AppStorage(PreferencesKey.quotaMeterRunwayPresentation)` and compute the effective
  active window:

  ```swift
  private enum ActiveLensWindow { case fiveHour, week }
  private var activeLensWindow: ActiveLensWindow? {
      switch RunwayPresentation.current(raw: runwayPresentationRaw) {
      case .fiveHour: return fiveAbsent ? nil : .fiveHour   // absent 5h → runway falls back to tokens
      case .weekly:   return weekAbsent ? nil : .week
      case .token, .dollar: return nil
      }
  }
  ```

  Gating on `fiveAbsent`/`weekAbsent` means a picked-but-unmeasurable window (e.g. `5h: no
  limit`, where the runway silently shows tokens) underlines nothing — the underline only
  ever marks the lens the drawer is *actually* using.

- Underline helper applied to the `5h`/`Wk` label token:

  ```swift
  @ViewBuilder private func lensLabel(_ text: String, active: Bool) -> some View {
      Text(text).overlay(alignment: .bottom) {
          if active {
              Rectangle().fill(Color.accentColor)
                  .frame(height: 1.5).offset(y: 1)
          }
      }
  }
  ```

- Replace the plain `Text("5h: ")` / `Text("Wk: ")` at each render site with
  `lensLabel("5h: ", active: activeLensWindow == .fiveHour)` /
  `lensLabel("Wk: ", active: activeLensWindow == .week)`. Sites: `alignedContent`
  (aligned columns), the non-aligned `HStack`, and — since only one of 5h/Wk shows in
  bottleneck-only mode — the bottleneck branches too. The `fiveAbsent` span ("5h: no
  limit") needs no underline (activeLensWindow is nil there by construction).

## Non-goals

- No change to the default chrome mode (stays `.onDemand`).
- No new toolbar button or menu item.
- No change to runway row rendering or the lens toggle itself.
- No color-coding beyond the single accent underline (token/$ deliberately unmarked).

## Testing

- Chrome enum: unit-assert `showsRightClickHint` is true on a fresh dwell with the toolbar
  closed regardless of any prior reveal, and `armsDwellTimer(.onDemand)` is `true`.
- Manual: On Demand QM — hover repeatedly, confirm the hint returns every time; right-click
  still opens the toolbar; window never resizes on plain hover.
- Manual: flip the runway toggle 5h → Wk → token → $ and confirm the underline moves to 5h,
  then Wk, then disappears for token/$. With a dropped 5h window, confirm 5h is not
  underlined while the lens is 5h.
