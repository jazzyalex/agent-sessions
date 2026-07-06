# QM Hover Stability + Runway Click-to-Switch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Quota Meter window stop moving under the cursor on hover (content-anchored resize), replace the Meter popover with an inline Full/Compact/Meter segmented selector, and make Claude runway rows clickable (focus live iTerm2 tab, or open the exact session in Claude Desktop via `claude://resume?session=`).

**Architecture:** Three independent parts sharing two files. Part 1 extracts pure frame math into `HUDLimitsFrameMath` and rewires `applyLimitsDefaultSize` in `AgentCockpitHUDWindow.swift` to anchor the resting meter rows (top edge absorbs toolbar reveal, bottom edge absorbs everything else, screen-edge clamps per spec F1). Part 2 is a view swap in `AgentCockpitHUDView.swift`. Part 3 adds a `ClaudeRunwaySwitchTarget` resolver (pure, testable) and wires click/hover handling into `HUDRunwayPanel`, plumbed from the two places that own `activeRows`.

**Tech Stack:** Swift / SwiftUI / AppKit, XCTest (target `AgentSessionsTests`), `scripts/xcode_add_file.rb` for new files.

**Spec:** `docs/superpowers/specs/2026-07-06-quota-meter-hover-stability-and-runway-switch-design.md`

## Global Constraints

- **Commits:** Conventional Commits with `Tool:`/`Model:`/`Why:` trailers only — NO "Generated with Claude Code" footer, NO Claude co-author. Owner must have authorized committing for this execution session; otherwise stop at each commit step and report "ready to commit".
- **New Swift files** must be registered with `ruby scripts/xcode_add_file.rb AgentSessions.xcodeproj <TARGET> <path> <group>` (targets: `AgentSessions` for app code, `AgentSessionsTests` for tests). Beware: running it twice for the same file creates duplicate references — check `git diff AgentSessions.xcodeproj/project.pbxproj` after each run.
- **Build command:** `xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug build`
- **Test command:** `xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "$PWD/.deriveddata-tests" -parallel-testing-enabled NO test -only-testing:<TestClass>` (never `open` an app bundle from `.deriveddata-tests`).
- **No UI automation / computer-use.** Owner does visual QA at feature-complete (Task 6 checklist).
- All line numbers below are as of commit `03e40964`; re-anchor by searching for the quoted code if they have drifted.

---

### Task 1: `HUDLimitsFrameMath` — pure anchored-frame math + tests

**Files:**
- Create: `AgentSessions/Views/HUDLimitsFrameMath.swift`
- Test: `AgentSessionsTests/HUDLimitsFrameMathTests.swift`
- Modify: `AgentSessions.xcodeproj/project.pbxproj` (via `xcode_add_file.rb` only)

**Interfaces:**
- Consumes: nothing (pure Foundation).
- Produces: `HUDLimitsFrameMath.anchoredFrame(current: NSRect, targetHeight: CGFloat, topDelta: CGFloat, visibleFrame: NSRect?) -> NSRect` — Task 2 calls this from `applyLimitsDefaultSize`.

- [ ] **Step 1: Write the failing test**

Create `AgentSessionsTests/HUDLimitsFrameMathTests.swift`:

