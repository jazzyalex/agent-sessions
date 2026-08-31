import Foundation

// MARK: - Weekly calibration bootstrap
//
// The live-tick tracker learns pp-per-dollar by watching the weekly quota drop.
// On Codex that is hopeless as a FIRST reading: `used_percent` is integer-only
// (verified across every local transcript), so the smallest observable drop is a
// full point of a WEEKLY quota — hours of work. A spinner that outlives the task
// the user is watching is worse than no feature.
//
// But the answer is already on disk. Every Codex `token_count` line carries both
// the turn's own token usage AND the `rate_limits` snapshot at that instant, so a
// transcript is a complete quota trace, not just an activity log. That means the
// conversion can be computed directly from history the moment the app launches:
//
//     calibration = used_percent_since_window_start ÷ priced_activity_since_start
//
// No waiting, and no invented quota size — both terms are measured.
//
// This is strictly better-conditioned than a single live tick, too. A 1pp tick
// carries up to ±50% quantization error; a bootstrap over 20pp carries ~±2.5%.

struct WeeklyQuotaBootstrapResult: Equatable, Codable, Sendable {
    /// Percentage points of the weekly window consumed since it opened.
    let usedPercentPoints: Double
    /// API-equivalent dollars of local activity over the same span.
    let dollars: Double
    /// Share of token volume we could not price. A whole week will occasionally
    /// contain one unknown slug; unlike a single interval, that must not void the
    /// whole scan — it is reported so the caller can apply a proportion cap.
    let unpricedVolumeShare: Double
    let windowStart: Date
    let resetsAt: Date
    let scannedAt: Date
    /// Price table the dollars were computed under. A measurement priced by a
    /// stale table describes a different conversion, so it must not be carried
    /// into a run using a newer one. Nil in records written before this was
    /// stamped: those are still usable — discarding them would throw away the
    /// completed windows this cache exists to keep — but they are rescanned.
    var priceRevision: Int?
    /// Window layout the plan reported (`5h+weekly` vs `weekly`). A plan change
    /// alters what a percentage point means, so it invalidates the conversion.
    var limitShape: String?

    /// Both providers report weekly consumption as whole percentage points, so a
    /// reported `2` means true consumption somewhere in `[2, 3)`. Taking the floor
    /// biases every estimate low, worst exactly where the numerator is smallest.
    static let quantizationMidpoint: Double = 0.5

    /// Whether this measurement may be served under the given conditions. An
    /// unstamped legacy record passes: it predates the stamp rather than
    /// contradicting it.
    func isCompatible(priceRevision: Int, limitShape: String?) -> Bool {
        if let stamped = self.priceRevision, stamped != priceRevision { return false }
        if let stamped = self.limitShape, let current = limitShape, stamped != current { return false }
        return true
    }

    /// Nil-ness here is the validity test — dollars and consumption must both be
    /// positive. Use `calibratedPercentPointsPerDollar` for the value to serve.
    var percentPointsPerDollar: Double? {
        guard dollars > 0, usedPercentPoints > 0 else { return nil }
        let value = usedPercentPoints / dollars
        return value.isFinite && value > 0 ? value : nil
    }

    /// The ratio to actually serve: numerator at the quantization midpoint.
    ///
    /// The midpoint used to live only on the freshening path, so whether a
    /// measurement got it depended on whether its window happened to match the
    /// current one — a carried-over bootstrap served the raw floor while a
    /// current-window one served the midpoint. That made two providers'
    /// numbers incomparable for no reason other than which code path they took.
    var calibratedPercentPointsPerDollar: Double? {
        guard percentPointsPerDollar != nil else { return nil }
        let value = (usedPercentPoints + Self.quantizationMidpoint) / dollars
        return value.isFinite && value > 0 ? value : nil
    }
}

/// Streams the local Codex transcripts that overlap the current weekly window and
/// sums their priced activity.
enum CodexWeeklyQuotaBootstrapScanner {

