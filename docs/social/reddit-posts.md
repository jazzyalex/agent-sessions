# Reddit Posts

One post per subreddit. Rotate over T+0 to T+2. Use a real account with history — no fresh accounts.

---

## r/ClaudeAI

**Title:** I built a macOS app to search and resume your Claude Code sessions (and 6 other AI coding CLIs)

**Body:**

I kept losing track of Claude Code sessions. Grepping through ~/.claude/sessions JSON files for a prompt I half-remembered from last week got old fast.

So I built Agent Sessions — a native macOS app that indexes your Claude Code sessions locally and lets you search, browse, and resume them.

What it does:
- Full-text search across all your Claude Code sessions
- Formatted transcript view with readable tool calls
- Right-click any session → Copy Resume Command → paste into terminal
- Agent Cockpit: live HUD showing active/waiting/idle status with token usage tracking
- Usage tracking for Claude tokens (reads your local OAuth credentials, never transmits them)

It also supports Codex CLI, Gemini CLI, Copilot CLI, Droid, OpenCode, and OpenClaw — same interface for all of them.

Everything is local. No telemetry, no cloud, no account. Read-only access to your session files.

MIT licensed, macOS 14+.

[screenshot]

GitHub: https://github.com/jazzyalex/agent-sessions
Download DMG: https://github.com/jazzyalex/agent-sessions/releases/download/v3.4/AgentSessions-3.4.dmg

Happy to answer questions about how the session parsing works.

---

## r/ChatGPTCoding

**Title:** Open source macOS tool for browsing Codex CLI session history — also supports Claude, Gemini, Copilot

**Body:**

If you use Codex CLI heavily, session history gets hard to manage fast — especially with subagent runs where worker sessions spin up all over the place.

I built Agent Sessions to fix this. New in v3.4: Codex subagent sessions now nest under their parent in the session list. You can see exactly which worker did what, toggle the hierarchy with Cmd+H, and Agent Cockpit shows live subagent counts per session.

Features:
- Unified session list across Codex CLI, Claude Code, Gemini CLI, Copilot CLI, Droid, OpenCode
- Subagent hierarchy for Codex (new in 3.4)
- Search across all sessions
- Right-click → Copy Resume Command
- Agent Cockpit live HUD with usage tracking
- 100% local, MIT licensed

[screenshot-subagent-hierarchy.png]

GitHub: https://github.com/jazzyalex/agent-sessions

---

## r/commandline

**Title:** Agent Sessions: local-first session browser for terminal AI coding tools (Codex, Claude, Gemini, Copilot, OpenCode)

**Body:**

Built a native macOS tool for managing AI coding CLI session history. Short version: it's a searchable, unified browser for ~/.codex/sessions, ~/.claude/sessions, ~/.gemini/tmp, and the session dirs for Copilot CLI, Droid, OpenCode, and OpenClaw.

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

**Title:** Agent Sessions 3.4 — native macOS session browser for AI coding CLIs

**Body:**

Agent Sessions is a native Swift macOS app (macOS 14+) for browsing AI coding CLI session history.

It reads session logs from Codex CLI, Claude Code, Gemini CLI, GitHub Copilot CLI, Droid, OpenCode, and OpenClaw, and presents them in a unified interface.

App details:
- Native SwiftUI app, not an Electron wrapper
- Signed and notarized
- Sparkle automatic updates
- Light and dark mode
- No telemetry, no cloud account required

New in 3.4:
- Codex subagent sessions nest under their parent
- Agent Cockpit HUD shows live subagent counts
- Fixed a CPU drain from an idle animation loop

Free, MIT licensed.

[screenshot-H.png]
[screenshot-cockpit-light.png]

GitHub: https://github.com/jazzyalex/agent-sessions
Download: https://github.com/jazzyalex/agent-sessions/releases/download/v3.4/AgentSessions-3.4.dmg

---

## r/opensource

**Title:** Agent Sessions: MIT-licensed macOS app for browsing AI coding CLI sessions locally

**Body:**

Sharing a project I've been building: Agent Sessions, a local-first macOS app for browsing and searching AI coding CLI session history.

Supports: Codex CLI, Claude Code, Gemini CLI, GitHub Copilot CLI, Droid (Factory CLI), OpenCode, OpenClaw.

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
