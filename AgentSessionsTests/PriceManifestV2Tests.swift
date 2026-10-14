import XCTest
@testable import AgentSessions

final class PriceManifestV2Tests: XCTestCase {
    private func rate(_ input: Double) -> RunwayModelPrice {
        RunwayModelPrice(standard: RunwayRateSet(inputPerMTok: input, cachedInputPerMTok: input / 10,
                                                 outputPerMTok: input * 5, cacheWritePerMTok: nil,
                                                 cacheWrite1hPerMTok: nil),
                         fast: nil, longContext: nil, inferenceGeoUSMultiplier: nil)
    }

    private func snapshot(_ models: [String: RunwayModelPrice],
                          aliases: [String: String] = [:]) -> RunwayPriceSnapshot {
        RunwayPriceSnapshot(models: models, aliases: aliases, updatedDate: "2026-10-13",
                            revision: 1, manifestFingerprint: "test")
    }

    // MARK: - Strict matching

    func testVendorKeyDoesNotPriceAnExtendedSlug() {
        let s = snapshot(["kimi-k2.7-code": rate(1), "glm-4.7": rate(2)])
        XCTAssertNotNil(s.price(forModel: "kimi-k2.7-code"))
        XCTAssertNil(s.price(forModel: "kimi-k2.7-code-v2"),
                     "a variant must not inherit the base model's rate")
        XCTAssertNil(s.price(forModel: "glm-4.70"))
        XCTAssertNil(s.price(forModel: "glm-4.7-preview"))
    }

    func testVendorKeyAcceptsDatedSnapshots() {
        let s = snapshot(["glm-4.7": rate(2)])
        XCTAssertEqual(s.price(forModel: "glm-4.7-20260901")?.inputPerMTok, 2)
        XCTAssertEqual(s.price(forModel: "glm-4.7-2026-09-01")?.inputPerMTok, 2)
        XCTAssertNil(s.price(forModel: "glm-4.7-2026090"))
    }

    func testCodexAutoReviewIsExactOrDatedOnly() {
        let s = RunwayPriceTable.makeForTesting().snapshot()
        XCTAssertNotNil(s.price(forModel: "codex-auto-review"))
        XCTAssertNil(s.price(forModel: "codex-auto-review-v2"))
    }

    func testTableAndSnapshotAgreeOnEveryLookup() {
        let table = RunwayPriceTable.makeForTesting()
        let s = table.snapshot()
        for slug in ["claude-opus-5", "claude-sonnet-5-20260101", "claude-sonnet-5-preview",
                     "gpt-5.5", "gpt-5.5-2026-01-01", "gpt-5.5-turbo", "codex-auto-review",
                     "kimi-k2.7-code-v2", ""] {
            XCTAssertEqual(table.price(forModel: slug), s.price(forModel: slug), slug)
        }
    }

    // MARK: - Resolved lookup

    func testResolvedPricePrefersTheRawSlug() {
        let s = snapshot(["gpt-5.5": rate(5)])
        let hit = s.resolvedPrice(forModel: "gpt-5.5")
        XCTAssertEqual(hit?.price.inputPerMTok, 5)
        XCTAssertEqual(hit?.viaFreeRoute, false)
    }

    func testResolvedPriceUsesResolverAndReportsFreeRoute() {
        let s = snapshot(["minimax-m2.5": rate(3), "gemini-3.5-flash": rate(4)],
                         aliases: ["gemini 3.5 flash": "gemini-3.5-flash"])
        XCTAssertEqual(s.resolvedPrice(forModel: "minimax-m2.5-free")?.price.inputPerMTok, 3)
        XCTAssertEqual(s.resolvedPrice(forModel: "minimax-m2.5-free")?.viaFreeRoute, true)
        XCTAssertEqual(s.resolvedPrice(forModel: "Gemini 3.5 Flash (Medium)")?.price.inputPerMTok, 4)
        XCTAssertNil(s.resolvedPrice(forModel: "big-pickle"))
        XCTAssertNil(s.resolvedPrice(forModel: nil))
    }

    // MARK: - Schema 2 lifecycle

    private func manifest(sequence: Int, opusOutput: Double, version: Int = 2,
                          aliases: String = "{}") -> Data {
        Data("""
        {"version":\(version),"sequence":\(sequence),"updated":"2026-10-13",
         "aliases":\(aliases),
         "models":{"claude-opus":{"inputPerMTok":5,"cachedInputPerMTok":0.5,"outputPerMTok":\(opusOutput)}}}
        """.utf8)
    }

