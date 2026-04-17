# Agent JSON Tracking Memory Bank

This document tracks agent session/log formats, parsing assumptions, and known format changes.
Update this file when:
- A new upstream agent version changes session storage or JSON/JSONL structure.
- Agent Sessions parsing is updated to handle a new format or migration.
- Fixtures/tests are added or updated to cover format drift.

## Last Scan (Repo)
- Repo commit: cb723ae (latest in this worktree)
- Parser/indexer commit scan (30 commits, parser/indexer files):
  - d75afd2: Codex parsing hardening
  - 8439b09: Claude error classification to avoid false positives
  - 7e902e3: Skip Agents.md preamble in Codex titles
  - 1d2703b/8abc49e: Claude title/preamble handling
  - 66c317e/6088617: Droid/Copilot session import
- No additional format changes found in recent parser commits beyond the documented changes below.

## Upstream Version Check Log
Record every upstream check, even if no changes are needed.
- YYYY-MM-DD: Agents checked; sources (release notes or repos); result (no change, candidate,
  or format change) and evidence path.
- 2026-04-17: Follow-up verification after auth/login and CLI updates. Sources: `scripts/probe_scan_output/agent_watch/20260417-021412Z-prebump/report.json` (Gemini 0.38.1 prebump), `scripts/probe_scan_output/agent_watch/20260417-021815Z-prebump/report.json` (Copilot 1.0.31 prebump), `scripts/agent_captures/20260417-022051Z/opencode/latest_session_export.json` (OpenCode 1.4.7 SQLite export), `scripts/agent_captures/20260417-022051Z/openclaw/agents/main/sessions/005976ca-88c4-4ec6-98fb-21d838cd3ecb.jsonl` (OpenClaw 2026.4.15 fresh local turn), and `scripts/probe_scan_output/agent_watch/20260417-022056Z/report.json` (weekly check before matrix bump). Result: bumped Gemini `0.37.1`->`0.38.1`, Copilot `1.0.24`->`1.0.31`, OpenCode `1.4.6`->`1.4.7`, and OpenClaw `2026.4.14`->`2026.4.15`. Gemini sandbox auth support was updated to copy non-secret `~/.gemini/settings.json` and `~/.gemini/google_accounts.json` support files while keeping `~/.gemini/oauth_creds.json` under strict credential hygiene. Fresh Copilot/Gemini samples match baseline; OpenCode remains SQLite-backed at `~/.local/share/opencode/opencode.db`; OpenClaw schema remains unchanged.
- 2026-04-16: Weekly check across eight active agents. Sources: `scripts/probe_scan_output/agent_watch/20260416-195201Z/report.json` (initial), `scripts/probe_scan_output/agent_watch/20260416-200416Z/report.json` (after first fixture refresh), `scripts/probe_scan_output/agent_watch/20260416-202518Z/report.json` (verification before matrix bump), `scripts/probe_scan_output/agent_watch/20260416-202711Z/report.json` (final after matrix bump), local CLI `--version` checks, and configured upstream release sources. Result: bumped Codex `0.120.0`->`0.121.0`, Claude `2.1.104`->`2.1.112`, OpenCode `1.4.3`->`1.4.6`, and OpenClaw `2026.4.10`->`2026.4.14`. Session-format changes verified: Claude added metadata families `permission-mode` and `system` subtype `stop_hook_summary`; parser preserves both as `.meta`, fixtures/tests were updated. OpenCode current storage is `~/.local/share/opencode/opencode.db` SQLite, with `session`, `message(data JSON)`, and `part(data JSON)` tables; runtime SQLite reader was already present, direct `opencode.db` overrides and a SQLite reader test were added, and monitoring/capture now fingerprint/copy SQLite evidence instead of stale `storage/session/**` files. OpenClaw schema remains unchanged on a fresh `2026.4.14` sample. Copilot upstream/installed `1.0.30` and Gemini upstream/installed `0.38.1` remain candidates because prebump drivers failed from missing sandbox-visible auth (`scripts/probe_scan_output/agent_watch/20260416-201608Z-prebump/report.json`: Copilot token/GitHub auth missing; Gemini auth method/API key missing). Claude sandbox prebump still cannot use local login state, but weekly fresh local evidence under `~/.claude/projects/**` is sufficient for session-format verification. Evidence: `Resources/Fixtures/stage0/agents/claude/small.jsonl`, `Resources/Fixtures/stage0/agents/claude/schema_drift.jsonl`, `Resources/Fixtures/stage0/agents/copilot/small.jsonl`, `Resources/Fixtures/stage0/agents/opencode/storage_v2/part/m_assistant_small/001.json`, `Resources/Fixtures/stage0/agents/opencode/storage_v2/part/m_assistant_large_1/001.json`, `AgentSessionsTests/Stage0GoldenFixturesTests.swift`, `AgentSessionsTests/SessionParserTests.swift`, `AgentSessions/OpenCode/OpenCodeBackendDetector.swift`, `scripts/agent_watch.py`, `scripts/capture_latest_agent_sessions.py`, `scripts/agent_watch_prebump_drivers.py`, `scripts/tests/test_prebump_driver_claude.py`, `docs/agent-support/agent-watch-config.json`, `docs/agent-support/agent-support-matrix.yml`, `docs/agent-support/agent-support-ledger.yml`, `scripts/agent_captures/20260416-202539Z/opencode/latest_session_export.json`, `scripts/agent_captures/20260416-202546Z/openclaw/agents/main/sessions/005976ca-88c4-4ec6-98fb-21d838cd3ecb.jsonl`, `scripts/probe_scan_output/agent_watch/20260416-202518Z/report.json`, `scripts/probe_scan_output/agent_watch/20260416-202711Z/report.json`.
- 2026-04-12: Droid marked legacy-only. Parser fixtures and historical notes remain, but active monitoring and public support claims were removed.
- 2026-04-12: Added Cursor as 8th monitored agent. Initial verified version 2026.04.12 (date-based; Cursor does not embed CLI version in transcripts). Schema: role-based JSONL (user/assistant buckets + content.<type> sub-buckets). SQLite probe added for ~/.cursor/chats/ health. No prebump driver (no headless mode). Evidence: Resources/Fixtures/stage0/agents/cursor/, scripts/agent_watch.py, scripts/cursor_sqlite_probe.py, docs/agent-support/agent-watch-config.json, docs/agent-support/agent-support-matrix.yml.
- 2026-04-12: Weekly check across all seven agents. Sources: `scripts/probe_scan_output/agent_watch/20260412-173755Z/report.json` (initial), `scripts/probe_scan_output/agent_watch/20260412-181759Z/report.json` (re-scan with fresh sessions). Result: bumped Claude `2.1.92`->`2.1.104` (additive `attachment` type — infrastructure metadata for hooks/skills/deferred-tools; parser handles via `.meta`; drift test passes), Copilot `1.0.16`->`1.0.24` (additive `session.shutdown` type — end-of-session telemetry; parser handles via `default:` branch; drift test passes; CLI updated from 1.0.16), OpenClaw `2026.4.5`->`2026.4.10` (schema unchanged; fresh session generated after discovery failure caused by `openclaw doctor --fix` mass-rename on 2026-03-16). Codex, Droid, Gemini, OpenCode unchanged. Prebump driver bugs noted: Claude driver needs `--verbose` with `--print --output-format=stream-json` (CLI 2.1.104 change); Copilot sandbox missing `GITHUB_TOKEN` forwarding. Evidence: `docs/agent-support/agent-support-matrix.yml`, `docs/agent-support/agent-support-ledger.yml`, `scripts/probe_scan_output/agent_watch/20260412-*/report.json`.
- 2026-04-11: Weekly check across all seven agents. Sources: `scripts/probe_scan_output/agent_watch/20260411-202120Z/report.json`, local CLI `--version` checks. Result: bumped verified for Codex `0.117.0`->`0.120.0`, OpenCode `1.3.17`->`1.4.3`, Droid `0.89.0`->`0.99.0`, Gemini `0.36.0`->`0.37.1` — all four schema unchanged, low severity, weekly scan (`schema_matches_baseline=true`, `recommendation=bump_verified_version`). Claude, Copilot, OpenClaw not cleared for bump in this scan. Evidence: `scripts/probe_scan_output/agent_watch/20260411-202120Z/report.json`, `docs/agent-support/agent-support-matrix.yml`, `docs/agent-support/agent-support-ledger.yml`.
- 2026-04-06: Weekly check across all seven agents. Sources: `scripts/probe_scan_output/agent_watch/20260407-004902Z/report.json`, local CLI `--version` checks. Installed: Codex `0.117.0`, Claude `2.1.92`, OpenCode `1.3.17`, Droid `0.89.0`, Gemini `0.36.0`, OpenClaw `2026.4.5`, Copilot `1.0.16`. Upstream: Codex `0.118.0`, Droid `0.94.0`, Copilot `1.0.19` (all others match installed). Result: bumped verified for OpenCode `1.3.17` (schema unchanged), Gemini `0.36.0` (schema unchanged), OpenClaw `2026.4.5` (schema unchanged), Claude `2.1.92` (additive: new `attachment` event type with subtype `deferred_tools_delta`; schema_drift.jsonl updated), Copilot `1.0.16` (additive: new `session.shutdown` event type with shutdown metrics; schema_drift.jsonl updated). Codex and Droid unchanged (upstream not installed). Evidence: `scripts/probe_scan_output/agent_watch/20260407-004902Z/report.json`, `scripts/agent_captures/20260407-004731Z/`, `docs/agent-support/agent-support-matrix.yml`, `docs/agent-support/agent-support-ledger.yml`, `Resources/Fixtures/stage0/agents/**`.
- 2026-03-31: Full weekly check across all seven agents. Sources: `https://github.com/openai/codex/releases/latest` (0.117.0), `https://github.com/anthropics/claude-code/releases/latest` (2.1.88), `https://github.com/opencode-ai/opencode/releases/latest` (1.3.9), `https://docs.factory.ai/changelog/cli-updates` (0.89.0), `https://registry.npmjs.org/@google%2Fgemini-cli/latest` (0.35.3), `https://registry.npmjs.org/openclaw/latest` (2026.3.28), `https://github.com/github/copilot-cli/releases/latest` (1.0.13). Result: bumped verified sessions for Codex `0.117.0`, Claude `2.1.88`, Gemini `0.35.3`, Copilot `1.0.11` (installed; upstream is 1.0.13), OpenCode `1.3.7` (installed; upstream is 1.3.9), Droid `0.89.0`, OpenClaw `2026.3.28`. Schema drift: Claude — additive new fields `system.messageCount` and `user.origin` (origin is an object e.g. `{"kind":"task-notification"}`); schema_drift.jsonl updated with synthetic events. Gemini — additive new root-level `summary` string field; schema_drift.json updated. Copilot — MAJOR version: storage layout changed from flat `~/.copilot/session-state/<id>.jsonl` to `~/.copilot/session-state/<uuid>/events.jsonl`; runtime patched in commit f77040f; agent-watch-config.json discovery contract and glob updated; new subdirectory fixture added at `Resources/Fixtures/stage0/agents/copilot/subdir_v1/`. Evidence: `scripts/probe_scan_output/agent_watch/20260331-012056Z/report.json`, `docs/agent-support/agent-support-matrix.yml`, `docs/agent-support/agent-support-ledger.yml`, `Resources/Fixtures/stage0/agents/**`.
- 2026-03-18: Codex rollout-format audit after usage regressions. Local evidence from `~/.codex/sessions/2026/03/**` showed many recent `payload.type=token_count` events with `payload.rate_limits = null`, while older/local mixed sessions still emitted full `rate_limits` objects. Upstream evidence: open Codex issues about `rate_limits` being null in rollout files and JSONL rate-limit omissions (`openai/codex#14880`, `#14728`, `#14489`) plus rollout/schema churn around `turn.completed`, `token_count` migration, websocket `codex.rate_limits`, and rollout JSON schema updates. Result: Agent Sessions parser now treats null-only recent Codex logs as “limits unavailable in recent logs” instead of falling back to stale older-file percentages. Evidence: local rollout samples under `~/.codex/sessions/2026/03/**`, `AgentSessions/CodexStatus/CodexStatusService.swift`, `AgentSessionsTests/CodexUsageParserTests.swift`.
- 2026-03-01: Full weekly check across all seven agents with online upstream verification. Sources: `https://github.com/openai/codex/releases/latest`, `https://github.com/anthropics/claude-code/releases/latest`, `https://github.com/anomalyco/opencode/releases/latest`, `https://docs.factory.ai/changelog/cli-updates`, `https://registry.npmjs.org/@google%2Fgemini-cli/latest`, `https://registry.npmjs.org/openclaw/latest`, `https://github.com/github/copilot-cli/releases/latest`. Result: bumped verified sessions for Codex `0.106.0`, Claude `2.1.63`, OpenCode `1.2.10`, Droid `0.62.1`, Gemini `0.30.0`, OpenClaw `2026.2.22`; Copilot remained `0.0.411` (installed not newer). Added Droid stream `type=error` parser coverage and refreshed stage0 drift fixtures/metadata for Gemini, OpenCode, OpenClaw, and Droid. Evidence: `scripts/probe_scan_output/agent_watch/20260301-004842Z/report.json`, `docs/agent-support/agent-support-matrix.yml`, `docs/agent-support/agent-support-ledger.yml`, `Resources/Fixtures/stage0/agents/**`.
- 2026-03-01: Follow-up after local CLI updates for Gemini/OpenCode/Copilot. Installed versions now match upstream for Gemini `0.31.0`, OpenCode `1.2.15`, Copilot `0.0.420`. Bumped verified support for all three; expanded OpenCode baseline evidence to include `part.text` keys (`messageID`, `sessionID`) so weekly schema drift checks remain additive-only. Evidence: `scripts/probe_scan_output/agent_watch/20260301-011329Z/report.json`, `docs/agent-support/agent-support-matrix.yml`, `docs/agent-support/agent-support-ledger.yml`, `Resources/Fixtures/stage0/agents/opencode/storage_v2/part/m_assistant_large_1/002.json`, `Resources/Fixtures/stage0/agents/copilot/{small,large,schema_drift}.jsonl`.
- 2026-01-07: Gemini CLI 0.23.0 + OpenCode CLI 1.1.6; confirmed tool-output drift (exit codes embedded in Gemini functionResponse output; OpenCode tool parts expose `state.metadata.exit`). Evidence: `Resources/Fixtures/stage0/agents/gemini/large.json`, `Resources/Fixtures/stage0/agents/opencode/storage_v2/part/m_assistant_large_1/001.json`.
- 2026-01-07: Droid CLI 0.43.0; sources `https://app.factory.ai/cli`, `https://docs.factory.ai/changelog/cli-updates`, `https://github.com/factory-ai/factory`; stream-json now emits numeric epoch timestamps, `tool_call`/`tool_result` IDs via `id`, `isError` flags, and `completion.usage` fields. Evidence: `Resources/Fixtures/stage0/agents/droid/stream_json_schema_drift.jsonl`.
- 2026-01-07: Verification bump (no schema drift observed in local sessions vs stage0 baselines): Codex CLI 0.79.0, Claude Code 2.0.76 (sessions), OpenCode 1.1.6, Gemini CLI 0.23.0, Droid CLI 0.43.0. Evidence: `docs/agent-support/agent-support-matrix.yml`, `docs/agent-support/agent-support-ledger.yml`, updated fixtures under `Resources/Fixtures/stage0/agents/`.
  - Note: Claude usage/limits probes may fail when upstream has an active incident; monitoring records `status.claude.com` context via `scripts/claude-status`.
