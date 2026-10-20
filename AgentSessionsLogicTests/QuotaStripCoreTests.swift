import XCTest
import Foundation
import CoreGraphics

final class QuotaStripCoreTests: XCTestCase {

    // MARK: Geometry

    func testNotchedLayoutUsesAuxWidths() {
        let l = QuotaStripGeometry.layout(
            screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950),
            safeAreaTop: 32, auxLeftWidth: 664, auxRightWidth: 664)
        XCTAssertEqual(l.notch, CGRect(x: 664, y: 950, width: 184, height: 32))
        XCTAssertEqual(l.leftWing, CGRect(x: 560, y: 950, width: 104, height: 32))
        XCTAssertEqual(l.rightWing, CGRect(x: 848, y: 950, width: 104, height: 32))
        XCTAssertFalse(l.isVirtual)
    }

    func testOffsetBuiltinScreen() {
        let l = QuotaStripGeometry.layout(
            screenFrame: CGRect(x: 2560, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 2560, y: 0, width: 1512, height: 950),
            safeAreaTop: 32, auxLeftWidth: 664, auxRightWidth: 664)
        XCTAssertEqual(l.notch.minX, 3224)
        XCTAssertEqual(l.notch.width, 184)
    }

    func testVirtualNotchCentred() {
        let l = QuotaStripGeometry.layout(
            screenFrame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
            visibleFrame: CGRect(x: 0, y: 0, width: 2560, height: 1415),
            safeAreaTop: 0, auxLeftWidth: nil, auxRightWidth: nil)
        XCTAssertEqual(l.notch, CGRect(x: 1268, y: 1415, width: 24, height: 25))
        XCTAssertEqual(l.leftWing, CGRect(x: 1164, y: 1415, width: 104, height: 25))
        XCTAssertTrue(l.isVirtual)
    }

    func testVirtualNotchAutoHiddenMenuBar() {
        let l = QuotaStripGeometry.layout(
            screenFrame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
            visibleFrame: CGRect(x: 0, y: 0, width: 2560, height: 1440),
            safeAreaTop: 0, auxLeftWidth: nil, auxRightWidth: nil)
        XCTAssertEqual(l.notch, CGRect(x: 1268, y: 1416, width: 24, height: 24))
    }

    // MARK: Sizing (Wings / Minimal)

    private let notchSizing = QuotaStripSizing(notchWidth: 184, notchHeight: 32)
    private let content = CGSize(width: 300, height: 200)

    func testMinimalCollapsedShapeIsTheNotchOnly() {
        // Wings: wing · notch · wing plus the two 6 pt flares.
        XCTAssertEqual(notchSizing.collapsedSize(minimal: false), CGSize(width: 404, height: 32))
        // Minimal: the notch plus its flares; the menu bar beside it is not covered.
        XCTAssertEqual(notchSizing.collapsedSize(minimal: true), CGSize(width: 196, height: 32))
        let virtual = QuotaStripSizing(notchWidth: 24, notchHeight: 25)
        XCTAssertEqual(virtual.collapsedSize(minimal: true), CGSize(width: 36, height: 25))
    }

    func testPanelDoesNotMoveWhenTheStyleChanges() {
        let panel = notchSizing.panelSize(content: content)
        // Expanded width never narrower than the wings (+40), plus 40 pt shadow margin a side.
        XCTAssertEqual(notchSizing.expandedSize(content: content), CGSize(width: 444, height: 210))
        XCTAssertEqual(panel, CGSize(width: 524, height: 260))
        let wings = notchSizing.hitRect(expanded: false, minimal: false, content: content)
        let minimal = notchSizing.hitRect(expanded: false, minimal: true, content: content)
        XCTAssertEqual(wings, CGRect(x: 60, y: 0, width: 404, height: 32))
        XCTAssertEqual(minimal, CGRect(x: 164, y: 0, width: 196, height: 32))
        XCTAssertEqual(wings.midX, minimal.midX) // both centred on the notch
    }

    func testExpandedHitRectCoversTheOpenShape() {
        let open = notchSizing.hitRect(expanded: true, minimal: true, content: content)
        XCTAssertEqual(open, CGRect(x: 40, y: 0, width: 444, height: 210))
    }

    // MARK: Placement

    private let builtin = PlacementScreen(id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982), isBuiltin: true)
    private let external = PlacementScreen(id: 2, frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440), isBuiltin: false)

    func testAutomaticFollowsTargetScreenKind() {
        let onExternal = CGRect(x: 2000, y: 900, width: 417, height: 200)
        let onBuiltin = CGRect(x: 100, y: 600, width: 417, height: 200)
        XCTAssertEqual(QuotaMeterPlacementResolver.resolve(.automatic, screens: [builtin, external], floatingFrame: onExternal), .floating)
        XCTAssertEqual(QuotaMeterPlacementResolver.resolve(.automatic, screens: [builtin, external], floatingFrame: onBuiltin), .strip(screenID: 1))
        // Lid closed: only the external display is connected.
        XCTAssertEqual(QuotaMeterPlacementResolver.resolve(.automatic, screens: [external], floatingFrame: onBuiltin), .floating)
    }

    func testMenuBarStripsOnTargetEvenWithoutNotch() {
        XCTAssertEqual(QuotaMeterPlacementResolver.resolve(.menuBar, screens: [external], floatingFrame: nil), .strip(screenID: 2))
    }

    func testFloatingAlwaysFloats() {
        XCTAssertEqual(QuotaMeterPlacementResolver.resolve(.floating, screens: [builtin], floatingFrame: nil), .floating)
    }

    func testOrphanedFrameFallsBackToFirstScreen() {
        let orphan = CGRect(x: 10000, y: 10000, width: 417, height: 200)
        XCTAssertEqual(QuotaMeterPlacementResolver.targetScreen(screens: [external, builtin], floatingFrame: orphan), external)
        XCTAssertEqual(QuotaMeterPlacementResolver.targetScreen(screens: [external, builtin], floatingFrame: nil), external)
    }

    func testNoScreensIsFloating() {
        XCTAssertEqual(QuotaMeterPlacementResolver.resolve(.menuBar, screens: [], floatingFrame: nil), .floating)
    }

    // MARK: Defaults

    func testDefaults() {
        XCTAssertNil(QuotaMeterPlacementDefaults.valueToWrite(storedRaw: "menuBar", menuBarEnabled: false, isFreshInstall: true))
        XCTAssertEqual(QuotaMeterPlacementDefaults.valueToWrite(storedRaw: nil, menuBarEnabled: true, isFreshInstall: false), .menuBar)
        XCTAssertEqual(QuotaMeterPlacementDefaults.valueToWrite(storedRaw: nil, menuBarEnabled: false, isFreshInstall: true), .automatic)
        XCTAssertEqual(QuotaMeterPlacementDefaults.valueToWrite(storedRaw: nil, menuBarEnabled: false, isFreshInstall: false), .floating)
    }

    // MARK: Wing cells

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// `projection` is the panel formatter's label (`formatUsageProjectionLabel`), already
    /// nil when stale, so the wing and the panel agree on when and what to show.
    private func input(_ state: StripCellInput.State = .live, five: Int? = nil, week: Int? = nil,
                       projection: String? = nil) -> StripCellInput {
        StripCellInput(state: state, fiveHourLeft: five, weekLeft: week, projection: projection)
    }

    func testCellStates() {
        let signIn = QuotaStripCellBuilder.cell(input(.needsAction, five: 50))
        XCTAssertEqual(signIn.text, "Sign in")
        XCTAssertEqual(signIn.tone, .muted)
        XCTAssertNil(signIn.chip)
        XCTAssertEqual(QuotaStripCellBuilder.cell(input(.idle)).text, "Idle")
        XCTAssertEqual(QuotaStripCellBuilder.cell(input(.limited)).text, "Limited")
        XCTAssertEqual(QuotaStripCellBuilder.cell(input(.retrying)).text, "Retrying")
        XCTAssertEqual(QuotaStripCellBuilder.cell(input(.probing)).text, "Probing")
    }

    func testCellPicksLeastRemaining() {
        let weekly = QuotaStripCellBuilder.cell(input(five: 62, week: 40))
        XCTAssertEqual(weekly.text, "40%")
        XCTAssertEqual(weekly.tag, "wk")
        XCTAssertEqual(weekly.tone, .healthy)
        let fiveHour = QuotaStripCellBuilder.cell(input(five: 24, week: 80))
        XCTAssertEqual(fiveHour.text, "24%")
        XCTAssertEqual(fiveHour.tag, "5h") // owner 2026-10-19: both windows are tagged
        XCTAssertEqual(fiveHour.tone, .warning)
        XCTAssertEqual(QuotaStripCellBuilder.cell(input(five: 8)).tone, .critical)
        let none = QuotaStripCellBuilder.cell(input())
        XCTAssertEqual(none.text, "∞")
        XCTAssertEqual(none.tone, .muted)
    }

    func testCellUsedModeShowsMostUsed() {
        var i = input(five: 62, week: 40)
        i.showsUsed = true
        let cell = QuotaStripCellBuilder.cell(i)
        XCTAssertEqual(cell.text, "60%")
        XCTAssertEqual(cell.tag, "wk")
        XCTAssertEqual(cell.tone, .healthy) // tone follows what is left, whatever the mode
        i.fiveHourLeft = 8
        XCTAssertEqual(QuotaStripCellBuilder.cell(i).text, "92%")
        XCTAssertEqual(QuotaStripCellBuilder.cell(i).tone, .critical)
    }

    func testCellChipHiddenWhenProjectionOff() {
        var i = input(five: 50, projection: "▸40m")
        i.showsProjection = false
        XCTAssertNil(QuotaStripCellBuilder.cell(i).chip)
    }

    func testEmptyWindowIsTaggedNotBareInfinity() {
        // Codex alone: no 5h window, so the 5h wing says "∞ 5h", never a bare "∞".
        var i = input(week: 61)
        i.weekLeft = nil
        i.emptyTag = "5h"
        let cell = QuotaStripCellBuilder.cell(i)
        XCTAssertEqual(cell.text, "∞")
        XCTAssertEqual(cell.tag, "5h")
        XCTAssertEqual(cell.tone, .muted)
    }

    // MARK: Polling signal

    func testPollingSignalCombinesSurfaces() {
        XCTAssertEqual(QuotaMeterPollingSignal.combine([]), QuotaMeterPollingSignal(visible: false, pinned: false))
        XCTAssertEqual(QuotaMeterPollingSignal.combine([.window(pinned: false)]), QuotaMeterPollingSignal(visible: true, pinned: false))
        XCTAssertEqual(QuotaMeterPollingSignal.combine([.window(pinned: true)]), QuotaMeterPollingSignal(visible: true, pinned: true))
        XCTAssertEqual(QuotaMeterPollingSignal.combine([.strip]), QuotaMeterPollingSignal(visible: true, pinned: true))
        XCTAssertEqual(QuotaMeterPollingSignal.combine([.window(pinned: false), .strip]), QuotaMeterPollingSignal(visible: true, pinned: true))
    }

    // MARK: Lid reopen

    func testAutomaticReturnsToBuiltinAfterScreenLoss() {
        let onExternal = CGRect(x: 2000, y: 900, width: 417, height: 200)
        // The strip left the built-in display because the lid closed; the window macOS moved
        // onto the external display must not keep the meter floating when the lid opens.
        XCTAssertEqual(QuotaMeterPlacementResolver.resolve(.automatic, screens: [builtin, external],
                                                           floatingFrame: onExternal, preferBuiltin: true),
                       .strip(screenID: 1))
        XCTAssertEqual(QuotaMeterPlacementResolver.resolve(.automatic, screens: [external],
                                                           floatingFrame: onExternal, preferBuiltin: true),
                       .floating)
        XCTAssertEqual(QuotaMeterPlacementResolver.resolve(.floating, screens: [builtin, external],
                                                           floatingFrame: onExternal, preferBuiltin: true),
                       .floating)
    }

    func testRunOutNeverChangesThePercentTone() {
        // Audit 2026-10-19: every projection the tracker publishes is before the reset, so a
        // red "will run out" percent was nearly always on. The chip carries the warning.
        let cell = QuotaStripCellBuilder.cell(input(five: 84, projection: "▸2h 5m"))
        XCTAssertEqual(cell.tone, .healthy)
        XCTAssertEqual(cell.chip, "▸2h")
    }

    func testChipOnlyBesideAFiveHourNumber() {
        // The weekly window is shown (less left); a 5h run-out next to it would read as "the
        // week runs out in 2h".
        let weekly = QuotaStripCellBuilder.cell(input(five: 60, week: 40, projection: "▸2h"))
        XCTAssertEqual(weekly.tag, "wk")
        XCTAssertNil(weekly.chip)
        XCTAssertEqual(QuotaStripCellBuilder.cell(input(five: 40, week: 60, projection: "▸2h")).chip, "▸2h")
    }

    func testChipIsTheFormattersLabelCutToItsFirstUnit() {
        // Same rounding as the panel ("▸2h 5m" there); the wing keeps the leading unit.
        XCTAssertEqual(QuotaStripCellBuilder.compactChip("▸2h 5m"), "▸2h")
        XCTAssertEqual(QuotaStripCellBuilder.compactChip("▸40m"), "▸40m")
        XCTAssertEqual(QuotaStripCellBuilder.compactChip("▸1d 3h"), "▸1d")
        XCTAssertEqual(QuotaStripCellBuilder.compactChip("▸<1m"), "▸<1m")
        // A stale projection reaches the builder as nil (the formatter drops it after 3 min).
        XCTAssertNil(QuotaStripCellBuilder.cell(input(five: 50, projection: nil)).chip)
    }

    func testFillFractionOnlyForNumbers() {
        XCTAssertEqual(QuotaStripCellBuilder.cell(input(five: 50)).fillFraction, 0.5)
        XCTAssertNil(QuotaStripCellBuilder.cell(input(.needsAction, five: 50)).fillFraction)
        var unlimited = input()
        unlimited.workingSessions = 2
        XCTAssertEqual(QuotaStripCellBuilder.cell(unlimited).activity, .none)
    }

    func testAgentActivityIsOneMarkPerWing() {
        // Owner 2026-10-19: agent-level in the strip, session detail in the panel.
        var i = input(five: 50)
        XCTAssertEqual(QuotaStripCellBuilder.cell(i).activity, .none)
        i.workingSessions = 3
        XCTAssertEqual(QuotaStripCellBuilder.cell(i).activity, .working)
        // A session that just finished is the user's turn, and that wins over working.
        i.finishedSessions = 1
        XCTAssertEqual(QuotaStripCellBuilder.cell(i).activity, .yourTurn)
        i.workingSessions = 0
        XCTAssertEqual(QuotaStripCellBuilder.cell(i).activity, .yourTurn)
    }

    func testActivityOnlyBesideLiveNumbers() {
        var signIn = input(.needsAction, five: 50)
        signIn.workingSessions = 2
        XCTAssertEqual(QuotaStripCellBuilder.cell(signIn).activity, .none)
    }

    func testHairlineFillFollowsTheShownPercent() {
        var used = input(five: 30)
        used.showsUsed = true
        let cell = QuotaStripCellBuilder.cell(used)
        XCTAssertEqual(cell.text, "70%")
        XCTAssertEqual(cell.fillFraction, 0.7)
        XCTAssertEqual(cell.tone, .healthy)
    }
}

