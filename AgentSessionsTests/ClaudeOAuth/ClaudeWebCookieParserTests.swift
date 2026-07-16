import XCTest
@testable import AgentSessions

/// Fixture tests for the Safari `Cookies.binarycookies` parser, exercising the
/// typed `ReadOutcome` cases the honesty fix introduces.
///
/// Provenance: the fixtures are built by `BinaryCookieFixture`, a byte-accurate
/// encoder of the documented macOS binarycookies layout (file header big-endian;
/// pages/records little-endian; url/name/path/value offsets at 16/20/24/28;
/// expiry float64 LE at 40, Apple-2001 epoch). Every cookie VALUE is fake — we
/// never embed (or read) a real session secret. This locks the parser's byte
/// offsets AND the typed outcomes without touching the user's real cookie store.
final class ClaudeWebCookieParserTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private var future: Date { now.addingTimeInterval(86_400) }
    private var past: Date { now.addingTimeInterval(-86_400) }

    // MARK: - found

    func testLiveClaudeSessionKey_isFound() {
        let data = BinaryCookieFixture.file(pages: [[
            .init(domain: ".claude.ai", name: "sessionKey", path: "/", value: "FAKE-live-token", expires: future),
        ]])
        let result = ClaudeWebCookieResolver.parseCookieData(data, now: now)
        XCTAssertEqual(result.outcome, .found(.init(sessionKey: "FAKE-live-token")))
        XCTAssertTrue(result.diagnostics.magicOK)
        XCTAssertEqual(result.diagnostics.claudeAiCookies, 1)
        XCTAssertEqual(result.diagnostics.sessionKeyMatches, 1)
        XCTAssertFalse(result.diagnostics.expiredMatch)
    }

    func testBareClaudeAiDomain_isFound() {
        let data = BinaryCookieFixture.file(pages: [[
            .init(domain: "claude.ai", name: "sessionKey", path: "/", value: "FAKE-bare", expires: future),
        ]])
        XCTAssertEqual(ClaudeWebCookieResolver.parseCookieData(data, now: now).outcome,
                       .found(.init(sessionKey: "FAKE-bare")))
    }

    // MARK: - validStoreNoCookie

    func testValidStore_otherDomainsOnly_isValidStoreNoCookie() {
        let data = BinaryCookieFixture.file(pages: [[
            .init(domain: ".github.com", name: "sessionKey", path: "/", value: "FAKE-gh", expires: future),
            .init(domain: ".example.com", name: "sid", path: "/", value: "FAKE-ex", expires: future),
        ]])
        let result = ClaudeWebCookieResolver.parseCookieData(data, now: now)
        XCTAssertEqual(result.outcome, .validStoreNoCookie)
        XCTAssertEqual(result.diagnostics.totalCookies, 2)
        XCTAssertEqual(result.diagnostics.claudeAiCookies, 0)
    }

    func testValidStore_claudeButNotSessionKey_isValidStoreNoCookie() {
        let data = BinaryCookieFixture.file(pages: [[
            .init(domain: ".claude.ai", name: "lastActiveOrg", path: "/", value: "FAKE-org", expires: future),
        ]])
        let result = ClaudeWebCookieResolver.parseCookieData(data, now: now)
        XCTAssertEqual(result.outcome, .validStoreNoCookie)
        XCTAssertEqual(result.diagnostics.claudeAiCookies, 1)
        XCTAssertEqual(result.diagnostics.sessionKeyMatches, 0)
    }

    func testValidHeaderNoPages_isValidStoreNoCookie() {
        let data = BinaryCookieFixture.file(pages: [])
        XCTAssertEqual(ClaudeWebCookieResolver.parseCookieData(data, now: now).outcome, .validStoreNoCookie)
    }

    // MARK: - cookieExpired

    func testExpiredClaudeSessionKey_isCookieExpired() {
        let data = BinaryCookieFixture.file(pages: [[
            .init(domain: ".claude.ai", name: "sessionKey", path: "/", value: "FAKE-stale", expires: past),
        ]])
        let result = ClaudeWebCookieResolver.parseCookieData(data, now: now)
        XCTAssertEqual(result.outcome, .cookieExpired)
        XCTAssertTrue(result.diagnostics.expiredMatch)
        XCTAssertEqual(result.diagnostics.sessionKeyMatches, 1)
    }

    // MARK: - unsupportedFormat

    func testBadMagic_isUnsupportedFormat() {
        let data = Data("this is not a binarycookies file".utf8)
        let result = ClaudeWebCookieResolver.parseCookieData(data, now: now)
        XCTAssertEqual(result.outcome, .unsupportedFormat)
        XCTAssertFalse(result.diagnostics.magicOK)
    }

    func testEmptyData_isUnsupportedFormat() {
        XCTAssertEqual(ClaudeWebCookieResolver.parseCookieData(Data(), now: now).outcome, .unsupportedFormat)
    }

    // MARK: - malformedRecord

    func testCorruptRecordOffsets_isMalformedRecord() {
        let data = BinaryCookieFixture.file(pages: [[
            .init(domain: ".claude.ai", name: "sessionKey", path: "/", value: "FAKE", expires: future, corruptOffsets: true),
        ]])
        let result = ClaudeWebCookieResolver.parseCookieData(data, now: now)
        XCTAssertEqual(result.outcome, .malformedRecord)
        XCTAssertTrue(result.diagnostics.malformed)
    }

    // MARK: - precedence

    func testLiveCookieWins_overExpiredAndMalformed() {
        let data = BinaryCookieFixture.file(pages: [[
            .init(domain: ".claude.ai", name: "sessionKey", path: "/", value: "FAKE-old", expires: past),
            .init(domain: ".claude.ai", name: "sessionKey", path: "/", value: "FAKE", expires: future, corruptOffsets: true),
            .init(domain: ".claude.ai", name: "sessionKey", path: "/", value: "FAKE-live", expires: future),
        ]])
        XCTAssertEqual(ClaudeWebCookieResolver.parseCookieData(data, now: now).outcome,
                       .found(.init(sessionKey: "FAKE-live")))
    }

    func testExpiredWins_overMalformedAndValidNoCookie() {
        let data = BinaryCookieFixture.file(pages: [[
            .init(domain: ".claude.ai", name: "sessionKey", path: "/", value: "FAKE", expires: future, corruptOffsets: true),
            .init(domain: ".claude.ai", name: "sessionKey", path: "/", value: "FAKE-stale", expires: past),
            .init(domain: ".github.com", name: "x", path: "/", value: "FAKE", expires: future),
        ]])
        XCTAssertEqual(ClaudeWebCookieResolver.parseCookieData(data, now: now).outcome, .cookieExpired)
    }
}

