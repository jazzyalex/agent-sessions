# Cursor Agent Local History: Search Cursor Agent Sessions on macOS

Cursor Agent sessions are useful long after the original run ends. They can contain the prompt, a tool call, a command output, or the exact file path that explains a change. Agent Sessions makes that local Cursor Agent history searchable in the same macOS browser as Codex, Claude, OpenCode, Hermes, OpenClaw, Gemini, Copilot, and Pi.

Agent Sessions supports Cursor Agent transcripts. It does not claim full Cursor IDE chat history support.

![Agent Sessions showing full-text search across local AI coding-agent sessions with a transcript preview.](../assets/session-search-dark.png)

## Where Cursor Agent Stores Local Data

Cursor Agent writes JSONL transcripts under the Cursor data directory:

```text
~/.cursor/projects/<project>/agent-transcripts/<session-id>/<session-id>.jsonl
```

Cursor also stores per-session chat metadata in SQLite databases:

```text
~/.cursor/chats/<workspace-hash>/<session-id>/store.db
```

Agent Sessions uses the JSONL transcript as the primary source for readable events. It reads the `store.db` metadata to enrich Cursor Agent sessions with names, model hints, timestamps, and workspace context when that metadata is available.

## What Agent Sessions Does With Cursor Agent History

Agent Sessions turns local Cursor Agent transcripts into searchable session history:

- Lists Cursor Agent sessions beside other local coding-agent sessions.
- Full-text searches transcript text.
- Shows user prompts, assistant responses, tool calls, and tool results from JSONL transcripts.
- Enriches sessions with Cursor chat metadata from `store.db`.
- Tracks Cursor Agent sessions separately from Codex, Claude, OpenCode, Hermes, OpenClaw, Gemini, Copilot, and Pi.
- Builds Cursor resume commands when the installed Cursor Agent command supports resume flags.

Cursor Agent support is verified against Cursor 3.5.38 using the Cursor app-bundled CLI at:

```text
/Applications/Cursor.app/Contents/Resources/app/bin/cursor
```

## What This Does Not Do

Agent Sessions does not:

- Parse every Cursor IDE chat from `store.db` when no Cursor Agent transcript exists.
- Decode Cursor's protobuf message blobs from DB-only chat history.
- Upload Cursor transcripts to a hosted search service.
- Write into Cursor's local databases.
- Replace Cursor's own chat or agent UI.

DB-only Cursor rows can appear as metadata-only sessions, but transcript viewing depends on the local `agent-transcripts` JSONL file.

## When This Is Useful

This helps when:

- You use Cursor Agent for coding work and need to find an old prompt or tool output.
- You remember a command, file path, or error but not the Cursor session.
- You want Cursor Agent history in the same browser as Claude Code, Codex, OpenCode, Hermes, OpenClaw, Gemini, Copilot, or Pi.
- Cursor's own recent-session UI is not enough context for a large local history.

![Agent Sessions showing local AI coding-agent histories across Codex, Claude, Gemini, OpenCode, Hermes, Copilot, OpenClaw, Cursor, and Pi.](../assets/session-all-agents-dark.png)

## Sources

- [Agent Sessions Cursor discovery](../../AgentSessions/Services/CursorSessionDiscovery.swift)
- [Agent Sessions Cursor transcript parser](../../AgentSessions/Services/CursorSessionParser.swift)
- [Agent Sessions Cursor chat metadata reader](../../AgentSessions/Cursor/CursorChatMetaReader.swift)
- [Agent Sessions Cursor indexer](../../AgentSessions/Services/CursorSessionIndexer.swift)
- [Agent Sessions support ledger](../agent-support/agent-support-ledger.yml)
