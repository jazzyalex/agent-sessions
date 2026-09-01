# Session Telemetry Core (Plan A) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A provider-neutral `SessionTelemetry` result (initial/current model+effort, configuration changes, token usage slices, fail-closed API-equivalent cost) computed on demand for a selected Codex or Claude session, with per-source capability declarations for all 15 sources.

**Architecture:** Telemetry is *not* stored on `Session` or in SQLite, and *not* derived from hydrated `SessionEvent`s (both parsers truncate `rawJSON` — Claude at 8,192 bytes, Codex sanitizes >100 KB lines — so usage on large assistant lines is already gone). A new `SessionTelemetryEngine` streams the transcript file when asked, caches by file signature, and runs a one-pass per-provider accumulator. The hot `Session` struct, DB schema, and hydration paths stay untouched.

**Tech Stack:** Swift 6 / Foundation only (JSONSerialization per line, matching existing parsers). XCTest. `scripts/xcode_add_file.rb` for pbxproj registration.

**Spec:** The SessionTelemetry spec delivered 2026-08-26 (chat message; excerpts restated inline). Corrections from three verification passes are in §"Spec corrections" and are binding.

> **STATUS 2026-08-31 — Tasks 1, 2, 4, 5, 6, 7, 8 implemented (Task 3 deleted as shipped upstream).**
> 75 new tests across 7 files, all green; full suite 2471 tests / 0 failures; Debug build clean.
> Uncommitted. Deviations recorded during execution:
> 1. **`anchorLine` is a record index, not a raw file line.** `JSONLReader` silently drops
>    blank lines and stubs oversize ones, so raw line numbers cannot survive streaming.
>    Documented on the field; consumers must walk the file with the same reader.
> 2. **Accumulators are `consume(line:index:)` + `finish()` structs**, with
>    `accumulate(lines:)` as a thin wrapper. A generic `Sequence` alone could not be fed
>    from `JSONLReader`'s push-based callback without materializing the file.
> 3. **A `token_count` record with `info: null` still marks the family present**, so the
>    summary reports zero rather than nil. "Usage records existed but carried no numbers"
>    is a different fact from "no usage records at all".
> 4. **`ConfigurationTimeline` takes two provenances** — Codex's initial config is
>    `.effectiveTurnContext` (recorded), Claude's is `.inferredFirstObservation` (inferred).
> 5. `RepoHandover.md` NOT written: a parallel session holds uncommitted edits there.
>
> **Revision history:** 2026-08-29 — re-verified every anchor against `main`; Task 3 (pricing) **deleted** (shipped upstream, more completely); speed-tier pricing promoted to a requirement. 2026-08-29 (later) — folded in an adversarial review verified against 227 real Claude transcripts (47,671 usage records), 1,196 real Codex rollouts (21,114 `token_count` records), and both stage0 fixtures: config-timeline carry-forward rules, Claude `usageSummary`, streaming signatures, cache key, sidechain handling.

## Global Constraints

- **NEVER commit or push without an explicit user request.** Implement, verify, leave uncommitted. When commits are authorized: Conventional Commits, `Tool:`/`Model:` trailers, **no** Claude co-author, and commit **only the task's paths** (`git commit -- <paths>`).
- New Swift files MUST be registered: `./scripts/xcode_add_file.rb AgentSessions.xcodeproj <TARGET> <FILE> <GROUP>`. A correct run adds **exactly 4 lines** to `project.pbxproj` — verify with `git diff --numstat`.
- Top-line tokens = fresh input + cache reads + cache writes + output. `reasoning_output_tokens` is a **subset of output** — never added again ([CodexRunwayModel.swift:1244](AgentSessions/CodexStatus/CodexRunwayModel.swift:1244)).
- Dollar results are named `apiEquivalentUSD` everywhere — never "cost" or "spend" in identifiers or user copy.
- Fail closed on pricing, **whole-session**: any positive-token slice with an unknown model, an unpriced speed tier, or a missing cache rate makes the session's dollar figure unavailable, with `unpricedModels`/`missingPriceComponents` naming the cause. This matches the shipped precedent ([CodexRunwayModel.swift:1259](AgentSessions/CodexStatus/CodexRunwayModel.swift:1259)): a partial sum silently understates, and a session-level figure exists to be compared across sessions.
- **Do not reimplement shared primitives.** Reuse `ClaudeRunwayLog.{jsonObject,double,date,cacheCreation}`, `RunwaySpeedTier(usageValue:)`, `RunwayModelPrice.rates(for:)`, `RunwayFileSignature`, and `JSONLReader`. Divergence here is the bug class the format tracker keeps catching.
- Weekly-quota attribution is **out of scope** (Plan B). Plan A declares it `unavailable` for every source.
- Final verification: targeted tests, then `./scripts/xcode_test_stable.sh` (0 failures **and** no drop in test count), then a Debug build against default DerivedData.

