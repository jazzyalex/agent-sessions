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

    private func input(_ state: StripCellInput.State = .live, five: Int? = nil, week: Int? = nil,
                       runout: TimeInterval? = nil, reset: TimeInterval? = nil) -> StripCellInput {
        StripCellInput(state: state, fiveHourLeft: five, weekLeft: week,
                       projectedRunout: runout.map { now.addingTimeInterval($0) },
                       fiveHourResetAt: reset.map { now.addingTimeInterval($0) }, now: now)
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
        XCTAssertNil(fiveHour.tag)
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
        var i = input(five: 50, runout: 40 * 60)
        i.showsProjection = false
        XCTAssertNil(QuotaStripCellBuilder.cell(i).chip)
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

    func testCellChip() {
        XCTAssertEqual(QuotaStripCellBuilder.cell(input(five: 50, runout: 40 * 60)).chip, "▸40m")
        XCTAssertEqual(QuotaStripCellBuilder.cell(input(five: 50, runout: 130 * 60)).chip, "▸2h")
        XCTAssertTrue(QuotaStripCellBuilder.cell(input(five: 50, runout: 40 * 60, reset: 90 * 60)).chipWarns)
        XCTAssertFalse(QuotaStripCellBuilder.cell(input(five: 50, runout: 40 * 60, reset: 20 * 60)).chipWarns)
        XCTAssertNil(QuotaStripCellBuilder.cell(input(five: 50, runout: -60)).chip)
    }
}
