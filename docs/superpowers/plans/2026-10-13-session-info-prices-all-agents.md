# Session Info Prices For All Agents Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Session Info shows an API-equivalent cost for OpenCode, OpenClaw, Hermes, Kimi, Cline, Qwen, Antigravity, and DeepSeek Harness sessions, and a specific reason when it cannot.

**Architecture:** A pure `ModelPriceKeyResolver` maps raw model strings to price keys. A new schema-2 manifest (`docs/prices-v2.json`) carries the new vendor rows and aliases, so shipped schema-1 clients never see them. The calculator treats model, context size, cache-write TTL, and speed tier as required evidence and refuses to price when evidence is missing.

**Tech Stack:** Swift 5, XCTest, Xcode project `AgentSessions.xcodeproj`, scheme `AgentSessions`. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-10-13-session-info-prices-all-agents-design.md` (revision 3). Read it before any task.

## Global Constraints

- **Right or absent.** Any unpriceable self-owned contribution makes the whole figure unavailable. Never infer, default, or borrow a value to produce a figure.
- **API-equivalent = standard list rate.** No native recorded cost anywhere.
- **No rate from memory.** Every new rate is read from the vendor's own pricing page on the day of the change, with host and UTC date recorded in `_note`.
- **Shipped clients are untouched.** `docs/prices.json` stays `version: 1` and gets no new vendor rows.
- **Out of scope:** Droid, fx, Cursor, Devin, Grok descriptors; Quota Meter; Runway burn math.
- **Edits use the Edit tool only.** No inline Python or heredoc scripts to rewrite Swift or JSON.
- **New Swift files** are added with `./scripts/xcode_add_file.rb` (argument order PROJECT TARGET FILE GROUP). A correct run adds exactly 4 lines to `project.pbxproj`.
- **Tests:** `./scripts/xcode_test_stable.sh`. It runs `clean test`, so one invocation is slow. Run a single class with `-only-testing:AgentSessionsTests/<Class>`. The app test host opens the real `index.db`; do not add migrations in this work.
- **Test count is an invariant, read from the result bundle.** Never grep `Executed N tests` from stdout: the scheme has two test bundles and stdout totals are per bundle (`agents.md`, "Tests"). Use `xcrun xcresulttool get test-results summary --path .deriveddata-tests/Logs/Test/Run-*.xcresult`. After every task the total must be the old total plus the tests that task added. A fall must be explained with a test-name inventory diff.
- **Execution starts from a fresh state.** Bind a new Repo MCP coding task to the actual execution `HEAD` (the review task `agent-sessions-prices-spec-review-20261013` is bound to the older `6467bbe0`). Leave `docs/agent-support/agent-support-ledger.yml` and every other path the owner has modified untouched.
- **Stronger review checkpoints** after Tasks 3, 5, 10, and 12, then a whole-branch review. Task 10 mutates persistent index state. Task 11's reviewer independently re-reads every vendor page and checks every entered rate and long-context rule.
- **Subagents never run `xcodebuild` in parallel.** One build at a time.
- **Commits:** only when the owner says "commit". Use `git commit -- <paths>` with the exact paths of the task. Conventional Commits, trailers `Tool:`, `Model:`, `Why:`. No `Co-Authored-By`, no "Generated with" footer. The "Commit" steps below give the message to use when the owner approves.
- **No branches or worktrees** without owner approval.

## Review Focus

1. **A model slug that extends a priced key** (`kimi-k2.7-code-v2`, `glm-4.70`) must be unpriced, never priced at the base rate. Test in Task 2.
2. **A session whose model changed mid-way** must price each request at the model in force for that request, or be unpriced. Tests in Tasks 8, 9, 10.
3. **A cached manifest from an older build** (schema 1, or schema 2 with a lower or equal `sequence`) must never override the bundled table. Tests in Task 3.
4. **A stored telemetry cache or calibration written by the previous build** must decode without crashing and must not be trusted for a figure. Tests in Tasks 4 and 5.
5. **A model string with unexpected shape** (two slashes, empty after stripping, a parenthetical that is not an effort word, mixed case) must pass through the resolver unchanged or return nil, never crash and never match a wrong row. Test in Task 1.

## File Structure

| File | Responsibility |
|---|---|
| Create `AgentSessions/Telemetry/ModelPriceKeyResolver.swift` | Raw model string → price key + free-route flag. Pure. |
| Create `AgentSessionsTests/ModelPriceKeyResolverTests.swift` | Resolver table tests. |
| Create `AgentSessionsTests/PriceManifestV2Tests.swift` | Schema-2 decode, sequence rule, lifecycle, guards, provider revision. |
| Create `docs/prices-v2.json` | Served schema-2 manifest: all rows, `sequence`, `aliases`. |
| Create `docs/prices-v2.released.json` | Checkpoint of the last released `sequence` and `revision`. Advanced by the release process only. |
| Modify `AgentSessions/Services/AntigravitySessionIndexer.swift` | Forced reparse plus a durable `session_meta` write before the parser generation advances. |
| Modify `AgentSessions/CodexStatus/RunwayPriceTable.swift` | Strict matcher, single matcher, schema 2, sequence, aliases, provider revision, bundled v2 table. |
| Modify `AgentSessions/Telemetry/TelemetryCostCalculator.swift` | Resolved lookup, free-route list, cache-write TTL evidence. |
| Modify `AgentSessions/Model/SessionTelemetry.swift` | `freeRouteModels`, `costUnavailableReason`, parser version 15. |
| Modify `AgentSessions/Model/SessionSourceDescriptor.swift` | `cacheWriteTTLVerified` capability. |
| Modify `AgentSessions/Telemetry/SessionTelemetryEngine.swift` | Cost gate uses the new reason and TTL flag. |
| Modify `AgentSessions/Views/TranscriptTelemetryView.swift` | `costValue` help text and unpriced reasons. |
| Modify `AgentSessions/CodexStatus/WeeklyQuotaCalibration.swift`, `CodexStatusService.swift`, `ClaudeStatus/ClaudeUsageModel.swift` | Provider-scoped price revision. |
| Modify readers: `Hermes/HermesTelemetryReader.swift`, `OpenCode/OpenCodeSqliteReader.swift`, `Telemetry/KimiTelemetryAccumulator.swift`, `Telemetry/AntigravityTelemetryAccumulator.swift`, `Services/AntigravityTranscriptParser.swift`, `Services/AntigravitySessionIndexer.swift` | Evidence rules from spec §6 and §8. |
| Modify 8 descriptors (OpenCode, OpenClaw, Hermes, Kimi, Cline, Qwen, Antigravity, DeepSeek Harness) | `cost: .partial(...)`, TTL flag. |

---

### Task 0: Baseline

**Files:** none.

- [ ] **Step 1: Record the baseline test totals**

```bash
./scripts/xcode_test_stable.sh > .deriveddata-tests-baseline.log 2>&1; echo "exit=$?"
xcrun xcresulttool get test-results summary --path .deriveddata-tests/Logs/Test/Run-*.xcresult
```

Expected: exit 0, `failedTests: 0`. Write `totalTestCount`, `passedTests`, and `skippedTests` into the PR notes. Every later task compares against them. Delete the log file afterwards; it is not committed.

- [ ] **Step 1b: Record the test-name inventory**

```bash
find AgentSessionsTests -name '*.swift' -print0 | xargs -0 grep -ho "func test[A-Za-z0-9_]*" | sort > /tmp/as-tests-before.txt
wc -l /tmp/as-tests-before.txt
```

Task 13 diffs against this file.

- [ ] **Step 2: Confirm the working tree state**

Run: `git status --short`
Expected: only the two untracked spec files and this plan. If other paths are modified, they belong to the owner's parallel work; never stage them.

---

### Task 1: `ModelPriceKeyResolver`

**Files:**
- Create: `AgentSessions/Telemetry/ModelPriceKeyResolver.swift`
- Test: `AgentSessionsTests/ModelPriceKeyResolverTests.swift`

**Interfaces:**
- Produces: `struct ResolvedPriceKey { let key: String; let viaFreeRoute: Bool }` and `enum ModelPriceKeyResolver { static func resolve(_ raw: String?, aliases: [String: String]) -> ResolvedPriceKey? }`.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import AgentSessions

final class ModelPriceKeyResolverTests: XCTestCase {
    private let aliases = ["gemini 3.5 flash": "gemini-3.5-flash",
                           "claude sonnet 4.6": "claude-sonnet-4-6",
                           "muse-spark-1.3": "muse-spark-1.3"]

    private func resolve(_ raw: String?) -> ResolvedPriceKey? {
        ModelPriceKeyResolver.resolve(raw, aliases: aliases)
    }

    func testEvidenceStringsResolve() {
        XCTAssertEqual(resolve("anthropic/claude-sonnet-5"),
                       ResolvedPriceKey(key: "claude-sonnet-5", viaFreeRoute: false))
        XCTAssertEqual(resolve("openai/gpt-5.5"),
                       ResolvedPriceKey(key: "gpt-5.5", viaFreeRoute: false))
        XCTAssertEqual(resolve("z-ai/glm-5.3-flash"),
                       ResolvedPriceKey(key: "glm-5.3-flash", viaFreeRoute: false))
        XCTAssertEqual(resolve("claude-haiku-4.5"),
                       ResolvedPriceKey(key: "claude-haiku-4-5", viaFreeRoute: false))
        XCTAssertEqual(resolve("Gemini 3.5 Flash (Medium)"),
                       ResolvedPriceKey(key: "gemini-3.5-flash", viaFreeRoute: false))
        XCTAssertEqual(resolve("Claude Sonnet 4.6 (Thinking)"),
                       ResolvedPriceKey(key: "claude-sonnet-4-6", viaFreeRoute: false))
    }

    func testFreeRoutesKeepTheFlagThroughAliasLookup() {
        XCTAssertEqual(resolve("muse-spark-1.3-contributor-free"),
                       ResolvedPriceKey(key: "muse-spark-1.3", viaFreeRoute: true))
        XCTAssertEqual(resolve("cline-free/deepseek-v4.1-flash"),
                       ResolvedPriceKey(key: "deepseek-v4.1-flash", viaFreeRoute: true))
        XCTAssertEqual(resolve("minimax-m2.5-free"),
                       ResolvedPriceKey(key: "minimax-m2.5", viaFreeRoute: true))
        XCTAssertEqual(resolve("poolside/laguna-s-2.1:free"),
                       ResolvedPriceKey(key: "laguna-s-2.1", viaFreeRoute: true))
    }

    func testUnrecognizedShapesPassThroughUnchanged() {
        // Unknown provider prefix is not stripped.
        XCTAssertEqual(resolve("acme/claude-sonnet-5")?.key, "acme/claude-sonnet-5")
        // Two slashes: not a single provider prefix.
        XCTAssertEqual(resolve("openrouter/anthropic/claude-sonnet-5")?.key,
                       "openrouter/anthropic/claude-sonnet-5")
        // A parenthetical that is not an effort word stays.
        XCTAssertEqual(resolve("some-model (beta)")?.key, "some-model (beta)")
        // The dot rule is Claude-only.
        XCTAssertEqual(resolve("gpt-5.5")?.key, "gpt-5.5")
        // Preview suffix is never normalized away.
        XCTAssertEqual(resolve("claude-sonnet-5-preview")?.key, "claude-sonnet-5-preview")
    }

    func testEmptyInputsReturnNil() {
        XCTAssertNil(resolve(nil))
        XCTAssertNil(resolve(""))
        XCTAssertNil(resolve("   "))
        XCTAssertNil(resolve("-free"))
        XCTAssertNil(resolve("cline-free/"))
    }
}
```

- [ ] **Step 2: Add the test file to the project and confirm it fails to build**

