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
- Weekly: all 9 active agents including `gemini`, `copilot`, `cursor`, `hermes`, and `pi` (release watch + minimal probes + schema fingerprints).
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

## Compatibility Verdict Model

The primary support answer is `results.<agent>.compatibility`, not `severity`.
It answers: can current Agent Sessions code support the latest available
session/storage/usage format from the latest available agent build?

Each verdict separates version scope from evidence quality:

| Verdict | Meaning | Required next action |
|---------|---------|----------------------|
| `supports_latest` | Latest known build is covered by a freshly generated real-session prebump report whose schema/probes match baseline. | None, unless bumping docs/matrix. |
| `supports_installed_only` | Installed build is covered by a non-stale real local session, but latest is newer, unknown, or lacks fresh real-session proof. | Run the real-session driver before claiming full latest support. |
| `latest_unknown` | No configured or reachable latest-version source, or no real-session driver exists for proving latest. | Add/fix latest source or driver, or record a scoped exception. |
| `blocked_stale_sample` | The newest sample predates the installed CLI or freshness window. | Run prebump for that agent. |
| `blocked_no_fresh_evidence` | A version changed, but no fresh sample proves format compatibility. | Generate a fresh sample and compare against baseline. |
| `format_drift_detected` | Unknown schema/storage/usage fields or types appeared. | Triage parser/fixture impact before any bump. |
| `monitoring_broken` | Latest source, usage probe, or discovery contract failed. | Fix monitoring before making support claims. |

Use `compatibility.scope` to distinguish `latest`, `installed`, and `none`.
Use `compatibility.blockers` for the exact reason a support claim is blocked.
Weekly stdout prints every monitored agent with its compatibility verdict.
Do not treat `supports_installed_only`, `latest_unknown`, `blocked_stale_sample`,
or `blocked_no_fresh_evidence` as verified latest support. For active agents,
`supports_latest` requires `evidence.fresh_evidence_source ==
"latest_prebump_report"` and `compatibility.latest_real_session_evidence ==
true`; ordinary weekly newest-on-disk samples only prove installed/local scope.
If a real-session driver ran but failed, inspect
`compatibility.latest_real_session_failure`. Auth failures surface as
`real_session_auth_failed` blockers and require re-auth before rerunning
prebump.

## Severity model
Each agent also gets a legacy `severity` and `recommendation` for escalation.
These fields are not sufficient to claim latest-format support.

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
`bump_verified_version` auto-downgrade, but it is not enough to claim
`supports_latest` unless paired with a fresh prebump report for that active
agent.

### Gating a matrix bump on prebump

Run the real-session driver for every active agent being claimed. Agents with
no `prebump` block in `agent-watch-config.json` cannot be reported as verified
latest until a bounded driver exists or a scoped exception is explicitly
recorded.

```
./scripts/agent_watch.py --mode prebump --agent codex --agent claude \
    && git add docs/agent-support/agent-support-matrix.yml \
    && git commit -m "chore(matrix): bump codex_cli / claude_code"
```

Auth notes:
- Copilot prebump accepts `COPILOT_GITHUB_TOKEN`, `GH_TOKEN`, or `GITHUB_TOKEN`; `GH_TOKEN=$(gh auth token) ./scripts/agent_watch.py --mode prebump --agent copilot` is the least intrusive local path when GitHub CLI auth is already available.
- Claude sandbox prebump requires sandbox-visible API/credential auth. If it fails with `Not logged in` but real-home Claude is authenticated, generate a real-home `claude -p --verbose --output-format stream-json ...` sample and cite that weekly evidence instead of treating the sandbox auth failure as session-format drift.
- Pi prebump runs `pi --print --mode json` with sandboxed `PI_CODING_AGENT_DIR` and `PI_CODING_AGENT_SESSION_DIR`, copying `~/.pi/agent/auth.json` and `settings.json` when env-var auth is not used. The fresh session must land under `.pi/agent/sessions/**/*.jsonl` and include `session` and `message` events.

Exit 0 is required. Exit 2 means the fresh session does not match baseline.
Exit 3 means a driver failed (CLI error, timeout, no headless mode, or
discovery-contract violation). Exit 4 means a config error (unknown
agent, missing/invalid `discover_session` contract, credential hygiene
failure) or a sandbox breach (the copilot hermeticity gate, overridable
only via `--allow-real-home`).
