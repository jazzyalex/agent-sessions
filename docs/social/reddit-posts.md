# Reddit Posts

One post per subreddit. Rotate over T+0 to T+2. Use a real account with history — no fresh accounts.

---

## r/ClaudeAI

**Title:** I built a macOS app to search and resume your Claude CLI sessions across a broader AI agent workspace

**Body:**

I kept losing track of Claude CLI sessions. Grepping through ~/.claude/sessions JSON files for a prompt I half-remembered from last week got old fast.

So I built Agent Sessions — a native macOS app that indexes your Claude CLI sessions locally and lets you search, browse, and resume them.

What it does:
- Full-text search across all your Claude CLI sessions
- Formatted transcript view with readable tool calls
- Right-click any session → Copy Resume Command → paste into terminal
- Agent Cockpit: live command center showing active/waiting/idle status with token usage tracking
- Usage tracking for Claude tokens (reads your local OAuth credentials, never transmits them)

It also supports Codex CLI/Desktop/VS Code, Hermes CLI, Pi CLI, Gemini CLI, GitHub Copilot CLI, OpenCode CLI, and OpenClaw CLI — with Claude Desktop sessions joining the same interface too.

Everything is local. No telemetry, no cloud, no account. Read-only access to your session files.

MIT licensed, macOS 14+.

[screenshot]

GitHub: https://github.com/jazzyalex/agent-sessions
Download DMG: https://github.com/jazzyalex/agent-sessions/releases/download/v3.8/AgentSessions-3.8.dmg

Happy to answer questions about how the session parsing works.

---

## r/ChatGPTCoding

**Title:** Open source macOS tool for browsing Codex CLI/Desktop/VS Code session history — also supports Claude CLI/Desktop, Hermes CLI, Pi CLI, Gemini CLI, GitHub Copilot CLI

**Body:**

If you use Codex CLI heavily, session history gets hard to manage fast — especially with subagent runs where worker sessions spin up all over the place.

I built Agent Sessions to fix this. Codex subagent sessions nest under their parent in the session list, so you can see exactly which worker did what, toggle the hierarchy with Cmd+H, and Agent Cockpit shows live subagent counts per session.

Features:
- Unified session list across Codex CLI/Desktop/VS Code, Claude CLI/Desktop, Hermes CLI, Pi CLI, Gemini CLI, GitHub Copilot CLI, OpenCode CLI, and OpenClaw CLI
- Subagent hierarchy for Codex
- Search across all sessions
- Right-click → Copy Resume Command
- Agent Cockpit live command center with usage tracking
- 100% local, MIT licensed

[screenshot-subagent-hierarchy.png]

GitHub: https://github.com/jazzyalex/agent-sessions

---

## r/commandline

**Title:** Agent Sessions: local-first session hub for AI coding tools across CLI and desktop surfaces

**Body:**

Built a native macOS tool for managing AI coding session history. Short version: it's a searchable, unified browser for Codex CLI/Desktop/VS Code, Claude CLI/Desktop, Hermes CLI, Pi CLI, Gemini CLI, GitHub Copilot CLI, OpenCode CLI, and OpenClaw CLI sessions.

Why I built it: I was grepping through JSON session files to find old prompts. Not fun.

What it does:
- Indexes all supported agent session directories locally (SQLite, no cloud)
- Full-text search across all agents
- Readable transcript view with tool calls parsed
- Right-click → Copy Resume Command (outputs the exact CLI invocation)
- Homebrew cask available

Install:
```
brew tap jazzyalex/agent-sessions
brew install --cask agent-sessions
```

MIT licensed. No telemetry. Not sandboxed (needs filesystem access to session dirs — explained in docs/security.md).

GitHub: https://github.com/jazzyalex/agent-sessions

---

## r/macapps

**Title:** Agent Sessions 3.8 — native macOS session hub for AI coding agents

**Body:**

Agent Sessions is a native Swift macOS app (macOS 14+) for browsing AI coding session history across CLI tools and desktop apps.

It reads session logs from Codex CLI/Desktop/VS Code, Claude CLI/Desktop, Hermes CLI, Pi CLI, Gemini CLI, GitHub Copilot CLI, OpenCode CLI, and OpenClaw CLI, and presents them in a unified interface.

App details:
- Native SwiftUI app, not an Electron wrapper
- Signed and notarized
- Sparkle automatic updates
- Light and dark mode
- No telemetry, no cloud account required

New in 3.8:
- Stronger Codex Desktop and Claude Desktop session support
- Pi CLI added to the supported lineup
- Archived/searchable Codex Desktop handling is much better

Free, MIT licensed.

[screenshot-H.png]
[screenshot-cockpit-light.png]

GitHub: https://github.com/jazzyalex/agent-sessions
Download: https://github.com/jazzyalex/agent-sessions/releases/download/v3.8/AgentSessions-3.8.dmg

---

## r/opensource

**Title:** Agent Sessions: MIT-licensed macOS app for browsing AI coding CLI sessions locally

**Body:**

Sharing a project I've been building: Agent Sessions, a local-first macOS app for browsing and searching AI coding CLI session history.

Supports: Codex CLI/Desktop/VS Code, Claude CLI/Desktop, Hermes CLI, Pi CLI, Gemini CLI, GitHub Copilot CLI, OpenCode CLI, OpenClaw CLI.

Open source highlights:
- MIT licensed (top-level LICENSE file)
- No telemetry, no analytics, no crash reporting
- Read-only access to session files
- SQLite local index, no cloud storage
- CI on every push (xcodebuild)
- Contributions welcome — especially new agent parsers

The easiest contribution is adding support for a new agent: add a SessionSource case, implement a parser + discovery, add fixtures, add tests. The session format docs are in docs/claude-code-session-format.md and similar.

GitHub: https://github.com/jazzyalex/agent-sessions

If you use an AI coding CLI that isn't listed, I'd love session format samples.
