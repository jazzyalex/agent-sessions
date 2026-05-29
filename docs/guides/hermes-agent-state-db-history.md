# Hermes Agent State Database History: Browse Hermes Sessions on macOS

Hermes Agent writes useful local project history: prompts, assistant responses, tool calls, command output, reasoning metadata, model changes, and working-directory context. Agent Sessions reads that history locally so Hermes sessions can be searched beside other coding-agent sessions on your Mac.

Current Hermes support is focused on the local Hermes session store. Agent Sessions reads the current SQLite state database first, then falls back to older JSON session files when needed.

![Agent Sessions showing full-text search across local AI coding-agent sessions with a transcript preview.](../assets/session-search-dark.png)

## Where Hermes Stores Local Data

Current Hermes versions use:

```text
~/.hermes/state.db
```

Older Hermes installs may still have JSON session files:

```text
~/.hermes/sessions/session_*.json
```

Agent Sessions checks `state.db` first. If the database exists and contains sessions, it reads session and message rows from that database. If the database is absent or empty, it falls back to the legacy JSON files.

## What Agent Sessions Does With Hermes History

Agent Sessions turns Hermes local history into a searchable macOS session browser:

- Lists Hermes sessions by time and project context.
- Reads `model_config` working-directory data when available.
- Full-text searches Hermes transcript text.
- Shows user messages, assistant responses, tool calls, tool results, and metadata events.
- Keeps Hermes rows labeled separately from Codex, Claude, Cursor Agent, OpenCode, OpenClaw, Gemini, Copilot, and Pi.
- Supports Hermes resume workflows when the installed Hermes command exposes the required session flags.

Hermes session-format support is verified through Hermes 0.15.0 with `~/.hermes/state.db` evidence.

## What This Does Not Do

Agent Sessions does not:

- Write into `~/.hermes/state.db`.
- Recover history that Hermes never wrote locally.
- Upload Hermes transcripts to a hosted index.
- Replace Hermes' own command-line interface.
- Treat hidden runtime state as recoverable transcript history.

It is a read-only path over local history that already exists on the Mac.

## When This Is Useful

This helps when:

- You need to find an old Hermes command output or tool result.
- You remember a phrase but not the project or session.
- Hermes work is split across multiple repos.
- You use Hermes alongside Cursor Agent, Claude Code, Codex, OpenCode, OpenClaw, Gemini, Copilot, or Pi.

![Agent Sessions showing local AI coding-agent histories across Codex, Claude, Gemini, OpenCode, Hermes, Copilot, OpenClaw, Cursor, and Pi.](../assets/session-all-agents-dark.png)

## Sources

- [Agent Sessions Hermes discovery](../../AgentSessions/Services/HermesSessionDiscovery.swift)
- [Agent Sessions Hermes parser](../../AgentSessions/Services/HermesSessionParser.swift)
- [Agent Sessions Hermes indexer](../../AgentSessions/Services/HermesSessionIndexer.swift)
- [Agent Sessions support ledger](../agent-support/agent-support-ledger.yml)