```swift
import XCTest
@testable import AgentSessions

final class HUDLimitsFrameMathTests: XCTestCase {
    // Screen visible area: y 0...800 (menu bar already excluded by AppKit).
    private let visible = NSRect(x: 0, y: 0, width: 1600, height: 800)

    func testToolbarRevealGrowsTopEdgeOnly() {
        // Mid-screen window, toolbar (45pt) reveals, no other content change.
        let current = NSRect(x: 100, y: 300, width: 380, height: 200)
        let result = HUDLimitsFrameMath.anchoredFrame(
            current: current, targetHeight: 245, topDelta: 45, visibleFrame: visible)
        // Top edge rises by 45; bottom edge (rows) stays fixed.
        XCTAssertEqual(result.maxY, 545, accuracy: 0.5)
        XCTAssertEqual(result.minY, 300, accuracy: 0.5)
        XCTAssertEqual(result.origin.x, 100)
        XCTAssertEqual(result.width, 380)
    }

    func testBottomContentGrowsBottomEdgeOnly() {
        // Credits line / runway rows appear below the anchor: topDelta 0.
        let current = NSRect(x: 100, y: 300, width: 380, height: 200)
        let result = HUDLimitsFrameMath.anchoredFrame(
            current: current, targetHeight: 260, topDelta: 0, visibleFrame: visible)
        XCTAssertEqual(result.maxY, 500, accuracy: 0.5) // top fixed
        XCTAssertEqual(result.minY, 240, accuracy: 0.5) // bottom grew down 60
    }

    func testCombinedToolbarAndBottomGrowth() {
        // Hover reveals toolbar (45) AND credits line (15) at once.
        let current = NSRect(x: 100, y: 300, width: 380, height: 200)
        let result = HUDLimitsFrameMath.anchoredFrame(
            current: current, targetHeight: 260, topDelta: 45, visibleFrame: visible)
        XCTAssertEqual(result.maxY, 545, accuracy: 0.5) // +45 toolbar
        XCTAssertEqual(result.minY, 285, accuracy: 0.5) // −15 credits
    }

    func testTopEdgeClampF1() {
        // Window flush near the top: only 10pt of headroom for a 45pt toolbar.
        // Top takes the 10 it can; the remaining 35 spills to the bottom (rows nudge down).
        let current = NSRect(x: 100, y: 590, width: 380, height: 200) // maxY 790
        let result = HUDLimitsFrameMath.anchoredFrame(
            current: current, targetHeight: 245, topDelta: 45, visibleFrame: visible)
        XCTAssertEqual(result.maxY, 800, accuracy: 0.5) // clamped at screen top
        XCTAssertEqual(result.minY, 555, accuracy: 0.5) // 800 − 245
    }

    func testBottomEdgeClampLiftsWindow() {
        // Window flush at the bottom: bottom growth has no room, window lifts.
        let current = NSRect(x: 100, y: 10, width: 380, height: 200)
        let result = HUDLimitsFrameMath.anchoredFrame(
            current: current, targetHeight: 260, topDelta: 0, visibleFrame: visible)
        XCTAssertEqual(result.minY, 0, accuracy: 0.5)   // pinned to screen bottom
        XCTAssertEqual(result.maxY, 260, accuracy: 0.5)
    }

    func testShrinkOnUnhoverReverses() {
        // Toolbar hides (topDelta −45), credits line goes away too.
        let current = NSRect(x: 100, y: 285, width: 380, height: 260)
        let result = HUDLimitsFrameMath.anchoredFrame(
            current: current, targetHeight: 200, topDelta: -45, visibleFrame: visible)
        XCTAssertEqual(result.maxY, 500, accuracy: 0.5) // 545 − 45
        XCTAssertEqual(result.minY, 300, accuracy: 0.5) // rows back where they rested
    }

    func testTallerThanScreenPinsTopAndSpillsBelow() {
        let current = NSRect(x: 100, y: 100, width: 380, height: 600)
        let result = HUDLimitsFrameMath.anchoredFrame(
            current: current, targetHeight: 900, topDelta: 45, visibleFrame: visible)
        XCTAssertEqual(result.maxY, 800, accuracy: 0.5)
        XCTAssertEqual(result.height, 900, accuracy: 0.5) // never shrinks content
    }

    func testNilVisibleFrameSkipsClamps() {
        let current = NSRect(x: 100, y: 700, width: 380, height: 200)
        let result = HUDLimitsFrameMath.anchoredFrame(
            current: current, targetHeight: 245, topDelta: 45, visibleFrame: nil)
        XCTAssertEqual(result.maxY, 945, accuracy: 0.5) // unclamped
        XCTAssertEqual(result.minY, 700, accuracy: 0.5)
    }
}
```

- [ ] **Step 2: Register the test file, run to verify it fails to compile**

```bash
ruby scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessionsTests AgentSessionsTests/HUDLimitsFrameMathTests.swift AgentSessionsTests
git diff --stat AgentSessions.xcodeproj/project.pbxproj   # expect exactly one file's worth of additions
xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "$PWD/.deriveddata-tests" -parallel-testing-enabled NO test -only-testing:AgentSessionsTests/HUDLimitsFrameMathTests
```

Expected: BUILD FAILS — `cannot find 'HUDLimitsFrameMath' in scope`.

- [ ] **Step 3: Write the implementation**

Create `AgentSessions/Views/HUDLimitsFrameMath.swift`:

```swift
import Foundation

/// Content-anchored frame math for the Quota Meter (limits) window.
///
/// The resting meter rows stay screen-fixed during hover expansion: the top
/// edge absorbs chrome revealed above them (the toolbar + its divider) via
/// `topDelta`, and the bottom edge absorbs everything else (credits line,
/// runway drawer rows). Screen-edge behavior (spec F1): when the top edge
/// hits the visible area's top, remaining top growth spills to the bottom
/// (rows nudge down once); when the bottom edge hits the visible area's
/// bottom, the window lifts. Height is never shrunk to fit — a
/// taller-than-screen window pins its top and spills below.
enum HUDLimitsFrameMath {
    /// - Parameters:
    ///   - current: window frame before the resize (screen coordinates)
    ///   - targetHeight: desired total window height after the resize
    ///   - topDelta: height of chrome being revealed (+) or hidden (−) above
    ///     the anchored content; 0 when the toolbar state is unchanged
    ///   - visibleFrame: the screen's visible frame, or nil to skip clamping
    static func anchoredFrame(current: NSRect,
                              targetHeight: CGFloat,
                              topDelta: CGFloat,
                              visibleFrame: NSRect?) -> NSRect {
        var newMaxY = current.maxY + topDelta
        if let visible = visibleFrame {
            newMaxY = min(newMaxY, visible.maxY)
            if newMaxY - targetHeight < visible.minY {
                // Bottom would underflow: lift the window so the bottom edge
                // sits on the screen bottom, but never past the screen top.
                newMaxY = min(visible.minY + targetHeight, visible.maxY)
            }
        }
        return NSRect(x: current.origin.x,
                      y: newMaxY - targetHeight,
                      width: current.width,
                      height: targetHeight)
    }
}
```

