# Quota Meter notch presentation — design

Date: 2026-10-12. Revised 2026-10-13 (architecture review), 2026-10-17
(XHigh spec review, verdict NO-SHIP; all 13 findings applied) and 2026-10-17
(owner design change: strip on every screen, old menu bar item replaced; see
"Owner decisions 2026-10-17").
Status: draft, awaiting owner review

## Problem

The floating Quota Meter window works well on a large external monitor. On a
14" MacBook Pro it covers window content. The notch row is unused space on
that display.

## Goal

Offer two Quota Meter designs and let the user choose:

- **Menu bar strip** ("strip", called the notch presentation in the
  architecture sections): the Quota Meter data in the menu bar row. On a
  notched screen it sits beside the notch; on a screen without a notch it sits
  at the top centre (see "Strip screen and geometry"). Covers no window content
  while collapsed.
- **Floating window**: unchanged.

The default follows the screen: floating on large external monitors, the strip
on a MacBook. The strip replaces the old menu bar status item (see "Old menu
bar item").

Out of scope for v1:

- Transient pop-ups when a session starts or stops burning.
- A wing that changes width by state.
- Automatic detection of menu bar collisions (see "Crowded menu bar").
- Any change to the floating window's layout or behaviour, except two
  additions: the "Move to menu bar" toolbar button and the one-time hint (see
  "Discoverability").
- Any feature that needs Accessibility or Screen Recording permission.

## Owner decisions 2026-10-17

These replace the 2026-10-13 opt-in default where they conflict.

1. The strip also shows on screens without a notch, at the top centre.
2. The user chooses menu bar strip or floating window.
3. Default: floating for large monitors, strip for MacBooks (`automatic`).
4. Existing installs stay on floating and get a one-time "Try the menu bar
   strip" hint in the floating toolbar. Fresh installs get `automatic`.
5. Clicking the strip opens the same menu as the old menu bar item. Hover
   still opens the expanded panel.
6. The old menu bar status item is removed. The floating window gives access
   to the main window and Settings, so floating mode needs no status item.

## Plans and gate

This spec produces two plans, in order:

1. **Spike plan.** A throwaway hardware prototype (see "Hardware spike"). Its
   findings are written back into this spec.
2. **Production plan.** Written only after the spike findings are in this spec
   and the owner has approved the revision. The implementation order at the
   end of this spec is the outline for that plan, not the plan itself.

## Placement setting

One new preference, `QuotaMeterPlacement`:

**Naming (owner decision, 2026-10-19, revised the same day).** "Quota Meter"
is the one product name for both presentations; the setting only says where it
shows. User-facing names: **Notch** (`menuBar`), **Desktop** (`floating`),
**Automatic**. Never "menu bar", "floating window" or "strip" for this feature
in UI copy: "menu bar" is the old menu bar item, which showed limits only.
"Notch" is used on every screen, including external monitors where the app
draws the notch. "Strip" stays an internal name. Stored raw values do not
change.

| Value | Behaviour |
|---|---|
| `floating` | Floating window always. Today's behaviour. |
| `menuBar` | Strip on the target screen, notched or not. |
| `automatic` | Strip when the target screen is the built-in display; floating window otherwise. |

**Default (owner decision, 2026-10-17; replaces 2026-10-13).**

- Fresh installs: `automatic`, written once at first launch.
- Existing installs (any install that ran an earlier version): an absent key
  resolves to `floating`, so nobody's Quota Meter moves after the update.
  They get the one-time notch intro (see "Discoverability").
- Users who had the old menu bar item on (`MenuBarEnabled == true`) get
  `menuBar` on the update, because the strip replaces what they chose.
- The resolver treats an unknown value as `floating`.

How the app tells a fresh install from an existing one is the builder's call;
it must use a key that every earlier version wrote.

### Strip screen and geometry

The strip goes on the target screen (below). Each screen with a menu bar has
its own, so the strip shows on that one screen only.

- **Notched screen** (`safeAreaInsets.top > 0` and both
  `auxiliaryTopLeftArea` and `auxiliaryTopRightArea` non-nil): wings flank the
  hardware notch; the notch sensor covers the notch rect. Notch x comes from
  the auxiliary rects' widths (`frame.minX + auxLeft.width` to
  `frame.maxX − auxRight.width`), which are right in any coordinate space.
- **Screen without a notch**: a virtual notch, a black sensor 24 pt wide
  centred on `frame.midX`, with the wings flanking it, so the strip reads as
  one black pill (95 + 24 + 95 pt). Height is the menu bar height
  (`frame.maxY − visibleFrame.maxY`), or 24 pt when the menu bar auto-hides.
  Long app menus on the left can reach the centre on narrow screens; Minimal
  style and `floating` are the escape hatches.

