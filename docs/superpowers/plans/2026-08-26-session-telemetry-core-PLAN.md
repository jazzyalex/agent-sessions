# Session Telemetry Core (Plan A) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A provider-neutral `SessionTelemetry` result (initial/current model+effort, configuration changes, token usage slices, fail-closed API-equivalent cost) computed on demand for a selected Codex or Claude session, with per-source capability declarations for all 15 sources.

**Architecture:** Telemetry is *not* stored on `Session` or in SQLite. A new `SessionTelemetryEngine` service re-reads the transcript file when asked (cached by path+mtime) and runs a one-pass per-provider accumulator. This keeps the hot `Session` struct, DB schema, and hydration paths untouched; rendering (a later plan) calls the engine for the selected session only.

**Tech Stack:** Swift 6 / Foundation only (JSONSerialization line parsing, matching existing parsers). XCTest. `scripts/xcode_add_file.rb` for pbxproj registration.

**Spec:** The SessionTelemetry spec delivered 2026-08-26 (chat message; key excerpts restated inline below). Spec corrections from the code-verification pass are in §"Spec corrections" and are binding.

## Global Constraints

- **NEVER push.** Commits only during approved plan execution, Conventional Commits, `Tool:`/`Model:` trailers, **no** Claude co-author, commit **only the task's paths** (`git commit -- <paths>`).
- New Swift files MUST be registered with `ruby scripts/xcode_add_file.rb <path>` (adds exactly 4 pbxproj lines per file; re-running can duplicate refs — check `git diff *.pbxproj` after).
- **Dirty-tree coordination:** the working tree carries uncommitted parallel work in `RunwayPriceTable.swift`, `docs/prices.json`, `UsageDisplayFormatter.swift`, `CodexRunwayModel.swift`, `CodexStatusService.swift`, `ClaudeUsageModel.swift`, `AgentCockpitHUDView.swift`, 2 test files (weekly burn-rate tracker + 2026-08-26 price refresh). Do not start Task 3 (pricing) until those are committed by their owner; never revert or overwrite them. All other tasks touch disjoint files.
- Top-line tokens = fresh input + cache reads + cache writes + output. `reasoning_output_tokens` is a **subset of output** — never added again (matches `CodexRunwayModel.swift` `dollarsPerHour`, comment at ~line 998).
- Dollar results are named `apiEquivalentUSD` everywhere — never "cost" or "spend" in identifiers/user copy.
- Fail closed on pricing: any positive-token slice with an unknown model or a missing required rate makes the session dollar total unavailable (with `unpricedModels`/`missingPriceComponents` populated). Never a silent partial sum or `$0`.
- Weekly-quota attribution is **out of scope** (Plan B). Plan A only declares its capability as `unavailable` per source.
- Final verification: targeted tests, then `./scripts/xcode_test_stable.sh`, then a Debug build.

## Spec corrections (verified against code 2026-08-26)

1. **`parentSpawnRequest` provenance is dropped.** Codex spawn records (`session_meta.payload.source.subagent.thread_spawn`) carry only `parent_thread_id`/`agent_path`/`agent_nickname`/`agent_role` — **no requested model/effort exists** (verified in [SessionIndexer.swift:2038](AgentSessions/Services/SessionIndexer.swift) and the stage0 codex fixture). A child's config comes solely from its own `turn_context` lines.
2. `ClaudeSessionParser` **does** extract `message.model` (lines 84/864); it drops top-level `effort` and never reads `message.usage`. The accumulator supplies both; the parser stays untouched.
3. Codex root effort is deliberately nulled at [SessionIndexer.swift:2093](AgentSessions/Services/SessionIndexer.swift) (`subagentReasoningEffort`). **Preserve that behavior** for `Session.reasoningEffort`; telemetry captures root effort in its own types instead. Do not "fix" the parser.
4. Codex `token_count` usage **does** include `cache_write_input_tokens` (fixture-verified), and Codex `input_tokens` **includes** `cached_input_tokens` (fixture: total 16422 = input 16341 + output 81, cached 3584 ⊂ input). Fresh input = `input_tokens − cached_input_tokens`, clamped ≥ 0. Claude's `input_tokens` is already fresh-only (cache read/write are separate fields).
5. The "in-memory weekly burn tracker" the spec cites is the **uncommitted** `UsageLimitBurnRateTracker` (working tree). Plan B must persist *its* samples, not build a second interval engine.

