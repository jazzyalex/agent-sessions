# Quota Meter notch presentation — design

Date: 2026-10-12 (revised 2026-10-13 after architecture review)
Status: draft, awaiting owner review

## Problem

The floating Quota Meter window works well on a large external monitor. On a
14" MacBook Pro it covers window content. The notch row is unused space on
that display.

## Goal

Show the Quota Meter data in the menu bar row beside the notch on the built-in
display. Cover no window content while collapsed. Keep the floating window
unchanged for external monitors.

Out of scope for v1:

- Transient pop-ups when a session starts or stops burning.
- A wing that changes width by state.
- Automatic detection of menu bar collisions (see "Crowded menu bar").
- Any change to the menu bar status item (`UsageMenuBarLabel`).
- Any change to the floating window's layout or behaviour.
- Any feature that needs Accessibility or Screen Recording permission.

## Placement setting

One new preference, `QuotaMeterPlacement`, in Settings → Quota Meter:

| Value | Behaviour |
|---|---|
| `automatic` | Notch when the Quota Meter's target screen has a notch; floating window otherwise. |
| `notch` | Notch on an available notched screen; floating window when none is connected. |
| `floating` | Floating window always. Today's behaviour. |

**Target screen.** The target screen is the screen that holds the floating
window's frame: its current screen while it is open, or the screen containing
its autosaved frame while it is not. "A notched screen exists somewhere" is not
the test. With an external monitor attached and the floating window on that
monitor, `automatic` stays floating. With the built-in display alone, the
target screen is the built-in display and `automatic` resolves to the notch.

A screen has a notch when `NSScreen.safeAreaInsets.top > 0` and
`auxiliaryTopLeftArea` / `auxiliaryTopRightArea` are non-nil.

Only one presentation is visible at a time. The notch presentation follows the
Quota Meter's desired visibility: if the user hid the Quota Meter, no wings
show.

### Default: opt-in (owner decision, 2026-10-13)

The default is `floating` for existing and fresh installs. The notch is
opt-in. Nobody's Quota Meter moves after an update.

### Discoverability: toolbar switch

Opt-in needs a visible way in. Each presentation's toolbar carries one switch
to the other:

- **Floating window toolbar:** a "Move to notch" button. It shows only while a
  notched screen is connected. It sets `QuotaMeterPlacement` to `notch`.
- **Notch panel toolbar:** a "Move to floating window" button. It sets
  `QuotaMeterPlacement` to `floating`. The window reopens at its autosaved
  frame.

Both go through `QuotaMeterPresentationCoordinator`, so the switch is one
continuous visible cockpit. `automatic` is offered in Settings only.

The floating toolbar is hidden by default (`QuotaMeterChrome` is on-demand),
so the button alone is not enough. The existing "Right-click for controls"
hint stays the route to it. The plan must also add the placement picker to
Settings → Quota Meter and a line in the release notes.

## Collapsed state: wings

Two black wings extend the notch sideways inside the menu bar row. Each wing
has one fixed width (about 95 pt) in every state. It never widens.

- **Codex is always the left wing. Claude is always the right wing.**
- Each wing shows: provider icon, one percent, and a run-out chip.
- The percent is the tighter of the 5h and weekly numbers for that provider. It
  honours the existing `UsageDisplayMode` (left / used).
- The run-out chip (`▸2h`) shows only while that provider has a burning
  session and a projection exists. It reuses the `HUDLimitsProjectionToken`
  logic.
- Under the text, one small tick per burning session, up to four. A session
  counts as burning when its runway row has confidence `.direct` or `.mixed`.
  Waiting, idle and cloud rows get no tick.

### States

| State | Wing content |
|---|---|
| Nothing burning | Icon and percent, dimmed. No chip, no ticks. |
| Burning | Icon, percent, run-out chip, ticks. |
| Will run out before reset | Same layout. Percent turns red, chip turns amber. No size change. The reset countdown shows on hover only. |
| Sign-in needed, rate-limited, reconnecting, idle, probing | The number is replaced by an icon plus one short word. Never show a stale or invented number. |
| 5h window absent | `∞` in place of the percent, as the floating window does. |

