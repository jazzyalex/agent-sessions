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
    /// Usage source that supplied the account-level observation. OAuth, CLI RPC,
    /// JSONL fallback and a status probe are not interchangeable evidence paths.
    /// Optional for records written before source-family provenance existed; such
    /// records are not compatible when a caller supplies a current family.
    var sourceFamily: String?
    /// Normalization contract used to create the denominator. Codex revision 6
    /// unifies bootstrap/live cumulative accounting and event-time semantics.
    var activityAccountingRevision: Int? = nil

    static let codexActivityAccountingRevision = 6

    /// Both providers report weekly consumption as whole percentage points, so a
    /// reported `2` means true consumption somewhere in `[2, 3)`. Taking the floor
    /// biases every estimate low, worst exactly where the numerator is smallest.
    static let quantizationMidpoint: Double = 0.5

    /// Whether this measurement may be served under the given conditions.
    /// Source-family provenance fails closed: a scoped caller cannot consume an
    /// unstamped legacy record because its evidence path cannot be established.
    func isCompatible(priceRevision: Int,
                      limitShape: String?,
                      sourceFamily: String? = nil,
                      activityAccountingRevision: Int? = nil) -> Bool {
        if let stamped = self.priceRevision, stamped != priceRevision { return false }
        if let required = activityAccountingRevision,
           self.activityAccountingRevision != required { return false }
        if let stamped = self.limitShape, let current = limitShape, stamped != current { return false }
        if let current = sourceFamily {
            guard self.sourceFamily == current else { return false }
        } else if self.sourceFamily != nil {
            // A caller without a family scope cannot safely consume a stamped
            // record because it cannot prove that the evidence paths agree.
            return false
        }
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
    /// `resetsAt` constrains transcript records to the observed weekly window.
    /// This prevents a different or superseded window from entering the denominator,
    /// but is not proof of durable account identity: two accounts can have matching
    /// reset instants. Account/source scope is enforced by the surrounding store.
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
        var hadIncompleteCandidate = false
        let priceSnapshot = priceTable.snapshot()

        for url in candidateFiles(root: root, modifiedAfter: windowStart, fileManager: fileManager) {
            seenFiles += 1
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                debugLog("open FAILED \(url.lastPathComponent)")
                hadIncompleteCandidate = true
                continue
            }

            // Stdlib split + Substring.contains, matching how the existing parsers
            // walk these transcripts (see `lastTurnContextModel`). A hand-rolled
            // byte matcher was tried here and is NOT an optimisation: it allocated
            // per line and ran O(line x needle), managing ~1 MB/s in a Debug build
            // and never finishing a 44 MB window. This form is memchr-backed.
            let text = String(decoding: data, as: UTF8.self)
            // Model attribution is chronological. A later turn_context must not
            // price earlier token records in the same file.
            var currentModel: String?
            var currentAnchor: Date?
            var previousTokenAnchor: Date?
            var cumulative = CumulativeCounters()
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                let isTokenCount = line.contains("token_count")
                let isTurnContext = line.contains("turn_context")
                guard isTokenCount || isTurnContext else { continue }
                let complete = ingest(line: line,
                       isTokenCount: isTokenCount,
                       isTurnContext: isTurnContext,
                       currentModel: &currentModel,
                       currentAnchor: &currentAnchor,
                       previousTokenAnchor: &previousTokenAnchor,
                       resetsAt: resetsAt,
                       windowMinutes: windowMinutes,
                       windowStart: windowStart,
                       observationCutoff: now,
                       priceSnapshot: priceSnapshot,
                       cumulative: &cumulative,
                       dollars: &dollars,
                       pricedVolume: &pricedVolume,
                       unpricedVolume: &unpricedVolume,
                       seenAnchors: &seenAnchors,
                       matchedTurns: &matchedTurns)
                hadIncompleteCandidate = hadIncompleteCandidate || !complete
            }
        }

        let totalVolume = pricedVolume + unpricedVolume
        debugLog("scan done files=\(seenFiles) anchorsSeen=\(seenAnchors.sorted()) matched=\(matchedTurns) dollars=\(dollars) priced=\(pricedVolume) unpriced=\(unpricedVolume)")
        guard !hadIncompleteCandidate else {
            debugLog("scan REJECT: incomplete or malformed candidate")
            return nil
        }
        guard dollars > 0, totalVolume > 0 else { debugLog("scan REJECT: no dollars"); return nil }
        return WeeklyQuotaBootstrapResult(
            usedPercentPoints: usedPercentPoints,
            dollars: dollars,
            unpricedVolumeShare: unpricedVolume / totalVolume,
            windowStart: windowStart,
            resetsAt: resetsAt,
            scannedAt: now,
            priceRevision: priceSnapshot.revision,
            activityAccountingRevision: WeeklyQuotaBootstrapResult.codexActivityAccountingRevision
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

    /// Retained for fixture diagnostics only. Production attribution deliberately
    /// does not use a future model mention to seed earlier usage.
    static func firstModelSlug(in text: String) -> String? {
        guard let range = text.range(of: "\"model\":\"") else { return nil }
        let rest = text[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        let slug = String(rest[..<end])
        return slug.isEmpty ? nil : slug
    }

    @discardableResult
    private static func ingest(line: Substring,
                               isTokenCount: Bool,
                               isTurnContext: Bool,
                               currentModel: inout String?,
                               currentAnchor: inout Date?,
                               previousTokenAnchor: inout Date?,
                               resetsAt: Date,
                               windowMinutes: Int,
                               windowStart: Date,
                               observationCutoff: Date,
                               priceSnapshot: RunwayPriceSnapshot,
                               cumulative: inout CumulativeCounters,
                               dollars: inout Double,
                               pricedVolume: inout Double,
                               unpricedVolume: inout Double,
                               seenAnchors: inout Set<Int>,
                               matchedTurns: inout Int) -> Bool {
        // The caller already prefiltered; only relevant lines are ever JSON-parsed,
        // which is what keeps a multi-megabyte transcript cheap to walk.
        guard let lineData = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
            return false
        }
        let payload = (object["payload"] as? [String: Any]) ?? object

        let structuredTurnContext = (payload["type"] as? String) == "turn_context"
            || (object["type"] as? String) == "turn_context"
        let structuredTokenCount = (payload["type"] as? String) == "token_count"
            || (object["type"] as? String) == "token_count"
        if isTurnContext, structuredTurnContext,
           let model = payload["model"] as? String, !model.isEmpty {
            currentModel = model
        }
        guard isTokenCount, structuredTokenCount else { return true }
        currentAnchor = nil

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
        let info = (payload["info"] as? [String: Any]) ?? payload
        guard let total = info["total_token_usage"] as? [String: Any],
              let timestamp = timestamp(object: object, payload: payload) else { return false }
        let sample = CumulativeCounters.Sample(usage: total)
        if cumulative.isReset(by: sample) { cumulative = CumulativeCounters() }
        var delta = cumulative.advance(to: sample)
        if let last = info["last_token_usage"] as? [String: Any] {
            let request = CumulativeCounters.Sample(usage: last)
            let requestDelta = UsageDelta(sample: request)
            delta = delta.withContextInput(
                request.hasComponents
                    && requestDelta.fresh == delta.fresh
                    && requestDelta.cacheRead == delta.cacheRead
                    && requestDelta.cacheWrite == delta.cacheWrite
                    && requestDelta.output == delta.output
                    ? request.input : nil)
        } else {
            delta = delta.withContextInput(nil)
        }

        // Another account's session, a superseded window, or data written after
        // the quota observation cannot enter this denominator. Normalization
        // still advanced above so a later matching record cannot import it.
        if let a = currentAnchor { seenAnchors.insert(Int(a.timeIntervalSince1970)) }
        guard let anchor = currentAnchor,
              abs(anchor.timeIntervalSince(resetsAt)) < anchorTolerance,
              timestamp >= windowStart,
              timestamp <= observationCutoff else {
            previousTokenAnchor = currentAnchor
            return currentAnchor != nil
        }
        let crossedAnchor = previousTokenAnchor.map {
            abs($0.timeIntervalSince(resetsAt)) >= anchorTolerance
        } ?? false
        previousTokenAnchor = currentAnchor
        guard !crossedAnchor else { return true }
        matchedTurns += 1

        let freshInput = Double(delta.fresh)
        let cached = Double(delta.cacheRead)
        let output = Double(delta.output)
        let cacheWrite = Double(delta.cacheWrite)
        let volume = freshInput + cached + output + cacheWrite
        guard volume > 0 else { return true }

        guard let price = priceSnapshot.price(forModel: currentModel),
              !(price.longContext.map {
                  delta.contextInput == nil && Double(delta.topLine - delta.output) > $0.thresholdInputTokens
              } ?? false),
              let rates = price.rates(for: .standard,
                                      contextInputTokens: delta.contextInput.map(Double.init)) else {
            unpricedVolume += volume
            return true
        }
        pricedVolume += volume
        dollars += rates.dollars(input: freshInput,
                                 cachedInput: cached,
                                 output: output,
                                 cacheWrite5m: cacheWrite,
                                 cacheWrite1h: 0)
        return true
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
