# W3 — Click-to-Focus Snappiness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Clicking a session row focuses it immediately, every time — no dropped clicks, no visible pause — by removing the periodic main-thread blocks the click queues behind (live-poll work on the main actor; synchronous row rebuilds), and cutting idle poll work at the source with file watching.

**Architecture:** Recon (2026-07-02, in `.superpowers/sdd/` W3 recon report + progress ledger) proved the click path itself is lightweight; the symptom is head-of-line blocking. Three offenders, in suspected order: (1) `CodexActiveSessionsModel.refreshOnce`'s main-actor phases — registry dir-scan + per-file JSON decodes (`loadPresences`, CodexActiveSessionsModel.swift:798-806/1582-1600), `Process.run()` fork/exec for ps/osascript probes launched pre-await on main (`runManagedCommand` :676-721), merge/classify (:1287-1440), and a Cockpit-gated SQLite read inside `refreshPublish` (:1441-1444); (2) `updateCachedRows()` (~115 ms at 3.3k rows) running synchronously on main per `unified.sessions` republish (UnifiedSessionsView.swift:2253-2381, call site :1150-1179) — its heavy phases (fallback-presence map, sort, hierarchy build) are pure functions over `Sendable` value types; (3) the 2 s disk poll itself, replaceable by FSEvents/DispatchSource watching (none exists in the codebase — new infra). The plan measures first (spans exist but were never captured on a current build), then de-mains in order of measured weight, then replaces the registry poll with watching. This is deliberately incremental — the full `PresenceEngine` actor extraction (original W3 sketch) remains the end-state if measurement shows merge/classify itself is heavy; otherwise it folds into W6.

**Tech Stack:** Swift 5 concurrency (actors, `nonisolated` async), SwiftUI/AppKit, `DispatchSource`/FSEvents (new), XCTest, `Perf` spans (Release no-op shim exists — no `#if DEBUG` guards needed at call sites).

## Global Constraints

- Commits: Conventional Commits with `Tool: Claude Code` / `Model: claude-fable-5` / `Why:` trailers. No co-author. Per-task commits authorized; NEVER push. Current branch (`perf/search-quick-wins`); no branches/worktrees.
- New Swift files via `LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 ./scripts/xcode_add_file.rb AgentSessions.xcodeproj <TARGET> <path> <group>`.
- Verification cadence per task: focused tests → full suite (`./scripts/xcode_test_stable.sh`, ~1092+, 0 failures) → **Release build** (`xcodebuild -configuration Release build`) — Release is mandatory on this branch.
- Behavior parity: presence classification results, membership-version bump semantics, publish-suppression heuristics, and row content must be byte-identical — only WHERE work runs changes. Any observable ordering change is a defect.
- The dedupe/selection state machines in UnifiedSessionsView (BuildSignature, selection policies, churn flags) are freshly reviewed — do not restructure them; move work around them.
- User-facing app launches for QA: detached via `open` (never as a child of a session background pipeline).

---

### Task 0: Measurement — rank the main-thread offenders (controller + user, no subagent)

- [ ] Add one missing span: wrap `classifyLiveStatesAsync`'s synchronous tail (`Self.classifyLiveStates`, CodexActiveSessionsModel.swift:1151) in `Perf.begin("refreshClassify", thresholdMs: 4)` — tiny diff, commit `perf(poll): add classify span`.
- [ ] Build Debug; launch ATTACHED for a short window with stdout grep for `loadPresences|refreshMerge|refreshClassify|refreshPublish|updateCachedRows|fallbackPresences|hierarchyBuild|STALL`; ask the user to click around the session list for ~2 minutes with normal agent activity running; then killall and relaunch DETACHED for their continued use.
- [ ] Tabulate: per-span p50/max, STALL count/durations, and which spans coincide with stalls. Record in the ledger + this plan's gate table.
- [ ] **Gate:** order Tasks 2–4 by measured weight; drop any task whose target measures < ~10 ms/tick (record the decision).

### Task 1: Off-main discovery — registry reads + probe launches leave the main actor

