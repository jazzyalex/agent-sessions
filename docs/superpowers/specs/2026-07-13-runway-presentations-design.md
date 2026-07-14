# Quota Meter — Selectable Session Runway Presentations

Date: 2026-07-13
Status: Design — reviewed by Fable (GO-WITH-CHANGES, incorporated). Pending user sign-off.
Related: `2026-07-13-codex-usage-window-classification-design.md` (v4.4 shipped the
`RunwayRateUnit` + token-mode primitives this builds on)

## 1. Intent

The Quota Meter's Session Runway shows one burn rate per active session. Today it
shows either the 5h `m/h` yardstick or (Codex, 5h dropped) token throughput `tk/h`.
This feature lets the user pick, from a QM-toolbar control, which of **four
presentations** the runway rows report:

1. **5h burn** — `m/h` against the 5h window (today's default yardstick).
2. **Token burn** — `tk/h` per-session token throughput (shipped in v4.4).
3. **$ burn** — API-equivalent value `$/h` (tokens × published API prices). ROI
   framing: "what this usage would cost on the API." Most QM users are on flat
   subscription plans, so this is explicitly an *estimate*, not a bill.
4. **Weekly burn** — per-session **share of the weekly average burn**, `%/h`
   (token-share × smoothed weekly average-burn). Honest label: historical share,
   not instantaneous pace (see §3b).

Selection is **global** across both providers. Each provider renders the chosen
presentation and falls back **snapshot-wide** (whole provider, one unit) where a
window/data isn't available, so a row never shows a dead or wrong number.

Non-goals: changing the 5h/weekly limit *lines* (only the runway rows); real
per-account billing; a live pricing API; per-provider independent selection
(declined); showing all 4 at once.

## 2. Presentation model & selection

- New `enum RunwayPresentation: String, CaseIterable { case fiveHour, token, dollar, weekly }`
  in `UsageDisplayMode.swift` (beside `QuotaMeterRunwayVisibility`), with
  `storageKey = PreferencesKey.quotaMeterRunwayPresentation` and `current(raw:)`.
- New `PreferencesKey.quotaMeterRunwayPresentation` in `PreferencesConstants.swift`.
- Default `.fiveHour` — with no user change, behavior is **exactly v4.4** (5h `m/h`,
  auto-→`tk/h` when Codex's 5h window is dropped). `RunwayProviderBaseline.init`
  already derives `rateUnit` from `windowMinutes`; `.fiveHour` is "keep deriving."
  Purely additive; no regression.
- **Selection control**: a QM-toolbar control matching the existing
  `cockpitModePicker` ("Meter") pill/popover style, offering the 4 options (compact
  labels `5h` · `tk` · `$` · `Wk`; full names + one-line help in the popover — the
  weekly help states "share of average weekly burn"). Bound via `@AppStorage`. Shown
  only when the runway is visible.

## 3. Architecture (Approach A — compute-selected)

The selected `RunwayPresentation` maps to a `(rateUnit, window)` on the request;
switching rebuilds the request → the loader computes only the selected presentation.

- Extend `RunwayRateUnit` to `{ quotaMinutesPerHour, tokensPerHour, dollarsPerHour, weeklyPercentPerHour }`.
  Both exhaustive switches over it (`HUDRunwayLoadBar.fillFraction`,
  `RunwayTimeFormatting.rate`) get new cases compiler-enforced. **`HUDRunwayLayout.rateWidth(for:)`
  is an `==` check, not a switch — must be updated manually for the 2 new cases.**
- **`effectivePresentation(preferred:provider:state:) -> (rateUnit, windowMinutes)`**
  — a pure, unit-tested function in `HUDRunwayRequestBuilder` implementing §5.
- `HUDRunwayRequestBuilder.request`/`.claudeRequest` gain a `presentation:` input;
  both call-site pairs pass the pref. Both builder signatures widen to always
  receive the **weekly** window fields (`weekRemainingPercent`/`weekResetText`;
  Claude `weekAllModels*`) so weekly can be computed even while the 5h window is
  present.
- **`CodexRunwaySnapshotRequest.id` must include the resolved `rateUnit` + the price-
  table version** (today it includes neither `rateUnit` nor `windowMinutes`), so a
  presentation switch or a price refresh refires `.task(id:)`. The price table is
  **not** carried on the request (it's Equatable/Sendable/id-hashed) — the loader
  reads a shared lock-guarded `RunwayPriceTable` singleton (the `RunwayAggregateBurnHold`
  house pattern); the id carries only the table *version*.
- **Rename `quotaMinutesPerHour` → `displayRate`** on both `RunwayPauseImpactRow`
  **and `RunwayShortBurstSummary`** (the field now carries m/h, tk/h, $/h, or %/h per
  `baseline.rateUnit`). Also rename the `HUDRunwayLoadBar` param. Mechanical, all
  readers found (calculator, `withPendingRows`, panel, `maxQuotaMinutesPerHour`,
  3 test files); no dynamic access. **Invariant preserved: one snapshot → one unit**
  (max-fill scaling and burst-summary sums stay valid only because of this — see §5).

### 3a. Token-family: token & $ (shared parse)

- Token mode unchanged from v4.4 (`tokenSnapshot`, netted `tk/h`).
- **$ needs per-type deltas.** Extend the cached line types **`CodexRawTokenLine`**
  (Codex) and the Claude equivalent, plus the sample types and `finalize`, to carry
  per-type cumulative counts. Subset identities (confirmed by the repo's own fixture):
  `total = input + output`; `cached_input ⊆ input`; `reasoning_output ⊆ output`;
  Claude adds `cache_creation_input_tokens` (billed at a premium) and
  `cache_read_input_tokens`.
- **Pricing formula (per session, per interval Δ):**
  `$ = (Δinput − Δcached)·pInput + Δcached·pCached + Δoutput·pOutput` (+ Claude
  `ΔcacheCreation·pCacheWrite`). **Reasoning is captured for display only, never
  priced** (it's a subset of output). Adding-cache-not-netting is deliberate: cache
  reads cost real API money.
- **tk/h vs $/h are intentionally non-proportional** for cache-heavy sessions: tk/h
  stays *netted* (`nettedTotal`, a throughput-honesty measure — excludes re-sent
  cache); $/h uses *raw* per-type deltas (cache reads/writes cost money). Write this
  down; pin it with one test (same fixture, both modes, different results).
- Claude specifics (P4): the current Claude sample carries a single *weighted* value
  (`input + output + cache_creation + 0.10×cache_read`) — an attribution heuristic,
  not a token count. Define **Claude tk/h = input + output + cache_creation** (cache
  reads excluded, paralleling Codex netting); $/h prices all four types. The
  burst-summation and provisional single-turn paths (`pathActivity`) must sum
  per-type alongside the weighted total.
- `CodexRunwayCalculator.dollarSnapshot(baseline:activities:priceTable:maxRows:)`:
  per session rate = Σ(per-type token/sec × per-type price) → `$/h`; ranked/split
  like `tokenSnapshot`.

### 3b. Percent-family: 5h & weekly

- 5h burn unchanged from v4.4 (`percentPerSecond × 5h window → m/h`).
- Weekly burn: provider weekly average-burn (`averageBurnRunout` on the weekly
  window — smoothed; elapsed floor `windowLength/30 ≈ 5.6h` keeps it coarse-counter-
  safe) attributed per session by token share → weekly `%/h`. Sustainable ≈
  `0.6%/h`. It does **not** touch the noisy integer-tick per-session weekly burns
  that v4.4 refused to use.
- **Honest semantics (P6):** this is "this session's share of the week's *average*
  drain," not its instantaneous pace — stable *because* historical. A burst in a
  quiet week under-reads; a quiet session after a heavy week over-reads. Label it as
  such in the control's help; pin a test that a burst in an idle week does not spike.
- **Dead-number fallback (P6):** fresh weekly window (`used% == 0` or
  `averageBurnRunout` nil) → weekly average unmeasurable → the provider's snapshot
  falls back to `tk/h` (snapshot-wide) rather than every row reading `0.0%/h`.

## 4. Price manifest (Phase 2 only — for $ burn)

- **Source**: self-hosted `prices.json` on GitHub Pages next to `appcast.xml`
  (`jazzyalex.github.io/agent-sessions/prices.json`). Schema:
  `{ version, updated, models: { "<slug>": { inputPerMTok, cachedInputPerMTok, outputPerMTok, cacheWritePerMTok? } } }`
  USD. **Unrecognized `version` → ignore the file, use bundled** (schema-change
  poison-pill guard).
- **Fetch**: read-only GET on launch, ≤ once/day; **no user data sent** (same trust
  model as the Sparkle appcast check — not telemetry). Fire-and-forget, decoupled
  from the runway loader. Cached to Application Support (timestamp/ETag).
- **Fallback**: bundled `prices.json` snapshot in the app bundle. Resolution: fresh
  cache → bundled. Never blocks the runway.
- **Model keying (P2)**: capture the per-session **model slug** in the token-activity
  parsers' cached line types — Codex `turn_context.payload.model`, Claude
  `message.model` (both already parsed elsewhere in the app). Resolve per session as
  latest-seen; then provider-level default slug; then `tk/h` (snapshot-wide per §5).
  **Longest-prefix matching** in `RunwayPriceTable` (Claude slugs are dated, e.g.
  `claude-sonnet-4-5-20250929`, so exact-key lookup misses).
- **Component**: `RunwayPriceTable` (load/cache/fetch/lookup + prefix match),
  isolated, lock-guarded shared singleton, unit-tested independently.
- **Maintenance**: edit `docs/prices.json` + commit — no app release. Keep the
  bundled snapshot roughly in sync at release time.

## 5. Fallback resolution (snapshot-wide per provider)

`effectivePresentation` resolves the preferred presentation against provider+state.
**Fallback is snapshot-wide** — if a provider can't render the picked unit, its
whole runway renders the fallback unit that cycle (preserving one-snapshot-one-unit):

| Preferred | Codex 5h present | Codex 5h dropped | Claude |
|---|---|---|---|
| 5h | m/h (5h) | → tk/h | m/h (session) |
| Tokens | tk/h | tk/h | tk/h |
| $ | $/h (→ tk/h if any active model unpriced / table unusable) | $/h (→ tk/h) | $/h (→ tk/h) |
| Weekly | weekly %/h (→ tk/h if weekly avg unmeasurable) | weekly %/h (→ tk/h) | weekly %/h (→ tk/h if no weekly window / unmeasurable) |

- Fallbacks render the real unit (no fabricated numbers); the unit suffix signals it.
- **Silent** fallback (no per-row badge) to avoid clutter.
- The toolbar control always shows the user's *preferred* selection, not the resolved
  one.

## 6. Rendering

- `RunwayTimeFormatting.rate(_:unit:confidence:)` gains `.dollarsPerHour`
  (`$0.42/h`; compact `$1.2K/h` for extremes) and `.weeklyPercentPerHour`
  (`0.6%/h`, one decimal). Reuse existing `.waiting`/`.idle` handling.
- `HUDRunwayLoadBar` fill: `$` and weekly use relative-to-max fill (the m/h `/45`
  anchor is already gated to `.quotaMinutesPerHour`); 5h keeps the anchor.
- `HUDRunwayLayout.rateWidth(for:)` sized per unit ($ and %/h short; token already 80).
- Toolbar control uses the shared `toolbarButtonCornerRadius` / picker styling to
  match "Meter".

## 7. Privacy (Phase 2)

Only new network activity is a read-only GET of public static `prices.json` (no
query params, no identifiers, no payload) — materially the same as the Sparkle
appcast check. Update `docs/PRIVACY.md` / README security copy to note "an optional
price-list fetch" alongside Sparkle. No user/session data transmitted.

## 8. Testing

Phase 1:
- `RunwayPresentation` pref round-trip + default.
- `effectivePresentation`: full §5 matrix incl. Codex-5h-dropped, no-weekly-window,
  weekly-unmeasurable → tk/h.
- Weekly: per-session `%/h` = token-share × weekly average-burn; sustainable ≈
  0.6%/h; **burst-in-idle-week does not spike**; fresh-week → tk/h fallback.
- Rename: snapshot stays one-unit; max-fill + burst sums correct per unit.
- Claude loader unit branch (P5): tk/h and weekly render on Claude.
- Rendering: $/weekly formatting, column widths; Codex `.fiveHour` default byte-equal
  to v4.4.

Phase 2:
- `RunwayPriceTable`: bundled load; cache-over-bundled precedence; malformed/unknown-
  version manifest → bundled, no crash; longest-prefix slug match; unknown slug → nil.
- Per-type parse from real `total_token_usage` fixture (Codex) + Claude fixture.
- `dollarSnapshot`: per-type × price → $/h; subset formula (no reasoning double-count);
  Claude cache-write priced; unknown-price model → snapshot-wide tk/h fallback.
- Non-proportionality test: cache-heavy fixture → tk/h ≠ $/h as specified.

## 9. Phasing & rollout

Two shippable phases (the single-plan spec was its weakest structural point):

- **Phase 1 — plumbing + 5h/token/weekly (no network):** `RunwayPresentation` +
  pref + toolbar control; `RunwayRateUnit.weeklyPercentPerHour`; the rename;
  request-id extension; `effectivePresentation`; **Claude loader unit branches (P5)**;
  weekly math + fallbacks (P6); rendering/formatting; weekly-field plumbing into both
  builders. Exercises every risky seam (request rebuild on switch, snapshot-wide
  fallback, Claude branch) with data the app already parses.
- **Phase 2 — $ burn:** per-type capture in both parsers (P3/P4); model-slug capture +
  prefix matching (P2); `RunwayPriceTable` + fetch/cache/bundled snapshot + version
  guard; `dollarSnapshot`; privacy copy. **Riskiest part** (two log grammars, subset
  semantics, model churn, the only new network surface). Build `RunwayPriceTable` +
  fixture-driven `dollarSnapshot` tests **before** any UI. Riskiest single element:
  **Claude $ accuracy** (weighted-vs-raw counts + cache-write price + dated slugs).

Default `.fiveHour` = no behavior change; ship behind the toolbar control. A pricing
bug in Phase 2 can never regress Phase 1's shipped presentations.