Register it:

```bash
ruby scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessions AgentSessions/Views/HUDLimitsFrameMath.swift AgentSessions/Views
git diff --stat AgentSessions.xcodeproj/project.pbxproj
```

- [ ] **Step 4: Run the tests, verify they pass**

Same test command as Step 2. Expected: `Test Suite 'HUDLimitsFrameMathTests' passed`, 8/8.

- [ ] **Step 5: Commit**

```bash
git add AgentSessions/Views/HUDLimitsFrameMath.swift AgentSessionsTests/HUDLimitsFrameMathTests.swift AgentSessions.xcodeproj/project.pbxproj
git commit -m "feat(qm): add content-anchored frame math for the Quota Meter window

Tool: Claude Code
Model: claude-fable-5
Why: hover reveals must grow the window at the edges instead of moving the rows under the cursor (spec 2026-07-06)"
```

---

### Task 2: Wire anchored resize into the QM window

**Files:**
- Modify: `AgentSessions/Views/AgentCockpitHUDWindow.swift` (Coordinator: `applyStyle` ~line 267, `applyModeTransition` ~line 468, `applyLimitsDefaultSize` ~line 669, delete `shouldGrowLimitsWindowDown` ~line 708)

**Interfaces:**
- Consumes: `HUDLimitsFrameMath.anchoredFrame(current:targetHeight:topDelta:visibleFrame:)` from Task 1.
- Produces: `applyLimitsDefaultSize(to:contentHeight:activeEnabled:includesToolbar:appliesDefaultWidth:animated:toolbarDelta:)` — internal to the Coordinator; no other task depends on it.

- [ ] **Step 1: Add the toolbar-height constant**

In the Coordinator's constants block (next to `private let compactHeaderHeight: CGFloat = 44.5`, ~line 140), add:

```swift
        /// Height the toolbar contributes in limits mode (header + 0.5pt divider),
        /// mirroring the `includesToolbar` term in `limitsWindowHeight`.
        private var limitsToolbarHeight: CGFloat { compactHeaderHeight + 0.5 }
```

- [ ] **Step 2: Replace `applyLimitsDefaultSize` body**

Replace the whole function (currently ~lines 669–706) with:

```swift
        private func applyLimitsDefaultSize(to window: NSWindow,
                                            contentHeight: CGFloat,
                                            activeEnabled: Bool,
                                            includesToolbar: Bool,
                                            appliesDefaultWidth: Bool,
                                            animated: Bool,
                                            toolbarDelta: CGFloat) {
            // Clamp to maxSize.width so the window snaps to the hugged content width
            // even when its saved/previous frame was wider than the content.
            let unclampedWidth = appliesDefaultWidth
                ? max(window.minSize.width, limitsDefaultFrameWidth)
                : max(window.minSize.width, window.frame.width)
            let targetWidth = min(window.maxSize.width, unclampedWidth)
            let targetHeight = max(
                window.minSize.height,
                self.limitsWindowHeight(
                    for: window,
                    contentHeight: contentHeight,
                    includesDisabledCallout: !activeEnabled,
                    includesToolbar: includesToolbar
                )
            )

            var frame = window.frame
            guard abs(frame.width - targetWidth) > 1 || abs(frame.height - targetHeight) > 1 else {
                return
            }
            frame.size.width = targetWidth
            // Content-anchored growth: the resting rows stay screen-fixed. The
            // toolbar reveal/hide moves the top edge; everything else (credits
            // line, drawer rows) moves the bottom edge. Screen-edge clamps per
            // spec F1 live in HUDLimitsFrameMath.
            let anchored = HUDLimitsFrameMath.anchoredFrame(
                current: frame,
                targetHeight: targetHeight,
                topDelta: toolbarDelta,
                visibleFrame: window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
            )
            // Animate only when the toolbar is toggling, so the window resize
            // moves with the toolbar reveal/hide instead of snapping. Other
            // limits resizes (content height changes) stay instant.
            setWindowFrame(anchored, display: true, animate: animated)
        }
```

- [ ] **Step 3: Delete `shouldGrowLimitsWindowDown`**

Remove the entire function (currently ~lines 708–720). It has no other callers (verify: `grep -n shouldGrowLimitsWindowDown AgentSessions/Views/AgentCockpitHUDWindow.swift` → no hits after removal).

- [ ] **Step 4: Update the two call sites**

In `applyStyle` (~lines 267–275), replace:

```swift
                if isLimitsOnly {
                    applyLimitsDefaultSize(
                        to: window,
                        contentHeight: limitsContentHeight,
                        activeEnabled: activeEnabled,
                        includesToolbar: compactToolbarVisible,
                        appliesDefaultWidth: false,
                        animated: previousCompactToolbarVisibility != compactToolbarVisible
                    )
                }
```