## Spec corrections (verified 2026-08-26, re-verified 2026-08-29)

1. **`parentSpawnRequest` provenance is dropped.** Codex spawn records carry only `parent_thread_id`/`agent_path`/`agent_nickname`/`agent_role` — **no requested model/effort exists** ([SessionIndexer.swift:2038](AgentSessions/Services/SessionIndexer.swift:2038)). A child's config comes solely from its own `turn_context` lines.
2. `ClaudeSessionParser` **does** extract `message.model`; it drops top-level `effort` and never reads `message.usage`. The accumulator supplies both; the parser stays untouched.
3. Codex root effort is deliberately nulled at [SessionIndexer.swift:2093](AgentSessions/Services/SessionIndexer.swift:2093). **Preserve that** for `Session.reasoningEffort`; telemetry captures root effort in its own types.
4. **Codex fresh input = `input_tokens − cached_input_tokens`**, clamped ≥ 0. Verified consistent with the live runway, which does the same subtraction in both places ([CodexRunwayModel.swift:2356](AgentSessions/CodexStatus/CodexRunwayModel.swift:2356) ledger, [:2409](AgentSessions/CodexStatus/CodexRunwayModel.swift:2409) rate deltas). Fixture: 16,422 = 16,341 + 81, cached 3,584 ⊂ input. Zero counterexamples in 60 real files. Claude's `input_tokens` is already fresh-only.
5. **Pricing is done (2026-08-30 manifest).** `RunwayRateSet.cacheWrite1hPerMTok` exists, and `RunwayModelPrice` carries an optional `fast` rate set with `rates(for:)`. **Original Task 3 is deleted.** Do not re-add a 1h column or a second price table.
6. **Speed tier is part of a usage slice's identity.** Fast mode bills Opus 5 / 4.8 at 2×. `usage.speed` is the only trustworthy signal — Opus 4.6 *accepts* `speed:"fast"` then bills standard, so a model-name heuristic doubles the bill in exactly the case that most looks like fast mode. A `fast` record whose model has no `fast` rate set is **unpriceable**, never billed at standard.
7. **Claude cache-write TTL split is live.** Use `ClaudeRunwayLog.cacheCreation(usage:)`: the `cache_creation` sub-object **replaces** the flat `cache_creation_input_tokens` (never sum); the flat field is the pre-split fallback priced at the 5-minute rate.
8. `RunwayRateSet.dollars(...)` deliberately falls back (`cacheWrite1h ?? cacheWrite5m ?? input`, [RunwayPriceTable.swift:44](AgentSessions/CodexStatus/RunwayPriceTable.swift:44)) for the live runway. The telemetry calculator must **not** call it — read rate fields directly and fail closed.
9. **Codex cumulative-delta + epochs is required, not defensive.** 11 of 60 recent real files contain a mid-file cumulative decrease (resumes; 21 of 60 have >1 `session_meta`). `total_token_usage` is present on 21,113 of 21,114 real records, so "prefer cumulative" is safe. Delta-on-total is more robust than summing `last_token_usage` (385 of 14,852 pairs disagree, all straddling epoch boundaries).
10. **`turn.completed` (family B) has zero sightings** in 80 recent real files. Keep it as drift insurance ([CodexStatusService.swift:3715](AgentSessions/CodexStatus/CodexStatusService.swift:3715) parses it defensively) but do not grow it.

## Standing reference: the format tracker

`docs/agent-support/agent-format-tracker.jsonl` (57 records; fields `agent`, `bucket`, `confidence`, `event`, `finding_id`, `observation`, `evidence`, `frequency`) is the authority on transcript-format drift. Before touching a provider's accumulator:

```bash
python3 -c "import json;[print(r['bucket'],'|',r['finding_id'],'|',r['observation'][:200]) for r in map(json.loads,open('docs/agent-support/agent-format-tracker.jsonl')) if r['agent']=='claude']"
```

