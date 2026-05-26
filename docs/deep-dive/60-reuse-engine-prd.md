# Agent Sessions Reuse Engine PRD

Status: Draft
Date: 2026-05-22
Scope: Product strategy, architecture, and MVP requirements for moving Agent Sessions from a macOS-only session browser toward a cross-platform local reuse engine.

## Executive Summary

Agent Sessions should not stay bounded by the Swift macOS app. The stronger product is a local-first reuse engine for coding-agent history:

- Core product: a cross-platform CLI plus local SQLite index.
- First hero workflow: generate a high-quality context pack for the next agent run.
- macOS app: a polished visual browser and live cockpit on top of the same index.
- Initial platform support: macOS only, because that is the environment available for real QA.
- Implementation direction: build the new engine in Rust, not Swift, while preserving the existing Swift app during migration.

The product should not begin by cloning a generic CLI viewer. That lane is already crowded. The wedge is action: `agent-sessions pack --repo . --goal "continue failed release work"` should return a ranked, evidence-backed handoff that a fresh Codex, Claude Code, Cursor, OpenCode, or other agent can use immediately.

## Current Repo Baseline

Verified local facts:

- The README positions the product as a "Unified session browser" and a local-first macOS app, with macOS 14+ as a requirement. Evidence: `README.md:1`, `README.md:12-21`.
- The README already names reuse as part of the job: search large histories, find prompt/tool output, then reuse by copying snippets or resuming sessions. Evidence: `README.md:35-37`.
- The current supported source list spans Codex CLI/Desktop/VS Code, Claude CLI/Desktop, Hermes, Cursor, Gemini, Copilot, OpenCode, OpenClaw, and Pi. Evidence: `README.md:64-75`, `AgentSessions/Model/SessionSource.swift:3-14`.
- Privacy posture is strong but currently app-shaped: local-only, no telemetry, local folders, local index, optional Sparkle update checks. Evidence: `README.md:47-55`, `docs/PRIVACY.md:1-18`, `docs/security.md:1-18`.
- The repo now has an MIT license. Evidence: `LICENSE:1-21`.
- The app already has a SQLite index at `~/Library/Application Support/AgentSessions/index.db`, with file scan state, session metadata, rollups, FTS-backed session search, and tool I/O search. Evidence: `docs/adr/0003-sqlite-rollups-index.md:10-29`, `AgentSessions/Indexing/DB.swift:10-25`, `AgentSessions/Indexing/DB.swift:273-327`, `AgentSessions/Indexing/DB.swift:329-373`.
- The current Swift architecture already separates sources and surfaces enough to make a shared core plausible: `SessionSource` is provider-oriented, `SessionSurface` distinguishes CLI/Desktop/VS Code/subagent, and `UnifiedSessionIndexer` aggregates provider indexers into one list. Evidence: `AgentSessions/Model/Session.swift:3-58`, `AgentSessions/Services/UnifiedSessionIndexer.swift:34-35`, `AgentSessions/Services/UnifiedSessionIndexer.swift:603-704`.
- Existing strategy docs already point to Context Pack as the hero workflow. Evidence: `docs/deep-dive/12-feature-specs.md:7-76`, `docs/deep-dive/50-growth-plan.md:17-33`, `docs/deep-dive/50-growth-plan.md:96-132`.

Current external baseline:

- `jazzyalex/agent-sessions` was verified with GitHub CLI at 566 stars, 34 forks, latest release `v3.8`, pushed `2026-05-21T19:29:28Z`.
- The old 2026-01-01 growth snapshot is stale. It reported 159 stars and a missing license. Evidence: `docs/deep-dive/00-state-of-the-project.md:8-15`, `docs/deep-dive/00-state-of-the-project.md:25-44`.

## Market Research Snapshot

This market changed materially. The "session viewer" lane is no longer empty.

### Claude Code Built-ins

I interpret the common shorthand `/insight` as Claude Code's official `/insights` command.

Claude Code now officially documents `/insights` as a command that generates a report analyzing Claude Code sessions, including project areas, interaction patterns, and friction points. It also documents `/team-onboarding`, which analyzes recent usage history and produces a markdown guide for teammates. Source: Claude Code Commands docs.

Claude Code also documents richer session management:

- sessions are saved locally and resumable;
- `/resume`, `claude --resume`, `--continue`, and `--from-pr` are first-class entry points;
- the session picker can widen from current worktree to all worktrees or all projects;
- `/export` can export the current conversation;
- transcripts live under `~/.claude/projects/<project>/<session-id>.jsonl`, with configurable storage via `CLAUDE_CONFIG_DIR`;
- local session files are removed after 30 days by default unless configured otherwise.

Implication: competing on "Claude session search" alone is weak. Claude itself now owns more of resume, naming, export, and retrospective analysis. Agent Sessions must be cross-agent and output-oriented.

### Direct And Adjacent Tools

Code Insights is a direct strategic signal. It is a free, open-source CLI plus embedded dashboard that parses Claude Code, Cursor, Codex CLI, Copilot CLI, and VS Code Copilot Chat into a local SQLite database. It offers a session browser, LLM-powered decisions/learnings/techniques, prompt quality analysis, weekly pattern synthesis, analytics, exports, and terminal stats. Source: Code Insights docs.

AgentsView is the closest current threat to the proposed direction. It is a local-first desktop and web app for browsing, searching, and analyzing past AI coding sessions across many agents. It ships desktop apps for macOS, Windows, and Linux, a CLI, a shared data directory, SQLite with FTS5, live sync, usage/cost CLI, and support claims for 20 AI coding agents. Verified with GitHub CLI: `wesm/agentsview` had 1080 stars, 139 forks, latest release `v0.29.0`, pushed `2026-05-21T16:20:11Z`. Source: AgentsView docs.

Claude Session is a narrower Claude-only tool that positions against native Claude by offering FTS5 search, cross-directory access, markdown export, key-point extraction, and token-efficient resume context. Source: Claude Session site.

Claude Chronicle focuses on curation and shareable single-file HTML export, including local processing, read-only source sessions, sanitization, Linux/macOS/Windows releases, and team handoff/postmortem/audit use cases. Source: Claude Chronicle site.

Agent Memory is a cross-agent persistent memory CLI. It uses local markdown files, optional qmd search, agent-specific skill files for Claude Code/Codex/Cursor/Agent, and context injection capped at 16K chars. Source: `jayzeng/agentmemory`.

Vibe-Log turns Claude Code and Codex sessions into local reports, standup summaries, and optional cloud analytics. It emphasizes "today's standup", local productivity reports, and hook/status-line workflows. Source: `vibe-log/vibe-log-cli`.

OpenUsage is an open-source terminal dashboard for spend, quotas, and rate limits across multiple coding agents and API providers, with local SQLite history. Source: OpenUsage site.

Clockwerk is a local work-history engine, not just an agent viewer. It uses hooks, daemonized event capture, local SQLite, session computation by idle gaps, CLI inspection, Studio, and export. Source: Clockwerk docs.

Cogpit, Poirot, Blackcrab, DossierKit, and other Claude-focused tools prove there is sustained demand for visual observability, but most are anchored to Claude Code or active-session control rooms.

## Strategic Conclusion

The proposed split is correct, but the wording needs to be sharper.

Do not pitch "cross-platform session viewer." That is already contested by AgentsView, Code Insights, Claude Session, and many Claude-specific dashboards.

Pitch:

> Local memory and context packs for coding agents.

The difference:

- Viewer: "Find a past session."
- Analytics: "Understand how you use agents."
- Memory service: "Remember facts across sessions."
- Reuse engine: "Produce the best next-agent handoff from what already happened."

Agent Sessions can still browse, search, and analyze, but those are supporting capabilities. The product-defining output is a context pack.

## Product Positioning

Primary sentence:

> Agent Sessions is a local-first reuse engine that turns past coding-agent sessions into ready-to-run context packs for your next agent.

Short variant:

> Stop re-explaining work to coding agents.

Developer-facing variant:

> Cross-agent local index and context-pack CLI for Codex, Claude Code, Cursor, OpenCode, Gemini, Copilot, and other coding agents.

Avoid leading with:

- macOS session browser;
- analytics dashboard;
- Claude Code viewer;
- usage tracker;
- generic memory.

Those are features or adjacent lanes, not the strongest category.

## Target Users

Primary user:

- Heavy coding-agent user with hundreds or thousands of local sessions.
- Uses more than one agent or switches between Codex and Claude Code.
- Works in local repos, SSH sessions, devcontainers, or parallel worktrees.
- Loses time reconstructing prior decisions, failed commands, verification state, and next steps.

