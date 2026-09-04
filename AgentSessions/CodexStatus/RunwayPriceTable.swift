import Foundation
import CryptoKit

/// Which billing tier a usage record was served at.
///
/// Read from the record's own `usage.speed` and NEVER inferred from the model name:
/// Opus 4.7 rejects `speed: "fast"` outright, and Opus 4.6 accepts it and then bills
/// standard while still reporting `"standard"` — so a name-based guess would double
/// the bill in exactly the case that most looks like a fast session.
enum RunwaySpeedTier: String, Equatable, Sendable {
    case standard
    case fast

    /// Only the literal `"fast"` selects the fast tier. Anything else — `"standard"`,
    /// null, absent, or a tier introduced after this build — reads as standard, so an
    /// unrecognized value can never silently double a session's cost.
    init(usageValue: Any?) {
        self = (usageValue as? String) == "fast" ? .fast : .standard
    }
}

/// One coherent set of per-MTok rates.
///
/// Fast mode is a whole second rate set rather than a multiplier on the standard one.
/// Output is exactly 2× today, but that is a coincidence of the current price list,
/// and the cache multipliers are defined off the *fast* input base — a 1-hour write on
/// fast Opus 5 is 2 × $10, not 2 × $5.
struct RunwayRateSet: Equatable, Sendable {
    let inputPerMTok: Double        // fresh (non-cached) input
    let cachedInputPerMTok: Double  // cached-input reads
    let outputPerMTok: Double
    /// 5-minute-TTL cache write (1.25× input). nil → falls back to input.
    let cacheWritePerMTok: Double?
    /// 1-hour-TTL cache write (2× input). nil → falls back to the 5-minute rate, then
    /// to input — the pre-split behavior, kept so a manifest published without this
    /// column still prices rather than dropping the session out of `$`.
    let cacheWrite1hPerMTok: Double?

    /// USD for a bundle of tokens at these rates.
    func dollars(input: Double,
                 cachedInput: Double,
                 output: Double,
                 cacheWrite5m: Double,
                 cacheWrite1h: Double) -> Double {
        let write5m = cacheWritePerMTok ?? inputPerMTok
        let write1h = cacheWrite1hPerMTok ?? write5m
        return (input * inputPerMTok
                + cachedInput * cachedInputPerMTok
                + output * outputPerMTok
                + cacheWrite5m * write5m
                + cacheWrite1h * write1h) / 1_000_000
    }
}

/// Per-model API price (USD per million tokens) for the runway `$` presentation:
/// the standard rate set, plus the fast-mode set for models that have one.
struct RunwayModelPrice: Equatable, Sendable {
    let standard: RunwayRateSet
    /// nil when this model has no fast tier. A record that nevertheless reports
    /// `speed: "fast"` is left UNPRICEABLE rather than billed at standard — silently
    /// halving a fast session is the exact failure this split exists to prevent, and
    /// the calculator already prefers an honest drop to a confident wrong number.
    let fast: RunwayRateSet?
    let longContext: RunwayLongContextPrice?

    /// Rates for one observed tier, or nil when that tier has no rate set here.
    func rates(for speed: RunwaySpeedTier,
               contextInputTokens: Double? = nil) -> RunwayRateSet? {
        let base: RunwayRateSet?
        switch speed {
        case .standard: base = standard
        case .fast: base = fast
        }
        guard let base else { return nil }
        guard let contextInputTokens, let longContext,
              contextInputTokens > longContext.thresholdInputTokens else { return base }
        return RunwayRateSet(
            inputPerMTok: base.inputPerMTok * longContext.inputMultiplier,
            cachedInputPerMTok: base.cachedInputPerMTok * longContext.inputMultiplier,
            outputPerMTok: base.outputPerMTok * longContext.outputMultiplier,
            cacheWritePerMTok: base.cacheWritePerMTok.map { $0 * longContext.inputMultiplier },
            cacheWrite1hPerMTok: base.cacheWrite1hPerMTok.map { $0 * longContext.inputMultiplier }
        )
    }