```bash
./scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessionsTests \
  AgentSessionsTests/ModelPriceKeyResolverTests.swift AgentSessionsTests
```

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/ModelPriceKeyResolverTests 2>&1 | tail -20`
Expected: build failure, "Cannot find 'ModelPriceKeyResolver' in scope".

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// A candidate price-table key for a raw model string, plus whether the raw
/// string named a free or promotional route.
struct ResolvedPriceKey: Equatable, Sendable {
    let key: String
    let viaFreeRoute: Bool
}

/// Maps the model strings agents write to price-table keys.
///
/// Never guesses: a string no step recognizes passes through unchanged and the
/// price lookup decides. Free-route detection is separate from key resolution so
/// an alias hit cannot erase it.
enum ModelPriceKeyResolver {
    private static let reasoningSuffixes: Set<String> =
        ["minimal", "low", "medium", "high", "xhigh", "thinking"]
    private static let freeSuffixes = [":free", "-contributor-free", "-free"]
    private static let freePrefix = "cline-free/"
    private static let providerPrefixes: Set<String> =
        ["anthropic", "openai", "google", "z-ai", "moonshotai", "deepseek", "minimax",
         "x-ai", "qwen", "meta", "opencode", "openrouter", "poolside"]

    static func resolve(_ raw: String?, aliases: [String: String]) -> ResolvedPriceKey? {
        guard let raw else { return nil }
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return nil }

        // 2. One trailing "(effort)" group, only for known effort words.
        if value.hasSuffix(")"), let open = value.lastIndex(of: "(") {
            let inner = value[value.index(after: open)..<value.index(before: value.endIndex)]
            if reasoningSuffixes.contains(String(inner)) {
                value = String(value[..<open]).trimmingCharacters(in: .whitespaces)
            }
        }

        // 3. Free route.
        var viaFreeRoute = false
        if value.hasPrefix(freePrefix) {
            viaFreeRoute = true
            value = String(value.dropFirst(freePrefix.count))
        }
        if let suffix = freeSuffixes.first(where: { value.hasSuffix($0) }) {
            viaFreeRoute = true
            value = String(value.dropLast(suffix.count))
        }

        // 4. Exactly one provider prefix, from the allowlist.
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        if parts.count == 2, providerPrefixes.contains(String(parts[0])) {
            value = String(parts[1])
        }
        guard !value.isEmpty else { return nil }

        // 5. Alias.
        if let alias = aliases[value] { value = alias }

        // 6. Claude dot variant: "4.5" → "4-5" between digits.
        if value.hasPrefix("claude-") {
            let chars = Array(value)
            var out = ""
            for (index, char) in chars.enumerated() {
                let betweenDigits = char == "." && index > 0 && index < chars.count - 1
                    && chars[index - 1].isNumber && chars[index + 1].isNumber
                out.append(betweenDigits ? "-" : char)
            }
            value = out
        }
        return ResolvedPriceKey(key: value, viaFreeRoute: viaFreeRoute)
    }
}
```

- [ ] **Step 4: Add the source file to the project and run the tests**

```bash
./scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessions \
  AgentSessions/Telemetry/ModelPriceKeyResolver.swift AgentSessions/Telemetry
git diff --stat AgentSessions.xcodeproj/project.pbxproj
```

Expected pbxproj delta: exactly 8 added lines (4 per file).

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/ModelPriceKeyResolverTests 2>&1 | tail -8`
Expected: 4 tests, 0 failures.

- [ ] **Step 5: Commit (when the owner approves)**

Message: `feat(prices): add ModelPriceKeyResolver for agent model strings`
Paths: the two new files and `AgentSessions.xcodeproj/project.pbxproj`.

---

### Task 2: Strict matching, one matcher, resolved lookup

**Files:**
- Modify: `AgentSessions/CodexStatus/RunwayPriceTable.swift` (`RunwayPriceSnapshot` at ~138–210; `RunwayPriceTable.price(forModel:)` at ~298–331)
- Test: `AgentSessionsTests/PriceManifestV2Tests.swift` (new)

**Interfaces:**
- Consumes: `ModelPriceKeyResolver.resolve(_:aliases:)`.
- Produces: `RunwayPriceSnapshot.init(models:aliases:updatedDate:revision:manifestFingerprint:)` with `aliases: [String: String] = [:]`; `func resolvedPrice(forModel raw: String?) -> (price: RunwayModelPrice, viaFreeRoute: Bool)?`.

- [ ] **Step 1: Write the failing tests**

Create `AgentSessionsTests/PriceManifestV2Tests.swift`:

```swift
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
}
```

Add it to the project:

```bash
./scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessionsTests \
  AgentSessionsTests/PriceManifestV2Tests.swift AgentSessionsTests
```

- [ ] **Step 2: Run to verify failure**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/PriceManifestV2Tests 2>&1 | tail -20`
Expected: build failure on `aliases:` and `resolvedPrice`.

- [ ] **Step 3: Implement in `RunwayPriceSnapshot`**

Add the stored property and replace `price(forModel:)`:

```swift
struct RunwayPriceSnapshot: Sendable {
    let models: [String: RunwayModelPrice]
    /// Normalized model string → `models` key. See `ModelPriceKeyResolver`.
    let aliases: [String: String]
    let updatedDate: String
    let revision: Int
    var semanticRevision: Int { revision }
    let manifestFingerprint: String

    init(models: [String: RunwayModelPrice], aliases: [String: String] = [:],
         updatedDate: String, revision: Int, manifestFingerprint: String) {
        self.models = models
        self.aliases = aliases
        self.updatedDate = updatedDate
        self.revision = revision
        self.manifestFingerprint = manifestFingerprint
    }

    func price(forModel slug: String?) -> RunwayModelPrice? {
        Self.price(forModel: slug, in: models)
    }

    /// The single matcher. Claude and GPT keep their guarded prefix rules; every
    /// other key matches exactly or with a dated-snapshot suffix, never by bare
    /// prefix, so a variant such as `kimi-k2.7-code-v2` cannot inherit a base rate.
    static func price(forModel slug: String?,
                      in models: [String: RunwayModelPrice]) -> RunwayModelPrice? {
        guard let slug, !slug.isEmpty else { return nil }
        if let exact = models[slug] { return exact }
        var best: (key: String, price: RunwayModelPrice)?
        for (key, price) in models where slug.hasPrefix(key) {
            if key.hasPrefix("claude-") {
                guard isRecognizedClaudeSlug(slug, extending: key) else { continue }
            } else {
                // GPT keys and every other vendor: exact key plus a dated suffix only.
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
```

`isRecognizedGPTSnapshot` already accepts exactly `-YYYYMMDD` and `-YYYY-MM-DD`. Rename it to `isDatedSnapshot` in the same edit (its body is unchanged) and keep it `private static`. Keep `isRecognizedClaudeSlug` as is.

- [ ] **Step 4: Remove the duplicate matcher in `RunwayPriceTable`**

Replace the body of `RunwayPriceTable.price(forModel:)` and delete its private `isRecognizedGPTSnapshot` and `isRecognizedClaudeSlug` copies:

```swift
    /// nil slug or no safe matching key → nil (→ $ unpriceable).
    func price(forModel slug: String?) -> RunwayModelPrice? {
        lock.lock(); defer { lock.unlock() }
        return RunwayPriceSnapshot.price(forModel: slug, in: models)
    }
```

`RunwayModelPrice` must be `Equatable` for `testTableAndSnapshotAgreeOnEveryLookup`; it already is.

- [ ] **Step 5: Run the tests**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/PriceManifestV2Tests -only-testing:AgentSessionsTests/CodexUsageParserTests -only-testing:AgentSessionsTests/ClaudeRunwayParserTests -only-testing:AgentSessionsTests/TelemetryCostCalculatorTests 2>&1 | tail -12`
Expected: all pass. If an existing test relied on bare-prefix matching for a non-Claude, non-GPT key, stop and report it; do not weaken the matcher.

- [ ] **Step 6: Commit (when the owner approves)**

Message: `fix(prices): match non-Claude, non-GPT keys exactly or by dated suffix`

---

### Task 3: Manifest schema 2

**Files:**
- Modify: `AgentSessions/CodexStatus/RunwayPriceTable.swift` (properties ~232–259, `adopt` ~272–282, decoding ~356–453, `bundledJSON` ~489–551)
- Create: `docs/prices-v2.json`
- Modify: `docs/prices.json` (`_note` only)
- Modify: existing tests that load schema-1 manifests (`CodexUsageParserTests.swift`, `SessionTelemetryEngineTests.swift`, `WeeklyQuotaCalibrationTests.swift`, `ClaudeRunwayParserTests.swift:1266`)
- Test: `AgentSessionsTests/PriceManifestV2Tests.swift`

**Interfaces:**
- Produces: `RunwayPriceTable.supportedVersion == 2`; `var sequence: Int`; `static let bundledJSON` (schema 2); `static let legacyV1FileName = "prices.json"`; `static let cacheFileName = "prices-v2.json"`; `snapshot()` now carries `aliases`.
- Sequence format: integer `YYYYMMDDNN` (date plus a two-digit counter). First value: `2026101301`.

- [ ] **Step 1: Write the failing tests** (append to `PriceManifestV2Tests`)

```swift
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
```

Step 3 also moves the local `knownVersions` dictionary out of `isRecognizedClaudeSlug` into `static let knownClaudeVersions: [String: Set<String>]` (same contents) so the production matcher has one definition. The parity test enumerates forms from it and uses the frozen `ShippedV1Matcher` only to compute the expected result.

Step 3 also adds two DEBUG seams for `testV2ClientLeavesTheLegacyCacheFileUntouched`: `static var cacheDirectoryOverride: URL?` (read by `cacheURL()` before the Application Support lookup), and `func persistForTesting(_ data: Data)`, which calls the same private `persist(_:)` that `refreshInBackground` now uses for its `data.write(to: Self.cacheURL(), options: .atomic)`.

Create `docs/prices-v2.released.json` in Step 5 with the pre-release value:

```json
{ "sequence": 0, "fingerprint": "", "_note": "Last released prices-v2.json. Written by the release process only: after a release, set sequence and fingerprint to the values the released build bundles. Never edit together with a price change." }
```

`fingerprint` is `RunwayPriceTable.makeForTesting().manifestFingerprint` of the released build. Task 13 adds the release-process step that advances it.

- [ ] **Step 2: Run to verify failure**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/PriceManifestV2Tests 2>&1 | tail -20`
Expected: build failure on `sequence`, `cacheFileName`, `knownClaudeVersions`.

- [ ] **Step 3: Implement schema 2 in `RunwayPriceTable`**

Replace the constants, state, `init`, `adopt`, `snapshot`, `Manifest`, `decode`, and `cacheURL`:

```swift
    /// Only schema 2 is accepted. A schema-1 document — the legacy manifest that
    /// shipped clients still read — is rejected from every source, so it can never
    /// become the resolver source for a client that matches strictly.
    static let supportedVersion = 2
    static let legacyV1FileName = "prices.json"
    static let cacheFileName = "prices-v2.json"
    private static let manifestURL = URL(string: "https://jazzyalex.github.io/agent-sessions/prices-v2.json")!
```

```swift
    private var aliases: [String: String] = [:]
    /// `sequence` of the table currently loaded. Strictly increases on every edit.
    private var loadedSequence = 0
    private var providerRevisions: [String: Int] = [:]
```

```swift
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
        if readCache, let data = try? Data(contentsOf: Self.cacheURL()), let decoded = Self.decode(data) {
            adopt(decoded)
        }
    }

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

    func snapshot() -> RunwayPriceSnapshot {
        lock.lock(); defer { lock.unlock() }
        return RunwayPriceSnapshot(models: models, aliases: aliases, updatedDate: loadedUpdated,
                                   revision: _revision, manifestFingerprint: _manifestFingerprint)
    }
```

`install` is called from `init` without the lock (no other thread can hold the instance yet) and from `adopt` under it.

```swift
    private struct Manifest: Decodable {
        let version: Int
        let sequence: Int?
        let updated: String?
        let aliases: [String: String]?
        let models: [String: RawPrice]
    }
```

```swift
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
        return DecodedManifest(models: models, aliases: aliases, updated: manifest.updated ?? "",
                               sequence: sequence, semanticRevision: semantic,
                               providerRevisions: [:],   // filled in Task 4
                               manifestFingerprint: fingerprint)
    }

    private static func stableHash(_ object: Any) -> Int? {
        guard let canonical = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return nil }
        let digest = SHA256.hash(data: canonical)
        return Int(digest.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } & UInt64(Int.max))
    }
```

In `cacheURL()` replace `"prices.json"` with `Self.cacheFileName`. Change `loadForTesting` to use the new `decode`/`adopt` (its body is unchanged). In `refreshInBackground` nothing changes except that `adopt` now compares sequence.

- [ ] **Step 4: Convert the bundled table to schema 2**

In `bundledJSON`, change the first two fields and add `aliases`. Keep every existing model row byte-for-byte:

```json
      "version": 2,
      "sequence": 2026101301,
      "updated": "2026-10-13",
      "aliases": {},
```

In the `_note`, replace the last sentence ("Clients only accept a manifest whose updated date …") with: `Schema 2. Clients adopt a manifest only when sequence is strictly greater than the loaded one, so raise sequence (YYYYMMDDNN) on every edit, in BOTH docs/prices-v2.json and the bundled copy in RunwayPriceTable.swift. Claude, GPT and codex-auto-review rows must also stay identical in the legacy docs/prices.json.`

- [ ] **Step 5: Create `docs/prices-v2.json`**

Copy `docs/prices.json` to `docs/prices-v2.json` with `cp`, then apply the same three field edits and the same `_note` edit as Step 4 using the Edit tool. The two documents must be equal as JSON; `testServedV2ManifestEqualsTheBundledTable` proves it.