Short bad-state strings, all localised: "Sign in", "Limited", "Retrying",
"Idle", "Probing". VoiceOver gets the full wording.

### One provider hidden

When `QuotaMeterHiddenProviders` leaves one provider, it takes both wings: 5h
on the left, weekly on the right. Ticks and chip sit on the left wing.

### Crowded menu bar

macOS has no supported, permission-free API for where other apps' menus and
status items sit. v1 does not detect collisions.

v1 ships a manual setting, `QuotaMeterNotchStyle`:

- **Wings** (default): as described above.
- **Minimal**: each wing becomes a 3 pt hairline under the notch. The bar's
  fill is the same percent and its colour follows the same state rules. Hover
  still opens the panel.

In Minimal the wing windows shrink to the hairline, so the menu bar pixels
beside the notch belong to the app underneath. `floating` remains the escape
hatch. Automatic collision avoidance is follow-up research.

### Full-screen apps

In a full-screen Space the top strip is black and empty. Wings stay visible
there.

## Expanded state: hover panel

Hovering either wing, or the notch, opens one black panel that drops from the
notch. It uses the existing dwell timings (350 ms to open, 700 ms to close
after the pointer leaves).

- Two columns. Codex under the left wing, Claude under the right wing.
- Each column, top to bottom:
  1. The full limits line: 5h percent, run-out chip, 5h reset, weekly percent,
     weekly reset.
  2. The extra lines the floating window shows with chrome revealed (Codex
     reset credits, Claude scoped-week line), under the same rules.
  3. The runway rows for that provider.
- Runway rows are the same as today: session name, rate, load bar. Same budget
  and ranking: up to four detail rows, then `+N sessions`; cloud rows take
  leftover slots only. `QuotaMeterRunwayVisibility` and
  `QuotaMeterRunwayPresentation` apply unchanged.
- Clicking a session row focuses that session, as today.
- Right-click on the panel reveals the toolbar (Probe, provider visibility,
  runway popovers, Settings, Open Agent Sessions). The Pin button is hidden in
  the notch presentation. The stored Pin preference is not changed (see
  "Invariants").
- With one provider visible, the panel is one column.
- Every toolbar action must also be reachable from the app's menus or
  Settings, because a non-activating panel is not keyboard-reachable.

The panel always renders dark, because it extends black hardware. It ignores
the system appearance and `CockpitHUDReduceTransparency`.

## Architecture

### Step 0: hardware spike (throwaway)

The window and input mechanism is the riskiest part and is unproven. Before
any production code, build a throwaway prototype on a real notched Mac: plain
black left and right panels, nothing else. Verify:

- `.statusBar` level and `.nonactivatingPanel` draw correctly over the menu
  bar row and do not block app menus or status items outside the panels.
- Notch coordinates from `NSScreen`, at default and scaled resolutions.
- Mouse enter and exit across wing → notch → panel, clicks and right-clicks.
- Menus still open normally. System pop-up menus outrank the panels.
- Full-screen Spaces, Stage Manager, Mission Control.
- Display attach and detach, lid close and reopen, sleep and wake.

The code is discarded. The findings fix the panel topology below. If the spike
contradicts this section, the spec is revised before the plan is written.

### Panel topology

Several small panels, not one large panel with click pass-through.
`ignoresMouseEvents` applies to a whole window, so one window cannot pass
clicks through some regions only.

- Left wing panel: covers only the left wing.
- Right wing panel: covers only the right wing.
- Notch hover sensor: an invisible panel over the logical notch rect, if the
  spike shows it is needed.
- Expanded panel: exists only while open.

Each is a borderless `NSPanel` with `.nonactivatingPanel`, `level =
.statusBar`, `hidesOnDeactivate = false`, non-opaque, no shadow on the wings.
Collection behaviour: `.canJoinAllSpaces`, `.stationary`,
`.fullScreenAuxiliary`, `.ignoresCycle`. No higher level than `.statusBar`.
The expanded panel may need `canBecomeKey == true`, `canBecomeMain == false`
so its controls work without activating the app.

Notch panels carry their own window identifiers.
`AppWindowRouter.existingWindow(identifier: "AgentCockpit")` must never find
one.