### Target screen

The target screen is the screen that holds the floating window's frame:

1. While the floating window is open: the screen with the largest intersection
   with its frame.
2. While it is not open: the screen with the largest intersection with its
   autosaved frame (`AgentCockpitHUDWindow.limits`).
3. When that frame intersects no connected screen, or there is no saved frame:
   the primary screen (`NSScreen.screens[0]`).

### When placement re-resolves

The coordinator re-resolves placement only on these events:

- app launch;
- the user shows the Quota Meter;
- `NSApplication.didChangeScreenParametersNotification` (display attached or
  removed, lid closed or opened, resolution or scaling changed), debounced by
  0.5 s so multi-step topology changes resolve once;
- the placement preference changes (Settings, View menu or toolbar switch).

Dragging the floating window to another screen does **not** re-resolve. A user
who drags the window onto the built-in display has chosen that position; the
window stays floating until the next event above.

Only one presentation is presented at a time, except for the brief overlap
allowed during a handoff (see "Handoff").

## Discoverability

Revised 2026-10-19 (owner decisions). The choice has four entry points:

1. **Settings → Quota Meter → Show Quota Meter in** (Notch / Desktop /
   Automatic, in that order). This is the canonical path. Automatic's help:
   "In the notch on the MacBook display, on the desktop on external monitors."
   The style row is "Notch Style" (Wings / Minimal).
2. **View menu → Show Quota Meter in** submenu with the same three choices.
   Keyboard-reachable; it also covers the strip's lack of keyboard focus.
3. **Toolbar and menu shortcuts:**
   - Desktop toolbar: "Move Quota Meter to Notch", with the notch glyph
     below. Sets `QuotaMeterPlacement` to `menuBar`.
   - Notch click menu and expanded-panel toolbar: "Move Quota Meter to
     Desktop". Sets `QuotaMeterPlacement` to `floating`.
   - The runway drawer button is gone from the toolbar; when the drawer shows
     is a Settings choice only (Session Runway: Auto by default).
4. **The notch intro** (below), once per user. It replaces the old one-time
   toolbar hint ("Try Quota Meter in the menu bar"), which is removed, so no
   user is asked twice. `QuotaMeterStripHintDismissed` is no longer read.

All routes change only the preference; the coordinator does the switch.

### Notch glyph

No SF Symbol means "notch" (`menubar.rectangle` and
`menubar.arrow.up.rectangle` were both rejected by the owner). The "Move
Quota Meter to Notch" button uses a custom glyph, option C from the owner
review (2026-10-19): a thin horizontal line for the top edge of the screen,
a filled notch silhouette hanging from its middle, and a small up arrow
below the notch pointing into it. About 15 × 11 pt, drawn as a SwiftUI
`Shape`/`Path` (not a bitmap) in the toolbar button's foreground colour, so
it follows the button states like the SF Symbols beside it. Accessibility
label: "Move Quota Meter to Notch".

### Notch intro (one-time launch dialog)

**Why.** The update's headline is the Quota Meter in the notch, and its value
is unique: live burn rate and when each quota will run out, always in view.
Existing desktop Quota Meter users and people with Codex or Claude sessions
who never opened the Quota Meter would otherwise find it only in Settings.
The pitch is never "limits" (the old menu bar item showed limits).

**Form (owner decision, 2026-10-19).** A modal dialog with a picture of the
notch, shown once when the app opens. Not a live drop-down from the notch.
This deliberately overrides the onboarding rule that updates never present a
modal (`OnboardingPresentation`): the owner wants this one shown to updating
users too.

**The picture.** A drawn illustration of the open notch, matching the owner-
reviewed mockup: a slice of the menu bar, the black notch panel open below
it, and inside it a Codex row and a Claude row in the real Quota Meter
styling (monospaced, green percents, bold orange run-out such as "▸2h 5m",
the "|" separator, reset times) plus one runway row with its burn rate and
orange load bar. Sample values, not the user's data. Drawn in SwiftUI so it
stays sharp and matches the product; the notch panel is black in both
appearances. No intro text inside the picture.

**Text.**
- Title: "Quota Meter in the notch"
- Body: "See your live burn rate and when your quota runs out, at the top of
  the screen. Hover to open it; click for the menu."

**Buttons, by state:**

