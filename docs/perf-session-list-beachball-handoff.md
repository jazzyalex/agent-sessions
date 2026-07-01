# Performance Handoff — Session List Beachball (multi-second main-thread stalls)

**Status:** UNRESOLVED. Multiple view-side attempts failed. Profiling points the root
cause at the live-session polling subsystem, not the list-rebuild path. This doc hands
the problem to a dedicated overall-performance pass.

**Branch:** `perf/search-quick-wins` · **Dataset:** ~3,300–3,423 sessions ·
**Env:** macOS 15.7.x, Apple Silicon, Debug build.

---

## Symptom
- On the Unified session list with a large dataset, the app **beachballs (SPOD, macOS
  spinning wheel) for multiple seconds**.
- Triggered by **clicking sort column headers** (Msgs / Date / Session) and also during
  **idle/live churn** (the visible row count fluctuates, e.g. 3249 ↔ 3330, as live
  sessions appear/disappear).
- User also asked for an in-app "sorting in progress" affordance — but a spinner can't
  animate while the main thread is blocked, so that's downstream of fixing the stall.

## What was tried and did NOT resolve it (all reverted)
All were view-side (`UnifiedSessionsView`), built + launched + user-tested → "still / no change":
1. **Reentrancy deferral** — defer selection reconciliation off the `NSTableView` update
   cycle. An early DEBUG probe showed the *common* rebuild dropping 6–7 s → ~200 ms, but
   the user still hit beachballs.
2. **Signature gate** — skip the `cachedRows` rebuild when a hashed list-signature is
   unchanged. Broken: it hashed `messageCount`, which is **computed from `events`**, so a
   focused-session event load changed it → gate never skipped its target case.
3. **Coalescing** — 0.18 s bool-flag debounce of rebuilds. No change; added latency.
4. **Event-injection decouple** — indexer publishes an event-independent
   `listContentToken`; the view rebuilds off it instead of `unified.sessions`. "No
   change", and the token hash became the #2 CPU frame in the profile.
5. **C5 rebuild-skip** — skip `updateCachedRows()` on live-poll membership ticks when
   Active-only filtering is off. "Same shit", and it risks **stale fallback-presence live
   dots** (the direct presence is live, but cross-workspace *fallback* dots depend on
   `cachedFallbackPresenceBySessionKey`, which is rebuilt inside `updateCachedRows`).

Only committed work from this effort: the earlier **code-review fix batch (`8c1830fb`)**,
which is unrelated correctness (hydration-gate bypasses, Copilot inline images, etc.).

## Profiling evidence (definitive)
Method that worked:
```
sample <pid> 30 -f out.txt      # DURING a reproduced freeze — hammer sort for the full 30s
```
A first 15 s sample **missed** it (main ~88% idle in `mach_msg2_trap`) because the freeze
didn't land in the window. The 30 s coordinated sample caught it:

**Main thread 100% busy (426/426 samples, zero idle).** Hot main-thread clusters:

| ~samples | frame |
|---|---|
| 245–313 | `CodexActiveSessionsModel.startPollingIfNeeded` → `refreshOnce` → `performRefreshDiscovery` / `classifyLiveStatesAsync` → SwiftUI `Update.dispatchActions` cascade |
| 156 | `UnifiedSessionsView.updateCachedRows` (via body / `onReceive($activeMembershipVersion)`) → `SubagentHierarchyBuilder.build` + `rebuildCachedFallbackPresences` |
| 53–59 | `AgentCockpitHUDDerivedStateModel.rebuildIfReady` |
| (bg thread) | `ClaudeDesktopSessionTitles.records` filesystem scan (Runway loader) |

## Root cause (well-supported hypothesis)
`CodexActiveSessionsModel` is **`@MainActor`** (`CodexActiveSessionsModel.swift:123`).
Its poll loop (`startPollingIfNeeded`, ~`:503`) calls `refreshOnce()` (`:1155`) every
`pollIntervalSeconds()` **on the main thread**, doing filesystem discovery + process/iTerm
probing + live-state classification largely on main. Each refresh publishes `@Published`
changes (`presences`, `activeMembershipVersion` bump at `:1418`) → SwiftUI update cascade →
full re-renders:
- `activeMembershipVersion` → `onReceive` (`UnifiedSessionsView.swift:717`) →
  `updateCachedRows()` full ~3,300-row rebuild (`SubagentHierarchyBuilder.build` +
  fallback-presence map).
- Cockpit HUD derived-state rebuild.

**Sorting adds one more full rebuild on top of an already-saturated main thread.** The
list-rebuild path is a *contributor*, not the dominant cost — which is why every view-side
list optimization failed to move the needle. The dominant cost is the `@MainActor`
live-poll refresh + its SwiftUI publish cascade.

## Recommended next steps (priority order)
1. **Offload `CodexActiveSessionsModel.refreshOnce` heavy work off the main actor.**
   Run discovery/probe/classify on a background executor (nonisolated), publish only small
   result diffs back to `@MainActor`. Preserve the existing `refreshInFlight` / generation
   guards. **This is the biggest lever.** Delicate (stateful probing, iTerm/process) — do it
   carefully.
2. **Break the publish → full-rebuild cascade.**
   - `activeMembershipVersion` → `updateCachedRows()` (`UnifiedSessionsView.swift:717`) does
     a full rebuild for what is mostly a live-dot change. Decouple the fallback-presence map
     (`cachedFallbackPresenceBySessionKey`) so dots refresh without rebuilding 3,300 rows.
     (Naive skip breaks fallback-matched dots — see reverted C5.)
   - Debounce `AgentCockpitHUDDerivedStateModel.scheduleRebuild`.
3. **Reduce genuine-rebuild cost.** A full `cachedRows` reassignment reloads all ~3,300
   `NSTableView` rows; the DEBUG probe measured 6–7 s on some passes with an **"NSTableView
   reentrant operation"** warning. Investigate the reentrancy (selection mutation during
   reload) and per-cell cost: `SubagentHierarchyBuilder.build` ~60–90 ms (does
   `URL(fileURLWithPath:)` per session), and expensive computed getters
   `listTitle` / `rowRepoDisplay` / `messageCount`.
4. **Poll cadence backoff** while the window is busy / the user is actively interacting.

## Key files / anchors
- `AgentSessions/Services/CodexActiveSessionsModel.swift` — `@MainActor` (`:123`); poll loop
  (`:503`); `refreshOnce` (`:1155`); `activeMembershipVersion` bump (`:1418`);
  `pollIntervalSeconds` (`:2368`).
- `AgentSessions/Views/UnifiedSessionsView.swift` — `updateCachedRows`; `onReceive(
  $activeMembershipVersion)` (`:717`); `onChange(of: unified.sessions)`; source-cell
  `.id("source-cell-…-\(activeMembershipVersion)")` (`:2508`); fallback presence map
  (`buildFallbackPresenceMap` / `rebuildCachedFallbackPresences`).
- `AgentSessions/Services/SubagentHierarchyBuilder.swift` — `build` O(n) resolution.
- `AgentSessions/Model/Session.swift` — `Session.==` compares `eventCount`/`events.count`/
  edges (`:234`); `messageCount` computed from events (`:786`); `modifiedAt` computed (allocs).

## Commit state
- `8c1830fb` — prior code-review fixes (committed, unrelated to the beachball).
- This handoff doc — committed.
- No beachball fix landed; all attempts reverted to baseline.