### New units

- **`NotchGeometry`** (pure value type). Input: screen frame, safe-area insets,
  auxiliary left and right rects. Output: notch rect, wing rects, hairline
  rects, panel rect. No AppKit calls inside. All geometry is recomputed from
  `NSScreen` on every change; no notch coordinates are persisted.
- **`QuotaMeterPlacementResolver`** (pure function). Input: placement
  preference, desired visibility, target screen, available screens. Output:
  `hidden`, `floating` or `notch(displayID)`.
- **`QuotaMeterPresentationCoordinator`** (`@MainActor`). The single owner of
  Quota Meter presentation:
  - owns desired visibility, independent of which presentation shows it;
  - calls the resolver and owns the notch controller;
  - opens the SwiftUI `Window` scene only for the floating presentation;
  - exposes one `isPresented` for the View menu checkmark;
  - is the only caller of the usage models' cockpit visible/pinned lifecycle;
  - observes `NSApplication.didChangeScreenParametersNotification` and
    re-resolves. Display-driven switches must not activate the app.
    `showAgentCockpitWindow()` activates today, so the coordinator needs a
    non-activating path for these switches.

  `AppWindowRouter`, the View-menu toggle and
  `maybeRestorePinnedCockpitOnLaunch` route through the coordinator.
  `CockpitWindowVisibility` stops being the source of truth for visibility.
- **`QuotaMeterNotchPanelController`**. Owns the notch panels and their frames.
  Orders the panels out before the coordinator restores the floating window.
- **`NotchWingView`** and **`NotchExpandedPanelView`** (SwiftUI). Notch-only
  state lives here: expanded or collapsed, pointer containment, notch style.

### Shared data: two extractions, not one model

`HUDLimitsProviderEntry` is private to `AgentCockpitHUDView.swift` (line 2782)
and built inside `HUDLimitsRowsPanel` (lines 3874–3915). The runway snapshots
are `@State` in that panel (lines 3809–3810) and its loaders are called from
the view (lines 4265, 4274).

1. **`QuotaMeterProviderPresentation`** plus a builder. A pure value type and a
   pure mapping from the existing model values and preferences. No polling, no
   copied source state.
2. **`QuotaMeterRunwayStore`** (`@MainActor`, observable). The one owner of
   the Codex and Claude runway snapshots, their loader tasks, cancellation and
   request identity. Both presentations read it, so the loaders run once.

`CodexUsageModel`, `ClaudeUsageModel` and `CodexActiveSessionsModel` stay the
source of truth. Do not add a shadow model that subscribes to their
`@Published` properties and republishes copies. The extraction must not
republish unchanged values; the existing publication throttling must survive.

Floating-only state stays in the floating view: pinning, hover and chrome
reveal, resize anchor, toolbar presentation, window geometry.

`AgentCockpitHUDView.swift` is 5,905 lines. New notch views go in new files.
Move `HUDRunwayPanel` and `HUDRunwayLoadBar` to their own file so both
presentations can use them; do not restructure the rest.

### Invariants

- Notch panels never use the floating window's autosave name
  (`AgentCockpitHUDWindow.limits`) and never write the floating frame.
- Switching to the notch preserves the autosaved floating frame. A
  display-driven fallback reopens the floating window at that frame.
- Switching presentations never changes `CockpitHUDPinned`. The notch being
  topmost does not set the Pin preference.
- Launch restore resolves placement first, then restores the resolved
  presentation. It does not open the floating scene directly.
- Floating → notch is one continuous visible cockpit for the usage models. It
  is never reported as hidden then visible.

## Energy

The collapsed notch UI adds no timers, animations or polling beyond the
source-model polling that an always-visible Quota Meter already needs.

- No `TimelineView`, animation loop, display link or timer in the collapsed
  state. Tick and percent updates come from model publishes only.
- `RunwayShimmerTicker` stays presentation-local. It runs only while the
  expanded panel is visible and a row burns. Reduce Motion disables it.
- One runway refresh loop, owned by `QuotaMeterRunwayStore`.
- Display changes are handled from notifications only.