| State | Buttons |
|---|---|
| Tracking on, placement resolves to the desktop | **Move to Notch** (default) · **Keep on Desktop** |
| Tracking on, placement resolves to the notch but the notch is hidden from the View menu | **Move to Notch** (default) · **Not Now** |
| Tracking on, placement already resolves to the notch (for example Automatic on a MacBook) | **Got It** (default) |
| Tracking off for every provider the user has sessions for | **Turn On** (default) · **Not Now** |

- **Move to Notch** clears `QuotaMeterStripHidden`, so a notch hidden from the
  View menu shows again. If the placement already resolves to the notch
  (Notch, or Automatic on the built-in display) it is kept, so Automatic stays
  Automatic; otherwise it sets `QuotaMeterPlacement` to `menuBar` (Notch). The
  coordinator does the switch as for any placement change. A user whose notch
  is hidden never gets Got It, and never "Keep on Desktop" when nothing is on
  the desktop (owner decisions, 2026-10-20).
- **Turn On** does what the session-list card's activation already does
  (turns usage tracking on for exactly the providers the user has sessions
  for, reusing `QuotaMeterPromoActivator`'s logic) and sets Notch the same way
  as Move to Notch (including showing a hidden notch). The
  button is the user's consent; the dialog never turns tracking on by
  itself.
- **After Move to Notch or Turn On** (owner decision, 2026-10-19): once the
  dialog has closed and the strip is presented, the real notch panel opens
  for about 3 s with the user's own data, then closes as after a hover. A
  pointer inside the panel keeps it open as usual. If the strip is not
  presented within 2 s (for example no screen can take it),
  skip this step.
- **Keep on Desktop**, **Not Now**, **Got It**, Escape and the close button
  change nothing.

**Who sees it.** Every user, on the first launch of the build that ships it
(fresh installs included), when all hold:

1. They have Codex or Claude sessions (`QuotaMeterProviderAvailability.hasAny`
   from the session index, after `audienceReady`). This includes users with
   usage tracking off (owner decision, 2026-10-19).
2. The fresh-install setup window and the What's New panel are not on screen.
   The dialog waits for them to close (the What's New *card* in the list does
   not block it).

**When.** As soon as both hold after launch: the moment the app opens for an
update, right after the setup window closes for a fresh install. Codex or
Claude sessions that reach the index within 60 s of that moment still count;
after that the decision is settled for the launch, so the dialog never pops up
mid-session (for example the first time someone runs Codex hours later, or
after Help → Power Tips closes).

**Once.** A new key, `QuotaMeterNotchIntroShown`, is set the moment the
dialog appears, so quitting or ignoring it never brings it back. No version
gating: once shown, never again in any later release. A placement change the
user makes in this build before the dialog appears (Settings, View menu,
toolbar or click menu) also sets the key: they have already chosen.

**Session-list Quota Meter card.** The dialog and the card never show in the
same launch: once the dialog has appeared, the card is not selected for the
rest of that launch. Move to Notch and Turn On also record the card's ask as
activated (`onboardingQuotaMeterAskState = .activated`) and mark the Quota
Meter as opened; the other buttons leave the card's state alone.

**How (builder's choice).** Reuse the onboarding presentation machinery (the
modal onboarding window or the list pane's sheet host, whichever fits) rather
than a new window type. The decision logic (eligibility, state, which buttons)
is pure and unit-tested in the hostless logic target, like
`QuotaMeterPlacementResolver`.

**Copy (zh-Hans needed).** Title, body and the six button labels above.

## Old menu bar item

The old status item (`UsageMenuBarLabel`, `StatusItemController`,
`MenuBarEnabled`) is removed. Its label duplicates the strip.

- **Its menu moves to the strip's click menu**, unchanged in content: sign-in
  "Fix…" rows, the live-session line ("N active • M waiting"), Open/Hide Quota
  Meter, Open/Hide Agent Sessions, the usage lines and reset credits, Hard
  Refresh per provider, copy-setup-command, Open Settings…, Show/Hide Dock
  Icon, Quit. Its label options (Source, Style, Scope, reset-indicator
  checkboxes, "Hide Menu Bar Item") are dropped, since they configured the old
  label.
- **Settings:** the Menu Bar tab and its keys (`MenuBarEnabled`,
  `MenuBarShowLiveSessionIcons`, reset-time toggles, `MenuBarShowPills`,
  `MenuBarScope`, `MenuBarStyle`, `MenuBarSource`) are retired.
- **Hidden Dock icon:** today allowed only while the status item is on or the
  Quota Meter is pinned. New rule: allowed only while the strip is presented
  or the floating window is pinned. If neither holds (for example the user
  switches to floating and unpins), the Dock icon comes back. The old
  "status item could not be shown" recovery path goes away with the item.
- **Polling:** the old label kept usage polling alive in the background
  (`setMenuVisible`). The strip already counts as visible and pinned in the
  usage-model table, so background polling is unchanged.

## Collapsed state: wings

Two black wings extend the notch (or the virtual notch) sideways inside the menu bar row. Each wing
has one fixed width (about 95 pt) in every state. It never widens.

- **Codex is always the left wing. Claude is always the right wing.**
- A wing shows a provider cell (see "Provider cell") and, only when that cell
  is a number, the runway indicators (see "Runway indicators").

### Provider cell

The wing uses the same state source and the same precedence as the floating
window's provider row (`HUDLimitsRowsPanel.row(entry:)`), first match wins:

| Order | State | Wing content |
|---|---|---|
| 1 | `presentationState == .needsAction` | Icon + "Sign in" |
| 2 | Probe visible for this source | Icon + "Probing" (or "Probe failed") |
| 3 | `presentationState == .idle` ("no active session") | Icon + "Idle" |
| 4 | `.reconnecting` and rate-limited | Icon + "Limited" |
| 5 | `.reconnecting` otherwise | Icon + "Retrying" |
| 6 | `.live` | Icon + percent (see below) |

"Idle" here is the provider-level state the floating window already shows as
"no active session". It is unrelated to idle runway rows.

Words come from localised resources. If a localised word does not fit the
fixed width, the wing shows the icon plus the state's SF Symbol only; the full
word goes to the tooltip and VoiceOver.

**Percent selection (`.live` only).** Candidates are the finite windows the
provider currently reports: 5h if present, weekly if present.

- Show the candidate with the least remaining quota (in "used" mode, the most
  used), honouring `UsageDisplayMode`.
- A dim tag follows the number: "5h" or "wk" (owner 2026-10-19: both windows are
  tagged, so the 5h number is as clear as the weekly one).
- Show `∞` only when the provider reports no finite window at all.

### Runway indicators

Revised 2026-10-19 after the visual and logic audit and the owner's choices.
Shown only when the provider cell is a number:

- **Agent activity mark** (owner 2026-10-19: agent-level in the strip,
  session-level in the hover panel and the floating window's runway): at most
  one small mark beside the number, from live presences (probe directories
  excluded):
  - dim white dot: at least one session of that agent is working (seen
    active-working within 30 s, so it does not flicker);
  - blue (accent) ring: a session stopped working within the last 10 minutes
    and has not started again, so it is the user's turn; wins over the dot;
  - nothing: quiet.
  Not orange or green, so it never reads as the system's microphone/camera
  dots or as the burn colour. No continuous animation. The app cannot yet tell
  a session blocked on a permission prompt from one that simply finished; the
  ring covers both. It replaces the orange tick bars, a "×2" count and a
  circled count, all of which read poorly.
- **Run-out chip** (`▸2h`): the panel's own 5h run-out label
  (`formatUsageProjectionLabel`, so it ages out after 3 minutes and rounds as
  there), cut to its leading unit (`▸2h 5m` → `▸2h`), bold, in the projection
  orange. Shown only beside a 5h number; beside a weekly number it would read as
  the week's run-out.
- **Tone** follows what is left only (green ≥ 30 %, orange < 30 %, red ≤ 10 %).
  The earlier "red when it will run out before reset" rule was removed: the
  projection tracker only publishes run-outs that fall before the reset, so the
  percent was red nearly all the time. The chip carries the warning, as in the
  panel. In the strip's hover panel, healthy percents use the same green.
- **Order:** the right wing mirrors the left (owner 2026-10-19): `icon 54% wk ●
  ▸2h` … `▸2h ● 5h 56% icon`. When a wing is too narrow, the activity mark
  drops first, then the chip.
- With one provider filling both wings, a window the provider lacks shows as
  `∞` with its tag (`∞ 5h`), never a bare `∞`; the chip and the count go on the
  5h wing only.
- The expanded Quota Meter stays loaded while the strip is on screen (owner: the
  on-hover load took 8–9 s), with its runway shimmer paused while collapsed.

### One provider hidden

When `QuotaMeterHiddenProviders` leaves one provider, it takes both wings: 5h
on the left, weekly on the right, each its own number with no "wk" tag needed.
Ticks and chip sit on the left wing.

### Crowded menu bar: Wings / Minimal

macOS has no supported, permission-free API for where other apps' menus and
status items sit. v1 does not detect collisions. A manual setting,
`QuotaMeterNotchStyle`, offers:

- **Wings** (default): as described above.
- **Minimal**: each wing becomes a 3 pt hairline on the bottom edge of the menu
  bar row beside the notch (2026-10-19: inside the row, so it never covers app
  windows below the bar). Its fill is
  the same percent; its colour follows the same state rules.

In Minimal the wing panels shrink to the hairline, so the menu bar pixels
beside the notch belong to the app underneath. The hover target is the notch
sensor over the black notch area itself, which never holds menu content, so
hover stays usable without a 3 pt target. `floating` remains the escape hatch.

### Full-screen apps

Acceptance criterion, confirmed or revised by the spike: in a full-screen Space
the wings stay visible in the black top strip.

## Expanded state: hover panel

Clicking a wing or the sensor opens the strip menu (see "Old menu bar item").
Hovering the strip grows the notch shape into the expanded panel (see "Visual
design"). It opens 0.3 s after the pointer enters and closes 0.1 s after the
pointer leaves.

- The floating Quota Meter's layout, stacked (revised 2026-10-18; replaces
  two columns): Codex block, a divider, Claude block. Each block, top to
  bottom:
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
  runway popovers, Settings, Open Agent Sessions, Move to floating window). The
  Pin button is hidden in the notch presentation; the stored Pin preference is
  not changed.
- With one provider visible, the panel shows one block.
- Every toolbar action is also reachable from the app's menus or Settings.

The panel always renders dark, because it extends black hardware. It ignores
the system appearance and `CockpitHUDReduceTransparency`.

## Hardware spike (spike plan scope)

Throwaway code on a real notched Mac, discarded afterwards. It must build the
full provisional topology, not just the wings:

- left wing panel, right wing panel;
- notch hover sensor over the notch rect;
- a provisional drop-down panel with one button and `canBecomeKey == true`,
  `canBecomeMain == false`;
- a Minimal-style hairline variant.

It must verify:

1. `.statusBar` level with `.nonactivatingPanel` draws over the menu bar row
   and does not block app menus or status items outside the panels, including
   Agent Sessions' own status item.
2. Notch geometry from `NSScreen` at default and scaled resolutions.
3. Hover crossing wing → notch sensor → drop panel and back without flicker;
   clicks and right-clicks; the panel button works without activating the app.
4. App menus and system pop-up menus open normally and outrank the panels.
5. Full-screen Spaces, Stage Manager, Mission Control.
6. Display attach and detach, lid close and reopen, sleep and wake, and rapid
   repeats of these; panels are torn down and recreated without leaks.
7. A handoff prototype in both directions (see "Handoff"), measuring the
   overlap or gap.
8. The top-centre strip on a screen without a notch (an external display with
   the lid closed): placement, hover, clicks, menus, and switching between the
   two screen kinds on lid open and close.
9. Clicking a wing opens an `NSMenu` from the strip without activating the
   app; the menu draws above the panels.

Findings are written into this spec ("Spike findings" section, added then).
If they contradict "Panel topology" or "Handoff", those sections change before
the production plan is written.

## Architecture

### Panel topology (revised 2026-10-18 after the prior-art study)

One panel per target screen, as boring.notch and codex-island do it. The
earlier design (several small panels) is replaced.

- The panel is sized for the expanded state and pinned top-centre on the
  notch (or virtual notch). It is clear; only the SwiftUI notch shape draws.
- **Click pass-through:** the hosting view's `hitTest` returns nil outside the
  current shape rect, and global plus local mouse monitors (`mouseMoved`,
  `leftMouseDragged`) toggle `ignoresMouseEvents` so the window takes events
  only while the pointer is inside the shape. `acceptsFirstMouse` is true.
- **Hover** comes from the same mouse monitors, not from `NSTrackingArea`
  (a window that ignores mouse events gets no tracking events).

Borderless `NSPanel` with `.nonactivatingPanel`, `canBecomeKey == false`,
`canBecomeMain == false`, `level = .statusBar`, `hidesOnDeactivate = false`,
non-opaque, no window shadow (the shape draws its own when open). Collection
behaviour: `.canJoinAllSpaces`, `.stationary`, `.fullScreenAuxiliary`,
`.ignoresCycle`. No level higher than `.statusBar` (best apps use
`.mainMenu + 3`; the spike checks whether `.statusBar` is enough).

### Visual design (revised 2026-10-18; owner approved the look on the LG)

- **Shape:** one animatable `NotchShape`: flat top flush with the screen edge,
  concave quad-curve flares into the menu bar, rounded bottom corners. Radii:
  closed top 6 / bottom 14, open top 19 / bottom 24. Pure black; a 1 pt black
  line inset by the flare hides seams at the screen edge.
- **Collapsed (mockup A):** wings 104 pt each beside the notch: Codex icon,
  percent, run-out chip on the left; mirrored Claude on the right. Percent
  green when healthy, orange under 30 %, red at 10 % or less; chip amber when
  the provider will run out before reset.
- **Expanded:** the same shape grows into the floating Quota Meter's content,
  in its own styles (SF Mono 12 pt medium limits rows, 11 pt runway rows,
  5 pt runway bars that breathe every 0.8 s, `hudProjectionColor` orange).
  A 0.5 pt white 12 % stroke and a black 50 % shadow (radius 20, y 10) appear
  only while open.
- **Motion:** open `spring(response 0.42, damping 0.82)`, close
  `spring(response 0.45, damping 1.0)`. Content fades in 0.22 s after a
  0.08 s delay (scale 0.98, top anchor) and fades out in 0.1 s. A
  `.levelChange` haptic plays on hover enter.

Notch panels carry their own window identifiers.
`AppWindowRouter.existingWindow(identifier: "AgentCockpit")` must never find
one.

### New units

- **`NotchGeometry`** (pure value type). Input: screen frame, safe-area insets,
  auxiliary left and right rects, menu bar height (for the virtual notch on a
  screen without one). Output: notch rect, wing rects, hairline
  rects, sensor rect, panel rect. No AppKit calls inside. Recomputed from
  `NSScreen` on every change; no notch coordinates are persisted.
- **`QuotaMeterPlacementResolver`** (pure function). Input: placement value
  (possibly absent), desired visibility, screen descriptors (frame, notched,
  built-in), floating frame (live or autosaved). Output: `hidden`, `floating`,
  or `notch(displayID)` (the strip, on any screen). It applies the "Strip
  screen and geometry", "Target screen" and default rules above (fresh,
  existing, and `MenuBarEnabled` installs).
- **`QuotaMeterPresentationCoordinator`** (`@MainActor`, app-scoped). The
  single owner of Quota Meter presentation. It:
  - owns desired visibility, persisted as `QuotaMeterDesiredVisible`;
  - calls the resolver on the events in "When placement re-resolves";
  - owns the notch panel controller and the runway store;
  - opens the SwiftUI `Window` scene only for the floating presentation;
  - exposes one `isPresented` for the View menu checkmark;
  - is the only caller of the usage models' `setCockpitVisible` (see
    "Usage-model lifecycle");
  - performs handoffs (see "Handoff") without activating the app.

  `AppWindowRouter`, the View-menu toggle and
  `maybeRestorePinnedCockpitOnLaunch` route through it.
  `CockpitWindowVisibility` may remain as a read-only facade derived from the
  coordinator; it stops being a mutable source of truth. The
  `setCockpitVisible` calls in `AgentCockpitHUDView` (today at lines 785–808,
  on appear, disappear and pin change) move to the coordinator.
