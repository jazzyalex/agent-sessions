# Agent Sessions (macOS)

[![Build](https://github.com/jazzyalex/agent-sessions/actions/workflows/ci.yml/badge.svg)](https://github.com/jazzyalex/agent-sessions/actions/workflows/ci.yml)

> Native macOS app for managing AI-assisted coding workflows.
> Search, resume, and track your **Codex CLI** sessions with a developer-friendly UI.

<div align="center">
  <img src="docs/assets/app-icon-512.png" alt="App Icon" width="128" height="128"/>
</div>

<p align="center">
  <a href="https://github.com/jazzyalex/agent-sessions/releases/download/v1.2.2/AgentSessions-1.2.2.dmg"><b>Download Agent Sessions 1.2.2 (DMG)</b></a>
  •
  <a href="https://github.com/jazzyalex/agent-sessions/releases">All Releases</a>
  •
  <a href="#install">Install</a>
  •
  <a href="#resume-with-codex">Resume with Codex</a>
</p>

<div align="center">
  <img src="docs/assets/screenshot-V.png" alt="Session browser with search, filters, and grouped timeline" style="max-width:960px; width:100%; border:1px solid #d0d7de; border-radius:8px;" />
  <p><em>Session browser with search, filters, and grouped timeline (vertical layout)</em></p>
  <br/>
  <img src="docs/assets/screenshot-H.png" alt="Transcript view with role-based styling and timestamps" style="max-width:960px; width:100%; border:1px solid #d0d7de; border-radius:8px; margin-top:10px;" />
  <p><em>Transcript view with role-based styling and timestamps (horizontal layout)</em></p>
  <br/>
  <img src="docs/assets/screenshot-menubar.png" alt="Menu bar usage tracking with 5-hour and weekly percentages" style="max-width:960px; width:100%; border:1px solid #d0d7de; border-radius:8px; margin-top:10px;" />
  <p><em>Menu bar usage tracking with configurable thresholds and reset times</em></p>
  <br/>
  <img src="docs/assets/screenshot-setings.png" alt="Preferences: Codex CLI configuration and usage strip settings" style="max-width:960px; width:100%; border:1px solid #d0d7de; border-radius:8px; margin-top:10px;" />
  <p><em>Preferences: Codex CLI configuration, binary detection, and usage display options</em></p>
  <br/>
</div>


## What it is
Agent Sessions reads **JSON Lines** logs produced by [Codex CLI](https://github.com/your-codex-cli-link)
and builds a searchable timeline of your AI coding/chat sessions.

**Stop grepping through JSONL files.** Agent Sessions gives you:

- **Find sessions instantly**: Full-text search across all conversations (vs. manual grepping)
- **Resume workflows**: One-click launch in Terminal with automatic working directory resolution
- **Track usage limits**: Menu bar display shows 5-hour and weekly rate limits with reset times
- **Local-first privacy**: All processing on your Mac, no cloud uploads or telemetry

## Key Features

### Session Management
- **Dual-pane browser**: Sidebar with grouped sessions (Today, Yesterday, date ranges) + transcript view
- **Smart search**: Full-text search with repo/path operators (`repo:myproject path:/src`)
- **Filter by model**: gpt-5-nano, claude-sonnet-4-5, and other Codex-supported models
- **Metadata extraction**: Automatic title, timestamps, repository, and branch detection

### Workflow Integration
- **One-click resume**: Launch Codex in Terminal with automatic working directory resolution
- **Session ID extraction**: Works with both resume-by-ID and experimental file-based resume
- **Context awareness**: Double-click project name to filter by repository

### Usage Monitoring
- **Menu bar widget**: Real-time display of 5-hour and weekly usage percentages
- **Color-coded thresholds**: Visual indicators for approaching rate limits
- **Reset time display**: Know exactly when your limits refresh (e.g., "resets 14:30 on 30 Sep")
- **Smart refresh**: Auto-updates every 60s on AC power when visible, 300s otherwise

### Performance & Privacy
- **Fast indexing**: Handles 1000+ sessions with optimized parsing (metadata-first for >20MB files)
- **Local processing**: All data stays on your Mac, no network calls except usage monitoring
- **SwiftUI native**: Clean, responsive interface that respects macOS conventions

## Requirements
- macOS 14 (Sonoma) or newer
- Xcode 15+ / Swift 5.9+
- Codex CLI logs in `$CODEX_HOME/sessions/YYYY/MM/DD/rollout-*.jsonl`  
  *(or `~/.codex/sessions/...`)*


## Install

### Option A — Download
1. Get the latest DMG: [AgentSessions-1.2.2.dmg](https://github.com/jazzyalex/agent-sessions/releases/download/v1.2.2/AgentSessions-1.2.2.dmg)  
2. Drag **Agent Sessions.app** to your Applications folder.

### Option B — Homebrew Tap
```bash
brew tap jazzyalex/agent-sessions
brew install --cask agent-sessions
```

### Option C — Build from source
```bash
git clone https://github.com/jazzyalex/agent-sessions.git
cd agent-sessions
open AgentSessions.xcodeproj
```

## Resume with Codex

Agent Sessions can launch Codex CLI to resume a saved session by ID or via explicit path.

- Verify Codex CLI
  - Ensure `codex` runs in Terminal: `codex --version`.
  - Install via Homebrew or npm (either works):
    - Homebrew: `brew install codex`
    - npm: `npm i -g @openai/codex`

- Point Agent Sessions to Codex
  - Open Preferences → Codex CLI.
  - Click “Check Version”. The app resolves `codex` using your login shell (no PATH edits needed).  
    If not found, set “Override path (optional)” to your codex binary.

- Resume from a saved log
  - Open Preferences → Codex CLI Resume.
  - Pick a session in the list or search.
  - Choose Launch Mode (Terminal or Embedded). Terminal is recommended.
  - If your Codex build doesn’t support resume by ID, enable “Use experimental resume flag”.
  - Use “Resume Log” for a quick diagnostic of your current session file.

## Disclaimer

**Agent Sessions** is an independent open-source project.  
It is **not affiliated with, endorsed by, or sponsored by OpenAI, Anthropic, or any of their products or services** (including ChatGPT, Claude, or Codex CLI).  

All trademarks and brand names belong to their respective owners. References to “OpenAI,” “Anthropic,” or “Codex CLI” are made solely for descriptive purposes.
