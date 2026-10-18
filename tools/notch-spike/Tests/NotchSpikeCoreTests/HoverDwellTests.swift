import Testing
@testable import NotchSpikeCore

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