- **`QuotaMeterNotchPanelController`**. Owns the notch panels and their frames.
- **`NotchWingView`** and **`NotchExpandedPanelView`** (SwiftUI). Notch-only
  state lives here: expanded or collapsed, pointer containment, notch style.

### Usage-model lifecycle

The usage models take one signal, `setCockpitVisible(visible, pinned)`. A
pinned cockpit is treated like the menu bar and keeps polling while the app is
inactive; an unpinned one polls only while the app is active. The coordinator
sends exactly this table:

| Desired visible | Presented as | Stored Pin | Signal sent |
|---|---|---|---|
| no | — | any | `(false, false)` |
| yes | floating | off | `(true, false)` |
| yes | floating | on | `(true, true)` |
| yes | notch | any | `(true, true)` |

Rules:

- The coordinator sends a signal only when the table's output changes.
- A handoff in either direction changes at most the `pinned` value. It never
  sends `visible = false` in between.
- App active/inactive stays inside the models (`setAppActive`), unchanged.
- Launch: the coordinator computes the row from the persisted inputs and sends
  it once, after resolving placement.
- `CockpitHUDPinned` is read, never written, by placement changes.

Consequence (accepted by the owner, 2026-10-13): a user whose floating window
is unpinned gets background polling while the Quota Meter is in the notch,
because the notch is always on top.

