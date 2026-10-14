# Session Info prices for all agents — design

Date: 2026-10-13
Status: revision 3, after two external review rounds (ChatGPT GPT-5.6 Sol Extra High via
Repo MCP, verdict NO-SHIP on revision 1). Awaiting owner review.

## Goal

Session Info shows an API-equivalent dollar figure for every agent whose
sessions record priceable tokens. Today only Claude, Codex, Pi, and Copilot
show one.

Success: a session from OpenCode, OpenClaw, Hermes, Kimi, Cline, Qwen,
Antigravity, or DeepSeek Harness shows a cost when its model has a verified
price row and its usage evidence is request-granular. Otherwise it shows a
specific reason.

## Decisions (owner, 2026-10-13)

1. **API-equivalent only.** Cost = tokens × published list price. The cost an
   agent records for itself is not shown and not stored.
2. **Free routes use the base model's list price.** A free or promo route is
   priced at the paid model's published rate when that model has a row.
3. **Right or absent.** The existing `TelemetryCostCalculator` rule stays: any
   unpriceable self-owned contribution makes the whole figure unavailable.

Definition: **API-equivalent means the standard list rate.** These readers do
not observe a service tier and emit `speed = "standard-normalized"`. The figure
is not a route-equivalent price. The help text already says "published rates".

## Current state

- `TelemetryCostCalculator` prices `TelemetryUsageEvent`s against a
  `RunwayPriceSnapshot`. `SessionTelemetryEngine` runs it only when
  `capabilities.cost.isAvailable`, `usageSummary.unavailableReason == nil`, and
  `usageSummary.hasComponentBreakdown`.
- `docs/prices.json` (schema `version: 1`) and the bundled copy in
  `RunwayPriceTable.swift` hold Claude rows, GPT rows, and one special row,
  `codex-auto-review`.
- `price(forModel:)` matches exact, then longest prefix. Claude and GPT keys
  have suffix guards. **Any other key matches by bare prefix with no guard.**
  This logic exists twice: in `RunwayPriceSnapshot` and in `RunwayPriceTable`.
- A manifest is accepted when `updated >= loadedUpdated`. `updated` is a
  calendar date, so it cannot advance twice in one day.
- The semantic `revision` hashes the whole manifest minus `_note` and
  `updated`. `WeeklyQuotaCalibrationScope.priceRevision` uses it, so any row
  edit invalidates Claude and Codex weekly calibration.
- The telemetry cache identity is `revision` + `updated` +
  `manifestFingerprint` (`TelemetryPricingIdentity`).

## Scope

| Agent | Change |
|---|---|
| OpenCode, OpenClaw, Cline, DeepSeek Harness | `cost: .partial(reason)` after the reader audit in §6 |
| Hermes | `cost: .partial(reason)`; models with a long-context tier stay unpriced (§6.1) |
| Kimi | `cost: .partial(reason)`; priced from turn records only (§6.3) |
| Qwen | `cost: .partial(reason)`; the opaque `coder-model` alias stays unpriced |
| Antigravity | Model capture, per-event model, index repair (§8), then `cost: .partial(reason)` |
| Droid, fx | No change. Aggregate input with no cache split would overstate cost |
| Cursor, Devin, Grok | No change. No token counts on disk |
| Pi, Copilot | No descriptor change. They gain the new rows and the resolver |

Out of scope: native recorded cost, Quota Meter, Runway burn math. Weekly
quota is touched only by §5, to stop this change from invalidating it.

## Evidence: model strings in the owner's index (2026-10-13)

Counts are sessions. The reviewer could not see the index, so these counts are
unverified by review.

- Provider prefix: `anthropic/claude-sonnet-5`, `openai/gpt-5.5`,
  `z-ai/glm-5.3-flash`, `poolside/laguna-s-2.1:free`.
- Free markers: `muse-spark-1.3-contributor-free` (59),
  `cline-free/deepseek-v4.1-flash` (5), `minimax-m2.5-free`, `:free` suffix.
- Spelling variant: `claude-haiku-4.5`.
- Display name: `Gemini 3.5 Flash (Medium)`, `Claude Sonnet 4.6 (Thinking)`.
- Stealth or unpublished: `big-pickle` (49), `x-preview-f-free`,
  `gateway-injected`, `coder-model`.
- Local: `qwen3.5-9b` (84, Hermes).
- Already matching existing rows: `gpt-5.4` (OpenClaw 53, Hermes 13),
  `gpt-5.5`, `gpt-5.4-mini`, `claude-sonnet-4-6`.
