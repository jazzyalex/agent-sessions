# Agent JSON Tracking Memory Bank

This document tracks agent session/log formats, parsing assumptions, and known format changes.
Update this file when:
- A new upstream agent version changes session storage or JSON/JSONL structure.
- Agent Sessions parsing is updated to handle a new format or migration.
- Fixtures/tests are added or updated to cover format drift.

## Last Scan (Repo)
- Repo commit: 3429971 (latest in this worktree)
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
- 2026-01-07: Gemini CLI 0.23.0 + OpenCode CLI 1.1.6; confirmed tool-output drift (exit codes embedded in Gemini functionResponse output; OpenCode tool parts expose `state.metadata.exit`). Evidence: `Resources/Fixtures/stage0/agents/gemini/large.json`, `Resources/Fixtures/stage0/agents/opencode/storage_v2/part/m_assistant_large_1/001.json`.
- 2026-01-07: Droid CLI 0.43.0; sources `https://app.factory.ai/cli`, `https://docs.factory.ai/changelog/cli-updates`, `https://github.com/factory-ai/factory`; stream-json now emits numeric epoch timestamps, `tool_call`/`tool_result` IDs via `id`, `isError` flags, and `completion.usage` fields. Evidence: `Resources/Fixtures/stage0/agents/droid/stream_json_schema_drift.jsonl`.
- 2026-01-07: Verification bump (no schema drift observed in local sessions vs stage0 baselines): Codex CLI 0.79.0, Claude Code 2.0.76 (sessions), OpenCode 1.1.6, Gemini CLI 0.23.0, Droid CLI 0.43.0. Evidence: `docs/agent-support/agent-support-matrix.yml`, `docs/agent-support/agent-support-ledger.yml`, updated fixtures under `Resources/Fixtures/stage0/agents/`.
  - Note: Claude usage/limits probes may fail when upstream has an active incident; monitoring records `status.claude.com` context via `scripts/claude-status`.
- 2026-01-16: Claude Code 2.1.9; new `system` and `queue-operation` event families plus additional per-event metadata keys (`slug`, `isMeta`, `todos`, `thinkingMetadata`, `sourceToolAssistantUUID`). Updated stage0 fixtures and meta-type classification to keep transcripts and drift monitoring stable. Evidence: `Resources/Fixtures/stage0/agents/claude/small.jsonl`, `Resources/Fixtures/stage0/agents/claude/large.jsonl`, `AgentSessions/Model/SessionEvent.swift`, `docs/agent-support/agent-support-matrix.yml`, `docs/agent-support/agent-support-ledger.yml`.

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

### GitHub Copilot CLI
- Session roots: `~/.copilot/session-state/<sessionId>.jsonl`
- Format notes:
  - JSONL event envelope: `{ type, data, id, timestamp, parentId }`.
  - Model changes recorded via `session.model_change`.
- Recent changes:
  - Support added in 2025-12 summary (no format changes noted yet).
- Parser entry points:
  - `AgentSessions/Services/CopilotSessionParser.swift`
  - `AgentSessions/Services/SessionDiscovery.swift` (Copilot)
- Fixtures:
  - `Resources/Fixtures/stage0/agents/copilot/{small,large,schema_drift}.jsonl`

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
