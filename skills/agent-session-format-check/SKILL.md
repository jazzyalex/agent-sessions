---
name: agent-session-format-check
description: Verify agent session format compatibility for Agent Sessions. Use when any agent CLI updates, when monitoring flags drift, or when bumping max verified versions (fixtures + docs + tests). Covers session schema, usage/limits tracking, storage backends, and discovery path contracts for all supported agents.
---

# Agent Session Format Check

Answer one precise question for every supported agent:

> Can current Agent Sessions code support the latest available session/storage/usage
> format from the latest available agent build?

The answer must be layered. Do not collapse version checks, stale samples, schema
fingerprints, discovery contracts, and usage probes into a vague severity label.

**Evidence-first:**
- Gather a report + sample paths first.
- Do not change parsers/fixtures/docs without explicit user approval.

**Related skill:** `agent-support-matrix` — maintains the matrix YAML, ledger, and
update-checklist workflow. This skill focuses on *detection and evidence collection*;
`agent-support-matrix` focuses on *recording and gating version bumps*.

**Process doc:** `docs/agent-support/monitoring.md` — defines the compatibility verdicts,
legacy severity model, cadence, and escalation workflow that feed into this skill.

---

## 1  Quick Start (all agents)

1. Run weekly monitoring:
   ```
   ./scripts/agent_watch.py --mode weekly
   ```
   Report path prints to stdout and is written under
   `scripts/probe_scan_output/agent_watch/*/report.json`.

2. In `report.json`, check each agent under `results.<agent>`:
   - `compatibility.verdict`, `compatibility.scope`, `compatibility.blockers`,
     and `compatibility.next_action`
   - `verified_version`, `installed.parsed_version`, `upstream.parsed_version`
   - `compatibility.latest_status` to distinguish `current_fetch_known`,
     `cached_latest`, and unknown latest-source states
   - `weekly.local_schema` (newest local session used for fingerprinting)
   - `weekly.schema_diff` and `evidence.schema_matches_baseline`
   - `evidence.sample_freshness` and `evidence.fresh_evidence_source`
   - `compatibility.latest_real_session_failure` when a prebump attempt failed
   - `severity` and `recommendation` only as legacy escalation fields

Interpretation:
- `supports_latest`: latest known build is covered by
  `evidence.fresh_evidence_source == "latest_prebump_report"` and
  `compatibility.latest_real_session_evidence == true` with
  `compatibility.latest_status == "current_fetch_known"`.
- `supports_installed_only`: installed build is covered by non-stale real local
  evidence, but latest is newer, cached from a prior report, unknown, or lacks
  fresh real-session proof.
- `latest_unknown`: no configured/reachable latest source or no real-session
  driver exists; do not claim latest support.
- `blocked_stale_sample`: evidence predates the installed CLI; run prebump before claiming support.
- `blocked_no_fresh_evidence`: a version changed but no fresh matching sample proves support.
- `format_drift_detected`: unknown schema/storage/usage fields appeared; update fixtures/parsers.
- `monitoring_broken`: latest source, usage probe, or discovery contract failed.
- `real_session_auth_failed` in blockers: the real-session driver ran but the
  sandboxed agent was not authenticated; re-auth or provide the configured env
  token, then rerun prebump.

---

## 1a  Real-Session Prebump Validation (required before latest claims)

Weekly scanning samples the newest on-disk session, which can predate a CLI
upgrade and give a false "safe to bump" call (the codex 0.120.0 trap and the
copilot `session.shutdown` trap). When weekly reports
`recommendation == run_prebump_validator` — or before you stage any
`max_verified_version` bump or latest-support claim — run the prebump path for
every active agent being claimed. The driver exercises the currently installed
CLI once inside a sandbox and diffs its output against the fixture baseline:

```
./scripts/agent_watch.py --mode prebump --agent codex --agent claude
```

Exit-code contract:
- `0` — every requested agent produced a fresh session and the schema
  matches baseline. Safe to bump.
- `2` — at least one fresh session's schema does **not** match baseline.
  Do **not** bump; investigate the schema diff in
  `scripts/probe_scan_output/agent_watch/<slug>-prebump/report.json`.
- `3` — at least one driver failed (timeout, auth, CLI not found, or
  discovery contract violation — wrong session root, wrong glob, or
  missing required event types).
- `4` — config/invariant error: unknown `--agent` (or one with no
  prebump block), missing/invalid `discover_session` contract,
  credential hygiene failure (oversize / mode), or sandbox breach
  (copilot hermeticity gate). Re-run with
  `--allow-real-home` only if you understand your real config dir will
  be mutated for that one invocation.

Flags:
- `--agent <name>` (repeatable) — restrict to specific agents. An
  unknown agent or one without a `prebump` config block exits 4.
- `--keep-sandbox` — preserve the temp `$HOME` for debugging.
- `--timeout-seconds N` — per-driver timeout. CLI flag overrides
  per-agent config; falls back to config, then global default (120s).
