import Foundation
import os.log

private let log = OSLog(subsystem: "com.triada.AgentSessions", category: "ClaudeOAuth")

// MARK: - Web Cookie Resolver
//
// Extracts the `sessionKey` cookie for claude.ai from Safari's
// ~/Library/Cookies/Cookies.binarycookies binary file.
//
// The binarycookies format (reverse-engineered):
//   File: "cook" magic (4) | numPages uint32 BE | pageSizes[] uint32 BE | pageData[]
//   Page: 0x00000100 magic LE (4) | numRecords uint32 LE | offsets[] uint32 LE | records[]
//   Record: size(4) | unk(4) | flags(4) | unk(4) | urlOff(4) | nameOff(4) |
//           pathOff(4) | valueOff(4) | unk(8) | expiry float64 LE | created float64 LE |
//           NUL-terminated strings at respective offsets (relative to record start)
//   Epoch: Apple CoreData epoch = 2001-01-01T00:00:00Z (Unix + 978307200)
//
// TCC note: macOS 14+ may prompt "AgentSessions would like to access data from
// other apps." Graceful degradation on denial — returns nil, source treated as
// unavailable. The prompt appears once; "Always Allow" makes future access silent.

actor ClaudeWebCookieResolver {
    struct ResolvedCookie: Sendable {
        let sessionKey: String
    }

    private var cachedCookie: ResolvedCookie?
    private var cacheExpiresAt: Date = .distantPast
    private static let cacheTTL: TimeInterval = 30 * 60  // 30 minutes

    // MARK: - Public

    func resolve() async -> ResolvedCookie? {
        if let cached = cachedCookie, Date() < cacheExpiresAt { return cached }
        let cookie = parseSafariCookies()
        cachedCookie = cookie
        cacheExpiresAt = cookie != nil ? Date().addingTimeInterval(Self.cacheTTL) : .distantPast
        return cookie
    }

    func invalidateCache() {
        cachedCookie = nil
        cacheExpiresAt = .distantPast
    }

    // MARK: - Binary Cookie Parser

    /// Search paths for Safari's binarycookies file.
    /// Legacy (pre-macOS 14): ~/Library/Cookies/
    /// Sandboxed (macOS 14+): ~/Library/Containers/com.apple.Safari/.../Cookies/
    private static let cookiePaths: [String] = [
        "Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies",
        "Library/Cookies/Cookies.binarycookies",
    ]

    private func parseSafariCookies() -> ResolvedCookie? {
        let home = NSHomeDirectory() as NSString
        for relative in Self.cookiePaths {
            let path = home.appendingPathComponent(relative)
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                os_log("ClaudeOAuth: web cookie — reading from %{public}@", log: log, type: .info, relative)
                if let cookie = extractSessionKey(from: data) { return cookie }
            }
        }
        os_log("ClaudeOAuth: web cookie — no readable Cookies.binarycookies found",
               log: log, type: .info)
        return nil
    }

    private func extractSessionKey(from data: Data) -> ResolvedCookie? {
        guard data.count > 8 else { return nil }
        // Magic: "cook" = 0x636F6F6B
        guard data[0] == 0x63, data[1] == 0x6F, data[2] == 0x6F, data[3] == 0x6B else { return nil }

        let numPages = Int(data.readUInt32BE(at: 4))
        guard numPages > 0 else { return nil }

        // Read page sizes
        var headerOffset = 8
        var pageSizes: [Int] = []
        for _ in 0..<numPages {
            guard headerOffset + 4 <= data.count else { return nil }
            pageSizes.append(Int(data.readUInt32BE(at: headerOffset)))
            headerOffset += 4
        }

        // Scan each page for the sessionKey cookie
        let now = Date()
        var pageOffset = headerOffset
        for pageSize in pageSizes {
            guard pageOffset + pageSize <= data.count else { break }
            let pageData = Data(data[pageOffset..<(pageOffset + pageSize)])
            if let key = extractSessionKeyFromPage(pageData, now: now) {
                return ResolvedCookie(sessionKey: key)
            }
            pageOffset += pageSize
        }
        return nil
    }

    private func extractSessionKeyFromPage(_ page: Data, now: Date) -> String? {
        guard page.count >= 8 else { return nil }
        // Page magic: 0x00000100 (LE)
        guard page[0] == 0x00, page[1] == 0x01, page[2] == 0x00, page[3] == 0x00 else { return nil }

        let numRecords = Int(page.readUInt32LE(at: 4))
        guard numRecords > 0 else { return nil }

        // Record offsets follow the page header
        var offsets: [Int] = []
        var cursor = 8
        for _ in 0..<numRecords {
            guard cursor + 4 <= page.count else { break }
            offsets.append(Int(page.readUInt32LE(at: cursor)))
            cursor += 4
        }

        for recordOffset in offsets {
            guard recordOffset < page.count else { continue }
            let record = Data(page[recordOffset...])
            guard let (name, domain, value, expires) = parseCookieRecord(record) else { continue }
            guard (domain.hasSuffix(".claude.ai") || domain == "claude.ai"),
                  name == "sessionKey",
                  expires > now else { continue }
            return value
        }
        return nil
    }

    /// Parse a single cookie record. All fields little-endian; strings NUL-terminated
    /// at their offsets (relative to start of record).
    private func parseCookieRecord(_ record: Data) -> (name: String, domain: String, value: String, expires: Date)? {
        guard record.count >= 56 else { return nil }

        let urlOff  = Int(record.readUInt32LE(at: 16))
        let nameOff = Int(record.readUInt32LE(at: 20))
        let valOff  = Int(record.readUInt32LE(at: 28))
        let expiry  = record.readFloat64LE(at: 40)

        guard let domain = record.readCString(at: urlOff),
              let name   = record.readCString(at: nameOff),
              let value  = record.readCString(at: valOff) else { return nil }

        // Apple CoreData epoch: 2001-01-01T00:00:00Z = Unix + 978307200
        let expiresDate = Date(timeIntervalSince1970: expiry + 978_307_200)
        return (name, domain, value, expiresDate)
    }
}

// MARK: - Data reading helpers (byte-level, alignment-safe)

private extension Data {
    func readUInt32BE(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return (UInt32(self[offset]) << 24)
             | (UInt32(self[offset + 1]) << 16)
             | (UInt32(self[offset + 2]) << 8)
             |  UInt32(self[offset + 3])
    }

    func readUInt32LE(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return  UInt32(self[offset])
             | (UInt32(self[offset + 1]) << 8)
             | (UInt32(self[offset + 2]) << 16)
             | (UInt32(self[offset + 3]) << 24)
    }

    func readFloat64LE(at offset: Int) -> Double {
        guard offset + 8 <= count else { return 0 }
        var bits: UInt64 = 0
        for i in 0..<8 { bits |= UInt64(self[offset + i]) << (i * 8) }
        return Double(bitPattern: bits)
    }

    func readCString(at offset: Int) -> String? {
        guard offset >= 0, offset < count else { return nil }
        var end = offset
        while end < count, self[end] != 0 { end += 1 }
        return String(data: self[offset..<end], encoding: .utf8)
    }
}