final class QuotaMeterNotchIntroTests: XCTestCase {

    /// Defaults: not shown yet, audience ready, Codex sessions with tracking on, the Quota
    /// Meter on the desktop, nothing else on screen.
    private func input(alreadyShown: Bool = false,
                       audienceReady: Bool = true,
                       hasCodex: Bool = true,
                       hasClaude: Bool = false,
                       codexTracking: Bool = true,
                       claudeTracking: Bool = false,
                       resolvesToNotch: Bool = false,
                       notchHidden: Bool = false,
                       blockingSurfaceOpen: Bool = false,
                       quotaMeterCardOnScreen: Bool = false) -> NotchIntroInput {
        NotchIntroInput(alreadyShown: alreadyShown, audienceReady: audienceReady,
                        hasCodex: hasCodex, hasClaude: hasClaude,
                        codexTracking: codexTracking, claudeTracking: claudeTracking,
                        resolvesToNotch: resolvesToNotch, notchHidden: notchHidden,
                        blockingSurfaceOpen: blockingSurfaceOpen,
                        quotaMeterCardOnScreen: quotaMeterCardOnScreen)
    }

    func testDesktopUserGetsMoveToNotch() {
        XCTAssertEqual(QuotaMeterNotchIntro.variant(for: input()), .moveToNotch)
    }

