# Quota Meter Notch Naming, Glyph and Intro Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Call the strip "Notch" everywhere, give "Move Quota Meter to Notch" its own glyph, and show every Codex or Claude user a one-time dialog that invites them to put the Quota Meter in the notch.

**Architecture:** Copy changes go through the existing `QuotaMeterPlacement` titles and the string catalog. The intro's who/which-buttons rule is a pure type in `AgentSessions/QuotaStrip/` compiled into both the app and the hostless `AgentSessionsLogicTests` target, like `QuotaMeterPlacementResolver`. The dialog is one more sheet on the session-list pane's existing onboarding sheet host, triggered from `OnboardingListTopSlot`, which already knows the session audience.

**Tech Stack:** Swift, SwiftUI + AppKit, XCTest (hostless logic target), `Localizable.xcstrings` + `scripts/validate_localization_catalogs.py`.

**Spec:** `docs/superpowers/specs/2026-10-12-quota-meter-notch-design.md`, sections revised 2026-10-19: "Placement setting" (Naming), "Discoverability", "Notch glyph", "Notch intro (one-time launch dialog)".

## Global Constraints

- User-facing names: **Notch** (`menuBar`), **Desktop** (`floating`), **Automatic**. Never "menu bar", "floating window" or "strip" for this feature in UI copy. Stored raw values do not change.
- `MenuBarEnabled` stays written only by `QuotaMeterPresentationCoordinator`; the intro writes only `QuotaMeterPlacement`, the usage-tracking keys (Turn On only) and `QuotaMeterNotchIntroShown`.
- Every new or changed user-facing string gets an `en` and a `zh-Hans` catalog entry (Quota Meter = 额度监视器, notch = 刘海, desktop = 桌面). Update `EXPECTED_LOCALIZABLE_KEY_COUNT`/`EXPECTED_LOCALIZABLE_KEY_SHA256` in `scripts/validate_localization_catalogs.py` and the count in `scripts/tests/test_validate_localization_catalogs.py` from the validator's own failure message.
- New Swift files are added with `scripts/xcode_add_file.rb` (a correct run adds exactly 4 pbxproj lines per target).
- Never run `xcodebuild test` on the hosted `AgentSessionsTests` scheme (it opens the live index). Only the hostless logic scheme.
- Edits use the Edit tool, never inline Python or heredoc rewrites.
- **No commits.** The owner commits on request with `git commit -- <paths>`. Each task ends at a checkpoint, not a commit.

**Baseline (already uncommitted on `main`, keep it):** panel grid alignment, strip click-menu position, "Desktop" naming and the Menu Bar copy that Task 1 replaces, runway drawer button removal, permission-prompt backlog entry, spec edits.

**Verification commands (used by every task):**
- Build: `xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug -derivedDataPath .deriveddata-run build` → `** BUILD SUCCEEDED **`
- Logic tests: `xcodebuild test -project AgentSessions.xcodeproj -scheme AgentSessionsLogicTests -destination 'platform=macOS,arch=arm64' -derivedDataPath .deriveddata-logic` → `** TEST SUCCEEDED **`, 82 tests before this plan
- Localization: `python3 scripts/validate_localization_catalogs.py --extraction-root .deriveddata-run/Build/Intermediates.noindex/AgentSessions.build/Debug/AgentSessions.build/Objects-normal` and `python3 -m unittest scripts/tests/test_validate_localization_catalogs.py` → both valid / OK

## Review Focus

1. A user with sessions for both agents, Codex tracking on and Claude tracking off, must get **Move to Notch**, not Turn On. Pinned in Task 3 (`testPartialTrackingIsTrackingOn`).
2. On a fresh install the setup window is open when the audience becomes ready; the dialog must wait and appear after it closes, not be lost. Pinned in Task 3 (`testBlockingSurfaceDefers`) and Task 5 Step 4 (re-evaluate on close).
3. The session-list Quota Meter card already chosen this launch must keep the dialog away for this launch, and the dialog must keep the card away. Pinned in Task 3 (`testQuotaMeterCardOnScreenDefers`) and Task 5 Step 3.
4. A placement change the user makes before the dialog appears must retire the dialog for good. Pinned in Task 4 Step 3 (coordinator write) and Task 3 (`testAlreadyShownNeverShows`).
5. Move to Notch while the notch is hidden from the View menu must still set the placement and must not leave a peek timer running against an absent panel. Pinned in Task 4 Step 2 (2 s presentation timeout).