Secondary user:

- Maintainer or team lead who wants local, share-safe handoff artifacts for PRs, incidents, onboarding, or delegation.

Not the MVP user:

- Enterprise observability buyer.
- Cloud dashboard user.
- User who only wants token-cost charts.
- User who wants a full IDE/worktree orchestrator.

## Jobs To Be Done

1. Continue work in a fresh agent session without replaying a long transcript.
2. Hand off a task to another agent, teammate, or future self.
3. Find the exact prior commands, errors, files, and decisions relevant to a new goal.
4. Trust the handoff because it includes evidence and says why each session was selected.
5. Keep sensitive coding history local unless the user explicitly exports.

## Non-Goals

For the first engine MVP, do not build:

- a generic terminal session viewer;
- a web dashboard;
- cloud sync;
- team account management;
- live multi-agent orchestration;
- a replacement for Claude Code `/insights`;
- semantic embeddings as a hard dependency;
- Windows support before macOS behavior is validated.

## Recommended Architecture

### Repository Shape

Target layout:

```text
crates/
  agent-sessions-core/
  agent-sessions-index/
  agent-sessions-pack/
  agent-sessions-cli/
AgentSessions/
  existing Swift macOS app
```

Package roles:

- `agent-sessions-core`: source discovery, provider parsers, normalized session/event model, path normalization, redaction primitives.
- `agent-sessions-index`: SQLite schema, migrations, FTS, incremental scan state, query APIs.
- `agent-sessions-pack`: relevance ranking, evidence extraction, pack assembly, formatters.
- `agent-sessions-cli`: terminal commands, JSON output, diagnostics, config.
- `AgentSessions.app`: visual browsing, live cockpit, rich transcript rendering, saved packs, and advanced UI.

### Language Recommendation

Use Rust for the new core and CLI.

Reasons:

- Cross-platform credibility without bringing a Node/Python runtime requirement.
- Good fit for file parsing, streaming JSONL, SQLite, FTS, path handling, redaction, and deterministic tests.
- Single-binary distribution is feasible for macOS first, then Linux, then Windows.
- Swift can call the CLI via `Process` initially, avoiding a risky immediate FFI migration.
- Later, the Swift app can embed the Rust library through a C ABI or continue using the CLI plus shared SQLite contract.

Why not Swift:

- Fastest path for the current app, but wrong product boundary for Linux, SSH, devcontainer, CI, and Windows users.
- Makes the CLI feel like a byproduct of a macOS app rather than the core engine.

Why not TypeScript:

- Faster iteration and strong ecosystem, but weaker trust story for a local indexing engine, heavier supply-chain surface, and less attractive single-binary distribution.
- Code Insights already owns much of the Node/npx-style lane.

Why not Go:

- Viable alternative. Go is good for single binaries and CLI UX.
- Rust is the better default here because parser correctness, memory safety, FFI optionality, and long-lived engine discipline matter more than fastest initial implementation.

### Migration Strategy

Do not rewrite the app first.

Phase 0:

- Keep the Swift app shipping.
- Create Rust CLI alongside the app.
- Let the CLI build its own index under a clearly versioned path such as `~/Library/Application Support/AgentSessions/engine/index.db` on macOS.
- Do not require the app to consume the Rust index in phase 0.

Phase 1:

- CLI supports `scan`, `search`, `pack`, `sources`, and `doctor`.
- Swift app can optionally call `agent-sessions pack` for context-pack generation.

Phase 2:

- Consolidate schema contracts between Swift and Rust.
- Move read-only source discovery/parsing rules into Rust.
- Decide whether Swift app reads Rust SQLite directly or invokes CLI JSON APIs.

Phase 3:

- Linux support once macOS parser/index behavior is stable.
- Windows support only after provider storage paths are researched and tested.

## CLI MVP

### Command Surface

```bash
agent-sessions scan
agent-sessions sources
agent-sessions search "xcode signing failure"
agent-sessions pack --repo . --goal "continue failed release work"
agent-sessions pack --session <id>
agent-sessions doctor
```

Do not ship dashboard commands in the first CLI MVP.

### `scan`

Purpose:

- Build or update the local index.

Requirements:

- Auto-detect supported source roots.
- Store file path, source, mtime, size, session ID, start/end time, cwd/repo, title, surface, model, message/tool counts.
- Incrementally re-index changed files only.
- Skip or defer hot files that are actively changing.
- Print a compact summary: sources found, sessions indexed, files skipped, duration, database path.
- Support `--json`.

### `sources`

Purpose:

- Explain what will be scanned.

Requirements:

- Show source name, detected path, status, count if cheap, and reason if unavailable.
- Support overrides via config or flags.
- Support `--json`.

### `search`

Purpose:

- Find candidate sessions from the index.

Requirements:

- FTS-backed search over normalized prompt, assistant, tool, command, error, file path, and title text.
- Output concise terminal results by default.
- Include session ID, source, repo, title, modified time, selected snippet, and why it matched.
- Support `--repo`, `--source`, `--since`, `--limit`, and `--json`.

### `pack`

Purpose:

- Produce the best handoff for the next agent run.

Requirements:

- Accept `--repo .` and `--goal`.
- Retrieve candidate sessions by repo/cwd, full-text query, recency, touched files, commands, errors, decisions, and verification signals.
- Rank sessions and explain selection.
- Extract evidence from transcripts and tool output without dumping raw logs.
- Generate a human-readable markdown pack by default.
- Support `--format markdown|json`.
- Support `--agent codex|claude|opencode|cursor|generic` to tune final prompt wording.
- Support `--share-safe` with redaction.
- Never mutate source session files.

### `doctor`

Purpose:

- Make local setup understandable.

Requirements:

- Check database access, source paths, supported provider roots, SQLite FTS availability, permissions, and stale schema.
- Report exact fix suggestions.
- Support `--json`.

## Context Pack MVP

Default output:

```markdown
# Agent Sessions Context Pack

## Goal
<goal passed by user>

## Recommended Starting Prompt
<pasteable prompt tuned to the selected agent>

## Selected Prior Sessions
1. <source> <title> <date> <session id>
   - Why selected: <reason>
   - Evidence: <short quote or paraphrase with file/session locator>

## What Already Happened
- <summary of work completed>

## Decisions
- <decision> - <rationale> - <evidence locator>

## Commands And Results
- `<command>` - passed/failed/unknown - <evidence locator>

## Files And Areas
- `<path>` - <what happened>

## Known Failures Or Warnings
- <failure> - <status> - <evidence locator>

## Next Steps
1. <step>
2. <step>
3. <step>

## Source Sessions
- <stable source/session references>
```

Hard requirements:

- The pack must explain why each session was selected.
- The pack must include evidence locators, not unsupported claims.
- The pack must distinguish verified facts from hypotheses.
- The pack must prefer commands that actually ran over guessed commands.
- The pack must be concise enough to paste into an agent.
- The pack must be useful even without LLM summarization.

Optional later layer:

- LLM synthesis can improve wording, infer decisions, and compress long evidence, but the rule-based/evidence-first pack must work without external calls.

## Ranking Model

MVP ranking should be deterministic.

Signals:

- repo/cwd match;
- direct text match against goal;
- recency;
- title/custom title match;
- touched files match if available;
- command/error match;
- session ended successfully or has verification commands;
- user-saved/bookmarked sessions;
- parent/subagent relationship;
- source-specific resume strength.

Avoid:

- opaque "AI picked this" ranking;
- embeddings as the only retrieval path;
- pulling unrelated sessions because they share a common word.

## Data Model Additions

The existing Swift DB already has useful pieces: `files`, `session_meta`, `session_search`, `session_search_fts`, `session_tool_io`, `session_tool_io_fts`, `session_days`, and rollups.

The engine should add or normalize:

- `sessions`: canonical row per session.
- `messages`: optional normalized message/event table for pack evidence.
- `tool_events`: command/tool name, input, output snippet, exit status if known.
- `file_mentions`: paths read/edited/generated, with source event references.
- `evidence_spans`: byte offsets or line/event IDs for cited pack claims.
- `packs`: saved context packs, goal, created time, selected sessions, hash of inputs.

Do not over-model every provider on day one. Preserve raw source locators so provider-specific extraction can improve later without losing trust.

## Privacy And Security

Baseline:

- Local-first.
- No telemetry.
- No session uploads.
- Read-only source scanning.
- Explicit export only.

New engine-specific requirements:

- `pack --share-safe` redacts home paths, usernames, common token formats, private key blocks, emails, URLs with credentials, and environment variables.
- `pack` clearly marks whether redaction was enabled.
- `doctor` prints data paths and what is stored.
- Any future LLM synthesis must be opt-in and must show what content would leave the machine.
- Saved packs are local files or local DB rows by default.

## Success Metrics

Product metrics:

- Median time from "I need to continue this work" to usable context pack: under 30 seconds after index warmup.
- Pack usefulness: user can paste the pack into a fresh agent and continue without manually opening prior sessions.
- Search-to-pack conversion: a search result can become a pack in one command or one app action.
- Trust: pack claims include evidence locators.

Technical metrics:

- `scan` incremental update for unchanged corpus: under 2 seconds on a 10k-session corpus after warmup.
- `search` common query latency: under 150 ms from warm index.
- `pack --repo . --goal ...`: under 5 seconds for deterministic pack without LLM synthesis on a 10k-session corpus.
- Index schema migration does not require manual cleanup.

Growth metrics:

- README and release messaging shift from "macOS session browser" to "local reuse engine".
- CLI install path exists independent of DMG.
- Public demo shows one loop: scan -> pack -> paste into agent -> continue work.

## 90-Day Plan

### Weeks 1-2: Engine Scaffold

- Create Rust workspace.
- Implement config/path resolution and provider trait.
- Implement read-only Codex and Claude discovery for macOS.
- Implement SQLite bootstrap with FTS5.
- Implement `sources`, `scan`, and `doctor`.
- Tests: fixture parsing, path detection, FTS search, schema migration.

### Weeks 3-5: Search And Pack MVP

- Implement normalized search corpus.
- Implement `search`.
- Implement deterministic `pack --repo . --goal`.
- Implement redaction.
- Add fixtures for high-signal context packs.
- Create golden pack tests.

### Weeks 6-7: App Bridge

- Add a Swift app entry point for "Copy Context Pack" or "Save Context Pack" that shells out to the CLI.
- Keep the existing app index untouched unless the bridge proves stable.
- Add app docs explaining the CLI/app split.

### Weeks 8-10: Distribution

- Ship macOS CLI binary.
- Add Homebrew formula or cask strategy.
- Update README positioning.
- Add demo GIF/video: failed release continuation pack.
- Publish "How Context Packs work" docs.

### Weeks 11-13: Hardening And Launch

- Add OpenCode/Cursor source support if stable enough.
- Add JSON output contract for integrations.
- Benchmark on a large corpus.
- Prepare Show HN and awesome-list submissions around the new hero loop.

## Open Questions

1. Should the CLI use the existing `agent-sessions` name or a distinct `asx`/`as` shorthand?
2. Should the first index path be shared with the Swift app or isolated until stable?
3. Which two sources should the Rust MVP support first: Codex + Claude, or Codex + Claude + Cursor?
4. Should saved packs live as markdown files, SQLite rows, or both?
5. Is LLM synthesis allowed as an opt-in in MVP, or should MVP stay fully deterministic?
6. Should `pack` include a "recommended resume command" when the selected source has reliable resume support?
7. How should Desktop/CLI/VS Code surfaces be represented in CLI output so existing app truth is preserved?

## Decision Recommendation

Build the reuse engine as a Rust CLI and local index, macOS-only at first. Keep the Swift app as the macOS power surface. Do not rewrite the current app first, and do not ship a generic CLI dashboard first.

The next product bet should be:

```bash
agent-sessions pack --repo . --goal "continue failed release work"
```

That command is the category. Search, analytics, app browsing, screenshots, live cockpit, and saved sessions should support that command rather than compete with it for the headline.

## Research Sources

- Claude Code Commands: https://code.claude.com/docs/en/commands
- Claude Code Sessions: https://code.claude.com/docs/en/sessions
- Code Insights docs: https://code-insights.app/docs/getting-started/introduction
- AgentsView docs: https://www.agentsview.io/
- Claude Session: https://claudesession.com/
- Claude Chronicle: https://claudechronicle.com/
- Agent Memory: https://github.com/jayzeng/agentmemory
- Vibe-Log CLI: https://github.com/vibe-log/vibe-log-cli
- OpenUsage: https://openusage.sh/
- Clockwerk: https://getclockwerk.com/
- Cogpit: https://cogpit.dev/
