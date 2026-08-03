# README hero — DRAFT

**This is a draft for Alex to merge by hand.** It does not touch `README.md`.
No emoji (per `agents.md`). Star/download badges are **dynamic** (shields.io reads GitHub live, so they never go stale). The weekly-active-users figure has no GitHub badge — it's shown as prose and should be updated by hand when it moves.

Numbers current as of 2026-07-06: 674 stars, 44 forks, 0 open issues, 9,240 downloads, ~700 weekly active users. The stars/downloads badges below will render the live values automatically once merged.

---

## Rendered draft (copy from here down)

```markdown
# Agent Sessions (macOS)

[![Build](https://github.com/jazzyalex/agent-sessions/actions/workflows/ci.yml/badge.svg)](https://github.com/jazzyalex/agent-sessions/actions/workflows/ci.yml)
[![Stars](https://img.shields.io/github/stars/jazzyalex/agent-sessions?style=flat&label=stars)](https://github.com/jazzyalex/agent-sessions/stargazers)
[![Downloads](https://img.shields.io/github/downloads/jazzyalex/agent-sessions/total?label=downloads)](https://github.com/jazzyalex/agent-sessions/releases)
[![Latest release](https://img.shields.io/github/v/release/jazzyalex/agent-sessions?label=release)](https://github.com/jazzyalex/agent-sessions/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Platform: macOS 14+](https://img.shields.io/badge/macOS-14%2B-black)](#install)

<table>
<tr>
<td width="100" align="center">
  <img src="docs/assets/app-icon-512.png" alt="App Icon" width="80" height="80"/>
</td>
<td>

**One local, searchable home for every coding agent's session history.**
Agent Sessions reads the sessions your AI coding tools already write to disk — Codex, Claude Code, Cursor, OpenCode, GitHub Copilot CLI, Hermes, OpenClaw, Antigravity, and Pi — and brings them into a single view you can search, read, and resume. Local-first: no account, no backend, no telemetry.

</td>
</tr>
</table>

> **Why it exists:** a single vendor's tool can only show you its own history — Codex won't index your Claude sessions, and no first-party tool will unify a competitor's data. Cross-agent history, search, and analytics is the one job only a neutral, local tool can do. It gets more useful with every agent you add.

**By the numbers** — nine months in, entirely word of mouth, zero marketing:
674 GitHub stars · ~700 weekly active users · 9,240 downloads · 9 supported agent sources · 0 open issues · MIT · macOS 14+

<p align="center">
  <a href="https://github.com/jazzyalex/agent-sessions/releases/latest"><b>Download Agent Sessions (DMG)</b></a>
  •
  <a href="https://github.com/jazzyalex/agent-sessions/releases">All Releases</a>
  •
  <a href="#install">Install</a>
  •
  <a href="#resume-workflows">Resume Workflows</a>
  •
  <a href="#development">Development</a>
</p>
```

---

## Notes for Alex (not part of the hero)

- The **download link** in the current README hardcodes a specific version (`.../download/v4.1/AgentSessions-4.1.dmg`). I swapped it to `releases/latest` so it never rots — but if you prefer the exact-DMG link for direct download, keep the versioned one and bump it each release.
- **~700 WAU** is a stated figure, not a live badge — GitHub has no such metric. If you'd rather not commit to a soft number in the hero, drop it and keep stars + downloads (both live) as the proof.
- I kept the existing icon table and the anchor nav so this drops in cleanly over the current lines 1–33.
- Consider a `[![Homebrew](https://img.shields.io/badge/homebrew-agent--sessions-orange)](...)` badge if you want the install path visible up top.
- The one-liner deliberately leads with the *job* ("one searchable home … history") rather than the feature list; the agent names follow so the SEO/keyword value is still there.