- 2026-01-16: Claude Code 2.1.9; new `system` and `queue-operation` event families plus additional per-event metadata keys (`slug`, `isMeta`, `todos`, `thinkingMetadata`, `sourceToolAssistantUUID`). Updated stage0 fixtures and meta-type classification to keep transcripts and drift monitoring stable. Evidence: `Resources/Fixtures/stage0/agents/claude/small.jsonl`, `Resources/Fixtures/stage0/agents/claude/large.jsonl`, `AgentSessions/Model/SessionEvent.swift`, `docs/agent-support/agent-support-matrix.yml`, `docs/agent-support/agent-support-ledger.yml`.
- 2026-01-16: Gemini CLI 0.24.0; new session message fields (`model`, `tokens`, `thoughts`) and assistant `type: gemini` in current sessions. Updated stage0 fixtures and bumped verified version. Evidence: `Resources/Fixtures/stage0/agents/gemini/small.json`, `Resources/Fixtures/stage0/agents/gemini/large.json`, `docs/agent-support/agent-support-matrix.yml`, `docs/agent-support/agent-support-ledger.yml`.
- 2026-01-16: OpenCode 1.1.23; bumped stage0 v2 session fixture versions and verified version record. Evidence: `Resources/Fixtures/stage0/agents/opencode/storage_v2/session/proj_test/ses_s_stage0_small.json`, `Resources/Fixtures/stage0/agents/opencode/storage_v2/session/proj_test/ses_s_stage0_large.json`, `docs/agent-support/agent-support-matrix.yml`, `docs/agent-support/agent-support-ledger.yml`.
- 2026-01-16: Copilot sessions; weekly drift baseline now includes `assistant.turn_start/end` and `session.truncation` envelope types to avoid false-positive schema drift. Evidence: `Resources/Fixtures/stage0/agents/copilot/schema_drift.jsonl`.
- 2026-01-24: Weekly monitoring run; Codex CLI 0.89.0 and Claude Code 2.1.19 verified via local schema comparison. Updated stage0 fixtures and bumped verified versions; extended weekly drift monitoring to compute schema diffs for Gemini and OpenCode sessions. Evidence: `scripts/probe_scan_output/agent_watch/20260124-001944Z/report.json`, `Resources/Fixtures/stage0/agents/codex/small.jsonl`, `Resources/Fixtures/stage0/agents/claude/small.jsonl`, `docs/agent-support/agent-support-matrix.yml`, `docs/agent-support/agent-support-ledger.yml`, `docs/agent-support/agent-watch-config.json`, `scripts/agent_watch.py`.
- 2026-02-24: OpenClaw format coverage refreshed; added stage0 fixtures and parser validation to keep `session` and `message` log variants under local schema watch. Evidence: `Resources/Fixtures/stage0/agents/openclaw/small.jsonl`, `Resources/Fixtures/stage0/agents/openclaw/large.jsonl`, `Resources/Fixtures/stage0/agents/openclaw/schema_drift.jsonl`, `docs/agent-support/agent-support-matrix.yml`, `docs/agent-support/agent-support-ledger.yml`, `docs/agent-support/agent-watch-config.json`, `scripts/agent_watch.py`, `scripts/scan_tool_formats.py`, `scripts/capture_latest_agent_sessions.py`.
- 2026-02-24: Weekly monitor with active usage probes; bumped verified versions for low-risk agents: Codex CLI `0.104.0`, Claude Code `2.1.51`, Gemini CLI `0.28.0`, and Copilot CLI `0.0.411`. Claude usage probe succeeded (`session_5h=98%`, `week_all_models=100%`). OpenCode and Droid were not bumped from this run (`medium`/`high` recommendations). Evidence: `scripts/probe_scan_output/agent_watch/20260224-020414Z/report.json`, `docs/agent-support/agent-support-matrix.yml`, `docs/agent-support/agent-support-ledger.yml`.

