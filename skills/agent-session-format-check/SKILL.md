---
name: agent-session-format-check
description: Verify agent session format compatibility for Agent Sessions. Use when any agent CLI updates, when monitoring flags drift, or when bumping max verified versions (fixtures + docs + tests). Covers session schema, usage/limits tracking, storage backends, and discovery path contracts for all supported agents.
---

# Agent Session Format Check

Quickly verify whether a newer agent CLI version changes the local session format,
usage/limits schema, or storage layout — and whether Agent Sessions can safely bump its
verified support.

**Evidence-first:**
- Gather a report + sample paths first.
- Do not change parsers/fixtures/docs without explicit user approval.

**Related skill:** `agent-support-matrix` — maintains the matrix YAML, ledger, and
update-checklist workflow. This skill focuses on *detection and evidence collection*;
`agent-support-matrix` focuses on *recording and gating version bumps*.

**Process doc:** `docs/agent-support/monitoring.md` — defines the severity model, cadence
(daily/weekly), and escalation workflow that feeds into this skill.

---

## 1  Quick Start (all agents)

1. Run weekly monitoring:
   ```
   ./scripts/agent_watch.py --mode weekly
   ```
   Report path prints to stdout and is written under
   `scripts/probe_scan_output/agent_watch/*/report.json`.

2. In `report.json`, check each agent under `results.<agent>`:
   - `verified_version`, `installed.parsed_version`, `upstream.parsed_version`
   - `weekly.local_schema` (newest local session used for fingerprinting)
   - `weekly.schema_diff` and `evidence.schema_matches_baseline`
   - `severity` and `recommendation`

Interpretation:
- `installed == verified` and `upstream == verified`: no action.
- `installed/upstream > verified` and `schema_matches_baseline == true`: safe to bump (after approval).
- `schema_matches_baseline == false`: collect evidence and plan a parser/fixture update.

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

OpenCode uses a **multi-file JSON tree** (`storage/session/`, `storage/message/`,
`storage/part/`) — not JSONL. The monitoring fingerprints this tree structure.

### Current layout
```
~/.local/share/opencode/storage/
  session/<project>/ses_*.json
  message/<sessionId>/msg_*.json
  part/<messageId>/*.json
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
- `opencode_storage_latest_session` kind scans the full tree (session + messages + parts).
- `_opencode_storage_session_tree_schema_fingerprint()` walks messages and parts for a
  session and reports keys per record kind.
- If a `.db`, `.sqlite`, or `.bolt` file appears under the storage root, the current
  scanner will **not** detect it. Risk keywords in `agent-watch-config.json` will flag
  release notes mentioning these backends, but a file-extension scan of the storage root
  is not yet implemented.
- **TODO:** add a file-extension probe to `agent_watch.py` that checks for `*.db`,
  `*.sqlite`, `*.bolt` files under the OpenCode storage root during weekly scans.

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
| Droid    | `~/.factory/sessions/**/*.jsonl` |
| Gemini   | `~/.gemini/tmp/<hash>/(chats/)?session-*.json` |
| Copilot  | `~/.copilot/session-state/*.jsonl` |
| OpenClaw | `*/agents/<id>/sessions/*.jsonl` |

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