with:

```swift
                if isLimitsOnly {
                    let toolbarToggled = previousCompactToolbarVisibility != nil
                        && previousCompactToolbarVisibility != compactToolbarVisible
                    applyLimitsDefaultSize(
                        to: window,
                        contentHeight: limitsContentHeight,
                        activeEnabled: activeEnabled,
                        includesToolbar: compactToolbarVisible,
                        appliesDefaultWidth: false,
                        animated: toolbarToggled,
                        toolbarDelta: toolbarToggled
                            ? (compactToolbarVisible ? limitsToolbarHeight : -limitsToolbarHeight)
                            : 0
                    )
                }
```

In `applyModeTransition`'s `case .limits:` (~line 468), add `toolbarDelta: 0` to the call (mode-entry default sizing has no anchored content yet):

```swift
                case .limits:
                    self.applyLimitsDefaultSize(
                        to: window,
                        contentHeight: limitsContentHeight,
                        activeEnabled: activeEnabled,
                        includesToolbar: compactToolbarVisible,
                        appliesDefaultWidth: true,
                        animated: false,
                        toolbarDelta: 0
                    )
```

- [ ] **Step 5: Build and run the full window-adjacent tests**

```bash
xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug build
xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "$PWD/.deriveddata-tests" -parallel-testing-enabled NO test -only-testing:AgentSessionsTests/HUDLimitsFrameMathTests
```

Expected: BUILD SUCCEEDED; math tests still pass. (Visual behavior verified by owner in Task 6.)

- [ ] **Step 6: Commit**

```bash
git add AgentSessions/Views/AgentCockpitHUDWindow.swift
git commit -m "fix(qm): anchor meter rows during hover resize instead of picking a grow direction

Tool: Claude Code
Model: claude-fable-5
Why: room-preference direction flip-flopped and moved rows under the cursor, making QM elements unclickable"
```

---

### Task 3: Inline Full/Compact/Meter segmented selector

**Files:**
- Modify: `AgentSessions/Views/AgentCockpitHUDView.swift` (`cockpitModePicker` ~line 1357, `@State showModePopover` ~line 811-ish, `HUDCockpitModePopover` struct ~line 4297)

**Interfaces:**
- Consumes: existing `hudDisplayModeRaw` AppStorage, `setHUDDisplayMode(_:)` (~line 1191), `AgentCockpitHUDDisplayMode.shortLabel`.
- Produces: nothing new (view-internal).

- [ ] **Step 1: Replace `cockpitModePicker`**

Replace the whole `private var cockpitModePicker` (Button + popover, ~lines 1357–1384) with:

```swift
    private var cockpitModePicker: some View {
        Picker("Cockpit view", selection: Binding(
            get: { AgentCockpitHUDDisplayMode(rawValue: hudDisplayModeRaw) ?? .full },
            set: { mode in
                withAnimation(.easeInOut(duration: 0.18)) {
                    setHUDDisplayMode(mode)
                }
            }
        )) {
            ForEach(AgentCockpitHUDDisplayMode.allCases) { mode in
                Text(mode.shortLabel).tag(mode)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .controlSize(.small)
        .fixedSize()
        .help("Switch Agent Cockpit view: Full, Compact, or Quota Meter.")
    }
```

- [ ] **Step 2: Remove the dead popover pieces**

- Delete `@State private var showModePopover = false` (search for it; it must have no remaining references).
- Delete the whole `private struct HUDCockpitModePopover: View { ... }` (~lines 4297–4343).
- Verify: `grep -n "showModePopover\|HUDCockpitModePopover" AgentSessions/Views/AgentCockpitHUDView.swift` → no hits.

- [ ] **Step 3: Build**

```bash
xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug build
```

Expected: BUILD SUCCEEDED. Note: the QM toolbar uses `ViewThatFits` fallbacks (~lines 1256–1296) that each include `cockpitModePicker`; the wider segmented control simply promotes narrower fallbacks — no code change needed there.

- [ ] **Step 4: Commit**

```bash
git add AgentSessions/Views/AgentCockpitHUDView.swift
git commit -m "feat(cockpit): replace mode popover with inline Full/Compact/Meter segmented selector

Tool: Claude Code
Model: claude-fable-5
Why: the popover was dismissed/displaced by QM hover resizes, making the cockpit view unreachable from Meter mode"
```

---

### Task 4: `ClaudeRunwaySwitchTarget` resolver + tests

**Files:**
- Create: `AgentSessions/ClaudeStatus/ClaudeRunwaySwitchTarget.swift`
- Test: `AgentSessionsTests/ClaudeRunwaySwitchTargetTests.swift`
- Modify: `AgentSessions.xcodeproj/project.pbxproj` (via `xcode_add_file.rb` only)

