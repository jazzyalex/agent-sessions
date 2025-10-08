# Agent Sessions (macOS)

[![Build](https://github.com/jazzyalex/agent-sessions/actions/workflows/ci.yml/badge.svg)](https://github.com/jazzyalex/agent-sessions/actions/workflows/ci.yml)

> **Unified session browser for Codex CLI and Claude Code.**  
> Search, browse, and resume any past AI-coding session in a single local-first macOS app.

<div align="center">
  <img src="docs/assets/app-icon-512.png" alt="App Icon" width="128" height="128"/>
</div>

<p align="center">
  <a href="https://github.com/jazzyalex/agent-sessions/releases/download/v2.2/AgentSessions-2.2.dmg"><b>Download Agent Sessions 2.2 (DMG)</b></a>
  •
  <a href="https://github.com/jazzyalex/agent-sessions/releases">All Releases</a>
  •
  <a href="#install">Install</a>
  •
  <a href="#resume-workflows">Resume Workflows</a>
</p>

---

## ✨ Overview

Agent Sessions 2 brings **Codex CLI** and **Claude Code** together in one interface.  
Look up any past session — even the ancient ones `/resume` can’t show — or browse visually to find that perfect prompt or code snippet, then instantly copy or resume it.

**Local-first, open source, and built for terminal vibe warriors.**

<div align="center">
  <img src="docs/assets/screenshot-V.png" alt="Session browser with search and filters" width="100%" style="max-width:960px;border:1px solid #d0d7de;border-radius:8px;"/>
  <p><em>Session browser with grouped timeline and full-text search</em></p>
  <img src="docs/assets/screenshot-H.png" alt="Transcript view with role-based styling" width="100%" style="max-width:960px;border:1px solid #d0d7de;border-radius:8px;"/>
  <p><em>Transcript view with timestamps and role-based styling</em></p>
  <img src="docs/assets/screenshot-menubar.png" alt="Menu bar usage tracking" width="50%" style="max-width:480px;border:1px solid #d0d7de;border-radius:8px;"/>
  <p><em>Menu-bar indicator showing 5-hour and weekly usage percentages</em></p>
</div>

---

## 🔧 Core Features

### Unified Interface v2
Browse **Codex CLI** and **Claude Code** sessions side-by-side. Toggle between Both / Codex / Claude sources with strict filtering and unified search.

### Unified Search v2
One search for everything. Find any snippet or prompt instantly — no matter which agent or project it came from.  
Smart sorting, instant cancel, full-text search with project filters.

### Instant Resume & Re-use
Reopen any Codex or Claude session in Terminal/iTerm with one click — or just copy what you need.  
When `/resume` falls short, browse visually, copy the fragment, and drop it into a new terminal or ChatGPT.

### Dual Usage Tracking
Independent 5-hour and weekly limits for Codex and Claude.  
A color-coded **menu-bar indicator** (or in-app strip) shows live percentages and reset times so you never get surprised mid-session.

### Local, Private & Safe
All processing runs on your Mac.  
Reads `~/.codex/sessions` and `~/.claude/sessions` locally.  
No cloud uploads or telemetry — **read-only by design.**

---

## 💻 Install

### Option A — Download DMG
1. [Download AgentSessions-2.2.dmg](https://github.com/jazzyalex/agent-sessions/releases/download/v2.2/AgentSessions-2.2.dmg)  
2. Drag **Agent Sessions.app** into Applications.

### Option B — Homebrew Tap
```bash
# install with Homebrew
brew tap jazzyalex/agent-sessions
brew install --cask agent-sessions