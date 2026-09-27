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
- Weekly: all 16 active agents — `codex`, `claude`, `opencode`, `hermes`, `antigravity`, `copilot`, `openclaw`, `cursor`, `pi`, `kimi`, `grok`, `qwen`, `devin`, `fx`, `cline`, `deepseek_harness` (release watch + local schema fingerprints; minimal probes where configured). Cline release/version comparison covers the CLI; Desktop currently contributes shared-format evidence but has no automated upstream version channel.
- Weekly also enforces `discovery_path_contract` checks from config to catch storage-layout drift that can break app discovery even when parser schema still matches.
- DeepSeek Harness inspects bounded headers under `$DSH_HOME/sessions` or `~/.dsh/sessions`, selects up to five canonical sessions by source-reported `createdAt`, then parses every validated row in those sessions. It supports plain JSONL and independently framed Zstandard, checks generation/header paths and dense event sequences, and fingerprints nested event data. Artifact mtime is recorded for diagnostics; each session's freshness is checked separately using its header timestamp against the installed CLI mtime and freshness window. That source-reported timestamp is not authenticated. The sample union remains useful for detecting drift, but only individually fresh sessions contribute to positive compatibility evidence. Catalog-known but unbaselined event shapes and unknown ignorable v3 events are reported separately; new keys and unsupported required event types remain drift findings. Known v3 surface records are checked against the app's envelope and reference rules, while legacy v0-v2 surface forms keep their existing validation. Prompt and tool payload values stay out of the report; sample paths and schema keys are written only to the ignored private report folder.
- A contract may declare `required_companion_files` — sidecars that must sit beside the sampled
  transcript for the app to discover the session at all. Entries are relative to the transcript's
  own directory and are either a bare path (existence) or `{path, must_parse: "json_object", note}`.
  `{stem}` and `{name}` expand from the sampled file for identity-matched companions such as
  Cline's `<id>.messages.json` beside `<id>.json`.
  A breach fails the contract, which means `severity: high`, `verdict: monitoring_broken`, and a
  `probe_or_discovery_failed` blocker. Grok declares `summary.json`: `GrokSessionDiscovery` skips
  any session directory that lacks it, so its loss removes every Grok session from the app while
  the schema fingerprint still reports `unknown_types: []` — a missing sidecar contributes no keys,
  and the schema diff ignores `missing_keys`/`missing_types` by design. The schema channel can
  never catch this class of break; the contract is the only thing that does.

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
| `supports_installed_only` | Installed build is covered by a non-stale real local session, but latest is newer, unknown, or lacks fresh real-session proof. | Run the configured real-session driver before claiming latest support. If there is no driver, capture a fresh native session or add a driver; do not emit an impossible prebump command. |
| `latest_unknown` | No configured or reachable latest-version source, or no real-session driver exists for proving latest. | Add/fix latest source or driver, or record a scoped exception. |
| `blocked_stale_sample` | The newest sample predates the installed CLI or freshness window. | Run prebump only when a driver is configured; otherwise capture a fresh native session or add a driver. |
| `blocked_no_fresh_evidence` | A version changed, but no fresh sample proves format compatibility. | Generate a fresh sample with the configured driver, or capture a native session when no driver exists. |
| `format_drift_detected` | Unknown schema/storage/usage fields or types appeared. | Triage parser/fixture impact before any bump. |
| `monitoring_broken` | Latest source, usage probe, or discovery contract failed. | Fix monitoring before making support claims. |

Use `compatibility.scope` to distinguish `latest`, `installed`, and `none`.
Use `compatibility.latest_status` to distinguish latest-source quality:
`current_fetch_known` means the current run reached a latest-version source;
`cached_latest` means the current source was degraded and the report reused the
most recent prior successful upstream version from agent-watch history;
`unknown_fetch_failed`, `unknown_no_version`, and `unknown_not_configured`
mean no usable latest candidate was available for the current report.
Use `compatibility.blockers` for the exact reason a support claim is blocked.
Weekly stdout prints every monitored agent with its compatibility verdict.

### Where the latest version came from

`upstream.parsed_version` is not always the configured registry's answer, so never read it
without `upstream.parsed_version_provenance`:

| Provenance | Meaning |
|------------|---------|
| `upstream_source` | The configured `upstream` source (GitHub release, npm, cask, URL regex). |
| `cached_prior_report` | The source was degraded; the version was carried over from an earlier report. |
| `cli_probe` | A weekly probe's own answer won, because it was higher than the configured source. |
| `both_agree` | A probe answered and matched the configured source exactly. |
| `none` | No usable version from any source. |

