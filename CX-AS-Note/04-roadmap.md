# Roadmap

## Active

- [ ] [2026-02-28] [Feature] Subagent session support in Session list (Codex first, then Claude)
  - Goal:
    - Detect and label subagent sessions explicitly in Session list rows.
    - Roll out support by source:
      1. Codex subagents,
      2. Claude subagents,
      3. Other providers later.
    - Next stage: optionally display subagent sessions as a subtree/group under the parent main session directly in Session list.
  - Inputs:
    - Current pain:
      - Subagent sessions are not clearly distinguished from main sessions.
      - Parent/child relationship is not visible in Session list.
  - Dependencies:
    - Provider-specific subagent identity signals (`kind`, inherited IDs, metadata conventions).
    - Stable parent-session linkage model suitable for list grouping.
    - Session list row model updates for badges/markers and optional tree rendering.
  - Definition of done:
    - Phase 1: Codex subagent sessions are clearly marked in Session list.
    - Phase 2: Claude subagent sessions are clearly marked in Session list.
    - Phase 3: Optional grouped/tree presentation behind a user-visible toggle or preference.
    - QA notes include mixed main + subagent scenarios and verify no regressions in selection/search.

- [ ] [2026-02-28] [Feature] Session rename (manual + agent-assisted)
  - Goal:
    - Allow users to rename sessions directly.
    - Support agent-assisted rename flow (ask agent to propose/perform rename) as an additional path.
  - Inputs:
    - Current pain:
      - Session titles are often auto-generated/noisy and hard to scan later.
  - Dependencies:
    - Persisted custom display-name storage keyed by stable session identity.
    - Conflict/merge behavior between computed title and user-defined title.
    - UX entry points in Session list/context menu and optional command palette action.
  - Definition of done:
    - Manual rename: user can set/edit/clear custom session title.
    - Agent-assisted rename: user can trigger rename suggestion/application flow.
    - Renames persist across refresh/reindex/restart and do not break sorting/filtering/search.

- [ ] [2026-02-28] [Bug] Session handoff after restart is delayed until first prompt (Codex + Claude)
  - Goal:
    - Ensure a newly started session B is recognized immediately after restart, even before first user prompt.
    - Ensure previous session A transitions out of live state without waiting for prompt activity in B.
  - Inputs:
    - Repro:
      1. Start session A and interact.
      2. Stop agent (`Ctrl+C`).
      3. Start agent again (session B), no prompt yet.
      4. Observe Cockpit/Unified live-state attribution.
    - Current behavior:
      - A can remain live/active too long.
      - B may not appear as current until first prompt.
  - Dependencies:
    - `CodexActiveSessionsModel` presence loading + join resolution.
    - `classifyLiveStates` and provider-specific probe fallback behavior.
    - Session join keys (`sessionId`, `sessionLogPath`, `tty`, `workspaceRoot`) before/after first event.
  - Definition of done:
    - Without sending a first prompt in B, UI correctly shows:
      - A as past (or not live),
      - B as live (idle/active as appropriate).
    - Works for both Codex and Claude.
    - Regression notes and exact validation steps captured in `CX-AS-Note/06-qa-notes.md`.

- [ ] [2026-02-13] [Bug] Codex sessions can be stale/missing until relaunch
  - Goal: diagnose why active rollout sessions are not visible or not updating when pressing Refresh, but become visible after app relaunch.
  - Inputs:
    - Codex session id observed: `rollout-2026-02-12T21-02-20-019c5560-e857-7392-85db-6d7f80583e5e`
    - Affected area: Codex indexing + lightweight parse + monitor refresh scheduling.
    - Candidate touchpoints: `SessionIndexer`, `SessionDiscovery`, `UnifiedSessionIndexer`, `SessionList/Unified view`.
  - Dependencies:
    - Confirm `refresh` trigger/mode semantics in `UnifiedSessionIndexer`.
    - Confirm delta window vs full scan behavior for recent/probe sessions.
    - Confirm lightweight/full parse decisions and search fallback.
  - Definition of done:
    - Refresh path yields visible updates for active sessions without app restart.
    - Search sees updates from actively-writing sessions without requiring cold restart.
    - Reproduction steps and validation notes captured in `CX-AS-Note/06-qa-notes.md`.

- [ ] [2026-02-13] [Design Decision] Hybrid refresh cadence for active + non-focused sessions
  - Goal:
    - Preserve focused session fast updates while preventing stale list states for other recently active sessions.
  - Inputs:
    - User feedback on expected visibility while reading one transcript and monitoring others.
  - Dependencies:
    - `UnifiedSessionIndexer.runNewSessionMonitorLoop()`
    - `UnifiedSessionIndexer.runFocusedSessionMonitorLoop()`
    - `SessionIndexer.refresh` mode/trigger behavior.
  - Definition of done:
    - Focused Codex/Claude session remains high-frequency update target.
    - Recent/visible non-focused sessions are refreshed on a lower frequency cadence.
    - List freshness improves for active sessions without regressing battery/CPU budget.

- [ ] [DATE] Name — Status: Not started
  - Goal:
  - Inputs:
  - Dependencies:
  - Definition of done:

## Completed

- [x] [DATE] Session memory bank structure initialized
  - Created `CX-AS-Note/` with standardized categories.