    /// Standard-tier accessors. Codex has no speed tiers at all, so its callers
    /// (weekly calibration, weekly bootstrap) read the standard rates through these
    /// rather than unwrapping a rate set they can never fail to have.
    var inputPerMTok: Double { standard.inputPerMTok }
    var cachedInputPerMTok: Double { standard.cachedInputPerMTok }
    var outputPerMTok: Double { standard.outputPerMTok }
    var cacheWritePerMTok: Double? { standard.cacheWritePerMTok }
    var cacheWrite1hPerMTok: Double? { standard.cacheWrite1hPerMTok }
}

struct RunwayLongContextPrice: Equatable, Sendable {
    let thresholdInputTokens: Double
    let inputMultiplier: Double
    let outputMultiplier: Double
}

/// Immutable view of one accepted price manifest. Session telemetry takes one
/// snapshot before pricing so a background refresh cannot mix revisions inside a
/// single session or between its event rows and total.
struct RunwayPriceSnapshot: Sendable {
    let models: [String: RunwayModelPrice]
    let updatedDate: String
    let revision: Int

    func price(forModel slug: String?) -> RunwayModelPrice? {
        guard let slug, !slug.isEmpty else { return nil }
        if let exact = models[slug] { return exact }
        var best: (key: String, price: RunwayModelPrice)?
        for (key, price) in models where slug.hasPrefix(key) {
            if key.hasPrefix("gpt-"), !Self.isRecognizedGPTSnapshot(slug, extending: key) { continue }
            if best == nil || key.count > best!.key.count { best = (key, price) }
        }
        return best?.price
    }

    private static func isRecognizedGPTSnapshot(_ slug: String, extending key: String) -> Bool {
        let suffix = String(slug.dropFirst(key.count))
        if suffix.count == 9, suffix.first == "-", suffix.dropFirst().allSatisfy(\.isNumber) { return true }
        guard suffix.count == 11, suffix.first == "-" else { return false }
        let date = Array(suffix.dropFirst())
        return date[4] == "-" && date[7] == "-"
            && date.enumerated().allSatisfy { index, character in
                index == 4 || index == 7 ? character == "-" : character.isNumber
            }
    }
}

/// Model→price lookup for `$` burn. Ships a compiled-in default snapshot and,
/// optionally, refreshes from a read-only public manifest so prices can be
/// corrected without an app release. The fetch is a plain GET of a static file —
/// no user or session data is sent (same trust model as the Sparkle appcast).
///
/// Lookup is **longest-prefix** for Claude and exact-or-dated-snapshot for GPT.
/// `revision` is a stable hash of manifest content, so persisted calibrations see
/// the same identity after restart and invalidate when accepted prices change.
///
/// A cached or fetched manifest is only accepted when its `updated` date is at
/// least as new as the compiled-in table's. Without that check, a client that
/// cached an older manifest would keep overriding a corrected bundled table
/// forever (indefinitely, if it's offline or the host still serves the old file).
///
/// `@unchecked Sendable`: lock-guarded mutable state touched from a background
/// URLSession callback (mirrors `RunwayAggregateBurnHold`).
final class RunwayPriceTable: @unchecked Sendable {
    static let shared = RunwayPriceTable()

    /// Only manifests declaring this schema version are accepted; an unrecognized
    /// version is ignored (keeps the current table) so a future schema change
    /// can't poison old clients.
    static let supportedVersion = 1
    private static let manifestURL = URL(string: "https://jazzyalex.github.io/agent-sessions/prices.json")!
    private static let minRefreshInterval: TimeInterval = 24 * 60 * 60

    private let lock = NSLock()
    private var models: [String: RunwayModelPrice] = [:]
    private var _revision = 0
    private var lastFetchAt: Date?
    /// `updated` of the table currently in `models`. ISO `yyyy-MM-dd` sorts
    /// lexicographically, so a plain string compare is a correct date compare.
    private var loadedUpdated: String = ""