## Known Format Changes (From Docs)
- 2025-12 summary: Claude sessions split embedded thinking/tool blocks into separate events.
- 2025-12 summary: Gemini sessions parse embedded toolCalls and treat type=info entries as metadata.
- 2025-12 summary: OpenCode storage schema migration=2 requires parsing storage/part msg_*/prt_*.json.
- 2.8.1 changelog: OpenCode older sessions now read user messages from summary.title (not summary.body).
- 2.8 changelog: OpenCode support added (storage layout and parsing introduced).

## Agent Notes

### Codex CLI
- Session roots: `$CODEX_HOME/sessions` or `~/.codex/sessions`
- File pattern: `rollout-YYYY-MM-DDThh-mm-ss-UUID.jsonl`
- Format notes:
  - JSONL, append-only; event kind inferred from `type` then `role` fallback.
  - Multiple timestamp key names and numeric/ISO variants (tolerant parse).
  - Image parts may be data: URLs or remote references; reasoning may include `encrypted_content`.
- Recent changes:
  - Skip Agents.md preamble in title parsing (2025-12 summary, commit 7e902e3).
  - Parsing hardening for schema drift (commit d75afd2).
  - 2026-03 audit: newer rollout files can emit `token_count` events where `payload.rate_limits` is present but `null`; Agent Sessions now treats those logs as missing current limit data instead of reusing older session-file limit snapshots.
