# Agent Sessions (macOS)

[![Build](https://github.com/jazzyalex/agent-sessions/actions/workflows/ci.yml/badge.svg)](https://github.com/jazzyalex/agent-sessions/actions/workflows/ci.yml)

<table>
<tr>
<td width="100" align="center">
  <img src="docs/assets/app-icon-512.png" alt="App Icon" width="80" height="80"/>
</td>
<td>

**Unified session browser for Codex CLI/Desktop/VS Code, Claude CLI/Desktop, Hermes CLI, Cursor CLI, Gemini CLI, GitHub Copilot CLI, OpenCode CLI, OpenClaw CLI, and Pi CLI sessions across CLI and desktop surfaces.**
Search, browse, and resume your past AI-coding sessions in a local-first macOS app.

</td>
</tr>
</table>

- Requires: macOS 14+
- License: MIT
- Security & Privacy: Local-only. No telemetry. Details: `docs/PRIVACY.md` and `docs/security.md`

<p align="center">
  <a href="https://github.com/jazzyalex/agent-sessions/releases/download/v3.8/AgentSessions-3.8.dmg"><b>Download Agent Sessions 3.8 (DMG)</b></a>
  •
  <a href="https://github.com/jazzyalex/agent-sessions/releases">All Releases</a>
  •
  <a href="#install">Install</a>
  •
  <a href="#resume-workflows">Resume Workflows</a>
  •
  <a href="#development">Development</a>
</p>

## Overview

Agent Sessions helps you search across large session histories, quickly find the right prompt/tool output, then reuse it by copying snippets or resuming supported sessions in your terminal.

<div align="center">
  <p style="margin:0 0 0px 0;"><em>Transcript view with search (Dark Mode)</em></p>
  <img src="docs/assets/screenshot-H.png" alt="Transcript view with search (Dark Mode)" width="100%" style="max-width:960px;border-radius:8px;margin:5px 0;"/>

  <p style="margin:0 0 0px 0;"><em>Resume Codex CLI, Claude CLI, and OpenCode CLI sessions</em></p>
  <img src="docs/assets/screenshot-V.png" alt="Resume Codex CLI, Claude CLI, and OpenCode CLI sessions" width="100%" style="max-width:960px;border-radius:8px;margin:5px;"/>
</div>

## Security & Privacy

- Local-first: session data stays on your Mac.
- No telemetry, analytics, remote logging, advertising identifiers, or session-history uploads.
- Reads local session folders you choose, plus supported default CLI locations.
- Builds local indexes/databases for search and navigation.
- Explicit actions may open Terminal/iTerm2 resume commands or run status/probe cleanup workflows.
- The only network activity is optional Sparkle update checks.

Details: `docs/PRIVACY.md` and `docs/security.md`.

## What's New in 3.8

**TL;DR** - Agent Sessions is expanding beyond CLI-only workflows into a broader session hub, and Pi CLI now joins the supported agent lineup.

**Highlights:** Agent Sessions now treats CLI and native-app sessions as part of one growing workspace. Codex Desktop and Claude Desktop sessions are easier to identify and filter, archived Codex Desktop sessions are easier to browse, and desktop chat/worktree rows now preserve clearer project context. Hermes CLI is now part of that broader searchable and resumable workspace, and Agent Sessions also adds tier-2 Pi CLI support with local JSONL discovery, browsing, search, Preferences controls, Pi-specific styling, and Resume/Copy Resume commands via `pi --session`.

## Core Features

- Agent Cockpit is the live command center for active Codex CLI, Claude CLI, and OpenCode CLI iTerm2 sessions.
- Browse and search Codex CLI, Codex Desktop, and Codex VS Code sessions in one place.
- Browse Claude CLI and Claude Desktop sessions with consistent labels and project context.
- Hermes CLI sessions participate in browsing, search, filtering, analytics, and resume workflows.
- Pi CLI sessions now participate in browsing, search, filtering, and resume workflows.
- Unified browsing across supported agents, with strict filtering and a single session list.
- Unified Search and image browsing across sessions, plus in-session Find for fast transcript navigation.
- Readable tool calls/outputs and navigation between prompts, tools, and errors.
- Right-click Copy Resume Command for Claude CLI, Codex CLI, OpenCode CLI, GitHub Copilot CLI, and Gemini CLI sessions.
- Local-only indexing designed for large histories.

## Agent Cockpit (Beta)

Agent Cockpit is the live command center for active iTerm2 Codex CLI, Claude CLI, and OpenCode CLI sessions, with shared active/waiting summaries and live Claude usage tracking.

<div align="center">
  <p style="margin:0 0 0px 0;"><em>Agent Cockpit</em></p>
  <img src="docs/assets/screenshot-cockpit-light.png" alt="Agent Cockpit in light mode" width="100%" style="max-width:820px;border-radius:8px;margin:5px 0;"/>
</div>

## Agent Cockpit Setup

### Prerequisites

- Agent Sessions with Live Sessions enabled
- iTerm2
- Agents running in iTerm2

### Ideal Setup

- Set the iTerm window title to the repo name
- Run that repo's agents in that window
- Give each tab/session its own clear name
- Use the same name for the tab, session, and badge

### Layout

- One repo per desktop/Space if possible
- Or keep several on one desktop if you prefer
- Keep Agent Cockpit pinned in a corner so you can always see activity
- Click from the cockpit to jump straight to a session

## Install

### Option A — Download DMG
1. [Download AgentSessions-3.8.dmg](https://github.com/jazzyalex/agent-sessions/releases/download/v3.8/AgentSessions-3.8.dmg)
2. Drag **Agent Sessions.app** into Applications.

### Option B — Homebrew
```bash
brew tap jazzyalex/agent-sessions
brew install --cask agent-sessions
```

### Automatic Updates (Sparkle)

Agent Sessions uses Sparkle for automatic updates (signed + notarized).

To force an update check (for testing):
```bash
defaults delete com.triada.AgentSessions SULastCheckTime
open "/Applications/Agent Sessions.app"
```

## Documentation

- Release notes: `docs/CHANGELOG.md`
- Monthly summaries: `docs/summaries/`
- Privacy: `docs/PRIVACY.md`
- Security: `docs/security.md`
- Maintainers: `docs/deployment.md`

## Resume Workflows

- Right-click any Claude CLI, Codex CLI, Cursor CLI, OpenCode CLI, GitHub Copilot CLI, or Gemini CLI session and choose **Copy Resume Command** to get the exact CLI command for that session.
- Open a session in your preferred terminal (Terminal.app or iTerm).
- Use Unified Search (across sessions) and Find (within a session) to jump to relevant tool calls and outputs quickly.

## Privacy & Security

- Local-only. No telemetry.
- Reads agent session directories in read-only mode:
  - `~/.codex/sessions`
  - `~/.claude/sessions`
  - `~/.gemini/tmp`
  - `~/.copilot/session-state`
  - `~/.cursor/projects` and `~/.cursor/chats`
  - `~/.factory/sessions` and `~/.factory/projects`
  - `~/.local/share/opencode/opencode.db` and `~/.local/share/opencode/storage/session`
- Details: `docs/PRIVACY.md` and `docs/security.md`

## Development

Prerequisites:
- Xcode (macOS 14+)

Build:
```bash
xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug -destination 'platform=macOS' build
```

Tests:
```bash
xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessionsTests -destination 'platform=macOS' test
```

Contributing:
- `CONTRIBUTING.md`

## License

MIT. See `LICENSE`.