In `docs/prices.json` change only `_note`: append `Legacy schema-1 manifest for Agent Sessions 5.5.2 and older. It receives Claude, GPT and codex-auto-review rate corrections only. New vendor rows live in prices-v2.json.` Do not change `updated` unless a rate changes.

- [ ] **Step 6: Migrate existing tests that load schema-1 manifests**

Run: `grep -n '"version":1\|"version": 1' AgentSessionsTests/*.swift`

For each hit that is passed to `loadForTesting` and is **expected to be accepted**: change `"version":1` to `"version":2,"sequence":9999999999`. For each that is **expected to be rejected as older** (for example `testPriceTableIgnoresOlderCachedManifest`, the `2020-01-01` manifest): change to `"version":2,"sequence":1`. For a test that asserts an unrecognized version is rejected (`testPriceTableRejectsMalformedAndUnrecognizedVersion`), keep the unrecognized value and add one assertion that `"version":1` is also rejected.

Replace `testServedManifestMatchesTheBundledTable` (`ClaudeRunwayParserTests.swift:1266`) with a one-line comment pointing at `PriceManifestV2Tests`; the new guard tests cover it. Net test count for this replacement: minus 1, recorded in the PR notes.

**Every successive accepted load needs a strictly higher `sequence`.** The rule is `decoded.sequence > loadedSequence`, so two different manifests loaded in turn with the same `sequence` fail on the second load. Known cases:

- `SessionTelemetryEngineTests.testSameDateManifestMetadataChangeInvalidatesExactProvenance` (~line 1386): the first manifest gets `"sequence":9999999998`, the second `"sequence":9999999999`. Both stay `updated: 2099-01-01`; the test is about a same-date metadata change.
- `WeeklyQuotaCalibrationTests.testSol61PriceUpdateRecoversAllWeeklyRowsFromRejectedMixedHistory` (~line 2195): it derives manifests from the bundled table. Set the "old" manifest's `sequence` to the bundle's `sequence + 1` and the corrected one to `sequence + 2`. Read the bundle value from `RunwayPriceTable.makeForTesting().sequence`, never a literal.

Then search for the remaining pattern: `grep -n "loadForTesting" AgentSessionsTests/*.swift AgentSessionsTests/**/*.swift`. In every test that calls it more than once on the same table, give each manifest that must be accepted a higher `sequence` than the one before. `updated` no longer orders anything.

- [ ] **Step 7: Run**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/PriceManifestV2Tests -only-testing:AgentSessionsTests/CodexUsageParserTests -only-testing:AgentSessionsTests/SessionTelemetryEngineTests -only-testing:AgentSessionsTests/WeeklyQuotaCalibrationTests -only-testing:AgentSessionsTests/ClaudeRunwayParserTests 2>&1 | tail -15`
Expected: all pass.

- [ ] **Step 8: Commit (when the owner approves)**

Message: `feat(prices): move the price manifest to schema 2 with a monotonic sequence`

---

### Task 4: Provider-scoped rate revision

**Files:**
- Modify: `AgentSessions/CodexStatus/RunwayPriceTable.swift` (`decode`, `RunwayPriceSnapshot`, accessors)
- Modify: `AgentSessions/CodexStatus/WeeklyQuotaCalibration.swift:774,791,801,806,812,1599`
- Modify: `AgentSessions/CodexStatus/WeeklyQuotaBootstrap.swift:190,321` (Codex scan), `:626,668` (Claude scan)
- Modify: `AgentSessions/CodexStatus/CodexStatusService.swift:695`, `AgentSessions/ClaudeStatus/ClaudeUsageModel.swift:660`
- Modify: every test that stamps or compares a calibration price revision (Step 4 lists the search)
- Test: `AgentSessionsTests/PriceManifestV2Tests.swift`, `AgentSessionsTests/WeeklyQuotaCalibrationTests.swift`, `AgentSessionsTests/WeeklyQuotaBootstrapTests.swift`

**Interfaces:**
- Produces: `RunwayPriceSnapshot.rateRevision(forProvider: String) -> Int` (`"claude"` or `"codex"`; any other value returns 0), with `RunwayPriceSnapshot.init(..., providerRevisions: [String: Int] = [:])`. `RunwayPriceTable.rateRevision(forProvider:)` returns `snapshot().rateRevision(forProvider:)`. `priceRevisionProvider` becomes `@Sendable (String) -> Int`.
- Rule: a bootstrap scan prices and stamps from **one captured snapshot**, so a background manifest refresh cannot stamp a revision from a different table than the rates it used.

- [ ] **Step 1: Write the failing tests** (append to `PriceManifestV2Tests`)

```swift
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
```

Append to `WeeklyQuotaCalibrationTests`. It goes through real persistence, using the file's existing `persistedCalibration(scope:hasExactPercent:model:)` and `scope(priceRevision:)` helpers (see `testOnlyScopedCalibrationSurvivesRestart`, ~line 482):

```swift
    /// The revision formula changed with provider scoping. A calibration persisted
    /// under the old global revision is intentionally not restored (one-time
    /// reset); one persisted under the provider revision survives a relaunch.
    func testProviderRevisionResetsLegacyCalibrationOnceThenSurvivesRelaunch() throws {
        let prices = RunwayPriceTable.makeForTesting()
        let legacyRevision = prices.revision
        let providerRevision = prices.rateRevision(forProvider: "codex")
        XCTAssertNotEqual(legacyRevision, providerRevision)
        let end = t0.addingTimeInterval(10 * 60)

        // Launch N (old build): persisted under the global revision.
        let legacy = try persistedCalibration(scope: scope(priceRevision: legacyRevision),
                                              hasExactPercent: false, model: "gpt-5.6")
        // Launch N+1 (new build): a fresh tracker restores under the provider revision.
        var upgraded = WeeklyQuotaCalibrationTracker()
        upgraded.restore(from: legacy.data, scope: scope(priceRevision: providerRevision), now: end)
        XCTAssertNil(upgraded.percentPointsPerDollar(now: end), "one-time reset")

        // The new build persists under the provider revision; launch N+2 keeps it.
        let current = try persistedCalibration(scope: scope(priceRevision: providerRevision),
                                               hasExactPercent: false, model: "gpt-5.6")
        var relaunched = WeeklyQuotaCalibrationTracker()
        relaunched.restore(from: current.data,
                           scope: scope(priceRevision: RunwayPriceTable.makeForTesting()
                                            .rateRevision(forProvider: "codex")),
                           now: end)
        XCTAssertEqual(try XCTUnwrap(relaunched.percentPointsPerDollar(now: end)),
                       current.ratio, accuracy: 0.000_001)
    }
```

Append to `WeeklyQuotaBootstrapTests` (reuse the setup of an existing Codex bootstrap scan test and of an existing Claude one in that file):

```swift
    func testBootstrapResultsAreStampedWithTheProviderRevision() throws {
        // Run one Codex and one Claude bootstrap scan with RunwayPriceTable.makeForTesting().
        // Assert:
        //   codexResult.priceRevision == table.rateRevision(forProvider: "codex")
        //   claudeResult.priceRevision == table.rateRevision(forProvider: "claude")
        //   both != table.revision
    }
```

The three assertions in the comment are required; the setup is copied from the existing scan tests in the same file.

- [ ] **Step 2: Run to verify failure**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/PriceManifestV2Tests 2>&1 | tail -15`
Expected: build failure on `rateRevision(forProvider:)`.

- [ ] **Step 3: Implement**

In `decode`, replace `providerRevisions: [:]` with a computed value:

```swift
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
```

and pass `providerRevisions: providerRevisions`.

Carry the values on the snapshot, so a scan that captured one snapshot stamps the revision of exactly the rates it used. In `RunwayPriceSnapshot` add a stored `let providerRevisions: [String: Int]`, an init parameter `providerRevisions: [String: Int] = [:]` (after `manifestFingerprint`), and:

```swift
    /// Semantic hash of one provider's own rate rows. Weekly-quota calibration is
    /// keyed by this, never by the global `revision`.
    func rateRevision(forProvider provider: String) -> Int {
        providerRevisions[provider] ?? 0
    }
```

In `RunwayPriceTable.snapshot()` pass `providerRevisions: providerRevisions`, and add:

```swift
    func rateRevision(forProvider provider: String) -> Int {
        snapshot().rateRevision(forProvider: provider)
    }
```

- [ ] **Step 4: Wire calibration**

In `WeeklyQuotaCalibration.swift` change the closure type at lines 774, 801, and 812 from `(@Sendable () -> Int)` to `(@Sendable (String) -> Int)`, the default at 791 to `{ RunwayPriceTable.shared.rateRevision(forProvider: $0) }`, and the call at 1599 to `priceRevisionProvider(provider)`.

In `CodexStatusService.swift:695` and `ClaudeUsageModel.swift:660`, read the `priceRevision:` argument of each `WeeklyQuotaCalibrationScope(` call. Where it passes `RunwayPriceTable.shared.revision` (or a value derived from it), pass `RunwayPriceTable.shared.rateRevision(forProvider: "codex")` and `"claude"` respectively.

Run: `grep -rn "\.revision\b" AgentSessions/CodexStatus AgentSessions/ClaudeStatus | grep -v "priceTableRevision\|snapshot.revision"`
Every remaining hit that feeds a calibration or bootstrap scope gets the same change. Hits that feed telemetry cache identity keep the global revision.

**Bootstrap scans stamp from one snapshot.** In `WeeklyQuotaBootstrap.swift`:

- Codex scan: it already captures `let priceSnapshot = priceTable.snapshot()` (~line 190). Change the stamp at ~line 321 from `priceSnapshot.revision` to `priceSnapshot.rateRevision(forProvider: "codex")`.
- Claude scan: it prices through the mutable table (`priceTable.price(forModel:)`, ~line 626) and stamps `priceTable.revision` afterwards (~line 668). Capture `let priceSnapshot = priceTable.snapshot()` once at the start of the scan, price with `priceSnapshot.price(forModel:)`, and stamp `priceSnapshot.rateRevision(forProvider: "claude")`.

**Test fixtures.** Change every test that stamps or compares a calibration or bootstrap price revision. Find them with:

```bash
grep -rn "priceRevision\s*[:=]\|priceRevisionProvider\|\.revision }" \
  AgentSessionsTests/WeeklyQuotaCalibrationTests.swift \
  AgentSessionsTests/WeeklyQuotaBootstrapTests.swift \
  AgentSessionsTests/SessionTelemetryEngineTests.swift
```

- `{ prices.revision }` closures (for example ~lines 2209 and 2267) become `{ prices.rateRevision(forProvider: $0) }`.
- A stamped `RunwayPriceTable.shared.revision` (for example `testALimitShapeChangeDropsAnInMemoryBootstrap`, ~line 2292) becomes `RunwayPriceTable.shared.rateRevision(forProvider: "codex")`, or `"claude"` when the test's provider is Claude.
- Leave a global revision in place only where the test deliberately represents the legacy formula; add a comment saying so.
- Fixed integers such as `scope(priceRevision: 1)` that never meet the real table stay as they are.

- [ ] **Step 5: Run**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/PriceManifestV2Tests -only-testing:AgentSessionsTests/WeeklyQuotaCalibrationTests -only-testing:AgentSessionsTests/WeeklyQuotaBootstrapTests 2>&1 | tail -12`
Expected: all pass.

- [ ] **Step 6: Commit (when the owner approves)**

Message: `fix(usage): key weekly calibration by the provider's own price rows`
Why trailer: adding another vendor's price row must not discard Claude or Codex calibration; this change resets calibration once.

---

### Task 5: Calculator evidence rules

**Files:**
- Modify: `AgentSessions/Model/SessionTelemetry.swift` (`TelemetryUsageSummary` ~302–336, `TelemetryCostEstimate` ~349–396, `parserVersion` 461)
- Modify: `AgentSessions/Model/SessionSourceDescriptor.swift` (`TelemetryCapabilities` ~217–236)
- Modify: `AgentSessions/Telemetry/TelemetryCostCalculator.swift`
- Modify: `AgentSessions/Telemetry/SessionTelemetryEngine.swift:584-597`
- Test: `AgentSessionsTests/TelemetryCostCalculatorTests.swift`

**Interfaces:**
- Consumes: `RunwayPriceSnapshot.resolvedPrice(forModel:)`.
- Produces:
  - `TelemetryUsageSummary.costUnavailableReason: String?` (init parameter, default nil).
  - `TelemetryCostEstimate.freeRouteModels: [String]` (init parameter, default `[]`).
  - `TelemetryCapabilities.cacheWriteTTLVerified: Bool` (default `true`).
  - `TelemetryCostCalculator.price(events:fallbackSlices:snapshot:cacheWriteTTLVerified:)` and `estimate(slices:priceTable:cacheWriteTTLVerified:)`, both with default `true`.
  - `SessionTelemetry.parserVersion == 15`.