- Parser entry points:
  - `AgentSessions/Services/SessionIndexer.swift`
  - `AgentSessions/Model/Session.swift`
  - `docs/session-storage-format.md`
- Fixtures:
  - `Resources/Fixtures/session_simple.jsonl`
  - `Resources/Fixtures/session_toolcall.jsonl`
  - `Resources/Fixtures/session_branch.jsonl`
  - `Resources/Fixtures/stage0/agents/codex/{small,large,schema_drift}.jsonl`

### Claude Code
- Session roots: `~/.claude/projects/**/<UUID>.jsonl` (also `~/.claude/history.jsonl` for global history)
- File pattern: `<UUID>.jsonl` per session; project root encoded in path.
- Format notes:
  - JSONL with nested message content at `message.content`.
  - `type` drives event kind; `isMeta` flags metadata lines.
  - Session metadata: `sessionId`, `cwd`, `gitBranch`, `version`.
- Recent changes:
  - Split embedded thinking/tool blocks into separate events (2025-12 summary).
  - Improved parsing for modern format, titles, and error detection (docs changelog).
  - Error classification tuned to avoid false positives (commit 8439b09).
- Parser entry points:
  - `AgentSessions/Services/ClaudeSessionParser.swift`
  - `docs/claude-code-session-format.md`
