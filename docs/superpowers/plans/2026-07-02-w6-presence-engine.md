# W6 — PresenceEngine + @Observable Presence Model (scoped subsystem rewrite)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Idle CPU becomes boring and interaction becomes smooth by fixing the one measured architectural defect left: every 2-second presence publish re-evaluates entire SwiftUI view trees because views observe a god-object. Acceptance bar (measured autonomously): **idle-with-QM < 5%; main window open + idle < 10%; key-down scrubbing smooth (select-walk bench: N steps → ~1 propagation, no stall > 50 ms); warm selection→content < 300 ms.** If the bar still fails after W6 lands, the full-rewrite discussion returns with endorsement — that is the agreed backstop.

**Architecture (from the two recon reports in `.superpowers/sdd/`, 2026-07-02):** Two moves, deliberately scoped to `CodexActiveSessionsModel` (3 @Published, 5 Combine consumer sites, 3 view files — tractable) and NOT `UnifiedSessionIndexer` (39 @Published, 10-child Combine aggregation, not the hot cadence — out of scope). Move 1: extract `actor PresenceEngine` — poll loop, registry reads, ps/osascript probe launches, merge/classify, publish-decision — everything `refreshOnce` does — off the main actor, emitting immutable `PresenceSnapshot`s at a controlled cadence (2 s foreground; 10–15 s background for freshness-only changes; membership/badge changes pass immediately, so the Quota Meter stays live). `CodexActiveSessionsModel` shrinks to a thin @MainActor facade: applies snapshots, retains the synchronous lookup API views call (`presence(for:)`, `liveState(...)`, `isActive/isLive`, `supportsLiveSessions`, visibility/consumer setters — full census in the recon), and keeps identical publish-semantics (`activeMembershipVersion` bumps only on real change). Move 2: migrate the facade to `@Observable` (macOS 14 floor confirmed; zero prior @Observable usage — this sets the codebase idiom) so a presence tick re-evaluates ONLY views that read presence properties — with explicit `PassthroughSubject`s replacing the 5 Combine-dependent sites (the @Observable macro removes `$` publishers and `objectWillChange`).

**Tech Stack:** Swift 5.9 concurrency (actor, AsyncStream), Observation framework (`@Observable`, macOS 14+), Combine bridges (explicit subjects), XCTest, Perf spans, select-walk bench (`AS_PERF_BENCH=select`).

## Global Constraints

- Commits: Conventional Commits + `Tool: Claude Code` / `Model: claude-fable-5` / `Why:` trailers, no co-author. Per-task commits authorized; NEVER push. Current branch; no branches/worktrees.
- Verification per task: focused tests → full suite (~1120+, 0 failures) → **Release build** (mandatory).
- **Behavior parity is absolute**: presence classification results, membership/badge bump semantics, publish-suppression heuristics, consumer-visibility cadence switching, `deferExpensiveProbesForSelectionOpen`, and every sync-lookup result must be identical. Only WHERE work runs and WHO re-renders change.
- The Quota Meter and HUD must keep updating on real membership/state changes with no added latency; only freshness-only background updates may slow.
- User-facing launches detached via `open`; measurement windows attached and short.
- New files via xcode_add_file.rb (LC_ALL/LANG prefix; no double-add).

---

### Task 1: `PresenceSnapshot` + `PresenceEngine` actor (compute side), facade applies

**Files:** Create `AgentSessions/Services/PresenceEngine.swift`, `AgentSessions/Services/PresenceSnapshot.swift`; modify `AgentSessions/Services/CodexActiveSessionsModel.swift`. Tests: create `AgentSessionsTests/PresenceEngineTests.swift`.

**Interfaces:**
- `struct PresenceSnapshot: Sendable, Equatable` — `presences: [CodexActivePresence]` (sorted as today), `liveStateByPresenceKey`, `idleReasonByPresenceKey`, `lastActivityByPresenceKey`, `membershipVersion: UInt64`, `badgeVersion: UInt64`, `runtimeSubagentCountsByPresenceKey: [String: Int]`, plus whatever the facade's sync lookups need (derive the exact field list from the model's current private state census in the W3 recon — `bySessionID`/`byLogPath` lookups become snapshot-embedded dictionaries).
- `actor PresenceEngine` — owns: the poll loop (`start/stop`), interval policies (port `pollIntervalSeconds`/`effectivePollIntervalSeconds` + visibility/appActive inputs as plain `Sendable` settings pushed in via `updateEnvironment(_:)`), registry reads (`loadPresences`), probe launches (`runManagedCommand`/`discoverProcessPresences`/`loadITermSessions` — all currently main-actor-hosted; they move wholesale), merge/dedup, classify (incl. the osascript batch probe), publish-decision (signature diffing + suppression heuristics + version bumps), and the Cockpit-gated SQLite read. Emits via `AsyncStream<PresenceSnapshot>` — one element ONLY when the publish-decision says publish (exact same conditions as today), tagged `isMembershipChange: Bool`.
- Facade: `CodexActiveSessionsModel` keeps its entire public API; internally it consumes the stream on the main actor, stores `latestSnapshot`, updates the 3 @Published from it. `refreshNow`/`refreshSoon`/visibility setters forward to the engine. Sync lookups read `latestSnapshot`.
- **Cadence diet lands here**: the engine suppresses freshness-only (non-membership) snapshot emission when the app is inactive to ≥10 s intervals; membership/badge changes always emit immediately. (This absorbs the deferred "publish backoff" one-off.)

