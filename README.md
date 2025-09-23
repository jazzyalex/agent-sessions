# Agent Sessions (macOS)

[![Build](https://github.com/jazzyalex/agent-sessions/actions/workflows/ci.yml/badge.svg)](https://github.com/jazzyalex/agent-sessions/actions/workflows/ci.yml)

> Fast, native macOS viewer/indexer for **Codex CLI** session logs.  
> Dual-pane browser with full-text search, filters, and a clean SwiftUI UI.

<div align="center">
  <img src="docs/assets/app-icon-512.png" alt="App Icon" width="128" height="128"/>
</div>


## ✨ What it is
Agent Sessions reads **JSON Lines** logs produced by [Codex CLI](https://github.com/your-codex-cli-link)  
and builds a searchable timeline of your AI coding/chat sessions.

- 🗂 **Sidebar**: sessions grouped by *Today*, *Yesterday*, date, or *Older*  
- 📝 **Transcript view**: full session content with role-based styling and optional timestamps  
- 🔍 **Search & filters**: full-text search, date ranges, model filter, message-type toggles  
- 🎨 **SwiftUI design**: fast, clean, and privacy-friendly (local only)


## 🧰 Requirements
- macOS 14 (Sonoma) or newer
- Xcode 15+ / Swift 5.9+
- Codex CLI logs in `$CODEX_HOME/sessions/YYYY/MM/DD/rollout-*.jsonl`  
  *(or `~/.codex/sessions/...`)*


## 📦 Install

### Option A — Download
1. Grab the latest build from [Releases](https://github.com/jazzyalex/agent-sessions/releases).  
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

---

## Disclaimer

**Agent Sessions** is an independent open-source project.  
It is **not affiliated with, endorsed by, or sponsored by OpenAI, Anthropic, or any of their products or services** (including ChatGPT, Claude, or Codex CLI).  

All trademarks and brand names belong to their respective owners. References to “OpenAI,” “Anthropic,” or “Codex CLI” are made solely for descriptive purposes.