    func testSchemaOneDocumentIsRejected() throws {
        let table = RunwayPriceTable.makeForTesting()
        let before = table.manifestFingerprint
        XCTAssertFalse(table.loadForTesting(json: manifest(sequence: 9_999_999_999, opusOutput: 1, version: 1)))
        let served = try Data(contentsOf: FixturePaths.repoRootURL()
            .appendingPathComponent("docs").appendingPathComponent("prices.json"))
        XCTAssertFalse(table.loadForTesting(json: served),
                       "the real legacy manifest must never become the v2 source")
        XCTAssertEqual(table.manifestFingerprint, before)
    }

    func testHigherSequenceIsAdoptedAndEqualOrLowerIsNot() {
        let table = RunwayPriceTable.makeForTesting()
        let bundled = table.sequence
        XCTAssertFalse(table.loadForTesting(json: manifest(sequence: bundled, opusOutput: 111)),
                       "equal sequence with different content must keep the bundled table")
        XCTAssertNotEqual(table.price(forModel: "claude-opus-4-8")?.outputPerMTok, 111)
        XCTAssertFalse(table.loadForTesting(json: manifest(sequence: bundled - 1, opusOutput: 222)))
        XCTAssertTrue(table.loadForTesting(json: manifest(sequence: bundled + 1, opusOutput: 333)))
        XCTAssertEqual(table.price(forModel: "claude-opus-4-8")?.outputPerMTok, 333)
    }

    func testManifestWithoutSequenceIsRejected() {
        let table = RunwayPriceTable.makeForTesting()
        let json = #"{"version":2,"updated":"2099-01-01","models":{"claude-opus":{"inputPerMTok":5,"cachedInputPerMTok":0.5,"outputPerMTok":1}}}"#
        XCTAssertFalse(table.loadForTesting(json: Data(json.utf8)))
    }

