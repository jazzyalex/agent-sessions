# Quota Meter Notch Spike Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a throwaway AppKit prototype that proves (or disproves) the notch panel topology and handoff on a real notched Mac, then write the findings into the spec.

**Architecture:** A standalone SwiftPM executable in `tools/notch-spike/`, outside the Xcode project, so nothing touches `AgentSessions.xcodeproj`. It uses the SwiftUI `App` lifecycle like the real app: an `NSApplicationDelegateAdaptor` owns the AppKit notch panels, and the floating stand-in is a SwiftUI `Window` scene configured exactly like the production Quota Meter window. It runs as an accessory app with its own status item for controls. Every observable event goes to a plain log file, which is the evidence for the findings. The owner runs a fixed checklist on their 14" MacBook Pro; the agent reads the log and writes the findings.

**Tech Stack:** Swift 6.2, SwiftPM, AppKit, swift-testing for the one pure unit, macOS 14 deployment target (matches the app).

**Spec:** `docs/superpowers/specs/2026-10-12-quota-meter-notch-design.md`, section "Hardware spike" (plus "Panel topology", "Handoff", "Crowded menu bar: Wings / Minimal", "Full-screen apps").

## Global Constraints

- Throwaway code. Never add it to `AgentSessions.xcodeproj`; never commit it. Task 1 adds `tools/notch-spike/` to `.git/info/exclude`.
- Commits only when the owner asks (repo rule). The only intended commit is the spec update in Task 6, with `git commit -- <paths>`.
- Panels: borderless `NSPanel`, `.nonactivatingPanel`, `level = .statusBar`, `hidesOnDeactivate = false`, non-opaque, no shadow on wings. Collection behaviour `[.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]`. No level above `.statusBar`.
- Notched screen: `safeAreaInsets.top > 0` and both `auxiliaryTopLeftArea` / `auxiliaryTopRightArea` non-nil; prefer `CGDisplayIsBuiltin`.
- Wing width: 95 pt. Hairline height: 3 pt. Dwell: 350 ms to open, 700 ms to close.
- Screen-change debounce: 0.5 s. A **burst** is a run of `screens.changed` events with gaps under 0.5 s; the topology is **settled** 0.5 s after the last event of a burst. Exactly one rebuild per burst.
- Handoff overlap target: under 250 ms; visibility wait timeout 1 s. A timeout is a handoff **failure**, never a success: the old presentation stays visible and no `overlap_ms` is reported.
- Floating stand-in = the production Quota Meter window's settings, read from `AgentSessions/Views/AgentCockpitHUDWindow.swift` and `AgentSessionsApp.swift` on 2026-10-17: SwiftUI `Window` scene (so an `NSWindow`, not an `NSPanel`), opened with `openWindow(id:)`; style mask with `.titled` removed and `.fullSizeContentView` added (`applyCompactChrome`, lines 268–282); `titleVisibility = .hidden`, `titlebarAppearsTransparent = true`, `isOpaque = false`, `backgroundColor = .clear`, `hasShadow = false`, standard window buttons hidden; `isMovableByWindowBackground = true` (line 186); fixed width 380 via `minSize == maxSize` (lines 121, 204–205); pinned: `level = .statusBar`, `collectionBehavior` ∪ `[.canJoinAllSpaces, .fullScreenAuxiliary]`, `hidesOnDeactivate = false` (lines 117–118, 228–230). The spike's handoff opens it **without** `NSApp.activate`; the production `showAgentCockpitWindow()` activates (line 77), which the spec forbids for display-driven handoffs.
- Evidence goes to `~/Library/Logs/AgentSessions-NotchSpike/spike.log` via direct file writes. `os_log` does not reach `log show` on this machine, so do not rely on it.
- No computer-use and no automated UI driving. The agent builds; the owner runs the checklist.
- Build with `swift build` from `tools/notch-spike/`. Never `xcodebuild test` (it touches the live index).

## Review Focus

