import Testing
import Foundation
@testable import NotchSpikeCore

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
