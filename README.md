# Agent Sessions (macOS)

[![Build](https://github.com/jazzyalex/agent-sessions/actions/workflows/ci.yml/badge.svg)](https://github.com/jazzyalex/agent-sessions/actions/workflows/ci.yml)

<table>
<tr>
<td width="100" align="center">
  <img src="docs/assets/app-icon-512.png" alt="App Icon" width="80" height="80"/>
</td>
<td>

 **Unified session browser for Codex CLI, Claude Code, Gemini CLI, GitHub Copilot CLI, Droid (Factory CLI), and OpenCode.**
 Search, browse, and resume any past AI-coding session in a single local-first macOS app.

</td>
</tr>
</table>

- License: MIT
- Security & Privacy: Local-only. No telemetry. Details: `docs/security.md`

<p align="center">
  <a href="https://github.com/jazzyalex/agent-sessions/releases/download/v2.9.2/AgentSessions-2.9.2.dmg"><b>Download Agent Sessions 2.9.2 (DMG)</b></a>
  •
  <a href="https://github.com/jazzyalex/agent-sessions/releases">All Releases</a>
  •
  <a href="#install">Install</a>
  •
  <a href="#resume-workflows">Resume Workflows</a>

</p>
<p></p>



##  Overview

Agent Sessions 2 brings **Codex CLI**, **Claude Code**, **Gemini CLI**, **GitHub Copilot CLI**, and **Droid (Factory CLI)** together in one interface.
Look up any past session — even the ancient ones `/resume` can't show — or browse visually to find that perfect prompt or code snippet, then instantly copy or resume it.

## Trust
- `docs/PRIVACY.md`
- `docs/security.md`
- `LICENSE`

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

## What's New in 2.9 🎄

### Onboarding Tours
Interactive onboarding experience for new users and a skippable update tour for major releases. Learn key features through guided walkthroughs. Reopen anytime from **Help → Show Onboarding**.

### GitHub Copilot CLI Support
Full session browser integration for GitHub Copilot CLI sessions from `~/.copilot/session-state`. Includes dedicated Preferences pane and toolbar filter (⌘5).

### Saved Sessions Window
New dedicated **Saved Sessions** window (View menu) for managing archived sessions. Delete, reveal, and diagnose saved sessions with archive status tooltips.

### Keyboard Navigation
New **Option-Command-Arrow** shortcuts jump between user prompts, tool calls, and errors in transcripts for faster navigation.

### Improvements
- Reorganized Preferences with better CLI agent controls
- Disabling an agent now hides it everywhere (toolbar, Analytics, menu bar) and stops background work
- Improved Tab focus behavior for Find controls

---

## What's New in 2.8

### OpenCode Support
Full session browser integration with OpenCode sessions from `~/.local/share/opencode/storage/session`. Includes transcript viewing, analytics, and favorites. Sessions appear in the unified list with source filtering.

### Improved Usage Tracking
Separate refresh intervals per agent (Codex: 1/5/15 min, Claude: 3/15/30 min). New Usage Probes pane consolidates probe settings with clear safety messaging. Usage probes no longer stall after 24 attempts.

---

## What's New in 2.7

### Color View
Terminal-inspired view with CLI-style colorized output and role-based filtering (User, Agent, Tools, Errors). Quick toggle with Cmd+Shift+T.

### Claude Usage Format Fix
Fixed compatibility with Claude Code's usage format change ("% left" vs "% used") with automatic percentage inversion.

---

## What's New in 2.6

### Usage Probe Support for Codex
Automatic background probes refresh Codex usage limits when data goes stale. New Usage Probes preferences pane provides full control: enable/disable auto-probes, configure refresh intervals, and manage probe session cleanup. Mirrors the Claude usage tracking workflow with 24-hour probe budgets and auto-delete options.

### Analytics Flip Cards
Interactive flip cards reveal insights behind every metric. Click any analytics card to see sparklines, agent breakdowns, and detailed context. Switch between Sessions and Messages views with unified toggle across all charts.

### Quality Improvements
- Improved launch loading UX with better progress indicators and analytics gating
- Hardened Claude and Codex probe reliability with robust capture logic
- Refined analytics card layouts with balanced spacing and visual hierarchy
- Better stale data indicators with "Last updated" timestamps

---

## What's New in 2.5

### Massive Performance Improvements
SQLite-backed indexing brings **dramatically faster** session loading and filtering. Background indexing runs at utility priority, updating only changed session files. No more waiting—browse thousands of sessions instantly.

### Analytics Dashboard (v1)
Visualize your AI coding patterns with comprehensive analytics. Track session trends, compare agent usage, discover your most productive hours with time-of-day heatmaps, and view key metrics—all in a dedicated analytics window.

### Git Context Inspector
Deep-dive into the git context of any Codex session. See repository state, branch info, and historical diffs—understand exactly what code changes were visible to Codex during each session. Right-click any Codex session → **Show Git Context**.

### Updated Usage Tracking
Usage limit tracking and reset times now properly support Codex 0.50+ session format changes. The strip and menu show a "Stale data" warning when rate‑limit information is older than the freshness threshold, even if token‑only events or UI refreshes occurred meanwhile. Flexible timestamp parsing handles both old and new session formats.

---

## Core Features

### Unified Interface v2
Browse **Codex CLI**, **Claude Code**, **Gemini CLI**, **GitHub Copilot CLI**, and **OpenCode** sessions side-by-side. Toggle between sources with strict filtering and unified search. Star favorites for quick access.

### Unified Search v2
One search for everything. Find any snippet or prompt instantly — no matter which agent or project it came from.
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
Reads `~/.codex/sessions`, `~/.claude/sessions`, `~/.gemini/tmp`, `~/.copilot/session-state`, and `~/.local/share/opencode/storage/session` (all read‑only).
No cloud uploads or telemetry — **read‑only by design.**

---

## Install

### Option A — Download DMG
1. [Download AgentSessions-2.9.2.dmg](https://github.com/jazzyalex/agent-sessions/releases/download/v2.9.2/AgentSessions-2.9.2.dmg)
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