1. **Notch absent at launch** (lid closed with an external display, or a Mac without a notch): the spike must log "no notched screen" and show nothing, not crash or place panels at y = 0. Test in Task 1 (`layoutIsNilWithoutNotch`), behaviour in Task 4.
2. **Rapid lid close/open or display replug within the 0.5 s debounce:** exactly one teardown and rebuild per settled topology, no duplicate panels. Test in Task 4 (`debouncerCoalescesBursts`).
3. **Pointer leaving the drop panel to a menu bar item** while the close timer runs: the panel closes after 700 ms and the menu opens normally. Owner checklist item C3.
4. **Clicking the drop panel's button while another app is frontmost:** the button works and `NSApp.isActive` stays false. Logged in Task 3; checklist C4.
5. **Scaled resolution ("More Space"):** wing and notch rects still line up with the hardware notch. Task 1 tests a second geometry; checklist C2 asks for a visual check at two scalings.

Also covered because the 2026-10-17 plan review flagged them: the handoff visibility timeout (Task 5 logs `handoff.failed` and keeps the old presentation), panel deallocation after rebuild (Task 2 deinit logging, Task 4 `panels.alive`), and both orders of cross-panel hover events (Task 3 tests).

---

### Task 1: Package scaffold and spike geometry

**Files:**
- Create: `tools/notch-spike/Package.swift`
- Create: `tools/notch-spike/Sources/NotchSpikeCore/SpikeGeometry.swift`
- Create: `tools/notch-spike/Tests/NotchSpikeCoreTests/SpikeGeometryTests.swift`
- Modify: `.git/info/exclude` (append `tools/notch-spike/`)

**Interfaces:**
- Produces:
  - `public struct SpikeLayout: Equatable { public let notch: CGRect; public let leftWing: CGRect; public let rightWing: CGRect; public let leftHairline: CGRect; public let rightHairline: CGRect; public let sensor: CGRect; public let dropPanel: CGRect }`
  - `public enum SpikeGeometry { public static func layout(screenFrame: CGRect, safeAreaTop: CGFloat, auxLeft: CGRect?, auxRight: CGRect?, wingWidth: CGFloat = 95, hairline: CGFloat = 3, dropSize: CGSize = CGSize(width: 620, height: 190)) -> SpikeLayout? }`
- Package: library `NotchSpikeCore`, executable `notch-spike` (depends on `NotchSpikeCore`), test target `NotchSpikeCoreTests`; `platforms: [.macOS(.v14)]`.

Geometry rules (Cocoa coordinates, origin bottom-left):
- `nil` when `safeAreaTop <= 0` or either aux rect is nil.
- `notch`: x from `auxLeft.maxX` to `auxRight.minX`; y from `screenFrame.maxY - safeAreaTop` to `screenFrame.maxY`.
- `leftWing`: width `wingWidth`, right edge at `notch.minX`, same y/height as `notch`. `rightWing`: mirror at `notch.maxX`.
- Hairlines: x span = wing span; height `hairline`; top edge at `notch.minY` (just under the menu bar row).
- `sensor` = `notch`.
- `dropPanel`: centred on `notch.midX`, top edge at `notch.minY`, size `dropSize`.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import CoreGraphics
@testable import NotchSpikeCore

// 14" MBP default scaling: 1512×982 pt, notch ≈ 184 pt wide, 32 pt tall.
let screen14 = CGRect(x: 0, y: 0, width: 1512, height: 982)
let left14 = CGRect(x: 0, y: 950, width: 664, height: 32)
let right14 = CGRect(x: 848, y: 950, width: 664, height: 32)

@Test func notchSitsBetweenAuxAreas() throws {
    let l = try #require(SpikeGeometry.layout(screenFrame: screen14, safeAreaTop: 32, auxLeft: left14, auxRight: right14))
    #expect(l.notch == CGRect(x: 664, y: 950, width: 184, height: 32))
    #expect(l.sensor == l.notch)
}

@Test func wingsAreFixedWidthAndFlankTheNotch() throws {
    let l = try #require(SpikeGeometry.layout(screenFrame: screen14, safeAreaTop: 32, auxLeft: left14, auxRight: right14))
    #expect(l.leftWing == CGRect(x: 569, y: 950, width: 95, height: 32))
    #expect(l.rightWing == CGRect(x: 848, y: 950, width: 95, height: 32))
}

@Test func hairlinesHangUnderTheMenuBarRow() throws {
    let l = try #require(SpikeGeometry.layout(screenFrame: screen14, safeAreaTop: 32, auxLeft: left14, auxRight: right14))
    #expect(l.leftHairline == CGRect(x: 569, y: 947, width: 95, height: 3))
    #expect(l.rightHairline == CGRect(x: 848, y: 947, width: 95, height: 3))
}

