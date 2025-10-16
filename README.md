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
  <a href="https://github.com/jazzyalex/agent-sessions/releases/download/v2.4/AgentSessions-2.4.dmg"><b>Download Agent Sessions 2.4 (DMG)</b></a>
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
</div>

---

## What's New in 2.3

- Gemini CLI:
  - Indexes `~/.gemini/tmp/**/session-*.json` (and common variants)
  - Lists and opens transcripts in the existing viewer (no writes, no resume)
  - Unified search and source toggle alongside Codex/Claude
- Favorites (★):
  - Inline star on each row + context menu Add/Remove
  - Toolbar “Favorites” toggle filters list (AND with search)
  - Persisted in UserDefaults; zero schema changes
- UI polish and fixes:
  - Transcript vs Terminal parity across providers
  - Persistent window/split positions; toolbar spacing adjustments
  - “Refresh preview” affordance for stale Gemini files

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

### Local, Private & Safe
All processing runs on your Mac.  
Reads `~/.codex/sessions`, `~/.claude/sessions`, and Gemini CLI checkpoints under `~/.gemini/tmp` (read‑only).  
No cloud uploads or telemetry — **read‑only by design.**

---

## Install

### Option A — Download DMG
1. [Download AgentSessions-2.3.2.dmg](https://github.com/jazzyalex/agent-sessions/releases/download/v2.4/AgentSessions-2.4.dmg)  
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