- Variant that must NOT inherit a base price: `kimi-k2.7-code-v2`
  (`ExpandedTelemetryProviderTests.swift:1574`).

## Design

### 1. `ModelPriceKeyResolver`

New file `AgentSessions/Telemetry/ModelPriceKeyResolver.swift`. Pure, no I/O.

```swift
struct ResolvedPriceKey: Equatable, Sendable {
    let key: String          // candidate key for RunwayPriceSnapshot
    let viaFreeRoute: Bool   // a free marker was present on the raw string
}
enum ModelPriceKeyResolver {
    static func resolve(_ raw: String?, aliases: [String: String]) -> ResolvedPriceKey?
}
```

One ordered pipeline. Each step is a table. Free-route detection is separate
from key resolution, so no later step can erase it.

1. Trim and lowercase. Return nil for empty input.
2. **Reasoning suffix.** Remove one trailing parenthetical only when its content
   is in a fixed list: `minimal`, `low`, `medium`, `high`, `xhigh`,
   `thinking`. Any other parenthetical stays.
3. **Free route.** Set `viaFreeRoute` and strip when the string has the prefix
   `cline-free/`, or one trailing `:free`, `-contributor-free`, or `-free`.
4. **Provider prefix.** If exactly one `/` remains, drop the part before it only
   when it is in a fixed allowlist (`anthropic`, `openai`, `google`, `z-ai`,
   `moonshotai`, `deepseek`, `minimax`, `x-ai`, `qwen`, `meta`, `opencode`,
   `openrouter`, `poolside`). An unknown prefix leaves the string unchanged.
5. **Alias.** One lookup of the normalized string in `aliases`.
6. **Claude dot variant.** For a `claude-` slug, replace `.` between two digits
   with `-`.

The resolver never guesses. A string no step recognizes passes through
unchanged and the snapshot lookup decides.

### 2. Strict matching for non-Claude, non-GPT keys

`price(forModel:)` keeps its Claude and GPT rules. For every other key, a key
matches a slug only when the slug equals the key, or equals the key plus
`-YYYYMMDD` or `-YYYY-MM-DD`. This applies to the existing `codex-auto-review`
row too; a regression test pins its behavior.

The duplicate matcher in `RunwayPriceTable` is removed; it calls the snapshot
implementation.

`RunwayPriceSnapshot` gains:

```swift
func resolvedPrice(forModel raw: String?) -> (price: RunwayModelPrice, viaFreeRoute: Bool)?
```

It tries the raw slug with `price(forModel:)` first, then the resolved key.
Every session that prices today keeps the same result.

### 3. Manifest v2: a separate file that shipped clients never read

Shipped clients use bare-prefix matching and accept any schema-v1 manifest.
A new `kimi-k2.7-code` row served to them would price `kimi-k2.7-code-v2` at
the base rate. No key-naming rule can prevent that, because the victim slug is
not a manifest key. So new rows never reach a v1 client.

- **`docs/prices.json` stays schema v1.** It keeps only the Claude, GPT, and
  `codex-auto-review` rows. It stays maintained for shipped clients.
- **`docs/prices-v2.json` is new, `version: 2`.** It holds every row plus:
  - `"sequence": <integer>` — strictly increases on every edit.
  - `"aliases": { "<normalized string>": "<models key>" }` — decoding drops
    an alias whose target is missing.
- **Acceptance rule (v2):** adopt a manifest when its `sequence` is greater
  than the loaded one. On equal `sequence` the loaded table stays. So a
  corrected bundle is never shadowed by an older cache from the same day.

**Lifecycle contract**

| | v1 clients (5.5.2 and older) | v2 clients (the release that ships this change, and later) |
|---|---|---|
| Fetch URL | `https://jazzyalex.github.io/agent-sessions/prices.json` | `https://jazzyalex.github.io/agent-sessions/prices-v2.json` |
| Cache file | `~/Library/Application Support/AgentSessions/prices.json` | `~/Library/Application Support/AgentSessions/prices-v2.json` |
| Accepted `version` | 1 | 2 only |
| Bundled table | v1 | v2 |

- A v2 client has exactly one accepted schema: `supportedVersion = 2`. The
  decoder rejects `version: 1`. So a v1 document can never become the
  resolver source, whether it arrives from the network, a cache file, or a
  misconfigured URL. A test feeds the real `docs/prices.json` to the v2
  decoder and expects rejection.