**Interfaces:**
- Consumes: `HUDRow` (AgentCockpitHUDView.swift:71 — fields `source`, `itermSessionId`, `tty`, `resolvedSessionID`, `runtimeSessionID`, `id`), `ClaudeDesktopSidecarRecord` (ClaudeDesktopSessionTitles.swift).
- Produces (Task 5 depends on these exact names):
  - `struct ClaudeRunwaySwitchTarget: Equatable { var itermSessionId: String?; var tty: String?; var desktopSessionID: String?; var hasTerminal: Bool; var isEmpty: Bool }`
  - `ClaudeRunwaySwitchTargetResolver.targets(rowIDs: [String], activeRows: [HUDRow], desktopRecords: [String: ClaudeDesktopSidecarRecord]) -> [String: ClaudeRunwaySwitchTarget]`
  - `ClaudeDesktopDeepLink.resumeURL(sessionID: String) -> URL?`

- [ ] **Step 1: Write the failing tests**

Create `AgentSessionsTests/ClaudeRunwaySwitchTargetTests.swift`:

```swift
import XCTest
@testable import AgentSessions

final class ClaudeRunwaySwitchTargetTests: XCTestCase {
    private func makeRow(id: String,
                         source: SessionSource = .claude,
                         itermSessionId: String? = nil,
                         tty: String? = nil,
                         resolvedSessionID: String? = nil) -> HUDRow {
        HUDRow(id: id,
               source: source,
               agentType: source == .claude ? .claude : .codex,
               projectName: "proj",
               displayName: "row",
               liveState: .active,
               preview: "",
               elapsed: "",
               lastSeenAt: nil,
               itermSessionId: itermSessionId,
               revealURL: nil,
               tty: tty,
               termProgram: nil,
               resolvedSessionID: resolvedSessionID)
    }

    private func makeSidecar(cliSessionID: String, isArchived: Bool = false) -> ClaudeDesktopSidecarRecord {
        ClaudeDesktopSidecarRecord(cliSessionID: cliSessionID,
                                   title: "Some title",
                                   isArchived: isArchived,
                                   autoArchiveExempt: false,
                                   sidecarPath: "/tmp/local_x.json",
                                   modifiedAt: Date(timeIntervalSince1970: 1))
    }

    func testLiveTerminalRowResolvesToITerm() {
        let targets = ClaudeRunwaySwitchTargetResolver.targets(
            rowIDs: ["s1"],
            activeRows: [makeRow(id: "s1", itermSessionId: "w0t0p0:GUID", tty: "/dev/ttys001")],
            desktopRecords: [:])
        XCTAssertEqual(targets["s1"]?.itermSessionId, "w0t0p0:GUID")
        XCTAssertEqual(targets["s1"]?.tty, "/dev/ttys001")
        XCTAssertNil(targets["s1"]?.desktopSessionID)
        XCTAssertEqual(targets["s1"]?.hasTerminal, true)
    }

    func testResolvedSessionIDMatchesWhenRowIDDiffers() {
        // Runway identity ids are ROOT session UUIDs; the HUD row id can be a
        // registry key while resolvedSessionID carries the transcript UUID.
        let row = makeRow(id: "registry-key", itermSessionId: "GUID", resolvedSessionID: "s2")
        let targets = ClaudeRunwaySwitchTargetResolver.targets(
            rowIDs: ["s2"], activeRows: [row], desktopRecords: [:])
        XCTAssertEqual(targets["s2"]?.itermSessionId, "GUID")
    }

    func testDesktopOnlySessionResolvesToDeepLink() {
        let targets = ClaudeRunwaySwitchTargetResolver.targets(
            rowIDs: ["s3"],
            activeRows: [],
            desktopRecords: ["s3": makeSidecar(cliSessionID: "s3")])
        XCTAssertEqual(targets["s3"]?.desktopSessionID, "s3")
        XCTAssertEqual(targets["s3"]?.hasTerminal, false)
    }

    func testTerminalWinsButDesktopKeptAsFallback() {
        let targets = ClaudeRunwaySwitchTargetResolver.targets(
            rowIDs: ["s4"],
            activeRows: [makeRow(id: "s4", tty: "/dev/ttys002")],
            desktopRecords: ["s4": makeSidecar(cliSessionID: "s4")])
        XCTAssertEqual(targets["s4"]?.hasTerminal, true)
        XCTAssertEqual(targets["s4"]?.desktopSessionID, "s4") // fallback preserved
    }

    func testArchivedSidecarIsIgnored() {
        let targets = ClaudeRunwaySwitchTargetResolver.targets(
            rowIDs: ["s5"],
            activeRows: [],
            desktopRecords: ["s5": makeSidecar(cliSessionID: "s5", isArchived: true)])
        XCTAssertNil(targets["s5"])
    }

    func testCodexRowsAndTerminallessRowsDoNotResolve() {
        let codexRow = makeRow(id: "s6", source: .codex, itermSessionId: "GUID")
        let bareRow = makeRow(id: "s7") // Claude, but no iTerm GUID and no tty
        let targets = ClaudeRunwaySwitchTargetResolver.targets(
            rowIDs: ["s6", "s7"], activeRows: [codexRow, bareRow], desktopRecords: [:])
        XCTAssertTrue(targets.isEmpty)
    }

    func testResumeDeepLinkURL() {
        let url = ClaudeDesktopDeepLink.resumeURL(sessionID: "abc-123")
        XCTAssertEqual(url?.absoluteString, "claude://resume?session=abc-123")
    }
}
```

