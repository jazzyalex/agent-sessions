# Quota Meter Menu Bar Strip Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the menu bar strip in Agent Sessions: a toggle between the existing floating Quota Meter and a notch-shaped strip with real data, whose click menu replaces the old menu bar item.

**Architecture:** Pure logic (geometry, placement resolution, defaults, wing cell text) lives in Foundation-only files compiled into both the app and the hostless `AgentSessionsLogicTests` target. A `QuotaStripController` owns one non-activating panel per target screen and hosts the spike-proven notch view; its expanded content is the real `AgentCockpitHUDView` in a new `.strip` surface mode, so the rows, runway and polling are identical to the floating window. A `QuotaMeterPresentationCoordinator` resolves placement and switches between the existing window and the strip.

**Tech Stack:** Swift 6.2, SwiftUI + AppKit, XCTest (logic target), macOS 14+.

**Spec:** `docs/superpowers/specs/2026-10-12-quota-meter-notch-design.md` (sections "Owner decisions 2026-10-17", "Placement setting", "Strip screen and geometry", "Discoverability", "Old menu bar item", "Panel topology", "Visual design", "Expanded state"). Visual reference: `tools/notch-spike/` (owner approved the look on the external display, 2026-10-18).

## Global Constraints

- The floating window is the existing Quota Meter, unchanged except the "Move to menu bar" toolbar button and the one-time hint. No new floating window.
- `QuotaMeterPlacement` values: `floating`, `menuBar`, `automatic`. Fresh installs get `automatic`; existing installs resolve an absent key to `floating`; `MenuBarEnabled == true` installs get `menuBar`; unknown values resolve to `floating`.
- `automatic`: strip when the target screen is the built-in display, floating otherwise. `menuBar`: strip on the target screen, notched or not.
- Target screen: largest intersection with the floating window's live frame, else its autosaved frame (`AgentCockpitHUDWindow.limits`), else `NSScreen.screens[0]`.
- Geometry: notch x from aux widths (`frame.minX + auxLeft.width` … `frame.maxX − auxRight.width`); screens without a notch get a 24 pt virtual notch centred on `frame.midX`, height `frame.maxY − visibleFrame.maxY` or 24 when that is ≤ 0. Wings 104 pt.
- Shape radii closed 6/14, open 19/24; open `spring(response 0.42, damping 0.82)`, close `spring(response 0.45, damping 1.0)`; hover opens after 0.3 s, closes 0.1 s after leaving; `.levelChange` haptic on enter; open-only 0.5 pt white 12 % stroke and black 50 % shadow (radius 20, y 10).
- Panel: borderless `NSPanel`, `.nonactivatingPanel`, `canBecomeKey == false`, `canBecomeMain == false`, `level = .statusBar`, `hidesOnDeactivate = false`, `[.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]`; `hitTest` limited to the shape; `ignoresMouseEvents` toggled by global + local mouse monitors.
- Screen changes debounced 0.5 s; wake goes through the same debouncer. Dragging the floating window never re-resolves.
- Clicking the strip opens the old menu bar item's menu; its label options and "Hide Menu Bar Item" are dropped; "Move to floating window" is added.
- Hidden Dock icon allowed only while the strip is presented or the floating window is pinned.
- New Swift files are added with `scripts/xcode_add_file.rb` (exactly 4 pbxproj lines per add). Pure files go into both `AgentSessions` and `AgentSessionsLogicTests`; they import only Foundation/CoreGraphics.
- Never run the hosted `AgentSessionsTests` (it opens the live index). Logic tests: `xcodebuild test -project AgentSessions.xcodeproj -scheme AgentSessionsLogicTests -destination 'platform=macOS,arch=arm64' -derivedDataPath .deriveddata-logic`. App build: `xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug -derivedDataPath .deriveddata-run build`.
- UI follows `agents.md` spacing tokens and HIG. Commits only when the owner asks, with `git commit -- <paths>`.

## Review Focus

1. **Lid closed with only an external display, `automatic` placement:** the floating window shows, no strip; opening the lid moves to the strip on the built-in display. Resolver test `automaticFollowsTargetScreenKind` (Task 1); owner QA Q4.
2. **Existing user updates:** their Quota Meter stays floating, nothing moves; an old `MenuBarEnabled` user gets the strip instead of losing their menu bar presence. Defaults tests (Task 1).
3. **Hidden Dock icon and the user switches to floating, unpinned:** the Dock icon returns, so the app stays reachable. Task 6 reconcile call; owner QA Q7.
4. **Provider signed out or idle while collapsed:** the wing shows the state word in a muted tone, never a stale percent. Cell tests (Task 1).
5. **Clicks beside the strip** (status items, app menus) reach their targets; only the shape takes events. Owner QA Q2.

