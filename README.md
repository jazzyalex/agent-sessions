# Agent Sessions (macOS)

[![Build](https://github.com/jazzyalex/agent-sessions/actions/workflows/ci.yml/badge.svg)](https://github.com/jazzyalex/agent-sessions/actions/workflows/ci.yml)

<table>
<tr>
<td width="100" align="center">
  <img src="docs/assets/app-icon-512.png" alt="App Icon" width="80" height="80"/>
</td>
<td>

 **Unified session browser for Codex CLI, Claude Code, and Gemini CLI (read‑only).**  
 Search, browse, and resume any past AI-coding session in a single local-first macOS app.

</td>
</tr>
</table>

<p align="center">
  <a href="https://github.com/jazzyalex/agent-sessions/releases/download/v2.5.2/AgentSessions-2.5.2.dmg"><b>Download Agent Sessions 2.5.2 (DMG)</b></a>
  •
  <a href="https://github.com/jazzyalex/agent-sessions/releases">All Releases</a>
  •
  <a href="#install">Install</a>
  •
  <a href="#resume-workflows">Resume Workflows</a>

</p>
<p></p>



##  Overview

Agent Sessions 2 brings **Codex CLI**, **Claude Code**, and **Gemini CLI** together in one interface.  
Look up any past session — even the ancient ones `/resume` can’t show — or browse visually to find that perfect prompt or code snippet, then instantly copy or resume it.

<div align="center">

```
Local-first, open source, and built for terminal vibe warriors.
```

</div>

<div align="center">
  <p style="margin:0 0 0px 0;"><em>Transcript view with search (Dark Mode)</em></p>
  <img src="docs/assets/screenshot-H.png" alt="Transcript view with search (Dark Mode)" width="100%" style="max-width:960px;border-radius:8px;margin:5px 0;"/>

  <p style="margin:0 0 0px 0;"><em>Resume any Codex CLI and Claude Code session</em></p>
  <img src="docs/assets/screenshot-V.png" alt="Resume any Codex CLI and Claude Code session" width="100%" style="max-width:960px;border-radius:8px;margin:5px;"/>

  <p style="margin:0 0 15px 0;"><em>Menu bar usage tracking with 5-hour and weekly percentages</em></p>
  <img src="docs/assets/screenshot-menubar.png" alt="Menu bar usage tracking with 5-hour and weekly percentages" width="50%" style="max-width:480px;border-radius:8px;margin:5px auto;display:block;"/>

  <p style="margin:0 0 0px 0;"><em>Analytics dashboard with session trends and agent breakdown (Dark Mode)</em></p>
  <img src="docs/assets/analytics-dark.png" alt="Analytics dashboard with session trends and agent breakdown (Dark Mode)" width="100%" style="max-width:960px;border-radius:8px;margin:5px 0;"/>

  <p style="margin:0 0 15px 0;"><em>Git Context Inspector showing repository state and historical diffs (Light Mode)</em></p>
  <img src="docs/assets/git-context-light.png" alt="Git Context Inspector showing repository state and historical diffs (Light Mode)" width="100%" style="max-width:960px;border-radius:8px;margin:5px auto;display:block;"/>
</div>

---

## What's New in 2.5.2

**Analytics filtering fix** reducing noise by 79% (now matches Sessions List defaults) • **Diagnostic script** for session analysis.

---

## What's New in 2.5

### Massive Performance Improvements
SQLite-backed indexing brings **dramatically faster** session loading and filtering. Background indexing runs at utility priority, updating only changed session files. No more waiting—browse thousands of sessions instantly.

### Analytics Dashboard (v1)
Visualize your AI coding patterns with comprehensive analytics. Track session trends, compare agent usage, discover your most productive hours with time-of-day heatmaps, and view key metrics—all in a dedicated analytics window.

### Git Context Inspector
Deep-dive into the git context of any Codex session. See repository state, branch info, and historical diffs—understand exactly what code changes were visible to Codex during each session. Right-click any Codex session → **Show Git Context**.

### Updated Usage Tracking
Usage limit tracking and reset times now properly support Codex 0.50+ session format changes. No more "Stale data" warnings—accurate usage tracking with flexible timestamp parsing for both old and new session formats.

---

## Core Features

### Unified Interface v2
Browse **Codex CLI**, **Claude Code**, and **Gemini CLI** sessions side-by-side. Toggle between sources (Both / Codex / Claude / Gemini) with strict filtering and unified search.

### Unified Search v2
One search for everything. Find any snippet or prompt instantly — no matter which agent or project it came from (Codex, Claude, or Gemini CLI).  
Smart sorting, instant cancel, full-text search with project filters.

### Instant Resume & Re-use
Reopen any Codex or Claude session in Terminal/iTerm with one click — or just copy what you need.  
When `/resume` falls short, browse visually, copy the fragment, and drop it into a new terminal or ChatGPT.

### Dual Usage Tracking
Independent 5-hour and weekly limits for Codex and Claude.
A color-coded **menu-bar indicator** (or in-app strip) shows live percentages and reset times so you never get surprised mid-session.

### Advanced Analytics
Visualize your AI coding patterns with comprehensive analytics:
- **Session trends**: Track daily/weekly session counts and message volume over time
- **Agent breakdown**: Compare Codex CLI vs Claude Code usage patterns
- **Time-of-day heatmap**: Discover when you're most productive with AI tools
- **Key metrics**: Average session length, total messages, and usage distribution

Access via **Window → Analytics** or the toolbar analytics icon.

### Git Context Inspector (Codex CLI)
Deep-dive into the git context of any Codex session:
- **Repository state**: See branch, commit, and working tree status at session time
- **Historical diffs**: Review exact code changes that were visible to Codex
- **Context timeline**: Understand what git context influenced each session

Right-click any Codex session → **Show Git Context** to open the inspector.

### Local, Private & Safe
All processing runs on your Mac.  
Reads `~/.codex/sessions`, `~/.claude/sessions`, and Gemini CLI checkpoints under `~/.gemini/tmp` (read‑only).  
No cloud uploads or telemetry — **read‑only by design.**

---

## Install

### Option A — Download DMG
1. [Download AgentSessions-2.5.2.dmg](https://github.com/jazzyalex/agent-sessions/releases/download/v2.5.2/AgentSessions-2.5.2.dmg)
2. Drag **Agent Sessions.app** into Applications.

### Option B — Homebrew Tap
```bash
# install with Homebrew
brew tap jazzyalex/agent-sessions
brew install --cask agent-sessions
```

### Automatic Updates

Agent Sessions includes **Sparkle 2** for automatic updates:
- **Background checks**: The app checks for updates every 24 hours (customizable in Settings)
- **Non-intrusive**: Update notifications only appear when the app is in focus (menu bar friendly)
- **Secure**: All updates are cryptographically signed (EdDSA) and Apple-notarized
- **Manual checks**: Use **Help → Check for Updates…** anytime

To manually check for updates:
```bash
# Force immediate update check (for testing)
defaults delete com.triada.AgentSessions SULastCheckTime
open "/Applications/Agent Sessions.app"
```

**Note**: The first Sparkle-enabled release (2.4.0+) requires a manual download. All subsequent updates work automatically via in-app prompts.