    func testAliasWithMissingTargetIsDropped() {
        let table = RunwayPriceTable.makeEmptyForTesting()
        XCTAssertTrue(table.loadForTesting(json: manifest(
            sequence: 1, opusOutput: 25,
            aliases: #"{"opus latest":"claude-opus","ghost":"no-such-row"}"#)))
        XCTAssertEqual(table.snapshot().aliases, ["opus latest": "claude-opus"])
    }

    func testCacheFileNamesDoNotCollide() {
        XCTAssertEqual(RunwayPriceTable.cacheFileName, "prices-v2.json")
        XCTAssertNotEqual(RunwayPriceTable.cacheFileName, RunwayPriceTable.legacyV1FileName)
    }

    /// A v2 client must never read, overwrite, or delete the v1 cache file that a
    /// downgraded build would still use.
    func testV2ClientLeavesTheLegacyCacheFileUntouched() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentSessions-PriceCache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir); RunwayPriceTable.cacheDirectoryOverride = nil }
        RunwayPriceTable.cacheDirectoryOverride = dir

        let legacyURL = dir.appendingPathComponent(RunwayPriceTable.legacyV1FileName)
        let sentinel = Data(#"{"version":1,"updated":"2099-12-31","models":{"claude-opus":{"inputPerMTok":1,"cachedInputPerMTok":1,"outputPerMTok":1}}}"#.utf8)
        try sentinel.write(to: legacyURL)
        let before = try FileManager.default.attributesOfItem(atPath: legacyURL.path)[.modificationDate] as? Date

        let table = RunwayPriceTable(loadBundled: true, readCache: true)
        XCTAssertNotEqual(table.price(forModel: "claude-opus-4-8")?.outputPerMTok, 1,
                          "the v1 cache must not be read")
        table.persistForTesting(manifest(sequence: table.sequence + 1, opusOutput: 25))

        XCTAssertEqual(try Data(contentsOf: legacyURL), sentinel)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: legacyURL.path)[.modificationDate] as? Date, before)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent(RunwayPriceTable.cacheFileName).path))
    }

    // MARK: - Guards (data invariants)

    private func json(_ relative: String) throws -> [String: Any] {
        let url = FixturePaths.repoRootURL().appendingPathComponent("docs").appendingPathComponent(relative)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func testServedV2ManifestEqualsTheBundledTable() throws {
        let served = try json("prices-v2.json")
        let bundled = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(RunwayPriceTable.bundledJSON.utf8)) as? [String: Any])
        XCTAssertEqual(NSDictionary(dictionary: served), NSDictionary(dictionary: bundled))
    }

    func testEveryAliasTargetExists() throws {
        let served = try json("prices-v2.json")
        let models = try XCTUnwrap(served["models"] as? [String: Any])
        for (alias, target) in (served["aliases"] as? [String: String]) ?? [:] {
            XCTAssertNotNil(models[target], "alias \(alias) points at a missing row")
            XCTAssertEqual(alias, alias.lowercased(), "alias keys are lowercased")
        }
    }

    /// Decodes the legacy v1 rows through the production decoder by re-labelling the
    /// document as schema 2, so the comparison is between decoded `RunwayModelPrice`
    /// values, not JSON representations.
    private func decodedV1Models() throws -> [String: RunwayModelPrice] {
        var v1 = try json("prices.json")
        v1["version"] = 2
        v1["sequence"] = 1
        let data = try JSONSerialization.data(withJSONObject: v1)
        let table = RunwayPriceTable.makeEmptyForTesting()
        XCTAssertTrue(table.loadForTesting(json: data))
        return table.snapshot().models
    }

    func testSharedRowsAreSemanticallyEqualInV1AndV2() throws {
        let v1 = try decodedV1Models()
        let v2 = RunwayPriceTable.makeForTesting().snapshot().models
        for key in v1.keys.sorted() {
            XCTAssertEqual(v1[key], v2[key], key)
        }
        XCTAssertTrue(v1.keys.allSatisfy { $0.hasPrefix("claude-") || $0.hasPrefix("gpt-") || $0 == "codex-auto-review" },
                      "the legacy manifest must not gain vendor rows")
    }

    /// The 5.5.2 matching contract, frozen here on purpose. This is an independent
    /// copy of the shipped matcher, NOT a call into production code: if the new
    /// matcher changes Claude or GPT semantics, this side must not change with it.
    /// Never "simplify" it to call `RunwayPriceSnapshot`.
    private enum ShippedV1Matcher {
        static let knownVersions: [String: Set<String>] = [
            "opus": ["4-5", "4-6", "4-7", "4-8", "5"],
            "sonnet": ["3", "3-5", "4", "4-5", "4-6", "5"],
            "haiku": ["4-5"],
            "fable": ["5"],
            "mythos": ["5"]
        ]

        static func key(forModel slug: String, in keys: Set<String>) -> String? {
            guard !slug.isEmpty else { return nil }
            if keys.contains(slug) { return slug }
            var best: String?
            for key in keys where slug.hasPrefix(key) {
                if key.hasPrefix("gpt-"), !isGPTSnapshot(slug, key) { continue }
                if key.hasPrefix("claude-"), !isClaudeSlug(slug, key) { continue }
                if best == nil || key.count > best!.count { best = key }
            }
            return best
        }

        static func isGPTSnapshot(_ slug: String, _ key: String) -> Bool {
            let suffix = String(slug.dropFirst(key.count))
            if suffix.count == 9, suffix.first == "-", suffix.dropFirst().allSatisfy(\.isNumber) { return true }
            guard suffix.count == 11, suffix.first == "-" else { return false }
            let date = Array(suffix.dropFirst())
            return date[4] == "-" && date[7] == "-"
                && date.enumerated().allSatisfy { i, c in i == 4 || i == 7 ? c == "-" : c.isNumber }
        }

        static func isClaudeSlug(_ slug: String, _ key: String) -> Bool {
            let suffix = String(slug.dropFirst(key.count))
            guard !suffix.isEmpty, suffix.first == "-" else { return false }
            let keyParts = key.split(separator: "-")
            let isGenericFamily = keyParts.count == 2 && keyParts[0] == "claude"
                && knownVersions[String(keyParts[1])] != nil
            if !isGenericFamily {
                let digits = suffix.dropFirst()
                return digits.count == 8 && digits.allSatisfy(\.isNumber)
            }
            var parts = suffix.dropFirst().split(separator: "-").map(String.init)
            if parts.last?.count == 8, parts.last?.allSatisfy(\.isNumber) == true { parts.removeLast() }
            return knownVersions[String(keyParts[1])]?.contains(parts.joined(separator: "-")) == true
        }
    }

    func testV2ResolvesEveryClaudeAndGPTFormLikeTheShippedV1Client() throws {
        let v1Rows = try XCTUnwrap(try json("prices.json")["models"] as? [String: Any])
        let v1Keys = Set(v1Rows.keys)
        let v2 = RunwayPriceTable.makeForTesting().snapshot()

        var forms: Set<String> = []
        for key in v1Keys {
            forms.formUnion([key, key + "-20260101", key + "-2026-01-01",
                             key + "-preview", key + "-v2", key + "x"])
        }
        // Forms come from the PRODUCTION version table, so a newly supported version
        // is covered automatically. The frozen ShippedV1Matcher is only the oracle.
        for (family, versions) in RunwayPriceSnapshot.knownClaudeVersions {
            for version in versions {
                forms.formUnion(["claude-\(family)-\(version)", "claude-\(family)-\(version)-20260101"])
            }
            forms.formUnion(["claude-\(family)-9", "claude-\(family)-5-2", "claude-\(family)-preview"])
        }

        for form in forms.sorted() where form.hasPrefix("claude-") || form.hasPrefix("gpt-") {
            let shippedKey = ShippedV1Matcher.key(forModel: form, in: v1Keys)
            let expected = shippedKey.flatMap { v2.models[$0] }
            XCTAssertEqual(v2.price(forModel: form), expected,
                           "\(form): shipped clients resolve to \(shippedKey ?? "nil")")
        }
    }

    /// `codex-auto-review` is the one shipped key that is neither Claude nor GPT.
    /// Shipped clients match it by bare prefix; v2 deliberately does not. Pin both.
    func testCodexAutoReviewDivergenceFromV1IsIntentional() {
        let v2 = RunwayPriceTable.makeForTesting().snapshot()
        XCTAssertEqual(ShippedV1Matcher.key(forModel: "codex-auto-review-v2", in: ["codex-auto-review"]),
                       "codex-auto-review")
        XCTAssertNil(v2.price(forModel: "codex-auto-review-v2"))
        XCTAssertNotNil(v2.price(forModel: "codex-auto-review"))
    }

    // MARK: - Released-sequence checkpoint

    /// An edit to the served manifest without a higher `sequence` would never reach
    /// clients that already hold the released one. The checkpoint records what the
    /// last release shipped; it is advanced by the release process only.
    func testSequenceIsRaisedWheneverTheManifestDiffersFromTheLastRelease() throws {
        let released = try json("prices-v2.released.json")
        let releasedSequence = try XCTUnwrap(released["sequence"] as? Int)
        let releasedFingerprint = try XCTUnwrap(released["fingerprint"] as? String)
        let table = RunwayPriceTable.makeForTesting()
        // The exact fingerprint covers every byte that clients compare, including
        // `_note` and `updated`; the semantic revision would miss a metadata-only edit.
        if table.manifestFingerprint == releasedFingerprint {
            XCTAssertEqual(table.sequence, releasedSequence,
                           "an unchanged manifest keeps the released sequence")
        } else {
            XCTAssertGreaterThan(table.sequence, releasedSequence,
                                 "the manifest changed since the last release, so sequence must be raised")
        }
    }

    // MARK: - Provider rate revision

    private func table(models: String, aliases: String = "{}", sequence: Int = 1,
                       note: String = "n") -> RunwayPriceTable {
        let t = RunwayPriceTable.makeEmptyForTesting()
        let json = #"{"version":2,"sequence":\#(sequence),"updated":"2026-10-13","_note":"\#(note)","aliases":\#(aliases),"models":{\#(models)}}"#
        XCTAssertTrue(t.loadForTesting(json: Data(json.utf8)))
        return t
    }

    private let claudeRow = #""claude-opus":{"inputPerMTok":5,"cachedInputPerMTok":0.5,"outputPerMTok":25}"#
    private let gptRow = #""gpt-5":{"inputPerMTok":1.25,"cachedInputPerMTok":0.125,"outputPerMTok":10}"#
    private let geminiRow = #""gemini-3.5-flash":{"inputPerMTok":1,"cachedInputPerMTok":0.1,"outputPerMTok":4}"#

    func testForeignRowsAliasesAndMetadataDoNotMoveProviderRevisions() {
        let base = table(models: "\(claudeRow),\(gptRow)")
        let withGemini = table(models: "\(claudeRow),\(gptRow),\(geminiRow)")
        let withAlias = table(models: "\(claudeRow),\(gptRow)", aliases: #"{"opus":"claude-opus"}"#)
        let metadataOnly = table(models: "\(claudeRow),\(gptRow)", sequence: 77, note: "other")
        for other in [withGemini, withAlias, metadataOnly] {
            XCTAssertEqual(other.rateRevision(forProvider: "claude"), base.rateRevision(forProvider: "claude"))
            XCTAssertEqual(other.rateRevision(forProvider: "codex"), base.rateRevision(forProvider: "codex"))
        }
        XCTAssertNotEqual(withGemini.revision, base.revision, "the global revision still tracks every row")
        XCTAssertNotEqual(withAlias.revision, base.revision, "aliases change which rate a session gets")
    }

    func testOwnRateChangeMovesOnlyThatProvider() {
        let base = table(models: "\(claudeRow),\(gptRow)")
        let claudeChanged = table(models: #""claude-opus":{"inputPerMTok":6,"cachedInputPerMTok":0.5,"outputPerMTok":25},\#(gptRow)"#)
        XCTAssertNotEqual(claudeChanged.rateRevision(forProvider: "claude"), base.rateRevision(forProvider: "claude"))
        XCTAssertEqual(claudeChanged.rateRevision(forProvider: "codex"), base.rateRevision(forProvider: "codex"))

        let codexAdded = table(models: #"\#(claudeRow),\#(gptRow),"codex-auto-review":{"inputPerMTok":4,"cachedInputPerMTok":0.4,"outputPerMTok":20}"#)
        XCTAssertEqual(codexAdded.rateRevision(forProvider: "claude"), base.rateRevision(forProvider: "claude"))
        XCTAssertNotEqual(codexAdded.rateRevision(forProvider: "codex"), base.rateRevision(forProvider: "codex"))
    }

    /// A non-rate annotation on a provider's own row must not move its revision.
    func testNonRateRowAnnotationDoesNotMoveTheProviderRevision() {
        let base = table(models: "\(claudeRow),\(gptRow)")
        let annotated = table(models: #""claude-opus":{"inputPerMTok":5,"cachedInputPerMTok":0.5,"outputPerMTok":25,"displayName":"Opus","deprecated":false},\#(gptRow)"#)
        XCTAssertEqual(annotated.rateRevision(forProvider: "claude"), base.rateRevision(forProvider: "claude"))
    }

    func testEveryRateBearingFieldMovesTheProviderRevision() {
        let base = table(models: claudeRow).rateRevision(forProvider: "claude")
        for row in [
            #""claude-opus":{"inputPerMTok":5,"cachedInputPerMTok":0.6,"outputPerMTok":25}"#,
            #""claude-opus":{"inputPerMTok":5,"cachedInputPerMTok":0.5,"outputPerMTok":25,"cacheWritePerMTok":6.25}"#,
            #""claude-opus":{"inputPerMTok":5,"cachedInputPerMTok":0.5,"outputPerMTok":25,"cacheWrite1hPerMTok":10}"#,
            #""claude-opus":{"inputPerMTok":5,"cachedInputPerMTok":0.5,"outputPerMTok":25,"inferenceGeoUSMultiplier":1.1}"#,
            #""claude-opus":{"inputPerMTok":5,"cachedInputPerMTok":0.5,"outputPerMTok":25,"longContext":{"thresholdInputTokens":200000,"inputMultiplier":2,"outputMultiplier":1.5}}"#,
            #""claude-opus":{"inputPerMTok":5,"cachedInputPerMTok":0.5,"outputPerMTok":25,"fast":{"inputPerMTok":10,"cachedInputPerMTok":1,"outputPerMTok":50}}"#
        ] {
            XCTAssertNotEqual(table(models: row).rateRevision(forProvider: "claude"), base, row)
        }
    }

    func testUnknownProviderHasNoRevision() {
        XCTAssertEqual(RunwayPriceTable.makeForTesting().rateRevision(forProvider: "gemini"), 0)
    }

    // MARK: - Evidence strings

    func testEvidenceStringsResolveAgainstTheBundledTable() {
        let s = RunwayPriceTable.makeForTesting().snapshot()
        for raw in ["anthropic/claude-sonnet-5", "openai/gpt-5.5", "claude-haiku-4.5",
                    "Claude Sonnet 4.6 (Thinking)",
                    "z-ai/glm-5.3-flash", "minimax-m2.5-free", "kimi-k2.7-code",
                    "grok-4.6",
                    "muse-spark-1.3-contributor-free"] {
            XCTAssertNotNil(s.resolvedPrice(forModel: raw), raw)
        }
        for raw in ["big-pickle", "x-preview-f-free", "gateway-injected", "coder-model",
                    "qwen3.5-9b", "kimi-k2.7-code-v2"] {
            XCTAssertNil(s.resolvedPrice(forModel: raw), raw)
        }
    }
}
