import XCTest
@testable import AgentSessions

/// End-to-end telemetry over the checked-in stage0 fixtures.
///
/// These fixtures are TRIMMED and REDACTED — the Claude one carries
/// `effort: "[trimmed for fixture]"`, a non-empty placeholder a correct
/// implementation scores as a real effort value. Pinning exact change counts here
/// would enshrine redaction artifacts as intent, so exact arithmetic is pinned by
/// the inline-JSONL unit tests and this file asserts INVARIANTS that must hold on
/// any real transcript, plus the handful of fixture values that are genuinely stable.
final class SessionTelemetryFixtureTests: XCTestCase {

    private func lines(_ relativePath: String) throws -> [String] {
        let url = FixturePaths.stage0FixtureURL(relativePath)
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private func assertUniversalInvariants(_ t: SessionTelemetry,
                                           file: StaticString = #filePath,
                                           line: UInt = #line) {
        // Carry-forward: a field going absent is never recorded as a change.
        for change in t.configurationChanges {
            XCTAssertNotNil(change.newValue, "a change to nil means absence was misread as a value",
                            file: file, line: line)
            XCTAssertFalse(change.newValue?.isEmpty ?? false, file: file, line: line)
        }
        // The summary must agree with the slices it summarizes.
        if let summary = t.usageSummary {
            let sliceTotal = t.usageSlices.reduce(0) { $0 + $1.topLineTokens }
            XCTAssertEqual(summary.topLineTokens, sliceTotal, file: file, line: line)
        }
        for slice in t.usageSlices {
            XCTAssertGreaterThanOrEqual(slice.topLineTokens, 0, file: file, line: line)
            XCTAssertLessThanOrEqual(slice.reasoningOutputTokens, slice.outputTokens,
                                     "reasoning is a subset of output", file: file, line: line)
        }
        // A dollar figure is either produced or explained — never silently absent.
        if let cost = t.costEstimate, cost.apiEquivalentUSD == nil {
            XCTAssertFalse(cost.unpricedModels.isEmpty && cost.missingPriceComponents.isEmpty
                           && t.usageSlices.contains { !$0.isEmpty },
                           "unpriced session with billable tokens must name a cause",
                           file: file, line: line)
        }
    }

    // MARK: - Codex

    func testCodexFixtureTelemetry() throws {
        let t = CodexTelemetryAccumulator.accumulate(lines: try lines("agents/codex/small.jsonl"))
        assertUniversalInvariants(t)

        XCTAssertEqual(t.source, .codex)
        XCTAssertNotNil(t.initialConfiguration)
        XCTAssertEqual(t.initialConfiguration?.provenance, .effectiveTurnContext)
        // The fixture's first epoch ends at the cumulative total published in the
        // record itself; this value is stable across redaction.
        XCTAssertEqual(t.usageSummary?.recordedTotalTokens, 16_422)
        XCTAssertEqual(t.usageSummary?.usageFamilies, ["token_count"])
        XCTAssertEqual(t.usageSummary?.usageFamilyConflict, false)
        XCTAssertTrue(t.usageSlices.allSatisfy { $0.speed == "standard" }, "Codex has no speed tiers")
    }

    // MARK: - Claude

    func testClaudeFixtureTelemetry() throws {
        let t = ClaudeTelemetryAccumulator.accumulate(lines: try lines("agents/claude/small.jsonl"))
        assertUniversalInvariants(t)

        XCTAssertEqual(t.source, .claude)
        XCTAssertEqual(t.initialConfiguration?.provenance, .inferredFirstObservation)
        XCTAssertEqual(t.usageSummary?.usageFamilies, ["message.usage"])
        XCTAssertEqual(t.usageSummary?.hasComponentBreakdown, true,
                       "without this the whole session is silently unpriceable")
    }

    /// The fixture contains two `<synthetic>` error placeholders. Counting them
    /// yields two phantom model changes each.
    func testClaudeFixtureExcludesSyntheticModel() throws {
        let t = ClaudeTelemetryAccumulator.accumulate(lines: try lines("agents/claude/small.jsonl"))
        XCTAssertFalse(t.usageSlices.contains { $0.model == "<synthetic>" })
        XCTAssertFalse(t.configurationChanges.contains { $0.newValue == "<synthetic>" || $0.oldValue == "<synthetic>" })
        XCTAssertNotEqual(t.initialConfiguration?.model, "<synthetic>")
        XCTAssertNotEqual(t.currentConfiguration?.model, "<synthetic>")
    }

    /// The fixture's three `isSidechain: true` records are exactly the ones carrying
    /// an effort with no model — they must not open the parent's timeline.
    func testClaudeFixtureSidechainRecordsStayOutOfTimeline() throws {
        let all = try lines("agents/claude/small.jsonl")
        let t = ClaudeTelemetryAccumulator.accumulate(lines: all)

        let sidechainModels: Set<String> = Set(all.compactMap { line -> String? in
            guard let obj = ClaudeRunwayLog.jsonObject(line),
                  (obj["isSidechain"] as? Bool) == true,
                  let message = obj["message"] as? [String: Any],
                  let model = message["model"] as? String else { return nil }
            return model
        })
        for model in sidechainModels {
            XCTAssertNotEqual(t.initialConfiguration?.model, model)
            XCTAssertFalse(t.configurationChanges.contains { $0.newValue == model })
        }
    }

    /// Real transcripts are read through JSONLReader, which drops blank lines; the
    /// fixture read here keeps them. Both must produce the same numbers, since
    /// blank lines carry no records.
    func testBlankLinesDoNotChangeTotals() throws {
        let raw = try lines("agents/claude/small.jsonl")
        let compact = raw.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let a = ClaudeTelemetryAccumulator.accumulate(lines: raw)
        let b = ClaudeTelemetryAccumulator.accumulate(lines: compact)
        XCTAssertEqual(a.usageSlices, b.usageSlices)
        XCTAssertEqual(a.configurationChanges.count, b.configurationChanges.count)
    }
}