// MARK: - Byte-accurate binarycookies fixture builder (fake values only)

enum BinaryCookieFixture {
    struct Cookie {
        var domain: String
        var name: String
        var path: String
        var value: String
        var expires: Date
        var corruptOffsets: Bool = false
    }

    static func file(pages: [[Cookie]]) -> Data {
        let pageDatas = pages.map { page($0) }
        var out = Data()
        out.append(contentsOf: [0x63, 0x6F, 0x6F, 0x6B])  // "cook"
        out.appendUInt32BE(UInt32(pageDatas.count))
        for p in pageDatas { out.appendUInt32BE(UInt32(p.count)) }
        for p in pageDatas { out.append(p) }
        // Real files append an 8-byte checksum + policy blob here; the parser
        // never reads past the declared page sizes, so it is omitted.
        return out
    }

    static func page(_ cookies: [Cookie]) -> Data {
        let records = cookies.map { record($0) }
        // header: magic(4) + numRecords(4) + offsets(n*4) + footer(4)
        let headerSize = 4 + 4 + records.count * 4 + 4
        var offsets: [Int] = []
        var cursor = headerSize
        for r in records { offsets.append(cursor); cursor += r.count }

        var out = Data()
        out.append(contentsOf: [0x00, 0x01, 0x00, 0x00])  // page magic
        out.appendUInt32LE(UInt32(records.count))
        for o in offsets { out.appendUInt32LE(UInt32(o)) }
        out.append(contentsOf: [0x00, 0x00, 0x00, 0x00])  // footer
        for r in records { out.append(r) }
        return out
    }

    static func record(_ c: Cookie) -> Data {
        let domainBytes = Data(c.domain.utf8) + [0]
        let nameBytes = Data(c.name.utf8) + [0]
        let pathBytes = Data(c.path.utf8) + [0]
        let valueBytes = Data(c.value.utf8) + [0]

        let headerSize = 56
        let urlOff = headerSize
        let nameOff = urlOff + domainBytes.count
        let pathOff = nameOff + nameBytes.count
        let valOff = pathOff + pathBytes.count
        let total = valOff + valueBytes.count

        var rec = Data(count: headerSize)
        rec.writeUInt32LE(UInt32(total), at: 0)   // record size
        rec.writeUInt32LE(0, at: 4)               // version
        rec.writeUInt32LE(0, at: 8)               // flags
        rec.writeUInt32LE(0, at: 12)
        rec.writeUInt32LE(UInt32(c.corruptOffsets ? total + 4096 : urlOff), at: 16)
        rec.writeUInt32LE(UInt32(nameOff), at: 20)
        rec.writeUInt32LE(UInt32(pathOff), at: 24)
        rec.writeUInt32LE(UInt32(valOff), at: 28)
        // 32..40 reserved zeros
        rec.writeFloat64LE(c.expires.timeIntervalSince1970 - 978_307_200, at: 40)  // expiry
        rec.writeFloat64LE(c.expires.timeIntervalSince1970 - 978_307_200, at: 48)  // created

        rec.append(domainBytes)
        rec.append(nameBytes)
        rec.append(pathBytes)
        rec.append(valueBytes)
        return rec
    }
}

private extension Data {
    mutating func appendUInt32BE(_ v: UInt32) {
        append(contentsOf: [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)])
    }
    mutating func appendUInt32LE(_ v: UInt32) {
        append(contentsOf: [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)])
    }
    mutating func writeUInt32LE(_ v: UInt32, at offset: Int) {
        self[offset] = UInt8(v & 0xFF)
        self[offset + 1] = UInt8(v >> 8 & 0xFF)
        self[offset + 2] = UInt8(v >> 16 & 0xFF)
        self[offset + 3] = UInt8(v >> 24 & 0xFF)
    }
    mutating func writeFloat64LE(_ v: Double, at offset: Int) {
        let bits = v.bitPattern
        for i in 0..<8 { self[offset + i] = UInt8(bits >> (i * 8) & 0xFF) }
    }
}