- [ ] **Step 1: Write the failing tests** (append to `TelemetryCostCalculatorTests`)

```swift
    // MARK: - Resolved keys and free routes

    private func v2Snapshot() -> RunwayPriceSnapshot {
        let t = RunwayPriceTable.makeEmptyForTesting()
        let json = #"""
        {"version":2,"sequence":1,"updated":"2026-10-13","aliases":{},
         "models":{
          "minimax-m2.5":{"inputPerMTok":1,"cachedInputPerMTok":0.1,"outputPerMTok":4},
          "claude-sonnet-5":{"inputPerMTok":2,"cachedInputPerMTok":0.2,"outputPerMTok":10,"cacheWritePerMTok":2.5,"cacheWrite1hPerMTok":4},
          "gpt-5":{"inputPerMTok":1.25,"cachedInputPerMTok":0.125,"outputPerMTok":10,"cacheWritePerMTok":null}}}
        """#
        XCTAssertTrue(t.loadForTesting(json: Data(json.utf8)))
        return t.snapshot()
    }

    func testFreeRouteIsPricedAtTheBaseRateAndReported() throws {
        let result = TelemetryCostCalculator.price(
            events: [event("minimax-m2.5-free", input: oneMillion, context: nil, output: oneMillion)],
            fallbackSlices: [], snapshot: v2Snapshot())
        XCTAssertEqual(try XCTUnwrap(result.estimate.apiEquivalentUSD), 5.0, accuracy: 0.0001)
        XCTAssertEqual(result.estimate.freeRouteModels, ["minimax-m2.5-free"])
    }

    func testOneStealthModelMakesTheWholeSessionUnpriced() {
        let result = TelemetryCostCalculator.price(
            events: [event("minimax-m2.5", input: oneMillion, context: nil),
                     event("big-pickle", input: oneMillion, context: nil)],
            fallbackSlices: [], snapshot: v2Snapshot())
        XCTAssertNil(result.estimate.apiEquivalentUSD)
        XCTAssertEqual(result.estimate.unpricedModels, ["big-pickle"], "the raw slug is reported")
    }

    func testProviderPrefixedClaudeModelPrices() throws {
        let result = TelemetryCostCalculator.price(
            events: [event("anthropic/claude-sonnet-5", input: oneMillion, context: nil)],
            fallbackSlices: [], snapshot: v2Snapshot())
        XCTAssertEqual(try XCTUnwrap(result.estimate.apiEquivalentUSD), 2.0, accuracy: 0.0001)
        XCTAssertTrue(result.estimate.freeRouteModels.isEmpty)
    }

    // MARK: - Cache-write TTL evidence

    func testUnverifiedTTLRefusesAModelThatPricesTheTwoWritesDifferently() {
        let result = TelemetryCostCalculator.price(
            events: [event("claude-sonnet-5", input: 10, context: nil, cacheWrite5m: 1_000)],
            fallbackSlices: [], snapshot: v2Snapshot(), cacheWriteTTLVerified: false)
        XCTAssertNil(result.estimate.apiEquivalentUSD)
        XCTAssertEqual(result.estimate.missingPriceComponents, ["claude-sonnet-5:cacheWriteTTL"])
    }

    func testUnverifiedTTLDoesNotBlockEventsWithoutCacheWrites() throws {
        let result = TelemetryCostCalculator.price(
            events: [event("claude-sonnet-5", input: oneMillion, context: nil)],
            fallbackSlices: [], snapshot: v2Snapshot(), cacheWriteTTLVerified: false)
        XCTAssertEqual(try XCTUnwrap(result.estimate.apiEquivalentUSD), 2.0, accuracy: 0.0001)
    }

    func testVerifiedTTLStillPricesCacheWrites() throws {
        let result = TelemetryCostCalculator.price(
            events: [event("claude-sonnet-5", input: 0, context: nil, cacheWrite5m: oneMillion)],
            fallbackSlices: [], snapshot: v2Snapshot(), cacheWriteTTLVerified: true)
        XCTAssertEqual(try XCTUnwrap(result.estimate.apiEquivalentUSD), 2.5, accuracy: 0.0001)
    }

    // MARK: - Stored results from the previous build

    func testCostEstimateWithoutFreeRouteFieldStillDecodes() throws {
        let old = #"{"unpricedModels":[],"missingPriceComponents":[],"priceTableUpdated":"2026-10-11"}"#
        let decoded = try JSONDecoder().decode(TelemetryCostEstimate.self, from: Data(old.utf8))
        XCTAssertEqual(decoded.freeRouteModels, [])
    }

    func testUsageSummaryWithoutCostReasonStillDecodes() throws {
        let old = #"{"topLineTokens":1,"hasComponentBreakdown":true,"usageFamilies":[],"usageFamilyConflict":false}"#
        let decoded = try JSONDecoder().decode(TelemetryUsageSummary.self, from: Data(old.utf8))
        XCTAssertNil(decoded.costUnavailableReason)
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/TelemetryCostCalculatorTests 2>&1 | tail -15`
Expected: build failure on `freeRouteModels`, `cacheWriteTTLVerified`, `costUnavailableReason`.

- [ ] **Step 3: Model changes**

`TelemetryUsageSummary`: add after `unavailableReason`:

```swift
    /// Non-nil when the token totals are sound but the evidence cannot support a
    /// dollar figure — for example a whole-session summary that cannot be
    /// attributed to one model or one request. Tokens still display.
    public let costUnavailableReason: String?
```

Add `costUnavailableReason: String? = nil` as the last init parameter and assign it. The synthesized `Decodable` uses `decodeIfPresent` for optionals, so older stored summaries decode.

`TelemetryCostEstimate`: add the property, init parameter, coding key, and decode line:

```swift
    /// Raw model slugs that were priced at the base model's list rate because the
    /// session ran on a free or promotional route.
    public let freeRouteModels: [String]
```

```swift
                freeRouteModels: [String] = [],
```

```swift
        case apiEquivalentUSD, unpricedModels, missingPriceComponents, freeRouteModels
```

```swift
        freeRouteModels = try values.decodeIfPresent([String].self, forKey: .freeRouteModels) ?? []
```

`SessionTelemetry.parserVersion`: `14` → `15`.

`TelemetryCapabilities`: add

```swift
    /// True when this source's cache-write tokens are known to be 5-minute writes
    /// (or the source splits 5m/1h itself). When false, a model that prices the two
    /// writes differently cannot be priced from this source's cache-write tokens.
    var cacheWriteTTLVerified: Bool = true
```

Because it is a `var` with a default, the memberwise init gains an optional trailing parameter and every existing call site keeps compiling.

- [ ] **Step 4: Calculator**

Add `cacheWriteTTLVerified: Bool = true` to the three `price(events:…)`/`estimate(slices:…)` entry points and thread it to the private `price(event:…)` and the slice loop. Collect free routes in both paths.

In `price(events:fallbackSlices:snapshot:cacheWriteTTLVerified:)` add `var freeRouteModels: [String] = []`, pass `&eventFreeRoute` to the per-event function, append once for session-owned events, and pass `freeRouteModels:` to the `TelemetryCostEstimate` init.

Replace the per-event function:

```swift
    private static func price(event: TelemetryUsageEvent,
                              snapshot: RunwayPriceSnapshot,
                              cacheWriteTTLVerified: Bool,
                              unpricedModels: inout [String],
                              missingComponents: inout [String],
                              freeRouteModels: inout [String]) -> Double? {
        guard event.topLineTokens > 0 else { return 0 }
        let slug = event.model ?? "(unknown)"
        guard let resolved = snapshot.resolvedPrice(forModel: event.model) else {
            appendOnce(slug, to: &unpricedModels)
            return nil
        }
        let price = resolved.price
        guard let tier = RunwaySpeedTier(rawValue: event.speed) else {
            appendOnce("\(slug):\(event.speed)", to: &missingComponents)
            return nil
        }
        if price.longContext != nil, event.contextInputTokens == nil {
            appendOnce("\(slug):contextInputTokens", to: &missingComponents)
            return nil
        }
        guard let rates = price.rates(for: tier,
                                      contextInputTokens: event.contextInputTokens.map(Double.init),
                                      inferenceGeo: event.inferenceGeo) else {
            appendOnce("\(slug):\(event.inferenceGeo.map { "inferenceGeo:\($0)" } ?? tier.rawValue)", to: &missingComponents)
            return nil
        }
        let writes = event.cacheWrite5mTokens + event.cacheWrite1hTokens
        // TTL is required evidence when the row prices the two writes differently.
        if !cacheWriteTTLVerified, writes > 0,
           let write5m = rates.cacheWritePerMTok, let write1h = rates.cacheWrite1hPerMTok,
           write5m != write1h {
            appendOnce("\(slug):cacheWriteTTL", to: &missingComponents)
            return nil
        }
        if event.cacheWrite5mTokens > 0, rates.cacheWritePerMTok == nil {
            appendOnce("\(slug):cacheWrite5m", to: &missingComponents)
            return nil
        }
        if event.cacheWrite1hTokens > 0, rates.cacheWrite1hPerMTok == nil {
            appendOnce("\(slug):cacheWrite1h", to: &missingComponents)
            return nil
        }
        if resolved.viaFreeRoute { appendOnce(slug, to: &freeRouteModels) }
        return rates.dollars(input: Double(event.freshInputTokens),
                             cachedInput: Double(event.cacheReadTokens),
                             output: Double(event.outputTokens),
                             cacheWrite5m: Double(event.cacheWrite5mTokens),
                             cacheWrite1h: Double(event.cacheWrite1hTokens))
    }
```

Apply the same three changes to the slice path: `snapshot.resolvedPrice(forModel: slice.model)`, the TTL check before the 5m/1h checks, and `freeRouteModels`.

- [ ] **Step 5: Engine gate**

In `SessionTelemetryEngine.swift` at the pricing gate (~584), add the new condition and pass the flag:

```swift
        guard capabilities.cost.isAvailable,
              base.usageSummary?.unavailableReason == nil,
              base.usageSummary?.costUnavailableReason == nil,
              base.usageSummary?.hasComponentBreakdown == true else {
```

```swift
        let priced = TelemetryCostCalculator.price(events: base.usageEvents,
                                                   fallbackSlices: base.usageSlices,
                                                   snapshot: priceSnapshot,
                                                   cacheWriteTTLVerified: capabilities.cacheWriteTTLVerified)
```

- [ ] **Step 6: Run**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/TelemetryCostCalculatorTests -only-testing:AgentSessionsTests/SessionTelemetryEngineTests 2>&1 | tail -12`
Expected: all pass. A `SessionTelemetryEngineTests` case that pins `parserVersion == 14` is updated to 15.

- [ ] **Step 7: Commit (when the owner approves)**

Message: `feat(telemetry): price resolved model keys and require cache-write TTL evidence`

---

### Task 6: Session Info presentation

**Files:**
- Modify: `AgentSessions/Views/TranscriptTelemetryView.swift:199-226` (`costValue`)
- Test: `AgentSessionsTests/TranscriptTelemetryPresentationTests.swift`

**Interfaces:**
- Consumes: `freeRouteModels`, `costUnavailableReason`.
- Produces: `TranscriptTelemetryPresentation.unpricedReason(forModel:) -> String` (internal static).

- [ ] **Step 1: Write the failing tests**

Reuse the file's existing helper that builds a `SessionTelemetry` (read the top of the file for its name). The assertions:

```swift
    func testFreeRouteAddsTheListPriceNote() {
        let estimate = TelemetryCostEstimate(apiEquivalentUSD: 1.5, unpricedModels: [],
                                             missingPriceComponents: [], priceTableUpdated: "2026-10-13",
                                             freeRouteModels: ["minimax-m2.5-free"])
        let value = TranscriptTelemetryPresentation.costValue(telemetry(cost: estimate),
                                                              locale: Locale(identifier: "en_US"))
        XCTAssertEqual(value.text, "$1.50")
        XCTAssertTrue(value.help.contains("List price. This session ran on a free route."))
    }

    func testUnpricedReasonsAreSpecific() {
        XCTAssertEqual(TranscriptTelemetryPresentation.unpricedReason(forModel: "qwen3.5-9b"),
                       "No published price for local model: qwen3.5-9b")
        XCTAssertEqual(TranscriptTelemetryPresentation.unpricedReason(forModel: "big-pickle"),
                       "No published price for unreleased model: big-pickle")
        XCTAssertEqual(TranscriptTelemetryPresentation.unpricedReason(forModel: "acme-9"),
                       "No price entry for: acme-9")
    }

    func testCostUnavailableReasonIsShown() {
        let summary = TelemetryUsageSummary(topLineTokens: 10, hasComponentBreakdown: true,
                                            recordedTotalTokens: nil, usageFamilies: ["usage.record.session"],
                                            usageFamilyConflict: false,
                                            costUnavailableReason: "Kimi recorded only a whole-session summary.")
        let value = TranscriptTelemetryPresentation.costValue(telemetry(summary: summary),
                                                              locale: Locale(identifier: "en_US"))
        XCTAssertEqual(value.text, "—")
        XCTAssertTrue(value.help.contains("Kimi recorded only a whole-session summary."))
    }
