# Runway Presentations — Phase 2 ($ Burn) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the runway's `$` presentation real — each active session's API-equivalent cost per hour (`$/h`), priced from a self-hosted, cached model price table.

**Architecture:** Extends Phase 1 (f4688f3b). Token parsers gain per-type counts + a per-session model slug; a shared `RunwayPriceTable` (bundled snapshot + read-only GitHub-Pages refresh) prices them; `dollarSnapshot` sums per-type deltas × per-type prices → `$/h`. `.dollar` resolves to `$/h` when the table is usable and every active model is priced, else snapshot-wide → token.

**Tech Stack:** Swift / SwiftUI / XCTest / URLSession. Build: `xcodebuild build -scheme AgentSessions -configuration Debug -derivedDataPath .deriveddata-run -destination 'platform=macOS'`. Full suite: `xcodebuild test -scheme AgentSessions -configuration Debug -derivedDataPath .deriveddata-test -destination 'platform=macOS'`.

## Global Constraints

- No behavior change unless `$` is selected; Phase 1's 5h/token/weekly and the `.fiveHour` default stay byte-equal.
- One snapshot → one `rateUnit`; `$` fallback to token is snapshot-wide per provider (never per-row).
- Network is a **read-only GET** of a public static file — no query params, no identifiers, no payload (same trust model as the Sparkle appcast). Bundled snapshot must make `$` work offline/first-launch.
- Pricing formula: `$ = (Δinput − Δcached)·pInput + Δcached·pCached + Δoutput·pOutput` (+ Claude `ΔcacheCreation·pCacheWrite`). **Reasoning is never priced** (subset of output). tk/h stays netted; `$/h` uses raw per-type deltas.
- Subset identities: Codex `total = input + output`, `cached_input ⊆ input`, `reasoning_output ⊆ output`; Claude `message.usage` is per-turn incremental (summed across a burst), with `input_tokens`, `output_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens`.
- Slug lookup is **longest-prefix** (Claude slugs are dated, e.g. `claude-sonnet-4-5-20250929`).
- Prices in USD per **million** tokens. Manifest with an unrecognized `version` → ignore, use bundled.
- TDD; frequent commits. Subagents never build/commit — ONE central verification in the main session (Task 10). Build `RunwayPriceTable` + `dollarSnapshot` (fixture-driven) BEFORE any UI wiring.

## File structure

- `AgentSessions/CodexStatus/RunwayPriceTable.swift` (new) — model→prices lookup, bundled load, fetch/cache, longest-prefix match. Shared lock-guarded singleton.
- `AgentSessions/Resources/prices.json` (new, bundled) — snapshot; also published to `docs/prices.json`.
- `AgentSessions/CodexStatus/CodexRunwayModel.swift` — `RunwayRateUnit.dollarsPerHour`; `RunwaySessionActivity` per-type + `modelSlug`; Codex parser per-type + model; `dollarSnapshot`; loader `$` branch; request.id price-version.
- `AgentSessions/ClaudeStatus/ClaudeRunwayTokenActivityParser.swift` — Claude per-type + model in the sample + `activity`.
- `AgentSessions/ClaudeStatus/ClaudeRunwaySnapshotLoader.swift` — `$` branch.
- `AgentSessions/Views/AgentCockpitHUDView.swift` — `$` rendering, `effectivePresentation` update, builder threading, review fixes #4/#5.
- `docs/PRIVACY.md`, `README.md` — privacy copy.

---

### Task 1: `RunwayRateUnit.dollarsPerHour` + rendering

**Files:** `CodexRunwayModel.swift` (enum); `AgentCockpitHUDView.swift` (`RunwayTimeFormatting.rate`, `HUDRunwayLoadBar.fillFraction`, `HUDRunwayLayout.rateWidth`); `AgentSessionsTests/CodexActiveSessionsRegistryTests.swift`.

**Interfaces:** Produces `RunwayRateUnit.dollarsPerHour`; `RunwayTimeFormatting.rate(_:unit:.dollarsPerHour:)` → `"$0.42/h"` / `"$1.2K/h"`.

