# Roadmap

## Active

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