---

### Task 1: "Notch" naming everywhere

**Files:**
- Modify: `AgentSessions/CodexStatus/UsageDisplayMode.swift` (`QuotaMeterPlacement.title` / `.detail`)
- Modify: `AgentSessions/Views/Preferences/PreferencesView+General.swift` (placement help, "Menu Bar Style" row and its help)
- Modify: `AgentSessions/Views/AgentCockpitHUDView.swift` (`cockpitMoveToMenuBarButton` tooltip)
- Modify: `AgentSessions/Resources/Localizable.xcstrings`, `scripts/validate_localization_catalogs.py`, `scripts/tests/test_validate_localization_catalogs.py`

**Interfaces:**
- Produces: the catalog keys "Notch", "Move Quota Meter to Notch", "Notch Style", used by Tasks 2 and 5.

- [ ] **Step 1: Change the copy to these exact strings**

| Where | New string |
|---|---|
| `QuotaMeterPlacement.menuBar.title` | "Notch" |
| `QuotaMeterPlacement.menuBar.detail` | "The Quota Meter sits in the notch at the top of the screen. Hover to expand it; click for the menu." |
| `QuotaMeterPlacement.automatic.detail` | "In the notch on the MacBook display, on the desktop on external monitors." |
| Settings placement `.help` | "Show the Quota Meter in the notch or on the desktop." |
| Settings style row label | "Notch Style" |
| Settings style row `.help` | "Choose how much of the menu bar the collapsed notch uses." |
| `cockpitMoveToMenuBarButton` `.help` and accessibility label | "Move Quota Meter to Notch" |
| "Hide Dock icon" `.help` | "Removes Agent Sessions from the Dock while the Quota Meter in the notch, or a pinned Quota Meter on the desktop, keeps the app reachable. Hiding the Dock icon without either moves the Quota Meter to the notch." |

Leave the "Menu Bar" catalog key in place: `PreferencesView.swift:1255` still uses it.

- [ ] **Step 2: Rename the catalog entries in place (key, `en` value, `zh-Hans` value) and update the validator baseline**

zh-Hans: "Notch" 刘海 · "Notch Style" 刘海样式 · "Move Quota Meter to Notch" 将额度监视器移至刘海 · the detail/help strings translated with 刘海 for notch.

- [ ] **Step 3: Run build and localization; grep the app sources for leftover user-facing "menu bar" copy about this feature**

Run: `grep -rn '"[^"]*[Mm]enu [Bb]ar[^"]*"' AgentSessions --include='*.swift'` and confirm every remaining hit is the old menu bar item, the macOS menu bar as a place ("menu bar" in "Notch Style" help is the macOS bar, which is correct), or a comment.

- [ ] **Step 4: Checkpoint** (no commit)

### Task 2: Notch glyph (option C) and removal of the old toolbar hint

**Files:**
- Create: `AgentSessions/QuotaStrip/NotchGlyph.swift` (add to target `AgentSessions`, group `AgentSessions/QuotaStrip`)
- Modify: `AgentSessions/Views/AgentCockpitHUDView.swift` (`cockpitMoveToMenuBarButton`, `showsMenuBarStripHint`, `menuBarStripHint` and its call site, `quotaMeterStripHintDismissed`)
- Modify: `AgentSessions/AgentSessionsApp.swift` (`applyQuotaMeterPlacementDefaults` hint write and doc comment)
- Modify: `AgentSessions/Views/Preferences/PreferencesConstants.swift` (delete `quotaMeterStripHintDismissed`)
- Modify: catalog + validator baseline

**Interfaces:**
- Produces: `struct NotchGlyph: View` with `init()`; renders at 15 × 11 pt in the inherited foreground style.

- [ ] **Step 1: Implement `NotchGlyph`**

Geometry in a 15 × 11 coordinate space (scale to the frame), from the owner-approved mockup:
- top edge: line from (0, 1) to (15, 1), stroke 1.2;
- notch: filled, x 4…11, y 1…4.5, bottom corners radius 1.7, square top;
- arrow: shaft (7.5, 10.2)→(7.5, 6.4); head (5.6, 8.1)→(7.5, 6.2)→(9.4, 8.1); stroke 1.2, round caps and joins.

Use `Path`/`Shape`, `.foregroundStyle(.foreground)` inheritance, no bitmap.

