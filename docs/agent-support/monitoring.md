# Agent Monitoring (Daily + Weekly)

This document defines the reliable process for detecting upstream agent format drift and deciding
whether Agent Sessions (AS) needs an urgent update for active providers. Droid is legacy-only and
is excluded from routine monitoring.

This is intentionally **non-destructive**:
- It produces reports and evidence captures.
- It does **not** modify parsers, fixtures, or the Xcode project.
- Any code/fixture change requires explicit user approval.

## Goals
- Detect upstream agent releases quickly (daily) and stay quiet when there is nothing to do.
- Confirm session-format drift promptly (weekly, with minimal probes + local evidence).
- Track, from now on, which AS version supports which agent versions (ledger).
- Include Claude + Codex **usage/limit tracking** in monitoring (these can drift independently of sessions).

## Cadence
- Daily: `codex`, `claude`, `opencode`, `openclaw` (release watch only; quiet unless there is actionable change).
- Weekly: all 7 active agents including `gemini`, `copilot`, and `cursor` (release watch + minimal probes + schema fingerprints).
- Weekly also enforces `discovery_path_contract` checks from config to catch storage-layout drift that can break app discovery even when parser schema still matches.

## Sources of Truth
- Current snapshot (latest): `docs/agent-support/agent-support-matrix.yml`
- Versioned record (append-only, from now on): `docs/agent-support/agent-support-ledger.yml`
- Narrative notes/evidence pointers: `docs/agent-json-tracking.md`

## Reports
Reports are written under the ignored folder `scripts/probe_scan_output/agent_watch/`.

Daily behavior:
- If no agent has upstream/installed versions newer than verified, and monitoring sources are reachable:
  - Write the report file but do not print to stdout (quiet run).
- If any agent has a newer upstream/installed version, or monitoring sources fail:
  - Print a short summary and write a full report.

Weekly behavior:
- Always write a report and print a short summary (weekly is expected to be reviewed).

## Severity model
Each agent gets a `severity` and a `recommendation`.

Severity levels:
- `none`: nothing newer than verified and monitoring succeeded.
- `low`: newer version exists; no schema/usage risk keywords; defer to weekly scan.
- `medium`: newer version exists and release notes contain schema/usage/limits keywords; run probes and collect evidence.
- `high`: probes indicate drift, monitoring failed, discovery path contract fails, or local evidence suggests parsing/usage breakage risk.

Recommendation guidelines:
- `ignore`: nothing to do.
- `monitor`: no risk keywords; defer to weekly scan.
- `run_weekly_now`: release watch shows risk keywords; run weekly scan early.
- `prepare_hotfix`: probe output/schema fingerprint shows breaking or likely-breaking drift; schedule parser/fixture update.

| Severity | Recommendation | Meaning |
|----------|----------------|---------|
| `medium` | `run_prebump_validator` | Weekly evidence passed schema diff but the sampled session predates the installed CLI binary. Run `./scripts/agent_watch.py --mode prebump --agent <name>` before bumping. |

## What “usage/limits drift” means (Claude + Codex)
- Codex:
  - Passive channel: session JSONL `token_count` / `rate_limits` event structure.
  - Active channel (weekly/when-risk): `codex_status_capture.sh` output schema.
- Claude:
  - Active channel (weekly/when-risk): `claude_usage_capture.sh` output schema and probe health.
  - If probe health fails (`parsing_failed`, auth required, etc.), treat as `high` severity because UI can break.
  - Context probe: `./scripts/claude-status --json` records status.claude.com indicator/incidents to help distinguish upstream outages from AS regressions.

## Running it
- Daily: `./scripts/agent_watch.py --mode daily`
- Weekly: `./scripts/agent_watch.py --mode weekly`
- Verbose (debug): `./scripts/agent_watch.py --mode daily --verbose`

Configuration:
- `docs/agent-support/agent-watch-config.json`
- Update sources/commands in config if a vendor changes distribution URLs or version strings.

## Scheduling (suggested)
- Daily (quiet): run once per day via launchd/cron.
- Weekly (review): run once per week and review the report output.

Implementation detail:
- Because daily runs are quiet on success, schedule them to write logs to a file only when you
  want auditing. Weekly runs always print a short summary plus the report path.

## How this feeds “support updates” (human-in-the-loop)
When the report recommends `prepare_hotfix`:
1. Capture evidence into `scripts/agent_captures/` (or the report’s capture folder).
2. Diff against fixtures, update parsers, add/update tests.
3. Run discovery-contract tests before bumping verified versions:
   - `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/SessionParserTests`
4. Build + run tests.
5. Update:
   - `docs/agent-json-tracking.md`
   - `docs/agent-support/agent-support-matrix.yml`
   - `docs/agent-support/agent-support-ledger.yml` (new AS release entry)

## Sample freshness (weekly)

`results.<agent>.evidence.sample_freshness` records whether the newest
local session predates the currently installed CLI binary. Fields:

- `sample_mtime_utc`, `cli_binary_mtime_utc`, `cli_binary_path` — raw inputs.
- `freshness_window_seconds` — per-agent backstop (14d hot / 30d cold).
- `sample_older_than_cli` — primary staleness signal.
- `sample_older_than_window` — backstop signal.
- `is_stale` — OR of both signals (with `forced_fresh` short-circuit).
- `stale_reason` — one of `sample_older_than_cli`, `sample_older_than_window`,
  `cli_binary_unresolved`, `forced_fresh`, or `null`.
- `mode_context` — `normal` or `skip_update`.

When `installed > verified`, `schema_matches_baseline == true`, and
`is_stale == true`, severity is `medium` and the recommendation is
`run_prebump_validator`. Fresh samples retain the existing
`bump_verified_version` auto-downgrade.

### Gating a matrix bump on prebump

```
./scripts/agent_watch.py --mode prebump --agent codex --agent claude \
    && git add docs/agent-support/agent-support-matrix.yml \
    && git commit -m "chore(matrix): bump codex_cli / claude_code"
```

Exit 0 is required. Exit 2 means the fresh session does not match baseline.
Exit 3 means a driver failed (CLI error, timeout, no headless mode, or
discovery-contract violation). Exit 4 means a config error (unknown
agent, missing/invalid `discover_session` contract, credential hygiene
failure) or a sandbox breach (the copilot hermeticity gate, overridable
only via `--allow-real-home`).
