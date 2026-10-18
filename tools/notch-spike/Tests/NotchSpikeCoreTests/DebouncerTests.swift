import Testing
import Foundation
@testable import NotchSpikeCore

@Test func debouncerCoalescesBursts() {
    var pending: [(TimeInterval, () -> Void)] = []
    let d = Debouncer(delay: 0.5) { delay, fire in pending.append((delay, fire)) }
    var runs = 0
    d.call { runs += 1 }; d.call { runs += 1 }; d.call { runs += 1 }
    pending.forEach { $0.1() }
    #expect(runs == 1)
    #expect(pending.allSatisfy { $0.0 == 0.5 })
}