- [ ] **Step 2: Use it in `cockpitMoveToMenuBarButton`** in place of the `menubar.arrow.up.rectangle` image; keep `HUDIconButtonStyle(isOn: false, tint: nil)`, the tooltip and the accessibility label from Task 1. Drop the `quotaMeterStripHintDismissed = true` write.

- [ ] **Step 3: Delete the old hint** — `showsMenuBarStripHint`, `menuBarStripHint`, its call site, the `@AppStorage` for the key, the key constant, and the fresh-install write in `applyQuotaMeterPlacementDefaults` (keep the placement default logic). Remove catalog keys the validator reports as unused ("Try Quota Meter in the menu bar", and "Try It" only if reported).

- [ ] **Step 4: Build, logic tests, localization; `grep -rn quotaMeterStripHintDismissed AgentSessions AgentSessionsTests AgentSessionsLogicTests` → no hits**

- [ ] **Step 5: Checkpoint** (no commit)

### Task 3: Intro decision rule (pure, unit-tested)

**Files:**
- Create: `AgentSessions/QuotaStrip/QuotaMeterNotchIntro.swift` (add to targets `AgentSessions` and `AgentSessionsLogicTests`, group `AgentSessions/QuotaStrip`)
- Test: `AgentSessionsLogicTests/QuotaStripCoreTests.swift` (append a `QuotaMeterNotchIntroTests` class)

**Interfaces:**
- Produces:

```swift
enum NotchIntroVariant: Equatable { case moveToNotch, alreadyInNotch, turnOnTracking }

struct NotchIntroInput: Equatable {
    var alreadyShown: Bool
    var audienceReady: Bool
    var hasCodex: Bool
    var hasClaude: Bool
    var codexTracking: Bool
    var claudeTracking: Bool
    var resolvesToNotch: Bool
    var blockingSurfaceOpen: Bool      // setup window or What's New panel on screen
    var quotaMeterCardOnScreen: Bool   // the list card was chosen this launch
}

enum QuotaMeterNotchIntro {
    static let shownKey = "QuotaMeterNotchIntroShown"
    static func variant(for input: NotchIntroInput) -> NotchIntroVariant?
}
```

Rule: `nil` when `alreadyShown`, `!audienceReady`, `blockingSurfaceOpen`, `quotaMeterCardOnScreen`, or neither `hasCodex` nor `hasClaude`. Otherwise `.turnOnTracking` when every provider the user has is untracked (`(!hasCodex || !codexTracking) && (!hasClaude || !claudeTracking)`); else `.alreadyInNotch` if `resolvesToNotch`, else `.moveToNotch`.

- [ ] **Step 1: Write the failing tests** (helper `input(...)` defaults: not shown, ready, Codex only, Codex tracked, not in notch, nothing blocking, no card)

```swift
func testDesktopUserGetsMoveToNotch() { XCTAssertEqual(QuotaMeterNotchIntro.variant(for: input()), .moveToNotch) }
func testNotchUserGetsGotIt() { XCTAssertEqual(QuotaMeterNotchIntro.variant(for: input(resolvesToNotch: true)), .alreadyInNotch) }
func testTrackingOffGetsTurnOn() { XCTAssertEqual(QuotaMeterNotchIntro.variant(for: input(codexTracking: false)), .turnOnTracking) }
func testTrackingOffWinsOverNotch() { XCTAssertEqual(QuotaMeterNotchIntro.variant(for: input(codexTracking: false, resolvesToNotch: true)), .turnOnTracking) }
func testPartialTrackingIsTrackingOn() { XCTAssertEqual(QuotaMeterNotchIntro.variant(for: input(hasClaude: true, claudeTracking: false)), .moveToNotch) }
func testUntrackedProviderUserLacksIsIgnored() { XCTAssertEqual(QuotaMeterNotchIntro.variant(for: input(hasCodex: false, hasClaude: true, codexTracking: false, claudeTracking: true)), .moveToNotch) }
func testNoSessionsNeverShows() { XCTAssertNil(QuotaMeterNotchIntro.variant(for: input(hasCodex: false))) }
func testAlreadyShownNeverShows() { XCTAssertNil(QuotaMeterNotchIntro.variant(for: input(alreadyShown: true))) }
func testAudienceNotReadyDefers() { XCTAssertNil(QuotaMeterNotchIntro.variant(for: input(audienceReady: false))) }
func testBlockingSurfaceDefers() { XCTAssertNil(QuotaMeterNotchIntro.variant(for: input(blockingSurfaceOpen: true))) }
func testQuotaMeterCardOnScreenDefers() { XCTAssertNil(QuotaMeterNotchIntro.variant(for: input(quotaMeterCardOnScreen: true))) }
func testShownKeyIsStable() { XCTAssertEqual(QuotaMeterNotchIntro.shownKey, "QuotaMeterNotchIntroShown") }
```