- `--force-fresh` — suppress staleness evaluation for this run only (records
  `stale_reason=forced_fresh` in the report).
- `--allow-real-home` — copilot/real-HOME opt-in after a sandbox-breach
  diagnostic; never persistent.

Configured real-session drivers today are `codex`, `claude`, `gemini`,
`copilot`, `opencode`, `hermes`, `openclaw`, `cursor`, and `pi`. Droid is
legacy-only and excluded from active checks.

Prebump uses the hybrid env-var-first auth policy: if the relevant API-key
env var (`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `GEMINI_API_KEY`,
`FACTORY_API_KEY`, `GITHUB_TOKEN`) is set it is forwarded into the sandbox
and real HOME is never read. Otherwise the driver copies the declared
credential file from real HOME into the sandbox after running three hygiene
gates (64 KiB max, mode `0600`, ≤90-day mtime warning). v1 drivers:
`codex_exec`, `claude_print`, `gemini_prompt`, `copilot_prompt`,
`opencode_run`, `hermes_oneshot`, `openclaw_local_agent`,
`cursor_agent_print`, and `pi_prompt`. Some OAuth/keychain-backed CLIs use
`real_home_session: true`; run them with `--allow-real-home` so the session
lands in the real agent store instead of copying single-use auth state into a
sandbox.

---

## 2  Usage / Limits Drift (Codex + Claude)

Usage and limits tracking can drift **independently** of session schema. Monitor both.

### Codex
- **Passive channel:** session JSONL `token_count` / `rate_limits` event structure.
- **Active channel (weekly):** `codex_status_capture.sh` output schema — parsed as
  `codex_status_json` by `agent_watch.py`.
- Check: does `report.json → results.codex.probes[codex_status_probe].ok` return `true`?
  If not, investigate whether Codex changed its status output format.

### Claude
- **Active channel (weekly):** `claude_usage_capture.sh` output schema — parsed as
  `claude_usage_json`.
- **Context probe:** `./scripts/claude-status --json` records status.claude.com
  indicator/incidents (parsed as `claude_status_json`).
- Check: `results.claude.probes[claude_usage_probe].ok` — if `false`, the usage API
  response format may have changed, or authentication may be required.
- If probe health fails (`parsing_failed`, auth required, etc.), treat as **high severity**
  because the UI can break.

### Known issue: Claude usage probe exit 16 (parsing_failed)
`claude_usage_capture.sh` can fail with exit 16 when Claude auth tokens are exhausted.
The `/usage` TUI command itself stops working in this state. This is **not** a format
change — resolution requires `claude auth login`. The failure is intermittent and clears
after re-authentication. The Swift side silently retains the last known good snapshot.

### What to look for in upstream release notes
- New or renamed fields in usage/billing/token responses.
- Auth changes (new scopes, cookie rotation, API key requirements).
- Rate-limit header changes or new quota enforcement mechanisms.

---

## 3  OpenCode Storage Changes

OpenCode's current local backend is SQLite at `~/.local/share/opencode/opencode.db`.
Legacy installs may still have a multi-file JSON tree (`storage/session/`,
`storage/message/`, `storage/part/`). Monitoring is SQLite-first and falls back to
the legacy JSON tree when no database is present.

### Current layout
```
~/.local/share/opencode/opencode.db

# legacy fallback
~/.local/share/opencode/storage/session/<project>/ses_*.json
~/.local/share/opencode/storage/message/<sessionId>/msg_*.json
~/.local/share/opencode/storage/part/<messageId>/*.json
```

### What to watch for
- **New storage backends:** OpenCode is a Go application. Watch upstream releases for
  introduction of SQLite, BoltDB/bbolt, Badger, or other embedded databases alongside or
  replacing the JSON file tree.
- **Schema changes in any record type:** session, message, or part records can evolve
  independently. The fingerprinter tracks keys per record kind.
- **New record types or directories:** a new sibling to `session/message/part` would
  indicate a storage expansion.
- **Migration flags:** look for `version`, `migration`, `schema_version` fields in
  session records or new migration files in the OpenCode repo.

### Detection in agent_watch.py
- `opencode_storage_latest_session` checks `db_roots` first and fingerprints
  `session`, `message`, and `part` rows from `opencode.db`.
- If no database is present, `_opencode_storage_session_tree_schema_fingerprint()`
  walks the legacy JSON tree for a session and reports keys per record kind.
- Risk keywords in `agent-watch-config.json` still flag release notes mentioning
  storage migrations such as SQLite, BoltDB/bbolt, Badger, or database changes.

---

## 3a  Cursor Storage

Cursor uses two storage backends:

- **JSONL transcripts** (`~/.cursor/projects/<workspace>/agent-transcripts/<uuid>/<uuid>.jsonl`) — primary session data, parsed by Agent Sessions. Subagent transcripts live in a `subagents/` subdirectory.
- **SQLite chat databases** (`~/.cursor/chats/<workspace-hash>/<uuid>/store.db`) — supplementary metadata (session name, model, timestamps). Key "0" in the `meta` table contains hex-encoded JSON.

The weekly scan fingerprints JSONL transcripts only. The SQLite probe (`cursor_sqlite_probe.py`) verifies the `meta` table is readable — it does not deep-fingerprint the database schema.

**What to watch for:**
- New top-level keys on `role: user/assistant` lines.
- New content block types beyond `text`, `tool_use`, `tool_result`, `thinking`.
- The `agent-transcripts/` directory being renamed or moved.
- SQLite probe failures indicating `meta` table schema changes.

**Note:** Some machines may have a stale PATH shim for `cursor` even when Cursor.app is installed. The weekly monitor tries the PATH command first, then falls back to the embedded app CLI at `/Applications/Cursor.app/Contents/Resources/app/bin/cursor --version`.

Cursor CLI latest-source truth comes from the official installer script at
`https://cursor.com/install`, which embeds `downloads.cursor.com/lab/<build>/...`
agent CLI package URLs. The Homebrew `cursor-cli` cask page is a fallback. Do
not use the unrelated npm package named `cursor-agent`.

Cursor Desktop agent windows use the same local surfaces as Cursor CLI:
`~/.cursor/projects/*/agent-transcripts/**/*.jsonl` for transcript content and
`~/.cursor/chats/*/*/store.db` for chat metadata. The weekly
`cursor_sqlite_probe` must keep reporting the newest Desktop chat DB's
`agentId`, `createdAt`, mode/model fields, mtime, and meta-key schema so fresh
Desktop-only windows are visible even when their JSONL transcript is absent or
older.

---

## 4  Discovery Path Contracts

Each agent has a `discovery_path_contract` in `agent-watch-config.json` defining the
expected file layout Agent Sessions uses to discover sessions. If an upstream agent moves
or renames its storage, discovery breaks even if the parser still works.

Weekly monitoring checks these contracts. When a contract fails:
- `severity` escalates to `high`.
- The session viewer will silently stop finding new sessions for that agent.
- Investigate whether the agent changed its storage location or naming convention.

Key contracts (simplified from regexes in `agent-watch-config.json`):
| Agent    | Expected pattern |
|----------|-----------------|
| Codex    | `*/sessions/YYYY/MM/DD/rollout-*.jsonl` |
| Claude   | `~/.claude/projects/**/*.{jsonl,ndjson}` |
| OpenCode | `*/opencode/storage/session/*/ses_*.json` |
| Hermes   | `~/.hermes/sessions/session_*.json` |
| Gemini   | `~/.gemini/tmp/<hash>/(chats/)?session-*.json` |
| Copilot  | `~/.copilot/session-state/*.jsonl` |
| OpenClaw | `*/agents/<id>/sessions/*.jsonl` |
| Cursor   | `~/.cursor/projects/*/agent-transcripts/*/*.jsonl` |

---

## 5  What to Collect as Evidence

From the weekly report (all agents):
- The path in `results.<agent>.weekly.local_schema.file` (newest session).
- The schema diff summary: `unknown_types`, `unknown_keys` (additive drift),
  `missing_types`, `missing_keys` (may mean "not observed in this sample").
- Probe results and `ok` status for usage probes.
- Discovery path contract pass/fail status.

Optional (recommended when a bump is needed):
- Copy the newest session file(s) into `scripts/agent_captures/<timestamp>/<agent>/`.
- Keep captures private (do not commit raw sessions; they can contain paths and prompts).

---

## 6  Verification Update Checklist (after approval)

1. **Refresh fixtures** for the affected agent under `Resources/Fixtures/stage0/agents/<agent>/`.
2. Ensure fixtures include the "important" event families when present:
   - Session metadata / `session_meta` payload keys.
   - Tool call / tool result events.
   - Usage/limits events (`token_count`, `rate_limits`, billing) when emitted.
   - Optional event wrappers (compaction, context, delta events) when present.
   - For OpenCode: representative session, message, and part JSON files.
3. Bump the verified version record:
   - `docs/agent-support/agent-support-matrix.yml` (`agents.<key>.max_verified_version`)
   - Append a new entry in `docs/agent-support/agent-support-ledger.yml`
   - Add a line to `docs/agent-json-tracking.md` under "Upstream Version Check Log"
4. Run tests locally:
   ```
   xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions \
     -destination 'platform=macOS' test
   ```
5. Run discovery-contract tests:
   ```
   ./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/SessionParserTests
   ```

---

## 7  Redaction Guardrails (fixtures)

When turning a real session into a committed fixture:
- Replace long instruction bodies with a short placeholder string (keep structure).
- Remove or truncate large base64/data-url blobs if present.
- Prefer keeping only minimal, deterministic message text (e.g., "List the files").
- Keep the schema shape intact: do not delete keys just because values were redacted.
- For OpenCode multi-file fixtures: redact each file independently but preserve
  cross-file references (session ID in message paths, message ID in part paths).