```

If the file has no `telemetry(cost:)`/`telemetry(summary:)` helpers, add private ones that call the full `SessionTelemetry` init with nil configurations, empty slices and events, and `parserVersion: SessionTelemetry.parserVersion`.

- [ ] **Step 2: Run to verify failure**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/TranscriptTelemetryPresentationTests 2>&1 | tail -15`
Expected: build failure on `unpricedReason(forModel:)`.

- [ ] **Step 3: Implement**

In `costValue`, after the `unavailableReason` branch add:

```swift
        if let reason = telemetry.usageSummary?.costUnavailableReason {
            return .absent(localized("Pricing unavailable: \(reason)", locale: locale))
        }
```

In the dollars branch, build the help text from two parts:

```swift
            var help = localized(
                "Estimated API price at published rates: \(dollars.formatted(.number.precision(.fractionLength(4)).locale(locale))) USD. Reference value, not a subscription charge.",
                locale: locale)
            if telemetry.costEstimate?.freeRouteModels.isEmpty == false {
                help += " " + localized("List price. This session ran on a free route.", locale: locale)
            }
            return Value(text: text, help: help)
```

Replace the final reasons block:

```swift
        let unpriced = (telemetry.costEstimate?.unpricedModels ?? []).map(unpricedReason(forModel:))
        let missing = telemetry.costEstimate?.missingPriceComponents ?? []
        if unpriced.isEmpty && missing.isEmpty {
            return .absent(localized("No priceable usage was recorded in this transcript.", locale: locale))
        }
        let parts = unpriced + (missing.isEmpty ? [] : ["No price entry for: \(missing.joined(separator: ", "))"])
        return .absent(parts.joined(separator: ". "))
```

Add the classifier:

```swift
    /// Local models carry a parameter-count tag (`qwen3.5-9b`); unreleased models
    /// are known code names. Everything else is simply a missing row.
    static func unpricedReason(forModel slug: String) -> String {
        let lower = slug.lowercased()
        let unreleased: Set<String> = ["big-pickle", "x-preview-f", "x-preview-f-free",
                                       "gateway-injected", "coder-model"]
        if unreleased.contains(lower) { return "No published price for unreleased model: \(slug)" }
        if lower.range(of: #"-\d+(\.\d+)?b$"#, options: .regularExpression) != nil {
            return "No published price for local model: \(slug)"
        }
        return "No price entry for: \(slug)"
    }
```

- [ ] **Step 4: Run**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/TranscriptTelemetryPresentationTests 2>&1 | tail -8`
Expected: all pass.

- [ ] **Step 5: Commit (when the owner approves)**

Message: `feat(session-info): explain free-route prices and unpriced models`

---

### Task 7: Hermes rollups carry no request context

**Files:**
- Modify: `AgentSessions/Hermes/HermesTelemetryReader.swift:321-323`
- Test: `AgentSessionsTests/SessionParserTests.swift` (next to `testHermesTelemetryReadsModelUsageWithoutTitleGenerationDoubleCount`, line ~10584)

- [ ] **Step 1: Write the failing test**

```swift
    /// `session_model_usage` sums several requests into one row. Two 150K requests
    /// must never be billed as one 300K long-context request.
    func testHermesRollupNeverSelectsALongContextTier() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentSessions-Hermes-LongCtx-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let dbURL = root.appendingPathComponent("state.db")
        try createHermesStateDBFixture(at: dbURL)
        let session = try XCTUnwrap(HermesStateDBReader.listSessions(dbURL: dbURL).first)
        let telemetry = try XCTUnwrap(HermesTelemetryReader.loadTelemetry(for: session)).result.telemetry

        XCTAssertFalse(telemetry.usageEvents.isEmpty)
        XCTAssertTrue(telemetry.usageEvents.allSatisfy { $0.contextInputTokens == nil },
                      "a rollup is not one request and must not claim a context size")

        // The same usage attributed to a long-context model must be refused.
        let asGPT54 = telemetry.usageEvents.map {
            TelemetryUsageEvent(recordID: $0.recordID, observedAt: $0.observedAt, anchorLine: $0.anchorLine,
                                usageFamily: $0.usageFamily, ownership: $0.ownership, model: "gpt-5.4",
                                reasoningEffort: nil, speed: $0.speed,
                                freshInputTokens: 300_000, cacheReadTokens: 0,
                                cacheWrite5mTokens: 0, cacheWrite1hTokens: 0,
                                outputTokens: 1_000, contextInputTokens: $0.contextInputTokens)
        }
        let result = TelemetryCostCalculator.price(events: asGPT54, fallbackSlices: [],
                                                   snapshot: RunwayPriceTable.makeForTesting().snapshot())
        XCTAssertNil(result.estimate.apiEquivalentUSD)
        XCTAssertEqual(result.estimate.missingPriceComponents, ["gpt-5.4:contextInputTokens"])
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/SessionParserTests/testHermesRollupNeverSelectsALongContextTier 2>&1 | tail -10`
Expected: FAIL on `contextInputTokens == nil`.

- [ ] **Step 3: Implement**

In `HermesTelemetryReader.swift`, in the event built from a usage row (~line 321), replace the `contextInputTokens:` argument:

```swift
            // A `session_model_usage` row is a per-model rollup of many requests, so
            // it has no request-level context size. nil makes the calculator refuse
            // any model with a long-context tier instead of billing short requests
            // at the long rate.
            contextInputTokens: nil))
```

Run: `grep -n "contextInputTokens" AgentSessions/Hermes/HermesTelemetryReader.swift`
Every other hit that builds an event from an aggregate row gets the same `nil`.

- [ ] **Step 4: Check the auxiliary-task ownership question**

Read the Hermes schema comment at the top of `HermesTelemetryReader.swift` and the test `testHermesTelemetryKeepsAuxiliaryUsageSeparateFromSessionAggregate`. If the source or its fixtures show that an auxiliary `task` row (`vision`, `title`) is work delegated to a separately listed session, report it to the owner before Task 12 flips the Hermes descriptor. If nothing indicates that, keep `.session` ownership and record "auxiliary tasks are parent-owned per `session_model_usage` schema" in the descriptor comment in Task 12.

- [ ] **Step 5: Run**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/SessionParserTests 2>&1 | tail -8`
Expected: all pass. An existing assertion on a non-nil Hermes `contextInputTokens` is updated to nil.

- [ ] **Step 6: Commit (when the owner approves)**

Message: `fix(hermes): stop claiming a request context size for usage rollups`

---

### Task 8: OpenCode prices from row evidence only

**Files:**
- Modify: `AgentSessions/OpenCode/OpenCodeSqliteReader.swift:461-485`
- Test: `AgentSessionsTests/SessionTelemetryEngineTests.swift` (next to `testOpenCodeTelemetryCacheKeyIncludesSessionIdentityForSharedDatabase`, line ~321)

- [ ] **Step 1: Write the failing test**

Read `testOpenCodeTelemetryCacheKeyIncludesSessionIdentityForSharedDatabase` and reuse its database fixture helper. Build a session whose metadata model is `model-b`, with two assistant usage rows: the first has no model, the second has model `model-b`. Assert:

```swift
        let scan = try XCTUnwrap(OpenCodeSqliteReader.loadTelemetry(for: session))
        let events = scan.result.telemetry.usageEvents
        XCTAssertEqual(events.count, 2)
        XCTAssertNil(events[0].model,
                     "session metadata is the current model; it must not be stamped on an older row")
        XCTAssertEqual(events[1].model, "model-b")
        // Configuration display still falls back to metadata.
        XCTAssertEqual(scan.result.telemetry.currentConfiguration?.model, "model-b")
```

If the fixture helper cannot write a row without a model, extend it with an optional `model: String?` parameter defaulting to its current value.

- [ ] **Step 2: Run to verify failure**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/SessionTelemetryEngineTests 2>&1 | tail -10`
Expected: FAIL, `events[0].model` is `"model-b"`.

- [ ] **Step 3: Implement**

At `OpenCodeSqliteReader.swift:461` replace `let model = row.model ?? metadataModel` with:

```swift
            // Price-bearing evidence: only the row's own model. Session metadata holds
            // the *current* model, so borrowing it would price an older request at a
            // later model's rate. A nil model makes the calculator refuse the figure.
            let model = row.model
```

The slice key a few lines below uses the same `model`; it becomes nil for such rows as well, which is correct.

- [ ] **Step 4: Run**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/SessionTelemetryEngineTests 2>&1 | tail -8`
Expected: all pass.

- [ ] **Step 5: Commit (when the owner approves)**

Message: `fix(opencode): never price a usage row at the session's current model`

---

### Task 9: Kimi prices from turn records only

**Files:**
- Modify: `AgentSessions/Telemetry/KimiTelemetryAccumulator.swift:152-175` (`finish`)
- Test: `AgentSessionsTests/ExpandedTelemetryProviderTests.swift` (next to `testKimiFallsBackToValidSessionSummaryWhenTurnRowIsMalformed`, line ~1557)

- [ ] **Step 1: Write the failing tests**

```swift
    func testKimiSessionSummaryFallbackShowsTokensButRefusesCost() {
        let lines = [
            #"{"type":"llm.request","model":"kimi-k2.7-code","thinkingEffort":"on","time":1785615365000}"#,
            #"{"type":"usage.record","model":"kimi-k2.7-code","usageScope":"session","usage":{"inputOther":100,"inputCacheRead":200,"inputCacheCreation":0,"output":300},"time":1785615366000}"#
        ]
        let telemetry = KimiTelemetryAccumulator.accumulate(lines: lines)
        XCTAssertEqual(telemetry.usageSummary?.usageFamilies, ["usage.record.session"])
        XCTAssertEqual(telemetry.usageSummary?.topLineTokens, 600)
        XCTAssertNil(telemetry.usageSummary?.unavailableReason, "tokens are still valid")
        XCTAssertEqual(telemetry.usageSummary?.costUnavailableReason,
                       "Kimi recorded only a whole-session usage summary, which cannot be attributed to one model or request.")
    }

    func testKimiTurnRecordsCarryNoCostReason() {
        let lines = [
            #"{"type":"llm.request","model":"kimi-k2.7-code","thinkingEffort":"on","time":1785615365000}"#,
            #"{"type":"usage.record","model":"kimi-k2.7-code","usageScope":"turn","usage":{"inputOther":2,"inputCacheRead":3,"inputCacheCreation":0,"output":5},"time":1785615367000}"#
        ]
        let telemetry = KimiTelemetryAccumulator.accumulate(lines: lines)
        XCTAssertNil(telemetry.usageSummary?.costUnavailableReason)
        XCTAssertEqual(telemetry.usageEvents.first?.model, "kimi-k2.7-code")
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/ExpandedTelemetryProviderTests 2>&1 | tail -10`
Expected: FAIL, `costUnavailableReason` is nil.

- [ ] **Step 3: Implement**

In `finish()`, add the argument to the `TelemetryUsageSummary` init, after `unavailableReason:`:

```swift
                costUnavailableReason: (!useTurns && hasUsage && !invalidSelectedFamily)
                    ? "Kimi recorded only a whole-session usage summary, which cannot be attributed to one model or request."
                    : nil)
```

