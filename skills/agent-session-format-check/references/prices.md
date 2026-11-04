# Format-check reference: prices

The [runbook](../SKILL.md) governs authority and run order. Historical incidents below
explain the checks; they do not authorize sign-ins, purchases, commits or releases.

Current correction (2026-11-02): the tables are `docs/prices-v2.json`, `docs/prices.json`
and `RunwayPriceTable.bundledJSON`. Keep shared rates identical. Legacy prices.json
contains Claude/GPT/internal rows only; vendor rows belong in v2 and bundledJSON.
Advance `sequence` and `updated` in v2/bundled, and `updated` in the legacy manifest
(schema 1 has no sequence). Never edit `docs/prices-v2.released.json`: release owns it.
The matcher is guarded: recognized Claude versions or dated snapshots, not arbitrary
prefixes. See `RunwayPriceSnapshot.price` and `ModelPriceKeyResolver.resolve`.
Weekly `price_coverage` scans recently modified transcripts and timestamped DB rows for
30 days; it reports unpriced slugs and read errors. It does not verify vendor prices.
Inspect the official pages of every represented provider: OpenAI, Anthropic, Google,
Z.ai, MiniMax, Moonshot/Kimi, xAI, Meta and Upstage. Record unavailable historical rates as limits.
Upstage's Solar Mini 4 source is https://console.upstage.ai/docs/models/solar-mini-4.
Use each published cache rate; a generic multiplier in historical notes is not authority.
The older two-table/update-date instructions below are superseded by this correction.

## 2a  Model Price Freshness (Session Runway `$` burn)

The runway's `$` presentation prices per-type token rates against a model table, so it
drifts whenever a provider changes prices or ships a model slug we don't know — with no
schema change and no failing probe. Nothing else in this scan catches it. Unlike a
broken probe, **stale prices fail silently**: the number still renders, just wrong.

**Sources of truth (fetch these, don't recall them):**
- Anthropic — <https://platform.claude.com/docs/en/about-claude/pricing>
- OpenAI — <https://developers.openai.com/api/docs/pricing>

**The table lives in two places that MUST stay identical:**
- `docs/prices.json` — served to clients from GitHub Pages (corrects shipped apps with
  no release)
- `RunwayPriceTable.bundledJSON` in `AgentSessions/CodexStatus/RunwayPriceTable.swift`
  — the compiled-in default (offline / pre-first-fetch)

### Checks
1. **Prices unchanged?** Compare every key's `inputPerMTok` / `cachedInputPerMTok` /
   `outputPerMTok` / `cacheWritePerMTok` against the official pages. Anthropic cache
   columns are derived: read = 0.1x input, 5m write = 1.25x input.
2. **New model slugs?** Any tier we don't have a key for is **dropped from `$`** (it
   still shows in `tk/h`), so a new model silently disappears from the cost view.
   Check what the local CLIs actually emit rather than guessing:
   ```bash
   # Codex: the model lives on turn_context lines
   grep -ho '"model":"[^"]*"' ~/.codex/sessions/$(date +%Y/%m)/*/*.jsonl | sort -u
   # Claude: message.model on assistant lines
   find ~/.claude/projects -name '*.jsonl' -mtime -7 -print0 \
     | xargs -0 -n1 jq -r 'select(.type=="assistant") | .message.model' 2>/dev/null | sort -u
   ```
   Every slug returned must resolve via longest-prefix against a table key.

   **Known slugs that look alarming but are fine** (verified 2026-07-14):
   - `<synthetic>` (Claude) — not a model. It appears on assistant lines and does
     carry a `usage` object, but every field is **0**, so it forms a zero-rate
     component and `dollarsPerHour` skips it. Do NOT "fix" this by adding a price
     key; the zero-rate exemption is what keeps it from dropping the whole session.
     If Claude ever gives `<synthetic>` real tokens, that exemption stops applying
     and every Claude session would vanish from `$` — re-check this if it changes.
   - `codex-auto-review` (Codex) — Codex's internal auto-review label, on `turn_context`.
     It bills **real** tokens, and because an unpriced *contributing* slice makes
     `dollarsPerHour` return nil for the whole session, a missing key here didn't
     understate the cost — it deleted the session from `$` entirely. Priced at the
     gpt-5.6/sol default since 2026-08-03. This is the failure mode to look for whenever
     a session is missing from `$`: check for a slug with no key before anything else.
   - `gpt-5.6-codex` (Codex) — no key of its own; resolves to the `gpt-5.6` fallback
     (sol pricing). OpenAI publishes no separate `-codex` rate, so that is the best
     available assumption. The bare `gpt-5.6` key exists for exactly this.
3. **Prefix collisions?** Keys match by longest prefix, so a shorter key must never
   shadow a longer one, and a legacy key must never capture a current slug (e.g.
   `claude-opus-4-1` must NOT match `claude-opus-4-8`). Adding a bare `claude-opus-4`
   would break exactly this. `testPriceTableLegacyKeysPriceWithoutShadowingCurrent`
   and `testPriceTableBundledAndPrefixMatch` pin it — run them after any table edit.
4. **Temporary pricing expired?** Introductory/promo rates have end dates — but check
   whether the end date still stands before "correcting" anything. Claude Sonnet 5's
   $2/$10 was announced as introductory through **2026-08-31**; Anthropic has since made
   it the standard price and cancelled the scheduled rise to $3/$15, so the explicit
   `claude-sonnet-5` key at $2/$10 is correct and must not be reverted to the
   `claude-sonnet` $3/$15 fallback (verified 2026-08-30 against the pricing page's
   `claude-sonnet-5-introductory-pricing` note). A promo whose date has simply passed is
   the easy case; this is the one that costs you, because the stale plan reads as
   authoritative.

### Updating
Edit `docs/prices.json`, mirror the identical change into `bundledJSON`, and **always
advance `updated`**. Clients only accept a manifest whose `updated` is `>=` their
bundled table's, so a forgotten bump means the correction is ignored — that date is the
only thing preventing a stale cache from shadowing corrected prices. Pushing
`docs/prices.json` corrects already-shipped apps within a day, with no release.

Verify: `xcodebuild test -scheme AgentSessions -only-testing:AgentSessionsTests/CodexUsageParserTests`

### Cadence
Monthly is enough — provider prices move rarely, but when they move they move a lot
(Opus went $15/$75 → $5/$25, a 3x overstatement that ran undetected). Also check on any
**new model launch**, since an unknown slug drops that session from `$` entirely.

---