    init(loadBundled: Bool = true, readCache: Bool = true) {
        if loadBundled, let decoded = Self.decode(Data(Self.bundledJSON.utf8)) {
            models = decoded.models
            loadedUpdated = decoded.updated
            _revision = decoded.revision
        }
        // Overlay a previously fetched manifest unless it predates what we ship.
        if readCache, let data = try? Data(contentsOf: Self.cacheURL()), let decoded = Self.decode(data) {
            adopt(decoded)
        }
    }

    /// The single acceptance rule for every source (cache overlay, network refresh,
    /// tests): take a manifest unless it is OLDER than the table already loaded.
    /// Returns false when it was too old and was ignored.
    ///
    /// Equal dates are accepted deliberately. The manifest is the correctable source
    /// of truth, so a same-date re-publish is a correction we want — and requiring
    /// the cache to be strictly newer would throw such a correction away on the next
    /// launch, reverting to the very price it fixed. The mirror hazard (a same-date
    /// cache shadowing a bundled table that a new build silently corrected) is
    /// prevented by process instead: `docs/prices.json` documents that `updated` MUST
    /// advance on every edit, and the bundled copy moves with it.
    @discardableResult
    private func adopt(_ decoded: (models: [String: RunwayModelPrice], updated: String, revision: Int)) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard decoded.updated >= loadedUpdated else { return false }
        models = decoded.models
        loadedUpdated = decoded.updated
        _revision = decoded.revision
        return true
    }

    var isEmpty: Bool { lock.lock(); defer { lock.unlock() }; return models.isEmpty }
    var revision: Int { lock.lock(); defer { lock.unlock() }; return _revision }
    /// `updated` date of the table currently loaded. Stamped onto stored telemetry
    /// cost results so a saved figure can be re-judged when rates move.
    var updatedDate: String { lock.lock(); defer { lock.unlock() }; return loadedUpdated }

    func snapshot() -> RunwayPriceSnapshot {
        lock.lock(); defer { lock.unlock() }
        return RunwayPriceSnapshot(models: models, updatedDate: loadedUpdated, revision: _revision)
    }

    /// nil slug or no safe matching key → nil (→ $ unpriceable).
    func price(forModel slug: String?) -> RunwayModelPrice? {
        guard let slug, !slug.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let exact = models[slug] { return exact }
        var best: (key: String, price: RunwayModelPrice)?
        for (key, price) in models where slug.hasPrefix(key) {
            if key.hasPrefix("gpt-"), !Self.isRecognizedGPTSnapshot(slug, extending: key) {
                continue
            }
            if best == nil || key.count > best!.key.count { best = (key, price) }
        }
        return best?.price
    }

    private static func isRecognizedGPTSnapshot(_ slug: String, extending key: String) -> Bool {
        let suffix = String(slug.dropFirst(key.count))
        if suffix.count == 9, suffix.first == "-", suffix.dropFirst().allSatisfy(\.isNumber) {
            return true
        }
        guard suffix.count == 11, suffix.first == "-" else { return false }
        let date = Array(suffix.dropFirst())
        return date[4] == "-" && date[7] == "-"
            && date.enumerated().allSatisfy { index, character in
                index == 4 || index == 7 ? character == "-" : character.isNumber
            }
    }

    /// Fire-and-forget: fetch the manifest at most once/day and cache it. Never
    /// blocks; failures are silent (the current table stays).
    func refreshInBackground(now: Date = Date()) {
        lock.lock()
        if let last = lastFetchAt, now.timeIntervalSince(last) < Self.minRefreshInterval {
            lock.unlock(); return
        }
        lastFetchAt = now
        lock.unlock()
        var request = URLRequest(url: Self.manifestURL)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            guard let self,
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let data, let decoded = Self.decode(data) else { return }
            // Ignore (and don't cache) a manifest older than what we already have —
            // e.g. the host still serves a file predating this build's bundled table.
            guard self.adopt(decoded) else { return }
            try? data.write(to: Self.cacheURL(), options: .atomic)
        }.resume()
    }

    // MARK: - Decoding

    private struct Manifest: Decodable {
        let version: Int
        let updated: String?
        let models: [String: RawPrice]
    }
    /// The five rate fields, shared by a model's standard rates and its nested
    /// `fast` object. Spelled out twice rather than made recursive because a struct
    /// cannot store an Optional of itself.
    private struct RawRates: Decodable {
        let inputPerMTok: Double
        let cachedInputPerMTok: Double
        let outputPerMTok: Double
        let cacheWritePerMTok: Double?
        let cacheWrite1hPerMTok: Double?

        var rateSet: RunwayRateSet {
            RunwayRateSet(inputPerMTok: inputPerMTok,
                          cachedInputPerMTok: cachedInputPerMTok,
                          outputPerMTok: outputPerMTok,
                          cacheWritePerMTok: cacheWritePerMTok,
                          cacheWrite1hPerMTok: cacheWrite1hPerMTok)
        }
    }
    private struct RawLongContext: Decodable {
        let thresholdInputTokens: Double
        let inputMultiplier: Double
        let outputMultiplier: Double

        var price: RunwayLongContextPrice {
            RunwayLongContextPrice(thresholdInputTokens: thresholdInputTokens,
                                   inputMultiplier: inputMultiplier,
                                   outputMultiplier: outputMultiplier)
        }
    }
    /// `cacheWrite1hPerMTok` and `fast` are optional, so this still decodes a
    /// manifest published before either existed — schema `version` stays 1, and an
    /// older client simply ignores the new keys.
    private struct RawPrice: Decodable {
        let inputPerMTok: Double
        let cachedInputPerMTok: Double
        let outputPerMTok: Double
        let cacheWritePerMTok: Double?
        let cacheWrite1hPerMTok: Double?
        let fast: RawRates?
        let longContext: RawLongContext?

        var standardRateSet: RunwayRateSet {
            RunwayRateSet(inputPerMTok: inputPerMTok,
                          cachedInputPerMTok: cachedInputPerMTok,
                          outputPerMTok: outputPerMTok,
                          cacheWritePerMTok: cacheWritePerMTok,
                          cacheWrite1hPerMTok: cacheWrite1hPerMTok)
        }
    }

    /// Returns the model map + its `updated` date, only for a recognized schema
    /// version; nil otherwise (malformed or unrecognized `version` → caller keeps
    /// its current table). A manifest with no `updated` sorts oldest, so it can
    /// never shadow a dated bundled table.
    private static func decode(_ data: Data)
        -> (models: [String: RunwayModelPrice], updated: String, revision: Int)? {
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.version == supportedVersion,
              !manifest.models.isEmpty else { return nil }
        let models = manifest.models.mapValues {
            RunwayModelPrice(standard: $0.standardRateSet,
                             fast: $0.fast?.rateSet,
                             longContext: $0.longContext?.price)
        }
        guard var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        object.removeValue(forKey: "_note")
        object.removeValue(forKey: "updated")
        guard let canonical = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        let digest = SHA256.hash(data: canonical)
        let stableRevision = digest.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            & UInt64(Int.max)
        return (models, manifest.updated ?? "", Int(stableRevision))
    }

    private static func cacheURL() -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("AgentSessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("prices.json")
    }

    #if DEBUG
    /// Test seam: load a manifest from raw JSON (bypassing the network/cache).
    /// Returns true if accepted — applies the same version + `updated`-date rules
    /// as the real cache/network paths, so tests exercise production acceptance.
    @discardableResult
    func loadForTesting(json: Data) -> Bool {
        guard let decoded = Self.decode(json) else { return false }
        return adopt(decoded)
    }
    static func makeForTesting() -> RunwayPriceTable { RunwayPriceTable(loadBundled: true, readCache: false) }
    static func makeEmptyForTesting() -> RunwayPriceTable { RunwayPriceTable(loadBundled: false, readCache: false) }
    #endif

    /// Compiled-in default snapshot. Also published at `docs/prices.json` for the
    /// refresh — the two MUST stay identical, because whichever is newer wins outright
    /// and a rate that reaches only one of them is silently reverted by the other.
    /// Verified 2026-09-03 against the official pricing pages
    /// (platform.claude.com/docs/en/about-claude/pricing and
    /// developers.openai.com/api/docs/pricing). Keyed by tier so longest-prefix
    /// resolves every generation (`claude-sonnet` → claude-sonnet-5, `gpt-5.6-sol`
    /// exact, `gpt-5` → any other gpt-5.x). Correct via docs/prices.json — no rebuild.
    ///
    /// `cachedInputPerMTok` = cache-hit read (0.1× input). `cacheWritePerMTok` =
    /// 5-minute cache write (1.25× input); `cacheWrite1hPerMTok` = 1-hour cache write
    /// (2× input). Both are omitted on the GPT keys, which have no TTL split — the
    /// 1-hour column then falls back to the 5-minute one.
    ///
    /// `fast` is Anthropic's fast mode, a research preview on Opus 5 and Opus 4.8
    /// only, published as $10/$50 per MTok. Its cache rates are derived off that
    /// $10 fast input base (0.1× read, 1.25× 5m write, 2× 1h write), which is how the
    /// multipliers are defined; only the $10/$50 pair is documented directly. The
    /// generic `claude-opus` key deliberately has NO fast set, so an Opus 4.6/4.7
    /// record that somehow reported `speed:"fast"` drops out of `$` instead of being
    /// billed at double. Sonnet 5's $2/$10 price is permanent; the generic Sonnet key
    /// stays at $3/$15 for Sonnet 4.x.
    static let bundledJSON = """
    {
      "version": 1,
      "updated": "2026-09-03",
      "_note": "USD per million tokens. Rates verified 2026-09-03 from platform.claude.com and developers.openai.com. Sol requests above 272K input tokens use 2x input and 1.5x output rates. GPT prefix fallback accepts dated snapshots only; Claude family prefixes remain supported. cachedInputPerMTok is cache read; cacheWritePerMTok is a 5-minute cache write (1.25x input) and cacheWrite1hPerMTok a 1-hour one (2x input), omitted on GPT keys which have no TTL split. The optional fast object is Anthropic fast mode. Codex logs currently carry no cache-creation tokens. codex-auto-review is an unpublished internal label priced at the GPT-5.6 Sol default. Correct here anytime and advance updated on every edit, in BOTH this file and the bundled copy in RunwayPriceTable.swift.",
      "models": {
        "claude-opus-5":   { "inputPerMTok": 5.0,  "cachedInputPerMTok": 0.5,   "outputPerMTok": 25.0, "cacheWritePerMTok": 6.25, "cacheWrite1hPerMTok": 10.0,
                             "fast": { "inputPerMTok": 10.0, "cachedInputPerMTok": 1.0, "outputPerMTok": 50.0, "cacheWritePerMTok": 12.5, "cacheWrite1hPerMTok": 20.0 } },
        "claude-opus-4-8": { "inputPerMTok": 5.0,  "cachedInputPerMTok": 0.5,   "outputPerMTok": 25.0, "cacheWritePerMTok": 6.25, "cacheWrite1hPerMTok": 10.0,
                             "fast": { "inputPerMTok": 10.0, "cachedInputPerMTok": 1.0, "outputPerMTok": 50.0, "cacheWritePerMTok": 12.5, "cacheWrite1hPerMTok": 20.0 } },
        "claude-opus":     { "inputPerMTok": 5.0,  "cachedInputPerMTok": 0.5,   "outputPerMTok": 25.0, "cacheWritePerMTok": 6.25, "cacheWrite1hPerMTok": 10.0 },
        "claude-sonnet-5": { "inputPerMTok": 2.0,  "cachedInputPerMTok": 0.2,   "outputPerMTok": 10.0, "cacheWritePerMTok": 2.5,  "cacheWrite1hPerMTok": 4.0 },
        "claude-sonnet":   { "inputPerMTok": 3.0,  "cachedInputPerMTok": 0.3,   "outputPerMTok": 15.0, "cacheWritePerMTok": 3.75, "cacheWrite1hPerMTok": 6.0 },
        "claude-haiku":    { "inputPerMTok": 1.0,  "cachedInputPerMTok": 0.1,   "outputPerMTok": 5.0,  "cacheWritePerMTok": 1.25, "cacheWrite1hPerMTok": 2.0 },
        "claude-fable":    { "inputPerMTok": 10.0, "cachedInputPerMTok": 1.0,   "outputPerMTok": 50.0, "cacheWritePerMTok": 12.5, "cacheWrite1hPerMTok": 20.0 },
        "claude-mythos":   { "inputPerMTok": 10.0, "cachedInputPerMTok": 1.0,   "outputPerMTok": 50.0, "cacheWritePerMTok": 12.5, "cacheWrite1hPerMTok": 20.0 },
        "claude-opus-4-1":  { "inputPerMTok": 15.0, "cachedInputPerMTok": 1.5,  "outputPerMTok": 75.0, "cacheWritePerMTok": 18.75, "cacheWrite1hPerMTok": 30.0 },
        "claude-3-opus":    { "inputPerMTok": 15.0, "cachedInputPerMTok": 1.5,  "outputPerMTok": 75.0, "cacheWritePerMTok": 18.75, "cacheWrite1hPerMTok": 30.0 },
        "claude-3-5-sonnet":{ "inputPerMTok": 3.0,  "cachedInputPerMTok": 0.3,  "outputPerMTok": 15.0, "cacheWritePerMTok": 3.75, "cacheWrite1hPerMTok": 6.0 },
        "claude-3-5-haiku": { "inputPerMTok": 0.8,  "cachedInputPerMTok": 0.08, "outputPerMTok": 4.0,  "cacheWritePerMTok": 1.0,  "cacheWrite1hPerMTok": 1.6 },
        "gpt-5.6-sol":     { "inputPerMTok": 4.0,  "cachedInputPerMTok": 0.4,   "outputPerMTok": 20.0, "cacheWritePerMTok": 5.0,
                             "longContext": { "thresholdInputTokens": 272000, "inputMultiplier": 2.0, "outputMultiplier": 1.5 } },
        "gpt-5.6-terra":   { "inputPerMTok": 2.0,  "cachedInputPerMTok": 0.2,   "outputPerMTok": 12.0, "cacheWritePerMTok": 2.5,
                             "longContext": { "thresholdInputTokens": 272000, "inputMultiplier": 2.0, "outputMultiplier": 1.5 } },
        "gpt-5.6-luna":    { "inputPerMTok": 0.2,  "cachedInputPerMTok": 0.02,  "outputPerMTok": 1.2,  "cacheWritePerMTok": 0.25,
                             "longContext": { "thresholdInputTokens": 272000, "inputMultiplier": 2.0, "outputMultiplier": 1.5 } },
        "gpt-5.6":         { "inputPerMTok": 4.0,  "cachedInputPerMTok": 0.4,   "outputPerMTok": 20.0, "cacheWritePerMTok": 5.0,
                             "longContext": { "thresholdInputTokens": 272000, "inputMultiplier": 2.0, "outputMultiplier": 1.5 } },
        "gpt-5.5":         { "inputPerMTok": 5.0,  "cachedInputPerMTok": 0.5,   "outputPerMTok": 30.0, "cacheWritePerMTok": null },
        "gpt-5.4-mini":    { "inputPerMTok": 0.75, "cachedInputPerMTok": 0.075, "outputPerMTok": 4.5,  "cacheWritePerMTok": null },
        "gpt-5.4":         { "inputPerMTok": 2.5,  "cachedInputPerMTok": 0.25,  "outputPerMTok": 15.0, "cacheWritePerMTok": null },
        "gpt-5":           { "inputPerMTok": 1.25, "cachedInputPerMTok": 0.125, "outputPerMTok": 10.0, "cacheWritePerMTok": null },
        "codex-auto-review": { "inputPerMTok": 4.0, "cachedInputPerMTok": 0.4,  "outputPerMTok": 20.0, "cacheWritePerMTok": 5.0,
                               "longContext": { "thresholdInputTokens": 272000, "inputMultiplier": 2.0, "outputMultiplier": 1.5 } }
      }
    }
    """
}