- [ ] **Step 4: Run**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/ExpandedTelemetryProviderTests 2>&1 | tail -8`
Expected: all pass.

- [ ] **Step 5: Commit (when the owner approves)**

Message: `fix(kimi): refuse a cost for whole-session usage summaries`

---

### Task 10: Antigravity model capture, per-event model, index repair

**Files:**
- Modify: `AgentSessions/Services/AntigravityTranscriptParser.swift:49-53,141-152`
- Modify: `AgentSessions/Telemetry/AntigravityTelemetryAccumulator.swift:25-71`
- Modify: `AgentSessions/Services/AntigravitySessionIndexer.swift:396-405`
- Test: `AgentSessionsTests/AntigravityTranscriptParserTests.swift`, `AgentSessionsTests/ExpandedTelemetryProviderTests.swift`

**Interfaces:**
- Produces: `AntigravityTranscriptParser.modelName(fromUserInput:)` (same name, corrected); `AntigravitySessionIndexer.parserGeneration: Int` and UserDefaults key `"AntigravityIndexParserGeneration"`.

- [ ] **Step 1: Write the failing parser tests** (append to `AntigravityTranscriptParserTests`)

```swift
    func testModelNameStopsAtTheEndOfTheSentence() {
        let content = "<USER_SETTINGS_CHANGE>\nThe user changed setting `Model Selection` from None to Gemini 3.5 Flash (Medium). No need to comment on this change if the user doesn't ask about it. If reporting what model you are, please use a human readable name instead of the exact string\n</USER_SETTINGS_CHANGE>"
        XCTAssertEqual(AntigravityTranscriptParser.modelName(fromUserInput: content),
                       "Gemini 3.5 Flash (Medium)")
    }

    func testModelNameKeepsVersionDotsAndHandlesClosingTag() {
        XCTAssertEqual(AntigravityTranscriptParser.modelName(
            fromUserInput: "`Model Selection` from Gemini 3.5 Flash (Low) to Claude Sonnet 4.6 (Thinking).\n</USER_SETTINGS_CHANGE>"),
                       "Claude Sonnet 4.6 (Thinking)")
        XCTAssertEqual(AntigravityTranscriptParser.modelName(
            fromUserInput: "`Model Selection` from None to Gemini 3.7 Flash (High)</USER_SETTINGS_CHANGE>"),
                       "Gemini 3.7 Flash (High)")
        XCTAssertNil(AntigravityTranscriptParser.modelName(fromUserInput: "<USER_REQUEST>hi</USER_REQUEST>"))
    }
```

- [ ] **Step 2: Write the failing telemetry tests** (append to `ExpandedTelemetryProviderTests`)

```swift
    private func antigravityInput(_ step: Int, from old: String, to new: String) -> String {
        #"{"step_index":\#(step),"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-10-04T20:21:00Z","content":"<USER_REQUEST>\nGo.\n</USER_REQUEST>\n<USER_SETTINGS_CHANGE>\nThe user changed setting `Model Selection` from \#(old) to \#(new).\n</USER_SETTINGS_CHANGE>"}"#
    }

    private func antigravityPlanner(_ step: Int, input: Int) -> String {
        #"{"step_index":\#(step),"source":"MODEL","type":"PLANNER_RESPONSE","status":"OK","created_at":"2026-10-04T20:21:34Z","input_tokens":\#(input),"cache_read_tokens":0,"output_tokens":10}"#
    }

    func testAntigravityStampsEachPlannerEventWithTheModelInForce() {
        let telemetry = AntigravityTelemetryAccumulator.accumulate(lines: [
            antigravityPlanner(0, input: 1),
            antigravityInput(1, from: "None", to: "Gemini 3.5 Flash (Medium)"),
            antigravityPlanner(2, input: 100),
            antigravityInput(3, from: "Gemini 3.5 Flash (Medium)", to: "Claude Sonnet 4.6 (Thinking)"),
            antigravityPlanner(4, input: 200)
        ])
        XCTAssertEqual(telemetry.usageEvents.map(\.model),
                       [nil, "Gemini 3.5 Flash (Medium)", "Claude Sonnet 4.6 (Thinking)"])
        XCTAssertEqual(Set(telemetry.usageSlices.map(\.model)),
                       [nil, "Gemini 3.5 Flash (Medium)", "Claude Sonnet 4.6 (Thinking)"])
        XCTAssertEqual(telemetry.usageSummary?.topLineTokens, 331)
    }

    func testAntigravityUserInputWithoutASettingsChangeKeepsTheModel() {
        let plain = #"{"step_index":3,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-10-04T20:22:00Z","content":"<USER_REQUEST>\nMention PLANNER_RESPONSE and Model Selection in prose.\n</USER_REQUEST>"}"#
        let telemetry = AntigravityTelemetryAccumulator.accumulate(lines: [
            antigravityInput(1, from: "None", to: "Gemini 3.5 Flash (Medium)"),
            plain,
            antigravityPlanner(4, input: 5)
        ])
        XCTAssertEqual(telemetry.usageEvents.map(\.model), ["Gemini 3.5 Flash (Medium)"])
        XCTAssertNil(telemetry.usageSummary?.unavailableReason,
                     "a user message that names PLANNER_RESPONSE is not a malformed planner row")
    }
```

Update `testAntigravityBuildsPlannerTokenEventsWithoutInventingModel`: it stays valid (no selection record → nil models). Add `XCTAssertTrue(telemetry.usageEvents.allSatisfy { $0.model == nil })` to it.

- [ ] **Step 3: Run to verify failure**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/AntigravityTranscriptParserTests -only-testing:AgentSessionsTests/ExpandedTelemetryProviderTests 2>&1 | tail -15`
Expected: FAIL. The parser returns the full trailing sentence; the accumulator returns nil models.

- [ ] **Step 4: Fix the shared parser**

Replace `modelName(fromUserInput:)`:

