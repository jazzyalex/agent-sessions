# Competitive Analysis — AgentsView (AV) vs Agent Sessions (AS)

**Date:** 2026-06-28
**Subject:** [AgentsView](https://github.com/kenn-io/agentsview) (kenn-io, MIT, ~3.4k stars) — an open-source, cross-platform session viewer that directly competes with Agent Sessions.
**Versions compared:** AS 4.0 (build 53) · AV 0.34.5 (2026-06-23)

> Companion docs:
> - [perf-transcript-virtualization-plan.md](perf-transcript-virtualization-plan.md) — the big speed refactor.
> - [perf-quick-wins.md](perf-quick-wins.md) — independent low-risk speed tickets.

---

## What each product is

| | Agent Sessions (AS) | AgentsView (AV) |
|---|---|---|
| **Stack** | Native macOS, AppKit/SwiftUI, single process | Go backend + Svelte 5 SPA; **Tauri 2** desktop wrapper running the Go binary as a localhost sidecar |
| **Footprint** | macOS 14+ only | macOS 11+, Windows, Linux, Docker; desktop app + self-host + CLI |
| **Agents** | 10 | **44** |
| **Posture** | Power-user *cockpit*: resume/launch, live HUD, quota runway, archive restore, zero telemetry | *Viewer + analytics platform*: breadth, sync, session intelligence, sharing |
| **Storage** | SQLite + FTS5 (`index.db`) | SQLite + FTS5 (`messages_fts`); optional Postgres/DuckDB |

**Key correction to a common misconception:** AV is *not* "just a web app." Its desktop build is a Tauri 2 shell (Rust + system webview) that launches the Go `agentsview` binary as a sidecar (`serve --no-browser`) on a local port and loads `localhost`. So the snappy app being compared against AS is a **local desktop app hitting a localhost server on the same machine** — apples-to-apples with AS. Its speed is the local SQLite+FTS5 index plus a virtualized frontend, **not** "web vs native."

---

## Feature parity table

Legend: ✅ present · ⚠️ partial / weaker · ❌ absent

| Capability | Agent Sessions (AS) | AgentsView (AV) |
|---|---|---|
| Agents supported | ⚠️ 10 (Codex, Claude, Antigravity, OpenCode, Hermes, Copilot, Droid, OpenClaw, Cursor, Pi) | ✅ **44** (+ Gemini, Zed, Warp, Kiro, Qwen, Aider, VS/VSCode Copilot, OpenHands, Forge, Kimi, many more) |
| Platforms | ⚠️ macOS 14+ only | ✅ macOS / Linux / Windows + Docker |
| Desktop app | ✅ native AppKit/SwiftUI | ✅ Tauri 2 webview + local Go sidecar (macOS, Windows) |
| Native macOS integration (menu-bar extra, Sparkle, native HUD) | ✅ | ❌ webview UI, no AppKit-level integration |
| Storage / index | ✅ SQLite + FTS5 | ✅ SQLite + FTS5 (+ Postgres/DuckDB) |
| Full-text search | ✅ FTS5 (warm path) | ✅ FTS5 (porter unicode61) |
| Filters | ✅ date/model/repo/path/archived/agent/kind | ✅ agent/machine/project/activity/type/starred |
| Transcript rendering | ⚠️ monospaced ANSI/attributed + JSON colorize; no markdown, no collapse | ✅ **markdown (GFM) + Shiki highlight + collapsible tool blocks + parallel groups + inline subagents + thinking blocks** |
| Resume / launch session | ✅ **native (Terminal/iTerm/Warp)** | ❌ viewer only |
| Archived-session restore | ✅ Claude + Codex restore | ❌ reads archived, no restore |
| Live session HUD / cockpit | ✅ **Agent Cockpit + Session Runway burn-rate** | ⚠️ SSE live updates, running-turn timers (no native HUD) |
| Multi-machine sync | ❌ | ✅ **Postgres push / SSH pull / S3** |
| Session intelligence (health grade A–F, outcome) | ❌ | ✅ |
| AI-generated insights | ❌ | ✅ (`claude -p` / `codex exec` locally) |
| MCP server | ❌ | ✅ (`search_sessions`, `get_messages`, …) |
| Secret scanning | ❌ | ✅ |
| Usage / cost tracking | ✅ quota strips (Codex/Claude) | ✅ **cost $, pricing, cache efficiency, treemap** |
| Analytics dashboard | ✅ charts / heatmap / breakdown | ✅ richer (velocity, grades, outcomes) |
| Export | ⚠️ Markdown | ✅ Markdown + HTML + GitHub Gist publish |
| Image gallery | ✅ screenshot grid | ❌ |
| Git context | ✅ Git Inspector (beta) | ✅ Recent Edits feed → exact message |
| Sharing / publish | ❌ | ✅ Gist |
| Telemetry | ✅ none | ⚠️ anonymous daemon ping (opt-out) |

### Where AS wins
Resume/launch into a terminal, archive **restore**, live native HUD + Session Runway burn-rate, menu-bar/native macOS integration, zero telemetry, screenshot gallery.

### Where AV wins
4× the agent coverage, true cross-platform, **transcript richness**, multi-machine sync, session intelligence (health grades/outcomes), AI insights, MCP server, secret scanning, cost tracking, and sharing/publish.

---

## The speed question — reframed

The instinct is "AV is fast because of a different architecture; AS is slow because native — so matching it means a big rewrite (add a DB/index)." **That premise is half-wrong, which is good news:**

**AS already has AV's core fast-path** — parse-once into SQLite, FTS5 full-text index, lightweight metadata-first hydration, bounded transcript cache, background queues. The DB foundation is not missing. AV's own README states the 100× comes from "session data already indexed in SQLite … vs tools that re-parse raw files on every run" — AS does *not* re-parse on every view; it hydrates from `index.db`.

So the felt 10–100× gap is concentrated in a few specific places, not architecture:

1. **Transcript rendering (biggest).** AS pushes the *entire* transcript into one `NSTextView` ([TranscriptPlainView.swift:3276/3347](../AgentSessions/Views/TranscriptPlainView.swift)) and re-runs whole-document colorization on six triggers ([:3352](../AgentSessions/Views/TranscriptPlainView.swift)). AV virtualizes (`@tanstack/virtual-core`, constant DOM) and serves windowed message pages (`WHERE ordinal >= ? LIMIT 100`). Opening a 10k-line session is where most of the gap lives. → [plan](perf-transcript-virtualization-plan.md).
2. **Self-throttling.** `lowerQoSForHeavyWork = true` ([FeatureFlags.swift:7](../AgentSessions/Support/FeatureFlags.swift)) runs work at `.utility` QoS and injects `Task.sleep(10ms)` between search batches ([SearchCoordinator.swift:515/590/835/934](../AgentSessions/Search/SearchCoordinator.swift)). A latency-for-smoothness trade that makes the app *feel* sluggish.
3. **Search fallbacks bypass FTS.** Cursor sessions are excluded from FTS and cold/restored sessions fall to a linear file scan with a non-memoized tokenizer ([FilterEngine.swift:192](../AgentSessions/Services/FilterEngine.swift)). AV routes everything through FTS5.
4. **Combine fan-in churn.** A 10-provider `CombineLatest` graph re-runs the full filter+sort on any emit, including indexing progress ticks ([UnifiedSessionIndexer.swift:738](../AgentSessions/Services/UnifiedSessionIndexer.swift)).

**Bottom line:** the win is a contained rendering refactor + removing artificial throttles, **not** an architectural rewrite. See the two companion docs for the plan and the quick wins.

---

## Strategic takeaways (not yet decisions)

- **Don't chase agent-count parity.** 44 vs 10 is AV's moat and a treadmill; AS should add agents opportunistically, not as a race.
- **Borrow the transcript presentation, keep the native shell.** AV's richer transcript (markdown, collapsible tool blocks, inline subagents) is its most visible quality lead and is portable to AppKit/SwiftUI.
- **Lean into AS-only strengths AV structurally can't match:** native resume/launch, archive restore, live HUD/Session Runway, zero-telemetry local-only posture.
- **Candidate net-new features inspired by AV:** session health/outcome grades, cost tracking in $, an MCP server exposing AS's index.
