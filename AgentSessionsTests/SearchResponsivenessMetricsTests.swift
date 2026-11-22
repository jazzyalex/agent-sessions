import Foundation
import XCTest
@testable import AgentSessions

final class SearchResponsivenessMetricsTests: XCTestCase {
    private func enabledInvocation() -> SearchResponsivenessBenchmarkInvocation {
        SearchResponsivenessBenchmarkInvocation(
            arguments: [SearchResponsivenessBenchmarkInvocation.argument],
            environment: [:])
    }

    func testRecorderRequiresExactExplicitBenchmarkOptIn() throws {
        XCTAssertFalse(SearchResponsivenessBenchmarkInvocation(arguments: [], environment: [:]).isEnabled)
        XCTAssertFalse(SearchResponsivenessBenchmarkInvocation(
            arguments: ["--benchmark-search-responsiveness=1"],
            environment: [:]).isEnabled)
        XCTAssertFalse(SearchResponsivenessBenchmarkInvocation(
            arguments: [],
            environment: [SearchResponsivenessBenchmarkInvocation.environmentKey: "true"]).isEnabled)
        XCTAssertTrue(enabledInvocation().isEnabled)
        XCTAssertTrue(SearchResponsivenessBenchmarkInvocation(
            arguments: [],
            environment: [SearchResponsivenessBenchmarkInvocation.environmentKey: "1"]).isEnabled)

        let clock = LockedMetricClock([42])
        let disabled = SearchResponsivenessMetrics(
            invocation: SearchResponsivenessBenchmarkInvocation(arguments: [], environment: [:]),
            now: { clock.next() })
        disabled.record(.discovery)
        XCTAssertNil(disabled.newOperationID())
        XCTAssertNil(disabled.beginSpan(.discovery))
        XCTAssertTrue(disabled.eventsSnapshot.isEmpty)
        XCTAssertEqual(clock.readCount, 0)

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("disabled-search-responsiveness-\(UUID().uuidString).jsonl")
        XCTAssertThrowsError(try disabled.export(to: output)) { error in
            XCTAssertEqual(error as? SearchResponsivenessMetrics.ExportError, .disabled)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testSpansPairByOperationAndPreserveEndCancelAndErrorDurations() {
        let clock = LockedMetricClock([100, 125, 130, 145, 150, 177])
        let recorder = SearchResponsivenessMetrics(invocation: enabledInvocation(), now: { clock.next() })

        let parent = recorder.newOperationID()!
        let discovery = recorder.beginSpan(.discovery, parentID: parent)!
        recorder.end(discovery)
        let tailRead = recorder.beginSpan(.tailRead, parentID: parent)!
        recorder.cancel(tailRead)
        let fullRead = recorder.beginSpan(.fullReadDecode, parentID: parent)!
        recorder.fail(fullRead, code: .decodeError)

        let events = recorder.eventsSnapshot
        XCTAssertEqual(events.map(\.phase), [.begin, .end, .begin, .cancel, .begin, .error])
        XCTAssertEqual(events[0].operationID, events[1].operationID)
        XCTAssertEqual(events[2].operationID, events[3].operationID)
        XCTAssertEqual(events[4].operationID, events[5].operationID)
        XCTAssertEqual(events.map(\.parentID), Array(repeating: Optional(parent.rawValue), count: 6))
        XCTAssertEqual(events[1].durationNanoseconds, 25)
        XCTAssertEqual(events[3].durationNanoseconds, 15)
        XCTAssertEqual(events[5].durationNanoseconds, 27)
        XCTAssertEqual(events[3].status, .cancelled)
        XCTAssertEqual(events[5].failureCode, .decodeError)
        XCTAssertEqual(clock.readCount, 6)
    }

    func testMissingStagesAreExplicitAndHaveNoDuration() throws {
        let clock = LockedMetricClock([500])
        let recorder = SearchResponsivenessMetrics(invocation: enabledInvocation(), now: { clock.next() })
        recorder.recordMissing(.findReady, reason: .notRequested)

        let event = try XCTUnwrap(recorder.eventsSnapshot.first)
        XCTAssertEqual(event.stage, .findReady)
        XCTAssertEqual(event.phase, .missing)
        XCTAssertEqual(event.status, .notRequested)
        XCTAssertNil(event.durationNanoseconds)

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any])
        XCTAssertTrue(json["duration_ns"] is NSNull)
        XCTAssertEqual(json["hydration_completeness"] as? String, "not_applicable")
        XCTAssertTrue(json["session_identity"] is NSNull)
    }

