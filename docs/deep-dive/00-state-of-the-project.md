# Agent Sessions: 10/10 Deep Dive (2026-01-01)

Scope: strategy + planning only. No code changes in this document.

Repository: https://github.com/jazzyalex/agent-sessions

## Snapshot (facts, not vibes)

As of 2026-01-01 (from GitHub APIs and this repo checkout):
- GitHub: 159 stars, 8 forks, 2 open issues
- Releases: 26 total; release downloads: ~1,174 DMG downloads (~1,204 total asset downloads)
- Recent releases (DMG downloads): v2.9.1 (28), v2.9 (41), v2.8.1 (212), v2.6 (110), v2.4 (140)
- CI: macOS build runs `xcodebuild` (no signing) on every push/PR (`.github/workflows/ci.yml`)

## What is genuinely strong (keep and double down)

1) You already ship like a real app
- Signed/notarized distribution flow exists (Sparkle feed + deployment runbook).
- “Download DMG” is a concrete, low-friction call-to-action.

2) Clear job-to-be-done and a differentiable niche
- “Find and resume any past AI coding session” is an actual painkiller for terminal-based agent users.
- Multi-agent support is not common in native desktop viewers; it is a moat if you keep it maintainable.

3) Local-first is a huge trust angle (if you actually package it right)
- You can win users who refuse cloud dashboards and telemetry, and who want a private “second brain” for coding sessions.

## What will cap adoption if you do nothing

### 1) Trust and “open source legitimacy” gap (highest leverage fix)
- The README claims “open source”, but the repo has no top-level `LICENSE` file. For a lot of developers, “no license” equals “not open source” and “I cannot contribute”.
- The app is explicitly not sandboxed (`AgentSessions/AgentSessions.entitlements`). That may be the right engineering decision for a developer tool, but it must be explained with clarity:
  - what is read
  - what is never read
  - what is stored locally
  - what is executed (and under what user action)

If you fix only one thing for growth, fix licensing + security posture docs.

### 2) Architecture duplication tax is already visible
You have near-copy session indexers per provider with repeated concepts:
- Progress throttling
- Filters + Combine pipelines
- Transcript caching
- Refresh token logic

Evidence: `AgentSessions/Services/SessionIndexer.swift`, `AgentSessions/Services/ClaudeSessionIndexer.swift`, `AgentSessions/Services/GeminiSessionIndexer.swift`, `AgentSessions/Services/OpenCodeSessionIndexer.swift`, `AgentSessions/Services/CopilotSessionIndexer.swift`, `AgentSessions/Services/DroidSessionIndexer.swift`.

This will slow you down disproportionately as more agents/formats change.

### 3) Scale story for “thousands of sessions / 10k+ messages”
Right now, search correctness leans on parsing and transcript generation/caching. That can work, but:
- in-memory transcript caching does not scale linearly
- “generate transcripts to search” is expensive compared to DB-backed search

You already have SQLite in the app (`AgentSessions/Indexing/DB.swift`). The clean next step is to turn it into the primary search/index layer (FTS-backed), not just analytics rollups.

## North star (what the product should become)

If you want 10/10 “vibe coding workflow” impact without turning into a full IDE:

Agent Sessions becomes the local-first memory layer for terminal AI:
- Unified timeline across Codex CLI, Claude Code, Gemini CLI, Copilot CLI, OpenCode, Droid
- “Context Pack” export that rehydrates a new agent session in seconds
- Limits radar (Codex + Claude usage) so you do not get cut off mid-work
- Quality signals (what was compiled/tested, what changed, what decisions were made)
- Optional integrations with multi-session/worktree managers (Crystal, Claude Squad) instead of competing head-on

## The strict mentor take: should you keep investing?

Yes, if you make these three pivots in effort allocation:
1) Trust + licensing first (otherwise growth stalls regardless of feature quality)
2) One hero workflow for resuming work (Context Pack + Command Palette)
3) Refactor for agent scalability (make “add new agent” cheap)

No, if you keep shipping incremental UI features while leaving:
- no license
- unclear security posture
- a widening duplication tax

## Immediate priorities (next 30 days)

Priority tags: URGENT / HIGH / MEDIUM / LOW.

- URGENT: Add `LICENSE`, `SECURITY.md`, and a crisp “Security and Privacy” doc that explains the non-sandbox decision and all subprocess behavior.
- HIGH: Ship a “Context Pack” export workflow (local, no cloud) as the primary vibe-coder painkiller.
- HIGH: Start the refactor track to unify session indexers behind a shared adapter/indexer core.
- MEDIUM: Reduce repo ballast (large binaries/logs/backups tracked in git) to lower contributor friction and improve repo hygiene.
- MEDIUM: Add DB-backed search (SQLite FTS) to make “thousands of sessions” feel instant and reduce transcript generation pressure.

## Repo hygiene and privacy (this is bigger than “cleanliness”)

This repo currently tracks some generated artifacts that include local machine paths.
That has two practical impacts:
- privacy: absolute paths and local directory names can leak into the public repo
- trust: contributors will wonder what else is accidentally committed

Examples (tracked in git as of this checkout):
- `docs/AgentSessions-2.9.1.dmg` (large binary release artifact committed to git)
- `scripts/probe_scan_output/*.txt` (generated scan outputs; at least one file contains absolute paths)
- `AgentSessions.xcodeproj/project.pbxproj.*` backup variants (merge/conflict and contributor friction)

Even if you do nothing else, cleaning these up is a high-leverage “trust repair” move.