- [ ] **Step 2: Register the test file, run to verify failure**

```bash
ruby scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessionsTests AgentSessionsTests/ClaudeRunwaySwitchTargetTests.swift AgentSessionsTests
git diff --stat AgentSessions.xcodeproj/project.pbxproj
xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "$PWD/.deriveddata-tests" -parallel-testing-enabled NO test -only-testing:AgentSessionsTests/ClaudeRunwaySwitchTargetTests
```

Expected: BUILD FAILS — `cannot find 'ClaudeRunwaySwitchTargetResolver' in scope`.

- [ ] **Step 3: Write the implementation**

Create `AgentSessions/ClaudeStatus/ClaudeRunwaySwitchTarget.swift`:

```swift
import Foundation

/// Where a click on a Claude runway row should take the user.
///
/// Terminal fields and the Desktop session id can both be set: a live CLI
/// session that also has a Desktop sidecar focuses its iTerm2 tab first and
/// falls back to the `claude://resume` deep link if the tab is gone.
struct ClaudeRunwaySwitchTarget: Equatable {
    var itermSessionId: String?
    var tty: String?
    var desktopSessionID: String?

    var hasTerminal: Bool {
        !(itermSessionId ?? "").isEmpty || !(tty ?? "").isEmpty
    }

    var isEmpty: Bool { !hasTerminal && desktopSessionID == nil }
}

enum ClaudeDesktopDeepLink {
    /// Claude Desktop registers the `claude` URL scheme and handles
    /// `claude://resume?session=<cli-session-uuid>` by importing/opening that
    /// exact CLI session (verified against Claude.app 1.18286.0).
    static func resumeURL(sessionID: String) -> URL? {
        var components = URLComponents()
        components.scheme = "claude"
        components.host = "resume"
        components.queryItems = [URLQueryItem(name: "session", value: sessionID)]
        return components.url
    }
}

enum ClaudeRunwaySwitchTargetResolver {
    /// Maps runway row ids (root CLI session UUIDs) to switch targets.
    /// Rows that resolve to neither a live terminal nor an unarchived Desktop
    /// sidecar are absent from the result — the UI renders them inert.
    static func targets(rowIDs: [String],
                        activeRows: [HUDRow],
                        desktopRecords: [String: ClaudeDesktopSidecarRecord]) -> [String: ClaudeRunwaySwitchTarget] {
        var terminalBySessionID: [String: (itermSessionId: String?, tty: String?)] = [:]
        for row in activeRows where row.source == .claude {
            let hasTerminal = !(row.itermSessionId ?? "").isEmpty || !(row.tty ?? "").isEmpty
            guard hasTerminal else { continue }
            let sessionID = row.resolvedSessionID ?? row.runtimeSessionID ?? row.id
            if terminalBySessionID[sessionID] == nil {
                terminalBySessionID[sessionID] = (row.itermSessionId, row.tty)
            }
        }

        var out: [String: ClaudeRunwaySwitchTarget] = [:]
        for rowID in rowIDs {
            var target = ClaudeRunwaySwitchTarget()
            if let terminal = terminalBySessionID[rowID] {
                target.itermSessionId = terminal.itermSessionId
                target.tty = terminal.tty
            }
            if let record = desktopRecords[rowID], !record.isArchived {
                target.desktopSessionID = rowID
            }
            if !target.isEmpty {
                out[rowID] = target
            }
        }
        return out
    }
}
```

Register it:

```bash
ruby scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessions AgentSessions/ClaudeStatus/ClaudeRunwaySwitchTarget.swift AgentSessions/ClaudeStatus
git diff --stat AgentSessions.xcodeproj/project.pbxproj
```

- [ ] **Step 4: Run tests, verify pass**

Same command as Step 2. Expected: `Test Suite 'ClaudeRunwaySwitchTargetTests' passed`, 7/7.

- [ ] **Step 5: Commit**

```bash
git add AgentSessions/ClaudeStatus/ClaudeRunwaySwitchTarget.swift AgentSessionsTests/ClaudeRunwaySwitchTargetTests.swift AgentSessions.xcodeproj/project.pbxproj
git commit -m "feat(runway): resolve Claude runway rows to iTerm2 focus or Desktop deep-link targets