TDD: the engine's pure pieces (merge, classify given fixed probe outputs, publish-decision, cadence policy) get direct actor tests with injected fixtures — port the semantics from the existing code as oracle where extractable; the probe-execution paths are integration-verified by parity behavior (Task 4 gate) and existing registry tests (`CodexActiveSessionsRegistryTests` — keep green). Named risks for the reviewer: generation-guard semantics across the actor boundary; `refreshNow`'s cancel-inflight-probes behavior; no main-actor state reads left inside the engine (compiler-enforced); `SessionRowsBuilder`'s documented dependency on main-actor `presence(for:)` still holds via the facade.

Commit: `refactor(presence): extract PresenceEngine actor — poll/probes/merge/classify/publish off the main actor`.

### Task 2: `@Observable` facade + Combine bridges

**Files:** Modify `CodexActiveSessionsModel.swift`, `AgentSessionsApp.swift:179` (@StateObject→@State), `UsageMenuBar.swift:104`, `UnifiedSessionsView.swift:318`, `AgentCockpitHUDView.swift:576`, `CockpitView.swift:16` (@EnvironmentObject→@Environment), `StatusItemController.swift:58,83-86`, plus the 5 Combine sites. Tests: extend `PresenceEngineTests` + affected model tests.

**Interfaces:**
- `@Observable @MainActor final class CodexActiveSessionsModel` — `private(set) var presences/activeMembershipVersion/subagentBadgeVersion` become plain observable properties.
- Explicit bridge subjects ON the model (Combine stays available to a class; only synthesized `$`/objectWillChange vanish): `let membershipTicks = PassthroughSubject<UInt64, Never>()`, `let badgeTicks = PassthroughSubject<UInt64, Never>()`, `let presenceUpdates = PassthroughSubject<[CodexActivePresence], Never>()` — fired at the exact points the properties change.
- The 5 consumer sites migrate mechanically (recon census): `AgentCockpitHUDDerivedStateModel` sinks → `presenceUpdates`/`badgeTicks`; `UsageMenuBarLiveSummaryModel` → `membershipTicks`; `StatusItemController.objectWillChange` sink → subscribe to all three subjects (equivalent trigger surface — verify what its `scheduleLengthUpdate` actually needs and note if narrower is correct); `UnifiedSessionsView.onReceive($activeMembershipVersion)` → `.onReceive(membershipTicks)`.
- `.environmentObject(activeSessions)` injections (App + StatusItemController's NSHostingView + the #Preview) → `.environment(...)`.

Named risks: `@Observable` + `@MainActor` interplay (fine on 14+, but the macro rejects property wrappers — confirm none of the 3 properties uses one beyond `private(set)`); SwiftUI views that READ `presences` in bodies must still update (Observation tracking covers it — the Task 4 bench proves it); no view silently loses updates because it observed via objectWillChange semantics before (the whole-body re-eval masked missing reads — property-level tracking exposes them; QA gate watches for stale UI).

Commit: `refactor(presence): @Observable presence model — property-level view invalidation + explicit Combine bridges`.

### Task 3: In-flight one-offs reconciled + observation-width audit

Fold-ins and residue, one commit: (a) verify the selection stability window + select bench (landed separately) interact correctly with the new facade (the propagation path reads `presence(for:)` — unchanged API); (b) audit the three hot view files for accidental wide observation under @Observable (a body that touches `presences` when it only needs `activeMembershipVersion` re-evaluates per presence change — narrow reads where trivial, list what you narrowed); (c) delete any now-dead Combine plumbing (old cancellables, `bind()` shapes) flagged by the compiler or grep. Full suite + Release.

Commit: `refactor(presence): narrow hot-view observation; remove dead presence plumbing`.

### Task 4: Acceptance gate (controller, autonomous)

- [ ] Build Debug; attached measurement: (1) idle with QM only (main window closed) — `ps` CPU over 3 min + 10 s sample; (2) main window open, idle — same; (3) `AS_PERF_BENCH=select AS_PERF_BENCH_CYCLES=30 AS_PERF_BENCH_INTERVAL=0.06` — selectWalkStep vs selectionPropagate counts, STALL log, CPU during walk; (4) warm selection→content: from the bench's propagate event to the transcript `transcriptModelBuild ... range=` span completion on a mid-size session (< 300 ms target).
- [ ] Compare against the bar: **idle-with-QM < 5%; window-open idle < 10%; walk coalesces (~1 propagate per rest) with no >50 ms stall; warm select < 300 ms.**
- [ ] Record verdict + numbers in ledger + perf-master-plan (W6 outcome note). PASS → relaunch detached, hand to user for feel-confirmation, then branch close-out per the standing workflow. FAIL → sample the failing dimension, one diagnosis note, and the rewrite conversation reopens per the backstop — no further patching.

## Deferred / explicitly not this plan

- `UnifiedSessionIndexer` @Observable migration (39 @Published + 10-child Combine aggregation; not the measured hot cadence). Revisit only if Task 4's window-open idle number implicates indexer publishes.
- FSEvents registry watcher (W3 Task 4): the PresenceEngine's background cadence diet reduces its urgency; keep as a follow-on inside the engine (it's now ONE actor's implementation detail — the right home when it happens).
- TranscriptDerivedState extraction (original W6 transcript half): transcript module measured fine post-Task-9; the Phase-4 caches stand as its embryo. Revisit with the loadOlder work.
