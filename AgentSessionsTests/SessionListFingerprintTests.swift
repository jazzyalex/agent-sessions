import XCTest
@testable import AgentSessions

/// W7 Task 2b review follow-up: `AgentCockpitHUDDerivedStateModel`'s
/// `$allSessions` sinks skip the `sessionsGeneration` bump +
/// `rebuildLookupIndexes()` + `scheduleRebuild()` chain whenever
/// `SessionListFingerprint` of the incoming array equals the stored one.
/// These tests pin that skip/bump decision: equal fingerprints == the sink
/// skips; unequal == the sink rebuilds. The fingerprint must therefore change
/// for EVERY input `makeRowsSnapshot` renders — including the title inputs
/// (`customTitle`/`lightweightTitle`/`events.isEmpty`) and projectLabel inputs
/// (`lightweightRepoName`/`lightweightCwd`) that metadata repairs like
/// `ClaudeSessionIndexer.fixupHydratedClaudeMetadataIfNeeded` rewrite while
/// id/modifiedAt/eventCount stay identical.
final class SessionListFingerprintTests: XCTestCase {

    private let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeEvent(id: String) -> SessionEvent {
        SessionEvent(id: id, timestamp: nil, kind: .user, role: "user", text: "hello",
                     toolName: nil, toolInput: nil, toolOutput: nil, messageID: nil,
                     parentID: nil, isDelta: false, rawJSON: "{}")
    }

    private func makeSession(
        id: String = "s1",
        modifiedAt: Date? = nil,
        eventCount: Int = 1,
        events: [SessionEvent] = [],
        lightweightCwd: String? = "/tmp/proj",
        lightweightRepoName: String? = "proj",
        lightweightTitle: String? = "Original title",
        customTitle: String? = nil
    ) -> Session {
        let date = modifiedAt ?? baseDate
        return Session(
            id: id,
            source: .claude,
            startTime: date,
            endTime: date,
            model: "test-model",
            filePath: "/tmp/\(id).jsonl",
            fileSizeBytes: 1024,
            eventCount: eventCount,
            events: events,
            cwd: lightweightCwd,
            repoName: lightweightRepoName,
            lightweightTitle: lightweightTitle,
            customTitle: customTitle
        )
    }

    // (i) Content-identical republish: the sink must skip (no generation bump,
    // no lookup rebuild) — equal fingerprints are the skip signal.
    func testContentIdenticalRepublishProducesEqualFingerprint() {
        let sessions = [makeSession(id: "a"), makeSession(id: "b")]
        // A distinct-but-identical array (what a copy-on-write whole-array
        // reassignment republish delivers).
        let republished = sessions.map { $0 }
        XCTAssertEqual(SessionListFingerprint(sessions), SessionListFingerprint(republished))
    }

    // (ii) Real deltas: membership, order, modifiedAt, and eventCount changes
    // must all produce a different fingerprint (the sink rebuilds).
    func testMembershipOrderFreshnessDeltasChangeFingerprint() {
        let base = [makeSession(id: "a"), makeSession(id: "b")]
        let fp = SessionListFingerprint(base)

        XCTAssertNotEqual(fp, SessionListFingerprint([makeSession(id: "a")]),
                          "membership change (removal) must rebuild")
        XCTAssertNotEqual(fp, SessionListFingerprint(base + [makeSession(id: "c")]),
                          "membership change (addition) must rebuild")
        XCTAssertNotEqual(fp, SessionListFingerprint([makeSession(id: "b"), makeSession(id: "a")]),
                          "order change must rebuild")
        XCTAssertNotEqual(
            fp,
            SessionListFingerprint([makeSession(id: "a", modifiedAt: baseDate.addingTimeInterval(60)), makeSession(id: "b")]),
            "modifiedAt change must rebuild"
        )
        XCTAssertNotEqual(
            fp,
            SessionListFingerprint([makeSession(id: "a", eventCount: 2), makeSession(id: "b")]),
            "eventCount change must rebuild"
        )
    }

    // (iii) Title-only republish (the review NIT): fixupHydratedClaudeMetadataIfNeeded
    // repairs lightweightTitle while explicitly preserving id/modifiedAt/eventCount,
    // and its own `changed` guard means it republishes EXACTLY when the title
    // changed. The fingerprint must catch it or the HUD shows a stale title with
    // no self-heal (the 5s stale-reclassify rebuild re-reads the stored array,
    // which the skip also left stale).
    func testTitleOnlyRepublishChangesFingerprint() {
        let fp = SessionListFingerprint([makeSession()])

        XCTAssertNotEqual(
            fp,
            SessionListFingerprint([makeSession(lightweightTitle: "Repaired title")]),
            "lightweightTitle repair must rebuild"
        )
        XCTAssertNotEqual(
            fp,
            SessionListFingerprint([makeSession(customTitle: "Renamed via /rename")]),
            "customTitle change must rebuild"
        )
    }

    // (iii) continued: lightweight→full hydration merge can keep eventCount
    // (max(...)) and modifiedAt identical while events goes empty→populated,
    // which flips Session.title's computation branch.
    func testHydrationEventsEmptinessFlipChangesFingerprint() {
        let lightweight = makeSession(eventCount: 3, events: [])
        let hydrated = makeSession(eventCount: 3, events: [makeEvent(id: "e1"), makeEvent(id: "e2"), makeEvent(id: "e3")])
        XCTAssertNotEqual(SessionListFingerprint([lightweight]), SessionListFingerprint([hydrated]),
                          "events empty→populated must rebuild (title branch flips)")
    }

    // (iii) continued: projectLabel inputs drift the same way — the Claude
    // metadata repair rebuilds the Session with repoName: nil and cwd from
    // lightweightCwd, so lightweightRepoName/lightweightCwd changes must rebuild.
    func testProjectLabelInputChangesChangeFingerprint() {
        let fp = SessionListFingerprint([makeSession()])

        XCTAssertNotEqual(
            fp,
            SessionListFingerprint([makeSession(lightweightRepoName: nil)]),
            "lightweightRepoName drop (metadata repair) must rebuild"
        )
        XCTAssertNotEqual(
            fp,
            SessionListFingerprint([makeSession(lightweightCwd: "/tmp/other-proj")]),
            "lightweightCwd change must rebuild"
        )
    }
}