- A v2 client never reads, writes, or deletes the v1 cache file. A downgrade
  to a v1 build finds its own cache untouched.
- If v2 fetch or decode fails, the client keeps its bundled v2 table. There is
  no fallback to v1.
- **Retirement of `docs/prices.json`.** Shipped v1 clients keep working
  without it, because they fall back to their bundled table. The file is
  removed, in its own change, when both hold: two feature releases have
  shipped with v2, and at least 90 days have passed since the first v2
  release. Until then every Claude or GPT rate correction is made in both
  files.

**Guards**

- The bundled table equals `docs/prices-v2.json`.
- `sequence` in the repo is greater than the last released value.
- Shared rows are compared **semantically, not by bytes**: for every key in
  v1, the decoded `RunwayModelPrice` in v1 equals the one in v2 (standard,
  fast, long-context, geo multiplier).
- Resolution parity: for every currently supported Claude and GPT form — each
  exact key, each dated alias form, and each generic-family version the
  matcher accepts — the v1 table and the v2 table return identical rates. The
  test enumerates the forms from the matcher's own version lists, so a new
  form cannot be added without being covered.

### 4. New price rows (v2 only)

Rule: **the model vendor's first-party list price**, whatever provider routed
the request. A model with no first-party public API price gets no row.

Candidate families: Gemini Flash 3.5–3.8, GLM 4.7 and 5.3 Flash, MiniMax M2.1
and M2.5, Kimi K2.7 Code, DeepSeek Flash / v4.1 Flash, Grok 4.6 and Grok Code,
Muse Spark 1.3.

Per row, the implementer must:

- Read the rate from the vendor's own pricing page on the day of the change.
  No rate comes from memory, an aggregator, or another agent's config.
- Record the source host and UTC date in `_note`.
- Set `cacheWritePerMTok: null` when the vendor publishes no cache-write rate.
- Add `longContext` when the vendor publishes a threshold tier.
- Skip the row and list it under Follow-up when the vendor page is ambiguous
  about cached-input price.

### 5. Provider-scoped price revision for weekly calibration

Adding a Gemini row must not discard Claude or Codex calibration.

`RunwayPriceSnapshot` gains `rateRevision(forProvider:)`.

**What hashes in.** The canonical, key-sorted JSON of the provider's own rows,
and nothing else:

- Claude: every `models` entry whose key starts with `claude-`.
- Codex: every `models` entry whose key starts with `gpt-` or `codex-`.
- Per entry: the key and all rate-bearing fields (standard rates, `fast`,
  `longContext`, `inferenceGeoUSMultiplier`).

**What does not hash in.** `version`, `sequence`, `updated`, `_note`,
`aliases`, and every row of another vendor.

**Consequences, each with a direct regression test:**

| Edit | Claude revision | Codex revision |
|---|---|---|
| Add or change a Gemini / Kimi / GLM row | unchanged | unchanged |
| Add, change, or remove any alias | unchanged | unchanged |
| Bump `sequence` or `_note` only | unchanged | unchanged |
| Change a `claude-*` rate, or add a `claude-*` row | **changes** | unchanged |
| Change a `gpt-*` or `codex-*` rate, or add such a row | unchanged | **changes** |

An alias that points a foreign string at a `claude-*` row does not move the
Claude revision. Calibration learns from Claude Code and Codex sessions, whose
slugs match rows directly; aliases cannot change their rates.

- `WeeklyQuotaCalibrationScope.priceRevision` and the default
  `priceRevisionProvider` in `WeeklyQuotaCalibration` use the provider
  revision. Every other `priceRevision` call site is checked in the plan.
- The global `revision` stays as the telemetry cache identity and includes
  `aliases`.
- **Intentional one-time reset.** The stored value's formula changes, so the
  first launch after the upgrade re-learns weekly calibration once. A test
  pins this: a calibration saved under the old global revision is treated as
  incompatible, and a second launch on the same manifest keeps it.

### 6. Reader rules: what may carry a price

**Priceability provenance contract.** Four values are not optional telemetry.
Each is **required evidence** whenever the selected rate row needs it. When
the evidence is absent the event is unpriced. The calculator never infers,
defaults, or borrows a value to produce a figure.