---

### Task 1: Pure core — geometry, placement resolver, defaults, wing cells

**Files:**
- Create: `AgentSessions/QuotaStrip/QuotaStripGeometry.swift`, `AgentSessions/QuotaStrip/QuotaMeterPlacementResolver.swift`, `AgentSessions/QuotaStrip/QuotaStripCell.swift`
- Test: `AgentSessionsLogicTests/QuotaStripCoreTests.swift`
- Modify: `AgentSessions.xcodeproj/project.pbxproj` (via `xcode_add_file.rb`: three sources to both targets, the test to the logic target)

**Interfaces:**
- Produces:
  - `struct QuotaStripLayout: Equatable { let notch: CGRect; let leftWing: CGRect; let rightWing: CGRect; let isVirtual: Bool }`
  - `enum QuotaStripGeometry { static let wingWidth: CGFloat = 104; static func layout(screenFrame: CGRect, visibleFrame: CGRect, safeAreaTop: CGFloat, auxLeftWidth: CGFloat?, auxRightWidth: CGFloat?) -> QuotaStripLayout }` — notched when `safeAreaTop > 0` and both widths non-nil, else virtual.
  - `enum PlacementChoice: String { case floating, menuBar, automatic }`
  - `struct PlacementScreen: Equatable { let id: UInt32; let frame: CGRect; let isBuiltin: Bool }`
  - `enum PlacementDecision: Equatable { case floating; case strip(screenID: UInt32) }`
  - `enum QuotaMeterPlacementResolver { static func resolve(_ choice: PlacementChoice, screens: [PlacementScreen], floatingFrame: CGRect?) -> PlacementDecision; static func targetScreen(screens: [PlacementScreen], floatingFrame: CGRect?) -> PlacementScreen? }`
  - `enum QuotaMeterPlacementDefaults { static func valueToWrite(storedRaw: String?, menuBarEnabled: Bool, isFreshInstall: Bool) -> PlacementChoice? }` — nil when a value is stored.
  - `struct StripCellInput { enum State { case live, needsAction, probing, idle, limited, retrying }; var state: State; var fiveHourLeft: Int?; var weekLeft: Int?; var projectedRunout: Date?; var fiveHourResetAt: Date?; var now: Date }`
  - `struct StripCell: Equatable { enum Tone { case healthy, warning, critical, muted }; let text: String; let tag: String?; let tone: Tone; let chip: String?; let chipWarns: Bool }`
  - `enum QuotaStripCellBuilder { static func cell(_ input: StripCellInput) -> StripCell }`

Rules for the cell builder: non-live states → text "Sign in" / "Probing" / "Idle" / "Limited" / "Retrying", tone `.muted`, no chip. Live → candidates are the non-nil windows; show the smallest; tag "wk" when it is the weekly one; "∞" with `.muted` when none. Tone: ≤ 10 critical, < 30 warning, else healthy. Chip only when `projectedRunout` is in the future: under 1 h "▸Nm", else "▸Nh" (whole hours, rounded down); `chipWarns` when `fiveHourResetAt` exists and runout is before it.

- [ ] **Step 1: Write the failing tests** in `QuotaStripCoreTests.swift` (XCTest):
  - `testNotchedLayoutUsesAuxWidths`: frame (0,0,1512,982), visible maxY 950, safeTop 32, aux 664/664 → notch `(664, 950, 184, 32)`, leftWing `(560, 950, 104, 32)`, `isVirtual == false`.
  - `testOffsetBuiltinScreen`: frame origin (2560,0), same widths → notch.minX `3224`.
  - `testVirtualNotchCentred`: frame (0,0,2560,1440), visible maxY 1415, safeTop 0 → notch `(1268, 1415, 24, 25)`, `isVirtual`.
  - `testVirtualNotchAutoHiddenMenuBar`: visible maxY 1440 → notch height 24, y 1416.
  - `testAutomaticFollowsTargetScreenKind`: builtin id 1 frame (0,0,1512,982), external id 2 frame (1512,0,2560,1440); floatingFrame on external → `.floating`; on builtin → `.strip(screenID: 1)`; only external connected (lid closed) → `.floating`.
  - `testMenuBarStripsOnTargetEvenWithoutNotch`: external only → `.strip(screenID: 2)`.
  - `testFloatingAlwaysFloats` and `testOrphanedFrameFallsBackToFirstScreen` (frame at x 10000 → target is `screens[0]`), `testNoScreensIsFloating`.
  - `testDefaults`: stored "menuBar" → nil; absent + MenuBarEnabled → `.menuBar`; absent + fresh → `.automatic`; absent, existing → `.floating`.
  - `testCellStates`: needsAction → ("Sign in", muted, chip nil); idle → "Idle".
  - `testCellPicksLeastRemaining`: 5h 62, wk 40 → text "40%", tag "wk", healthy; 5h 24, wk 80 → "24%", tag nil, warning; 5h 8 → critical; both nil → "∞" muted.
  - `testCellChip`: runout now+40 min → "▸40m"; now+2h10m → "▸2h"; runout before reset → `chipWarns`; runout in the past → chip nil.
