import XCTest
@testable import AgentSessions

final class TranscriptRenderGenerationGateTests: XCTestCase {
    func testGateAllowsCurrentGenerationAndSession() {
        var gate = TranscriptRenderGenerationGate()
        let generation = gate.begin()

        XCTAssertTrue(gate.allowsApply(candidateGeneration: generation,
                                       activeSessionID: "session-1",
                                       expectedSessionID: "session-1"))
    }

    func testGateRejectsStaleGeneration() {
        var gate = TranscriptRenderGenerationGate()
        let staleGeneration = gate.begin()
        _ = gate.begin()

        XCTAssertFalse(gate.allowsApply(candidateGeneration: staleGeneration,
                                        activeSessionID: "session-1",
                                        expectedSessionID: "session-1"))
    }

    func testGateRejectsSessionMismatch() {
        var gate = TranscriptRenderGenerationGate()
        let generation = gate.begin()

        XCTAssertFalse(gate.allowsApply(candidateGeneration: generation,
                                        activeSessionID: "session-2",
                                        expectedSessionID: "session-1"))
    }

    func testGateRejectsWhenActiveSessionIsNil() {
        var gate = TranscriptRenderGenerationGate()
        let generation = gate.begin()

        XCTAssertFalse(gate.allowsApply(candidateGeneration: generation,
                                        activeSessionID: nil,
                                        expectedSessionID: "session-1"))
    }

    func testGateRejectsPreviousGenerationAfterNewBegin() {
        var gate = TranscriptRenderGenerationGate()
        let firstGeneration = gate.begin()
        let secondGeneration = gate.begin()

        XCTAssertFalse(gate.allowsApply(candidateGeneration: firstGeneration,
                                        activeSessionID: "session-1",
                                        expectedSessionID: "session-1"))
        XCTAssertTrue(gate.allowsApply(candidateGeneration: secondGeneration,
                                       activeSessionID: "session-1",
                                       expectedSessionID: "session-1"))
    }
}

final class UnifiedSelectionPolicyTests: XCTestCase {
    func testPreservesSelectionWhenRowsTransientlyDropDuringIndexing() {
        XCTAssertTrue(
            UnifiedSelectionPolicy.shouldPreserveSelectionOnEmptyTableMutation(
                oldSelection: ["session-1"],
                newSelection: [],
                isProgrammaticUpdate: false,
                isIndexing: true,
                cachedRowCount: 0
            )
        )
    }

    func testPreservesSelectionWhenRowsAreTemporarilyEmpty() {
        XCTAssertTrue(
            UnifiedSelectionPolicy.shouldPreserveSelectionOnEmptyTableMutation(
                oldSelection: ["session-1"],
                newSelection: [],
                isProgrammaticUpdate: false,
                isIndexing: false,
                cachedRowCount: 0
            )
        )
    }

    func testDoesNotPreserveForUserDeselectWithRowsPresent() {
        XCTAssertFalse(
            UnifiedSelectionPolicy.shouldPreserveSelectionOnEmptyTableMutation(
                oldSelection: ["session-1"],
                newSelection: [],
                isProgrammaticUpdate: false,
                isIndexing: false,
                cachedRowCount: 5
            )
        )
    }
}
