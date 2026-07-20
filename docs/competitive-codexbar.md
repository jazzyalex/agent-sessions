# Competitive Analysis — CodexBar vs Agent Sessions

**Date:** 2026-07-20
**Subject:** [steipete/CodexBar](https://github.com/steipete/CodexBar) — macOS menu-bar usage/quota monitor. **18,723 stars**, actively developed (commits same-day as this analysis), macOS 14+, Swift.
**Method:** read directly from a shallow clone of CodexBar's source — not its README or docs.

> Companion doc: [competitive-agentsview.md](competitive-agentsview.md) — AgentsView is the competitor on the *session browser* axis. **CodexBar is the competitor on the *live cockpit / quota* axis.** They barely overlap with each other; AS is the only product standing in both.

---

## Why this doc exists

Prior positioning work treated AgentsView as "the competitor." That is wrong for the Quota Meter and Agent Cockpit. AV has no live HUD at all. **CodexBar does** — and on live-session detection it is broader than AS. Any marketing claim about "live session monitoring" must be checked against CodexBar, not AV.

---

## What CodexBar is

A menu-bar app showing usage/quota across **~30 providers** (Codex, Claude, Cursor, OpenCode, Gemini, Copilot, Droid, Devin, z.ai, Kimi, Warp, OpenRouter, and more — each with its own auth path: OAuth, cookies, API keys, local files). Per-provider **session (5-hour), weekly, and monthly windows with reset countdowns**, credit balances, spend dashboards, and provider status polling. Ships a macOS app, a CLI, and a widget.

It also has an **opt-in "Agent Sessions" feature** (off by default) that discovers, lists, and focuses live agent sessions.

---

## The overlap: CodexBar's agent-sessions vs AS Agent Cockpit

This is a real overlap, and **CodexBar is broader**. Source-verified:

**Two discovery paths:**

1. **Process-based** (`AgentPSOutputParser`, `Sources/CodexBarCore/AgentSession.swift`) — scans `ps` for running `codex` / `claude` processes, so it is **terminal-independent**. Explicitly whitelists the desktop-app binary `/Applications/Codex.app/Contents/Resources/codex` (`:289`). `source(for:)` (`:254`) returns `.desktopApp` for Claude when the path contains `Application Support/Claude/claude-code`, else `.cli`.
2. **File-based** ("file-only" sessions) — `CodexRolloutMetadata.sessionSource` (`:521-535`) reads the Codex rollout JSONL's `originator`/`source` fields and maps them to surfaces: `desktop`/`app-server` → `.desktopApp`; `ide`/`vscode`/`cursor`/`zed` → **`.ide`**; `codex_exec`/`exec`/`cli` → `.cli`. Plus inference at `:493` (unknown metadata + `app-server` present → `.desktopApp`).

**Focus:** `SessionWindowFocuser.swift:70-71` maps `(.claude, .desktopApp)` → `com.anthropic.claudefordesktop` and `(.codex, .desktopApp)` → `com.openai.codex`, raising the real desktop window.

**Remote:** discovers and lists sessions on **SSH / Tailscale-connected hosts** (`RemoteSessionFetcher`, `remoteHosts`).

### Head-to-head, live-session detection

| | AS Agent Cockpit | CodexBar agent-sessions |
|---|---|---|
| Agents | Codex CLI, Claude CLI, **OpenCode CLI** | Codex, Claude only (`enum Provider { codex, claude }`) |
| Terminal scope | **iTerm2 only** | Any terminal (process-scoped) |
| Desktop apps | ❌ | ✅ Codex.app, Claude Desktop |
| IDE surfaces | ❌ | ✅ VS Code / Cursor / Zed (via rollout metadata) |
| Remote hosts | ❌ | ✅ SSH / Tailscale |
| Focus/jump | ✅ jump to session in-app | ✅ raises the app/terminal window |
| Default state | on | opt-in, off by default |

**Conclusion: do not market AS live-session detection as differentiated.** AS wins only on OpenCode; CodexBar wins on terminal-independence, desktop, IDE, and remote.

---

## The moat: per-session quota attribution

CodexBar's session model is **presence-only**. `AgentSession` (`Sources/CodexBarCore/AgentSession.swift:3-61`) carries exactly:

```
id, provider, source, state (.active/.idle), pid, cwd,
projectName, sessionName, startedAt, lastActivityAt, transcriptPath, host
```

**No tokens. No cost. No burn rate. No quota linkage.**

Two terminology traps that make CodexBar *look* like it does per-session burn when it does not:

1. **"Session limits"** and `UsageStore+SessionEquivalents.swift` refer to the **5-hour quota window** (paired with weekly for plan-utilization math) — the provider's window, nothing to do with an individual agent session.
2. **`burnRate`** appears in exactly one file — `Sources/CodexBarWidget/CombinedBurnDownWidgetViews.swift:340` — as an **aggregate** quota burn-down curve (`%/unit-t`) for a widget chart. Not attributed to any session.

So CodexBar holds both halves side by side and **never joins them**: it knows which sessions are live, and it knows aggregate quota. It never asks *which session is spending it*.

### What only AS does

**Session Runway** attributes burn to the individual session, against the live 5h/weekly window, with selectable lenses (5-hour %, weekly %, tokens/hour, $/hour) — and the `$` lens prices **each model within a session at its own rate**, so an Opus orchestrator driving Sonnet subagents is costed per-model rather than blended.

**The single defensible claim:**

> Per-session — and per-model-within-session — burn attribution against the live 5h/weekly quota window.

Nothing else in the live/quota space is uniquely AS.

---

## The three-way map

| | Session browser + history | Live session detection | Aggregate quota | **Per-session burn attribution** |
|---|---|---|---|---|
| AgentsView | ✅ (44 agents) | ⚠️ SSE/running-turn only | ❌ | ❌ |
| CodexBar | ❌ | ✅ **broadest** | ✅ ~30 providers | ❌ |
| **Agent Sessions** | ✅ (10 agents) | ⚠️ iTerm2-scoped | ✅ Codex + Claude | ✅ **only** |

AS is the only product in all four columns, and the sole occupant of the last one. That — not coverage, not "a native HUD" — is the position.

---

## Positioning rules that follow

1. **Lead with Session Runway / per-session burn.** It is the only uncontested claim.
2. **Never claim breadth** of live-session detection, click-to-focus, provider count, or agent count. Each is matched or beaten.
3. **Agent Cockpit is supporting cast**, not a headline — and its "(Beta)" label currently sits on the *overlapping* feature while the moat (QM) is nested inside it. That burial is backwards.
4. **Re-verify before any "only app that…" claim ships.** CodexBar commits daily and has ~110-contributor-scale momentum; per-session attribution is not a hard feature for them to add if they see it working.

---

## Notable incidental finding

CodexBar classifies session surface (CLI / desktop / IDE) by reading the Codex rollout's `originator` / `source` metadata fields (`:521-535`). AS deliberately stopped relying on those fields because DB-hydrated sessions have them NULL (the surface-pill mislabel bug), and now keys off file path instead. If AS ever wants reliable surface labels, CodexBar's parse-at-discovery approach is a working reference implementation.