- [ ] **Step 2: Run logic tests → FAIL** (`QuotaMeterNotchIntro` not found)
- [ ] **Step 3: Implement `QuotaMeterNotchIntro.swift`** (Foundation only, no AppKit)
- [ ] **Step 4: Run logic tests → PASS, 94 tests** (82 + 12)
- [ ] **Step 5: Checkpoint** (no commit)

### Task 4: Strip peek and "a placement change retires the intro"

**Files:**
- Modify: `AgentSessions/QuotaStrip/QuotaStripController.swift`
- Modify: `AgentSessions/QuotaStrip/QuotaMeterPresentationCoordinator.swift`

**Interfaces:**
- Consumes: `QuotaMeterNotchIntro.shownKey` (Task 3).
- Produces: `QuotaStripController.peek(duration: TimeInterval)`; `QuotaMeterPresentationCoordinator.peekStrip(duration: TimeInterval = 3, presentTimeout: TimeInterval = 2)`.

- [ ] **Step 1: `QuotaStripController.peek(duration:)`** — opens the panel with the existing open spring (`setExpanded(true)`), then after `duration` closes it the way a hover-out does, unless the pointer is inside the hit shape at that moment (then normal hover handling takes over). A no-op when not presented. Uses the existing common-mode timer helper so a tracking menu does not stall it.

- [ ] **Step 2: `QuotaMeterPresentationCoordinator.peekStrip(duration:presentTimeout:)`** — if `isStripPresented`, peek now; otherwise re-check every 0.1 s until `presentTimeout`, then give up silently (Review Focus 5).