- Fixtures:
  - `Resources/Fixtures/stage0/agents/claude/{small,large,schema_drift}.jsonl`

### Gemini CLI
- Session roots: `~/.gemini/tmp/<projectHash>/chats/session-*.json` (fallback `~/.gemini/tmp/<projectHash>/session-*.json`)
- File pattern: `session-*.json` (JSON, not JSONL)
- Format notes:
  - Root shapes vary: object with `messages`, root array, or `object.history`.
  - Some entries embed tool calls; parser normalizes to SessionEvents.
- Recent changes:
  - Tool calls extracted and type=info mapped to metadata (2025-12 summary).
  - `run_shell_command` responses may embed structured output containing `Exit Code:`; parser prefers this path so terminal outputs preserve exit codes (2026-01-07 scan).
- Parser entry points:
  - `AgentSessions/Services/GeminiSessionParser.swift`
  - `AgentSessions/Services/GeminiSessionDiscovery.swift`
- Fixtures:
  - `Resources/Fixtures/stage0/agents/gemini/{small,large,schema_drift}.json`

### OpenCode
- Session roots: `~/.local/share/opencode/storage/session`
- File pattern: `ses_*.json` (session records); message and part JSON stored under `storage/message` and `storage/part`.
- Format notes:
  - Two storage schemas: legacy (v1) and v2 (migration=2).
  - v2 parts live in `storage/part/msg_<message-id>/prt_*.json`.