## Verified JSONL shapes (fixtures `Resources/Fixtures/stage0/agents/{codex,claude}/small.jsonl`)

Codex line: `{"timestamp":"…","type":"turn_context","payload":{"model":"…","effort":"…", …}}` and
`{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":16341,"cached_input_tokens":3584,"cache_write_input_tokens":0,"output_tokens":81,"reasoning_output_tokens":63,"total_tokens":16422},"last_token_usage":{…}},"rate_limits":{…}}}` — some payloads carry `token_count` at `payload.type` directly; accept both (mirror `CodexStatusService.extractUsageIfPresent`, ~line 3656). New-style: `payload.type == "turn.completed"|"turn_completed"|"turn-completed"` with `usage` at `payload.usage` or `payload.data.usage`.

Claude assistant line: top-level `"type":"assistant"`, top-level `"effort":"medium"`, `"message":{"id":"msg_…","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0}}}`.

---

### Task 1: Telemetry model types

**Files:**
- Create: `AgentSessions/Model/SessionTelemetry.swift`
- Test: `AgentSessionsTests/SessionTelemetryTypesTests.swift`

**Interfaces (Produces — later tasks depend on these exact names):**

```swift
public enum TelemetryProvenance: String, Codable, Sendable {
    case effectiveTurnContext      // Codex turn_context payload (effective settings)
    case assistantRecord           // Claude assistant record (message.model / top-level effort)
    case inferredFirstObservation  // initial config backfilled from the first observed value
}

public struct SessionConfiguration: Equatable, Codable, Sendable {
    public let model: String?
    public let reasoningEffort: String?
    public let observedAt: Date?
    public let anchorLine: Int          // 0-based transcript line index of the observation
    public let provenance: TelemetryProvenance
}

public struct ConfigurationChange: Equatable, Codable, Sendable {
    public enum Field: String, Codable, Sendable { case model, reasoningEffort }
    public let field: Field
    public let oldValue: String?
    public let newValue: String?
    public let observedAt: Date?
    public let anchorLine: Int
    public let provenance: TelemetryProvenance
}

/// Tokens attributed to one effective (model, effort) configuration.
public struct TelemetryUsageSlice: Equatable, Codable, Sendable {
    public var model: String?
    public var reasoningEffort: String?
    public var freshInputTokens: Int = 0
    public var cacheReadTokens: Int = 0
    public var cacheWrite5mTokens: Int = 0
    public var cacheWrite1hTokens: Int = 0
    public var outputTokens: Int = 0
    public var reasoningOutputTokens: Int = 0   // informational subset of output — never added to totals
    public var topLineTokens: Int {
        freshInputTokens + cacheReadTokens + cacheWrite5mTokens + cacheWrite1hTokens + outputTokens
    }
    public var isEmpty: Bool { topLineTokens == 0 }
}

public struct TelemetryUsageSummary: Equatable, Codable, Sendable {
    public let topLineTokens: Int
    /// false for legacy Codex logs that expose only recorded totals (no components);
    /// component fields are then 0 and the session is unpriceable.
    public let hasComponentBreakdown: Bool
    /// The provider's own recorded total (Codex total_tokens), when present.
    public let recordedTotalTokens: Int?
    /// e.g. ["token_count", "turn.completed"]; >1 means both families appeared and
    /// one was chosen as authoritative (see conflict flag).
    public let usageFamilies: [String]
    public let usageFamilyConflict: Bool
}

public struct TelemetryCostEstimate: Equatable, Codable, Sendable {
    /// nil ⇒ unavailable; then at least one of the two arrays is non-empty.
    public let apiEquivalentUSD: Double?
    public let unpricedModels: [String]
    public let missingPriceComponents: [String]   // e.g. "claude-opus-5:cacheWrite1h"
    public let priceTableUpdated: String          // manifest `updated` date used
}

public struct SessionTelemetry: Equatable, Codable, Sendable {
    public static let parserVersion = 1
    public let source: SessionSource
    public let initialConfiguration: SessionConfiguration?
    public let currentConfiguration: SessionConfiguration?
    public let configurationChanges: [ConfigurationChange]
    public let usageSlices: [TelemetryUsageSlice]
    public let usageSummary: TelemetryUsageSummary?
    public let costEstimate: TelemetryCostEstimate?
    public let parserVersion: Int
}
```

