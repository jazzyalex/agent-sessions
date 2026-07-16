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
// KNOWN LIMITATION (macOS 14/15): Safari no longer keeps its live browsing
// `sessionKey` in these legacy binarycookies files — it moved to the WebKit
// network data store, which the app cannot read as a file (verified 2026-07-16:
// a fresh 488KB container Cookies.binarycookies held zero claude.ai markers, and
// the WebsiteDataStore / HTTPStorages locations are absent or permission-denied).
// So on modern macOS this reader typically returns `.validStoreNoCookie` even for
// a signed-in user. It is retained only as a LEGACY import path; the primary web
// source is the user's manually-pasted claude.ai cookie (ClaudeManualWebCookie).
//
// TCC note: macOS 14+ may prompt "AgentSessions would like to access data from
// other apps." Graceful degradation on denial — returns .permissionDenied, source
// treated as unavailable.

actor ClaudeWebCookieResolver {
    struct ResolvedCookie: Sendable, Equatable {
        let sessionKey: String
    }

    /// Typed read outcome so callers can tell the failure worlds apart — they need
    /// different remedies and must never collapse into one silent "no session
    /// cookie" (which is how a missing Full Disk Access grant, and later a
    /// relocated cookie store, hid behind an unusable Web API path for weeks):
    /// - `.found` — a live claude.ai `sessionKey` cookie.
    /// - `.permissionDenied` — the cookie file exists but macOS TCC blocked the
    ///   read → the user must grant Full Disk Access; retrying won't help.
    /// - `.storeMissing` — no binarycookies file exists at any known path.
    /// - `.validStoreNoCookie` — the file parsed cleanly but holds no claude.ai
    ///   `sessionKey` (signed out, OR — the common macOS 14/15 case — the live
    ///   cookie now lives in a store the app cannot read).
    /// - `.unsupportedFormat` — the file is present/readable but is not a
    ///   binarycookies file (bad magic).
    /// - `.malformedRecord` — binarycookies magic but the internal structure is
    ///   broken (truncated page table, bad record offsets, unreadable strings).
    /// - `.cookieExpired` — a claude.ai `sessionKey` is present but expired → the
    ///   user must sign in again.
    enum ReadOutcome: Sendable, Equatable {
        case found(ResolvedCookie)
        case permissionDenied
        case storeMissing
        case validStoreNoCookie
        case unsupportedFormat
        case malformedRecord
        case cookieExpired
    }

    /// Value-free parse telemetry — counts and booleans only, NEVER cookie values.
    /// Logged at parse time so a future "why is the web path empty" can be answered
    /// from the log without ever exposing a session secret.
    struct ParseDiagnostics: Sendable, Equatable {
        var magicOK = false
        var pageCount = 0
        var recordCount = 0
        var totalCookies = 0
        var claudeAiCookies = 0
        var sessionKeyMatches = 0
        var expiredMatch = false
        var malformed = false
    }

    private var cachedCookie: ResolvedCookie?
    private var cacheExpiresAt: Date = .distantPast
    private static let cacheTTL: TimeInterval = 30 * 60  // 30 minutes

    // MARK: - Public

    func resolve() async -> ResolvedCookie? {
        if case .found(let cookie) = await resolveDetailed() { return cookie }
        return nil
    }

    /// Cause-aware resolution. Same cache as `resolve()` — only a found cookie
    /// is cached; failures re-probe (the file read is cheap and the outcome can
    /// change under the app: an FDA grant or a Safari sign-in).
    func resolveDetailed() async -> ReadOutcome {
        if let cached = cachedCookie, Date() < cacheExpiresAt { return .found(cached) }
        let outcome = parseSafariCookiesDetailed()
        if case .found(let cookie) = outcome {
            cachedCookie = cookie
            cacheExpiresAt = Date().addingTimeInterval(Self.cacheTTL)
        } else {
            cachedCookie = nil
            cacheExpiresAt = .distantPast
        }
        return outcome
    }

    func invalidateCache() {
        cachedCookie = nil
        cacheExpiresAt = .distantPast
    }

    // MARK: - Binary Cookie Parser

    /// Search paths for Safari's binarycookies file.
    /// Legacy (pre-macOS 14): ~/Library/Cookies/
    /// Sandboxed (macOS 14+): ~/Library/Containers/com.apple.Safari/.../Cookies/
    /// Known limitation: on macOS 14/15 the live `sessionKey` is typically absent
    /// from both (see file header) — this reader is a best-effort legacy import.
    private static let cookiePaths: [String] = [
        "Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies",
        "Library/Cookies/Cookies.binarycookies",
    ]

    private func parseSafariCookiesDetailed() -> ReadOutcome {
        let home = NSHomeDirectory() as NSString
        let now = Date()
        var sawPermissionDenied = false
        var sawReadableFile = false
        var best: ReadOutcome?

        for relative in Self.cookiePaths {
            let path = home.appendingPathComponent(relative)
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                sawReadableFile = true
                let (outcome, diagnostics) = Self.parseCookieData(data, now: now)
                Self.logDiagnostics(diagnostics, path: relative)
                if case .found = outcome { return outcome }
                best = Self.higherPrecedence(best, outcome)
            } catch {
                if Self.isPermissionDenial(error) {
                    // TCC blocked the read (the file exists — that's why the error
                    // is EPERM, not ENOENT). Remember it, but keep trying the other
                    // path: a readable legacy file with a live cookie still wins.
                    sawPermissionDenied = true
                    os_log("ClaudeOAuth: web cookie — permission denied reading %{public}@ (Full Disk Access needed)",
                           log: log, type: .info, relative)
                }
                // ENOENT / other read errors: fall through to the next path.
            }
        }

        if sawPermissionDenied { return .permissionDenied }
        if let best { return best }
        if !sawReadableFile { return .storeMissing }
        return .validStoreNoCookie
    }

    /// Classify a single binarycookies blob into a typed outcome + value-free
    /// diagnostics. Pure (no I/O) and `nonisolated static` so it is unit-testable
    /// against fixture bytes without touching the real cookie store.
    ///
    /// Precedence within one file: a live `sessionKey` wins over everything; then
    /// an expired match (actionable "re-sign-in") over a structural malformation
    /// over a clean "no cookie" store.
    nonisolated static func parseCookieData(_ data: Data, now: Date) -> (outcome: ReadOutcome, diagnostics: ParseDiagnostics) {
        var diagnostics = ParseDiagnostics()

        // Magic: "cook" = 0x636F6F6B. A mismatch means this isn't a binarycookies
        // file at all (Safari wrote something else, or the file is truncated/empty).
        // `>= 8` is the minimum to read the magic (4) + numPages (4); an 8-byte
        // file is a valid, empty store (numPages == 0), not an unsupported format.
        guard data.count >= 8,
              data[0] == 0x63, data[1] == 0x6F, data[2] == 0x6F, data[3] == 0x6B else {
            return (.unsupportedFormat, diagnostics)
        }
        diagnostics.magicOK = true

        let numPages = Int(data.readUInt32BE(at: 4))
        diagnostics.pageCount = numPages
        if numPages == 0 { return (.validStoreNoCookie, diagnostics) }

        var headerOffset = 8
        var pageSizes: [Int] = []
        for _ in 0..<numPages {
            guard headerOffset + 4 <= data.count else {
                diagnostics.malformed = true
                return (.malformedRecord, diagnostics)  // truncated page-size table
            }
            pageSizes.append(Int(data.readUInt32BE(at: headerOffset)))
            headerOffset += 4
        }

        var liveValue: String?
        var pageOffset = headerOffset
        for pageSize in pageSizes {
            guard pageSize >= 8, pageOffset + pageSize <= data.count else {
                diagnostics.malformed = true
                break
            }
            let page = Data(data[pageOffset..<(pageOffset + pageSize)])
            scanPage(page, now: now, diagnostics: &diagnostics, liveValue: &liveValue)
            if liveValue != nil { break }  // live cookie found — stop early
            pageOffset += pageSize
        }

        if let liveValue { return (.found(.init(sessionKey: liveValue)), diagnostics) }
        if diagnostics.expiredMatch { return (.cookieExpired, diagnostics) }
        if diagnostics.malformed { return (.malformedRecord, diagnostics) }
        return (.validStoreNoCookie, diagnostics)
    }

    private nonisolated static func scanPage(_ page: Data,
                                             now: Date,
                                             diagnostics: inout ParseDiagnostics,
                                             liveValue: inout String?) {
        // Page magic: 0x00000100 (LE)
        guard page.count >= 8,
              page[0] == 0x00, page[1] == 0x01, page[2] == 0x00, page[3] == 0x00 else {
            diagnostics.malformed = true
            return
        }

        let numRecords = Int(page.readUInt32LE(at: 4))
        diagnostics.recordCount += numRecords
        guard numRecords > 0 else { return }

        var offsets: [Int] = []
        var cursor = 8
        for _ in 0..<numRecords {
            guard cursor + 4 <= page.count else { diagnostics.malformed = true; break }
            offsets.append(Int(page.readUInt32LE(at: cursor)))
            cursor += 4
        }

        for recordOffset in offsets {
            guard recordOffset >= 0, recordOffset < page.count else { diagnostics.malformed = true; continue }
            let record = Data(page[recordOffset...])
            guard let (name, domain, value, expires) = parseCookieRecord(record) else {
                diagnostics.malformed = true
                continue
            }
            diagnostics.totalCookies += 1
            let isClaude = domain.hasSuffix(".claude.ai") || domain == "claude.ai"
            if isClaude { diagnostics.claudeAiCookies += 1 }
            guard isClaude, name == "sessionKey" else { continue }
            diagnostics.sessionKeyMatches += 1
            if expires > now {
                if liveValue == nil { liveValue = value }
            } else {
                diagnostics.expiredMatch = true
            }
        }
    }

    /// Parse a single cookie record. All fields little-endian; strings NUL-terminated
    /// at their offsets (relative to start of record).
    private nonisolated static func parseCookieRecord(_ record: Data) -> (name: String, domain: String, value: String, expires: Date)? {
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

    /// Precedence for aggregating per-file outcomes across the search paths: a
    /// `.found` returns immediately (handled by the caller); among failures the
    /// most-actionable/most-specific wins.
    private nonisolated static func higherPrecedence(_ lhs: ReadOutcome?, _ rhs: ReadOutcome) -> ReadOutcome {
        guard let lhs else { return rhs }
        return precedenceRank(rhs) < precedenceRank(lhs) ? rhs : lhs
    }

    private nonisolated static func precedenceRank(_ outcome: ReadOutcome) -> Int {
        switch outcome {
        case .found: return 0
        case .cookieExpired: return 1
        case .validStoreNoCookie: return 2
        case .malformedRecord: return 3
        case .unsupportedFormat: return 4
        case .storeMissing: return 5
        case .permissionDenied: return 6
        }
    }

    private nonisolated static func logDiagnostics(_ d: ParseDiagnostics, path: String) {
        os_log("""
               ClaudeOAuth: web cookie parse — path=%{public}@ magicOK=%{public}@ pages=%d records=%d \
               cookies=%d claudeAi=%d sessionKey=%d expiredMatch=%{public}@ malformed=%{public}@
               """,
               log: log, type: .info, path,
               d.magicOK ? "yes" : "no", d.pageCount, d.recordCount,
               d.totalCookies, d.claudeAiCookies, d.sessionKeyMatches,
               d.expiredMatch ? "yes" : "no", d.malformed ? "yes" : "no")
    }

    /// True when a file-read error means macOS denied access (TCC / permissions)
    /// rather than the file being absent. `Data(contentsOf:)` surfaces TCC
    /// denials as `NSFileReadNoPermissionError` (POSIX EPERM/EACCES underneath).
    static func isPermissionDenial(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain {
            if ns.code == NSFileReadNoPermissionError { return true }
            // Foundation sometimes wraps the real POSIX denial in a generic
            // read-unknown error — unwrap and re-check the underlying error so
            // a TCC denial can't misreport as "no session in Safari".
            if ns.code == NSFileReadUnknownError,
               let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
                return isPermissionDenial(underlying)
            }
            return false
        }
        if ns.domain == NSPOSIXErrorDomain {
            return ns.code == Int(EPERM) || ns.code == Int(EACCES)
        }
        return false
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
