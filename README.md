# Agent Sessions (macOS)

[![Build](https://github.com/jazzyalex/agent-sessions/actions/workflows/ci.yml/badge.svg)](https://github.com/jazzyalex/agent-sessions/actions/workflows/ci.yml)

<table>
<tr>
<td width="100" align="center">
  <img src="docs/assets/app-icon-512.png" alt="App Icon" width="80" height="80"/>
</td>
<td>

**Session management for [Codex](docs/guides/codex-local-history.html), [Claude](docs/guides/claude-code-jsonl-history.html), [OpenCode](docs/guides/opencode-sqlite-history.html), [Cursor](docs/guides/cursor-agent-local-history.html), GitHub Copilot CLI, Pi, Antigravity CLI, [Hermes](docs/guides/hermes-agent-state-db-history.html), and [OpenClaw](docs/guides/openclaw-local-agent-history.html) on macOS.**
Search, inspect, save, and resume local AI-coding sessions from CLI tools, desktop apps, and IDE agent surfaces.

</td>
</tr>
</table>

- Requires: macOS 14+
- License: MIT
- Security & Privacy: Local-only. No telemetry. Details: `docs/PRIVACY.md` and `docs/security.md`

<p align="center">
  <a href="https://github.com/jazzyalex/agent-sessions/releases/download/v4.6/AgentSessions-4.6.dmg"><b>Download Agent Sessions 4.6 (DMG)</b></a>
  •
  <a href="https://github.com/jazzyalex/agent-sessions/releases">All Releases</a>
  •
  <a href="#install">Install</a>
  •
  <a href="#resume-workflows">Resume Workflows</a>
  •
  <a href="#development">Development</a>
</p>

> **New in 4.6** — Read your Claude subscription usage without the CLI. If you don't run the Claude CLI, Agent Sessions reads usage over the web instead — but on macOS 14+ Safari stopped handing the claude.ai session to other apps. Now you paste your session cookie once in Settings; it lives in your Keychain, needs no Full Disk Access, and a **Test now** button confirms it works. [See what's new ↓](#whats-new-in-46)

## Overview

Agent Sessions is a local-first Mac app for finding useful work that coding agents already wrote to disk. It brings Codex, Claude, OpenCode, Cursor Agent, Hermes, OpenClaw, Antigravity, GitHub Copilot CLI, and Pi histories into one searchable view, with transcript inspection, image browsing, saved-session recovery, and resume commands for supported CLIs.

<div align="center">
  <p style="margin:0 0 0px 0;"><em>New in 4.0 — Session Runway: live per-session quota burn-rate</em></p>
  <img src="docs/assets/quota-meter-runway.gif" alt="Quota Meter with Session Runway showing live per-session quota burn-rate bars" width="100%" style="max-width:960px;border-radius:8px;margin:5px 0;"/>

  <p style="margin:0 0 0px 0;"><em>Sessions search with transcript and image preview</em></p>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/assets/session-all-agents-dark.png">
    <img src="docs/assets/session-history-light.png" alt="Main Sessions window with local agent history and transcript preview" width="100%" style="max-width:960px;border-radius:8px;margin:5px 0;"/>
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

## What's New in 4.6

**TL;DR** - Read your Claude subscription usage without the CLI. If you don't run the Claude CLI, Agent Sessions reads your usage over the web — but macOS 14+ Safari stopped sharing the claude.ai session with other apps, so that path had gone quiet. Paste your session cookie once in Settings and it works again: kept in your Keychain, no Full Disk Access, sign-in never leaves your browser.

**Highlights:** On macOS 14 and 15, Safari keeps the live claude.ai cookie in a store other apps can't read, so the Web API usage path had become a dead end for anyone without the Claude CLI. Now Settings → Usage Tracking accepts your claude.ai `sessionKey` (or the whole cookie header) and uses it directly for usage lookups — no scraping, no Full Disk Access. The app only holds the token you hand it, stored in the Keychain, and a **Test now** button confirms it on the spot. The old advice to "sign in at claude.ai" — impossible to satisfy on these macOS versions — is gone, replaced with honest, cause-aware messages that point to the fix that works. The Quota Meter also got two small touches: its right-click hint stays findable on every hover, and the agent row now marks which runway lens is live.

New in 4.6:
- **Paste-a-cookie Claude web usage** — hand Settings your claude.ai session cookie once; it reads your subscription usage over the web with no CLI, no Full Disk Access, and no scraping.
- **Kept in the Keychain** — the app stores only the token you paste, and a **Test now** button runs an end-to-end check.
- **Honest Web API messages** — no more "sign in at claude.ai" advice you can't act on; the guidance now points to the cookie paste that actually works.
- **Quota Meter polish** — the right-click hint recurs on hover, and the agent row marks the active runway lens (5h/Wk).

Previous release — 4.5: See what each session is costing you, and a Quota Meter that holds still. Full history in the [changelog](docs/CHANGELOG.md).

## What's New in 4.5

**TL;DR** - See what each session is costing you: the Session Runway can report every active session's API-equivalent spend per hour, priced per model. And the Quota Meter holds still — it no longer grows when your pointer crosses it, so you can drag it where you want it.

**Highlights:** The Session Runway now measures whatever you ask it to — **5-hour** burn, **weekly** share, raw **tokens/hour**, or **dollars**. The `$` rate prices each model in a session at its own rate, so an orchestrator on Opus driving subagents on Sonnet is costed at what each actually runs at rather than blended into one number. Meanwhile the Quota Meter stops fighting you: it used to expand whenever the pointer crossed it, moving the window while you were aiming at it. Now the pointer only moves it and **right-click** summons its controls. The cockpit also gets one View-menu entry for the whole choice — Quota Meter, Compact, Full, or **Off** — so the pinned window can finally be closed.

New in 4.5:
- **Dollar burn** — each active session's API-equivalent cost per hour, priced per model, not blended.
- **Selectable runway rates** — 5-Hour, Weekly, Tokens, or Dollars, chosen from the meter and remembered.
- **A Quota Meter that stays put** — no pointer-driven resizing; right-click for the toolbar; drag it anywhere.
- **One View-menu entry** — Quota Meter / Compact / Full / Off, with ⌘⌥⇧C and ⇧⌘M. ⌘W closes the cockpit.

Previous release — 4.4: Codex usage keeps working when OpenAI pauses the 5-hour limit. Full history in the [changelog](docs/CHANGELOG.md).

## What's New in 4.4

**TL;DR** - Codex usage keeps working when OpenAI pauses the 5-hour limit. Agent Sessions detects the change, shows a calm "no limit" for 5h while keeping your weekly usage accurate, and the Session Runway shows honest per-session token throughput instead of a misleading rate.

**Highlights:** OpenAI temporarily removed Codex's 5-hour rate-limit window, which left the Quota Meter mislabeling weekly usage as "5h" with the wrong reset. Agent Sessions now recognizes this automatically — the 5h line reads a calm **"no limit"**, your **weekly** usage stays accurate, and it snaps back on its own when OpenAI restores the window. With no 5-hour budget to measure against, each active Codex session's runway now shows its real **token throughput** (e.g. `412K tk/h`) instead of a burn rate scaled to the wrong window, and a new **format guardrail** shows "can't verify" rather than a wrong number if a provider changes its usage data unexpectedly.

New in 4.4:
- **Codex 5-hour drop handled** — auto-detects when OpenAI pauses the 5h window; shows "no limit" for 5h, keeps weekly accurate, and self-recovers when it returns.
- **Honest Session Runway for Codex** — active sessions show real token throughput (`412K tk/h`) while the 5h window is gone; reverts to the familiar 5h "m/h" once it's back.
- **Format guardrail** — shows "can't verify" instead of a wrong number when a provider's usage format changes unexpectedly.

## Core Features

- Browse and search [Codex CLI, Codex Desktop, and Codex VS Code sessions](docs/guides/codex-local-history.html) in one place.
- Browse [Claude CLI and Claude Desktop sessions](docs/guides/claude-code-jsonl-history.html) with consistent labels and project context.
- Browse [Cursor Agent transcripts](docs/guides/cursor-agent-local-history.html) from Cursor's local storage, enriched with Cursor chat metadata when available.
- [Hermes Agent sessions](docs/guides/hermes-agent-state-db-history.html) participate in browsing, search, filtering, analytics, and resume workflows, including current `~/.hermes/state.db` storage.
- [OpenClaw sessions](docs/guides/openclaw-local-agent-history.html) participate in browsing, search, filtering, deleted-session visibility, and resume workflows while ignoring trajectory traces.
- Pi CLI sessions now participate in browsing, search, filtering, and resume workflows.
- Unified browsing across supported agents, with strict filtering, saved sessions, and a single session list.
- Unified Search and Image Browser across sessions, plus in-session Find for fast transcript navigation.
- Readable tool calls/outputs and navigation between prompts, tools, and errors.
- Right-click Copy Resume Command or Resume for supported CLI sessions, with Terminal.app, iTerm2, and Warp launch targets.
- Agent Cockpit is the live command center for active Codex CLI, Claude CLI, and OpenCode CLI iTerm2 sessions, with a compact Quota Meter for always-on Codex and Claude usage visibility, freshness diagnostics, and projected run-out alerts.
- Local-only indexing designed for large histories.

## Agent Cockpit (Beta)

Agent Cockpit is the live command center for active iTerm2 [Codex CLI](docs/guides/codex-local-history.html), [Claude CLI](docs/guides/claude-code-jsonl-history.html), and [OpenCode CLI](docs/guides/opencode-sqlite-history.html) sessions, with shared active/waiting summaries and live Claude usage tracking.

<div align="center">
  <p style="margin:0 0 0px 0;"><em>Quota Meter with Session Runway per-session burn</em></p>
  <img src="docs/assets/quota-meter-light.png" alt="Quota Meter showing Codex and Claude 5h/weekly limits with Session Runway per-session burn-rate bars" width="100%" style="max-width:770px;border-radius:8px;margin:5px 0 22px;"/>

  <p style="margin:0 0 0px 0;"><em>Agent Cockpit</em></p>
  <img src="docs/assets/screenshot-cockpit-light.png" alt="Compact cockpit menu showing grouped active sessions in Light Mode" width="100%" style="max-width:820px;border-radius:8px;margin:5px 0;"/>
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
1. [Download AgentSessions-4.6.dmg](https://github.com/jazzyalex/agent-sessions/releases/download/v4.6/AgentSessions-4.6.dmg)
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
  - [Codex local history: search Codex CLI, Desktop, and VS Code sessions](docs/guides/codex-local-history.html)
  - [OpenCode SQLite history: browsing old runs](docs/guides/opencode-sqlite-history.html)
  - [Claude Code JSONL history: what you can recover locally](docs/guides/claude-code-jsonl-history.html)
  - [Cursor Agent local history: search Cursor Agent transcripts](docs/guides/cursor-agent-local-history.html)
  - [Hermes Agent state database history](docs/guides/hermes-agent-state-db-history.html)
  - [OpenClaw local agent history](docs/guides/openclaw-local-agent-history.html)
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