Note: no `weeklyQuotaAttribution` field yet — Plan B adds it; `parserVersion` bumps then.

- [ ] **Step 1: Write failing tests** — in `SessionTelemetryTypesTests.swift`:

```swift
import XCTest
@testable import AgentSessions

final class SessionTelemetryTypesTests: XCTestCase {
    func testTopLineExcludesReasoningSubset() {
        var s = TelemetryUsageSlice(model: "m", reasoningEffort: nil)
        s.freshInputTokens = 10; s.cacheReadTokens = 20
        s.cacheWrite5mTokens = 5; s.cacheWrite1hTokens = 5
        s.outputTokens = 40; s.reasoningOutputTokens = 30
        XCTAssertEqual(s.topLineTokens, 80)  // reasoning NOT added
    }
    func testTelemetryRoundTripsThroughCodable() throws {
        let cfg = SessionConfiguration(model: "gpt-5.6-codex", reasoningEffort: "medium",
                                       observedAt: Date(timeIntervalSince1970: 1_000),
                                       anchorLine: 3, provenance: .effectiveTurnContext)
        let t = SessionTelemetry(source: .codex, initialConfiguration: cfg, currentConfiguration: cfg,
                                 configurationChanges: [], usageSlices: [], usageSummary: nil,
                                 costEstimate: nil, parserVersion: SessionTelemetry.parserVersion)
        let data = try JSONEncoder().encode(t)
        XCTAssertEqual(try JSONDecoder().decode(SessionTelemetry.self, from: data), t)
    }
}
```