### Desired visibility and launch

- `QuotaMeterDesiredVisible` is written whenever the user shows or hides the
  Quota Meter, by any route.
- First launch after the update, with the key absent: the coordinator keeps
  today's behaviour (pinned restore via `CockpitHUDPinned`; otherwise the
  SwiftUI scene's own restoration) and records the result as the key.
- Later launches: if the key is true, the coordinator resolves placement and
  presents accordingly; it never opens the floating scene directly before
  resolving.

### Handoff

Rule: **show the new presentation first, then hide the old one.** A brief
overlap is allowed (target: under 250 ms); a gap is not.

- **Floating → notch:** order the notch panels front, then close the floating
  window. The model signal changes `pinned` only.
- **Notch → floating:** open the floating window without activating the app.
  When it reports on screen (`NSWindow.didChangeOcclusionStateNotification`
  with `.visible`, or a 1 s timeout), order the notch panels out. The model
  signal changes `pinned` only.

The spike measures the real overlap and confirms the signals.

### Shared data: two extractions

`HUDLimitsProviderEntry` is private to `AgentCockpitHUDView.swift` and built
inside `HUDLimitsRowsPanel`. The runway snapshots are `@State` in that panel
and refreshed by `runRunwayRefreshLoop()`, a 5 s loop started from the view's
`.task`.