- Recent changes:
  - Migration=2 support and part parsing for user/assistant messages (2025-12 summary).
  - Older sessions: user messages read from `summary.title` (2.8.1 changelog).
  - Tool parts may carry non-zero exit codes under `state.metadata.exit` while `state.status` remains `completed`; parser classifies these as errors and appends exit code to tool output (2026-01-07 scan).
- Parser entry points:
  - `AgentSessions/Services/OpenCodeSessionParser.swift`
  - `AgentSessions/Services/OpenCodeSessionDiscovery.swift`
- Fixtures:
  - `Resources/Fixtures/stage0/agents/opencode/storage_v2/...`
  - `Resources/Fixtures/stage0/agents/opencode/storage_legacy/...`

### OpenClaw
- Session roots:
  - `~/.openclaw/agents/<agentId>/sessions/*.jsonl`
  - `~/.clawdbot/agents/<agentId>/sessions/*.jsonl`
  - `$OPENCLAW_STATE_DIR/agents/<agentId>/sessions/*.jsonl`
- Format notes:
  - JSONL events with top-level `type` + nested `message`.
  - `type=message` supports `message.role` values: `user`, `assistant` (with `toolCall` blocks), and `toolResult`.
  - Optional meta events include `model_change` and `thinking_level_change`.
  - Housekeeping prompts may appear as `user` text and are filtered as lightweight metadata.