Tool: Claude Code
Model: claude-fable-5
Why: groundwork for click-to-switch on runway rows (spec 2026-07-06)"
```

---

### Task 5: Clickable Claude runway rows

**Files:**
- Modify: `AgentSessions/Views/AgentCockpitHUDView.swift`:
  - `HUDRunwayPanel` (struct ~line 4490, `runwayRow` ~line 4563)
  - QM panel `runwayBlock` (~line 4156, inside the `HUDLimitsRowsPanel`-style struct that owns `activeRows` and `visibleRunwaySnapshot(for:)`)
  - `HUDLimitsBar.expandedPanel` (~line 3905) and `HUDLimitsExpandedPanel` (~line 4235)
  - `HUDLimitsDetailPanel` (~line 4345, runway usage ~line 4409)

**Interfaces:**
- Consumes (from Task 4): `ClaudeRunwaySwitchTarget` (fields `itermSessionId`, `tty`, `desktopSessionID`, `hasTerminal`), `ClaudeRunwaySwitchTargetResolver.targets(rowIDs:activeRows:desktopRecords:)`, `ClaudeDesktopDeepLink.resumeURL(sessionID:)`. Also existing `CodexActiveSessionsModel.tryFocusITerm2(itermSessionId:tty:) -> Bool` (CodexActiveSessionsModel.swift:1735) and `ClaudeDesktopSessionTitles.records()`.
- Produces: `HUDRunwayPanel` gains `var switchTargets: [String: ClaudeRunwaySwitchTarget] = [:]`; `HUDLimitsExpandedPanel` and `HUDLimitsDetailPanel` gain `var claudeSwitchTargets: [String: ClaudeRunwaySwitchTarget] = [:]`. All defaulted so Codex call sites stay unchanged.

- [ ] **Step 1: Extend `HUDRunwayPanel` with targets, hover state, and click handling**

Add to `HUDRunwayPanel`'s properties (next to `let snapshot` / `let now` / `agentLabel`):

```swift
    /// Row id → switch target. Empty for agents without click-to-switch (Codex).
    var switchTargets: [String: ClaudeRunwaySwitchTarget] = [:]
    @State private var hoveredRowID: String?
```

Replace `runwayRow(_:index:)` (~lines 4563–4583) with:

```swift
    private func runwayRow(_ row: RunwayPauseImpactRow, index: Int) -> some View {
        let target = switchTargets[row.id]
        let isHoveredTarget = target != nil && hoveredRowID == row.id
        return GeometryReader { proxy in
            let titleWidth = HUDRunwayLayout.titleWidth(for: proxy.size.width)
            HStack(spacing: HUDRunwayLayout.columnSpacing) {
                Text(sessionLabel(row))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: titleWidth, alignment: .leading)
                rateCell(quota: row.quotaMinutesPerHour, confidence: row.confidence)
                    .frame(width: HUDRunwayLayout.rateWidth, alignment: .trailing)
                HUDRunwayLoadBar(
                    quotaMinutesPerHour: row.quotaMinutesPerHour,
                    maxQuotaMinutesPerHour: maxQuotaMinutesPerHour,
                    confidence: row.confidence,
                    animationTick: animationTick,
                    index: index
                )
            }
            // Destination glyph floats over the trailing edge so the row's
            // layout never shifts on hover (the point of this whole feature).
            .overlay(alignment: .trailing) {
                if isHoveredTarget, let target {
                    Image(systemName: target.hasTerminal ? "terminal" : "arrow.up.forward.app")
                        .font(.system(size: runwayFontSize))
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 1)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(height: runwayRowHeight)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color.primary.opacity(isHoveredTarget ? 0.07 : 0))
                .padding(.horizontal, -4)
        )
        .onHover { hovering in
            hoveredRowID = hovering ? row.id : (hoveredRowID == row.id ? nil : hoveredRowID)
            guard target != nil else { return }
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .onTapGesture {
            guard let target else { return }
            activate(target)
        }
        .help(target.map { $0.hasTerminal ? "Switch to the iTerm2 tab for this session." : "Open this session in Claude Desktop." } ?? "")
    }

    private func activate(_ target: ClaudeRunwaySwitchTarget) {
        if target.hasTerminal,
           CodexActiveSessionsModel.tryFocusITerm2(itermSessionId: target.itermSessionId, tty: target.tty) {
            return
        }
        // Terminal gone (or never existed): fall back to the Desktop deep link.
        if let sessionID = target.desktopSessionID,
           let url = ClaudeDesktopDeepLink.resumeURL(sessionID: sessionID) {
            NSWorkspace.shared.open(url)
        }
    }
```

Note: the summary row (`+N sessions`) is untouched — aggregated rows are never clickable.

- [ ] **Step 2: Plumb targets in the QM window panel**

In the struct that owns the QM content (the one with `let activeRows: [HUDRow]`, `visibleRunwaySnapshot(for:)` at ~line 4026, and `runwayBlock` at ~line 4156), add:

```swift
    private var claudeSwitchTargets: [String: ClaudeRunwaySwitchTarget] {
        guard let rows = visibleRunwaySnapshot(for: .claude)?.rows, !rows.isEmpty else { return [:] }
        return ClaudeRunwaySwitchTargetResolver.targets(
            rowIDs: rows.map(\.id),
            activeRows: activeRows,
            desktopRecords: ClaudeDesktopSessionTitles.records()
        )
    }