    func testFirstContentRejectsStaleIdentityOrRevision() {
        let recorder = SearchResponsivenessMetrics(
            invocation: enabledInvocation(),
            now: { 900 })
        let selected = context(
            source: "SOURCE_SECRET",
            sessionID: "SESSION_SECRET",
            contentRevision: "CONTENT_REVISION_SECRET",
            storageRevision: "STORAGE_REVISION_SECRET",
            hydration: .provisional,
            generation: 4)
        let priorSession = context(
            source: "SOURCE_SECRET",
            sessionID: "PRIOR_SESSION_SECRET",
            contentRevision: "CONTENT_REVISION_SECRET",
            storageRevision: "STORAGE_REVISION_SECRET",
            hydration: .provisional,
            generation: 3)
        let staleRevision = context(
            source: "SOURCE_SECRET",
            sessionID: "SESSION_SECRET",
            contentRevision: "OLD_CONTENT_REVISION_SECRET",
            storageRevision: "STORAGE_REVISION_SECRET",
            hydration: .provisional,
            generation: 3)
        let currentPresentation = context(
            source: "SOURCE_SECRET",
            sessionID: "SESSION_SECRET",
            contentRevision: "CONTENT_REVISION_SECRET",
            storageRevision: "STORAGE_REVISION_SECRET",
            hydration: .provisional,
            generation: 5)

        recorder.record(.firstContentVisible, context: selected)
        XCTAssertNil(recorder.beginSpan(.firstContentVisible, context: selected))
        XCTAssertTrue(recorder.eventsSnapshot.isEmpty)
        XCTAssertFalse(recorder.recordFirstContentVisible(selected: selected, presented: priorSession))
        XCTAssertFalse(recorder.recordFirstContentVisible(selected: selected, presented: staleRevision))
        XCTAssertTrue(recorder.recordFirstContentVisible(selected: selected, presented: currentPresentation))
        XCTAssertEqual(recorder.eventsSnapshot.map(\.stage), [
            .staleContentRejected,
            .staleContentRejected,
            .firstContentVisible
        ])
    }

    func testSelectionOperationsAndUnhydratedContentCannotClaimPaint() {
        let recorder = SearchResponsivenessMetrics(invocation: enabledInvocation())
        let a = recorder.operation(source: "test", sessionID: "a", start: true)
        XCTAssertTrue(recorder.isCurrentSelection(a))
        let b = recorder.operation(source: "test", sessionID: "b", start: true)
        XCTAssertFalse(recorder.isCurrentSelection(a))
        XCTAssertTrue(recorder.isCurrentSelection(b))
        let again = recorder.operation(source: "test", sessionID: "a", start: true)
        XCTAssertNotEqual(a, again)
        let empty = context(source: "test", sessionID: "a", contentRevision: "r", storageRevision: "s",
                            hydration: .notRequested, generation: 1)
        XCTAssertFalse(recorder.recordFirstContentVisible(selected: empty, presented: empty))
        let partial = context(source: "test", sessionID: "a", contentRevision: "r", storageRevision: "s",
                              hydration: .provisional, generation: 1)
        XCTAssertFalse(recorder.recordVisibleContent(.fullContentVisible, selected: partial, presented: partial))
        recorder.clearSelection()
        XCTAssertFalse(recorder.isCurrentSelection(again))
    }

    func testExportContainsOnlyOpaqueOwnersAndHonorsRecorderBound() throws {
        let clock = LockedMetricClock([1, 2, 3, 4])
        let recorder = SearchResponsivenessMetrics(
            invocation: enabledInvocation(),
            now: { clock.next() },
            maximumEventCount: 4)
        let owner = context(
            source: "SOURCE_SECRET",
            sessionID: "SESSION_SECRET",
            contentRevision: "/private/path/CONTENT_REVISION_SECRET",
            storageRevision: "STORAGE_REVISION_SECRET",
            hydration: .full,
            generation: 12)

        let span = try XCTUnwrap(recorder.beginSpan(.searchMatching, context: owner))
        recorder.record(.searchScanStarted, context: owner)
        XCTAssertNil(recorder.beginSpan(.searchExtraction, context: owner))
        recorder.end(span)
        recorder.record(.searchTerminal, context: owner)
        recorder.record(.searchCoverageCounters, context: owner)

        XCTAssertEqual(recorder.eventsSnapshot.count, 4)
        XCTAssertEqual(recorder.droppedEventCountSnapshot, 2)
        XCTAssertEqual(recorder.eventsSnapshot.map(\.droppedEventCount), [2, 2, 2, 2])
        XCTAssertEqual(recorder.eventsSnapshot[0].operationID, recorder.eventsSnapshot[2].operationID)

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("search-responsiveness-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: output) }
        try recorder.export(to: output)

        let exported = try String(contentsOf: output, encoding: .utf8)
        XCTAssertFalse(exported.contains("SOURCE_SECRET"))
        XCTAssertFalse(exported.contains("SESSION_SECRET"))
        XCTAssertFalse(exported.contains("CONTENT_REVISION_SECRET"))
        XCTAssertFalse(exported.contains("STORAGE_REVISION_SECRET"))
        XCTAssertFalse(exported.contains("/private/path"))
        XCTAssertTrue(exported.contains("\"session_identity\""))
        XCTAssertTrue(exported.contains("\"timestamp_ns\""))
    }

    private func context(
        source: String,
        sessionID: String,
        contentRevision: String,
        storageRevision: String,
        hydration: SearchResponsivenessHydration,
        generation: Int64
    ) -> SearchResponsivenessMetricContext {
        SearchResponsivenessMetricContext(
            session: SearchResponsivenessSessionIdentity(source: source, sessionID: sessionID),
            contentRevision: SearchResponsivenessRevision(contentRevision),
            storageRevision: SearchResponsivenessRevision(storageRevision),
            hydration: hydration,
            presentationGeneration: generation,
            credentialEpoch: 7)
    }
}

private final class LockedMetricClock: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UInt64]
    private var _readCount = 0

    var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _readCount
    }

    init(_ values: [UInt64]) {
        self.values = values
    }

    func next() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        _readCount += 1
        guard !values.isEmpty else { return 0 }
        return values.removeFirst()
    }
}
