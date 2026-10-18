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

@Test func offsetScreenUsesAuxWidthsNotOrigins() throws {
    // Built-in display right of a main external display; aux rects in screen-local x.
    let screen = CGRect(x: 2560, y: 0, width: 1512, height: 982)
    let l = try #require(SpikeGeometry.layout(screenFrame: screen, safeAreaTop: 32, auxLeft: left14, auxRight: right14))
    #expect(l.notch == CGRect(x: 3224, y: 950, width: 184, height: 32))
    #expect(l.leftWing.minX == 3129)
}

let lg = CGRect(x: 0, y: 0, width: 2560, height: 1440)

@Test func virtualNotchIsCentredInTheMenuBar() {
    let l = SpikeGeometry.virtualLayout(screenFrame: lg, menuBarHeight: 25)
    #expect(l.notch == CGRect(x: 1268, y: 1415, width: 24, height: 25))
    #expect(l.sensor == l.notch)
    #expect(l.leftWing == CGRect(x: 1173, y: 1415, width: 95, height: 25))
    #expect(l.rightWing == CGRect(x: 1292, y: 1415, width: 95, height: 25))
    #expect(l.dropPanel == CGRect(x: 970, y: 1225, width: 620, height: 190))
}

@Test func virtualNotchFallsBackWhenMenuBarAutoHides() {
    let l = SpikeGeometry.virtualLayout(screenFrame: lg, menuBarHeight: 0)
    #expect(l.notch == CGRect(x: 1268, y: 1416, width: 24, height: 24))
}
