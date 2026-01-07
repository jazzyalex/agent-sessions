# Impact Scan Heuristics

Use this checklist when a newer agent version appears.

## Two-Signal Rule
Do not declare a format change unless two independent signals agree, for example:
- Release notes mention storage or schema changes, plus a diff indicates new paths/fields.
- Diff indicates storage changes, plus a sample log confirms it.

## Common Signals
- New or renamed session directories.
- New file extensions or patterns (jsonl -> json, ndjson, etc).
- Migration flags (e.g., `migration=2`).
- Renamed keys in events (`message`, `content`, `summary`, `toolCalls`).
- New nested structures for tool results or multimodal content.

## Agent-Specific Paths
- Codex CLI: `~/.codex/sessions/**/rollout-*.jsonl`
- Claude Code: `~/.claude/projects/**/<uuid>.jsonl`, `~/.claude/history.jsonl`
- Gemini CLI: `~/.gemini/tmp/<hash>/chats/session-*.json`, fallback `session-*.json`
- Copilot CLI: `~/.copilot/session-state/*.jsonl`
- OpenCode: `~/.local/share/opencode/storage/{session,message,part}/`
- Droid: `~/.factory/sessions/**/<id>.jsonl`, `~/.factory/projects/**/*.jsonl`

## Diff Targets (When Available)
Search for:
- `jsonl`, `ndjson`, `session`, `history`, `migration`, `schema`, `message`, `summary`
- `sessionId`, `parentId`, `toolCalls`, `tool_use`, `tool_result`
