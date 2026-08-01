import XCTest

// The LogicTests target compiles app sources directly rather than importing the
// app module (see SessionFilterShims.swift). ClaudeCloud sources depend only on
// Foundation, so they join this target without shims.

final class ClaudeCloudAPIClientTests: XCTestCase {

    // MARK: - HTTP mapping

    func test_mapHTTP_401_isExpired() {
        XCTAssertEqual(ClaudeCloudAPIClient.mapHTTP(401, retryAfter: nil), .expired)
    }

    func test_mapHTTP_429_parsesRetryAfterSeconds() throws {
        guard case .rateLimited(let until)? = ClaudeCloudAPIClient.mapHTTP(429, retryAfter: "120") else {
            return XCTFail("expected rateLimited")
        }
        let deadline = try XCTUnwrap(until)
        XCTAssertGreaterThan(deadline.timeIntervalSinceNow, 60)
    }

    func test_mapHTTP_429_withoutRetryAfterStillRateLimited() {
        XCTAssertEqual(ClaudeCloudAPIClient.mapHTTP(429, retryAfter: nil), .rateLimited(until: nil))
    }

    /// Regression: a 403 must not be terminal. `.expired` clears the row list, and an
    /// edge 403 is not proof the cookie died — treating it as terminal made rows
    /// vanish and reappear on the next poll.
    func test_mapHTTP_403_isTransientNotExpired() {
        let mapped = ClaudeCloudAPIClient.mapHTTP(403, retryAfter: nil)
        XCTAssertEqual(mapped, .offline)
        XCTAssertNotEqual(mapped, .expired, "403 must not clear the session list")
    }

    func test_mapHTTP_200_isNil() {
        XCTAssertNil(ClaudeCloudAPIClient.mapHTTP(200, retryAfter: nil))
    }

    func test_mapHTTP_500_isContractDrift() {
        guard case .contractDrift? = ClaudeCloudAPIClient.mapHTTP(500, retryAfter: nil) else {
            return XCTFail("expected contractDrift")
        }
    }

    // MARK: - List decoding

    private let onePage = """
    {"data":[{"id":"cse_a","title":"PingCraft game design prototype","status":"active",
              "status_bucket":"working","worker_status":"running",
              "connection_status":"connected","environment_kind":"anthropic_cloud",
              "unread":1,"last_event_at":"2026-08-01T02:19:02.357615Z"}],
     "next_cursor":"abc","resume_token":"r"}
    """.data(using: .utf8)!

    func test_decodeList_readsEnvelopeAndCursor() throws {
        let out = try ClaudeCloudAPIClient.decodeList(onePage)
        XCTAssertEqual(out.nextCursor, "abc")
        XCTAssertEqual(out.rows.count, 1)
        let row = try XCTUnwrap(out.rows.first)
        XCTAssertEqual(row.id, "cse_a")
        XCTAssertEqual(row.title, "PingCraft game design prototype")
        XCTAssertEqual(row.workerStatus, "running")
        XCTAssertEqual(row.environmentKind, "anthropic_cloud")
        XCTAssertEqual(row.unread, 1)
    }

    func test_decodeList_parsesFractionalSecondTimestamps() throws {
        let row = try XCTUnwrap(try ClaudeCloudAPIClient.decodeList(onePage).rows.first)
        XCTAssertNotNil(row.lastEventAt, "last_event_at carries fractional seconds and must parse")
    }

    func test_parseTimestamp_acceptsNonFractionalForm() {
        XCTAssertNotNil(ClaudeCloudAPIClient.parseTimestamp("2026-08-01T02:19:02Z"))
    }

    func test_decodeList_skipsRowsWithoutIdInsteadOfFailingBatch() throws {
        let json = #"{"data":[{"id":"cse_ok"},{"no_id":true}],"next_cursor":null}"#.data(using: .utf8)!
        let out = try ClaudeCloudAPIClient.decodeList(json)
        XCTAssertEqual(out.rows.map(\.id), ["cse_ok"])
        XCTAssertNil(out.nextCursor)
    }

    func test_decodeList_emptyPageIsNotDrift() throws {
        let json = #"{"data":[],"next_cursor":null}"#.data(using: .utf8)!
        let out = try ClaudeCloudAPIClient.decodeList(json)
        XCTAssertTrue(out.rows.isEmpty)
    }

    func test_decodeList_unrecognisedEnvelopeThrowsContractDrift() {
        let json = #"{"unexpected":"envelope"}"#.data(using: .utf8)!
        XCTAssertThrowsError(try ClaudeCloudAPIClient.decodeList(json)) { error in
            guard case ClaudeCloudError.contractDrift = error else {
                return XCTFail("expected contractDrift, got \(error)")
            }
        }
    }

    func test_decodeList_pageOfUndecodableRowsThrowsContractDrift() {
        // A whole page where nothing carries an id means the row shape changed —
        // that must surface as drift, not as a silently empty list.
        let json = #"{"data":[{"a":1},{"b":2}],"next_cursor":null}"#.data(using: .utf8)!
        XCTAssertThrowsError(try ClaudeCloudAPIClient.decodeList(json)) { error in
            guard case ClaudeCloudError.contractDrift = error else {
                return XCTFail("expected contractDrift, got \(error)")
            }
        }
    }
}
