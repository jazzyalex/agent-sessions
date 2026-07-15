import Foundation

/// Per-model API price (USD per million tokens) for the runway `$` presentation.
struct RunwayModelPrice: Equatable, Sendable {
    let inputPerMTok: Double        // fresh (non-cached) input
    let cachedInputPerMTok: Double  // cached-input reads
    let outputPerMTok: Double
    let cacheWritePerMTok: Double?  // Claude cache creation; nil → falls back to input
}

/// Model→price lookup for `$` burn. Ships a compiled-in default snapshot and,
/// optionally, refreshes from a read-only public manifest so prices can be
/// corrected without an app release. The fetch is a plain GET of a static file —
/// no user or session data is sent (same trust model as the Sparkle appcast).
///
/// Lookup is **longest-prefix**: dated slugs like `claude-sonnet-4-5-20250929`
/// match the key `claude-sonnet-4-5`. `revision` bumps on every accepted table
/// change; it's informational only — the runway request id already recomputes on
/// its 5s refresh bucket, so a refreshed price lands within one cycle.
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
            _revision = 1
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
    private func adopt(_ decoded: (models: [String: RunwayModelPrice], updated: String)) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard decoded.updated >= loadedUpdated else { return false }
        models = decoded.models
        loadedUpdated = decoded.updated
        _revision += 1
        return true
    }

    var isEmpty: Bool { lock.lock(); defer { lock.unlock() }; return models.isEmpty }
    var revision: Int { lock.lock(); defer { lock.unlock() }; return _revision }

    /// Longest-prefix price lookup. nil slug or no matching key → nil (→ $ unpriceable).
    func price(forModel slug: String?) -> RunwayModelPrice? {
        guard let slug, !slug.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let exact = models[slug] { return exact }
        var best: (key: String, price: RunwayModelPrice)?
        for (key, price) in models where slug.hasPrefix(key) {
            if best == nil || key.count > best!.key.count { best = (key, price) }
        }
        return best?.price
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
    private struct RawPrice: Decodable {
        let inputPerMTok: Double
        let cachedInputPerMTok: Double
        let outputPerMTok: Double
        let cacheWritePerMTok: Double?
    }

    /// Returns the model map + its `updated` date, only for a recognized schema
    /// version; nil otherwise (malformed or unrecognized `version` → caller keeps
    /// its current table). A manifest with no `updated` sorts oldest, so it can
    /// never shadow a dated bundled table.
    private static func decode(_ data: Data) -> (models: [String: RunwayModelPrice], updated: String)? {
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.version == supportedVersion,
              !manifest.models.isEmpty else { return nil }
        let models = manifest.models.mapValues {
            RunwayModelPrice(inputPerMTok: $0.inputPerMTok,
                             cachedInputPerMTok: $0.cachedInputPerMTok,
                             outputPerMTok: $0.outputPerMTok,
                             cacheWritePerMTok: $0.cacheWritePerMTok)
        }
        return (models, manifest.updated ?? "")
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
    /// refresh. Verified 2026-07-14 against the official pricing pages
    /// (platform.claude.com/docs/en/about-claude/pricing and
    /// developers.openai.com/api/docs/pricing). Keyed by tier so longest-prefix
    /// resolves every generation (`claude-sonnet` → claude-sonnet-5, `gpt-5.6-sol`
    /// exact, `gpt-5` → any other gpt-5.x). Correct via docs/prices.json — no rebuild.
    ///
    /// `cachedInputPerMTok` = cache-hit read (0.1× input). `cacheWritePerMTok` =
    /// 5-minute cache write (1.25× input); unused for Codex (its logs carry no
    /// cache-creation tokens) so it's null for OpenAI. Sonnet 5 is at introductory
    /// $2/$10 through 2026-08-31; the stable $3/$15 is bundled — flip in prices.json
    /// if you want the promo reflected.
    static let bundledJSON = """
    {
      "version": 1,
      "updated": "2026-07-14",
      "_note": "USD per million tokens. Verified 2026-07-14 from platform.claude.com and developers.openai.com. Keyed by tier so longest-prefix covers every generation; legacy keys are kept so an older model is priced rather than dropped from the $ view. cachedInputPerMTok=cache read (0.1x input); cacheWritePerMTok=5m cache write (1.25x) — only ever consumed for Claude, since Codex logs carry no cache-creation tokens. Sonnet 5 shown at stable $3/$15 (intro $2/$10 runs through 2026-08-31). Correct here anytime — no app rebuild.",
      "models": {
        "claude-opus":     { "inputPerMTok": 5.0,  "cachedInputPerMTok": 0.5,   "outputPerMTok": 25.0, "cacheWritePerMTok": 6.25 },
        "claude-sonnet":   { "inputPerMTok": 3.0,  "cachedInputPerMTok": 0.3,   "outputPerMTok": 15.0, "cacheWritePerMTok": 3.75 },
        "claude-haiku":    { "inputPerMTok": 1.0,  "cachedInputPerMTok": 0.1,   "outputPerMTok": 5.0,  "cacheWritePerMTok": 1.25 },
        "claude-fable":    { "inputPerMTok": 10.0, "cachedInputPerMTok": 1.0,   "outputPerMTok": 50.0, "cacheWritePerMTok": 12.5 },
        "claude-mythos":   { "inputPerMTok": 10.0, "cachedInputPerMTok": 1.0,   "outputPerMTok": 50.0, "cacheWritePerMTok": 12.5 },
        "claude-opus-4-1":  { "inputPerMTok": 15.0, "cachedInputPerMTok": 1.5,  "outputPerMTok": 75.0, "cacheWritePerMTok": 18.75 },
        "claude-3-opus":    { "inputPerMTok": 15.0, "cachedInputPerMTok": 1.5,  "outputPerMTok": 75.0, "cacheWritePerMTok": 18.75 },
        "claude-3-5-sonnet":{ "inputPerMTok": 3.0,  "cachedInputPerMTok": 0.3,  "outputPerMTok": 15.0, "cacheWritePerMTok": 3.75 },
        "claude-3-5-haiku": { "inputPerMTok": 0.8,  "cachedInputPerMTok": 0.08, "outputPerMTok": 4.0,  "cacheWritePerMTok": 1.0 },
        "gpt-5.6-sol":     { "inputPerMTok": 5.0,  "cachedInputPerMTok": 0.5,   "outputPerMTok": 30.0, "cacheWritePerMTok": 6.25 },
        "gpt-5.6-terra":   { "inputPerMTok": 2.5,  "cachedInputPerMTok": 0.25,  "outputPerMTok": 15.0, "cacheWritePerMTok": 3.125 },
        "gpt-5.6-luna":    { "inputPerMTok": 1.0,  "cachedInputPerMTok": 0.1,   "outputPerMTok": 6.0,  "cacheWritePerMTok": 1.25 },
        "gpt-5.6":         { "inputPerMTok": 5.0,  "cachedInputPerMTok": 0.5,   "outputPerMTok": 30.0, "cacheWritePerMTok": 6.25 },
        "gpt-5.5":         { "inputPerMTok": 5.0,  "cachedInputPerMTok": 0.5,   "outputPerMTok": 30.0, "cacheWritePerMTok": null },
        "gpt-5.4-mini":    { "inputPerMTok": 0.75, "cachedInputPerMTok": 0.075, "outputPerMTok": 4.5,  "cacheWritePerMTok": null },
        "gpt-5.4":         { "inputPerMTok": 2.5,  "cachedInputPerMTok": 0.25,  "outputPerMTok": 15.0, "cacheWritePerMTok": null },
        "gpt-5":           { "inputPerMTok": 1.25, "cachedInputPerMTok": 0.125, "outputPerMTok": 10.0, "cacheWritePerMTok": null }
      }
    }
    """
}