1. **`QuotaMeterProviderPresentation`** plus a builder. A pure value type and a
   pure mapping from the existing model values and preferences, including the
   provider-cell precedence and percent-selection rules above. No polling, no
   copied source state.
2. **`QuotaMeterRunwayStore`** (`@MainActor`, observable facade):
   - **Lifetime:** one instance, created and owned by the coordinator for the
     app's lifetime.
   - **Activation:** active while the Quota Meter is presented in either
     presentation and runway visibility is not `alwaysOff`. Inactive otherwise:
     the loop stops and in-flight tasks are cancelled.
   - **Loop:** keeps today's 5 s cadence and today's request building
     (`HUDRunwayRequestBuilder`, `RunwaySnapshotAssembly`), moved out of the
     view.
   - **Per provider:** one in-flight task; a request key derived from the
     request inputs; a monotonic generation. A result whose generation is older
     than the current one is dropped (latest wins).
   - **Actor boundary:** loader work (`CodexRunwaySnapshotLoader`,
     `ClaudeRunwaySnapshotLoader`: file reads, parsing) runs off the main actor;
     only the finished snapshot is published on `@MainActor`.
   - Both presentations read it, so the loaders run once.

`CodexUsageModel`, `ClaudeUsageModel` and `CodexActiveSessionsModel` stay the
source of truth. No shadow model republishes their `@Published` values. The
extraction must not republish unchanged values; the existing publication
throttling must survive.