- [ ] **Step 3: Retire the intro on a user placement change** — in `defaultsChanged()`, inside `if raw != lastPlacementRaw`, set `defaults.set(true, forKey: QuotaMeterNotchIntro.shownKey)`. (The dialog's own Move to Notch changes placement after it has already set the key, so this is harmless there.)

- [ ] **Step 4: Build, logic tests**
- [ ] **Step 5: Checkpoint** (no commit)

### Task 5: The intro dialog

**Files:**
- Create: `AgentSessions/Onboarding/Views/NotchIntroView.swift` (target `AgentSessions`, group `AgentSessions/Onboarding/Views`)
- Modify: `AgentSessions/Onboarding/Models/OnboardingCoordinator.swift`
- Modify: `AgentSessions/Onboarding/Views/OnboardingListTopSlot.swift`
- Modify: catalog + validator baseline

**Interfaces:**
- Consumes: `NotchIntroVariant`, `NotchIntroInput`, `QuotaMeterNotchIntro` (Task 3); `peekStrip()` (Task 4); `NotchGlyph` is not used here.
- Produces on `OnboardingCoordinator`: `@Published var notchIntroVariant: NotchIntroVariant?`; `func presentNotchIntro(_ variant: NotchIntroVariant)` (sets the shown key in `defaults`, sets `notchIntroVariant`, and blocks the Quota Meter card for the rest of the launch via `quotaMeterCardSuppressedThisLaunch = true`); `func dismissNotchIntro()`.
- Produces: `enum QuotaMeterActivation { @MainActor static func enableTracking(for providers: QuotaMeterProviderAvailability, defaults: UserDefaults = .standard) }` (in `OnboardingListTopSlot.swift`), extracted from `QuotaMeterPromoActivator.activate()` so both use it; it only ever switches tracking on, and only for providers the user has.

- [ ] **Step 1: `NotchIntroView(variant:onPrimary:onSecondary:)`**, a sheet laid out like `QuotaMeterPromoView` (24 pt padding, 500 pt wide):
  - **Picture** (`NotchIntroPicture`, private, drawn in SwiftUI): a menu-bar slice, the black open notch panel (bottom corners 22, `NotchShape` look) with a Codex row `5h:63% ▸2h 5m ↻ 1h 40m | Wk:54% ↻ Sun 4:59 AM`, one runway row `transcript-redesign 38m/h` with a 70 % orange bar, a hairline, and a Claude row `5h:81% · ↻ 3h 12m | Wk:72% ↻ Thu 9:00 AM`. Monospaced provider font; percents in `QuotaStripPalette.healthy`; run-out bold in the HUD projection orange; secondary grey for resets, "|" and "·". Sample values are verbatim, not localized (`Text(verbatim:)`), and the picture is `accessibilityHidden(true)`.
  - Title "Quota Meter in the notch"; body "See your live burn rate and when your quota runs out, at the top of the screen. Hover to open it; click for the menu."
  - Buttons by variant (primary is `.keyboardShortcut(.defaultAction)`, secondary `.cancelAction`): `.moveToNotch` → "Move to Notch" · "Keep on Desktop"; `.alreadyInNotch` → "Got It" only (also `.cancelAction`); `.turnOnTracking` → "Turn On" · "Not Now".

- [ ] **Step 2: Coordinator state** — add the Interfaces members. `shouldShowQuotaMeterCard` already honours `quotaMeterCardSuppressedThisLaunch`.

- [ ] **Step 3: Trigger in `OnboardingListTopSlot`** — `evaluateNotchIntro()` builds `NotchIntroInput` from `UserDefaults.standard.bool(forKey: QuotaMeterNotchIntro.shownKey)`, `audienceReady`, `providers`, the two `@AppStorage` tracking flags, `QuotaMeterPresentationCoordinator.shared.resolvesToStrip()`, `coordinator.presentation != nil || coordinator.isWhatsNewPanelPresented`, and `selectedCard == .quotaMeter`; when it returns a variant, call `presentNotchIntro`. Call it in `.onAppear`, `.onChange(of: audienceReady)`, `.onChange(of: coordinator.presentation)` and `.onChange(of: coordinator.isWhatsNewPanelPresented)`, and **before** `chooseTopSlotCardIfNeeded()` in each, so a dialog shown at audience-ready keeps the card out (Review Focus 3).

- [ ] **Step 4: Sheet + actions** — in `onboardingSheets(...)` add a sheet bound to `coordinator.notchIntroVariant != nil`:
  - Move to Notch: `UserDefaults.standard.set(QuotaMeterPlacement.menuBar.rawValue, forKey: PreferencesKey.quotaMeterPlacement)`, `coordinator.recordQuotaMeterActivated()`, `coordinator.noteCockpitOpened()`, dismiss, then `QuotaMeterPresentationCoordinator.shared.peekStrip()`.
  - Turn On: `QuotaMeterActivation.enableTracking(for: providers)`, then the same as Move to Notch.
  - Got It / Keep on Desktop / Not Now / Escape: `dismissNotchIntro()` only.

- [ ] **Step 5: Catalog** — add en + zh-Hans for: "Quota Meter in the notch" (刘海中的额度监视器), the body (在屏幕顶部查看实时消耗速度以及额度何时用完。悬停可展开；点击可打开菜单。), "Move to Notch" (移至刘海), "Keep on Desktop" (留在桌面), "Got It" (知道了), "Turn On" (开启), "Not Now" (以后再说). These are new keys: the catalog has only a lowercase "Not now", and these buttons use title case like the other dialog buttons. Update the validator baseline.

- [ ] **Step 6: Build, logic tests, localization**
- [ ] **Step 7: Checkpoint** (no commit)

### Task 6: Whole-feature verification and owner QA hand-off

- [ ] **Step 1: Run all three verification commands** → build succeeded, 94 logic tests pass, localization valid and its unittest OK.
- [ ] **Step 2: Fresh-reviewer pass** on the whole uncommitted diff (spec + this plan as context), most capable model; fix confirmed findings.
- [ ] **Step 3: Prepare the QA state and relaunch** — `defaults delete com.triada.AgentSessions QuotaMeterNotchIntroShown`, then `killall AgentSessions; open .deriveddata-run/Build/Products/Debug/AgentSessions.app`. The owner checks: the dialog appears once; each variant's buttons (switch Settings placement to Desktop first, and tracking off for the Turn On variant); the 3 s peek after Move to Notch; the glyph; "Notch" copy in Settings, View menu, toolbar and click menu. No computer-use QA.
- [ ] **Step 4: Report and stop.** The owner decides on commit and push.