A weekly probe becomes a latest-version source by declaring `latest_version_key` in config —
the key of its parsed JSON holding the vendor's own "latest" (Grok's `grok_update_check` uses
`latestVersion`). Reconciliation takes the **higher** of the two, never a straight replacement:
a CLI answers for the channel it is pinned to, so a lower CLI answer must not be allowed to
hide a newer published release. Because it can only raise the number, reconciliation can add a
`upstream_newer_than_verified` alarm but never silence one. A failed probe gets no vote.
The full comparison is in `upstream.reconciliation`, and any disagreement prints on the weekly
summary line as `latest_disagree=probe:<v>/source:<v>/used:<v>`.

Reconciliation deliberately does **not** clear `risk.monitoring_failed`. If the configured
source failed outright, that source is still broken and stays reported as broken; a CLI
self-report is better data for the version, not a repair of the monitoring path.
Do not treat `supports_installed_only`, `latest_unknown`, `blocked_stale_sample`,
or `blocked_no_fresh_evidence` as verified latest support. For active agents,
`supports_latest` requires `evidence.fresh_evidence_source ==
"latest_prebump_report"` and `compatibility.latest_real_session_evidence ==
true` with `compatibility.latest_status == "current_fetch_known"`; ordinary
weekly newest-on-disk samples and `cached_latest` only prove installed/local
scope. `latest_real_session_evidence` is true only when the current upstream version is
known from this run and equals the installed version that produced the fresh prebump.
The separate `fresh_schema_evidence` field can still prove installed-build compatibility
when upstream is unknown or newer.
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
  - Passive channel: session JSONL `token_count` / `rate_limits` event structure. Covered by the
    schema fingerprint **only because codex is fingerprinted nested** — these events live under
    `event_msg.payload`, and the flat fingerprint that ran until 2026-08-03 stopped at
    `{payload,timestamp,type}` and could never see them. Moving codex back to the flat
    fingerprint would silently unwatch this channel.
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

## Scheduling

The weekly run has a tracked LaunchAgent — `tools/agent-watch/`. Install it with:

    bash tools/agent-watch/install.sh

That schedules `--mode weekly` for Mondays at 09:00 local and logs to
`tools/agent-watch/out/launchd.log`; `tools/agent-watch/uninstall.sh` removes it.
Read `tools/agent-watch/README.md` before relying on it — in particular, PATH is
baked into the plist at install time, so **re-run the installer after installing a
new agent CLI** or the scan will report that agent as unavailable.

Until this existed the weekly cadence was aspirational: the run dates under
`scripts/probe_scan_output/agent_watch/` are hand-run bursts with gaps of up to
three weeks.

The daily run is still unscheduled — run `--mode daily` by hand when you want it.

Implementation detail:
- Because daily runs are quiet on success, schedule them to write logs to a file only when you
  want auditing. Weekly runs always print a short summary plus the report path.
- Neither mode signals findings through its exit status — `daily` and `weekly` both exit 0
  regardless of severity. A scheduler can only tell you the run happened; the report is what
  says whether anything drifted.

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
`is_stale == true`, severity is `medium`. The recommendation is
`run_prebump_validator` only when that agent has a configured driver; otherwise
it is `monitor` and `compatibility.next_action` explains how to collect native
evidence. A weekly clean sample may still suggest `bump_verified_version`, but
the final recommendation is changed to `run_prebump_validator` until a fresh
prebump report exists. A prebump proves the installed build; it proves latest
support only when that build equals the current known upstream version.

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
- Cursor latest-source monitoring uses the official `https://cursor.com/install`
  installer script and a Homebrew `cursor-cli` cask fallback. The unrelated npm
  package named `cursor-agent` is not an official Cursor CLI source.
- Cursor Desktop agent-window sessions are covered through
  `~/.cursor/projects/*/agent-transcripts/**/*.jsonl` transcripts,
  `~/.cursor/chats/*/*/store.db` metadata, and persisted ACP stores under
  `~/.cursor/acp-sessions/<UUID>/store.db`. The weekly `cursor_sqlite_probe`
  fingerprints chat metadata keys/types and validates up to five newest ACP
  stores against the app's sidecar, SQLite table/column, content-addressed blob,
  and protobuf wire contracts. Its output contains schema names, wire field/type
  pairs, and counts only; it does not emit paths, IDs, metadata values,
  transcript text, or blob contents.
- Pi prebump runs `pi --print --mode json` with sandboxed `PI_CODING_AGENT_DIR` and `PI_CODING_AGENT_SESSION_DIR`, copying `~/.pi/agent/auth.json` and `settings.json` when env-var auth is not used. The fresh session must land under `.pi/agent/sessions/**/*.jsonl` and include `session` and `message` events.

Exit 0 is required. Exit 2 means the fresh session does not match baseline.
Exit 3 means a driver failed (CLI error, timeout, no headless mode, or
discovery-contract violation). Exit 4 means a config error (unknown
agent, missing/invalid `discover_session` contract, credential hygiene
failure) or a sandbox breach (the copilot hermeticity gate, overridable
only via `--allow-real-home`).
