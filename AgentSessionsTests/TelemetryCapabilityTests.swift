import XCTest
@testable import AgentSessions

/// Every source must state, explicitly, what telemetry it can and cannot produce.
/// The field is non-optional on `SessionSourceDescriptor` so the compiler forces a
/// declaration for each of the 15 sources — a new source cannot silently inherit
/// "no telemetry" and then be mistaken for a source that was audited and found
/// wanting.
final class TelemetryCapabilityTests: XCTestCase {

    func testEverySourceDeclaresCapabilities() {
        XCTAssertEqual(SessionSource.allCases.count, 15,
                       "A source was added or removed — update the telemetry capability table too")
        for source in SessionSource.allCases {
            _ = SessionSourceRegistry.descriptor(for: source).telemetry
        }
    }

    // An `unavailable`/`partial` verdict without a reason is the failure this whole
    // type exists to prevent: it reads identically to "not audited yet".
    func testAllSourcesDeclareNonEmptyReasons() {
        for source in SessionSource.allCases {
            let t = SessionSourceRegistry.descriptor(for: source).telemetry
            for cap in [t.configuration, t.tokens, t.cost, t.weeklyQuota] {
                if case .unavailable(let reason) = cap {
                    XCTAssertFalse(reason.isEmpty, "\(source) declares an unavailable with no reason")
                }
                if case .partial(let reason) = cap {
                    XCTAssertFalse(reason.isEmpty, "\(source) declares a partial with no reason")
                }
            }
        }
    }

    /// The sources wired to an accumulator. Everything else must remain unavailable
    /// even after an audit proves that its store has no usable telemetry.
    private static let dispatchableSources: Set<SessionSource> = [.codex, .claude, .pi, .copilot]

    func testNonDispatchableSourcesDeclareNothingAvailable() {
        for source in SessionSource.allCases where !Self.dispatchableSources.contains(source) {
            let t = SessionSourceRegistry.descriptor(for: source).telemetry
            for cap in [t.configuration, t.tokens, t.cost, t.weeklyQuota] {
                guard case .unavailable = cap else {
                    return XCTFail("\(source) must be unavailable until its format is audited")
                }
            }
        }
    }

    /// Every source the engine can actually dispatch must declare it, and vice
    /// versa — a mismatch means either dead code or a silently ignored source.
    func testSupportedSourcesDeclareConfigurationAndTokens() {
        for source in Self.dispatchableSources {
            let t = SessionSourceRegistry.descriptor(for: source).telemetry
            if case .unavailable = t.configuration {
                XCTFail("\(source) must produce a configuration timeline")
            }
            if case .unavailable = t.tokens {
                XCTFail("\(source) must produce token usage")
            }
        }
    }

    func testDevinRecordsAuditedNegativeTelemetryEvidence() {
        let telemetry = SessionSourceRegistry.descriptor(for: .devin).telemetry
        XCTAssertEqual(
            telemetry.configuration,
            .unavailable("session rows expose only scalar model/mode; no configuration timeline")
        )
        XCTAssertEqual(
            telemetry.tokens,
            .unavailable("3000.6.7 audit: num_tokens is always null; num_tokens_preceding is a context cursor")
        )
        XCTAssertEqual(
            telemetry.cost,
            .unavailable("3000.6.7 audit: cogs_json is configuration and recorded cost fields are always zero")
        )
        XCTAssertEqual(telemetry.weeklyQuota, .unavailable("no account-level quota feed"))
    }

    // Weekly-quota attribution needs persisted account quota snapshots, which no
    // source has yet. Plan B adds the store; until then every source says so.
    func testWeeklyQuotaIsUnavailableEverywhereInPlanA() {
        for source in SessionSource.allCases {
            let cap = SessionSourceRegistry.descriptor(for: source).telemetry.weeklyQuota
            guard case .unavailable = cap else {
                return XCTFail("\(source) weeklyQuota must be unavailable until Plan B")
            }
        }
    }

}