- [ ] **Step 2: Run** `xcodebuild test -scheme AgentSessions -only-testing:AgentSessionsTests/SessionTelemetryTypesTests` (via `./scripts/xcode_test_stable.sh` filter if that's the repo norm) — expect compile FAIL (types missing).
- [ ] **Step 3: Create `SessionTelemetry.swift`** with the interface block above, then `ruby scripts/xcode_add_file.rb AgentSessions/Model/SessionTelemetry.swift` (and the test file).
- [ ] **Step 4: Re-run the test — PASS.**
- [ ] **Step 5: Commit** `feat(telemetry): provider-neutral session telemetry types` (only the 3 touched paths + pbxproj).

---

### Task 2: Per-source telemetry capability declarations

**Files:**
- Modify: `AgentSessions/Model/SessionSourceDescriptor.swift` (struct at ~line 150)
- Modify: `AgentSessions/Model/SessionSourceRegistry.swift` (ordered list, lines 31–47) — only if descriptors are constructed there; otherwise each per-source descriptor file
- Test: `AgentSessionsTests/TelemetryCapabilityTests.swift`

**Interfaces (Produces):**

```swift
public enum TelemetryCapability: Equatable, Sendable {
    case supported
    case partial(String)          // reason
    case unavailable(String)      // reason
}

public struct TelemetryCapabilities: Sendable {
    public let configuration: TelemetryCapability
    public let tokens: TelemetryCapability
    public let cost: TelemetryCapability
    public let weeklyQuota: TelemetryCapability
}
```

Add **non-optional** `let telemetry: TelemetryCapabilities` to `SessionSourceDescriptor` so the compiler forces all 15 declarations. Initial values:

| source | configuration | tokens | cost | weeklyQuota |
|---|---|---|---|---|
| codex | supported | `partial("legacy total-only logs have no component breakdown")` | partial (same reason) | `unavailable("no persisted account quota snapshots (Plan B)")` |
| claude | `partial("initial config is first-observed, not recorded at session start")` | supported | supported | unavailable (same Plan B reason) |
| pi, openclaw, copilot | `unavailable("change records exist in logs; accumulator not built (Plan C)")` | unavailable("Plan C") | unavailable("Plan C") | unavailable("no account quota feed") |
| qwen, kimi | `unavailable("per-call token telemetry retained but unparsed (Plan C)")` | unavailable("Plan C") | unavailable("Plan C") | unavailable("no account quota feed") |
| grok, fx | `unavailable("scalar metadata only; timeline/usage audit pending (Plan C)")` | unavailable(...) | unavailable(...) | unavailable(...) |
| antigravity, opencode, hermes, droid, cursor, devin | `unavailable("format not audited for telemetry")` × all four |

- [ ] **Step 1: Failing test:**

```swift
final class TelemetryCapabilityTests: XCTestCase {
    func testAllFifteenSourcesDeclareTelemetryCapabilities() {
        for source in SessionSource.allCases {
            let d = SessionSourceRegistry.descriptor(for: source)   // use the registry's actual accessor
            _ = d.telemetry   // compile-time forced; runtime asserts the reasons are non-empty
            for cap in [d.telemetry.configuration, d.telemetry.tokens, d.telemetry.cost, d.telemetry.weeklyQuota] {
                if case .unavailable(let reason) = cap { XCTAssertFalse(reason.isEmpty) }
                if case .partial(let reason) = cap { XCTAssertFalse(reason.isEmpty) }
            }
        }
    }
    func testOnlyCodexAndClaudeHaveAnySupport() {
        for source in SessionSource.allCases where ![.codex, .claude].contains(source) {
            let t = SessionSourceRegistry.descriptor(for: source).telemetry
            for cap in [t.configuration, t.tokens, t.cost, t.weeklyQuota] {
                guard case .unavailable = cap else { return XCTFail("\(source) must be unavailable in Plan A") }
            }
        }
    }
}
```

(Adjust `descriptor(for:)` to the registry's real accessor — verified structure is `SessionSourceRegistry.ordered`; if only the array exists, look up by `id`.)

- [ ] **Step 2: Run — compile FAIL.**
- [ ] **Step 3: Implement** — put `TelemetryCapability`/`TelemetryCapabilities` in `SessionSourceDescriptor.swift`; add the field; fill all 15 descriptors per the table. This modifies every per-source descriptor construction — grep `SessionSourceDescriptor(` for all callsites (repo rule).
- [ ] **Step 4: Run full unit target once** (descriptor inits are used everywhere) — PASS.
- [ ] **Step 5: Commit** `feat(telemetry): per-source telemetry capability declarations`.

---

### Task 3: Pricing — 1h cache-write rate + shared lookup surface

**Precondition: the parallel session's price-refresh changes are committed.** Rebase this task on that commit.

**Files:**
- Modify: `AgentSessions/CodexStatus/RunwayPriceTable.swift`
- Modify: `docs/prices.json`
- Test: extend the existing price-table test file (grep `RunwayPriceTable` under `AgentSessionsTests/`)

**Interfaces (Produces):**
- `RunwayModelPrice` gains `let cacheWrite1hPerMTok: Double?` (after `cacheWritePerMTok`). Semantics: `cacheWritePerMTok` stays the 5-minute write rate; `cacheWrite1hPerMTok` is the 1-hour write rate (Anthropic: 2× input). `nil` ⇒ that component is unpriceable (fail-closed), **not** a fallback to the 5m rate.
- `RunwayPriceTable` gains `var updatedDate: String` (lock-guarded read of `loadedUpdated`) so cost results can stamp the manifest date.

- [ ] **Step 1: Failing tests:** decode of a manifest entry carrying `cacheWrite1hPerMTok` populates it; an entry without it decodes with `nil` (backward compatible — `JSONDecoder` ignores unknown/missing optional keys); `updatedDate` returns the adopted manifest's date.
- [ ] **Step 2: Run — FAIL.**
- [ ] **Step 3: Implement.** Add the field to the struct + the decode path (find `Self.decode` in the same file). In the **bundled JSON** and `docs/prices.json`, add `"cacheWrite1hPerMTok"` = 2× `inputPerMTok` to every `claude-*` key (e.g. `claude-opus` → 10.0, `claude-sonnet-5` → 4.0, `claude-sonnet` → 6.0, `claude-haiku` → 2.0, `claude-fable` → 20.0 — compute each from the committed table, don't trust this list if rates moved) and leave it absent for `gpt-*` keys. Keep `"version": 1` (additive optional key; old clients ignore it). **Advance `updated`** in both copies (manifest acceptance rule requires it) and note the new key in `_note`.
- [ ] **Step 4: Run — PASS.** Also run the existing runway `$` tests to prove no behavior change for the live runway path.
- [ ] **Step 5: Commit** `feat(pricing): 1-hour cache-write rate in the price manifest`.

---

### Task 4: Codex telemetry accumulator

**Files:**
- Create: `AgentSessions/Telemetry/CodexTelemetryAccumulator.swift`
- Test: `AgentSessionsTests/CodexTelemetryAccumulatorTests.swift`

**Interfaces:**
- Consumes: Task 1 types.
- Produces: `struct CodexTelemetryAccumulator { static func accumulate(lines: [String]) -> SessionTelemetry }` (pure; costEstimate left nil — Task 6 fills it).

**Rules (from spec, fixture-verified):**
1. `type == "turn_context"` → read `payload.model` / `payload.effort`. First one = `initialConfiguration` (`.effectiveTurnContext`). Later differing values append `ConfigurationChange` per changed field; identical repeats append nothing. Timestamps from the line's top-level `timestamp` (ISO8601, reuse the shared formatter other parsers use).
2. Usage family A — `token_count` (at `payload.type` or, wrapped, `payload.payload.type` is NOT a thing; accept `payload["type"]=="token_count"` and the `event_msg` wrapper by also checking `(payload["payload"] as? [String:Any])` if the existing extractor does — mirror `CodexStatusService.extractUsageIfPresent` exactly): prefer cumulative `info.total_token_usage`. Maintain `lastCumulative` per component (`input_tokens`, `cached_input_tokens`, `cache_write_input_tokens`, `output_tokens`, `reasoning_output_tokens`, `total_tokens`). Each new record yields component deltas vs `lastCumulative`, assigned to the slice for the *current* effective (model, effort). Fresh-input delta = Δinput − Δcached, clamped ≥ 0; Codex cache writes go to `cacheWrite5mTokens` (single undifferentiated bucket today; fixture field `cache_write_input_tokens`).
3. **Epochs:** any cumulative component decreasing ⇒ new epoch: reset `lastCumulative` to this record's values and treat the record's own values as the first delta of the epoch (i.e., add them whole).
4. Usage family B — `turn.completed` / `turn_completed` / `turn-completed` with `usage` at `payload.usage` or `payload.data.usage`: **per-turn incremental** — sum, don't delta.
5. Authority: if any family-A cumulative record exists, family A is authoritative and family-B records are counted only into `usageFamilies`; `usageFamilyConflict = true` when both families report positive tokens. Never sum both.
6. Legacy total-only: family-A records where only `total_tokens` parses ⇒ `hasComponentBreakdown = false`, slices stay empty, `recordedTotalTokens` = last cumulative total (per epoch summed).
7. `recordedTotalTokens` = sum over epochs of each epoch's final `total_tokens` (when present).

- [ ] **Step 1: Failing tests** with inline JSONL (compact; timestamps ISO8601). Cover, at minimum:

```swift
func testInitialConfigAndSingleChange()      // 2 turn_context lines, model changes once, effort stable → 1 change record, initial preserved
func testRepeatedIdenticalContextNoChange()  // 3 identical turn_context lines → 0 changes
func testCumulativeDeltasAttributedPerModel()// token_count 100/0/0/10 under model A, then context switch to B, then token_count 250/0/0/40 → slice A {fresh 100, out 10}, slice B {fresh 150, out 30}
func testCumulativeResetStartsNewEpoch()     // cumulative drops → totals = epoch1_final + epoch2_final, no negative deltas
func testTurnCompletedFamilySummed()         // only turn.completed records → summed, family ["turn.completed"]
func testBothFamiliesNeverDoubleCounted()    // both present → total equals family-A result, usageFamilyConflict true
func testLegacyTotalOnly()                   // only total_tokens → hasComponentBreakdown false, recordedTotalTokens set, slices empty
func testReasoningSubsetNotAddedToTopLine()  // reasoning_output_tokens tracked informationally; topLine uses output only
func testFreshInputClampedWhenCachedExceedsInputDelta()
```

Test JSONL lines must copy the real shapes from §"Verified JSONL shapes" (e.g. `{"timestamp":"2026-08-26T10:00:00.000Z","type":"turn_context","payload":{"model":"gpt-5.6-codex","effort":"medium"}}` and the `token_count`/`info` nesting exactly as in the fixture).

- [ ] **Step 2: Run — FAIL.**
- [ ] **Step 3: Implement** the one-pass accumulator (single `for (lineIndex, line) in lines.enumerated()`, `JSONSerialization` per line, tolerant of non-JSON lines). `currentConfiguration` = last effective config.
- [ ] **Step 4: Run — PASS.**
- [ ] **Step 5:** Also run existing `CodexUsageParserTests` + `SessionParserTests` untouched-behavior check (should be unaffected — no shared files).
- [ ] **Step 6: Commit** `feat(telemetry): one-pass Codex configuration+usage accumulator`.

---

### Task 5: Claude telemetry accumulator

**Files:**
- Create: `AgentSessions/Telemetry/ClaudeTelemetryAccumulator.swift`
- Test: `AgentSessionsTests/ClaudeTelemetryAccumulatorTests.swift`

**Interfaces:** `struct ClaudeTelemetryAccumulator { static func accumulate(lines: [String]) -> SessionTelemetry }`

**Rules:**
1. Only top-level `"type":"assistant"` records contribute. Model from `message.model`; effort from the record's **top-level** `effort`.
2. First observed (model|effort) ⇒ `initialConfiguration` with provenance `.inferredFirstObservation` (Claude never records session-start config); subsequent differing values ⇒ `ConfigurationChange` with `.assistantRecord`. If model appears before effort, backfill the initial configuration's effort from the first record that has one *without* emitting a change (the spec's "first observed effective" semantics).
3. Dedup: if `message.id` was already seen **with usage**, skip the record entirely (streaming duplicates). Mirror `ClaudeRunwayTokenActivityParser.swift:333` (`seenMessageIDs`).
4. Usage mapping per record (sum, never delta): fresh = `usage.input_tokens`; cacheRead = `usage.cache_read_input_tokens`; 5m/1h from `usage.cache_creation.ephemeral_5m_input_tokens` / `ephemeral_1h_input_tokens`; when the `cache_creation` dict is absent, the undifferentiated `cache_creation_input_tokens` counts as 5m (Anthropic's default TTL for old records); output = `usage.output_tokens`. Attribute to the record's own `message.model` + effort (per-message attribution, not "current config").
5. All-zero usage records (synthetic) contribute to config observation but add no slice tokens.

- [ ] **Step 1: Failing tests:**

```swift
func testFirstObservedConfigIsInitial()          // provenance .inferredFirstObservation
func testDuplicateMessageIDCountedOnce()         // same msg id twice with usage → tokens counted once
func testFiveMinuteAndOneHourWritesKeptSeparate()// cache_creation split lands in the two fields
func testLegacyUndifferentiatedWriteCountsAs5m() // no cache_creation dict → cache_creation_input_tokens → 5m bucket
func testMixedModelsProducePerModelSlices()      // opus record + haiku record → 2 slices
func testModelChangeRecordedOnce()               // A,A,B → exactly 1 change
func testZeroTokenSyntheticIgnoredForUsage()     // config observed, slices unchanged
func testEffortChangeRecorded()                  // top-level effort medium→high → change with .assistantRecord
```

Use the real record shape from §"Verified JSONL shapes" (the stage0 claude fixture line 29 is the template).

- [ ] **Step 2: Run — FAIL.**  
- [ ] **Step 3: Implement.**  
- [ ] **Step 4: Run — PASS.**
- [ ] **Step 5: Commit** `feat(telemetry): one-pass Claude configuration+usage accumulator`.

---

### Task 6: Fail-closed cost calculator

**Files:**
- Create: `AgentSessions/Telemetry/TelemetryCostCalculator.swift`
- Test: `AgentSessionsTests/TelemetryCostCalculatorTests.swift`

**Interfaces:**
- Consumes: Task 1 `TelemetryUsageSlice`/`TelemetryCostEstimate`, Task 3 `RunwayModelPrice` (incl. `cacheWrite1hPerMTok`) and `RunwayPriceTable.price(forModel:)`/`updatedDate`.
- Produces: `struct TelemetryCostCalculator { static func estimate(slices: [TelemetryUsageSlice], priceTable: RunwayPriceTable) -> TelemetryCostEstimate }`

**Rules:** per non-empty slice: `USD = fresh×input + cacheRead×cachedInput + write5m×cacheWrite + write1h×cacheWrite1h + output×output` (all /1_000_000). Unknown model (nil lookup or nil slug with positive tokens) → append to `unpricedModels`. Positive `cacheWrite5mTokens` with `cacheWritePerMTok == nil`, or positive `cacheWrite1hTokens` with `cacheWrite1hPerMTok == nil` → append `"\(model):cacheWrite5m"` / `":cacheWrite1h"` to `missingPriceComponents`. Any entry in either array ⇒ `apiEquivalentUSD = nil`. Empty slices list ⇒ nil USD with both arrays empty (nothing to price ≠ error). Always stamp `priceTableUpdated`.

- [ ] **Step 1: Failing tests:** priced mixed-model session sums per slice (hand-computed expected value with a table built via `RunwayPriceTable(loadBundled:false, readCache:false)` + a test manifest through the existing decode path, or an injected `[String: RunwayModelPrice]` seam if the initializer can't be fed — check the existing price-table tests for the established seam and reuse it); unknown-model slice ⇒ nil + `unpricedModels`; positive 1h writes with nil 1h rate ⇒ nil + `missingPriceComponents`; zero-token slice with unknown model does NOT poison the result.
- [ ] **Step 2: FAIL. Step 3: implement. Step 4: PASS.**
- [ ] **Step 5: Commit** `feat(telemetry): fail-closed api-equivalent cost calculator`.

---

### Task 7: SessionTelemetryEngine (on-demand computation + cache)

**Files:**
- Create: `AgentSessions/Telemetry/SessionTelemetryEngine.swift`
- Test: `AgentSessionsTests/SessionTelemetryEngineTests.swift`

**Interfaces:**
- Consumes: Tasks 1–6.
- Produces:

```swift
/// On-demand telemetry for one session. Not stored on `Session`, not in SQLite:
/// computed from the transcript file when asked, cached by (path, mtime, parserVersion).
final class SessionTelemetryEngine {
    static let shared = SessionTelemetryEngine()
    /// nil when the source's tokens+configuration capabilities are both unavailable,
    /// or the file is unreadable. Runs file IO + parsing off the caller's thread.
    func telemetry(for session: Session) async -> SessionTelemetry?
    func invalidate(path: String)
}
```

**Rules:** dispatch on `session.source` — `.codex` → `CodexTelemetryAccumulator`, `.claude` → `ClaudeTelemetryAccumulator`, everything else → nil (checked via the Task 2 capability, not a hardcoded list, so Plan C only edits descriptors). After accumulation, fill `costEstimate` via `TelemetryCostCalculator` **only when** the source's `cost` capability isn't `unavailable` and `usageSummary?.hasComponentBreakdown == true`. Cache: `[path: (mtime: Date, telemetry: SessionTelemetry)]`, NSLock-guarded, capacity ~16 LRU (one selected transcript at a time; generous). A changed mtime or `parserVersion` recomputes. Read the file with the same encoding-tolerant read the indexer uses (`String(contentsOf:)` with `.utf8` fallback — copy the pattern from `SessionIndexer`'s file read).

- [ ] **Step 1: Failing tests:** write a temp JSONL (codex shape) → engine returns telemetry; second call returns cached (assert via a probe counter seam `var parseCount` exposed `internal` for tests); touching the file (new mtime + appended line) recomputes; a `.qwen`-sourced session returns nil; a claude fixture file end-to-end returns the same numbers as `ClaudeTelemetryAccumulator` directly (uses `Resources/Fixtures/stage0/agents/claude/small.jsonl`).
- [ ] **Step 2: FAIL. Step 3: implement. Step 4: PASS.**
- [ ] **Step 5: Commit** `feat(telemetry): on-demand telemetry engine with mtime cache`.

---

### Task 8: Fixture integration test + full verification

**Files:**
- Test: `AgentSessionsTests/SessionTelemetryFixtureTests.swift`

- [ ] **Step 1:** Integration tests over the real stage0 fixtures for both providers: assert exact expected initial config, change count, per-component token totals and (for Claude) a priced `apiEquivalentUSD` computed by hand from the committed price table; for Codex assert `recordedTotalTokens == 16422`-style exact values read off the fixture. These pin the whole pipeline.
- [ ] **Step 2:** Run new test files — PASS.
- [ ] **Step 3:** `./scripts/xcode_test_stable.sh` (full suite) — 0 failures.
- [ ] **Step 4:** Debug build (default DerivedData, NOT the test-derived-data path) — builds clean.
- [ ] **Step 5: Commit** `test(telemetry): fixture integration coverage for codex+claude telemetry`.
- [ ] **Step 6:** Update `RepoHandover.md` with a dated entry (state, decisions incl. the two spec corrections, Plan B/C pointers). Commit `docs: telemetry core handover`.

---

## Deliberately out of scope (follow-up plans)

- **Plan B — weekly quota attribution:** persist `UsageLimitBurnRateTracker` samples (provider/account scope, observedAt, remaining %, resetAt, source, freshness) in a **separate** store (not `session_meta`); interval attribution `quotaDrop × sessionTokens/allTrackedTokens` with same-reset + monotonic guards (the uncommitted tracker already encodes these semantics — reuse it); Codex historical backfill from embedded `rate_limits` (fixture confirms `rate_limits` rides on `token_count` lines); Claude forward-only. Name: `estimatedWeeklyQuotaPercentagePoints`, always confidence-tagged.
- **Plan C — provider expansion:** Pi/OpenClaw/Copilot configuration timelines (explicit change events exist: `PiSessionParser.swift:561`, `OpenClawSessionParser.swift:220`), Qwen/Kimi token records (backlog lines 772/757), Grok/fx audits. Only descriptor edits + new accumulators; the engine dispatch is already capability-driven.
- **Rendering:** all UI. The engine exposes anchors (`anchorLine`) and complete results; placement/formatting is a later session with owner input.
