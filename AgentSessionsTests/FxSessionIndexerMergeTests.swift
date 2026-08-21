import XCTest
@testable import AgentSessions

/// Guide §3.1 regression: a successful full reload is authoritative for every
/// branch-derived field. fx has no branches, but compaction rewrites
/// `state.history` in place — so the reloaded transcript can be *shorter* than
/// the row it replaces and carry a different title. Merging those fields with
/// `max` or current-first fallbacks would keep discarded history's metadata
/// beside the newly parsed transcript.
final class FxSessionIndexerMergeTests: XCTestCase {
    private func makeSession(eventCount: Int,
                             title: String?,
                             commands: Int?,
                             startTime: Date? = Date(timeIntervalSince1970: 100),
                             model: String? = "demo/model-1") -> Session {
        // `nonMetaCount` derives from the rendered events, so the fixture
        // carries one non-meta event per claimed count.
        let events = (0..<eventCount).map {
            SessionEvent(id: "\($0)", timestamp: nil, kind: .user, role: "user", text: nil,
                         toolName: nil, toolInput: nil, toolOutput: nil,
                         messageID: nil, parentID: nil, isDelta: false, rawJSON: "")
        }
        return Session(id: "fx-session",
                       source: .fx,
                       startTime: startTime,
                       endTime: Date(timeIntervalSince1970: 200),
                       model: model,
                       filePath: "/tmp/fx/fx-session/checkpoint.json",
                       eventCount: eventCount,
                       events: events,
                       cwd: "/tmp/alpha",
                       repoName: "alpha",
                       lightweightTitle: title,
                       lightweightCommands: commands)
    }

    /// Compaction shrank the transcript: the reloaded count must shrink with
    /// it, not ride `max` on the pre-compaction row.
    func testCompactedReloadShrinksEventCount() {
        let current = makeSession(eventCount: 40, title: "Pre-compaction title", commands: 12)
        let parsed = makeSession(eventCount: 6, title: "Post-compaction summary", commands: 1)

        let merged = FxSessionIndexer.mergedSession(parsed: parsed, current: current)

        XCTAssertEqual(merged.eventCount, 6)
    }

    /// A changed title follows the fresh parse; only a parse that could not
    /// produce one keeps the old row's.
    func testReloadTakesFreshTitleOverStaleTitle() {
        let current = makeSession(eventCount: 40, title: "Old first prompt", commands: nil)
        let renamed = makeSession(eventCount: 6, title: "New display.json title", commands: nil)
        XCTAssertEqual(FxSessionIndexer.mergedSession(parsed: renamed, current: current).lightweightTitle,
                       "New display.json title")

        let untitled = makeSession(eventCount: 6, title: nil, commands: nil)
        XCTAssertEqual(FxSessionIndexer.mergedSession(parsed: untitled, current: current).lightweightTitle,
                       "Old first prompt")
    }

    /// If compaction removed every tool turn, the fresh "command-free" verdict
    /// wins over the discarded history's command count.
    func testReloadDoesNotKeepDiscardedHistoryCommandCount() {
        let current = makeSession(eventCount: 40, title: nil, commands: 12)
        let parsed = makeSession(eventCount: 2, title: nil, commands: nil)

        let merged = FxSessionIndexer.mergedSession(parsed: parsed, current: current)

        XCTAssertNil(merged.lightweightCommands)
    }

    /// Values neither the checkpoint nor the reread sidecar carries survive a
    /// reload from the old row instead of being blanked.
    func testSidecarOnlyFactsSurviveAParseThatLostThem() {
        let current = makeSession(eventCount: 40, title: "Kept", commands: 3)
        let parsed = makeSession(eventCount: 4, title: "Kept", commands: 1,
                                 startTime: nil, model: nil)

        let merged = FxSessionIndexer.mergedSession(parsed: parsed, current: current)

        XCTAssertNotNil(merged.startTime)
        XCTAssertEqual(merged.model, "demo/model-1")
    }
}