- [ ] **Step 2: Add the files to the project and run the logic tests.** Expected: compile failure (types missing).
- [ ] **Step 3: Implement the three files** per the interfaces and rules.
- [ ] **Step 4: Run the logic tests.** Expected: all pass, including the existing logic tests.

### Task 2: Placement preference, defaults at launch, Settings and View menu

**Files:**
- Modify: `AgentSessions/CodexStatus/UsageDisplayMode.swift` (add `QuotaMeterPlacement`), `AgentSessions/Views/Preferences/PreferencesConstants.swift` (`quotaMeterPlacement = "QuotaMeterPlacement"`, `quotaMeterStripHintDismissed = "QuotaMeterStripHintDismissed"`), `AgentSessions/Views/Preferences/PreferencesView+General.swift` (Placement row in the Quota Meter section), `AgentSessions/Views/PreferencesView.swift` (`@AppStorage` + reset block), `AgentSessions/AgentSessionsApp.swift` (defaults at init; View → Quota Meter Placement submenu)

**Interfaces:**
- Produces: `enum QuotaMeterPlacement: String, CaseIterable, Identifiable { case floating, menuBar, automatic; static let storageKey; var title: LocalizedStringResource /* "Floating window", "Menu bar", "Automatic" */; var detail: LocalizedStringResource; var choice: PlacementChoice; static func current(raw: String?) -> QuotaMeterPlacement /* unknown → .floating */ }`.
- Defaults run first thing in `AgentSessionsApp.init`, before the Sparkle updater is created: `isFreshInstall = defaults.object(forKey: "SUHasLaunchedBefore") == nil && defaults.object(forKey: "OnboardingFirstLaunchDate") == nil`; write `QuotaMeterPlacementDefaults.valueToWrite(...)` when non-nil.
- Settings: `labeledRow("Placement")` with a segmented `Picker` over `QuotaMeterPlacement.allCases`, then the selected case's `detail` as the caption, matching the "Toolbar" row.
- View menu: a "Quota Meter Placement" `Picker` (inline) under the existing Quota Meter toggle, bound to the same `@AppStorage`.

- [ ] **Step 1: Implement**, then build. Expected: `** BUILD SUCCEEDED **`.
- [ ] **Step 2: Run the logic tests.** Expected: pass (no change in count).

### Task 3: `AgentCockpitHUDView` strip surface

**Files:**
- Modify: `AgentSessions/Views/AgentCockpitHUDView.swift`

**Interfaces:**
- Produces: `enum QuotaMeterSurface { case window, strip }` and `init(codexIndexer:claudeIndexer:opencodeIndexer:surface: QuotaMeterSurface = .window)`.
- In `.strip`: no `header`, no `AgentCockpitHUDWindowConfigurator`, no right-click catcher or hint pill, no hidden ⌘W shortcut, no background material or border (clear; the strip draws black), `.environment(\.colorScheme, .dark)`, `showsChrome` true for the limits panel (extra lines visible), usage-model visibility `setCockpitVisible(true, pinned: true)` with a distinct consumer ID `"quota-strip"` for `setCockpitConsumerVisible`, and it must not write `Cockpit.hudOpen = false` on disappear while a floating window is open (only the window surface owns `hudOpen`; the strip sets it true on appear and false on disappear only when no window is visible).
- `.window` behaviour is byte-for-byte unchanged.

- [ ] **Step 1: Implement**, build. Expected: success. The floating window looks and behaves exactly as before (owner QA Q1).

### Task 4: Strip panel, view and controller

