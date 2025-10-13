# Agent Sessions (macOS)

[![Build](https://github.com/jazzyalex/agent-sessions/actions/workflows/ci.yml/badge.svg)](https://github.com/jazzyalex/agent-sessions/actions/workflows/ci.yml)

<table>
<tr>
<td width="100" align="center">
  <img src="docs/assets/app-icon-512.png" alt="App Icon" width="80" height="80"/>
</td>
<td>

 **Unified session browser for Codex CLI and Claude Code.**  
 Search, browse, and resume any past AI-coding session in a single local-first macOS app.

</td>
</tr>
</table>

<p align="center">
  <a href="https://github.com/jazzyalex/agent-sessions/releases/download/v2.2.1/AgentSessions-2.2.1.dmg"><b>Download Agent Sessions 2.2.1 (DMG)</b></a>
  •
  <a href="https://github.com/jazzyalex/agent-sessions/releases">All Releases</a>
  •
  <a href="#install">Install</a>
  •
  <a href="#resume-workflows">Resume Workflows</a>

</p>
<p></p>
<div align="center">

<a href="https://www.producthunt.com/products/agent-sessions?embed=true&utm_source=badge-featured&utm_medium=badge&utm_source=badge-agent&#0045;sessions" target="_blank"><img src="https://api.producthunt.com/widgets/embed-image/v1/featured.svg?post_id=1024948&theme=light&t=1760385821577" alt="Agent&#0032;Sessions&#0032; - Unified&#0032;history&#0032;&#0038;&#0032;usage&#0032;for&#0032;Codex&#0032;CLI&#0032;and&#0032;Claude&#0032;Code | Product Hunt" style="width: 250px; height: 76px;" width="250" height="76" /></a>
</div>

##  Overview

Agent Sessions 2 brings **Codex CLI** and **Claude Code** together in one interface.  
Look up any past session — even the ancient ones `/resume` can’t show — or browse visually to find that perfect prompt or code snippet, then instantly copy or resume it.

**Local-first, open source, and built for terminal vibe warriors.**

<div align="center">
  <p style="margin:0 0 0px 0;"><em>Transcript view with search (Dark Mode)</em></p>
  <img src="docs/assets/screenshot-H.png" alt="Transcript view with search (Dark Mode)" width="100%" style="max-width:960px;border:1px solid #d0d7de;border-radius:8px;margin:5px 0;"/>
  <p style="margin:0 0 0px 0;"><em>Resume any Codex CLI and Claude Code session</em></p>
  <img src="docs/assets/screenshot-V.png" alt="Resume any Codex CLI and Claude Code session" width="100%" style="max-width:960px;border:1px solid #d0d7de;border-radius:8px;margin:5px 0;"/>
  <p style="margin:0 0 15px 0;"><em>Menu bar usage tracking with 5-hour and weekly percentages</em></p>
  <img src="docs/assets/screenshot-menubar.png" alt="Menu bar usage tracking with 5-hour and weekly percentages" width="50%" style="max-width:480px;border:1px solid #d0d7de;border-radius:8px;margin:5px auto;display:block;"/>
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
1. [Download AgentSessions-2.2.1.dmg](https://github.com/jazzyalex/agent-sessions/releases/download/v2.2.1/AgentSessions-2.2.1.dmg)  
2. Drag **Agent Sessions.app** into Applications.

### Option B — Homebrew Tap
```bash
# install with Homebrew
brew tap jazzyalex/agent-sessions
brew install --cask agent-sessions