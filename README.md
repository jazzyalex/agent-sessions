# Agent Sessions (macOS)

[![Build](https://github.com/jazzyalex/agent-sessions/actions/workflows/ci.yml/badge.svg)](https://github.com/jazzyalex/agent-sessions/actions/workflows/ci.yml)

<table>
<tr>
<td width="100" align="center">
  <img src="docs/assets/app-icon-512.png" alt="App Icon" width="80" height="80"/>
</td>
<td>

**Live per-session quota burn for Codex and Claude — see *which* session is eating your 5-hour and weekly limits, priced per model.**
Plus a searchable history across [Codex](https://jazzyalex.github.io/agent-sessions/guides/codex-local-history.html?campaign=github&ref=readme-guide), [Claude](https://jazzyalex.github.io/agent-sessions/guides/claude-code-jsonl-history.html?campaign=github&ref=readme-guide), [OpenCode](https://jazzyalex.github.io/agent-sessions/guides/opencode-sqlite-history.html?campaign=github&ref=readme-guide), [Cursor](https://jazzyalex.github.io/agent-sessions/guides/cursor-agent-local-history.html?campaign=github&ref=readme-guide), GitHub Copilot CLI, Pi, Kimi Code, Antigravity CLI, [Hermes](https://jazzyalex.github.io/agent-sessions/guides/hermes-agent-state-db-history.html?campaign=github&ref=readme-guide), and [OpenClaw](https://jazzyalex.github.io/agent-sessions/guides/openclaw-local-agent-history.html?campaign=github&ref=readme-guide) — transcripts, images, and one-click resume. macOS, local-only.

[**Session Bench**](https://jazzyalex.github.io/agent-sessions/bench/?campaign=github&ref=readme): how ten agents' session formats score — 19 pass/fail gates, evidence behind every cell.

</td>
</tr>
</table>

> If Agent Sessions hands you back something you thought you'd lost, **[star the repo](https://github.com/jazzyalex/agent-sessions)**. It is the only thing this project asks for.

- Requires: macOS 14+
- License: MIT
- Security & Privacy: Local-only. No telemetry. Details: `docs/PRIVACY.md` and `docs/security.md`

<p align="center">
  <a href="https://github.com/jazzyalex/agent-sessions/releases/download/v4.7/AgentSessions-4.7.dmg"><b>Download Agent Sessions 4.7 (DMG)</b></a>
  •
  <a href="https://github.com/jazzyalex/agent-sessions/releases">All Releases</a>
  •
  <a href="#install">Install</a>
  •
  <a href="#resume-workflows">Resume Workflows</a>
  •
  <a href="#development">Development</a>
</p>

> **New in 4.7** — Kimi Code joins as the tenth current agent source, active Claude cloud sessions appear in the Quota Meter, and Pi and Cursor sessions get back the working directory their resume commands and project filters depend on. [See what's new ↓](#whats-new-in-47)

## Overview

Run three agents at once and a normal quota meter tells you "60% used" — not which one spent it. Agent Sessions attributes burn to the **individual session**, live, against your Codex and Claude 5-hour and weekly windows. Pick the lens you want (5-hour, weekly, tokens/hour, or dollars); the `$` lens prices each model in a session at its own rate, so an Opus orchestrator driving Sonnet subagents is costed per model instead of blended into one number.

It's also a local-first Mac app for finding useful work coding agents already wrote to disk — Codex, Claude, OpenCode, Cursor Agent, Hermes, OpenClaw, Antigravity, GitHub Copilot CLI, Pi, and Kimi Code histories in one searchable view, with transcript inspection, image browsing, saved-session recovery, and resume commands for supported CLIs.

<div align="center">
  <p style="margin:0 0 0px 0;"><em>Session Runway — live per-session quota burn-rate</em></p>
  <img src="docs/assets/quota-meter-runway-rate-small.gif" alt="Quota Meter with Session Runway showing live per-session quota burn-rate bars" width="100%" style="max-width:640px;border-radius:8px;margin:5px 0;"/>

  <p style="margin:0 0 0px 0;"><em>Sessions search with transcript and image preview</em></p>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/assets/sessions-overview-dark.png">
    <img src="docs/assets/sessions-overview-light.png" alt="Main Sessions window with local agent history and transcript preview" width="100%" style="max-width:960px;border-radius:8px;margin:5px 0;"/>
  </picture>

  <p style="margin:0 0 0px 0;"><em>Saved Sessions with restore actions</em></p>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/assets/saved-sessions-dark.png">
    <img src="docs/assets/screenshot-V.png" alt="Saved Sessions window listing stored sessions and restore actions" width="100%" style="max-width:960px;border-radius:8px;margin:5px 0;"/>
  </picture>

  <p style="margin:0 0 0px 0;"><em>Image Browser for visual session outputs</em></p>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/assets/image-browser-dark.png">
    <img src="docs/assets/image-browser-light.png" alt="Image Browser window with thumbnail grid and selected screenshot preview" width="100%" style="max-width:960px;border-radius:8px;margin:5px 0;"/>
  </picture>
</div>

## Security & Privacy

- Local-first: session data stays on your Mac.
- No telemetry, analytics, remote logging, advertising identifiers, or session-history uploads.
- Reads local session folders you choose, plus supported default CLI locations.
- Builds local indexes/databases for search and navigation.
- Explicit actions may open Terminal/iTerm2 resume commands or run status/probe cleanup workflows.
- The only network activity is optional Sparkle update checks and an optional read-only fetch of a public model-price list (for the runway's $ estimate) — neither sends any personal or session data.

Details: `docs/PRIVACY.md` and `docs/security.md`.

## What's New in 4.7

**TL;DR** - Kimi Code is the tenth current agent source Agent Sessions reads, active Claude cloud sessions now show up in the Quota Meter, and a working-directory bug that quietly broke resume commands and project filtering for Pi and Cursor is fixed.

New in 4.7:
- **Kimi Code, the tenth current agent source** — sessions in the list, in search and in Analytics, with tool calls and assistant output in the transcript, a toolbar filter pill, Copy Resume Command and terminal resume. It switches itself on when Kimi Code is on your Mac.
- **Claude cloud sessions in the Quota Meter** — sessions running on Anthropic's infrastructure were invisible outside Claude Desktop; they now sit beside your local agents, marked Cloud. Off by default, offered once you have saved a claude.ai cookie.
- **Pi and Cursor get their working directory back** — resume commands came back without the `cd`, and the search index stored no path at all, so filtering by project silently missed those sessions. History you already have is repaired in the background after you update.
- **A resume that fails now says so** — every failure reason produced an error nothing displayed, so a refused launch looked exactly like no launch. Warp in particular used to report success when it never opened.
- **Checking an agent's CLI no longer freezes the window** — eight of the agent coordinators probed binaries on the main thread with no timeout, so a slow shell profile hung the whole app.

**Recent releases** — 4.6.4: Compact and Full Agent Cockpit retired, leaving the Quota Meter as the only mode. 4.6.3: the footer usage meters can finally be switched off. 4.6.2: Codex guardian sessions nest under their parent instead of duplicating it. 4.6: paste-a-cookie Claude web usage, no CLI or Full Disk Access needed. Full history in the [changelog](docs/CHANGELOG.md).

## Core Features

- Browse and search [Codex CLI, Codex Desktop, and Codex VS Code sessions](https://jazzyalex.github.io/agent-sessions/guides/codex-local-history.html?campaign=github&ref=readme-guide) in one place.
- Browse [Claude CLI and Claude Desktop sessions](https://jazzyalex.github.io/agent-sessions/guides/claude-code-jsonl-history.html?campaign=github&ref=readme-guide) with consistent labels and project context.
- Browse [Cursor Agent transcripts](https://jazzyalex.github.io/agent-sessions/guides/cursor-agent-local-history.html?campaign=github&ref=readme-guide) from Cursor's local storage, enriched with Cursor chat metadata when available.
- [Hermes Agent sessions](https://jazzyalex.github.io/agent-sessions/guides/hermes-agent-state-db-history.html?campaign=github&ref=readme-guide) participate in browsing, search, filtering, analytics, and resume workflows, including current `~/.hermes/state.db` storage.
- [OpenClaw sessions](https://jazzyalex.github.io/agent-sessions/guides/openclaw-local-agent-history.html?campaign=github&ref=readme-guide) participate in browsing, search, filtering, deleted-session visibility, and resume workflows while ignoring trajectory traces.
- Pi CLI sessions now participate in browsing, search, filtering, and resume workflows.
- Unified browsing across supported agents, with strict filtering, saved sessions, and a single session list.
- Unified Search and Image Browser across sessions, plus in-session Find for fast transcript navigation.
- Readable tool calls/outputs and navigation between prompts, tools, and errors.
- Right-click Copy Resume Command or Resume for supported CLI sessions, with Terminal.app, iTerm2, and Warp launch targets.
- Quota Meter with Session Runway shows **live burn rate per session** against your Codex and Claude 5-hour and weekly limits — in percent, tokens/hour, or dollars priced per model.
- Local-only indexing designed for large histories.

## Quota Meter — Session Runway

An ordinary quota meter says "60% used." It won't say which of your three running agents spent it. The Quota Meter attributes burn to the **individual session**, live, against your Codex and Claude 5-hour and weekly windows.

- **Per-session burn bars** — each active session gets its own rate against the live window, so you know which one to stop.
- **Four lenses** — 5-hour, weekly, tokens/hour, or dollars; chosen from the meter and remembered.
- **Priced per model** — the `$` lens rates each model in a session at its own rate, so an Opus orchestrator driving Sonnet subagents is costed at what each actually runs at rather than blended into one number.
- **Honest states** — a calm "no limit" when a provider drops a window, and "can't verify" rather than a wrong number if usage data changes shape.
- **Stays where you put it** — drag it anywhere, right-click for controls. Show or hide it from the View menu (⌘⌥⇧C).

<div align="center">
  <img src="docs/assets/quota-meter-light.png" alt="Quota Meter showing Codex and Claude 5h/weekly limits with Session Runway per-session burn-rate bars" width="100%" style="max-width:770px;border-radius:8px;margin:5px 0 22px;"/>
</div>

## Quota Meter Setup

### Prerequisites

- Agent Sessions with live session detection enabled
- Agents running in a terminal, or in Codex or Claude Desktop

### Ideal Setup

Session rows read best when your terminal names them clearly:

- Set the terminal window title to the repo name
- Run that repo's agents in that window
- Give each tab/session its own clear name
- Use the same name for the tab, session, and badge

### Layout

- One repo per desktop/Space if possible
- Or keep several on one desktop if you prefer
- Keep the Quota Meter pinned in a corner so you can always see activity

## Install

### Option A — Download DMG
1. [Download AgentSessions-4.7.dmg](https://github.com/jazzyalex/agent-sessions/releases/download/v4.7/AgentSessions-4.7.dmg)
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

- Guides:
  - [Codex local history: search Codex CLI, Desktop, and VS Code sessions](https://jazzyalex.github.io/agent-sessions/guides/codex-local-history.html?campaign=github&ref=readme-guide)
  - [OpenCode SQLite history: browsing old runs](https://jazzyalex.github.io/agent-sessions/guides/opencode-sqlite-history.html?campaign=github&ref=readme-guide)
  - [Claude Code JSONL history: what you can recover locally](https://jazzyalex.github.io/agent-sessions/guides/claude-code-jsonl-history.html?campaign=github&ref=readme-guide)
  - [Cursor Agent local history: search Cursor Agent transcripts](https://jazzyalex.github.io/agent-sessions/guides/cursor-agent-local-history.html?campaign=github&ref=readme-guide)
  - [Hermes Agent state database history](https://jazzyalex.github.io/agent-sessions/guides/hermes-agent-state-db-history.html?campaign=github&ref=readme-guide)
  - [OpenClaw local agent history](https://jazzyalex.github.io/agent-sessions/guides/openclaw-local-agent-history.html?campaign=github&ref=readme-guide)
- Release notes: `docs/CHANGELOG.md`
- Monthly summaries: `docs/summaries/`
- Privacy: `docs/PRIVACY.md`
- Security: `docs/security.md`
- Maintainers: `docs/deployment.md`

## Resume Workflows

- Right-click any supported CLI session and choose **Copy Resume Command** to get the exact CLI command for that session.
- Open supported Resume sessions in your preferred terminal: Terminal.app, iTerm2, or Warp.
- Use Unified Search (across sessions) and Find (within a session) to jump to relevant tool calls and outputs quickly.

## Privacy & Security

- Local-only. No telemetry.
- Reads agent session directories in read-only mode:
  - `~/.codex/sessions`
  - `~/.claude/projects`
  - `~/.gemini/antigravity/brain`
  - `~/.copilot/session-state`
  - `~/.cursor/projects` and `~/.cursor/chats`
  - `~/.factory/sessions` and `~/.factory/projects`
  - `~/.hermes/state.db` and `~/.hermes/sessions`
  - `~/.openclaw/agents` and legacy `~/.clawdbot/agents`
  - `~/.pi/agent/sessions`
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