    /// Integer quantization makes a small numerator imprecise (±50% at 1pp, ~±17%
    /// at 3pp), but a rough number now beats "n/a" for an hour: a freshly
    /// re-anchored window sits at 1-3pp for its first hours, and refusing to
    /// divide there is exactly the dead wait this bootstrap exists to remove.
    /// Live ticks and later rescans sharpen it as the week accumulates.
    static let minimumUsedPercentPoints: Double = 1
    /// A week may legitimately contain a slug the price table has never seen. Void
    /// the scan only when the unknown share is big enough to move the answer.
    static let maximumUnpricedShare: Double = 0.05
#if DEBUG
    /// Temporary instrumentation: os_log does not reach `log show` in this setup,
    /// so diagnose via an explicit file write.
    static func debugLog(_ message: String) {
        let path = "/tmp/agentsessions-wkcal.log"
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(stamp)] \(message)\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
#else
    static func debugLog(_ message: String) {}
#endif

    /// Same location the runway scanner uses (`CodexRunwayRecentSessionScanner`).
    static let defaultSessionsRoot: URL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".codex/sessions", isDirectory: true)

    /// Anchor equality tolerance, matching `WeeklyQuotaCalibrationTracker`.
    static let anchorTolerance: TimeInterval = 120

    /// Scan `root` for activity inside the weekly window ending at `resetsAt`.
    ///
    /// `resetsAt` also acts as an ACCOUNT FILTER, which matters more than it looks:
    /// two accounts can share one machine (OpenClaw shares the Codex OAuth store),
    /// and their sessions interleave in the same directory. A naive "everything
    /// modified this week" sum would put another account's dollars in the
    /// denominator and bias the calibration low. Banking a turn only when the
    /// transcript's own live weekly anchor matches keeps the ratio self-consistent,
    /// and handles mid-week re-anchors for free.
    static func scan(root: URL,
                     resetsAt: Date,
                     windowMinutes: Int,
                     usedPercentPoints: Double,
                     priceTable: RunwayPriceTable,
                     now: Date,
                     fileManager: FileManager = .default) -> WeeklyQuotaBootstrapResult? {
        debugLog("scan start used=\(usedPercentPoints)pp resetsAt=\(resetsAt.timeIntervalSince1970) win=\(windowMinutes) root=\(root.path)")
        guard usedPercentPoints >= minimumUsedPercentPoints else {
            debugLog("scan REJECT: used \(usedPercentPoints) < min \(minimumUsedPercentPoints)")
            return nil
        }
        let windowStart = resetsAt.addingTimeInterval(-Double(windowMinutes) * 60)
        guard windowStart < now else { debugLog("scan REJECT: windowStart in future"); return nil }

        var dollars = 0.0
        var pricedVolume = 0.0
        var unpricedVolume = 0.0
        var seenFiles = 0
        var seenAnchors: Set<Int> = []
        var matchedTurns = 0

        for url in candidateFiles(root: root, modifiedAfter: windowStart, fileManager: fileManager) {
            seenFiles += 1
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                debugLog("open FAILED \(url.lastPathComponent)")
                continue
            }

            // A resumed transcript can open with `token_count` lines whose model was
            // declared in an earlier segment. Without a seed those tokens price as
            // "unknown" and can trip the 5% unpriced cap, throwing away an
            // otherwise good scan. Seed from the first model the file mentions;
            // later `turn_context` lines still override as the file progresses.
            // Stdlib split + Substring.contains, matching how the existing parsers
            // walk these transcripts (see `lastTurnContextModel`). A hand-rolled
            // byte matcher was tried here and is NOT an optimisation: it allocated
            // per line and ran O(line x needle), managing ~1 MB/s in a Debug build
            // and never finishing a 44 MB window. This form is memchr-backed.
            let text = String(decoding: data, as: UTF8.self)
            var currentModel: String? = Self.firstModelSlug(in: text)
            var currentAnchor: Date?
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                let isTokenCount = line.contains("token_count")
                let isTurnContext = line.contains("turn_context")
                guard isTokenCount || isTurnContext else { continue }
                ingest(line: line,
                       isTokenCount: isTokenCount,
                       isTurnContext: isTurnContext,
                       currentModel: &currentModel,
                       currentAnchor: &currentAnchor,
                       resetsAt: resetsAt,
                       windowMinutes: windowMinutes,
                       windowStart: windowStart,
                       priceTable: priceTable,
                       dollars: &dollars,
                       pricedVolume: &pricedVolume,
                       unpricedVolume: &unpricedVolume,
                       seenAnchors: &seenAnchors,
                       matchedTurns: &matchedTurns)
            }
        }

        let totalVolume = pricedVolume + unpricedVolume
        debugLog("scan done files=\(seenFiles) anchorsSeen=\(seenAnchors.sorted()) matched=\(matchedTurns) dollars=\(dollars) priced=\(pricedVolume) unpriced=\(unpricedVolume)")
        guard dollars > 0, totalVolume > 0 else { debugLog("scan REJECT: no dollars"); return nil }
        return WeeklyQuotaBootstrapResult(
            usedPercentPoints: usedPercentPoints,
            dollars: dollars,
            unpricedVolumeShare: unpricedVolume / totalVolume,
            windowStart: windowStart,
            resetsAt: resetsAt,
            scannedAt: now,
            priceRevision: priceTable.revision
        )
    }

    /// Enumerated by MODIFICATION TIME, never by the YYYY/MM/DD path: a session
    /// created months ago and resumed this week is still this week's activity.
    static func candidateFiles(root: URL,
                               modifiedAfter: Date,
                               fileManager: FileManager = .default) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [URL] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified >= modifiedAfter else { continue }
            result.append(url)
        }
        return result
    }

    /// First `"model":"…"` mentioned anywhere in the file, used only as the initial
    /// value before the first `turn_context` line is reached.
    static func firstModelSlug(in text: String) -> String? {
        guard let range = text.range(of: "\"model\":\"") else { return nil }
        let rest = text[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        let slug = String(rest[..<end])
        return slug.isEmpty ? nil : slug
    }

    private static func ingest(line: Substring,
                               isTokenCount: Bool,
                               isTurnContext: Bool,
                               currentModel: inout String?,
                               currentAnchor: inout Date?,
                               resetsAt: Date,
                               windowMinutes: Int,
                               windowStart: Date,
                               priceTable: RunwayPriceTable,
                               dollars: inout Double,
                               pricedVolume: inout Double,
                               unpricedVolume: inout Double,
                               seenAnchors: inout Set<Int>,
                               matchedTurns: inout Int) {
        // The caller already prefiltered; only relevant lines are ever JSON-parsed,
        // which is what keeps a multi-megabyte transcript cheap to walk.
        guard let lineData = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { return }
        let payload = (object["payload"] as? [String: Any]) ?? object

        if isTurnContext, let model = payload["model"] as? String, !model.isEmpty {
            currentModel = model
        }
        guard isTokenCount else { return }

        // The rate_limits block rides along on the same line, so the anchor is
        // always the one that was live when these tokens were spent.
        //
        // Both slots are searched BY DECLARED LENGTH, never by position. The 5h
        // window is plan-dependent (Plus has it, Pro-lite does not), so weekly is
        // `primary` on an account with no 5h window and `secondary` on one that has
        // it. Reading `primary` alone would find no weekly anchor on a Plus account
        // and silently never calibrate. This mirrors the existing repo rule in
        // `CodexRateLimitWindowClassifier.route`.
        if let limits = payload["rate_limits"] as? [String: Any] ?? object["rate_limits"] as? [String: Any] {
            for slot in ["primary", "secondary"] {
                guard let window = limits[slot] as? [String: Any],
                      let minutes = window["window_minutes"] as? Int, minutes == windowMinutes,
                      let epoch = window["resets_at"] as? Double else { continue }
                currentAnchor = Date(timeIntervalSince1970: epoch)
                break
            }
        }
        // Another account's session, or a superseded window. Not our denominator.
        if let a = currentAnchor { seenAnchors.insert(Int(a.timeIntervalSince1970)) }
        guard let anchor = currentAnchor,
              abs(anchor.timeIntervalSince(resetsAt)) < anchorTolerance else { return }
        matchedTurns += 1

        guard let timestamp = timestamp(object: object, payload: payload), timestamp >= windowStart else { return }
        let info = (payload["info"] as? [String: Any]) ?? payload
        // `last_token_usage` is the turn's OWN usage, so no cumulative diffing is
        // needed and a resumed session cannot double-count its history.
        guard let last = info["last_token_usage"] as? [String: Any] else { return }

        func value(_ key: String) -> Double { (last[key] as? Double) ?? Double((last[key] as? Int) ?? 0) }
        let cached = value("cached_input_tokens")
        // Codex `input_tokens` INCLUDES cached reads; fresh input is the remainder.
        let freshInput = max(0, value("input_tokens") - cached)
        let output = value("output_tokens")
        let cacheWrite = value("cache_write_input_tokens")
        let volume = freshInput + cached + output + cacheWrite
        guard volume > 0 else { return }

        guard let price = priceTable.price(forModel: currentModel) else {
            unpricedVolume += volume
            return
        }
        pricedVolume += volume
        dollars += freshInput * price.inputPerMTok / 1_000_000
            + cached * price.cachedInputPerMTok / 1_000_000
            + output * price.outputPerMTok / 1_000_000
            + cacheWrite * (price.cacheWritePerMTok ?? price.inputPerMTok) / 1_000_000
    }

    /// Codex writes ISO-8601 strings on transcript lines, but older rollouts and
    /// some payloads carry epoch numbers; accept both rather than dropping a turn
    /// (a dropped turn understates the denominator and inflates the calibration).
    private static func timestamp(object: [String: Any], payload: [String: Any]) -> Date? {
        for key in ["timestamp", "created_at"] {
            for source in [object, payload] {
                if let date = parseDate(source[key]) { return date }
            }
        }
        return nil
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    private static func parseDate(_ raw: Any?) -> Date? {
        if let seconds = raw as? Double { return Date(timeIntervalSince1970: seconds) }
        if let seconds = raw as? Int { return Date(timeIntervalSince1970: Double(seconds)) }
        guard let text = raw as? String, !text.isEmpty else { return nil }
        return isoFractional.date(from: text) ?? isoPlain.date(from: text)
    }
}


/// Claude's counterpart to `CodexWeeklyQuotaBootstrapScanner`.
///
/// Same ratio (consumed percent ÷ priced activity over the same span), different
/// source shape. Two differences that matter:
///
/// 1. Claude transcripts carry NO quota trace — `message.usage` records tokens but
///    no `rate_limits` — so the window comes from the account snapshot rather than
///    from the file, and there is no per-line anchor to filter accounts by. That
///    is acceptable here only because Claude calibration is memory-only anyway
///    (`ClaudeLimitSnapshot` exposes no account scope).
/// 2. `message.usage` is already per-call, so entries are summed directly with no
///    cumulative diffing, deduped by message id exactly as the runway parser does.
enum ClaudeWeeklyQuotaBootstrapScanner {

    static let defaultProjectsRoot: URL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".claude/projects", isDirectory: true)

    static func scan(root: URL,
                     resetsAt: Date,
                     windowMinutes: Int,
                     usedPercentPoints: Double,
                     priceTable: RunwayPriceTable,
                     now: Date,
                     fileManager: FileManager = .default) -> WeeklyQuotaBootstrapResult? {
        CodexWeeklyQuotaBootstrapScanner.debugLog(
            "claude scan start used=\(usedPercentPoints)pp resetsAt=\(resetsAt.timeIntervalSince1970)")
        guard usedPercentPoints >= CodexWeeklyQuotaBootstrapScanner.minimumUsedPercentPoints else {
            CodexWeeklyQuotaBootstrapScanner.debugLog("claude scan REJECT: used too small")
            return nil
        }
        let windowStart = resetsAt.addingTimeInterval(-Double(windowMinutes) * 60)
        guard windowStart < now else { return nil }

        let urls = CodexWeeklyQuotaBootstrapScanner.candidateFiles(
            root: root, modifiedAfter: windowStart, fileManager: fileManager)

        // Claude's week is an order of magnitude larger than Codex's (~680 MB vs
        // ~44 MB here), enough that a serial walk blew straight through the 60s
        // budget. Files are independent, so fan out across cores and merge.
        let accumulator = NSLock()
        var dollars = 0.0
        var pricedVolume = 0.0
        var unpricedVolume = 0.0
        // Message ids are deduped GLOBALLY, not per file: a subagent transcript can
        // repeat records that also appear in its parent, and counting them twice
        // inflates the denominator, which silently understates every session's %/h.
        // Stored as hashes so a week's worth of ids stays small.
        var seenMessageIDs: Set<Int> = []

        // Bounded fan-out. Each worker decodes a whole file into a String, and the
        // largest transcripts here are ~44 MB (so ~2x that live per worker); an
        // unbounded `concurrentPerform` over every core peaked near a gigabyte,
        // which is not an acceptable cost for a background convenience scan.
        let workers = min(4, max(1, ProcessInfo.processInfo.activeProcessorCount - 2))
        DispatchQueue.concurrentPerform(iterations: workers) { worker in
            var index = worker
            while index < urls.count {
                defer { index += workers }
                let url = urls[index]
                guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { continue }
                var localEntries: [(id: Int?, dollars: Double, volume: Double, priced: Bool)] = []

                let text = String(decoding: data, as: UTF8.self)
                for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                    guard line.contains("\"usage\"") else { continue }
                    guard let lineData = line.data(using: .utf8),
                          let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                          let message = object["message"] as? [String: Any],
                          let usage = message["usage"] as? [String: Any] else { continue }
                    guard let at = ClaudeRunwayLog.date(object["timestamp"]), at >= windowStart, at <= now else { continue }

                    func value(_ key: String) -> Double { ClaudeRunwayLog.double(usage[key]) ?? 0 }
                    // Claude reports fresh input separately from cache reads already, so
                    // unlike Codex there is nothing to subtract.
                    let input = value("input_tokens")
                    let cacheRead = value("cache_read_input_tokens")
                    // Cache writes bill by TTL — 1.25× input at 5 minutes, 2× at one
                    // hour. Resolved by the shared helper so this scan and the live
                    // runway price the same record identically.
                    let writes = ClaudeRunwayLog.cacheCreation(usage: usage)
                    let output = value("output_tokens")
                    let volume = input + cacheRead + writes.fiveMinute + writes.oneHour + output
                    guard volume > 0 else { continue }

                    let id = (message["id"] as? String).map { $0.hashValue }
                    let model = (message["model"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    // A tier with no rates counts as unpriced for the same reason an
                    // unknown model does — better an honest gap than a halved cost.
                    guard let price = priceTable.price(forModel: model),
                          let rates = price.rates(for: RunwaySpeedTier(usageValue: usage["speed"])) else {
                        localEntries.append((id, 0, volume, false))
                        continue
                    }
                    let cost = rates.dollars(input: input,
                                             cachedInput: cacheRead,
                                             output: output,
                                             cacheWrite5m: writes.fiveMinute,
                                             cacheWrite1h: writes.oneHour)
                    localEntries.append((id, cost, volume, true))
                }
                accumulator.lock()
                for entry in localEntries {
                    if let id = entry.id {
                        if seenMessageIDs.contains(id) { continue }
                        seenMessageIDs.insert(id)
                    }
                    if entry.priced {
                        dollars += entry.dollars
                        pricedVolume += entry.volume
                    } else {
                        unpricedVolume += entry.volume
                    }
                }
                accumulator.unlock()
            }
        }
        let files = urls.count

        let totalVolume = pricedVolume + unpricedVolume
        CodexWeeklyQuotaBootstrapScanner.debugLog(
            "claude scan done files=\(files) dollars=\(dollars) priced=\(pricedVolume) unpriced=\(unpricedVolume)")
        guard dollars > 0, totalVolume > 0 else { return nil }
        return WeeklyQuotaBootstrapResult(
            usedPercentPoints: usedPercentPoints,
            dollars: dollars,
            unpricedVolumeShare: unpricedVolume / totalVolume,
            windowStart: windowStart,
            resetsAt: resetsAt,
            scannedAt: now,
            priceRevision: priceTable.revision
        )
    }
}