**Files:**
- Create: `AgentSessions/QuotaStrip/NotchShape.swift`, `AgentSessions/QuotaStrip/QuotaStripView.swift`, `AgentSessions/QuotaStrip/QuotaStripController.swift`
- Modify: `AgentSessions.xcodeproj/project.pbxproj` (app target only)

**Interfaces:**
- Consumes: Task 1 geometry and cells, Task 3 surface.
- Produces: `@MainActor final class QuotaStripController { init(codexIndexer:claudeIndexer:opencodeIndexer:activeCodex:codexUsage:claudeUsage:); var menuProvider: (() -> NSMenu?)?; private(set) var isPresented: Bool; func present(on screenID: UInt32); func dismiss() }`.
- Port from the spike: `NotchShape` (animatable radii), the model (`expanded`, `notchWidth/Height`, `expandedSize`, `panelSize`, `hitRect`), the hosting view (`hitTest` to `hitRect`, `acceptsFirstMouse`, click → menu when collapsed or in the notch row), mouse monitors toggling `ignoresMouseEvents`, single-region hover timer (0.3 s open / 0.1 s close, `.common` run-loop mode), screen-change and wake debouncer (0.5 s) that asks the coordinator to re-resolve.
- Collapsed wings read `QuotaData.codex(from:)` / `.claude(from:)`, map `presentationState` (and probe/limited/retrying as `HUDLimitsRowsPanel.row(entry:)` does) into `StripCellInput`, and render `StripCell` like the spike's `WingContent` (icons `FooterIconCodex` template white, `FooterIconClaude` original; SF Mono 12 pt semibold; tones: healthy green `(0.36, 0.84, 0.62)`, warning orange, critical red, muted 55 % white; chip white 72 % or `hudProjectionColor` dark when `chipWarns`). `QuotaMeterHiddenProviders` with one provider left: that provider fills both wings (5h left, weekly right).
- Expanded content: `AgentCockpitHUDView(..., surface: .strip)` mounted for the whole time the strip is presented (so data and polling stay live), shown only while expanded; its size is measured with a `GeometryReader` preference and drives `expandedSize`.
- Panels carry identifier `"QuotaStrip"`; `AppWindowRouter.existingWindow(identifier: "AgentCockpit")` never matches them.

- [ ] **Step 1: Implement**, build. Expected: success.

### Task 5: Presentation coordinator and switching

**Files:**
- Create: `AgentSessions/QuotaStrip/QuotaMeterPresentationCoordinator.swift`
- Modify: `AgentSessions/AgentSessionsApp.swift` (create the coordinator at bootstrap; View-menu toggle and pinned-restore go through it), `AgentSessions/Views/AgentCockpitHUDView.swift` (toolbar "Move to menu bar" button, window surface only), `AgentSessions/Onboarding/Views/OnboardingListTopSlot.swift:775` (show via coordinator)

**Interfaces:**
- Produces: `@MainActor final class QuotaMeterPresentationCoordinator: ObservableObject { static let shared; @Published private(set) var decision: PlacementDecision; var isStripPresented: Bool; func start(stripController: QuotaStripController, openWindow: @escaping () -> Void); func reresolve(reason: String); func toggleQuotaMeter(); func showQuotaMeter() }`.
- `reresolve` runs on: start, placement preference change, debounced screen change, wake. Strip decision → close the floating window (`AppWindowRouter.closeAgentCockpitWindow()`), `present(on:)`. Floating decision → `dismiss()` the strip and, when it was presented before or the window was pinned, open the window. No re-resolve on window drag.
- View-menu "Quota Meter" toggle: in strip mode it hides/shows the strip (`QuotaMeterStripHidden`, default false); in floating mode it opens/closes the window as today. `CockpitWindowVisibility.isVisible` is true while either is presented.
- Toolbar button "Move to menu bar" (`menubar.rectangle` symbol, `HUDIconButtonStyle`) sets placement to `menuBar`.

- [ ] **Step 1: Implement**, build. Expected: success.

### Task 6: Strip menu replaces the old menu bar item

**Files:**
- Modify: `AgentSessions/MenuBar/StatusItemController.swift` (keep the class as the menu provider; never create an `NSStatusItem`; `func makeMenu() -> NSMenu`), `AgentSessions/AgentSessionsApp.swift` (remove status-item creation, `MenuBarEnabled` observer and visibility-recovery path; migrate via Task 2 defaults), `AgentSessions/Services/ActivationPolicyDecider.swift` callers (pass `menuBarEnabled: coordinator.isStripPresented`; call `reconcileReachability` after every decision change), `AgentSessions/Views/PreferencesView.swift` and `Preferences/PreferencesView+MenuBar.swift` (remove the Menu Bar tab), `AgentSessions/MenuBar/UsageMenuBar.swift` (unused label views removed)

