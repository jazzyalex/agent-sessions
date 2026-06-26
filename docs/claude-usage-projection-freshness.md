# Claude usage: "cached, not fresh" and the coarse 5h projection

Date: 2026-06-26
Status: **Accepted** (documented limitation — no fix planned)

## TL;DR
The Quota Meter / Session Runway diagnostics show Claude usage as
**"OAuth (cached) / recent cache"**, essentially never **"fresh"** (which Codex
reaches via "CLI RPC"). As a result Claude's 5h **projection** — the `▸ETA`
badge and the runway rate "sharpening" to measured velocity — forms far less
readily than Codex's. This is **by design**, and after the runway burn was
decoupled from the projection (commit `5289cf52`) it no longer affects the burn
rate / EQ at all. It only costs the projection *extras*, which matter only
during fast burn. **Decision: accept; do not fix.**

## Mechanism (traced)
1. `ClaudeUsageSourceManager` polls OAuth every **60s** (`refreshInterval`).
2. `ClaudeOAuthUsageClient.fetch()` is **cache-first with no bypass**: if the
   shared cache file is younger than `cacheMaxAge = 180s` it is returned
   (`fromCache: true`) and the live API call is skipped. Even
   `hardProbeNowDiagnostics` goes through this path.
3. The cache file `/tmp/claude/statusline-usage-cache.json` is **shared with the
   external ClaudeCodeStatusLine tool**. A running Claude Code session renders
   that statusline, which keeps the file continuously warm.
4. So each 60s poll re-serves the statusline's cache → source `.cachedOAuth` →
   label **"OAuth (cached)"**.
5. `ClaudeUsageModel.alertFreshness` reserves `.fresh` for **live** fetches only
   (`.oauthEndpoint`/`.webEndpoint`/`.tmuxUsage` with `.live` health ≤ 3min);
   `.cachedOAuth` can only be `.recentCached` (≤10min) or `.stale`. So while
   Claude Code is running, AgentSessions can never reach "fresh".

## Why the projection rarely forms
The projection needs two samples ≥60s apart showing a **drop**, with run-out
before reset. Three structural factors starve it on Claude:
- **Coarse cadence:** the cached payload changes only at the statusline's
  refresh interval (minutes), not AgentSessions' 60s poll, so the tracker mostly
  re-reads the same snapshot ("Waiting for usage drop / 60s sample").
- **Coarse resolution:** the OAuth payload reports usage as **whole-percent**
  (`five_hour.utilization`, `limits[].percent`), so a "drop" only registers per
  full 1% burned — a high bar over a 5h window.
- **Designed for fast burn:** the projection only shows when burning fast enough
  to exhaust before reset; at low usage it correctly stays absent.

Codex uses a direct, fine-grained, frequently-updated **CLI-RPC** local stream,
so its projection forms readily and stays "fresh".

## Live evidence (2026-06-26 09:5x)
- Cache file mtime ~104s old; content unchanged over an 8s sample.
- `five_hour.utilization = 7.0` (whole-percent), reset hours away.
- Diagnostics: Claude `OAuth (cached) / recent cache`, projection
  "Waiting for 60s sample"; Codex `CLI RPC / fresh`.

## Why this is acceptable
- Cache-first sharing is deliberate: it avoids hammering the OAuth endpoint
  (which returns 429 with a 5-min retry clamp) and cooperates with the
  statusline.
- The runway burn no longer depends on the projection (the `hasProjectedRunout`
  gate was removed for Claude in `ClaudeRunwaySnapshotLoader`), so burn + EQ
  render from token attribution regardless of projection freshness — matching
  how Codex stays alive via its always-on direct path.
- The only loss is the projection *extras* (▸ETA badge, velocity sharpening),
  which are fast-burn-only niceties.

## Deferred options (only if the ▸ETA badge should behave like Codex's)
- **A — periodic forced-live fetch:** add a cache-bypass path that fetches live
  on a cadence *when a Claude session is actively burning*, giving AgentSessions
  its own fresh samples. Trade: more OAuth calls → 429 risk (mitigated by the
  existing clamp); should be gated to active-burn only.
- **B — feed the tracker on content change:** dedup cached reads by
  `rawPayloadHash` so flat re-reads don't stall the tracker. Lower risk, smaller
  gain (still bounded by 1% resolution + statusline cadence).

Neither is planned. Revisit only if the Claude projection badge becomes a
priority.