    func testNotchUserGetsGotIt() {
        XCTAssertEqual(QuotaMeterNotchIntro.variant(for: input(resolvesToNotch: true)), .alreadyInNotch)
    }

    func testTrackingOffGetsTurnOn() {
        XCTAssertEqual(QuotaMeterNotchIntro.variant(for: input(codexTracking: false)), .turnOnTracking)
    }

    func testTrackingOffWinsOverNotch() {
        XCTAssertEqual(QuotaMeterNotchIntro.variant(for: input(codexTracking: false, resolvesToNotch: true)),
                       .turnOnTracking)
    }

    func testPartialTrackingIsTrackingOn() {
        XCTAssertEqual(QuotaMeterNotchIntro.variant(for: input(hasClaude: true, claudeTracking: false)), .moveToNotch)
    }

    func testUntrackedProviderUserLacksIsIgnored() {
        XCTAssertEqual(QuotaMeterNotchIntro.variant(for: input(hasCodex: false, hasClaude: true,
                                                               codexTracking: false, claudeTracking: true)),
                       .moveToNotch)
    }

    func testNoSessionsNeverShows() {
        XCTAssertNil(QuotaMeterNotchIntro.variant(for: input(hasCodex: false)))
    }

    func testAlreadyShownNeverShows() {
        XCTAssertNil(QuotaMeterNotchIntro.variant(for: input(alreadyShown: true)))
    }

