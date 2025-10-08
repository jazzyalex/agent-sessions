# Agent Sessions (macOS)

[![Build](https://github.com/jazzyalex/agent-sessions/actions/workflows/ci.yml/badge.svg)](https://github.com/jazzyalex/agent-sessions/actions/workflows/ci.yml)

> Native macOS app for managing AI-assisted coding workflows.
> Search, resume, and track your **Codex CLI** and **Claude Code** sessions with a unified, developer-friendly interface.

<div align="center">
  <img src="docs/assets/app-icon-512.png" alt="App Icon" width="128" height="128"/>
</div>

<p align="center">
  <a href="https://github.com/jazzyalex/agent-sessions/releases/download/v2.1/AgentSessions-2.1.dmg"><b>Download Agent Sessions 2.1 (DMG)</b></a>
  •
  <a href="https://github.com/jazzyalex/agent-sessions/releases">All Releases</a>
  •
  <a href="#install">Install</a>
  •
  <a href="#resume-workflows">Resume Workflows</a>
</p>

<div align="center">
  <img src="docs/assets/screenshot-V.png" alt="Session browser with search, filters, and grouped timeline" style="max-width:960px; width:100%; border:1px solid #d0d7de; border-radius:8px;" />
  <p><em>Session browser with search, filters, and grouped timeline (vertical layout)</em></p>
  <br/>
  <img src="docs/assets/screenshot-H.png" alt="Transcript view with role-based styling and timestamps" style="max-width:960px; width:100%; border:1px solid #d0d7de; border-radius:8px; margin-top:10px;" />
  <p><em>Transcript view with role-based styling and timestamps (horizontal layout)</em></p>
  <br/>
  <div align="center">
    <img src="docs/assets/screenshot-menubar.png" alt="Menu bar usage tracking with 5-hour and weekly percentages" style="max-width:480px; width:50%; border:1px solid #d0d7de; border-radius:8px; margin-top:10px;" />
    <p><em>Menu bar usage tracking with configurable thresholds and reset times</em></p>
  </div>
  <br/>
  <!-- <img src="docs/assets/screenshot-setings.png" alt="Preferences: Codex CLI configuration and usage strip settings" style="max-width:960px; width:100%; border:1px solid #d0d7de; border-radius:8px; margin-top:10px;" />
  <p><em>Preferences: Codex CLI configuration, binary detection, and usage display options</em></p> -->
  <br/>
</div>


## What it is

Agent Sessions is a **unified session browser** for **Codex CLI** and **Claude Code** (official Claude CLI).

It reads JSONL logs from both tools and builds a searchable, resumable timeline of your AI coding conversations.

**Stop grepping through scattered log files.** Agent Sessions gives you:

- **Unified view**: Browse Codex and Claude sessions side-by-side with source filtering (Both/Codex/Claude)
- **Advanced search**: Two-phase incremental search with progress tracking and instant cancellation
- **Resume anywhere**: One-click launch in Terminal/iTerm with automatic working directory resolution
- **Dual usage tracking**: Separate 5-hour and weekly limits for Codex and Claude with menu bar display
- **Local-first privacy**: All processing on your Mac, no cloud uploads or telemetry

## Key Features

### Unified Session Management
- **Single window, dual sources**: Toggle between Codex, Claude, or both with strict filtering
- **Smart search v2**: Cancellable, two-phase pipeline (small files first, large deferred) with real-time progress
- **Filter by model**: gpt-5-nano, claude-sonnet-4-5, and other supported models
- **Metadata extraction**: Automatic title, timestamps, repository, and branch detection
- **Intelligent defaults**: Shows file size for unloaded sessions; skips preambles (agents.md, Claude caveats)

### Workflow Integration
- **Claude Code support**: Full parsing, transcript rendering, and resume via Terminal or iTerm
- **Codex resume**: Launch with automatic working directory resolution and session ID extraction
- **Context menu actions**: "Open Session in Folder" reveals hidden system files in Finder
- **Keyboard-first**: Option+Cmd+F for instant search focus, Tab navigation without focus stealing

### Usage Monitoring (Dual-Source)
- **Separate tracking**: Independent 5-hour and weekly limits for Codex and Claude
- **Menu bar widget**: Real-time display with color-coded thresholds
- **Reset time display**: Know exactly when limits refresh (e.g., "resets 14:30 on 30 Sep")
- **Smart refresh**: Auto-updates every 60s on AC power when visible, 300s otherwise

### Performance & Privacy
- **Lazy hydration**: Defer-until-needed loading for sessions ≥10 MB
- **Off-main parsing**: No UI freezes during large file processing
- **Fast indexing**: Handles 1000+ sessions with metadata-first scanning (>20MB files)
- **Local processing**: All data stays on your Mac, no network calls except usage monitoring
- **SwiftUI native**: Clean, responsive interface that respects macOS conventions

## Requirements
- macOS 14 (Sonoma) or newer
- Xcode 15+ / Swift 5.9+
- Codex CLI logs in `$CODEX_HOME/sessions/YYYY/MM/DD/rollout-*.jsonl`  
  *(or `~/.codex/sessions/...`)*


## Install

### Option A — Download
1. Get the latest DMG: [AgentSessions-2.0.dmg](https://github.com/jazzyalex/agent-sessions/releases/download/v2.1/AgentSessions-2.1.dmg)
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

## Resume Workflows

Agent Sessions can launch **both Codex CLI and Claude Code** to resume saved sessions.

### Codex CLI
- Verify Codex CLI
  - Ensure `codex` runs in Terminal: `codex --version`
  - Install via Homebrew or npm (either works):
    - Homebrew: `brew install codex`
    - npm: `npm i -g @openai/codex`

- Point Agent Sessions to Codex
  - Open Preferences → Codex CLI
  - Click "Check Version". The app resolves `codex` using your login shell (no PATH edits needed)
  - If not found, set "Override path (optional)" to your codex binary

- Resume from a saved log
  - Open Preferences → Codex CLI Resume
  - Pick a session in the list or search
  - Choose Launch Mode (Terminal or Embedded). Terminal is recommended
  - If your Codex build doesn't support resume by ID, enable "Use experimental resume flag"
  - Use "Resume Log" for a quick diagnostic of your current session file

### Claude Code
- Verify Claude Code CLI
  - Ensure `claude` runs in Terminal: `claude --version`
  - Install via official documentation at [docs.claude.com](https://docs.claude.com)

- Configure in Agent Sessions
  - Open Preferences → Claude Resume
  - Choose Terminal or iTerm as launch target
  - Sessions resume with automatic working directory and trust confirmations

## Disclaimer

**Agent Sessions** is an independent open-source project.  
It is **not affiliated with, endorsed by, or sponsored by OpenAI, Anthropic, or any of their products or services** (including ChatGPT, Claude, or Codex CLI).  

All trademarks and brand names belong to their respective owners. References to “OpenAI,” “Anthropic,” or “Codex CLI” are made solely for descriptive purposes.