**Interfaces:**
- Consumes: `QuotaStripController.menuProvider`, coordinator.
- Menu content per spec "Old menu bar item": keep sign-in Fix rows, live-session line, Open/Hide Agent Sessions, usage lines and reset credits, Hard Refresh, copy-setup-command, Open Settings…, Show/Hide Dock Icon, Quit; replace "Open/Hide Quota Meter" with "Move to floating window" (sets placement `floating`); drop Source/Style/Scope, reset-indicator checkboxes and "Hide Menu Bar Item". "Open Settings…" opens the Quota Meter tab.

- [ ] **Step 1: Implement**, build. Expected: success; `grep -n "NSStatusBar" AgentSessions` finds nothing.
- [ ] **Step 2: Run the logic tests.** Expected: pass.

### Task 7: One-time hint for existing installs

**Files:**
- Modify: `AgentSessions/Views/AgentCockpitHUDView.swift` (window surface toolbar)

**Interfaces:**
- When placement is `floating`, `QuotaMeterStripHintDismissed` is false and the toolbar is revealed: a capsule under the toolbar, "Try the menu bar strip", with "Try it" (sets `menuBar`, marks dismissed) and a close button (marks dismissed). Fresh installs write the key true at launch (Task 2 defaults step) so they never see it.

- [ ] **Step 1: Implement**, build. Expected: success.

### Task 8: Verification and owner QA

- [ ] **Step 1: Logic tests and build.** Expected: all pass; build succeeds.
- [ ] **Step 2: Docs.** Spike plan and checklist: drop the floating stand-in (Task 5, C7, V4) and note the strip shipped in the app; spec "Hardware spike" item 7 moves to this QA.
- [ ] **Step 3: Owner QA** (the agent builds, the owner runs the app):
  - Q1 Floating window unchanged; toolbar shows "Move to menu bar".
  - Q2 Menu bar placement: strip with real numbers; hover opens the real Quota Meter rows and runway; clicks beside the strip reach status items and menus.
  - Q3 Click the strip: the menu opens with the old item's actions; "Move to floating window" switches back.
  - Q4 Automatic: lid closed + LG → floating; open the lid → strip on the MacBook.
  - Q5 Settings Placement and View menu stay in sync.
  - Q6 No old menu bar item anywhere; Settings has no Menu Bar tab.
  - Q7 Hide the Dock icon in strip mode, switch to floating unpinned: the Dock icon returns.
- [ ] **Step 4: Fresh-context code review** (Repo MCP, commit-pinned) once the owner asks to commit; fix; commit and push on request.

## Follow-up (owner request 2026-10-19): the four spec features not covered above

### Task 9: Will-run-out turns the percent red
- `QuotaStripCellBuilder`: when `chipWarns`, tone is `.critical` (spec "Runway indicators": percent red, chip amber, no size change).
- Test `testWillRunOutTurnsPercentRed`: 5h 50 %, runout before reset → tone `.critical`, `chipWarns`.

### Task 10: Runway ticks in the wings
- `StripCellInput.burningSessions: Int` (default 0); `StripCell.ticks: Int` = `min(4, burningSessions)` only for a live number, else 0.
- Burning sessions per provider = live presences of that source whose `liveState == .activeWorking`, probe directories excluded (the collapsed strip does not run the runway loaders; Ruling: active-working presence stands in for runway `.direct`/`.mixed`).
- Wing draws up to four 6×2 pt orange ticks under the number, inside the wing; no width change.
- Tests `testTicksOnlyForLiveNumbers`, `testTicksClampAtFour`.

### Task 11: Right-click toolbar on the open panel
- `.strip` surface: right-click reveals the HUD header (same as on-demand chrome); the Pin button is hidden; a "Move to floating window" button replaces "Move to menu bar". The header collapses when the panel collapses.
- `QuotaStripController` keeps the panel open while a toolbar popover is on screen.

### Task 12: Wings / Minimal style
- `QuotaMeterNotchStyle` (`wings` default, `minimal`), key `QuotaMeterNotchStyle`; Settings "Strip Style" row (Wings / Minimal) with a caption.
- Minimal: collapsed shape is the notch (or virtual notch) only, which is the hover and click target; two 3 pt hairlines under the wing positions, filled by percent left, coloured by the cell tone.
- Test: geometry unchanged; visual check by the owner.