    func testAudienceNotReadyDefers() {
        XCTAssertNil(QuotaMeterNotchIntro.variant(for: input(audienceReady: false)))
    }

    func testBlockingSurfaceDefers() {
        XCTAssertNil(QuotaMeterNotchIntro.variant(for: input(blockingSurfaceOpen: true)))
    }

    func testQuotaMeterCardOnScreenDefers() {
        XCTAssertNil(QuotaMeterNotchIntro.variant(for: input(quotaMeterCardOnScreen: true)))
    }

    func testHiddenNotchGetsUnhide() {
        XCTAssertEqual(QuotaMeterNotchIntro.variant(for: input(resolvesToNotch: true, notchHidden: true)), .unhideNotch)
    }

    func testHiddenNotchOnDesktopPlacementIsMoveToNotch() {
        XCTAssertEqual(QuotaMeterNotchIntro.variant(for: input(resolvesToNotch: false, notchHidden: true)), .moveToNotch)
    }

    func testHiddenNotchStillOffersTurnOn() {
        XCTAssertEqual(QuotaMeterNotchIntro.variant(for: input(codexTracking: false, notchHidden: true)), .turnOnTracking)
    }

    func testShownKeyIsStable() {
        XCTAssertEqual(QuotaMeterNotchIntro.shownKey, "QuotaMeterNotchIntroShown")
    }
}
