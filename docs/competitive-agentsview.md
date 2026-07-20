# Competitive Analysis — AgentsView (AV) vs Agent Sessions (AS)

**Date:** 2026-06-28
**Subject:** [AgentsView](https://github.com/kenn-io/agentsview) (kenn-io, MIT, ~3.4k stars) — an open-source, cross-platform session viewer that directly competes with Agent Sessions.
**Versions compared:** AS 4.0 (build 53) · AV 0.34.5 (2026-06-23)

> **Update 2026-07-14 (source-verified refresh).** The AV clone in `.reference/agentsview` is newer than 0.34.5 and changes three claims below — all read directly from AV's code, not its docs:
> 1. AV **now resumes sessions** (including OpenCode: `opencode --session …`) and can launch a configured terminal — it is **no longer "viewer only."**
> 2. AV **renders no images at all** — image/attachment content is skipped or flattened to text placeholders.
> 3. AV is **read-only toward the agent stores** (server `ReadOnly` mode, `:ro` mounts) and cannot save/restore a session back into the agent.
>
> A new **"UI philosophy"** section is added below; corrected table rows are marked *corrected 2026-07-14*.

> Companion docs:
> - [competitive-codexbar.md](competitive-codexbar.md) — **CodexBar (18.7k★) is the competitor on the live-cockpit/quota axis, not AV.** AV has no live HUD; CodexBar's live-session detection is *broader* than AS's. Read that doc before making any claim about live sessions, quota, or the Quota Meter.
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

## UI philosophy — the core difference

Reading AV's current source (not the 0.34.5 notes above) makes the split concrete, and it is bigger than "native vs webview."

**AgentsView is a local web analytics console.** The frontend is a single-page Svelte 5 app (`frontend/src/App.svelte` + `main.ts` — no per-view routing; one client-rendered app) built around a `ThreeColumnLayout` and a command palette. Its component tree is organized like a data product, not a document viewer: dedicated *pages* for `analytics`, `insights`, `trends`, `usage`, `activity`, `recentedits`, `pinned`, and `trash`, plus `SignalPanel` and `SessionVitals` inside the transcript. The transcript is rich and web-native — virtualized `MessageList`, GFM markdown, Shiki-highlighted `CodeBlock`, collapsible `ToolBlock`/`ThinkingBlock`, `SubagentInline`, `ParallelGroup`, `CompactBoundaryDivider`. The whole thing is something you *browse and analyze* like a dashboard: cost treemaps, health grades, velocity trends, keyboard-driven navigation. It runs identically in a Tauri webview, at localhost, or self-hosted/Docker — the same web console everywhere.

**Agent Sessions is a native macOS cockpit.** AppKit/SwiftUI, a menu-bar extra, Sparkle updates, HIG spacing, and a single operational flow: list → transcript → act. The center of gravity is *doing something with the session now* — resume/launch into a terminal, a live Agent Cockpit HUD, image/screenshot browsing, archive restore — not analyzing it after the fact. It is macOS-only and behaves like a Mac app, down to the window chrome.

**The session list itself reflects the split.** AS renders a native SwiftUI `Table` with sortable columns — `★ / Agent / Session / Date / Project / Msgs / Size` (`AgentSessions/Views/UnifiedSessionsView.swift:1011-1110`), each with a sort keypath, so clicking a header sorts the grid. AV renders a compact left-sidebar item per session (title, project, relative time, machine tag, agent tag, plus star/subagent/teammate badges — `frontend/src/lib/components/sidebar/SessionItem.svelte`); sorting lives in a separate control, not column headers. AS surfaces **Size** and **message count** as first-class sortable columns AV doesn't show in-row; AV's underlying row model carries more fields (15, incl. `machine`/`is_teammate`/`termination_status`) but presents them as sidebar context, not a grid. **Both filter by agent, but the surfacing is where AS wins.** AS puts always-visible **agent pills** right in the toolbar — one-click capsule toggles per agent (`AgentTabToggle`), collapsing into an "Agents ▾" overflow menu only past four (`AgentSessions/Views/UnifiedSessionsView.swift:3460-3484`). AV's agent filter is a searchable multi-select checkbox list with per-agent counts, but it's tucked behind a generic **"Filters"** button in the sidebar header (`SessionFilterControl.svelte:139`, mounted at `SessionList.svelte:488`) — same capability, materially lower discoverability. Not a feature gap; a UX-friction gap in AS's favor.

The practical read: AV optimizes for **breadth and post-hoc intelligence** (44 agents, cost/analytics, cross-platform, sync, sharing); AS optimizes for **native, private, in-the-moment operation** on a Mac. They overlap on the session list and transcript, but the surrounding philosophy differs enough that users self-select by which they want — a web-style analytics console, or a native operational cockpit.

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
| Resume / launch session | ✅ **native, one-click into Terminal/iTerm/Warp** | ✅ *corrected 2026-07-14:* builds resume cmd (opencode/claude/codex/copilot/gemini/amp) and launches a configured terminal (auto/custom) or copies to clipboard — **no longer "viewer only"** |
| Save / restore sessions (write-back to the agent) | ✅ Claude + Codex archive restore | ❌ *corrected 2026-07-14:* **read-only by design** — server `ReadOnly` mode, agent stores mounted `:ro`; star/pin/exclude/trash write only to AV's own catalog, never back to the agent |
| Live session HUD / cockpit | ✅ **Agent Cockpit + Session Runway burn-rate** | ⚠️ SSE live updates, running-turn timers (no native HUD) |
| Multi-machine sync | ❌ | ✅ **Postgres push / SSH pull / S3** |
| Session intelligence (health grade A–F, outcome) | ❌ | ✅ |
| AI-generated insights | ❌ | ✅ (`claude -p` / `codex exec` locally) |
| MCP server | ❌ | ✅ (`search_sessions`, `get_messages`, …) |
| Secret scanning | ❌ | ✅ |
| Usage / cost tracking | ✅ quota strips (Codex/Claude) | ✅ **cost $, pricing, cache efficiency, treemap** |
| Analytics dashboard | ✅ charts / heatmap / breakdown | ✅ richer (velocity, grades, outcomes) |
| Export | ⚠️ Markdown | ✅ Markdown + HTML + GitHub Gist publish |
| Images (inline + gallery) | ✅ inline images + screenshot grid | ❌ *corrected 2026-07-14:* **no image rendering at all** — parsers classify `image`/`canvas` as non-text and skip or flatten them to `[Attachment: …]` text; no `<img>`/`data:image` anywhere in the UI |
| Git context | ✅ Git Inspector (beta) | ✅ Recent Edits feed → exact message |
| Sharing / publish | ❌ | ✅ Gist |
| Telemetry | ✅ none | ⚠️ anonymous daemon ping (opt-out) |

### Where AS wins
Source-verified as of 2026-07-14: **image display + screenshot gallery** (AV renders none), **session save/restore write-back** (AV is read-only toward the agent stores), **native macOS integration** (menu-bar extra, Sparkle, live Agent Cockpit HUD + Session Runway), and **zero telemetry** (AV pings an anonymous daemon, opt-out). Resume/launch is now *parity* — AV added it — so AS's remaining resume edge is the native Terminal/iTerm/Warp preset UX baked into the app, not the capability itself.

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
