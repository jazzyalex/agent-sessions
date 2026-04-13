# Roadmap

## Active

- [ ] [2026-03-01] [Feature] Agent Cockpit branch column (post-HUD parity release)
  - Goal:
    - Add branch display to Agent Cockpit rows after backend/data support is explicitly approved.
    - Keep compact mode branch-free even after branch support ships.
  - Update [2026-03-03]:
    - Branch support explicitly deferred for current HUD stabilization pass.
    - Evaluate branch source strategy before implementation:
      1. `Session.gitBranch` only (cheap, may be sparse in lightweight rows),
      2. `Session.gitBranch` + live git fallback from `cwd` (more complete, async),
      3. tab-title heuristic fallback (low confidence).
  - Inputs:
    - Current release intentionally hides branch in all Agent Cockpit modes to avoid introducing new backend capability.
  - Dependencies:
    - Confirmed branch-source strategy for live rows (without regressing current backend parity guarantees).
    - HUD row layout update for non-compact modes only.
    - QA coverage for dark/light, grouped/flat, and filter states.
  - Definition of done:
    - Branch column appears in non-compact Agent Cockpit views with stable data.
    - Compact mode continues hiding branch by design.
    - Changelog + summary entries document the behavior split.

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

- [ ] [2026-03-11] [Feature] Session bookmarks / collections
  - Goal:
    - Let users save important sessions for quick return.
    - Support lightweight organization beyond a flat session list.
  - Inputs:
    - User feedback requests bookmark-style saving and collections/grouping for frequently revisited sessions.
  - Dependencies:
    - Stable persisted metadata keyed by session identity.
    - UX entry points in Session list and/or detail views for add/remove/manage actions.
    - Clear model choice for v1: simple bookmarks first vs full user-defined collections.
  - Definition of done:
    - Users can mark sessions as saved/bookmarked and find them quickly later.
    - If collections ship in v1, users can assign a saved session to at least one named collection.
    - Behavior persists across refresh/reindex/restart.


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

- [x] [2026-02-28] [Bug] Session handoff after restart is delayed until first prompt (Codex + Claude) — Fixed 2026-04-12

- [x] [2026-02-13] [Bug] Codex sessions can be stale/missing until relaunch — Fixed 2026-04-12

- [x] [2026-02-26] [Bug] Ghost active Codex subagent rows in Cockpit — Fixed 2026-04-12

- [x] [2026-02-26] [Bug] Claude sessions showing as open when actually active — Fixed 2026-04-12
