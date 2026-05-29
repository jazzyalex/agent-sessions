# OpenCode SQLite History: Browsing Old Runs

OpenCode sessions become useful project history quickly. A run may contain the failed command, a model explanation, a file path, or the decision that explains why code changed. The hard part is finding that material later, especially when work spans projects and terminal tabs.

Agent Sessions is built for that local-history layer. It reads local coding-agent session data on your Mac, gives it a visual browser, and lets you full-text search old runs without uploading transcripts.

![Agent Sessions showing full-text search across local AI coding-agent sessions with a transcript preview.](../assets/session-search-dark.png)

## Where OpenCode Stores Local Data

OpenCode's public troubleshooting docs point to local data under:

```text
~/.local/share/opencode
```

Current OpenCode source defines SQLite tables for session history, including `session`, `message`, `part`, `todo`, and `session_message`.

Agent Sessions supports the current SQLite-backed shape when this database exists:

```text
~/.local/share/opencode/opencode.db
```

It also keeps a fallback for older per-file JSON storage:

```text
~/.local/share/opencode/storage/session
```

The SQLite backend is preferred when `opencode.db` exists and contains a `session` table. Agent Sessions opens the database read-only, reads session metadata plus message/part rows, and leaves OpenCode's files untouched.

## What Agent Sessions Does With OpenCode History

Agent Sessions turns local OpenCode history into a macOS session browser:

- Lists old OpenCode sessions by project and time.
- Full-text searches transcript text.
- Opens old runs as readable timelines.
- Keeps OpenCode rows labeled separately from Codex, Claude Code, Gemini CLI, Cursor, Copilot CLI, Hermes, OpenClaw, and Pi.
- Copies or launches resume commands when the installed OpenCode CLI supports the needed flags.

For resume workflows, Agent Sessions checks local OpenCode CLI help for `--session` and `--continue`, then builds commands like:

```text
opencode --session <session-id>
opencode --continue
```

It can launch those through Terminal.app, iTerm2, Warp, or WarpPreview depending on your Agent Sessions preferences.

## What This Does Not Do

Agent Sessions is not an OpenCode replacement.

It does not:

- Fix OpenCode TUI rendering behavior.
- Recover hidden model/runtime state that was never written to disk.
- Migrate sessions between machines.
- Upload OpenCode transcripts to a hosted index.
- Write into OpenCode's database.

It is a local read path over history that already exists on the Mac.

## When This Is Useful

This helps when:

- An old OpenCode session contains the command, error, or design decision you need.
- A long terminal session is painful to scroll.
- You remember a phrase but not the project or session.
- Work is split across OpenCode and other agents.
- The built-in recent/session picker is not enough context.

![Agent Sessions showing local AI coding-agent histories across Codex, Claude, Gemini, OpenCode, Hermes, Copilot, OpenClaw, Cursor, and Pi.](../assets/session-all-agents-dark.png)

## Sources

- [OpenCode troubleshooting docs](https://opencode.ai/docs/troubleshooting/)
- [OpenCode session SQLite schema](https://github.com/anomalyco/opencode/blob/dev/packages/opencode/src/session/session.sql.ts)
- [Agent Sessions README](../../README.md)
- [Agent Sessions OpenCode backend detector](../../AgentSessions/OpenCode/OpenCodeBackendDetector.swift)
- [Agent Sessions OpenCode SQLite reader](../../AgentSessions/OpenCode/OpenCodeSqliteReader.swift)