**Files:** Modify `AgentSessions/Services/CodexActiveSessionsModel.swift`. Test: `AgentSessionsTests/` (find the existing model's test file by grep; add there or create `CodexPresenceDiscoveryTests.swift`).

**Interfaces:** `performRefreshDiscovery` (:766-891) already consumes only immutable snapshots built by `refreshOnce` (:1188-1228) — that was the extraction seam all along. Produce: a `nonisolated` async discovery entry point (same signature + an explicit snapshot struct if parameters are unwieldy) so that awaiting it from the main actor executes on the cooperative pool, not main. Inside it: `Self.loadPresences` (already `nonisolated static`) now actually runs off-main; `runManagedCommand`'s `command.start()` (fork/exec) runs off-main; the utility-queue output drain and termination waits are unchanged. Anything the discovery path currently reads from `self` must become a parameter (the recon lists the snapshot fields — verify by compiling, the isolation checker enumerates violations for you). Post-discovery mutation of caches (`cachedProcessPresences` etc., :1265-1285) stays on the main actor in `refreshOnce` exactly as today.

TDD: the pure pieces (any helper you extract to make discovery `nonisolated`) get unit tests; the isolation change itself is compile-enforced. Add one behavior test if a seam allows: discovery given a temp registry dir returns identical presences on main-actor vs detached invocation. Full suite + Release. Commit: `perf(poll): run presence discovery off the main actor`.

**Named risk for the reviewer:** `deferExpensiveProbesUntil`/generation guards read mid-discovery — ensure they were already snapshotted (recon says yes) and no new cross-actor read snuck in. And: `Process` termination handlers + continuations must not assume main.

### Task 2: `updateCachedRows` heavy phases off-main (snapshot pipeline)

**Files:** Modify `AgentSessions/Views/UnifiedSessionsView.swift` (:2253-2381 + call sites), possibly a new pure `AgentSessions/Services/SessionRowsBuilder.swift`. Tests: extend the policy test class (grep `TranscriptRenderGenerationGateTests` / wherever `UnifiedTableSelectionPolicy` tests live) + new pure-builder tests.

**Interfaces:** Extract phases 1/2/4/6a of the recon's anatomy — fallback-presence map (`buildFallbackPresenceMap`, :3105+), sort (:2296-2302), `SubagentHierarchyBuilder.build` (already a pure enum), row-derived sets (:2383-2393) — into a pure `SessionRowsBuilder.build(input: RowsInput) -> RowsOutput` where `RowsInput` snapshots `[Session]`, presences, sortOrder, collapsedParents, search results, flags (all `Sendable` per recon). The `.onChange(of: unified.sessions)` handler computes `RowsOutput` on a background task and applies it on main: assign `cachedRows`/`hierarchyRowMeta`/derived sets + run the UNCHANGED selection-reconciliation block (:2358-2380, including the churn-deferral flag and `UnifiedTableIdentityPolicy.isLargeReorder` bump — identity/selection logic stays main-side and byte-identical). Staleness discipline: tag each computation with the triggering sessions-array generation; apply only if still current (a newer republish supersedes) — mirror the BuildSignature pattern. Synchronous callers of `updateCachedRows()` that need immediate rows (grep the 14 call sites; e.g. filter toggles) may keep a synchronous path for small datasets OR await the async pipeline — judge per call site, keep the diff minimal, document each choice.

TDD: `SessionRowsBuilder` parity tests — output equals the legacy synchronous computation for randomized fixtures (port the legacy phases as the oracle before deleting them). Full suite + Release. Commit: `perf(list): compute row rebuilds off-main, apply as generation-checked snapshots`.

**Named risks:** selection reconciliation must still see fresh rows in the same main-actor turn as the apply (no user-visible window where rows and selection disagree); the tableReorderGeneration bump must happen with the apply, not the compute; re-entrancy (new republish mid-compute) must supersede, never interleave.

### Task 3: Publish-side residuals

**Files:** `CodexActiveSessionsModel.swift` (:1373-1457). Move the Cockpit-gated `runtimeCodexSubagentCountsByPresenceKey` SQLite read (:1441-1444, :1969+) off the main actor (compute in discovery/classify stage or a detached read applied next tick); keep the publish diffing/suppression logic (:1381-1433) main-side (it's cheap and touches @Published). Only if Task 0 measured `refreshMerge`/`refreshClassify` heavy: extract merge/classify into the background stage too (they're pure over the snapshot maps per recon) — otherwise leave and note. Tests: parity on any moved pure function. Commit: `perf(poll): move publish-side SQLite read off the main actor`.

### Task 4: FSEvents/DispatchSource registry watcher (kill the 2 s disk poll)

**Files:** Create `AgentSessions/Services/RegistryWatcher.swift` (+ tests). Modify `CodexActiveSessionsModel` poll loop (:503-515, :2386+).

**Interfaces:** `RegistryWatcher` — DispatchSource-based directory watcher (`DispatchSource.makeFileSystemObjectSource` on each registry root's dirfd, `.write` events; recreate on rename/delete; debounce 250 ms) with an AsyncStream of change events. The poll loop becomes: refresh on watcher events + a slow TTL sweep (e.g. every 30 s foreground / existing background intervals) as the staleness backstop — presence TTL expiry and process-probe cadence still need timed refreshes, so the timer doesn't die, it slows. All existing interval policies (:125-129, `effectivePollIntervalSeconds`) remain as the sweep cadence; `refreshSoon`/`refreshNow`/visibility triggers unchanged. NO behavior change to what a refresh does — only when it fires.

TDD: watcher unit tests with a temp dir (create/modify/delete a .json → events fire; debounce coalesces bursts). Integration: model-level test that a registry write triggers a refresh without waiting a full sweep (if the model's test seams allow; otherwise pin at the watcher layer and note). Full suite + Release. Commit: `perf(poll): watch registry roots with DispatchSource; demote timer to TTL sweep`.

**Named risks:** dirfd leaks on watcher recreate; events during app-inactive (watcher should pause or events queue harmlessly — decide, document); the deferExpensiveProbes selection throttle must still apply to watcher-triggered refreshes.

### Task 5: Gate — joint QA + numbers (controller + user)

- [ ] Fresh Debug build; short attached capture window repeating Task 0's measurement during user clicking; then detached relaunch.
- [ ] Compare span table vs Task 0 baseline; STALL count target: near-zero during idle, no stall > ~50 ms coinciding with clicks.
- [ ] User verdict on click feel (the actual acceptance bar) + idle Battery/energy glance (the W3 side benefit).
- [ ] Record in ledger + perf-master-plan W3 outcome note. If click feel still fails: sample DURING the user's clicking and re-diagnose before any further code (evidence-first, as ever).

## Deferred / explicitly not this plan

- Full `PresenceEngine` actor extraction with AsyncStream snapshots — do it as W6's presence half if Task 0/3 show merge/classify heavy or when TranscriptDerivedState work begins; Tasks 1–4 here are designed to be forward-compatible with it (snapshot-in, snapshot-out seams).
- Table→NSTableView swap (W5) — unchanged trigger: measured p95 sort > 200 ms at 40k synthetic rows.
- Cockpit/HUD further gating — Task 7's gate already landed; revisit only if gate numbers implicate it.
