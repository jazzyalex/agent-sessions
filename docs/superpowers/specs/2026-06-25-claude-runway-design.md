# Claude Runway — per-agent session burn rate

Date: 2026-06-25
Status: approved (design), implementing

## Goal
Bring the Codex "Runway" feature (per-session burn rate + pause-impact rows) to
Claude sessions, placed **under each agent's own provider row** in the expanded
Quota Meter panel — not as a single drawer under the whole meter.

Out of scope: a separate EQ bar concept (we reuse the existing runway row view,
which already renders the pressure bar from `quotaMinutesPerHour`).

## Background (verified)
- The "total burn rate" projection (`fiveHourProjectedRunoutAt`) is shared by both
  providers via `UsageLimitProjectionTracker` and only shows when the projected
  runout lands before the window reset (`UsageDisplayFormatter.swift:154`).
- Codex Runway uses two signals: **direct** (per-session `rate_limits` deltas in
  the JSONL) and **token-activity** (per-session token rate → split the provider
  burn proportionally). `CodexRunwayCalculator` is provider-agnostic.
- Claude transcripts carry per-turn `message.usage` token counts + ISO timestamps,
  but **no** `rate_limits` (those come from the OAuth/web usage API). So Claude
  Runway = the token-activity path only (`.mixed` confidence, never `.direct`).
- Claude rate limits are account-wide, exactly like Codex — so token-volume
  attribution is the same trust level as Codex's `.mixed`/token path.
- Active Claude sessions already resolve a `sessionLogPath`
  (`CodexActiveSessionsModel.swift:1037`).

## Reused unchanged
`CodexRunwayCalculator`, `RunwayProviderBaseline`, `RunwaySessionIdentity`,
`RunwaySessionBurn`, `CodexRunwaySnapshot`, `RunwayPauseImpactRow`,
`RunwayShortBurstSummary`, `CodexRunwaySnapshotRequest`,
`quotaMeterVisibleRunwaySnapshot(...)`, `HUDRunwayPanel`, `HUDRunwayLoadBar`.

## New files
1. `AgentSessions/ClaudeStatus/ClaudeRunwayTokenActivityParser.swift`
   - `activity(identity:now:)` and `burns(identities:baseline:now:)`.
   - Reads `message.usage`; dedupes by `message.id`; sums weighted incremental
     tokens (`input + output + cache_creation + 0.1·cache_read`) over the recent
     tail window; tokens/sec = consumed-after-anchor / span.
   - Same window guards as Codex token parser (`maximumSampleAge` 75s,
     `minimumPairInterval` 10s, `maximumPairInterval` 30m).
2. `AgentSessions/ClaudeStatus/ClaudeRunwayRecentSessionScanner.swift`
   - `identities(root:now:fileManager:)` scanning `~/.claude/projects/**/*.jsonl`.
   - Recency cutoff 30m; active-tail check via newest event timestamp ≤ 75s;
     excludes `ClaudeProbeConfig.isProbeWorkingDirectory(cwd)`.
   - Display name from first real user text → cwd last path component → file UUID.
   - One file == one session (Claude keeps subagents in-file as `isSidechain`),
     so no cross-file parent merging.
3. `AgentSessions/ClaudeStatus/ClaudeRunwaySnapshotLoader.swift`
   - `snapshot(for: CodexRunwaySnapshotRequest)` (request gets
     `recentSessionsRoot = ~/.claude/projects`).
   - Merge request identities (active HUD `.claude` rows) + scanner identities,
     dedupe, compute token burns only, build via `CodexRunwayCalculator.snapshot`,
     append `waiting` pending rows for active identities with no burn yet.

## Edits to existing files
`AgentSessions/Views/AgentCockpitHUDView.swift`
- `HUDRunwayIdentityReducer.identities(from:source:)` — add `source` param
  (default `.codex`); generalize placeholder copy.
- `HUDRunwayRequestBuilder` — add `claudeRequest(...)` building a `.claude`
  baseline from `ClaudeUsageModel` with `recentSessionsRoot = ~/.claude/projects`.
- `HUDLimitsBar` + `HUDLimitsRowsPanel` — hold `codexRunwaySnapshot` and
  `claudeRunwaySnapshot`; load both in `refreshRunwaySnapshot`; combined
  `.task(id:)`.
- `HUDLimitsExpandedPanel` / `HUDLimitsDetailPanel` / `HUDLimitsRowsPanel` body —
  render each agent's runway block immediately under that agent's provider row.
- `HUDRunwayPanel` / `HUDRunwayEmptyPanel` — parameterize the "No active Codex
  burn" copy with an agent label.

## Tests
`AgentSessionsTests/CodexUsageParserTests.swift` (or a new
`ClaudeRunwayParserTests.swift`):
- token parser extracts tokens/sec from incremental Claude usage + dedupes by id
- token parser ignores stale movement (> maximumSampleAge)
- scanner discovers a recent Claude log and skips a probe-cwd log

## Behavior
- Claude runway rows appear (under Auto) only when Claude's projection is live
  (fast burn). At lazy burn → no rows (or "calc"/waiting placeholders).
- Shared Auto/On/Off control applies to each agent's block independently.

## Naming debt (deferred)
`CodexRunwayCalculator` / `CodexRunwaySnapshot` are now multi-provider but keep
their `Codex` names to avoid churn. Rename in a separate pass if desired.