Already folded in: `claude/message.usage.cache_creation` (TTL split — fixed upstream; measured 182.8M local cache-creation tokens, 100% 1-hour, a 16.6% understatement before the fix), `claude/message.usage.speed` (fast tier — fixed upstream), `codex/pricing/openai-long-context` (won't-do; no long-context tier reachable from the CLI).

**Known follow-up, deliberately not built on:** `claude/cost-state` — a top-level record carrying `totalCostUSD` (the session's *measured* cost), per-model token counts and `hasUnknownModelCost`. It is ground truth for what this plan estimates. The tracker filed it at 1-of-80 sessions with "re-count, don't build on"; an independent count found **7 sightings in the 120 newest local files**, so the re-count trigger is close. Keep it out of Plan A; when adopted it becomes a cross-check on `apiEquivalentUSD`, never a replacement.

## Verified JSONL shapes

Codex ([fixture](Resources/Fixtures/stage0/agents/codex/small.jsonl)): `{"timestamp":"…","type":"turn_context","payload":{"model":"…","effort":"…"}}` and
`{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":16341,"cached_input_tokens":3584,"cache_write_input_tokens":0,"output_tokens":81,"reasoning_output_tokens":63,"total_tokens":16422},"last_token_usage":{…}},"rate_limits":{…}}}`. New-style: `payload.type == "turn.completed"|"turn_completed"|"turn-completed"` with `usage` at `payload.usage` or `payload.data.usage`. **`payload` may be absent on old rollouts — read `obj["payload"] ?? obj`** ([CodexStatusService.swift:3644](AgentSessions/CodexStatus/CodexStatusService.swift:3644)). `token_count` records with `info: null` exist (fixture line 86; precedent test `testToleratesTokenCountWithNullInfo`, [CodexUsageParserTests.swift:62](AgentSessionsTests/CodexUsageParserTests.swift:62)).

Claude ([fixture](Resources/Fixtures/stage0/agents/claude/small.jsonl)): top-level `"type":"assistant"`, top-level `"effort"`, `"isSidechain"`, `"message":{"id":"msg_…","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0},"speed":"standard"}}`.

**The Claude fixture is adversarial — this is why the carry-forward rules below exist.** Its 11 assistant records include: 3 with `effort` but **no model, no `message.id`, no usage**, all three also `isSidechain: true` (lines 8/18/19); 2 with `model: "<synthetic>"` and zero usage (lines 47/97); 2 with `effort: "[trimmed for fixture]"` — a **non-empty junk string** that naive rules score as a real effort change (lines 65/78); and several with a model but `effort: null` (lines 50/55/77).

---

### Task 1: Telemetry model types

**Files:**
- Create: `AgentSessions/Model/SessionTelemetry.swift`
- Test: `AgentSessionsTests/SessionTelemetryTypesTests.swift` *(already written and registered — verify it matches the interface below, then make it pass)*

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
    /// 0-based index of the RAW file line, counting blank and non-JSON lines, so a
    /// future "jump to this line" lands on the right one. The engine's line feed
    /// MUST NOT drop empty lines (no `omittingEmptySubsequences: true`).
    public let anchorLine: Int
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

/// Tokens attributed to one effective (model, effort, speed) configuration.
///
/// Slices are a BREAKDOWN, not a pricing requirement: cost is linear in tokens, so
/// any UI regrouping (per model, per speed) sums slices without re-pricing. Effort
/// does not affect price at all — it is here because "what did xhigh cost me in
/// tokens" is the deliverable.
public struct TelemetryUsageSlice: Equatable, Codable, Sendable {
    public var model: String?
    public var reasoningEffort: String?
    public var speed: String            // RunwaySpeedTier.rawValue; always "standard" for Codex
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
    /// false for legacy Codex logs exposing only recorded totals; component fields
    /// are then 0 and the session is unpriceable.
    public let hasComponentBreakdown: Bool
    public let recordedTotalTokens: Int?
    public let usageFamilies: [String]        // e.g. ["token_count"], ["message.usage"]
    public let usageFamilyConflict: Bool
}

public struct TelemetryCostEstimate: Equatable, Codable, Sendable {
    /// nil ⇒ unavailable. Both arrays empty AND nil ⇒ nothing to price (not a failure).
    public let apiEquivalentUSD: Double?
    public let unpricedModels: [String]
    /// e.g. "claude-opus-5:fast" (no fast rate set) or "claude-opus-5:cacheWrite1h".
    public let missingPriceComponents: [String]
    public let priceTableUpdated: String      // manifest `updated` date used
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

No `weeklyQuotaAttribution` yet — Plan B adds it and bumps `parserVersion`.

- [ ] **Step 1: Confirm the failing test** — `AgentSessionsTests/SessionTelemetryTypesTests.swift` exists and covers: reasoning excluded from `topLineTokens`; a reasoning-only slice is `isEmpty`; `speed` participates in equality; full `Codable` round-trip; an unavailable cost carries a reason.
- [ ] **Step 2: Run to verify it fails** — expect a compile failure (types missing).
- [ ] **Step 3: Create `SessionTelemetry.swift`** with the interface block above; register it: `./scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessions AgentSessions/Model/SessionTelemetry.swift AgentSessions/Model`.
- [ ] **Step 4: Run the tests — PASS.**
- [ ] **Step 5: Report.** (Commit on request: `feat(telemetry): provider-neutral session telemetry types`.)

---

### Task 2: Per-source telemetry capability declarations

**Files:**
- Modify: `AgentSessions/Model/SessionSourceDescriptor.swift` (struct fields begin ~line 158)
- Modify: every `SessionSourceDescriptor(` construction — `grep -rn 'SessionSourceDescriptor(' AgentSessions/`
- Test: `AgentSessionsTests/TelemetryCapabilityTests.swift`

**Interfaces (Produces):**

```swift
public enum TelemetryCapability: Equatable, Sendable {
    case supported
    case partial(String)          // reason
    case unavailable(String)      // reason
}

public struct TelemetryCapabilities: Equatable, Sendable {
    public let configuration: TelemetryCapability
    public let tokens: TelemetryCapability
    public let cost: TelemetryCapability
    public let weeklyQuota: TelemetryCapability
}
```

Add **non-optional** `let telemetry: TelemetryCapabilities` to `SessionSourceDescriptor` so the compiler forces all 15 declarations:

| source | configuration | tokens | cost | weeklyQuota |
|---|---|---|---|---|
| codex | supported | `partial("legacy total-only logs have no component breakdown")` | partial (same reason) | `unavailable("no persisted account quota snapshots (Plan B)")` |
| claude | `partial("initial config is first-observed, not recorded at session start")` | supported | supported | unavailable (same Plan B reason) |
| pi, openclaw, copilot | `unavailable("change records exist in logs; accumulator not built (Plan C)")` | `unavailable("Plan C")` | `unavailable("Plan C")` | `unavailable("no account quota feed")` |
| qwen, kimi | `unavailable("per-call token telemetry retained but unparsed (Plan C)")` | `unavailable("Plan C")` | `unavailable("Plan C")` | `unavailable("no account quota feed")` |
| grok, fx | `unavailable("scalar metadata only; timeline/usage audit pending (Plan C)")` | `unavailable("Plan C")` | `unavailable("Plan C")` | `unavailable("no account quota feed")` |
| antigravity, opencode, hermes, droid, cursor, devin | `unavailable("format not audited for telemetry")` × all four |

- [ ] **Step 1: Write the failing test:**

```swift
import XCTest
@testable import AgentSessions

final class TelemetryCapabilityTests: XCTestCase {
    func testAllSourcesDeclareNonEmptyReasons() {
        for source in SessionSource.allCases {
            let t = SessionSourceRegistry.descriptor(for: source).telemetry
            for cap in [t.configuration, t.tokens, t.cost, t.weeklyQuota] {
                if case .unavailable(let r) = cap { XCTAssertFalse(r.isEmpty, "\(source)") }
                if case .partial(let r) = cap { XCTAssertFalse(r.isEmpty, "\(source)") }
            }
        }
    }
    func testOnlyCodexAndClaudeHaveAnySupportInPlanA() {
        for source in SessionSource.allCases where source != .codex && source != .claude {
            let t = SessionSourceRegistry.descriptor(for: source).telemetry
            for cap in [t.configuration, t.tokens, t.cost, t.weeklyQuota] {
                guard case .unavailable = cap else {
                    return XCTFail("\(source) must be unavailable in Plan A")
                }
            }
        }
    }
    func testWeeklyQuotaIsUnavailableEverywhereInPlanA() {
        for source in SessionSource.allCases {
            guard case .unavailable = SessionSourceRegistry.descriptor(for: source).telemetry.weeklyQuota else {
                return XCTFail("\(source) weeklyQuota must be unavailable until Plan B")
            }
        }
    }
}
```

- [ ] **Step 2: Run to verify it fails** — compile failure.
- [ ] **Step 3: Implement** — types in `SessionSourceDescriptor.swift`, the new field, all 15 descriptors per the table.
- [ ] **Step 4: Run the unit target — PASS** (descriptor inits are used app-wide, so this catches missed callsites).
- [ ] **Step 5: Report.** (Commit on request: `feat(telemetry): per-source telemetry capability declarations`.)

---

### ~~Task 3: Pricing~~ — DELETED (shipped upstream 2026-08-30)

`RunwayRateSet.cacheWrite1hPerMTok` and `RunwayModelPrice.fast` / `rates(for:)` already exist, manifest and bundled table updated together. Task 6 consumes them.

---

### Task 4: Codex telemetry accumulator

**Files:**
- Create: `AgentSessions/Telemetry/CodexTelemetryAccumulator.swift`
- Test: `AgentSessionsTests/CodexTelemetryAccumulatorTests.swift`

**Interfaces:**
- Consumes: Task 1 types; `ClaudeRunwayLog.{jsonObject,double,date}` (provider-neutral despite the name — reuse rather than re-parse).
- Produces:

```swift
enum CodexTelemetryAccumulator {
    /// Generic over the sequence so the engine can stream a 256 MB rollout without
    /// materializing it; tests pass arrays unchanged.
    static func accumulate<S: Sequence<String>>(lines: S) -> SessionTelemetry
}
```

(`costEstimate` left nil — Task 7 fills it.)

**Rules:**
1. Read `payload = obj["payload"] ?? obj` on every line (old rollouts drop the wrapper).
2. `type == "turn_context"` → `payload.model` / `payload.effort`. **Carry-forward semantics: an absent, null, or empty value is NO OBSERVATION, never a change to nil.** Track model and effort independently; emit a `ConfigurationChange` only when a record carries a non-empty value differing from the last non-empty value seen for that field. Same discipline as [SessionIndexer.swift:2061](AgentSessions/Services/SessionIndexer.swift:2061), which guards `!turnModel.isEmpty`.
3. `initialConfiguration` = the first observed values, with **symmetric backfill**: whichever of model/effort is seen first, the other field is filled from the first record carrying it, **without** emitting a change. Provenance `.effectiveTurnContext`.
4. Usage family A — `payload.type == "token_count"`: prefer cumulative `info.total_token_usage`. Tolerate `info: null` (contributes nothing). Track `lastCumulative` per component (`input_tokens`, `cached_input_tokens`, `cache_write_input_tokens`, `output_tokens`, `reasoning_output_tokens`, `total_tokens`). Each record contributes component deltas vs `lastCumulative`, assigned to the slice for the *current* effective config. Fresh-input delta = Δinput − Δcached, clamped ≥ 0. Cache writes → `cacheWrite5mTokens`. Codex slices always use `speed: "standard"`.
5. **Epochs:** any cumulative component decreasing ⇒ new epoch: reset `lastCumulative` and add this record's values whole.
6. Usage family B — `turn.completed`/`turn_completed`/`turn-completed`, `usage` at `payload.usage` or `payload.data.usage`: **per-turn incremental — sum, don't delta.**
7. Authority: if any family-A cumulative record exists, family A is authoritative; family B only contributes its name to `usageFamilies`. `usageFamilyConflict = true` when both families report positive tokens. **Never sum both.**
8. Legacy total-only (only `total_tokens` parses) ⇒ `hasComponentBreakdown = false`, slices empty, `recordedTotalTokens` set.
9. `recordedTotalTokens` = sum over epochs of each epoch's final `total_tokens`.
10. Aborted turns (`turn_aborted`, fixture line 20) need no handling: family A's cumulative counters already include their tokens. Family B would undercount on aborts — accepted, family B is unobserved insurance.

- [ ] **Step 1: Write the failing tests** — inline JSONL copying the real shapes:

```swift
func testInitialConfigAndSingleChange()
func testRepeatedIdenticalContextNoChange()
func testTurnContextMissingEffortDoesNotEmitNilChange()      // carry-forward
func testTurnContextEmptyModelIsNotAnObservation()
func testEffortObservedBeforeModelBackfillsWithoutChange()   // symmetric backfill
func testPayloadlessLineReadsTopLevelFields()                // obj["payload"] ?? obj
func testCumulativeDeltasAttributedPerModel()                // 100/0/0/10 under A, switch to B, 250/0/0/40 → A{fresh 100,out 10}, B{fresh 150,out 30}
func testCumulativeResetStartsNewEpoch()
func testTokenCountWithNullInfoContributesNothing()          // fixture line 86
func testUsageBeforeAnyTurnContextLandsInNilModelSlice()
func testTurnCompletedFamilySummed()
func testBothFamiliesNeverDoubleCounted()                    // usageFamilyConflict true
func testLegacyTotalOnly()
func testReasoningSubsetNotAddedToTopLine()
func testFreshInputClampedWhenCachedExceedsInputDelta()
func testCodexSlicesAlwaysStandardSpeed()
func testAnchorLineAndObservedAtRecordedOnInitialConfig()    // assert exact index + date
```

- [ ] **Step 2: Run to verify it fails. Step 3: Implement (single pass, tolerant of non-JSON lines). Step 4: Run — PASS.**
- [ ] **Step 5: Report.** (Commit on request: `feat(telemetry): one-pass Codex configuration+usage accumulator`.)

---

### Task 5: Claude telemetry accumulator

**Files:**
- Create: `AgentSessions/Telemetry/ClaudeTelemetryAccumulator.swift`
- Test: `AgentSessionsTests/ClaudeTelemetryAccumulatorTests.swift`

**Interfaces:**
- Consumes: Task 1 types; `ClaudeRunwayLog.{jsonObject,double,date,cacheCreation}`; `RunwaySpeedTier(usageValue:)`.
- Produces: `enum ClaudeTelemetryAccumulator { static func accumulate<S: Sequence<String>>(lines: S) -> SessionTelemetry }`

**Rules — the four exclusion rules exist because the fixture itself triggers every one of them:**
1. Only top-level `"type":"assistant"` records contribute. Model = `message.model`; effort = the record's **top-level** `effort`.
2. **`model == "<synthetic>"` contributes nothing** — no config observation, no change, no tokens. These are error placeholders (fixture lines 47/97; 12 of 120 recent real files, always zero usage). Without this rule each one emits two phantom model changes.
3. **`isSidechain == true` records are excluded from the configuration timeline** (initial/current/changes) — they are nested subagents, on their own model. Their **usage still accumulates** into slices keyed by their own model/effort/speed; those tokens are real API spend.
4. **Carry-forward, identical to Task 4 rule 2:** model and effort are tracked independently; an absent or null field is no observation, never a change to nil. (10,466 of 47,671 real assistant records have no `effort`; 15 of 120 real files mix present and absent mid-stream.) Symmetric backfill for `initialConfiguration`, provenance `.inferredFirstObservation`; later differing non-empty values ⇒ `ConfigurationChange` with `.assistantRecord`.
5. **Dedup, exactly as [ClaudeRunwayTokenActivityParser.swift:437-449](AgentSessions/ClaudeStatus/ClaudeRunwayTokenActivityParser.swift:437) does it:** insert `message.id` into the seen-set whenever the record carries a `message.usage` object — **even if all counts are zero**; skip *usage* (but not config observation) for any record whose id is already in the set; records without a usage object never touch the set. Empirically first-seen-wins equals last-seen-wins: 24,246 duplicate ids across 120 files, zero with differing usage.
6. Usage (sum, never delta): fresh = `usage.input_tokens`; cacheRead = `usage.cache_read_input_tokens`; **5m/1h via `ClaudeRunwayLog.cacheCreation(usage:)`** (sub-object replaces the flat field; never sum); output = `usage.output_tokens`. Slice model = the record's own; **slice effort = the record's own when present, else the carried-forward effective effort** (nil only when none has ever been observed) — otherwise 10k+ real records fragment into a junk "unknown effort" row; slice speed = `RunwaySpeedTier(usageValue: usage["speed"]).rawValue`.
7. **`usageSummary` (do not leave nil — Task 7 gates cost on it):**
   `TelemetryUsageSummary(topLineTokens: Σ slices, hasComponentBreakdown: true iff ≥1 usage-carrying record was consumed, recordedTotalTokens: nil, usageFamilies: ["message.usage"], usageFamilyConflict: false)`. nil **only** when the file contains no assistant records at all.

- [ ] **Step 1: Write the failing tests:**

```swift
func testFirstObservedConfigIsInitial()                  // .inferredFirstObservation
func testSyntheticModelNeverEntersTimeline()             // fixture lines 47/97
func testSyntheticModelContributesNoTokens()
func testSidechainRecordsCountTokensButNotConfig()       // fixture lines 8/18/19
func testEffortObservedBeforeModelBackfillsWithoutChange()
func testAbsentEffortMidStreamEmitsNoChange()            // carry-forward
func testDuplicateMessageIDCountedOnce()
func testZeroTokenUsageRecordConsumesMessageID()         // id consumed before the >0 check
func testRecordWithoutUsageNeverConsumesMessageID()
func testFiveMinuteAndOneHourWritesKeptSeparate()
func testSubObjectReplacesFlatFieldNeverSums()           // flat 100 + split {5m:0,1h:100} → 100 total, all 1h
func testLegacyUndifferentiatedWriteCountsAs5m()
func testFastAndStandardAreSeparateSlices()
func testEffortAbsentRecordJoinsCarriedEffortSlice()     // no junk nil-effort row
func testMixedModelsProducePerModelSlices()
func testModelChangeRecordedOnce()
func testUsageSummaryHasComponentBreakdownWhenUsageSeen()
func testUsageSummaryNilOnlyWhenNoAssistantRecords()
```

- [ ] **Step 2: Run to verify it fails. Step 3: Implement. Step 4: Run — PASS.**
- [ ] **Step 5: Report.** (Commit on request: `feat(telemetry): one-pass Claude configuration+usage accumulator`.)

---

### Task 6: Fail-closed cost calculator

**Files:**
- Create: `AgentSessions/Telemetry/TelemetryCostCalculator.swift`
- Modify: `AgentSessions/CodexStatus/RunwayPriceTable.swift` — add a lock-guarded `var updatedDate: String { lock.lock(); defer { lock.unlock() }; return loadedUpdated }`. `loadedUpdated` is currently private with no accessor ([RunwayPriceTable.swift:115](AgentSessions/CodexStatus/RunwayPriceTable.swift:115)); the public surface is only `isEmpty` / `revision` / `price(forModel:)`.
- Test: `AgentSessionsTests/TelemetryCostCalculatorTests.swift`

**Interfaces:** `enum TelemetryCostCalculator { static func estimate(slices: [TelemetryUsageSlice], priceTable: RunwayPriceTable) -> TelemetryCostEstimate }`

**Rules:** for each **non-empty** slice, resolve `price(forModel:)` then `rates(for: RunwaySpeedTier(rawValue: slice.speed) ?? .standard)`, and sum
`fresh×input + cacheRead×cachedInput + write5m×cacheWrite + write1h×cacheWrite1h + output×output`, all ÷ 1_000_000.
**Do not call `RunwayRateSet.dollars(...)`** — its fallback chain is right for the live runway and wrong here.

Fail-closed triggers (each appends and forces `apiEquivalentUSD = nil`):
- nil model slug, or no price entry ⇒ `unpricedModels += [slug ?? "(unknown)"]`
- `rates(for:)` nil (a `fast` record on a model with no fast set) ⇒ `missingPriceComponents += ["\(slug):fast"]`
- positive `cacheWrite5mTokens` with nil `cacheWritePerMTok` ⇒ `"\(slug):cacheWrite5m"`; positive `cacheWrite1hTokens` with nil `cacheWrite1hPerMTok` ⇒ `"\(slug):cacheWrite1h"`

Empty/zero slices are skipped entirely — a dead unknown-model slice cannot poison the result. No slices at all ⇒ `apiEquivalentUSD = nil` with both arrays empty. Always stamp `priceTableUpdated`.

- [ ] **Step 1: Write the failing tests:** mixed-model session sums per slice (hand-computed); fast Opus 5 priced at the fast set (2× standard, **not** standard); fast slice on a model with no fast set ⇒ nil + `":fast"`; unknown model ⇒ nil + `unpricedModels`; positive 1h writes with nil 1h rate ⇒ nil + `":cacheWrite1h"`; a **zero-token** unknown-model slice does NOT poison; `priceTableUpdated` matches the loaded manifest. Build the table via the existing seam (`RunwayPriceTable(loadBundled:readCache:)`).
- [ ] **Step 2: Run to verify it fails. Step 3: Implement. Step 4: Run — PASS**, plus the existing runway `$` tests to prove the new accessor changed nothing.
- [ ] **Step 5: Report.** (Commit on request: `feat(telemetry): fail-closed api-equivalent cost calculator`.)

---

### Task 7: SessionTelemetryEngine (on-demand computation + cache)

**Files:**
- Create: `AgentSessions/Telemetry/SessionTelemetryEngine.swift`
- Test: `AgentSessionsTests/SessionTelemetryEngineTests.swift`

**Interfaces:**

```swift
/// On-demand telemetry for one session. Not stored on `Session`, not in SQLite,
/// not derived from hydrated events (both parsers truncate rawJSON).
///
/// Recompute is a FULL re-read of the file, so callers must not poll this on a
/// timer: a live session's signature changes on every append.
final class SessionTelemetryEngine {
    static let shared = SessionTelemetryEngine()
    /// nil when the source declares both configuration and tokens unavailable,
    /// or the file is unreadable. Does file IO + parsing off the caller's thread.
    func telemetry(for session: Session) async -> SessionTelemetry?
}
```

**Rules:**
1. Dispatch on `session.source`, **gated on the Task 2 capability rather than a hardcoded list** (so Plan C only edits descriptors): `.codex` → `CodexTelemetryAccumulator`, `.claude` → `ClaudeTelemetryAccumulator`, else nil.
2. Stream lines via `JSONLReader` into the generic `accumulate(lines:)` — **never materialize the file**. Real worst cases: Codex median 268 KB / p90 2.7 MB / **max 256 MB**; Claude median 860 KB / p90 7 MB / max 43 MB. Preserve raw line indices (no `omittingEmptySubsequences`) so `anchorLine` stays truthful. Parse at utility QoS.
3. Fill `costEstimate` via Task 6 only when the source's `cost` capability isn't `unavailable` **and** `usageSummary?.hasComponentBreakdown == true`.
4. **Cache keyed by `RunwayFileSignature.read(path:)` (mtime **and** size) plus `parserVersion`** — reuse the existing type ([CodexRunwayModel.swift:6](AgentSessions/CodexStatus/CodexRunwayModel.swift:6)). Size participation is not optional: [ClaudeRunwayParserTests.swift:885](AgentSessionsTests/ClaudeRunwayParserTests.swift:885) exists specifically to pin it. ~16-entry LRU, NSLock-guarded. A nil signature (missing/unstat-able file) bypasses the cache rather than serving stale data.
5. Expose an `internal var parseCount` probe for the cache tests.

- [ ] **Step 1: Write the failing tests:**

```swift
func testFirstCallParsesAndSecondCallIsCached()          // parseCount == 1
func testSizeChangeWithFixedMtimeRecomputes()            // the pinned lesson
func testMtimeChangeRecomputes()
func testUnsupportedSourceReturnsNil()                   // .qwen
func testUnreadableFileReturnsNil()
func testClaudeFixtureMatchesAccumulatorCalledDirectly()
func testClaudeSessionWithBreakdownGetsCostEstimate()    // guards the dead-cost-path bug
func testCodexLegacyTotalOnlySessionHasNoCostEstimate()
```

- [ ] **Step 2: Run to verify it fails. Step 3: Implement. Step 4: Run — PASS.**
- [ ] **Step 5: Report.** (Commit on request: `feat(telemetry): on-demand telemetry engine with signature cache`.)

---

### Task 8: Fixture integration + full verification

**Files:**
- Test: `AgentSessionsTests/SessionTelemetryFixtureTests.swift`

**The stage0 fixtures are trimmed and redacted** — they contain `effort: "[trimmed for fixture]"` and other placeholder strings. Pinning exact change counts on them encodes redaction artifacts as intent. So: **exact numbers are pinned by the inline-JSONL tests in Tasks 4–7; this task asserts invariants** on the real fixtures, plus the handful of exact values that are genuinely stable.

- [ ] **Step 1:** Write the integration tests. Invariants for both providers:
  - no `ConfigurationChange` has a nil `newValue` (carry-forward holds)
  - no configuration or change references `"<synthetic>"`
  - `initialConfiguration` is non-nil and its `anchorLine` is the first qualifying record's raw index
  - every slice's `topLineTokens` ≥ 0 and the summary equals the slice sum
  - `costEstimate` is either priced or names a cause (never nil USD with both arrays empty when slices are non-empty)
  - Claude: no sidechain record's model appears in the timeline; `usageSummary` non-nil with `hasComponentBreakdown == true`
  - Codex: `recordedTotalTokens == 16_422` (fixture-stable), 2 epochs
- [ ] **Step 2:** Run the new test files — PASS.
- [ ] **Step 3:** `./scripts/xcode_test_stable.sh` — 0 failures **and** the test count must not drop.
- [ ] **Step 4:** Debug build against default DerivedData (never the `xcodebuild test` derived-data path — launching that bundle yields a healthy-but-invisible process).
- [ ] **Step 5:** Append a dated `RepoHandover.md` entry: state, the deleted Task 3, the speed-tier requirement, the carry-forward/sidechain/synthetic rules and *why* (the fixture triggers all three), the `claude/cost-state` re-count trigger, Plan B/C pointers.
- [ ] **Step 6: Report.** (Commit on request.)

---

## Deliberately out of scope (follow-up plans)

- **Plan B — weekly quota attribution:** persist the samples `UsageLimitBurnRateTracker` already produces (provider/account scope, observedAt, remaining %, resetAt, source, freshness) in a **separate** store (not `session_meta`); attribute `quotaDrop × sessionTokens / allTrackedTokens` with same-reset + monotonic guards; Codex historical backfill from the `rate_limits` riding on `token_count` lines; Claude forward-only. Name: `estimatedWeeklyQuotaPercentagePoints`, always confidence-tagged.
- **Plan C — provider expansion:** Pi/OpenClaw/Copilot configuration timelines, Qwen/Kimi token records, Grok/fx audits. Descriptor edits + new accumulators only; engine dispatch is already capability-driven.
- **`claude/cost-state` adoption** — see §"Standing reference: the format tracker"; the re-count trigger is close.
- **Rendering:** all UI, deferred to a later session with owner input.