```

and change `runwayBlock` (~line 4156) to pass them:

```swift
    @ViewBuilder
    private func runwayBlock(for source: UsageTrackingSource) -> some View {
        // The runway panels draw their own faint top rule (the within-agent
        // QM ↔ runway separator), so no extra divider is added here.
        if let snapshot = visibleRunwaySnapshot(for: source) {
            HUDRunwayPanel(
                snapshot: snapshot,
                now: clockNow,
                agentLabel: source == .claude ? "Claude" : "Codex",
                switchTargets: source == .claude ? claudeSwitchTargets : [:]
            )
        } else if runwayVisibility == .alwaysOn {
            HUDRunwayEmptyPanel(agentLabel: source == .claude ? "Claude" : "Codex")
        }
    }
```

- [ ] **Step 3: Plumb targets through the expanded (hover) panel path**

`HUDLimitsBar` owns `activeRows` and builds `expandedPanel` (~line 3905). Add the same `claudeSwitchTargets` computed property to `HUDLimitsBar` (using `visibleClaudeRunwaySnapshot?.rows` as the row source):

```swift
    private var claudeSwitchTargets: [String: ClaudeRunwaySwitchTarget] {
        guard let rows = visibleClaudeRunwaySnapshot?.rows, !rows.isEmpty else { return [:] }
        return ClaudeRunwaySwitchTargetResolver.targets(
            rowIDs: rows.map(\.id),
            activeRows: activeRows,
            desktopRecords: ClaudeDesktopSessionTitles.records()
        )
    }
```

Pass it into `HUDLimitsExpandedPanel` in `expandedPanel` (~line 3906): add argument `claudeSwitchTargets: claudeSwitchTargets`.

Add to `HUDLimitsExpandedPanel` (~line 4235): `var claudeSwitchTargets: [String: ClaudeRunwaySwitchTarget] = [:]`, and forward it in its body's `HUDLimitsDetailPanel(...)` call (~line 4244): `claudeSwitchTargets: claudeSwitchTargets`.

Add to `HUDLimitsDetailPanel` (~line 4345): `var claudeSwitchTargets: [String: ClaudeRunwaySwitchTarget] = [:]`, and change its runway call (~line 4409) to:

```swift
            HUDRunwayPanel(
                snapshot: snapshot,
                now: now,
                agentLabel: source == .claude ? "Claude" : "Codex",
                switchTargets: source == .claude ? claudeSwitchTargets : [:]
            )
```

All new parameters are defaulted, so any other `HUDLimitsDetailPanel`/`HUDLimitsExpandedPanel` call sites (e.g. onboarding previews) compile unchanged — verify with the build.

- [ ] **Step 4: Build and run the runway/registry test classes**

```bash
xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug build
xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "$PWD/.deriveddata-tests" -parallel-testing-enabled NO test -only-testing:AgentSessionsTests/ClaudeRunwaySwitchTargetTests -only-testing:AgentSessionsTests/ClaudeRunwayParserTests -only-testing:AgentSessionsTests/CodexActiveSessionsRegistryTests
```

Expected: BUILD SUCCEEDED, all listed suites pass.

- [ ] **Step 5: Commit**

```bash
git add AgentSessions/Views/AgentCockpitHUDView.swift
git commit -m "feat(runway): click a Claude runway row to focus its iTerm2 tab or open it in Claude Desktop

Tool: Claude Code
Model: claude-fable-5
Why: /pet-style quick session switching from the runway (spec 2026-07-06)"
```

---

### Task 6: Full verification + owner QA handoff

**Files:** none (verification only).

- [ ] **Step 1: Run the full test suite**

```bash
xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "$PWD/.deriveddata-tests" -parallel-testing-enabled NO clean test
```

Expected: all suites pass. Grep for `callsite drift`: also run `grep -rn "applyLimitsDefaultSize(" AgentSessions --include='*.swift'` — every call must pass `toolbarDelta:`.

- [ ] **Step 2: Build the run bundle for the owner (never from .deriveddata-tests)**

```bash
xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug -derivedDataPath "$PWD/.deriveddata-manual" build
killall AgentSessions 2>/dev/null; open .deriveddata-manual/Build/Products/Debug/AgentSessions.app
```

- [ ] **Step 3: Hand the owner this QA checklist (do not drive the app yourself)**

1. Switch to Quota Meter mode via the new segmented selector; switch back to Full and Compact — one click each, no popover.
2. Park QM mid-screen; hover — toolbar appears above, rows do not move; unhover — reverse.
3. Park QM flush at the top edge; hover — window grows downward, single small nudge at entry, then stable clicking.
4. Park QM flush at the bottom edge; hover — window grows upward, rows stay put.
5. With a Claude CLI session burning in iTerm2: hover its runway row (tint + terminal glyph + pointing hand), click — iTerm2 tab focuses.
6. With a Claude Desktop session burning: click its row — Claude Desktop opens that exact conversation.
7. A stale/unmatched row and the "+N sessions" summary row show no hover affordance.
8. Codex runway rows unchanged (inert).

- [ ] **Step 4: Report results; on owner GO, follow repo release/commit protocol**

No auto-push. Any QA failure loops back to the offending task with superpowers:systematic-debugging.
