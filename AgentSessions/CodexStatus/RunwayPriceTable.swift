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
/// match the key `claude-sonnet-4-5`. `revision` changes whenever the table
/// content changes so the runway request id recomputes after a refresh.
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

    init(loadBundled: Bool = true, readCache: Bool = true) {
        if loadBundled, let decoded = Self.decode(Data(Self.bundledJSON.utf8)) {
            models = decoded
            _revision = 1
        }
        // Overlay a newer cached manifest if one was fetched previously.
        if readCache, let data = try? Data(contentsOf: Self.cacheURL()), let decoded = Self.decode(data) {
            models = decoded
            _revision += 1
        }
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
            self.lock.lock()
            self.models = decoded
            self._revision += 1
            self.lock.unlock()
            try? data.write(to: Self.cacheURL(), options: .atomic)
        }.resume()
    }

    // MARK: - Decoding

    private struct Manifest: Decodable {
        let version: Int
        let models: [String: RawPrice]
    }
    private struct RawPrice: Decodable {
        let inputPerMTok: Double
        let cachedInputPerMTok: Double
        let outputPerMTok: Double
        let cacheWritePerMTok: Double?
    }

    /// Returns the model map only for a recognized schema version; nil otherwise
    /// (malformed or unrecognized `version` → caller keeps its current table).
    private static func decode(_ data: Data) -> [String: RunwayModelPrice]? {
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.version == supportedVersion,
              !manifest.models.isEmpty else { return nil }
        return manifest.models.mapValues {
            RunwayModelPrice(inputPerMTok: $0.inputPerMTok,
                             cachedInputPerMTok: $0.cachedInputPerMTok,
                             outputPerMTok: $0.outputPerMTok,
                             cacheWritePerMTok: $0.cacheWritePerMTok)
        }
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
    /// Returns true if accepted.
    @discardableResult
    func loadForTesting(json: Data) -> Bool {
        guard let decoded = Self.decode(json) else { return false }
        lock.lock(); models = decoded; _revision += 1; lock.unlock()
        return true
    }
    static func makeForTesting() -> RunwayPriceTable { RunwayPriceTable(loadBundled: true, readCache: false) }
    static func makeEmptyForTesting() -> RunwayPriceTable { RunwayPriceTable(loadBundled: false, readCache: false) }
    #endif

    /// Compiled-in default snapshot. Also published at `docs/prices.json` for the
    /// refresh. Anthropic prices are current public list prices; OpenAI gpt-5.x /
    /// o-series are best-effort ESTIMATES — verify and correct via docs/prices.json
    /// (no app rebuild needed). Keys are longest-prefix match targets.
    static let bundledJSON = """
    {
      "version": 1,
      "updated": "2026-07-14",
      "_note": "USD per million tokens. Keyed by tier so longest-prefix covers every generation (claude-sonnet → claude-sonnet-5, gpt-5 → gpt-5.6). Anthropic are tier list prices; claude-fable and OpenAI gpt-5.x/o-series are ESTIMATES — correct via docs/prices.json (no app rebuild).",
      "models": {
        "claude-opus":      { "inputPerMTok": 15.0, "cachedInputPerMTok": 1.5,  "outputPerMTok": 75.0, "cacheWritePerMTok": 18.75 },
        "claude-sonnet":    { "inputPerMTok": 3.0,  "cachedInputPerMTok": 0.3,  "outputPerMTok": 15.0, "cacheWritePerMTok": 3.75 },
        "claude-haiku":     { "inputPerMTok": 1.0,  "cachedInputPerMTok": 0.1,  "outputPerMTok": 5.0,  "cacheWritePerMTok": 1.25 },
        "claude-fable":     { "inputPerMTok": 3.0,  "cachedInputPerMTok": 0.3,  "outputPerMTok": 15.0, "cacheWritePerMTok": 3.75 },
        "claude-3-opus":    { "inputPerMTok": 15.0, "cachedInputPerMTok": 1.5,  "outputPerMTok": 75.0, "cacheWritePerMTok": 18.75 },
        "claude-3-5-sonnet":{ "inputPerMTok": 3.0,  "cachedInputPerMTok": 0.3,  "outputPerMTok": 15.0, "cacheWritePerMTok": 3.75 },
        "claude-3-5-haiku": { "inputPerMTok": 0.8,  "cachedInputPerMTok": 0.08, "outputPerMTok": 4.0,  "cacheWritePerMTok": 1.0 },
        "gpt-5":            { "inputPerMTok": 1.25, "cachedInputPerMTok": 0.125, "outputPerMTok": 10.0, "cacheWritePerMTok": null },
        "gpt-4":            { "inputPerMTok": 2.5,  "cachedInputPerMTok": 1.25,  "outputPerMTok": 10.0, "cacheWritePerMTok": null },
        "o4-mini":          { "inputPerMTok": 1.1,  "cachedInputPerMTok": 0.275, "outputPerMTok": 4.4,  "cacheWritePerMTok": null },
        "o3":               { "inputPerMTok": 2.0,  "cachedInputPerMTok": 0.5,   "outputPerMTok": 8.0,  "cacheWritePerMTok": null }
      }
    }
    """
}
