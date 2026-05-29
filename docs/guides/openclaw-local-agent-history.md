# OpenClaw Local Agent History: Browse OpenClaw Sessions on macOS

OpenClaw sessions can contain the practical audit trail of a coding task: the prompt, assistant response, tool call, tool result, model change, compaction, and project path. Agent Sessions reads that local history and makes OpenClaw sessions searchable beside the other coding agents you use on macOS.

Agent Sessions supports OpenClaw JSONL session transcripts and legacy Clawdbot paths. It intentionally ignores trajectory trace files so search and evidence focus on user-visible session transcripts.

![Agent Sessions showing full-text search across local AI coding-agent sessions with a transcript preview.](../assets/session-search-dark.png)

## Where OpenClaw Stores Local Data

Agent Sessions discovers OpenClaw sessions under:

```text
~/.openclaw/agents/<agent-id>/sessions/*.jsonl
```

It also supports the legacy Clawdbot location:

```text
~/.clawdbot/agents/<agent-id>/sessions/*.jsonl
```

If `OPENCLAW_STATE_DIR` is set, Agent Sessions uses that state root instead. Deleted transcript files can still be shown when the OpenClaw deleted-session preference is enabled.

Trajectory files are excluded:

```text
*.trajectory.jsonl
```

Those traces are not the normal transcript surface users expect to browse.

## What Agent Sessions Does With OpenClaw History

Agent Sessions turns OpenClaw local history into a macOS session browser:

- Lists OpenClaw sessions across agent IDs.
- Full-text searches transcript content.
- Shows user prompts, assistant text, tool calls, tool results, and metadata events.
- Preserves deleted-session visibility for OpenClaw transcript files when enabled.
- Keeps OpenClaw rows labeled separately from Codex, Claude, Cursor Agent, OpenCode, Hermes, Gemini, Copilot, and Pi.
- Supports OpenClaw resume workflows when the installed command exposes the required session flags.

OpenClaw session-format support is verified through OpenClaw 2026.5.27 with normal session-file evidence.

## What This Does Not Do

Agent Sessions does not:

- Treat trajectory traces as user-facing sessions.
- Write into OpenClaw state.
- Restore deleted OpenClaw files that no longer exist locally.
- Upload OpenClaw transcripts to a hosted search service.
- Replace OpenClaw's own command-line interface.

It is a read-only browser over local OpenClaw transcript history.

## When This Is Useful

This helps when:

- You need to find an old OpenClaw tool output, file path, or decision.
- You want deleted OpenClaw transcript visibility without mixing in trajectory traces.
- You use OpenClaw alongside Cursor Agent, Hermes, Codex, Claude, OpenCode, Gemini, Copilot, or Pi.
- A built-in recent-session picker does not provide enough transcript context.

![Agent Sessions showing local AI coding-agent histories across Codex, Claude, Gemini, OpenCode, Hermes, Copilot, OpenClaw, Cursor, and Pi.](../assets/session-all-agents-dark.png)

## Sources

- [Agent Sessions OpenClaw discovery](../../AgentSessions/Services/OpenClawSessionDiscovery.swift)
- [Agent Sessions OpenClaw parser](../../AgentSessions/Services/OpenClawSessionParser.swift)
- [Agent Sessions support ledger](../agent-support/agent-support-ledger.yml)
