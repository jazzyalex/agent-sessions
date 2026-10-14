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
    /// The provider did not expose a billing tier, but another trusted source
    /// normalized the record to the standard API-equivalent rate set. This is
    /// intentionally distinct from an observed `standard` value in provenance.
    case standardNormalized = "standard-normalized"
    case fast
    /// Sentinel used when a raw usage value is absent or not understood. It has
    /// no rate set: callers must not turn an unknown tier into standard pricing.
    case unknown

    /// The Claude source contract treats an absent speed as standard. An explicit
    /// value is evidence, so an unrecognized string or type must remain unknown
    /// and make pricing fail closed.
    init(usageValue: Any?) {
        guard let usageValue else { self = .standard; return }
        guard let raw = usageValue as? String,
              let tier = Self(rawValue: raw) else { self = .unknown; return }
        self = tier
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
    /// Regional inference multiplier published for this exact model generation.
    /// nil means the model is not subject to regional pricing.
    let inferenceGeoUSMultiplier: Double?

    /// Rates for one observed tier, or nil when that tier has no rate set here.
    func rates(for speed: RunwaySpeedTier,
               contextInputTokens: Double? = nil,
               inferenceGeo: String? = nil) -> RunwayRateSet? {
        let base: RunwayRateSet?
        switch speed {
        case .standard, .standardNormalized: base = standard
        case .fast: base = fast
        case .unknown: base = nil
        }
        guard var resolved = base else { return nil }
        if let contextInputTokens, let longContext,
           contextInputTokens > longContext.thresholdInputTokens {
            resolved = RunwayRateSet(
                inputPerMTok: resolved.inputPerMTok * longContext.inputMultiplier,
                cachedInputPerMTok: resolved.cachedInputPerMTok * longContext.inputMultiplier,
                outputPerMTok: resolved.outputPerMTok * longContext.outputMultiplier,
                cacheWritePerMTok: resolved.cacheWritePerMTok.map { $0 * longContext.inputMultiplier },
                cacheWrite1hPerMTok: resolved.cacheWrite1hPerMTok.map { $0 * longContext.inputMultiplier }
            )
        }
        switch inferenceGeo {
        case nil, "global", "not_available", "": return resolved
        case "us":
            guard let multiplier = inferenceGeoUSMultiplier else { return nil }
            return resolved.scaled(by: multiplier)
        default: return nil
        }
    }

    /// Standard-rate accessors. Codex callers use these for an explicitly
    /// standard-normalized API-equivalent estimate because rollout logs do not
    /// preserve the actual service tier.
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

private extension RunwayRateSet {
    func scaled(by multiplier: Double) -> RunwayRateSet {
        RunwayRateSet(inputPerMTok: inputPerMTok * multiplier,
                      cachedInputPerMTok: cachedInputPerMTok * multiplier,
                      outputPerMTok: outputPerMTok * multiplier,
                      cacheWritePerMTok: cacheWritePerMTok.map { $0 * multiplier },
                      cacheWrite1hPerMTok: cacheWrite1hPerMTok.map { $0 * multiplier })
    }
}

/// Immutable view of one accepted price manifest. Session telemetry takes one
/// snapshot before pricing so a background refresh cannot mix revisions inside a
/// single session or between its event rows and total.
struct RunwayPriceSnapshot: Sendable {
    let models: [String: RunwayModelPrice]
    /// Normalized model string → `models` key. See `ModelPriceKeyResolver`.
    let aliases: [String: String]
    let updatedDate: String
    /// Changes only when the model/rate semantics change. Calibration scopes use
    /// this value so a date or note-only manifest edit does not discard learning.
    let revision: Int
    var semanticRevision: Int { revision }
    /// Exact canonical JSON fingerprint, including manifest metadata. Cache and
    /// telemetry provenance can use this when byte/content identity matters.
    let manifestFingerprint: String
    /// Provider name (`"claude"`, `"codex"`) → semantic hash of that provider's
    /// own rate rows. See `rateRevision(forProvider:)`.
    let providerRevisions: [String: Int]

    init(models: [String: RunwayModelPrice], aliases: [String: String] = [:],
         updatedDate: String, revision: Int, manifestFingerprint: String,
         providerRevisions: [String: Int] = [:]) {
        self.models = models
        self.aliases = aliases
        self.updatedDate = updatedDate
        self.revision = revision
        self.manifestFingerprint = manifestFingerprint
        self.providerRevisions = providerRevisions
    }

    /// Semantic hash of one provider's own rate rows. Weekly-quota calibration is
    /// keyed by this, never by the global `revision`.
    func rateRevision(forProvider provider: String) -> Int {
        providerRevisions[provider] ?? 0
    }

    func price(forModel slug: String?) -> RunwayModelPrice? {
        Self.price(forModel: slug, in: models)
    }

    /// The single matcher. Claude keys keep their guarded prefix rule; every
    /// other key (GPT and all vendors) matches exactly or with a dated-snapshot
    /// suffix, never by bare prefix, so a variant such as `kimi-k2.7-code-v2`
    /// cannot inherit a base rate.
    static func price(forModel slug: String?,
                      in models: [String: RunwayModelPrice]) -> RunwayModelPrice? {
        guard let slug, !slug.isEmpty else { return nil }
        if let exact = models[slug] { return exact }
        var best: (key: String, price: RunwayModelPrice)?
        for (key, price) in models where slug.hasPrefix(key) {
            if key.hasPrefix("claude-") {
                guard isRecognizedClaudeSlug(slug, extending: key) else { continue }
            } else {
                guard isDatedSnapshot(slug, extending: key) else { continue }
            }
            if best == nil || key.count > best!.key.count { best = (key, price) }
        }
        return best?.price
    }

    /// Raw slug first, so every session that prices today keeps its result; then
    /// the resolved key.
    func resolvedPrice(forModel raw: String?) -> (price: RunwayModelPrice, viaFreeRoute: Bool)? {
        if let direct = price(forModel: raw) { return (direct, false) }
        guard let resolved = ModelPriceKeyResolver.resolve(raw, aliases: aliases),
              let price = price(forModel: resolved.key) else { return nil }
        return (price, resolved.viaFreeRoute)
    }

    private static func isDatedSnapshot(_ slug: String, extending key: String) -> Bool {
        let suffix = String(slug.dropFirst(key.count))
        if suffix.count == 9, suffix.first == "-", suffix.dropFirst().allSatisfy(\.isNumber) { return true }
        guard suffix.count == 11, suffix.first == "-" else { return false }
        let date = Array(suffix.dropFirst())
        return date[4] == "-" && date[7] == "-"
            && date.enumerated().allSatisfy { index, character in
                index == 4 || index == 7 ? character == "-" : character.isNumber
            }
    }

    /// Generic Claude family key (`claude-<family>`) → the versions it may price.
    /// Bounded to versions whose rates have been verified. Numeric-looking future
    /// minors must not silently inherit an older family's price (for example
    /// Fable 5.2 from Fable 5.0).
    static let knownClaudeVersions: [String: Set<String>] = [
        "opus": ["4-5", "4-6", "4-7", "4-8", "5"],
        "sonnet": ["3", "3-5", "4", "4-5", "4-6", "5"],
        "haiku": ["4-5"],
        "fable": ["5"],
        "mythos": ["5"]
    ]

    fileprivate static func isRecognizedClaudeSlug(_ slug: String, extending key: String) -> Bool {
        let suffix = String(slug.dropFirst(key.count))
        guard !suffix.isEmpty, suffix.first == "-" else { return false }

        // Versioned keys accept the provider's dated alias form only. This keeps
        // `claude-sonnet-5-20260101` working without treating arbitrary suffixes
        // such as `claude-sonnet-5-preview` as the same priced model.
        let keyParts = key.split(separator: "-")
        let isGenericFamily = keyParts.count == 2
            && keyParts[0] == "claude"
            && knownClaudeVersions[String(keyParts[1])] != nil
        if !isGenericFamily {
            return Self.isClaudeDateSuffix(suffix)
        }

        var parts = suffix.dropFirst().split(separator: "-").map(String.init)
        if parts.last?.count == 8, parts.last?.allSatisfy(\.isNumber) == true {
            parts.removeLast()
        }
        let version = parts.joined(separator: "-")
        return knownClaudeVersions[String(keyParts[1])]?.contains(version) == true
    }

    private static func isClaudeDateSuffix(_ suffix: String) -> Bool {
        let digits = suffix.dropFirst()
        return digits.count == 8 && digits.allSatisfy(\.isNumber)
    }
}

/// Model→price lookup for `$` burn. Ships a compiled-in default snapshot and,
/// optionally, refreshes from a read-only public manifest so prices can be
/// corrected without an app release. The fetch is a plain GET of a static file —
/// no user or session data is sent (same trust model as the Sparkle appcast).
///
/// Lookup is **longest-prefix** for Claude and exact-or-dated-snapshot for every other key.
/// `revision` is a stable semantic hash of the model/rate content, so persisted
/// calibrations survive metadata-only edits. `manifestFingerprint` is the exact
/// canonical manifest identity exposed for verification; telemetry caches pair
/// `revision` with `updated` so metadata-only manifest changes also invalidate.
///
/// A cached or fetched manifest is only accepted when its `sequence` is strictly
/// greater than the loaded table's. Without that check, a client that cached an
/// older manifest would keep overriding a corrected bundled table forever
/// (indefinitely, if it's offline or the host still serves the old file).
///
/// `@unchecked Sendable`: lock-guarded mutable state touched from a background
/// URLSession callback (mirrors `RunwayAggregateBurnHold`).
final class RunwayPriceTable: @unchecked Sendable {
    static let shared = RunwayPriceTable()

    /// Only schema 2 is accepted. A schema-1 document — the legacy manifest that
    /// shipped clients still read — is rejected from every source, so it can never
    /// become the resolver source for a client that matches strictly.
    static let supportedVersion = 2
    static let legacyV1FileName = "prices.json"
    static let cacheFileName = "prices-v2.json"
    private static let manifestURL = URL(string: "https://jazzyalex.github.io/agent-sessions/prices-v2.json")!
    private static let minRefreshInterval: TimeInterval = 24 * 60 * 60

    private let lock = NSLock()
    private var models: [String: RunwayModelPrice] = [:]
    private var aliases: [String: String] = [:]
    private var _revision = 0
    private var _manifestFingerprint = ""
    private var lastFetchAt: Date?
    /// `updated` of the table currently in `models`. Metadata only: it no longer
    /// orders manifests (`sequence` does), but telemetry stamps it onto results.
    private var loadedUpdated: String = ""
    /// `sequence` of the table currently loaded. Strictly increases on every edit.
    private var loadedSequence = 0
    private var providerRevisions: [String: Int] = [:]

    struct DecodedManifest {
        let models: [String: RunwayModelPrice]
        let aliases: [String: String]
        let updated: String
        let sequence: Int
        let semanticRevision: Int
        let providerRevisions: [String: Int]
        let manifestFingerprint: String
    }

    init(loadBundled: Bool = true, readCache: Bool = true) {
        if loadBundled, let decoded = Self.decode(Data(Self.bundledJSON.utf8)) {
            install(decoded)
        }
        // Overlay a previously fetched manifest only when its sequence is higher.
        if readCache, let data = try? Data(contentsOf: Self.cacheURL()), let decoded = Self.decode(data) {
            adopt(decoded)
        }
    }

    /// Called from `init` without the lock (no other thread can hold the instance
    /// yet) and from `adopt` under it.
    private func install(_ decoded: DecodedManifest) {
        models = decoded.models
        aliases = decoded.aliases
        loadedUpdated = decoded.updated
        loadedSequence = decoded.sequence
        _revision = decoded.semanticRevision
        providerRevisions = decoded.providerRevisions
        _manifestFingerprint = decoded.manifestFingerprint
    }

    /// The single acceptance rule for every source: take a manifest only when its
    /// `sequence` is strictly greater than the loaded one. Equal sequence keeps the
    /// loaded table, so a corrected bundle is never shadowed by a cache written
    /// earlier the same day.
    @discardableResult
    private func adopt(_ decoded: DecodedManifest) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard decoded.sequence > loadedSequence else { return false }
        install(decoded)
        return true
    }

    var sequence: Int { lock.lock(); defer { lock.unlock() }; return loadedSequence }
    var isEmpty: Bool { lock.lock(); defer { lock.unlock() }; return models.isEmpty }
    var revision: Int { lock.lock(); defer { lock.unlock() }; return _revision }
    var semanticRevision: Int { revision }
    var manifestFingerprint: String { lock.lock(); defer { lock.unlock() }; return _manifestFingerprint }
    /// `updated` date of the table currently loaded. Stamped onto stored telemetry
    /// cost results so a saved figure can be re-judged when rates move.
    var updatedDate: String { lock.lock(); defer { lock.unlock() }; return loadedUpdated }

    func snapshot() -> RunwayPriceSnapshot {
        lock.lock(); defer { lock.unlock() }
        return RunwayPriceSnapshot(models: models, aliases: aliases, updatedDate: loadedUpdated,
                                   revision: _revision, manifestFingerprint: _manifestFingerprint,
                                   providerRevisions: providerRevisions)
    }

    func rateRevision(forProvider provider: String) -> Int {
        snapshot().rateRevision(forProvider: provider)
    }

    /// nil slug or no safe matching key → nil (→ $ unpriceable).
    func price(forModel slug: String?) -> RunwayModelPrice? {
        lock.lock(); defer { lock.unlock() }
        return RunwayPriceSnapshot.price(forModel: slug, in: models)
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
            // Ignore (and don't cache) a manifest whose sequence is not higher than
            // what we already have — e.g. the host still serves a file predating
            // this build's bundled table.
            guard self.adopt(decoded) else { return }
            Self.persist(data)
        }.resume()
    }

    /// Writes the v2 cache file only. Never touches `legacyV1FileName`.
    private static func persist(_ data: Data) {
        try? data.write(to: cacheURL(), options: .atomic)
    }

    // MARK: - Decoding

    private struct Manifest: Decodable {
        let version: Int
        let sequence: Int?
        let updated: String?
        let aliases: [String: String]?
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
    /// row published before either existed; an older client simply ignores the
    /// new keys.
    private struct RawPrice: Decodable {
        let inputPerMTok: Double
        let cachedInputPerMTok: Double
        let outputPerMTok: Double
        let cacheWritePerMTok: Double?
        let cacheWrite1hPerMTok: Double?
        let fast: RawRates?
        let longContext: RawLongContext?
        let inferenceGeoUSMultiplier: Double?

        var standardRateSet: RunwayRateSet {
            RunwayRateSet(inputPerMTok: inputPerMTok,
                          cachedInputPerMTok: cachedInputPerMTok,
                          outputPerMTok: outputPerMTok,
                          cacheWritePerMTok: cacheWritePerMTok,
                          cacheWrite1hPerMTok: cacheWrite1hPerMTok)
        }
    }

    /// Returns the decoded manifest only for schema 2 with a positive `sequence`;
    /// nil otherwise (malformed, schema 1, unrecognized `version`, or no
    /// `sequence` → caller keeps its current table).
    private static func decode(_ data: Data) -> DecodedManifest? {
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.version == supportedVersion,
              let sequence = manifest.sequence, sequence > 0,
              !manifest.models.isEmpty else { return nil }
        let models = manifest.models.mapValues {
            RunwayModelPrice(standard: $0.standardRateSet,
                             fast: $0.fast?.rateSet,
                             longContext: $0.longContext?.price,
                             inferenceGeoUSMultiplier: $0.inferenceGeoUSMultiplier)
        }
        // An alias whose target row is missing is dropped rather than failing the
        // whole manifest; keys are compared lowercased by the resolver.
        let aliases = (manifest.aliases ?? [:]).reduce(into: [String: String]()) { out, pair in
            if models[pair.value] != nil { out[pair.key.lowercased()] = pair.value }
        }
        guard var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exactCanonical = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return nil }
        let fingerprint = SHA256.hash(data: exactCanonical).map { String(format: "%02x", $0) }.joined()
        object.removeValue(forKey: "_note")
        object.removeValue(forKey: "updated")
        object.removeValue(forKey: "sequence")
        guard let semantic = stableHash(object) else { return nil }

        // Only the provider's own rows hash in, and only their rate-bearing fields,
        // projected from the DECODED price. Aliases, sequence, notes, other vendors'
        // rows, and any future non-rate annotation on a row are excluded, so none of
        // them can discard Claude or Codex weekly calibration.
        func rates(_ set: RunwayRateSet?) -> Any {
            guard let set else { return NSNull() }
            return ["input": set.inputPerMTok, "cachedInput": set.cachedInputPerMTok,
                    "output": set.outputPerMTok,
                    "cacheWrite": set.cacheWritePerMTok as Any? ?? NSNull(),
                    "cacheWrite1h": set.cacheWrite1hPerMTok as Any? ?? NSNull()] as [String: Any]
        }
        func revision(_ prefixes: [String]) -> Int {
            var projection: [String: Any] = [:]
            for (key, price) in models where prefixes.contains(where: { key.hasPrefix($0) }) {
                projection[key] = [
                    "standard": rates(price.standard),
                    "fast": rates(price.fast),
                    "longContext": price.longContext.map {
                        ["threshold": $0.thresholdInputTokens, "input": $0.inputMultiplier,
                         "output": $0.outputMultiplier] as [String: Any]
                    } as Any? ?? NSNull(),
                    "geoUS": price.inferenceGeoUSMultiplier as Any? ?? NSNull()
                ] as [String: Any]
            }
            return stableHash(projection) ?? 0
        }
        let providerRevisions = ["claude": revision(["claude-"]),
                                 "codex": revision(["gpt-", "codex-"])]
        return DecodedManifest(models: models, aliases: aliases, updated: manifest.updated ?? "",
                               sequence: sequence, semanticRevision: semantic,
                               providerRevisions: providerRevisions,
                               manifestFingerprint: fingerprint)
    }

    private static func stableHash(_ object: Any) -> Int? {
        guard let canonical = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return nil }
        let digest = SHA256.hash(data: canonical)
        return Int(digest.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } & UInt64(Int.max))
    }

    private static func cacheURL() -> URL {
        #if DEBUG
        if let override = cacheDirectoryOverride {
            return override.appendingPathComponent(cacheFileName)
        }
        #endif
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("AgentSessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(cacheFileName)
    }

    #if DEBUG
    /// Test seam: when set, `cacheURL()` resolves inside this directory instead of
    /// Application Support.
    static var cacheDirectoryOverride: URL?

    /// Test seam: the same write `refreshInBackground` performs after adopting.
    func persistForTesting(_ data: Data) {
        Self.persist(data)
    }

    /// Test seam: load a manifest from raw JSON (bypassing the network/cache).
    /// Returns true if accepted — applies the same version + `sequence` rules
    /// as the real cache/network paths, so tests exercise production acceptance.
    @discardableResult
    func loadForTesting(json: Data) -> Bool {
        guard let decoded = Self.decode(json) else { return false }
        return adopt(decoded)
    }
    static func makeForTesting() -> RunwayPriceTable { RunwayPriceTable(loadBundled: true, readCache: false) }
    static func makeEmptyForTesting() -> RunwayPriceTable { RunwayPriceTable(loadBundled: false, readCache: false) }
    #endif

    /// Compiled-in default snapshot. Also published at `docs/prices-v2.json` for the
    /// refresh — the two MUST stay identical, because whichever has the higher
    /// `sequence` wins outright and a rate that reaches only one of them is silently
    /// reverted by the other. Claude, GPT and codex-auto-review rows must also stay
    /// identical in the legacy schema-1 `docs/prices.json`.
    /// Verified 2026-09-09 against the official pricing pages
    /// (platform.claude.com/docs/en/about-claude/pricing and
    /// developers.openai.com/api/docs/pricing). Keyed by tier so longest-prefix
    /// resolves every generation (`claude-sonnet` → claude-sonnet-5, `gpt-5.6-sol`
    /// exact, `gpt-5` → any other gpt-5.x). Correct via docs/prices-v2.json — no rebuild.
    ///
    /// `cachedInputPerMTok` = cache-hit read (0.1× input). `cacheWritePerMTok` =
    /// 5-minute cache write (1.25× input); `cacheWrite1hPerMTok` = 1-hour cache write
    /// (2× input). GPT cache-write columns are populated only where the provider
    /// publishes a write rate; a positive unpriced write otherwise fails closed.
    ///
    /// `fast` is Anthropic's fast mode, a research preview on Opus 5.5, 5, and 4.8.
    /// Opus 5.5 is $8/$40 per MTok with a 0.05× cache read; 5 and 4.8 are
    /// $10/$50 with a 0.1× read. Cache writes are 1.25×/2× the fast input rate. The
    /// generic `claude-opus` key deliberately has NO fast set, so an Opus 4.6/4.7
    /// record that somehow reported `speed:"fast"` drops out of `$` instead of being
    /// billed at double. Sonnet 5's $2/$10 price is permanent; the generic Sonnet key
    /// stays at $3/$15 for Sonnet 4.x.
    static let bundledJSON = """
    {
      "version": 2,
      "sequence": 2026101402,
      "updated": "2026-10-14",
      "aliases": { "claude sonnet 4.6": "claude-sonnet-4-6", "gemini 3.6 flash": "gemini-3.6-flash", "gemini 3.8 flash": "gemini-3.8-flash" },
      "_note": "USD per million tokens. Served read-only to Agent Sessions' Session Runway $ burn; no user data is sent. Verified 2026-10-11 UTC from platform.claude.com and developers.openai.com. Claude Opus 4 and 4.1 retain their historical $15/$75 rates; generic Claude family aliases accept only versions with the same rate. Opus 5.5 cache reads are $0.20/MTok and fast input/output are $8/$40. Sonnet 5.5 uses the published Sonnet 5 rates: $2/$10 input/output, $0.20 cache reads, and $2.50/$4 cache writes. Fable and Mythos 5.1 cache reads are $0.25/MTok. GPT-6.1 Sol pricing verified 2026-09-30 UTC at developers.openai.com/api/docs/models/gpt-6.1-sol: $2/$10 input/output, $0.10 cache reads, $2.50 cache writes, and 2x fast rates. Astra, GPT-6.1 Sol, GPT-6 Sol/Luna, GPT-5.6 Sol, GPT-5.5, and GPT-5.4 requests above 272K input tokens use 2x input and 1.5x output rates. GPT prefix fallback accepts dated snapshots only; Claude family fallbacks accept only verified versions. cachedInputPerMTok is cache read; cacheWritePerMTok is a 5-minute cache write (1.25x input) and cacheWrite1hPerMTok a 1-hour one (2x input). A positive cache-write volume with no published GPT write rate is unavailable. The optional fast object supplies model-specific fast-mode rates. codex-auto-review is an unpublished internal label priced at the GPT-5.6 Sol default. Schema 2. Clients adopt a manifest only when sequence is strictly greater than the loaded one, so raise sequence (YYYYMMDDNN) on every edit, in BOTH docs/prices-v2.json and the bundled copy in RunwayPriceTable.swift. Claude, GPT and codex-auto-review rows must also stay identical in the legacy docs/prices.json. Vendor rows below are schema-2 only and never go into docs/prices.json. Google rates verified 2026-10-14 at ai.google.dev: Gemini 3.8 Flash and 3.6 Flash Standard rates apply through December 31, 2026 (Google publishes $1.50/$0.15/$7.50 from January 1, 2027); context-caching storage is billed per hour, so no cache-write rate. Z.ai rates verified 2026-10-14 at docs.z.ai. MiniMax rates verified 2026-10-14 at platform.minimax.io. Moonshot rates verified 2026-10-14 at platform.kimi.ai. xAI rates verified 2026-10-14 at docs.x.ai: grok-4.6 bills every token at 2x when the prompt reaches 200k tokens; thresholdInputTokens is exclusive, so it is 199999. Meta rates verified 2026-10-14 at dev.meta.ai: muse-spark-1.3 is the Standard-mode rate; Meta states no long-context premium. Aliases map the display names Antigravity records (Claude Sonnet 4.6, Gemini 3.6 Flash, Gemini 3.8 Flash; effort suffix stripped, lowercased) to their rows; added 2026-10-14.",
      "models": {
        "claude-opus-5-5": { "inputPerMTok": 4.0, "cachedInputPerMTok": 0.2, "outputPerMTok": 20.0, "cacheWritePerMTok": 5.0, "cacheWrite1hPerMTok": 8.0, "inferenceGeoUSMultiplier": 1.1,
                            "fast": { "inputPerMTok": 8.0, "cachedInputPerMTok": 0.4, "outputPerMTok": 40.0, "cacheWritePerMTok": 10.0, "cacheWrite1hPerMTok": 16.0 } },
        "claude-opus-5":   { "inputPerMTok": 5.0,  "cachedInputPerMTok": 0.5,   "outputPerMTok": 25.0, "cacheWritePerMTok": 6.25, "cacheWrite1hPerMTok": 10.0, "inferenceGeoUSMultiplier": 1.1,
                             "fast": { "inputPerMTok": 10.0, "cachedInputPerMTok": 1.0, "outputPerMTok": 50.0, "cacheWritePerMTok": 12.5, "cacheWrite1hPerMTok": 20.0 } },
        "claude-opus-4-8": { "inputPerMTok": 5.0,  "cachedInputPerMTok": 0.5,   "outputPerMTok": 25.0, "cacheWritePerMTok": 6.25, "cacheWrite1hPerMTok": 10.0, "inferenceGeoUSMultiplier": 1.1,
                             "fast": { "inputPerMTok": 10.0, "cachedInputPerMTok": 1.0, "outputPerMTok": 50.0, "cacheWritePerMTok": 12.5, "cacheWrite1hPerMTok": 20.0 } },
        "claude-opus-4":   { "inputPerMTok": 15.0, "cachedInputPerMTok": 1.5,   "outputPerMTok": 75.0, "cacheWritePerMTok": 18.75, "cacheWrite1hPerMTok": 30.0 },
        "claude-opus-4-7": { "inputPerMTok": 5.0,  "cachedInputPerMTok": 0.5,   "outputPerMTok": 25.0, "cacheWritePerMTok": 6.25, "cacheWrite1hPerMTok": 10.0, "inferenceGeoUSMultiplier": 1.1 },
        "claude-opus-4-6": { "inputPerMTok": 5.0,  "cachedInputPerMTok": 0.5,   "outputPerMTok": 25.0, "cacheWritePerMTok": 6.25, "cacheWrite1hPerMTok": 10.0, "inferenceGeoUSMultiplier": 1.1 },
        "claude-opus":     { "inputPerMTok": 5.0,  "cachedInputPerMTok": 0.5,   "outputPerMTok": 25.0, "cacheWritePerMTok": 6.25, "cacheWrite1hPerMTok": 10.0 },
        "claude-sonnet-5-5": { "inputPerMTok": 2.0, "cachedInputPerMTok": 0.1, "outputPerMTok": 10.0, "cacheWritePerMTok": 2.5, "cacheWrite1hPerMTok": 4.0, "inferenceGeoUSMultiplier": 1.1 },
        "claude-sonnet-5": { "inputPerMTok": 2.0,  "cachedInputPerMTok": 0.2,   "outputPerMTok": 10.0, "cacheWritePerMTok": 2.5,  "cacheWrite1hPerMTok": 4.0, "inferenceGeoUSMultiplier": 1.1 },
        "claude-sonnet-4-6": { "inputPerMTok": 3.0, "cachedInputPerMTok": 0.3, "outputPerMTok": 15.0, "cacheWritePerMTok": 3.75, "cacheWrite1hPerMTok": 6.0, "inferenceGeoUSMultiplier": 1.1 },
        "claude-sonnet":   { "inputPerMTok": 3.0,  "cachedInputPerMTok": 0.3,   "outputPerMTok": 15.0, "cacheWritePerMTok": 3.75, "cacheWrite1hPerMTok": 6.0 },
        "claude-haiku-5-5": { "inputPerMTok": 0.1, "cachedInputPerMTok": 0.01, "outputPerMTok": 0.5, "cacheWritePerMTok": 0.125, "cacheWrite1hPerMTok": 0.2, "inferenceGeoUSMultiplier": 1.1,
                         "longContext": { "thresholdInputTokens": 100000, "inputMultiplier": 5.0, "outputMultiplier": 5.0 } },
        "claude-haiku":    { "inputPerMTok": 1.0,  "cachedInputPerMTok": 0.1,   "outputPerMTok": 5.0,  "cacheWritePerMTok": 1.25, "cacheWrite1hPerMTok": 2.0 },
        "claude-fable-5-1": { "inputPerMTok": 10.0, "cachedInputPerMTok": 0.25,  "outputPerMTok": 50.0, "cacheWritePerMTok": 12.5, "cacheWrite1hPerMTok": 20.0, "inferenceGeoUSMultiplier": 1.1 },
        "claude-fable":    { "inputPerMTok": 10.0, "cachedInputPerMTok": 1.0,   "outputPerMTok": 50.0, "cacheWritePerMTok": 12.5, "cacheWrite1hPerMTok": 20.0, "inferenceGeoUSMultiplier": 1.1 },
        "claude-mythos-5-1": { "inputPerMTok": 10.0, "cachedInputPerMTok": 0.25, "outputPerMTok": 50.0, "cacheWritePerMTok": 12.5, "cacheWrite1hPerMTok": 20.0, "inferenceGeoUSMultiplier": 1.1 },
        "claude-mythos":   { "inputPerMTok": 10.0, "cachedInputPerMTok": 1.0,   "outputPerMTok": 50.0, "cacheWritePerMTok": 12.5, "cacheWrite1hPerMTok": 20.0, "inferenceGeoUSMultiplier": 1.1 },
        "claude-opus-4-1":  { "inputPerMTok": 15.0, "cachedInputPerMTok": 1.5,  "outputPerMTok": 75.0, "cacheWritePerMTok": 18.75, "cacheWrite1hPerMTok": 30.0 },
        "claude-3-opus":    { "inputPerMTok": 15.0, "cachedInputPerMTok": 1.5,  "outputPerMTok": 75.0, "cacheWritePerMTok": 18.75, "cacheWrite1hPerMTok": 30.0 },
        "claude-3-5-sonnet":{ "inputPerMTok": 3.0,  "cachedInputPerMTok": 0.3,  "outputPerMTok": 15.0, "cacheWritePerMTok": 3.75, "cacheWrite1hPerMTok": 6.0 },
        "claude-3-5-haiku": { "inputPerMTok": 0.8,  "cachedInputPerMTok": 0.08, "outputPerMTok": 4.0,  "cacheWritePerMTok": 1.0,  "cacheWrite1hPerMTok": 1.6 },
        "gpt-6-astra":     { "inputPerMTok": 10.0, "cachedInputPerMTok": 1.0,   "outputPerMTok": 50.0, "cacheWritePerMTok": 12.5,
                             "fast": { "inputPerMTok": 20.0, "cachedInputPerMTok": 2.0, "outputPerMTok": 100.0, "cacheWritePerMTok": 25.0 },
                             "longContext": { "thresholdInputTokens": 272000, "inputMultiplier": 2.0, "outputMultiplier": 1.5 } },
        "gpt-6.1-sol":     { "inputPerMTok": 2.0,  "cachedInputPerMTok": 0.1,   "outputPerMTok": 10.0, "cacheWritePerMTok": 2.5,
                             "fast": { "inputPerMTok": 4.0, "cachedInputPerMTok": 0.2, "outputPerMTok": 20.0, "cacheWritePerMTok": 5.0 },
                             "longContext": { "thresholdInputTokens": 272000, "inputMultiplier": 2.0, "outputMultiplier": 1.5 } },
        "gpt-6-sol":       { "inputPerMTok": 2.0,  "cachedInputPerMTok": 0.2,   "outputPerMTok": 10.0, "cacheWritePerMTok": 2.5,
                             "fast": { "inputPerMTok": 4.0, "cachedInputPerMTok": 0.4, "outputPerMTok": 20.0, "cacheWritePerMTok": 5.0 },
                             "longContext": { "thresholdInputTokens": 272000, "inputMultiplier": 2.0, "outputMultiplier": 1.5 } },
        "gpt-6-luna":      { "inputPerMTok": 0.1,  "cachedInputPerMTok": 0.01,  "outputPerMTok": 0.5,  "cacheWritePerMTok": 0.125,
                             "fast": { "inputPerMTok": 0.2, "cachedInputPerMTok": 0.02, "outputPerMTok": 1.0, "cacheWritePerMTok": 0.25 },
                             "longContext": { "thresholdInputTokens": 272000, "inputMultiplier": 2.0, "outputMultiplier": 1.5 } },
        "gpt-5.6-sol":     { "inputPerMTok": 4.0,  "cachedInputPerMTok": 0.4,   "outputPerMTok": 20.0, "cacheWritePerMTok": 5.0,
                             "longContext": { "thresholdInputTokens": 272000, "inputMultiplier": 2.0, "outputMultiplier": 1.5 } },
        "gpt-5.6-terra":   { "inputPerMTok": 2.0,  "cachedInputPerMTok": 0.2,   "outputPerMTok": 12.0, "cacheWritePerMTok": 2.5,
                             "longContext": { "thresholdInputTokens": 272000, "inputMultiplier": 2.0, "outputMultiplier": 1.5 } },
        "gpt-5.6-luna":    { "inputPerMTok": 0.2,  "cachedInputPerMTok": 0.02,  "outputPerMTok": 1.2,  "cacheWritePerMTok": 0.25,
                             "longContext": { "thresholdInputTokens": 272000, "inputMultiplier": 2.0, "outputMultiplier": 1.5 } },
        "gpt-5.6":         { "inputPerMTok": 4.0,  "cachedInputPerMTok": 0.4,   "outputPerMTok": 20.0, "cacheWritePerMTok": 5.0,
                             "longContext": { "thresholdInputTokens": 272000, "inputMultiplier": 2.0, "outputMultiplier": 1.5 } },
        "gpt-5.5":         { "inputPerMTok": 5.0,  "cachedInputPerMTok": 0.5,   "outputPerMTok": 30.0, "cacheWritePerMTok": null,
                             "longContext": { "thresholdInputTokens": 272000, "inputMultiplier": 2.0, "outputMultiplier": 1.5 } },
        "gpt-5.4-mini":    { "inputPerMTok": 0.75, "cachedInputPerMTok": 0.075, "outputPerMTok": 4.5,  "cacheWritePerMTok": null },
        "gpt-5.4":         { "inputPerMTok": 2.5,  "cachedInputPerMTok": 0.25,  "outputPerMTok": 15.0, "cacheWritePerMTok": null,
                             "longContext": { "thresholdInputTokens": 272000, "inputMultiplier": 2.0, "outputMultiplier": 1.5 } },
        "gpt-5":           { "inputPerMTok": 1.25, "cachedInputPerMTok": 0.125, "outputPerMTok": 10.0, "cacheWritePerMTok": null },
        "codex-auto-review": { "inputPerMTok": 4.0, "cachedInputPerMTok": 0.4,  "outputPerMTok": 20.0, "cacheWritePerMTok": 5.0,
                               "longContext": { "thresholdInputTokens": 272000, "inputMultiplier": 2.0, "outputMultiplier": 1.5 } },
        "gemini-3.8-flash": { "inputPerMTok": 0.75, "cachedInputPerMTok": 0.075, "outputPerMTok": 3.75, "cacheWritePerMTok": null },
        "gemini-3.6-flash": { "inputPerMTok": 0.75, "cachedInputPerMTok": 0.075, "outputPerMTok": 3.75, "cacheWritePerMTok": null },
        "glm-5.3-flash":   { "inputPerMTok": 0.15, "cachedInputPerMTok": 0.03,  "outputPerMTok": 0.5,  "cacheWritePerMTok": null },
        "glm-4.7":         { "inputPerMTok": 0.6,  "cachedInputPerMTok": 0.11,  "outputPerMTok": 2.2,  "cacheWritePerMTok": null },
        "minimax-m2.5":    { "inputPerMTok": 0.3,  "cachedInputPerMTok": 0.03,  "outputPerMTok": 1.2,  "cacheWritePerMTok": 0.375 },
        "minimax-m2.1":    { "inputPerMTok": 0.3,  "cachedInputPerMTok": 0.03,  "outputPerMTok": 1.2,  "cacheWritePerMTok": 0.375 },
        "kimi-k2.7-code":  { "inputPerMTok": 0.95, "cachedInputPerMTok": 0.19,  "outputPerMTok": 4.0,  "cacheWritePerMTok": null },
        "grok-4.6":        { "inputPerMTok": 2.0,  "cachedInputPerMTok": 0.5,   "outputPerMTok": 6.0,  "cacheWritePerMTok": null,
                             "longContext": { "thresholdInputTokens": 199999, "inputMultiplier": 2.0, "outputMultiplier": 2.0 } },
        "muse-spark-1.3":  { "inputPerMTok": 1.25, "cachedInputPerMTok": 0.15,  "outputPerMTok": 4.25, "cacheWritePerMTok": null }
      }
    }
    """
}
