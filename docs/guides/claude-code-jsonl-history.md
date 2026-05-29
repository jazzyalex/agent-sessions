# Claude Code JSONL History: What You Can Recover Locally

Claude Code writes local session transcripts as JSONL. That matters because the transcript is often the useful part of an old run: the prompt, assistant response, tool call, command output, error, or file path that explains what happened.

Agent Sessions is built around that local-history layer. It gives Claude Code transcripts a searchable macOS browser without turning them into a hosted dashboard.

![Agent Sessions showing full-text search and a readable transcript preview for local AI coding-agent sessions.](../assets/session-search-dark.png)

## Where Claude Code Session History Lives

Anthropic's Claude Code session docs describe local session files under:

```text
~/.claude/projects/<encoded-cwd>/<session-id>.jsonl
```

The project directory is derived from the working directory, and each session is stored as its own JSONL file.

Agent Sessions currently scans Claude session files from:

```text
~/.claude
~/.claude/projects
CLAUDE_CONFIG_DIR
CLAUDE_CONFIG_DIRS
Claude Desktop local-agent-mode session roots
```

The important path for standard Claude Code local history is `~/.claude/projects`. Do not use older `~/.claude/sessions` wording for current public copy.

## What You Can Recover

If the information was written into the local transcript, Agent Sessions can help you find it:

- Old prompts and assistant responses.
- Tool calls and tool results.
- Command output.
- File paths and errors mentioned in the session.
- Old decisions or implementation notes.
- Sessions from multiple Claude Code projects.

The important boundary is transcript context versus hidden runtime/model state.

Transcript context is the durable text/event history that Claude Code wrote to disk. Hidden runtime/model state is not necessarily exposed as local files. Agent Sessions can search and display the former; it should not be described as recovering the latter.

## What Agent Sessions Does With Claude Code History

Agent Sessions gives Claude Code sessions:

- A local macOS browser.
- Full-text search across old transcripts.
- Readable timeline views.
- Source labels so Claude Code is not mixed with Codex, OpenCode, Gemini CLI, Cursor, Copilot CLI, Hermes, OpenClaw, or Pi rows.
- Filters by date, model, project, and event kind.
- Resume workflows where the underlying CLI supports resume.

It is local-first and does not upload transcripts.

## What This Does Not Do

Agent Sessions does not:

- Recover model state that Claude Code never wrote to disk.
- Guarantee that deleted local files can be restored.
- Replace Claude Code's own `/resume` behavior.
- Upload transcripts to a hosted memory service.
- Turn transcript history into persistent project memory automatically.

It is a read path over local transcript history.

## When This Is Useful

This helps when:

- You remember what Claude did but not which session did it.
- A project has many old Claude Code sessions.
- A built-in resume picker is not enough to identify the right run.
- You need to find a command output or file path from an earlier run.
- You use Claude Code alongside Codex, OpenCode, Gemini CLI, Cursor, or Copilot CLI.

![Agent Sessions showing local AI coding-agent histories across Codex, Claude, Gemini, OpenCode, Hermes, Copilot, OpenClaw, Cursor, and Pi.](../assets/session-all-agents-dark.png)

## Sources

- [Claude Code sessions docs](https://code.claude.com/docs/en/agent-sdk/sessions)
- [Agent Sessions README](../../README.md)
- [Agent Sessions Claude discovery](../../AgentSessions/Services/SessionDiscovery.swift)
- [Agent Sessions Claude session indexer](../../AgentSessions/Services/ClaudeSessionIndexer.swift)
- [Agent Sessions multi-Claude config dirs plan](../multi-claude-config-dirs-plan.md)