```swift
    static func modelName(fromUserInput content: String) -> String? {
        // The selection is embedded in a USER_INPUT record's content as
        // "...`Model Selection` from <old> to <new>." followed by more prompt text.
        // Stop at the first period that ends a sentence (followed by whitespace, a
        // tag, or the end), so version dots such as "3.5" survive and the trailing
        // instructions are not stored as the model.
        guard let rx = try? NSRegularExpression(
            pattern: "Model Selection`?\\s+from\\s+.+?\\s+to\\s+(.+?)(?:\\.(?=\\s|<|$)|(?=<)|$)",
            options: [.dotMatchesLineSeparators]) else { return nil }
        let ns = content as NSString
        guard let m = rx.firstMatch(in: content, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1 else { return nil }
        let name = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
```

- [ ] **Step 5: `Session.model` is the current model**

In `AntigravityTranscriptParser.swift:51` replace `if model == nil { model = modelName(fromUserInput: content ?? "") }` with:

```swift
                // `Session.model` is the current (last selected) model, matching the
                // descriptor: "current model comes from loaded Session metadata".
                if let selected = modelName(fromUserInput: content ?? "") { model = selected }
```

Add a parser test in `AntigravityTranscriptParserTests` using the file's existing parse helper: a transcript with two selections ends with `session.model == "Claude Sonnet 4.6 (Thinking)"`.

- [ ] **Step 6: Accumulator tracks the model in file order**

In `AntigravityTelemetryAccumulator.swift` add `private var activeModel: String?` and replace the start of `consume`:

```swift
    mutating func consume(line: String, index: Int) {
        // Model selections arrive embedded in USER_INPUT content. Only such a line
        // that mentions the setting is decoded; any other non-planner line is skipped
        // without JSON work.
        if line.contains("\"USER_INPUT\""), line.contains("Model Selection"),
           let object = ClaudeRunwayLog.jsonObject(line),
           object["type"] as? String == "USER_INPUT",
           let selected = AntigravityTranscriptParser.modelName(
               fromUserInput: object["content"] as? String ?? "") {
            activeModel = selected
            return
        }
        guard line.contains("\"PLANNER_RESPONSE\"") else { return }
```

The existing guard was `line.contains("PLANNER_RESPONSE")`; the quoted form stops a user message that merely names the type from being treated as a malformed planner row. Keep the rest of the function, and replace both `model: nil` arguments (the `slices.addComponents` call and the `TelemetryUsageEvent` init) with `model: activeModel`.

Check `finish()`: if it derives `usageSlices` in a way that assumed a single nil-model slice, confirm `slices.ordered` returns one slice per model; `testAntigravityStampsEachPlannerEventWithTheModelInForce` proves it.

- [ ] **Step 7: One-time index repair**

In `AntigravitySessionIndexer.swift` add:

```swift
    /// Bump when `AntigravityTranscriptParser` changes what it stores in a session
    /// row. Hydrated rows are otherwise skipped while mtime and size are unchanged,
    /// so a parser fix would never reach them.
    static let parserGeneration = 2
    static let parserGenerationDefaultsKey = "AntigravityIndexParserGeneration"
```

**Why a forced reparse alone is not enough.** `reconcileHydratedSessions` returns corrected `Session` values in memory only. The hydrated path installs them in `allSessions` and never writes `session_meta`. `SearchIngestService` (~line 409) skips files whose mtime, size, and search data are current. So a forced reparse without a write gives: stale row → corrected in memory → generation marked done → stale row hydrated again on every later launch. The repair must write each reparsed row, and the generation advances only after every write succeeds.

**7a. `reconcileHydratedSessions` reports what it reparsed and whether it finished.**

Extend the result type and signature:

```swift
    internal struct HydratedReconciliation {
        var sessions: [Session]
        var confirmedMissingPaths: [String]
        /// Sessions re-parsed in this pass (changed files, plus every hydrated file
        /// when `forceReparse` is set).
        var reparsed: [Session] = []
        /// False when `shouldContinue` stopped the pass early.
        var completed: Bool = true
    }

    internal static func reconcileHydratedSessions(
        hydrated: [Session],
        snapshot: AntigravitySessionDiscovery.DiscoverySnapshot,
        parseNew: (URL) -> Session?,
        currentStat: (URL) -> SessionFileStat? = { fileStat(for: $0) },
        forceReparse: Bool = false,
        shouldContinue: () -> Bool = { true }
    ) -> HydratedReconciliation {
```

Inside: declare `var reparsed: [Session] = []` and `var completed = true`. At both `if !shouldContinue() { break }` / `guard shouldContinue() else { break }` sites in the file loop, set `completed = false` before the `break`. Change the skip condition to:

```swift
                if !forceReparse, cachedSecond == stat.mtime && cachedSize == stat.size { continue }
```

Where the loop takes `if let reparsed = parseNew(url) {`, rename that local to `fresh` and append it: `reparsed.append(fresh)`. When `forceReparse` is true, **every hydrated row the loop reaches must end up reparsed, or the pass is incomplete.** The two existing early `continue`s skip a hydrated row silently: `guard snapshot.isAuthoritative(path: cached.filePath) else { continue }` and `guard let stat = currentStat(url) else { continue }` (~lines 399–400). Under `forceReparse`, set `completed = false` before each of those `continue`s. A forced reparse that returns nil also sets `completed = false`. Otherwise a temporarily unreadable or non-authoritative session would keep its corrupted model while the generation advances, and it would never be retried. Return the two new fields.

**7b. A durable, testable repair step.**

```swift
    /// Writes every reparsed session row, then — only if the pass finished and every
    /// write succeeded — records the parser generation. Returns true when the
    /// generation was advanced. `upsertSessionMetaCore` updates the parser-owned
    /// columns and leaves analytics-owned fields alone.
    internal static func persistParserRepair(
        reparsed: [Session],
        completed: Bool,
        defaults: UserDefaults,
        shouldContinue: () -> Bool = { true },
        write: (SessionMetaRow) async throws -> Void
    ) async -> Bool {
        guard completed else { return false }
        for session in reparsed {
            guard shouldContinue() else { return false }
            do {
                try await write(SessionIndexer.sessionMetaRow(from: session))
            } catch {
                return false
            }
        }
        guard shouldContinue() else { return false }
        defaults.set(parserGeneration, forKey: parserGenerationDefaultsKey)
        return true
    }
```

**7c. Call site** (hydrated branch, ~line 205–245). Before the `reconcileHydratedSessions` call:

```swift
                let repairDefaults = self.parserRepairDefaultsOverride ?? UserDefaults.standard
                let needsRepair = repairDefaults.integer(forKey: Self.parserGenerationDefaultsKey)
                    < Self.parserGeneration
```

Pass `forceReparse: needsRepair`. After the existing confirmed-missing deletion block and before `hydratedReconciled = withArchives`:

```swift
                if needsRepair {
                    _ = await Self.persistParserRepair(
                        reparsed: reconciliation.reparsed,
                        completed: reconciliation.completed,
                        defaults: repairDefaults,
                        shouldContinue: shouldContinue,
                        write: { row in
                            if let override = self.persistSessionMetaOverride {
                                try await override(row)
                            } else {
                                try await IndexDB().upsertSessionMetaCore(row)
                            }
                        })
                }
```

Add the two test seams next to `deletePersistedPathsOverride` (line 43):

```swift
    internal var persistSessionMetaOverride: ((SessionMetaRow) async throws -> Void)? = nil
    internal var parserRepairDefaultsOverride: UserDefaults? = nil
```

A failed or cancelled repair leaves the generation unchanged, so the next refresh retries. The in-memory list is already correct for this launch either way.

**7d. Tests** — append to `AntigravityParserTests` (it already tests the indexer's reconciliation; if `grep -ln "reconcileHydratedSessions" AgentSessionsTests/*.swift` names a different file, use that one):

```swift
    private func scratchDefaults() -> UserDefaults {
        let name = "AntigravityRepair-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func antigravitySession(id: String, path: String, model: String?) -> Session {
        // Build with the same initializer `AntigravityTranscriptParser` uses
        // (AntigravityTranscriptParser.swift ~line 95): copy that call and set
        // id, source: .antigravity, filePath: path, and model.
    }

    /// The repair must reach the database, not only memory.
    func testParserRepairWritesTheCorrectedModelAndAdvancesTheGeneration() async throws {
        let (db, cleanup) = try makeTestIndexDB()
        defer { cleanup() }
        let stale = antigravitySession(
            id: "ag-1", path: "/tmp/ag-1/transcript.jsonl",
            model: "Gemini 3.5 Flash (Medium). No need to comment on this change if the user doesn't ask about it.")
        try await db.upsertSessionMetaCore(SessionIndexer.sessionMetaRow(from: stale))

        let fixed = antigravitySession(id: "ag-1", path: "/tmp/ag-1/transcript.jsonl",
                                       model: "Gemini 3.5 Flash (Medium)")
        let defaults = scratchDefaults()
        let advanced = await AntigravitySessionIndexer.persistParserRepair(
            reparsed: [fixed], completed: true, defaults: defaults,
            write: { try await db.upsertSessionMetaCore($0) })

        XCTAssertTrue(advanced)
        XCTAssertEqual(defaults.integer(forKey: AntigravitySessionIndexer.parserGenerationDefaultsKey),
                       AntigravitySessionIndexer.parserGeneration)
        // Read back through the repository the app hydrates from.
        let stored = try await SessionMetaRepository(db: db).fetchSessions(for: .antigravity)
        XCTAssertEqual(stored.first { $0.id == "ag-1" }?.model, "Gemini 3.5 Flash (Medium)")
    }

    func testParserRepairDoesNotAdvanceWhenAWriteFails() async {
        struct WriteFailed: Error {}
        let defaults = scratchDefaults()
        let fixed = antigravitySession(id: "ag-2", path: "/tmp/ag-2/transcript.jsonl", model: "X")
        let advanced = await AntigravitySessionIndexer.persistParserRepair(
            reparsed: [fixed], completed: true, defaults: defaults,
            write: { _ in throw WriteFailed() })
        XCTAssertFalse(advanced)
        XCTAssertEqual(defaults.integer(forKey: AntigravitySessionIndexer.parserGenerationDefaultsKey), 0)
    }

    func testParserRepairDoesNotAdvanceWhenThePassWasCancelledOrIncomplete() async {
        let defaults = scratchDefaults()
        let fixed = antigravitySession(id: "ag-3", path: "/tmp/ag-3/transcript.jsonl", model: "X")
        var writes = 0
        let incomplete = await AntigravitySessionIndexer.persistParserRepair(
            reparsed: [fixed], completed: false, defaults: defaults, write: { _ in writes += 1 })
        XCTAssertFalse(incomplete)
        XCTAssertEqual(writes, 0, "an incomplete pass writes nothing and is retried whole")

        let cancelled = await AntigravitySessionIndexer.persistParserRepair(
            reparsed: [fixed, fixed], completed: true, defaults: defaults,
            shouldContinue: { writes < 1 }, write: { _ in writes += 1 })
        XCTAssertFalse(cancelled)
        XCTAssertEqual(defaults.integer(forKey: AntigravitySessionIndexer.parserGenerationDefaultsKey), 0)
    }

    func testForcedReconcileReparsesUnchangedFilesAndReportsThem() throws {
        // Reuse the fixture setup of the existing reconcileHydratedSessions test in
        // this file: one hydrated session whose file stat equals the cached stat.
        // Call reconcileHydratedSessions twice with the same inputs:
        //   forceReparse: false → result.reparsed is empty (the skip applies)
        //   forceReparse: true  → result.reparsed.count == 1 and result.completed
        // Then once more with forceReparse: true and shouldContinue: { false }
        //   → result.completed == false
    }

    func testForcedReconcileIsIncompleteWhenAHydratedRowCannotBeRepaired() throws {
        // Same fixture, forceReparse: true, three variants:
        //   currentStat: { _ in nil }                 → result.completed == false
        //   a snapshot where isAuthoritative(path:) is false for the row
        //                                             → result.completed == false
        //   parseNew: { _ in nil }                    → result.completed == false
        // And in each case persistParserRepair(reparsed: result.reparsed,
        //   completed: result.completed, ...) returns false and leaves the
        //   generation at 0.
    }
```

The last test and the `antigravitySession` helper are written against helpers already in that file; read the existing reconciliation test first and copy its setup. Every assertion listed above is required. These tests must fail before 7a–7c: `persistParserRepair`, `reparsed`, and `completed` do not exist.

- [ ] **Step 8: Run**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/AntigravityTranscriptParserTests -only-testing:AgentSessionsTests/AntigravityParserTests -only-testing:AgentSessionsTests/ExpandedTelemetryProviderTests 2>&1 | tail -10`
Expected: all pass.

- [ ] **Step 9: Verify the repair on real data (owner's machine)**

Build with `xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug build` (default DerivedData, never the test path). The owner runs the app once. Then:

```bash
sqlite3 "file:$HOME/Library/Application Support/AgentSessions/index.db?mode=ro" \
  "SELECT model, COUNT(*) FROM session_meta WHERE source='antigravity' GROUP BY 1;"
```

Expected: no row contains "No need to comment". If rows still do, the reparse did not run; check that the defaults domain is `com.triada.AgentSessions`.

- [ ] **Step 10: Commit (when the owner approves)**

Message: `fix(antigravity): capture the selected model cleanly and stamp it on usage`

---

### Task 11: New price rows and aliases

**Files:**
- Modify: `docs/prices-v2.json`, `AgentSessions/CodexStatus/RunwayPriceTable.swift` (`bundledJSON`)
- Test: `AgentSessionsTests/PriceManifestV2Tests.swift`

This task is research plus data entry. It is the only task where values are not in this plan, because the spec forbids rates from memory.

- [ ] **Step 1: Read each vendor's own pricing page**

For each family below, open the vendor's first-party pricing page with `agent-browser read <url>` and record: input, cached-input (cache read), output, cache-write (or "not published"), any long-context threshold and multipliers. Record the page host and today's UTC date.

| Family | Models seen in the index | Vendor |
|---|---|---|
| Gemini Flash | 3.5, 3.6, 3.7, 3.8 | Google (`ai.google.dev` pricing) |
| GLM | `glm-4.7`, `glm-5.3-flash` | Zhipu / Z.ai |
| MiniMax | `minimax-m2.1`, `minimax-m2.5` | MiniMax |
| Kimi | `kimi-k2.7-code` | Moonshot |
| DeepSeek | `deepseek-flash`, `deepseek-v4.1-flash` | DeepSeek |
| Grok | `grok-4.6`, `grok-code` | xAI |
| Muse Spark | `muse-spark-1.3` | its vendor's own API pricing page |

A model is **skipped** (no row) when: the vendor has no public API price for it; the page does not state a cached-input price; or the page prices it in a unit other than tokens. List every skipped model, with the reason, in the PR notes and in the spec's Follow-up section.

Do not add `big-pickle`, `x-preview-f`, `gateway-injected`, `coder-model`, `qwen3.5-9b`, or any `laguna`/`solar`/`nemotron`/`trinity`/`mimo`/`ling`/`north` model unless its vendor publishes a token price; the same rule applies.

- [ ] **Step 2: Add the rows**

Row shape (USD per million tokens):

```json
"<key>": { "inputPerMTok": <n>, "cachedInputPerMTok": <n>, "outputPerMTok": <n>, "cacheWritePerMTok": <n or null> }
```

Add `"longContext": { "thresholdInputTokens": <n>, "inputMultiplier": <n>, "outputMultiplier": <n> }` only when the vendor publishes a threshold tier. Keys are the vendor's API model id, lowercased. Add the same rows, in the same order, to both `docs/prices-v2.json` and `bundledJSON`.

- [ ] **Step 3: Add aliases**

Add to `aliases` in both copies one entry per display name or non-API spelling that maps to an added row. Keys are lowercased and have the reasoning suffix already removed, for example `"gemini 3.5 flash": "<the gemini 3.5 flash key>"`, `"claude sonnet 4.6": "claude-sonnet-4-6"`. Add an alias only for a string that appears in the spec's Evidence section or in a test fixture.

- [ ] **Step 4: Raise `sequence` and extend `_note`**

Set `sequence` to today's `YYYYMMDD01` (or the next counter) in both copies. Append to `_note`, per vendor: `<Vendor> rates verified <UTC date> at <host>.`

- [ ] **Step 5: Add resolution tests for the real strings**

Append to `PriceManifestV2Tests`. Keep only the lines whose row was actually added in Step 2:

```swift
    func testEvidenceStringsResolveAgainstTheBundledTable() {
        let s = RunwayPriceTable.makeForTesting().snapshot()
        for raw in ["anthropic/claude-sonnet-5", "openai/gpt-5.5", "claude-haiku-4.5",
                    "Claude Sonnet 4.6 (Thinking)", "Gemini 3.5 Flash (Medium)",
                    "z-ai/glm-5.3-flash", "minimax-m2.5-free", "kimi-k2.7-code",
                    "cline-free/deepseek-v4.1-flash", "grok-4.6",
                    "muse-spark-1.3-contributor-free"] {
            XCTAssertNotNil(s.resolvedPrice(forModel: raw), raw)
        }
        for raw in ["big-pickle", "x-preview-f-free", "gateway-injected", "coder-model",
                    "qwen3.5-9b", "kimi-k2.7-code-v2"] {
            XCTAssertNil(s.resolvedPrice(forModel: raw), raw)
        }
    }
```

- [ ] **Step 6: Run**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/PriceManifestV2Tests 2>&1 | tail -10`
Expected: all pass, including `testServedV2ManifestEqualsTheBundledTable` and `testEveryAliasTargetExists`.

- [ ] **Step 7: Commit (when the owner approves)**

Message: `feat(prices): add first-party rates for Gemini, GLM, MiniMax, Kimi, DeepSeek and Grok models` (edit the list to match what was added)

---

### Task 12: Reader audit and descriptor flips

**Files:**
- Modify: `AgentSessions/OpenCode/OpenCodeSourceDescriptor.swift:16`, `AgentSessions/Model/OpenClawSourceDescriptor.swift:18`, `AgentSessions/Hermes/HermesSourceDescriptor.swift:16`, `AgentSessions/Kimi/KimiSourceDescriptor.swift:16`, `AgentSessions/Cline/ClineSourceDescriptor.swift:41`, `AgentSessions/Qwen/QwenSourceDescriptor.swift:35`, `AgentSessions/Model/AntigravitySourceDescriptor.swift:20`, `AgentSessions/DeepSeekHarness/DeepSeekHarnessSourceDescriptor.swift:16`
- Test: the telemetry test file of each agent; `AgentSessionsTests/SessionTelemetryEngineTests.swift`

- [ ] **Step 1: Audit each reader against the provenance table (spec §6)**

For OpenClaw, Cline, Qwen, and DeepSeek Harness (the four not changed in Tasks 7–10), read the code that builds `TelemetryUsageEvent` and answer in the PR notes, with file and line:

1. Does `model` come from the usage record or an earlier record in the same stream, and never from session metadata?
2. Does `contextInputTokens` describe one request? If an event is built from an aggregate, it must be nil.
3. Are fresh input and cache-read disjoint (cached tokens are not also counted in input)?
4. Does the format record a cache-write TTL?

Files: `AgentSessions/Telemetry/OpenClawTelemetryProvider.swift` (~258–390) and `AgentSessions/OpenClaw/OpenClawSqliteReader.swift` (~1020), `AgentSessions/Cline/ClineTelemetryReader.swift` (~100–155), `AgentSessions/Telemetry/QwenTelemetryReader.swift` (~280–330, ~730), `AgentSessions/Telemetry/DeepSeekHarnessTelemetryReader.swift` (~130–160, ~380–430).

A reader that fails question 1 or 2 is fixed in this task the same way as Task 8 (row model only) or Task 7 (`contextInputTokens: nil`), with a test in that agent's test file modeled on those tasks. A reader that fails question 3 does **not** get its descriptor flipped; report it to the owner.

- [ ] **Step 2: Write the failing engine test**

In `SessionTelemetryEngineTests`, next to an existing test that runs a real file through the engine for a registry provider (`testEngineUsesKimiRegistryProviderForARealFileRevision` in `ExpandedTelemetryProviderTests.swift:1666` shows the pattern), add **one engine-level priced test for each of the eight enabled agents**. Each test runs descriptor → reader → `SessionTelemetryEngine` → calculator and asserts a non-nil dollar figure. No agent is exempt; database-backed readers use a scratch database fixture.

| Agent | Reader path | Fixture | Model to use |
|---|---|---|---|
| Kimi | line provider | inline JSONL lines (template below) | a row added in Task 11 |
| Antigravity | line provider | inline JSONL: one `USER_INPUT` with a model selection, then one `PLANNER_RESPONSE` (helpers from Task 10 Step 2) | an aliased Gemini display name |
| OpenClaw | line provider and SQLite | the fixture of the existing OpenClaw telemetry test (`grep -n "OpenClawTelemetryProvider\|OpenClawSqliteReader.loadTelemetry" AgentSessionsTests/*.swift`) | `gpt-5.4-mini` (no long-context tier) |
| OpenCode | `scanTelemetry` (SQLite) | the scratch database helper used by `testOpenCodeTelemetryCacheKeyIncludesSessionIdentityForSharedDatabase`, with the model on the usage row itself | `gpt-5.4-mini` |
| Hermes | `scanTelemetry` (SQLite) | `createHermesStateDBFixture`, extended with an optional model parameter | `gpt-5.4-mini`. **Not** `gpt-5.4`: Hermes rollups carry no context size, so a long-context model is refused by design (Task 7 tests that refusal) |
| Cline | `scanTelemetry` (directory) | the fixture of the existing Cline telemetry test (`grep -n "ClineTelemetryReader.loadTelemetry" AgentSessionsTests/*.swift`) | `anthropic/claude-sonnet-5`, with **zero** cache-write tokens (TTL is unverified for Cline) |
| Qwen | `scanTelemetry` | the fixture of the existing Qwen telemetry test (`grep -n "QwenTelemetryReader.loadTelemetry" AgentSessionsTests/*.swift`) | a row that exists in the bundled table; not `coder-model` |
| DeepSeek Harness | `scanTelemetry` | the fixture of the existing DSH telemetry test (`grep -n "DeepSeekHarnessTelemetryReader.loadTelemetry" AgentSessionsTests/*.swift`) | a DeepSeek row added in Task 11, zero cache-write tokens |

Every one of the eight tests ends with the same three assertions:

```swift
        XCTAssertNotNil(telemetry.costEstimate?.apiEquivalentUSD, "priced end to end")
        XCTAssertEqual(telemetry.costEstimate?.unpricedModels, [])
        XCTAssertEqual(telemetry.costEstimate?.missingPriceComponents, [])
```

If Task 11 could not add a row for an agent's native model family, use a Claude or GPT model that the agent can legitimately record, and say so in the test comment. If an agent's fixture helper cannot set the model or zero the cache writes, extend the helper with an optional parameter that defaults to its current value.

All eight must fail before Step 4, because the descriptors still say `.unavailable`. Kimi is the template for the two line-provider agents:

```swift
    func testKimiTurnUsageIsPricedThroughTheEngine() async throws {
        let lines = [
            #"{"type":"llm.request","model":"kimi-k2.7-code","thinkingEffort":"on","time":1785615365000}"#,
            #"{"type":"usage.record","model":"kimi-k2.7-code","usageScope":"turn","usage":{"inputOther":1000000,"inputCacheRead":0,"inputCacheCreation":0,"output":0},"time":1785615367000}"#
        ]
        // Build the session and engine exactly as
        // testEngineUsesKimiRegistryProviderForARealFileRevision does, with these lines.
        let telemetry = try await priceThroughEngine(source: .kimi, lines: lines)
        XCTAssertNotNil(telemetry.costEstimate?.apiEquivalentUSD)
        XCTAssertEqual(telemetry.costEstimate?.unpricedModels, [])
    }
```

Extract the setup of `testEngineUsesKimiRegistryProviderForARealFileRevision` into a private helper `priceThroughEngine(source:lines:) async throws -> SessionTelemetry` in that test file and call it from the Kimi and Antigravity tests. For the six `scanTelemetry` agents add a second helper `priceThroughEngine(session:) async throws -> SessionTelemetry` that takes an already-built `Session` (from the agent's fixture) and calls the same engine entry point; the engine reaches the reader through `SessionSourceRegistry.descriptor(for:).scanTelemetry`, so the descriptor is on the tested path.

Also assert the capability for each flipped descriptor:

```swift
    func testEnabledAgentsDeclarePartialCostAndUnverifiedCacheWriteTTL() {
        for source in [SessionSource.opencode, .openclaw, .hermes, .kimi, .cline, .qwen,
                       .antigravity, .deepseekHarness] {
            let caps = SessionSourceRegistry.descriptor(for: source).telemetry
            XCTAssertTrue(caps.cost.isAvailable, "\(source)")
            if case .supported = caps.cost { XCTFail("\(source) must be .partial") }
        }
        for source in [SessionSource.opencode, .hermes, .kimi, .cline, .deepseekHarness] {
            XCTAssertFalse(SessionSourceRegistry.descriptor(for: source).telemetry.cacheWriteTTLVerified,
                           "\(source)")
        }
        for source in [SessionSource.claude, .codex, .pi, .copilot] {
            XCTAssertTrue(SessionSourceRegistry.descriptor(for: source).telemetry.cacheWriteTTLVerified)
        }
    }
```

- [ ] **Step 3: Run to verify failure**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/SessionTelemetryEngineTests -only-testing:AgentSessionsTests/ExpandedTelemetryProviderTests 2>&1 | tail -12`
Expected: FAIL; the descriptors still say `.unavailable`.

- [ ] **Step 4: Flip the descriptors**

In each descriptor replace the `cost:` line and, for the five generic cache-write readers, add the flag as the last `TelemetryCapabilities` argument.

```swift
// OpenCode
                cost: .partial("models without a published first-party price are not estimated; usage rows without their own model are not priced"),
                weeklyQuota: .unavailable("OpenCode does not expose a compatible account quota feed"),
                cacheWriteTTLVerified: false
// OpenClaw
                cost: .partial("models without a published first-party price are not estimated"),
// Hermes
                cost: .partial("models without a published first-party price are not estimated; per-model usage rollups cannot price models with a long-context tier"),
                weeklyQuota: .unavailable("Hermes does not expose a compatible account quota feed"),
                cacheWriteTTLVerified: false
// Kimi
                cost: .partial("models without a published first-party price are not estimated; whole-session usage summaries are not priced"),
                weeklyQuota: .unavailable("Kimi does not expose a compatible account quota feed"),
                cacheWriteTTLVerified: false
// Cline
                cost: .partial("models without a published first-party price are not estimated"),
                weeklyQuota: .unavailable("Cline does not expose a compatible account quota feed"),
                cacheWriteTTLVerified: false
// Qwen
                cost: .partial("models without a published first-party price are not estimated; the coder-model alias is opaque"),
// Antigravity
                cost: .partial("models without a published first-party price are not estimated; usage before the first recorded model selection is not priced"),
// DeepSeek Harness
                cost: .partial("models without a published first-party price are not estimated"),
                weeklyQuota: .unavailable("DeepSeek Harness does not expose a compatible account quota feed"),
                cacheWriteTTLVerified: false
```

If Step 1 found that OpenClaw or Qwen also store a generic cache-write count, add `cacheWriteTTLVerified: false` to it and to the test list. If Step 1 found upstream evidence that a source's writes are always 5-minute, leave its flag true and cite the evidence in a comment above the descriptor.

- [ ] **Step 5: Update tests that pinned the old verdicts**

Run: `grep -n "telemetry.cost" AgentSessionsTests/*.swift | grep "unavailable"`
For each hit on a flipped source (for example `SessionParserTests.swift` ~10611, the Hermes assertion), replace the expected value with the new `.partial(...)` string. Do not touch assertions for Droid, fx, Cursor, Devin, Grok, or Copilot.

- [ ] **Step 6: Run**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/SessionTelemetryEngineTests -only-testing:AgentSessionsTests/ExpandedTelemetryProviderTests -only-testing:AgentSessionsTests/SessionParserTests 2>&1 | tail -12`
Expected: all pass.

- [ ] **Step 7: Commit (when the owner approves)**

Message: `feat(session-info): show API-equivalent cost for eight more agents`

---

### Task 13: Full verification and docs

**Files:**
- Modify: `docs/CHANGELOG.md` (Unreleased section), `docs/summaries/2026-10.md`, `docs/adding-a-session-source.md`

- [ ] **Step 1: Full suite**

```bash
./scripts/xcode_test_stable.sh > .deriveddata-tests-final.log 2>&1; echo "exit=$?"
xcrun xcresulttool get test-results summary --path .deriveddata-tests/Logs/Test/Run-*.xcresult
```

Expected: exit 0, `failedTests: 0`. Delete the log file afterwards.

- [ ] **Step 1b: Prove the test-count delta with a name inventory**

```bash
find AgentSessionsTests -name '*.swift' -print0 | xargs -0 grep -ho "func test[A-Za-z0-9_]*" | sort > /tmp/as-tests-after.txt
comm -23 /tmp/as-tests-before.txt /tmp/as-tests-after.txt   # removed
comm -13 /tmp/as-tests-before.txt /tmp/as-tests-after.txt   # added
```

Expected: the "removed" list contains exactly one name, `testServedManifestMatchesTheBundledTable` (replaced in Task 3 Step 6 by the `PriceManifestV2Tests` guards). Any other removed name is a defect: restore it. `totalTestCount` from the result bundle must equal the Task 0 value, plus the number of added names, minus one. Paste both lists and both totals into the PR notes.

- [ ] **Step 2: Real-data check (read-only)**

After the owner runs the new build once:

```bash
sqlite3 "file:$HOME/Library/Application Support/AgentSessions/index.db?mode=ro" \
  "SELECT source, COUNT(*) FROM session_meta WHERE source IN ('opencode','openclaw','hermes','kimi','cline','qwen','antigravity','deepseek-harness') GROUP BY 1;"
```

The owner opens one session per agent in Session Info and confirms: an OpenClaw `gpt-5.4` session shows a dollar figure; a Hermes `gpt-5.4` session shows `—` with the context reason; an OpenCode `big-pickle` session shows `—` with "unreleased model"; an OpenCode `-free` session whose base row exists shows a figure with the free-route note. The implementer does not drive the app.

- [ ] **Step 3: Docs**

`docs/adding-a-session-source.md`: in the telemetry section add a short "Cost evidence" subsection that restates the four-row provenance table from spec §6 and the `cacheWriteTTLVerified` flag.

`docs/CHANGELOG.md`, Unreleased: one entry, user-facing wording, for example "Session Info now shows an API-equivalent cost for OpenCode, OpenClaw, Hermes, Kimi, Cline, Qwen, Antigravity and DeepSeek Harness sessions when the model has a published price." Check the wording against the release-notes linter word list before committing.

`docs/summaries/2026-10.md`: repository policy (`agents.md`, ~line 136) requires a one-or-two-bullet note there for every user-visible change. Append one bullet in the file's existing style, for example: "- Session Info now shows an API-equivalent cost for eight more agents when the session's model has a published first-party price; free routes are priced at the base model's list rate and labeled as such."

- [ ] **Step 3b: Add the released-sequence step to the release process**

Find the release checklist: `grep -rln "appcast" .claude/skills skills docs 2>/dev/null | head`. In the deploy skill's post-release steps add: "After the release is published, set `sequence` and `fingerprint` in `docs/prices-v2.released.json` to the values the released build bundles (`RunwayPriceTable.makeForTesting().sequence` and `.manifestFingerprint`), in a commit of its own." Ordinary price edits never touch that file; `testSequenceIsRaisedWheneverTheManifestDiffersFromTheLastRelease` then forces a higher `sequence` on the next edit of any byte.

- [ ] **Step 4: Publish order note for the release**

Add to the PR description: `docs/prices-v2.json` must be live on the docs site before or with the app release. `docs/prices.json` is unchanged in rates. Weekly calibration re-learns once on first launch.

- [ ] **Step 5: Commit (when the owner approves)**

Message: `docs: describe cost evidence rules for session sources`

---

## Self-Review Notes

- Spec §1 → Task 1. §2 → Task 2. §3 → Task 3. §4 → Task 11. §5 → Task 4. §6.1 → Task 7. §6.2 → Task 8. §6.3 and §6.4 → Tasks 5 and 9. §6.5 → Tasks 5 and 12. §7 → Tasks 5 and 6. §8 → Task 10. Compatibility and lifecycle → Task 3. Tests list → each task. Reader audit → Task 12 Step 1.
- Spec lifecycle rule "a v2 client leaves the v1 cache file untouched" is covered by `testV2ClientLeavesTheLegacyCacheFileUntouched` (sentinel file, real init and persist path) and `testCacheFileNamesDoNotCollide`.
- Retirement of `docs/prices.json` is a follow-up change by the spec's rule and has no task here.
- Task 11 is the one task without literal values. That is deliberate: the spec forbids rates from memory.