- Recent changes:
  - Stage0 fixtures and parse coverage added for small/large/schema-drift variants (2026-02-24).
- Parser entry points:
  - `AgentSessions/Services/OpenClawSessionParser.swift`
  - `AgentSessions/Services/OpenClawSessionDiscovery.swift`
- Fixtures:
  - `Resources/Fixtures/stage0/agents/openclaw/{small,large,schema_drift}.jsonl`

### GitHub Copilot CLI
- Session roots (two layouts; both supported):
  - **Legacy (<1.0):** `~/.copilot/session-state/<sessionId>.jsonl` — flat JSONL files at the root
  - **Current (1.0+):** `~/.copilot/session-state/<uuid>/events.jsonl` — JSONL inside a UUID subdirectory; additional metadata files (`workspace.yaml`, `checkpoints/`, etc.) in the same directory are not parsed
- Format notes:
  - JSONL event envelope: `{ type, data, id, timestamp, parentId }`.
  - Model changes recorded via `session.model_change`.
  - In 1.0+ sessions, the `session.start` `data.context` object includes git context (`cwd`, `gitRoot`, `branch`, `headCommit`, `repository`, `hostType`, `baseCommit`).
  - In 1.0+ sessions, `user.message` `data` includes `interactionId`; `assistant.message` `data` includes `messageId`, `outputTokens`, `interactionId`; `assistant.turn_start/end` include `turnId` and `interactionId`.
- Recent changes:
  - 2026-03-31 (v1.0.11): Storage layout changed from flat to subdirectory. Runtime patched in commit `f77040f`. Session ID for subdirectory layout is derived from the UUID directory name.
- Parser entry points:
  - `AgentSessions/Services/CopilotSessionParser.swift`
  - `AgentSessions/Services/SessionDiscovery.swift` (`CopilotSessionDiscovery`)
- Fixtures:
  - `Resources/Fixtures/stage0/agents/copilot/{small,large,schema_drift}.jsonl` — legacy flat layout (0.0.420)
  - `Resources/Fixtures/stage0/agents/copilot/subdir_v1/aaaabbbb-1111-2222-3333-ccccddddeeee/events.jsonl` — subdirectory layout (1.0.11)

### Droid (Factory CLI)
- Session roots:
  - Interactive store: `~/.factory/sessions/**/<sessionId>.jsonl`
  - Stream-json logs: `~/.factory/projects/**/*.jsonl` (best-effort)
- Format notes:
  - Two dialects:
    - Session store: `type=session_start` and `type=message` with `message.content[]` parts.
    - Stream-json: `type=system|message|tool_call|tool_result|completion`.
  - Stream-json timestamps may be ISO strings or epoch milliseconds; `session_id`/`sessionId` and tool call IDs may use snake or camel keys.
- Recent changes:
  - Support added in 2025-12 summary (no format changes noted yet).
  - Stream-json now includes `system.subtype=init`, `reasoning_effort`, tool IDs via `id`, `isError`, and `completion.usage` (2026-01-07 scan).
  - Stream-json `type=error` records are now parsed as `.error` events for failed/auth-blocked probes (2026-03-01 scan).
  - Active monitoring disabled on 2026-04-12. Keep fixtures/parser coverage for legacy imports only.
- Parser entry points:
  - `AgentSessions/Services/DroidSessionParser.swift`
  - `AgentSessions/Services/DroidSessionDiscovery.swift`
- Fixtures:
  - `Resources/Fixtures/stage0/agents/droid/{session_store_small,session_store_large,stream_json_small,stream_json_large,session_store_schema_drift,stream_json_schema_drift}.jsonl`

## Support Matrix Link
- `docs/agent-support/agent-support-matrix.yml`
- This memory bank references the matrix for "max verified" agent versions.

## Workflow
- Use `docs/agent-support/workflow.md` for the error-proof update process.