Floating-only state stays in the floating view: hover and chrome reveal,
resize anchor, toolbar presentation, window geometry.

`AgentCockpitHUDView.swift` is about 5,900 lines. New notch views go in new
files. Move `HUDRunwayPanel` and `HUDRunwayLoadBar` to their own file so both
presentations can use them; do not restructure the rest.

### Invariants

- Notch panels never use the floating window's autosave name and never write
  the floating frame.
- Switching to the notch preserves the autosaved floating frame. Returning to
  floating reopens at that frame (or, if it intersects no connected screen, at
  the default position on the primary screen).
- Placement changes never write `CockpitHUDPinned`.
- Launch restore resolves placement first, then presents.
- The usage models never see `visible = false` during a handoff.

## Energy

What the notch adds beyond today's visible Quota Meter:

- No `TimelineView`, animation loop, display link or timer in the collapsed
  state. Wing updates come from model and runway-store publishes only.
- `RunwayShimmerTicker` stays presentation-local and runs only while the
  expanded panel is visible and a row burns. Reduce Motion disables it.
- Display changes are handled from notifications only.

What it inherits (known costs):

- The runway store's 5 s loop runs while the Quota Meter is presented, as it
  does today while the floating window is open. The notch is presented for
  longer (always on top), so the loop runs for longer.
- Usage-model background polling, per "Usage-model lifecycle".

The production plan measures both against an unpinned floating baseline.

## Accessibility

- **VoiceOver:** one element per wing: provider, which window the number is
  (5h or weekly), quota, burn and run-out state, and the full bad-state wording.
  Session rows stay actionable.
- **Reduce Motion:** no open and close animation, no shimmer.
- **Increase Contrast:** state must not depend on dimming or on red and amber
  alone; provide a high-contrast text and border path.
- **Localisation:** all wing strings come from localised resources, with the
  icon-only fallback above.
- **Keyboard:** every action is reachable from menus or Settings.

## Risks and open questions

1. **Window and input mechanism.** Covered by the spike; nothing else starts
   until it passes.
2. **Background polling and the runway loop** run longer in the notch. Accepted;
   measured in the production plan.
3. **Discoverability.** Settings and the View menu are the real ways in; watch
   whether users find them.
