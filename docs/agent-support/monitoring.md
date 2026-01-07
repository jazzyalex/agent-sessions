# Agent Monitoring (Daily + Weekly)

This document defines the reliable process for detecting upstream agent format drift and deciding
whether Agent Sessions (AS) needs an urgent update.

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
- Daily: `codex`, `claude`, `opencode`, `droid` (release watch only; quiet unless there is actionable change).
- Weekly: all agents including `gemini`, `copilot` (release watch + minimal probes + schema fingerprints).

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
- `high`: probes indicate drift, monitoring failed, or local evidence suggests parsing/usage breakage risk.

Recommendation guidelines:
- `ignore`: nothing to do.
- `monitor`: no risk keywords; defer to weekly scan.
- `run_weekly_now`: release watch shows risk keywords; run weekly scan early.
- `prepare_hotfix`: probe output/schema fingerprint shows breaking or likely-breaking drift; schedule parser/fixture update.

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
3. Build + run tests.
4. Update:
   - `docs/agent-json-tracking.md`
   - `docs/agent-support/agent-support-matrix.yml`
   - `docs/agent-support/agent-support-ledger.yml` (new AS release entry)