| Evidence | Required when | Must come from | If absent |
|---|---|---|---|
| Model | Always | The usage record itself, or a model-selection record earlier in the same ordered stream | Unpriced: `(unknown)`. Never session metadata or "current model" |
| `contextInputTokens` | The row has a `longContext` tier | One request. Never a sum over requests | Unpriced: `<model>:contextInputTokens` |
| Cache-write TTL | The event has cache-write tokens and the row prices 5-minute and 1-hour writes differently | A TTL field on the record, or a source whose TTL is proven (`cacheWriteTTLVerified`) | Unpriced: `<model>:cacheWriteTTL` |
| Speed tier | The row has a `fast` rate set | An observed tier, or the explicit `standard-normalized` declaration that this source is priced at the standard list rate by definition | Unpriced: `<model>:<tier>`. `unknown` never maps to standard |

The reader decides what evidence exists; the calculator decides whether it is
enough. A reader must not fill a field to make a session priceable. The plan
audits every enabled reader against this table before its descriptor flips;
the confirmed violations are below.

**6.1 Hermes.** `session_model_usage` is a per-model rollup, emitted as one
event. Two 150K requests become one 300K "event" and would be billed at the
long-context tier. Rollup events set `contextInputTokens: nil`. The calculator
then refuses any model that has a `longContext` tier (`gpt-5.4`, `gpt-5.5`) and
still prices models without one (`gpt-5.4-mini`, Claude Sonnet). Whether
auxiliary rows such as `task = "vision"` are session-owned stays as it is
today; the plan checks the upstream schema before the descriptor flips.

**6.2 OpenCode.** The reader stamps `row.model ?? metadataModel` on the usage
event. Session metadata holds the current model, so an older row without its
own model would be priced at a later model. Price-bearing events use
`row.model` only. Configuration display keeps the metadata fallback.

**6.3 Kimi.** When no turn records exist the reader falls back to one
`usage.record.session` summary event, stamped with the currently active model
and a whole-session context total. That is unsafe after a model change and for
tier selection. Cost is computed from the turn family only.

**6.4 Cost gate.** `TelemetryUsageSummary` gains
`costUnavailableReason: String?`. The engine's pricing gate requires it to be
nil, and `costValue` shows it. Kimi sets it when it used the session-summary
fallback. Token display is unaffected.

**6.5 Cache-write TTL.** OpenCode, Hermes, Kimi, Cline, and DeepSeek Harness
put a generic cache-write count in `cacheWrite5mTokens`. Claude prices 5-minute
and 1-hour writes differently. `SessionSourceDescriptor` gains
`cacheWriteTTLVerified: Bool`, default false for these sources. When it is
false, the event has cache-write tokens, and the price row has a distinct
`cacheWrite1hPerMTok`, the calculator reports the missing component
`<model>:cacheWriteTTL` and gives no figure. A source flips to true only with
upstream format evidence cited in the descriptor comment.

### 7. Calculator, estimate, presentation

- `TelemetryCostCalculator` calls `snapshot.resolvedPrice(forModel:)` in both
  the event path and the slice path.
- `TelemetryCostEstimate` gains `freeRouteModels: [String]` (raw slugs).
  Decoding defaults a missing field to `[]`.
- `unpricedModels` keeps reporting the **raw** slug.
- `costValue`: when `freeRouteModels` is non-empty the help text adds "List
  price. This session ran on a free route." A small classifier turns an
  unpriced raw slug into one of: local model, unpublished or stealth model, no
  price entry. No layout change.
- Each enabled descriptor sets `cost: .partial("models without a published
  first-party price are not estimated")`, extended per agent where §6 adds a
  limit.

### 8. Antigravity

Real record shape (`Resources/Fixtures/stage0/agents/antigravity/cli_small.jsonl`):
the model selection is **not** its own record. It is a `<USER_SETTINGS_CHANGE>`
block embedded in the `content` of a top-level `USER_INPUT` record.

1. **One shared parser.** A single function extracts the new model from that
   embedded block. Its capture stops at the first period followed by
   whitespace, a tag, or end of string. `Gemini 3.5 Flash (Medium)` survives;
   trailing prompt text does not.
2. **Telemetry.** `AntigravityTelemetryAccumulator` currently drops every line
   that is not a `PLANNER_RESPONSE`. It gains a `USER_INPUT` branch that runs
   the shared parser and updates the active model in file order. Each
   `PLANNER_RESPONSE` event is stamped with the model in force. Events before
   the first observed selection stay `nil` and unpriced.
3. **Session row.** `AntigravityTranscriptParser` sets the model only while it
   is nil, so a later switch is lost. `Session.model` is defined as the
   **current** (last observed) model, matching the descriptor's wording, and
   the parser updates it on every selection.