4. **Notch size varies** by model and display scaling. All geometry comes from
   `NSScreen` at run time; only the wing width is fixed.
5. **Third-party notch apps** (Vibe Island, NotchNook, boring.notch) draw in the
   same place. No coordination is possible. Document it; `floating` is the
   escape hatch.
6. **Unverified code claims.** The 2026-10-17 review could not read source
   (Repo MCP returned empty reads). Claims checked locally on 2026-10-17: the
   provider-cell order (`HUDLimitsRowsPanel.row(entry:)`), the 5 s runway loop,
   the `setCockpitVisible` callers and the pinned-as-menu polling rule. The
   production plan re-checks the rest against source.

## Testing

- `NotchGeometry`: unit tests with fixed inputs for 14" and 16" at default and
  scaled resolutions, a screen with no notch (virtual notch, including an
  auto-hidden menu bar), a built-in screen whose origin is not (0,0), and two
  notched screens.
- `QuotaMeterPlacementResolver`: table test over placement (including absent) ×
  install kind (fresh, existing, `MenuBarEnabled`) × desired visibility ×
  screens × floating frame (on built-in, on external,
  orphaned, absent).
- `QuotaMeterPresentationCoordinator`: lifecycle tests for every row of the
  usage-model table and every transition between rows; handoff in both
  directions never emits `visible = false`; launch with the desired-visibility
  key absent and present; screen-change debounce; dragging does not
  re-resolve; autosaved frame preserved.
- Provider presentation builder: precedence table, percent selection (5h only,
  weekly only, both, neither), "wk" tag, one-provider case.
- `QuotaMeterRunwayStore`: activation and deactivation, latest-wins with an
  out-of-order completion, cancellation on deactivate, one loader per provider.
- Both extractions: the existing Quota Meter tests pass unchanged, with the same
  test count.
- Visual: render `NotchWingView` and `NotchExpandedPanelView` to PNG with
  `ImageRenderer` for each state, including the longest localised words. This
  is supplementary; it cannot test window level, Spaces or clicks.
- Hardware matrix, run in the spike and again at feature-complete: built-in
  only, external extended desktop, external with lid closed, lid reopen,
  full-screen Space, Stage Manager, scaled resolution, an app with long menus, a
  crowded status area including Agent Sessions' own item, sleep and wake.

## Implementation order (outline for the production plan)

Written up as the production plan only after the spike findings are in this
spec. Steps 1–4 ship with no visible change; each step is independently
shippable.

1. Placement and screen types: `QuotaMeterPlacement`, screen descriptors,
   `NotchGeometry`, resolver, table tests.
2. `QuotaMeterProviderPresentation` and builder. Floating window unchanged.
3. `QuotaMeterRunwayStore`. Floating window wired to it first.
4. `QuotaMeterPresentationCoordinator`, resolving everything to floating. View
   menu, pinned restore and the `setCockpitVisible` calls routed through it.
5. Strip panel controller and collapsed wings on both screen kinds, behind the
   `menuBar` preference; strip click menu.
6. Expanded panel with session actions and right-click toolbar.
7. Settings placement picker, View-menu submenu, toolbar shortcuts.
8. Wings / Minimal notch style.
9. Accessibility, localisation and energy pass, covering both styles.
10. Remove the old menu bar item: retire its keys and Settings tab, migrate
    `MenuBarEnabled` users to `menuBar`, new hidden-Dock-icon rule, defaults
    for fresh and existing installs, one-time hint.
11. Hardware regression QA.

## Prior art

Vibe Island (paid) advertises usage limits in the notch. Its own comparison
lists Claude Island, Notchi and Open Island as not showing them; that is a
vendor claim, not verified here. CodexBar shows limits in the menu bar only.

## Review record

- 2026-10-12, architecture review via Repo MCP, ChatGPT web, 5.6 Extra High
  (not the Sol Pro profile; not journaled). Proceed with changes; partial
  (tunnel dropped). All nine findings applied 2026-10-13.
- 2026-10-17, XHigh spec review via Repo MCP, ChatGPT web, GPT-5.6 Sol Extra
  High, commit-pinned to 3152f1a0, journaled (run a3fef95b). NO-SHIP. Source
  reads returned empty, so only spec-internal findings. All 13 findings
  applied in this revision.
- 2026-10-17, XHigh review of the spike plan via Repo MCP, ChatGPT web,
  GPT-5.6 Sol Extra High, commit-pinned 32c02443..40419a2a, journaled (run
  286a7034). NO-SHIP: 1 blocker (a visibility timeout counted as a successful
  handoff), 2 majors, 4 minors. All applied to the spike plan; see its
  "Review record".