- [ ] **Step 1: Failing test** (formatting is `private` — instead assert via a public seam is impossible; add the case and cover it indirectly in Task 6's dollarSnapshot + a manual check). Since `RunwayTimeFormatting` is file-private, this task has **no direct unit test**; its correctness is exercised by Task 6 (values) and visual QA (Task 10). Skip Step 1–2 for the formatter; the enum case is compiler-enforced across the two exhaustive switches.

- [ ] **Step 2: Add the case** to `RunwayRateUnit`:
```swift
    case dollarsPerHour
```

- [ ] **Step 3: Formatter** — in `RunwayTimeFormatting.rate` add:
```swift
        case .dollarsPerHour:
            guard confidence != .waiting else { return "$0/h" }
            guard confidence != .idle else { return "idle" }
            guard value.isFinite, value >= 0.005 else { return "flat" }
            if value >= 1000 { return String(format: "$%.1fK/h", value / 1000) }
            if value >= 100 { return String(format: "$%.0f/h", value) }
            return String(format: "$%.2f/h", value)
```

- [ ] **Step 4: Load bar** — in `HUDRunwayLoadBar.fillFraction` switch, add `.dollarsPerHour` to the relative-fill arm: `case .tokensPerHour, .weeklyPercentPerHour, .dollarsPerHour:`.

- [ ] **Step 5: Column width** — `HUDRunwayLayout.rateWidth(for:)` add `case .dollarsPerHour: return 72`.

- [ ] **Step 6: Build** to confirm exhaustive switches compile. Commit `feat(runway): dollarsPerHour rate unit + $/h rendering`.

---

### Task 2: `RunwaySessionActivity` gains per-type rates + model slug

**Files:** `CodexRunwayModel.swift` (`RunwaySessionActivity`); `AgentSessionsTests/…`.

**Interfaces:** Produces the extended activity struct consumed by Tasks 3, 4, 6:
```swift
struct RunwaySessionActivity: Equatable, Sendable {
    let identity: RunwaySessionIdentity
    let tokensPerSecond: Double          // existing (netted throughput for tk/h)
    let inputPerSecond: Double            // non-cached + cached input, per second
    let cachedInputPerSecond: Double
    let outputPerSecond: Double
    let cacheCreationPerSecond: Double    // Claude only; 0 for Codex
    let modelSlug: String?
    let sampleStart: Date
    let sampleEnd: Date
}
```

- [ ] **Step 1:** Add the four `*PerSecond` fields (default not allowed on `let` in memberwise use across call sites — instead update every `RunwaySessionActivity(...)` construction site). Grep: `grep -rn "RunwaySessionActivity(" AgentSessions AgentSessionsTests`.
- [ ] **Step 2:** For each existing construction (Codex `activity`, Claude `activity`, the path-merge in Codex `activity(identity:now:)`, and every test), pass the new fields — 0 for the ones not yet parsed (they get real values in Tasks 3/4). This keeps the build green with tk/h unchanged.
- [ ] **Step 3: Build** green. Commit `refactor(runway): RunwaySessionActivity carries per-type token rates + model slug`.

---

### Task 3: Codex per-type + model capture

**Files:** `CodexRunwayModel.swift` (`CodexRawTokenLine`, `CodexRunwayTokenActivitySample`, `parseRawLine`, `finalize`, `activity(identity:samples:now:)`, `totalTokens`/new `perTypeTokens`); `AgentSessionsTests/CodexUsageParserTests.swift`.

**Interfaces:** Consumes Task 2. Produces Codex activities with per-type `*PerSecond` (from cumulative deltas ÷ interval) + `modelSlug`.

- [ ] **Step 1:** Extend `CodexRawTokenLine` and `CodexRunwayTokenActivitySample` with cumulative `input`, `cachedInput`, `output` (Doubles) and `modelSlug: String?` alongside `totalTokens`.
- [ ] **Step 2:** In `parseRawLine`, parse from the same `payload`/`info`/`total_token_usage`/`usage` object: `input_tokens`, `cached_input_tokens`, `output_tokens` (reuse the existing key-walk); parse the model slug from `turn_context.payload.model` OR `payload.model` OR `obj["model"]` (whichever present). `finalize` copies them onto the sample.
- [ ] **Step 3:** In the private `activity(identity:samples:now:)`, when it finds the valid pair, also compute per-type per-second: `(current.input − previous.input)/elapsed` etc. (clamped ≥ 0), and carry `current.modelSlug`. `tokensPerSecond` stays the netted delta (unchanged).
- [ ] **Step 4: Failing test** using a fixture with two `token_count` lines carrying `total_token_usage {input, cached_input, output, total}` + `turn_context`; assert the activity's `inputPerSecond`/`cachedInputPerSecond`/`outputPerSecond`/`modelSlug`.
- [ ] **Step 5:** Implement; run — PASS. Commit `feat(runway): Codex per-type token + model-slug capture`.

---

### Task 4: Claude per-type + model capture

**Files:** `ClaudeRunwayTokenActivityParser.swift` (`ClaudeRunwayTokenActivitySample`, `parseLine`, `activity`); `AgentSessionsTests/ClaudeRunwayParserTests.swift`.

**Interfaces:** Consumes Task 2. Produces Claude activities with per-type `*PerSecond` (per-turn increments **summed** across the burst ÷ span) + `modelSlug`; `cacheCreationPerSecond` from `cache_creation_input_tokens`.

- [ ] **Step 1:** Extend `ClaudeRunwayTokenActivitySample` with incremental `input`, `output`, `cacheCreation`, `cacheRead` (Doubles) + `modelSlug: String?` (keep the existing weighted `tokens` for tk/h).
- [ ] **Step 2:** In `parseLine`, read `message.usage.{input_tokens, output_tokens, cache_creation_input_tokens, cache_read_input_tokens}` and `message.model`; keep the existing weighted `tokens = input + output + cache_creation + cacheReadWeight×cache_read`.
- [ ] **Step 3:** In `activity`, when summing the burst, also sum each per-type increment; per-second = sum ÷ span. `tokensPerSecond` (weighted) unchanged so tk/h is unchanged. `inputPerSecond` = (input including cache_read? No) — define **Claude `inputPerSecond` = fresh input only** (`input_tokens`), `cachedInputPerSecond` = `cache_read_input_tokens`, `outputPerSecond` = `output_tokens`, `cacheCreationPerSecond` = `cache_creation_input_tokens`. (So dollarSnapshot's `(Δinput − Δcached)` term uses fresh input directly for Claude — see Task 6 note.)
- [ ] **Step 4: Failing test** with two Claude usage lines; assert per-type per-second + `modelSlug`. Implement; PASS. Commit `feat(runway): Claude per-type token + model-slug capture`.

---

### Task 5: `RunwayPriceTable`

**Files:** Create `AgentSessions/CodexStatus/RunwayPriceTable.swift`, `AgentSessions/Resources/prices.json`, `docs/prices.json`; `AgentSessionsTests/RunwayPriceTableTests.swift`. (Add the new Swift file + resource to the Xcode project via `scripts/xcode_add_file.rb`.)

**Interfaces:** Produces:
```swift
struct RunwayModelPrice: Equatable, Sendable { let inputPerMTok, cachedInputPerMTok, outputPerMTok: Double; let cacheWritePerMTok: Double? }
final class RunwayPriceTable: @unchecked Sendable {
    static let shared = RunwayPriceTable()
    var version: Int { get }               // for request.id
    func price(forModel slug: String?) -> RunwayModelPrice?   // longest-prefix match
    func refreshInBackground()             // launch/daily, fire-and-forget
    #if DEBUG func loadForTesting(json: Data) #endif
}
```
Schema: `{ "version": 1, "updated": "…", "models": { "<slug>": { "inputPerMTok": 1.25, "cachedInputPerMTok": 0.125, "outputPerMTok": 10, "cacheWritePerMTok": 1.5625 } } }`.

- [ ] **Step 1: Failing tests** (`RunwayPriceTableTests`): bundled snapshot loads (non-empty); `price(forModel:)` exact hit; **longest-prefix** (`claude-sonnet-4-5-20250929` matches key `claude-sonnet-4-5`); unknown slug → nil; nil slug → nil; malformed JSON → keeps bundled (no crash); manifest `version: 999` (unrecognized) → keeps bundled.
- [ ] **Step 2:** Author `prices.json` with current OpenAI (gpt-5.x / o-series) and Anthropic (opus/sonnet/haiku) prices; copy to both `AgentSessions/Resources/prices.json` and `docs/prices.json`.
- [ ] **Step 3:** Implement load (bundled → Application-Support cache precedence), `price` (exact then longest-prefix over keys), version guard. Lock-guarded (`NSLock`, `@unchecked Sendable`, mirror `RunwayAggregateBurnHold`).
- [ ] **Step 4:** Implement `refreshInBackground()` — `URLSession` GET `https://jazzyalex.github.io/agent-sessions/prices.json`, ETag/Last-Modified conditional, ≤ once/day (persist last-fetch), write cache on 200 + valid version, bump `version` on change. Never blocks; failures are silent.
- [ ] **Step 5:** Call `RunwayPriceTable.shared.refreshInBackground()` once at app launch (near the Sparkle check in `AgentSessionsApp`).
- [ ] **Step 6:** Run — PASS. Commit `feat(runway): RunwayPriceTable (bundled + GitHub-Pages fetch, prefix match)`.

---

### Task 6: `dollarSnapshot`

**Files:** `CodexRunwayModel.swift` (`CodexRunwayCalculator.dollarSnapshot`); `AgentSessionsTests/CodexUsageParserTests.swift`.

**Interfaces:** Consumes Tasks 2–5. Produces `dollarSnapshot(baseline:activities:priceTable:maxRows:) -> CodexRunwaySnapshot?` — rows carry `$/h` in `displayRate`, ranked, overflow split; `nil` when no positive activity OR any active model is unpriced (→ loader falls back token snapshot-wide).

- [ ] **Step 1: Failing tests:** (a) two Codex activities with known per-type rates + a stub price table → expected `$/h` per row (compute by hand); (b) **non-proportionality**: a cache-heavy activity yields `$/h` that is NOT tk/h × constant (raw per-type vs netted); (c) an activity whose `modelSlug` is unpriced → `dollarSnapshot` returns nil.
- [ ] **Step 2: Implement:**
```swift
static func dollarSnapshot(baseline: RunwayProviderBaseline,
                           activities: [RunwaySessionActivity],
                           priceTable: RunwayPriceTable,
                           maxRows: Int) -> CodexRunwaySnapshot? {
    guard maxRows > 0 else { return nil }
    let positive = activities.filter { ($0.inputPerSecond + $0.outputPerSecond + $0.cacheCreationPerSecond) > 0 }
    guard !positive.isEmpty else { return nil }
    // Every active model must be priceable, else fall back snapshot-wide (P1).
    var priced: [(RunwaySessionActivity, Double)] = []
    for a in positive {
        guard let p = priceTable.price(forModel: a.modelSlug) else { return nil }
        let freshInput = max(0, a.inputPerSecond - a.cachedInputPerSecond)
        let perSec = freshInput * p.inputPerMTok / 1_000_000
            + a.cachedInputPerSecond * p.cachedInputPerMTok / 1_000_000
            + a.outputPerSecond * p.outputPerMTok / 1_000_000
            + a.cacheCreationPerSecond * (p.cacheWritePerMTok ?? p.inputPerMTok) / 1_000_000
        priced.append((a, perSec * 3600))   // $/h
    }
    let ranked = priced.sorted { rank($0) }   // by $/h desc, then isGoal, then name (mirror tokenSnapshot)
    let (visible, overflow) = RunwayOverflowRule.split(ranked, maxRows: maxRows)
    // rows: displayRate = $/h, deadline .unavailable, confidence .direct; burst summary sums $/h.
    …
    return CodexRunwaySnapshot(baseline: baseline, rows: rows, burstSummary: summary)
}
```
(Claude note: Task 4 sets `inputPerSecond = fresh input`, `cachedInputPerSecond = cache_read`, so `freshInput` = `inputPerSecond` for Claude; the `max(0, input − cached)` is a Codex-shape guard and a no-op for Claude — correct for both.)
- [ ] **Step 3:** Run — PASS. Commit `feat(runway): dollarSnapshot ($/h from per-type tokens × price table)`.

---

### Task 7: Resolve `.dollar` + thread through builders/loaders + request id

**Files:** `AgentCockpitHUDView.swift` (`effectivePresentation`, `request`/`claudeRequest`); `CodexRunwayModel.swift` (`CodexRunwaySnapshotLoader` + `CodexRunwaySnapshotRequest.id`); `ClaudeRunwaySnapshotLoader.swift`; tests.

**Interfaces:** `.dollar` → `.dollarsPerHour` when the price table is usable; loaders call `dollarSnapshot`, falling back to `tokenSnapshot` (baseline swapped to `.tokensPerHour`) when it returns nil.

- [ ] **Step 1:** `effectivePresentation` — replace the `.token, .dollar` arm; add a `dollarPriceable: Bool` param (builder passes `!RunwayPriceTable.shared.isEmpty`); `.dollar` → `.dollarsPerHour` if `dollarPriceable` else `.tokensPerHour`. Update the Phase-1 matrix test + add `.dollar` rows. **(Review fix #4)** drop the unused `source` param.
- [ ] **Step 2:** Builders (`request`, `claudeRequest`) — when `resolved.rateUnit == .dollarsPerHour`, build the active-window baseline with `rateUnit: .dollarsPerHour` (same fields as token; $ ignores run-out). **(Review fix #5)** wrap the `weekResetAt`/`weeklyRunout` compute in `if presentation == .weekly`.
- [ ] **Step 3:** `CodexRunwaySnapshotRequest.id` — append `String(RunwayPriceTable.shared.version)` when `rateUnit == .dollarsPerHour` (so a price refresh recomputes; and `$` vs token already differ by rateUnit — **review fix #3**).
- [ ] **Step 4:** Loaders (Codex + Claude) — add `case .dollarsPerHour:` → `dollarSnapshot(…, priceTable: .shared, …)` with the same swap-to-token fallback pattern as weekly (`effectiveBaseline = request.baseline.with(rateUnit: .tokensPerHour)`).
- [ ] **Step 5: Tests:** builder `.dollar` → `.dollarsPerHour` baseline when priceable; loader `$` branch produces `$/h` rows for a priced fixture and token rows for an unpriced one. Run — PASS. Commit `feat(runway): resolve $ presentation to $/h via price table (+ Phase 1 review fixes)`.

---

### Task 8: UI — real `$` option

**Files:** `AgentCockpitHUDView.swift` (`HUDRunwayPresentationPopover`, `runwayPresentationButton`).

- [ ] **Step 1:** `$` is now functional, so keep it in the picker (Phase 1 finding #1 resolved). Confirm the popover detail for `.dollar` reads "Estimated API-equivalent cost per hour" (already set). No code change beyond confirming `.dollar` renders `$/h`.
- [ ] **Step 2:** Deferred to Task 10 visual QA. Commit only if copy tweaks are needed.

---

### Task 9: Privacy copy

**Files:** `docs/PRIVACY.md`, `README.md`.

- [ ] **Step 1:** Add one line to the network-activity section: "an optional, read-only fetch of a public model-price list (no personal or session data is sent)" alongside Sparkle. Commit `docs: note the optional price-list fetch (privacy)`.

---

### Task 10: Central verification

- [ ] **Step 1:** Build `.deriveddata-run` → `BUILD SUCCEEDED`.
- [ ] **Step 2:** Full suite `.deriveddata-test` → 0 failures.
- [ ] **Step 3:** Confirm Phase 1 + v4.4 tests still pass (default/token/weekly unchanged).
- [ ] **Step 4:** Relaunch for visual QA: select `$`, confirm `$/h` per session; unprice a model locally → falls back to tk/h; offline → bundled prices still price.
- [ ] **Step 5:** Report GO/NO-GO.

## Self-Review

- **Spec coverage:** §3a per-type + formula → T2/T3/T4/T6; §3a `$` non-proportionality → T6; §4 manifest/fetch/cache/prefix/version → T5; §4 model-slug keying → T3/T4; §5 `$` fallback snapshot-wide → T6 (nil) + T7 (loader swap); §6 `$` rendering → T1; §7 privacy → T9. Phase-1 review #1/#3/#4/#5 → T7/T8. ✓
- **Placeholder scan:** `dollarSnapshot` ranking/summary elided with a "mirror tokenSnapshot" note — acceptable (repeats the exact Phase-1 pattern); everything else concrete.
- **Type consistency:** `RunwaySessionActivity` per-type field names (`inputPerSecond`/`cachedInputPerSecond`/`outputPerSecond`/`cacheCreationPerSecond`/`modelSlug`) stable T2→T3/T4→T6; `RunwayPriceTable.price(forModel:)`/`version`/`isEmpty` stable T5→T6/T7; `dollarSnapshot` signature stable T6→T7.
- **Risk:** Claude $ accuracy (T4 per-type semantics + T6 cache-write) is the crux — its fixture test (T4/T6) must use a real Claude `message.usage` shape.