@Test func dropPanelIsCentredUnderTheNotch() throws {
    let l = try #require(SpikeGeometry.layout(screenFrame: screen14, safeAreaTop: 32, auxLeft: left14, auxRight: right14))
    #expect(l.dropPanel == CGRect(x: 446, y: 760, width: 620, height: 190))
}

@Test func scaledResolutionKeepsAlignment() throws {
    // "More Space" on 14": 1800×1169 pt; notch narrower in points.
    let screen = CGRect(x: 0, y: 0, width: 1800, height: 1169)
    let l = try #require(SpikeGeometry.layout(
        screenFrame: screen, safeAreaTop: 32,
        auxLeft: CGRect(x: 0, y: 1137, width: 822, height: 32),
        auxRight: CGRect(x: 978, y: 1137, width: 822, height: 32)))
    #expect(l.notch == CGRect(x: 822, y: 1137, width: 156, height: 32))
    #expect(l.leftWing.maxX == l.notch.minX)
    #expect(l.rightWing.minX == l.notch.maxX)
}

@Test func layoutIsNilWithoutNotch() {
    #expect(SpikeGeometry.layout(screenFrame: screen14, safeAreaTop: 0, auxLeft: nil, auxRight: nil) == nil)
    #expect(SpikeGeometry.layout(screenFrame: screen14, safeAreaTop: 32, auxLeft: left14, auxRight: nil) == nil)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd tools/notch-spike && swift test`
Expected: compile failure, `SpikeGeometry` not found.

- [ ] **Step 3: Implement `Package.swift`, `SpikeLayout` and `SpikeGeometry.layout(...)`** per the rules above. Add a stub `Sources/notch-spike/main.swift` that prints "notch-spike" so the executable target builds. Append `tools/notch-spike/` to `.git/info/exclude`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd tools/notch-spike && swift test`
Expected: 6 tests passed. Also `git status --short tools/` prints nothing.

### Task 2: Event log and panel factory

**Files:**
- Create: `tools/notch-spike/Sources/NotchSpikeCore/SpikeLog.swift`
- Create: `tools/notch-spike/Sources/notch-spike/SpikePanel.swift`
- Test: `tools/notch-spike/Tests/NotchSpikeCoreTests/SpikeLogTests.swift`

**Interfaces:**
- Produces:
  - `public final class SpikeLog: @unchecked Sendable { public init(url: URL); public static let shared: SpikeLog; public func write(_ event: String, _ fields: [String: String] = [:]) }`. One line per event: ISO-8601 time with milliseconds, tab, event name, tab, `key=value` pairs sorted by key. Appends; creates the directory. `shared` uses `~/Library/Logs/AgentSessions-NotchSpike/spike.log`. A serial queue guards writes.
  - `final class SpikePanel: NSPanel` with `init(frame: CGRect, role: String, generation: Int, opaqueBlack: Bool, log: SpikeLog)`. Applies every panel constraint from Global Constraints. `role` is stored and used as the window identifier (`"notch-spike.<role>"`) and in log lines. `canBecomeKey` returns true only for role `"drop"`; `canBecomeMain` always false. `isReleasedWhenClosed = false`. `deinit` logs `panel.deinit role=<role> gen=<generation>`; this is the leak evidence.

- [ ] **Step 1: Write the failing test**

```swift
@Test func logLinesAreTimestampedAndSorted() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    let log = SpikeLog(url: dir.appending(path: "spike.log"))
    log.write("hover.enter", ["role": "leftWing", "app_active": "false"])
    log.write("panel.created")
    log.flushForTesting()
    let lines = try String(contentsOf: dir.appending(path: "spike.log"), encoding: .utf8)
        .split(separator: "\n")
    #expect(lines.count == 2)
    #expect(lines[0].contains("\thover.enter\tapp_active=false role=leftWing"))
    // ISO-8601 UTC with exactly three fractional digits, e.g. 2026-10-17T21:22:59.123Z
    let stamp = try #require(lines[0].split(separator: "\t").first.map(String.init))
    #expect(stamp.wholeMatch(of: /\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z/) != nil)
    #expect(lines[1].hasSuffix("\tpanel.created\t"))
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd tools/notch-spike && swift test --filter logLinesAreTimestampedAndSorted`
Expected: compile failure, `SpikeLog` not found.

- [ ] **Step 3: Implement `SpikeLog` (including `func flushForTesting()`, which drains the serial queue synchronously) and `SpikePanel`.**

- [ ] **Step 4: Run to verify it passes**

Run: `cd tools/notch-spike && swift test`
Expected: 7 tests passed.

### Task 3: Wings, notch sensor, drop panel and hover state

**Files:**
- Create: `tools/notch-spike/Sources/notch-spike/SpikeController.swift`
- Create: `tools/notch-spike/Sources/NotchSpikeCore/HoverDwell.swift`
- Delete: `tools/notch-spike/Sources/notch-spike/main.swift` (the Task 1 stub)
- Create: `tools/notch-spike/Sources/notch-spike/SpikeApp.swift`
- Test: `tools/notch-spike/Tests/NotchSpikeCoreTests/HoverDwellTests.swift`

**Interfaces:**
- Consumes: `SpikeGeometry.layout`, `SpikeLayout`, `SpikeLog`, `SpikePanel`.
- Produces:
  - `public struct HoverDwell { public enum Action: Equatable { case none, scheduleOpen(TimeInterval), scheduleClose(TimeInterval), cancelTimers } ; public init(openDelay: TimeInterval = 0.35, closeDelay: TimeInterval = 0.7); public mutating func pointer(entered region: String) -> Action; public mutating func pointer(exited region: String) -> Action; public mutating func timerFired() -> Bool /* true = panel should toggle */ ; public private(set) var isOpen: Bool; public private(set) var activeRegions: Set<String> }`. Regions are `"leftWing"`, `"rightWing"`, `"sensor"`, `"drop"`.
    Rules: `entered` inserts into `activeRegions`; `exited` removes. Only the empty ↔ non-empty transitions act. Becoming non-empty: `.scheduleOpen(openDelay)` if closed, `.cancelTimers` if open. Becoming empty: `.scheduleClose(closeDelay)` if open, `.cancelTimers` if closed. Every other event returns `.none`. So exit-old → enter-new may schedule a provisional close that the enter cancels, and enter-new → exit-old never schedules one.
  - `@MainActor final class SpikeController { init(log: SpikeLog); func start(); func rebuild(reason: String); var style: Style /* .wings or .minimal */; func showNotchPanels(); func hideNotchPanels(); func anyWingPanel() -> NSWindow? }`.
  - `@main struct SpikeApp: App` with `@NSApplicationDelegateAdaptor(SpikeAppDelegate.self)`; `SpikeAppDelegate.applicationDidFinishLaunching` sets `.accessory`, creates the controller and calls `start()`. Task 5 adds the stand-in `Window` scene to this file.
- Wing content: black fill plus a static label ("62%" left, "34%" right). Drop panel: black, two columns of static text, one `NSButton` "Spike action" that logs `drop.button` with `app_active=\(NSApp.isActive)`.
- Each panel's content view installs an `NSTrackingArea` (`.mouseEnteredAndExited`, `.activeAlways`, `.inVisibleRect`) feeding `HoverDwell`; log `hover.enter`, `hover.exit`, `drop.open`, `drop.close`, each with `role`.
- Content views log `click` and `rightClick` (`mouseDown`, `rightMouseDown`) with `role`, `app_active` and `frontmost=<NSWorkspace.shared.frontmostApplication bundle id>`. A right-click shows no menu in the spike.
- On start and rebuild, log `layout` with all rects and `screen` with frame, `builtin`, `backingScale`; when `layout(...)` returns nil, log `no-notched-screen` and create no panels.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func enteringSchedulesOpenAfterDwell() {
    var d = HoverDwell()
    #expect(d.pointer(entered: "leftWing") == .scheduleOpen(0.35))
    #expect(d.timerFired() == true)
    #expect(d.isOpen)
}

@Test func movingBetweenRegionsDoesNotClose() {
    var d = HoverDwell()
    _ = d.pointer(entered: "leftWing"); _ = d.timerFired()
    #expect(d.pointer(exited: "leftWing") == .scheduleClose(0.7))
    #expect(d.pointer(entered: "sensor") == .cancelTimers)
    #expect(d.pointer(exited: "sensor") == .scheduleClose(0.7))
    #expect(d.pointer(entered: "drop") == .cancelTimers)
    #expect(d.isOpen)
}

@Test func overlappingEnterThenExitNeverSchedulesClose() {
    var d = HoverDwell()
    _ = d.pointer(entered: "leftWing"); _ = d.timerFired()
    #expect(d.pointer(entered: "sensor") == .none)
    #expect(d.pointer(exited: "leftWing") == .none)
    #expect(d.activeRegions == ["sensor"])
    #expect(d.isOpen)
}

@Test func leavingEverythingClosesAfterDelay() {
    var d = HoverDwell()
    _ = d.pointer(entered: "rightWing"); _ = d.timerFired()
    #expect(d.pointer(exited: "rightWing") == .scheduleClose(0.7))
    #expect(d.timerFired() == true)
    #expect(!d.isOpen)
}

@Test func briefHoverNeverOpens() {
    var d = HoverDwell()
    _ = d.pointer(entered: "leftWing")
    #expect(d.pointer(exited: "leftWing") == .cancelTimers)
    #expect(!d.isOpen)
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd tools/notch-spike && swift test --filter HoverDwell`
Expected: compile failure, `HoverDwell` not found.

- [ ] **Step 3: Implement `HoverDwell`, then `SpikeController` and `SpikeApp.swift`; delete the stub `main.swift`.** `SpikeController` owns one `Timer` and applies `HoverDwell` actions to it.

- [ ] **Step 4: Run tests and build**

Run: `cd tools/notch-spike && swift test && swift build`
Expected: 12 tests passed; build succeeds.

- [ ] **Step 5: Smoke run**

Run: `cd tools/notch-spike && swift build && (.build/debug/notch-spike & echo $! > "$TMPDIR/notch-spike.pid"); sleep 5; tail -5 ~/Library/Logs/AgentSessions-NotchSpike/spike.log; kill "$(cat "$TMPDIR/notch-spike.pid")"`
Expected: a `screen` line with `builtin=true` and a `layout` line whose `notch` width matches the Task 1 rule for this display. If the agent's session cannot show windows, record that and leave the visual check to the owner.

### Task 4: Status-item controls, Minimal style, screen changes, sleep and wake

**Files:**
- Create: `tools/notch-spike/Sources/notch-spike/SpikeMenu.swift`
- Create: `tools/notch-spike/Sources/NotchSpikeCore/Debouncer.swift`
- Modify: `tools/notch-spike/Sources/notch-spike/SpikeController.swift`
- Test: `tools/notch-spike/Tests/NotchSpikeCoreTests/DebouncerTests.swift`

**Interfaces:**
- Consumes: `SpikeController.rebuild(reason:)`, `SpikeController.style`.
- Produces:
  - `public final class Debouncer { public init(delay: TimeInterval, schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { d, f in DispatchQueue.main.asyncAfter(deadline: .now() + d, execute: f) }); public func call(_ action: @escaping () -> Void) }`. Only the last call within `delay` runs (generation counter).
  - `SpikeMenu`: an `NSStatusItem` titled "NS" with items: "Style: Wings", "Style: Minimal", "Handoff → floating", "Handoff → notch", "Mark checklist step…" (prompts for a label via `NSAlert` with a text field and logs `mark label=<text>`), "Open log", "Quit".
- Minimal: wing panels resize to the hairline rects; the sensor stays the notch rect and keeps hover working. Log `style value=minimal|wings`.
- Observers: `NSApplication.didChangeScreenParametersNotification` → log `screens.changed`, then `Debouncer(delay: 0.5)` → `rebuild(reason: "screens")`. `NSWorkspace.willSleepNotification` / `didWakeNotification` → log `sleep` / `wake`, then rebuild on wake. `rebuild` increments a panel generation, closes and releases every panel, logs `panels.torn-down count=N gen=<old>`, recreates, and logs `panels.created count=N gen=<new>`. The controller also keeps weak references to every panel it ever created; 1 s after each rebuild it logs `panels.alive gen=<new> current=<n> stale=<m>`. `stale` counts previous-generation panels that are still allocated. Pass is `stale=0`, backed by matching `panel.deinit` lines.
- Each `screens.changed` line carries `burst=<k>`, which increments when the previous `screens.changed` was 0.5 s or more earlier, so a C14 analysis can count one `panels.created` per burst.
- `NSWorkspace.activeSpaceDidChangeNotification` → log `space.changed` with the frontmost app's bundle id.

- [ ] **Step 1: Write the failing test**

```swift
@Test func debouncerCoalescesBursts() {
    var pending: [(TimeInterval, () -> Void)] = []
    let d = Debouncer(delay: 0.5) { delay, fire in pending.append((delay, fire)) }
    var runs = 0
    d.call { runs += 1 }; d.call { runs += 1 }; d.call { runs += 1 }
    pending.forEach { $0.1() }
    #expect(runs == 1)
    #expect(pending.allSatisfy { $0.0 == 0.5 })
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd tools/notch-spike && swift test --filter debouncerCoalescesBursts`
Expected: compile failure, `Debouncer` not found.

- [ ] **Step 3: Implement `Debouncer`, `SpikeMenu` and the controller changes.**

- [ ] **Step 4: Run tests and build**

Run: `cd tools/notch-spike && swift test && swift build`
Expected: 13 tests passed; build succeeds.

### Task 5: Handoff prototype

**Files:**
- Create: `tools/notch-spike/Sources/notch-spike/SpikeHandoff.swift`
- Create: `tools/notch-spike/Sources/notch-spike/StandInWindowConfigurator.swift`
- Create: `tools/notch-spike/Sources/NotchSpikeCore/VisibilityWait.swift`
- Modify: `tools/notch-spike/Sources/notch-spike/SpikeApp.swift`, `SpikeMenu.swift`
- Test: `tools/notch-spike/Tests/NotchSpikeCoreTests/VisibilityWaitTests.swift`

**Interfaces:**
- Consumes: `SpikeController` (show and hide the notch panel set; `func anyWingPanel() -> NSWindow?`), `SpikeLog`.
- Produces:
  - `public final class VisibilityWait { public enum Outcome: Equatable { case visible(source: String), timedOut }; public init(timeout: TimeInterval = 1.0, schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { d, f in DispatchQueue.main.asyncAfter(deadline: .now() + d, execute: f) }); public func start(alreadyVisible: Bool, completion: @escaping (Outcome) -> Void); public func reportVisible() }`. The completion fires exactly once: `.visible(source: "initial")` immediately when `alreadyVisible`, `.visible(source: "occlusion")` on the first `reportVisible()`, or `.timedOut` when the timeout fires first. Later calls are ignored.
  - `@MainActor final class SpikeHandoff { init(controller: SpikeController, log: SpikeLog, openStandIn: @escaping () -> Void); func toFloating(); func toNotch() }`.
  - Stand-in: a SwiftUI `Window("Stand-in", id: "notch-spike.standin")` scene in `SpikeApp`, 380×120, static text. `StandInWindowConfigurator` is an `NSViewRepresentable` background that applies every production setting from Global Constraints ("Floating stand-in") to the hosting `NSWindow`, in the "pinned" variant. It logs `standin.config` with style mask, level, collection behaviour and `hidesOnDeactivate` so the findings can quote the real values. `openStandIn` calls `openWindow(id:)`, captured from the scene, without `NSApp.activate`.

Rules (from the spec's "Handoff"; show new, then hide old; a timeout is a failure):
- `toFloating()`:
  1. Log `handoff.start dir=to-floating`.
  2. Register the occlusion observer (`NSWindow.didChangeOcclusionStateNotification`, filtered to the stand-in window once it exists) **before** opening.
  3. Call `openStandIn()`. When the window appears, check `occlusionState.contains(.visible)` and pass that as `alreadyVisible`.
  4. On `.visible`: log `floating.visible source=<s>`, order the notch panels out, log `notch.out`, then log `handoff.end dir=to-floating overlap_ms=<notch.out − floating.visible> app_active=<NSApp.isActive>`.
  5. On `.timedOut`: log `handoff.failed dir=to-floating reason=visibility-timeout` and keep the notch panels visible. No `overlap_ms`.
- `toNotch()`:
  1. Log `handoff.start dir=to-notch`.
  2. Register the observer for `controller.anyWingPanel()`, then order the notch panels front.
  3. Check the wing's current occlusion state as `alreadyVisible`.
  4. On `.visible`: log `notch.visible source=<s>`, close the stand-in, log `floating.closed`, then log `handoff.end dir=to-notch overlap_ms=<floating.closed − notch.visible>`.
  5. On `.timedOut`: log `handoff.failed dir=to-notch reason=visibility-timeout` and keep the stand-in open.
- A "model signal" stand-in logs `model.signal visible=true pinned=<true for notch, false for floating>` once per **successful** handoff, never `visible=false`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func alreadyVisibleCompletesImmediately() {
    let w = VisibilityWait(timeout: 1.0) { _, _ in }
    var outcomes: [VisibilityWait.Outcome] = []
    w.start(alreadyVisible: true) { outcomes.append($0) }
    w.reportVisible()
    #expect(outcomes == [.visible(source: "initial")])
}

@Test func occlusionBeforeTimeoutWins() {
    var fireTimeout: (() -> Void)?
    let w = VisibilityWait(timeout: 1.0) { _, f in fireTimeout = f }
    var outcomes: [VisibilityWait.Outcome] = []
    w.start(alreadyVisible: false) { outcomes.append($0) }
    w.reportVisible()
    fireTimeout?()
    #expect(outcomes == [.visible(source: "occlusion")])
}

@Test func timeoutIsAFailureAndLateVisibilityIsIgnored() {
    var fireTimeout: (() -> Void)?
    var requested: TimeInterval?
    let w = VisibilityWait(timeout: 1.0) { d, f in requested = d; fireTimeout = f }
    var outcomes: [VisibilityWait.Outcome] = []
    w.start(alreadyVisible: false) { outcomes.append($0) }
    fireTimeout?()
    w.reportVisible()
    #expect(outcomes == [.timedOut])
    #expect(requested == 1.0)
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd tools/notch-spike && swift test --filter VisibilityWait`
Expected: compile failure, `VisibilityWait` not found.

- [ ] **Step 3: Implement `VisibilityWait`, the stand-in scene with `StandInWindowConfigurator`, and `SpikeHandoff`; wire the two menu items.**

- [ ] **Step 4: Run tests and build**

Run: `cd tools/notch-spike && swift test && swift build`
Expected: 16 tests passed; build succeeds.

- [ ] **Step 5: Log-shape check**

Run the spike, choose "Handoff → floating" then "Handoff → notch" from the status item, quit, then:
`grep -E "standin\.config|handoff\.(start|end|failed)|model\.signal" ~/Library/Logs/AgentSessions-NotchSpike/spike.log | tail -8`
Expected: one `standin.config` line whose style mask lacks `titled` and includes `fullSizeContentView`, level `statusBar`, and collection behaviour including `canJoinAllSpaces` and `fullScreenAuxiliary`. Then either two `handoff.end` lines with numeric `overlap_ms` and two `model.signal visible=true` lines, or a `handoff.failed` line, which is itself a finding. If the agent cannot interact with menus, this check moves to the owner checklist (step C7).

### Task 6: Owner checklist run, findings, cleanup

**Files:**
- Create: `tools/notch-spike/CHECKLIST.md` (throwaway, uncommitted)
- Modify: `docs/superpowers/specs/2026-10-12-quota-meter-notch-design.md` (add "Spike findings" before "Architecture"; revise "Panel topology" and "Handoff" if contradicted)

- [ ] **Step 1: Write `CHECKLIST.md`** for the owner. Each item tells them to choose "Mark checklist step…" with the item's ID first, then do the action, then note what they saw in one line in the file:

| ID | Action | Pass looks like |
|---|---|---|
| C1 | Launch with the built-in display only | Two black wings flush with the notch; nothing else covered |
| C2 | Repeat C1 at Default and "More Space" scaling | Wings stay flush with the notch at both |
| C3 | Hover left wing → notch → drop panel → back out to a menu bar item | Opens after ~⅓ s, no flicker crossing regions, closes ~0.7 s after leaving, menu opens normally |
| C4 | With Safari frontmost, click "Spike action" in the drop panel | Button works; Safari stays frontmost (`app_active=false` in log) |
| C4b | With Safari frontmost, right-click the left wing, then right-click inside the open drop panel | Two `rightClick` lines with `app_active=false frontmost=com.apple.Safari`; Safari stays frontmost; no menu appears |
| C5 | Open a long app menu (Xcode → View) and a system menu (Apple menu) while wings show | Menus open and draw above the wings |
| C6 | Click status items right of the right wing, including the spike's own "NS" | All respond; nothing is blocked outside the wings |
| C7 | Handoff → floating, then Handoff → notch; repeat three times | No moment with neither visible; two `handoff.end` per round with `overlap_ms` under 250; any `handoff.failed` is a fail |
| C8 | Switch Style to Minimal; hover the notch | Hairlines only; menu bar items beside the notch clickable; hover over the notch still opens the panel |
| C9 | Full-screen Safari; check the top strip; hover the notch | Wings visible in the black strip (or note that they are not) |
| C10 | Stage Manager on; Mission Control open | Wings stay put and are not part of window groups |
| C11 | Connect an external display; disconnect it | One `panels.created` per burst; `panels.alive ... stale=0`; wings return on the built-in display |
| C12 | With the external display connected, close the lid; reopen it | Wings disappear with the lid closed (`no-notched-screen`) and return on reopen |
| C13 | Sleep and wake | Wings return after wake |
| C14 | Close and reopen the lid three times quickly | No duplicate panels; exactly one `panels.created` per `burst` value; every `panels.alive` shows `stale=0` |

- [ ] **Step 2: Owner runs the checklist.** The agent builds (`swift build`) and hands over the run command: `cd tools/notch-spike && swift run notch-spike`. Wait for the owner.

- [ ] **Step 3: Analyse the log and checklist notes.** For each item, quote the log lines that support pass or fail (`mark`, `hover.*`, `drop.*`, `click`, `rightClick`, `standin.config`, `handoff.end overlap_ms`, `handoff.failed`, `panels.*`, `panel.deinit`, `screens.changed burst=`, `no-notched-screen`, `space.changed`). Count `panels.created` per `burst` value. Confirm every `panels.alive` has `stale=0`. Report the min/median/max handoff overlap per direction and every `handoff.failed`. State in the findings that the stand-in mirrors the production window's AppKit settings but not its SwiftUI content or `AgentCockpitHUDWindowConfigurator` resize logic, so real-window integration stays a production-plan check.

- [ ] **Step 4: Write the "Spike findings" section into the spec.** One row per checklist item: result, evidence, consequence for the design. Then revise "Panel topology", "Handoff", "Crowded menu bar: Wings / Minimal" and "Full-screen apps" wherever a finding contradicts them, and update the "Status" line to "spike complete, awaiting owner review".

- [ ] **Step 5: Owner reviews the spec revision.** Commit only on the owner's request:

```bash
git commit -m "docs(spec): add notch spike findings" -- docs/superpowers/specs/2026-10-12-quota-meter-notch-design.md
```

- [ ] **Step 6: Remove the spike.**

Run: `rm -rf tools/notch-spike ~/Library/Logs/AgentSessions-NotchSpike` after copying the log into the scratch area if the owner wants it kept, and remove the `tools/notch-spike/` line from `.git/info/exclude`.
Expected: `git status --short` shows no spike paths.

## Review record

- 2026-10-17, XHigh plan review via Repo MCP, ChatGPT web, GPT-5.6 Sol Extra
  High, commit-pinned 32c02443..40419a2a, journaled (run 286a7034). NO-SHIP.
  Findings and where they were applied:
  - Blocker: a visibility timeout produced a successful handoff. Task 5 now
    uses `VisibilityWait`; a timeout logs `handoff.failed` and keeps the old
    presentation.
  - Major: to-notch overlap was measured from `orderFront`, not observed
    visibility. Task 5 waits for occlusion in both directions.
  - Major: the stand-in did not match the production window. Global
    Constraints list the real settings; Task 5 uses a SwiftUI `Window` scene
    and logs `standin.config`.
  - Minor: right-click was not exercised. Checklist C4b.
  - Minor: panel release was not evidenced. Task 2 `panel.deinit`, Task 4
    `panels.alive ... stale=`.
  - Minor: `HoverDwell` assumed exit-before-enter order. Task 3 is set-based
    with a test for both orders.
  - Minor: weak timestamp test and broad `pkill`. Exact regex; exact-PID kill.
  - Also asked: define "settled". Global Constraints define burst and settled.