4. **Index repair.** There is no session-parser version for Antigravity, and
   the indexer skips hydrated rows whose mtime and size are unchanged. Bumping
   `SessionTelemetry.parserVersion` (14 → 15) recomputes telemetry only. The
   corrupted `session_meta.model` values need an explicit one-time reparse of
   Antigravity sessions. The plan must use the indexer's existing invalidation
   path if one exists, or add a stored per-source parser generation that the
   skip check compares. No manual database edit.

## Compatibility

- Shipped clients keep reading `docs/prices.json`, which gets no new vendor
  rows. Their behavior does not change.
- Cached estimates: the pricing identity changes, so the engine reprices
  through the existing path.
- `index.db`: no schema change. Antigravity rows are rewritten by reparse.

## Tests

Regressions. Each must fail on the pre-change code:

- A v1-style bare-prefix lookup prices `kimi-k2.7-code-v2` from a
  `kimi-k2.7-code` row; the new matcher refuses it.
- Hermes: two short requests rolled up above the threshold yield no figure,
  never a long-tier figure.
- OpenCode: after a model change, an older usage row with no model is unpriced.
- Kimi: the session-summary fallback yields no figure and a stated reason.
- Antigravity: capture stops at the sentence end; a mid-session switch splits
  cost across two models; `Session.model` is the last model.
- Manifest: equal `sequence` with a different fingerprint keeps the bundled
  table.
- Calibration: a non-Claude row edit leaves the Claude rate revision unchanged.
- Cache-write TTL: an unverified source with Claude cache writes yields no
  figure and names `cacheWriteTTL`.
- Resolver: one case per string in the Evidence section, including
  `viaFreeRoute` surviving an alias hit, plus negatives (unknown prefix,
  `claude-sonnet-5-preview`, arbitrary parenthetical, empty).
- Calculator: a free-route session yields a figure and `freeRouteModels`; a
  mixed session with one stealth model yields no figure and names it.
- One priced fixture per enabled agent.

- Manifest lifecycle: the v2 decoder rejects the real `docs/prices.json`; a v2
  client leaves the v1 cache file untouched.
- Rate revision: one test per row of the table in §5, plus the one-time reset.

Data guards. These can pass before the change and do not count as regressions:
bundled equals `prices-v2.json`; shared v1 and v2 rows are semantically equal;
v1 and v2 resolve every supported Claude and GPT form to identical rates;
every alias target exists; `codex-auto-review` matching is pinned.

## Risks

- **Wrong rate published.** First-party source per row, dated; v2 can be
  corrected without a release, and `sequence` makes the correction win.
- **A reader not yet audited breaks the §6 rule.** No descriptor flips until
  its reader is checked against one real session.
- **Two manifests drift.** The shared-row guard test fails the build.
- **Free-route figure misread as a charge.** The "API-equivalent" label plus
  the new help line.

## Follow-up, not in this change

- Droid and fx, if either starts recording a cache split.
- Qwen `coder-model`, if Qwen documents what it routes to.
- Hermes per-request usage, which would restore `gpt-5.4` and `gpt-5.5`.
- Retiring `docs/prices.json` once v1 clients are gone.
- Showing native recorded cost.
- Skipped price rows (vendor pages read 2026-10-14):
  - `gemini-3.5-flash`, `gemini-3.7-flash`: Google publishes no price for these
    ids. Its deprecations page routes them to `gemini-3.6-flash` and
    `gemini-3.8-flash`.
  - `deepseek-flash` / `deepseek-v4.1-flash`: DeepSeek prices by time of day
    (peak and off-peak), and the schema cannot express that.
    `deepseek-v4.1-flash` is a model version name, not an API id.
  - `grok-code`: not an xAI API id. Only `grok-code-fast-1` and its aliases
    exist.
- Gemini 3.6 Flash and 3.8 Flash rates are published as valid through
  2026-12-31. From 2027-01-01 they double to $1.50 / $0.15 / $7.50. On
  2027-01-01, update both manifests and raise `sequence`.
- Muse Spark: `muse-spark-1.3-contributor-free` is priced at the Standard rate,
  as in the resolver example. Meta publishes `muse-spark-1.3-contributor` at
  $0.10 / $0.002 / $0.20, and `cline-free/muse-spark-1.3-contributor` stays
  unpriced. The owner decides which rate a contributor route uses.
