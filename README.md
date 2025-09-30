# Agent Sessions (macOS)

[![Build](https://github.com/jazzyalex/agent-sessions/actions/workflows/ci.yml/badge.svg)](https://github.com/jazzyalex/agent-sessions/actions/workflows/ci.yml)

> Fast, native macOS viewer/indexer for **Codex CLI** session logs.  
> Dual-pane browser with full-text search, filters, and a clean SwiftUI UI.

<div align="center">
  <img src="docs/assets/app-icon-512.png" alt="App Icon" width="128" height="128"/>
</div>

<p align="center">
  <a href="https://github.com/jazzyalex/agent-sessions/releases/download/v1.2/AgentSessions-1.2.dmg"><b>Download Agent Sessions 1.2 (DMG)</b></a>
  •
  <a href="https://github.com/jazzyalex/agent-sessions/releases">All Releases</a>
  •
  <a href="#install">Install</a>
  •
  <a href="#resume-with-codex">Resume with Codex</a>
</p>

<div align="center">
  <img src="docs/assets/screenshot-V.png" alt="Agent Sessions vertical layout" style="max-width:960px; width:100%; border:1px solid #d0d7de; border-radius:8px;" />
  <br/>
  <img src="docs/assets/screenshot-H.png" alt="Agent Sessions horizontal layout" style="max-width:960px; width:100%; border:1px solid #d0d7de; border-radius:8px; margin-top:10px;" />
  <br/>
  <img src="docs/assets/screenshot-menubar.png" alt="Agent Sessions menu bar usage display" style="max-width:960px; width:100%; border:1px solid #d0d7de; border-radius:8px; margin-top:10px;" />
  <br/>
  <img src="docs/assets/screenshot-setings.png" alt="Agent Sessions preferences" style="max-width:960px; width:100%; border:1px solid #d0d7de; border-radius:8px; margin-top:10px;" />
  <br/>
</div>


## What it is
Agent Sessions reads **JSON Lines** logs produced by [Codex CLI](https://github.com/your-codex-cli-link)  
and builds a searchable timeline of your AI coding/chat sessions.

- Sidebar: sessions grouped by Today, Yesterday, date, or Older  
- Transcript view: full session content with role-based styling and optional timestamps  
- Search & filters: full-text search, date ranges, model filter, message-type toggles  
- SwiftUI design: fast, clean, and privacy-friendly (local only)


## Requirements
- macOS 14 (Sonoma) or newer
- Xcode 15+ / Swift 5.9+
- Codex CLI logs in `$CODEX_HOME/sessions/YYYY/MM/DD/rollout-*.jsonl`  
  *(or `~/.codex/sessions/...`)*


## Install

### Option A — Download
1. Get the latest DMG: [AgentSessions-1.2.dmg](https://github.com/jazzyalex/agent-sessions/releases/download/v1.2/AgentSessions-1.2.dmg)  
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