Known cost: the usage models treat a pinned cockpit as always visible and keep
polling while the app is inactive. A notch presentation is always visible, so
a user whose floating window is unpinned today will get more background
polling in the notch. Accepted by the owner on 2026-10-13: the notch is
opt-in, so the user chooses it. The plan must state how the coordinator
reports the notch to the models and measure the difference.

## Accessibility

- **VoiceOver:** one element per wing with provider, quota, burn and run-out
  state, and the full bad-state wording. Session rows stay actionable.
- **Reduce Motion:** no open and close animation, no shimmer.
- **Increase Contrast:** state must not depend on dimming or on red and amber
  alone; provide a high-contrast text and border path.
- **Localisation:** all wing strings come from localised resources.

## Risks and open questions

1. **Window and input mechanism.** Covered by the step 0 spike. Nothing else
   starts until it passes.
2. **Background polling increase** for users who are unpinned today. Accepted;
   measure it. See Energy.
3. **Discoverability of an opt-in feature.** The toolbar switch sits behind a
   right-click. Watch whether users find it.
4. **Notch size varies** by model and by display scaling. All geometry comes
   from `NSScreen` at run time; no hard-coded widths except the wing width.
5. **Third-party notch apps** (Vibe Island, NotchNook, boring.notch) draw in
   the same place. No coordination is possible. Document it; `floating` is the
   escape hatch.
6. **Review coverage.** The architecture review did not read the runway
   loaders, `CodexActiveSessionsModel`, the menu bar files,
   `PreferencesConstants.swift`, entitlements or tests. The plan must check
   preference migration and sandbox entitlements against the source.

## Testing

- `NotchGeometry`: unit tests with fixed inputs for 14" and 16" at default and
  scaled resolutions, and for a screen with no notch.
- `QuotaMeterPlacementResolver`: table test over preference × visibility ×
  target screen × available screens.
- `QuotaMeterPresentationCoordinator`: lifecycle tests for presentation
  switching, screen selection, desired visibility, pinned launch restore,
  non-activating display migration and preserved autosave frame. One test
  asserts the models see one continuous visible cockpit across a switch.
- Wing state mapping (model state → percent, colour, chip, tick count, bad
  state): unit tests on the builder, including the one-provider case.
- Energy: a debug counter or test asserting one runway loader owner and no
  notch timer while collapsed.
- Both extractions: the existing Quota Meter tests must pass unchanged, with
  the same test count.
- Visual: render `NotchWingView` and `NotchExpandedPanelView` to PNG with
  `ImageRenderer` for each state. This is supplementary; it cannot test window
  level, Spaces or clicks.
- Hardware matrix, run once in the spike and once at feature-complete:
  built-in display only, external extended desktop, external with lid closed,
  lid reopen, full-screen Space, Stage Manager, scaled resolution, an app with
  long menus, a crowded status area, sleep and wake.

## Implementation order

Steps 1–4 ship with no visible change. Each step is independently shippable.

0. Hardware spike (throwaway).
1. Placement and screen types: `QuotaMeterPlacement`, screen descriptors,
   `NotchGeometry`, resolver, table tests.
2. `QuotaMeterProviderPresentation` and builder. Floating window unchanged.
3. `QuotaMeterRunwayStore`. Floating window wired to it first.
4. `QuotaMeterPresentationCoordinator`, resolving everything to floating.
   View menu and pinned restore routed through it.
5. Notch panel controller and collapsed wings, behind the `notch` preference.
6. Expanded panel with session actions and right-click toolbar.
7. Toolbar switch in both presentations and the Settings placement picker.
8. Accessibility, localisation and energy pass.
9. Wings / Minimal notch style.
10. Hardware regression QA.

## Prior art

Vibe Island (paid) advertises usage limits in the notch. Its own comparison
lists Claude Island, Notchi and Open Island as not showing them; that is a
vendor claim, not verified here. CodexBar shows limits in the menu bar only.

## Review record

Architecture review 2026-10-12 via Repo MCP, ChatGPT web, 5.6 Extra High (not
the Sol Pro profile; not recorded in the `chatgpt-run` journal). Verdict:
proceed with changes. The review was partial: the tunnel dropped before all
requested files were read. All nine findings are applied in this revision.
