# Final whole-branch review — Session Source Registry program

Range: `0e2cb747..48276c72` (11 commits, 57 files, +4662/−2411, all on `main`)
Reviewer: final whole-branch pass (Fable), 2026-08-16. Read-only; no edits, builds, or commits.
Orientation: SPEC rev 2 + §6.A′ amendment, full SDD ledger (Tasks 0–9), `docs/adding-a-session-source.md`.

## Verdict: **APPROVED FOR QA** — zero must-fix items

The program is done. Nothing found in this pass requires a fix task before the owner's
batched visual QA. Two controller-accepted widenings still carry **pending owner
sign-off** (Task 7's `analyticsIsStale` correction; Task 8's upgrade-path enablement
convergence) — both were surfaced in chat and are adjudications, not defects; they fold
naturally into the QA pass.

---

## A. Deferred-minors triage

Tally: **0 must-fix / 6 follow-up / 18 accept-as-is / 6 already resolved by later tasks.**

### Already resolved inside the program (no action)

| Item | Resolution verified |
|---|---|
| T1: SourceKeyTable unpinned vs test table | `testDescriptorKeysMatchTheStabilityTests` cross-check landed in Task 2 (`SessionSourceRegistryTests.swift:33`) |
| T1 (half): dead `?? A` fallback at `UnifiedSessionIndexer.swift:1827` | Gone — Task 7's rewrite removed it (site now focused-signature bookkeeping) |
| T2 M3: `SessionArchiveBackfill.minimalSession` unpinned twin | Task 5 verified byte-identical then deleted the `SessionArchiveManager` copy |
| T2 M7: `resolveBackfillURLsFromFilesystem` internal `.standard` read | Task 5 passes `.standard` explicitly (`SessionArchiveManager.swift:374-380`, with doc comment) |
| T5 M-3: `applyFiltersAndSort`/`updateLaunchState` hand-written conjunction | Task 7's `activeSources(included:enabled:)` is now the single policy; both sites read it (verified at `UnifiedSessionIndexer.swift:861,2104,2206`) |
| T6: `AnalyticsService.runtimes` computed per access | Now a stored `private let runtimes: [SourceRuntime]` (`AnalyticsService.swift:22`) |

### Follow-up tasks (none needs to ride this branch)

1. **Stale `SessionSourceRegistry.swift:21` header** — still reads "THE one remaining
   hand-maintained per-source list", contradicting SPEC §6.A′.16 and guide row 19b
   (`PreferencesTab.sidebarAgentSources` is the second). One-line comment fix; the guide
   (the contributor entry point) and SPEC are already correct, so nobody following the
   documented path is misled — it does **not** need to ride this branch, but it is the
   top item for the next docs/comment commit.
2. **Dead `?? same-key` double-reads in `PresenceEngine.swift:1565,1574,1596`** — still
   present, provably dead (`a ?? a` on an identical expression), zero behavior impact.
   The already-offered spawn chip covers it. Does not need to ride this branch.
3. **`AvailabilityContext.live()` zero-caller seam** (`SessionSourceDescriptor.swift:122`,
   T4 minor) — confirmed dead at HEAD (no call sites outside its own definition). It is
   the *uncached* detector with a documented hot-path hazard; delete it or mark it
   test-only so a future consumer cannot reintroduce PATH sweeps. Fold T4's stale
   `live()` doc-comment minor into the same edit.
4. **T5 M-1: `expectedAllowed()` tautology in the allow-list test** — the kimi-exclusion
   and enablement-off legs are genuine, but the helper re-implements
   `allowedSearchSources` verbatim; add the `XCTAssertFalse(empty)` guard +
   unconditional positive-membership pin. Test hardening only.
5. **Guide-rot sentinel test** (Task 9 concern 3) — named a backlog candidate in the
   ledger but **never filed in `docs/backlog.md`** (no entry found). agents.md's new
   Backlog section (added by this very branch) requires deferred work to be recorded
   with a stamp line. File it.
6. **@AppStorage literal-default convergence** (new finding N1 below) — converge the
   hermes/cursor/openclaw `@AppStorage` defaults in `AnalyticsView`,
   `FirstRunSetupView` and `PreferencesView` to `AgentEnablement.isEnabled(...)`
   initializers, the pattern their own pi/kimi/grok rows already use.

### Accept-as-is (with one-line justifications)

- T1: unused key-table columns; table-self-referential openclaw test (13th-source sentinel by design).
- T2 M4 (dark-leg parity redundancy), M5 (mapping-not-strings — the literal strings are pinned by the stability test), M6 (AppKit-at-lazy-init — closed by the `@autoclosure`/closure discipline Task 3 landed and the guide §4.2 documents).
- T3: 24 `Color.agentX` statics stay hand-maintained — out of scope by design; guide §4.2 marks them optional aliases.
- T4: tautological `testEnablementKeyMatchesRegistryDescriptor…` (dead coverage, harmless); `binaryInstalled(for:detect:)` hardcoding `.standard` (documented in-file at `AgentEnablement.swift:279` — no `isBinaryInstalled` closure reads `ctx.defaults` today, and the key-location rule keeps it that way).
- T5 M-2 (test writes to `.standard` under hosted bundle — value-neutral, restored), M-4 informational.
- T6: trivially-satisfied churn test (the Mirror-based `testCatalogHasNoPublishedStoredProperties` is the real K16 guard — both exist); `indexer(_:as:)` weak constraint (traps loudly with a named message); injectable `init(runtimes:)` partial-catalog edge (test seam; `UnifiedSessionIndexer.init(handles:)` carries its own completeness precondition); `@MainActor` init narrowing (necessary, callers already main).
- T7 M1 (absent-key `?? false`/`?? []` unexercised — dictionaries are complete by construction), M2 (no-op republish skip, outcome-identical), M3 (`orderedSources` comment nit — `allCases` and registry order are test-pinned equal; fold into follow-up 1 if desired), M4 (24 memoized probes at init), M5 (test-comment inaccuracy), M6 (wall-clock-timed emission test — ran green twice; watch for CI flake before hardening), M7 (`activeSources`/`isSourceActive` twin spelling — both read the same two dictionaries, semantically identical).
- T8 M2 (duplicate assertions), M3 (pill test coupling by convention, documented), M4 (codex/claude arms in `includeBinding` — reachable via the segmented pills, not actually dead), M5 (droid-pane comment nit), M6 (observer re-allocated per view-struct init — SwiftUI `@State` discards duplicates; minor waste only).

---

## B. Cross-task integration sweep

**Hermes end-to-end trace (`.whenAvailable`, absent key on upgrade installs) — consistent
at every registry-driven layer.** `AgentEnablement.isEnabled(.hermes)` → explicit key if
present, else `isAvailable` (root probe then binary, through `AvailabilityContext` with
the cached detector) → seeds `enablementBySource` at `UnifiedSessionIndexer` init and on
every enablement-key write via the key-filtered defaults observer →
`applyEnablement` republishes the dictionary and mirrors `hermesAgentEnabled` → pills
(`enabledOtherAgentSpecs` gates on `unified.isAgentEnabled`), notice
(`flashAgentEnablementNoticeIfNeeded` over `allCases`), list filter, launch state and
search allow-list all read the same `activeSources` conjunction. `seedIfNeeded` never
re-runs after `didSeedEnabledAgents`, so the absent-key state is durable — and every
converged layer gives the same availability-derived answer for it. The story is
self-consistent; the only dissenters are the three §6.A′ `@AppStorage` islands (finding
N1). The notice observer and the indexer's sync observer are separate main-queue
subscribers to the same defaults writes; worst case the notice reads a value one cycle
stale — cosmetic, idempotent, no cycle.

**ProviderHandle → folds → views: clean.** All twelve adapters' handle and searchAdapter
closures capture only the local `indexer` (hermes read in full; remaining eleven verified
arm-by-arm by the Task 6 review). `UnifiedSessionIndexer.init` captures `sources`/`ordered`
as locals and every sink uses `[weak self]`, so the stored pipelines never retain the
indexer and `deinit` (`:2344`) keeps running. Multiple folds subscribing one `@Published`
handle publisher is ordinary Combine fan-out, not double-subscription.
`AnalyticsService` subscribes `handle.launchPhase` independently via `combineLatestArray`
(not `MergeMany`, per the spike finding) — correct. No ordering hazard found: dictionary
publishes before mirrors inside `applyEnablement`, and `publishAfterCurrentUpdate` defers
all cross-pipeline writes past the render pass.

**§8.5 × §8.4 circularity — none.** The write path is one-directional: Preferences toggle
→ `AgentEnablement.setEnabled` writes the key → both filtered observers fire →
(a) view flashes notice + re-asserts footer visibility (no defaults writes),
(b) indexer syncs → `applyEnablement` (mutates `@Published` only) → possible
`requestProviderRefresh` (no enablement-key writes). `applyInclude` writes include keys,
which are not in either observer's key list. Same-value rewrites terminate on the
`!=` guards. No path writes an observed key from inside a handler.

**K16 — holds with all consumers wired.** `SessionProviderCatalog` has zero `@Published`
members and `runtimes` is a `let`; it is `ObservableObject` solely for the single
`@StateObject` in `AgentSessionsApp:182` (lifetime guarantee; `objectWillChange` can never
fire). Every other consumer holds it as a plain `let`
(`UnifiedSessionsView:335`, `FirstRunSetupView:16`, `AnalyticsService:15`,
`TranscriptHostView:3940`). No `@ObservedObject`/`@EnvironmentObject` over the catalog
anywhere. Both K16 tests exist (`testCatalogHasNoPublishedStoredProperties`,
`testCatalogDoesNotEmitWhenAnIndexerChurns`).

**K15 — holds.** `Session.swift` imports Foundation only; `computeIsHousekeeping`'s ten
written-out arms are literal `return false` with an explicit K15 comment, reading nothing
from the registry. pbxproj confirms `Session.swift` compiles into both `AgentSessions`
and `AgentSessionsLogicTests`; no registry/adapter/catalog file is in the logic target.
Ledger records LogicTests 55/0 re-run after the Task 8 edit.

**xcodeproj — clean.** All 21 program-added files (Task 2's 17, Task 6's 3, Task 8's 1)
have exactly 4 references each (fileRef + group child + PBXBuildFile + Sources-phase
entry), no duplicates. Target mapping verified: app files in `AgentSessions`, the three
test files in `AgentSessionsTests`, exactly one Sources phase each.

**CHANGELOG — no on-branch gap.** `CHANGELOG.md` is a pointer; `docs/CHANGELOG.md` is
authored at release time by `deploy bump`, and its `[Unreleased]` section is empty by
convention between releases. So the program correctly touched neither. **At the next
release** the §8 user-visible fixes must appear under Bug Fixes: kimi/grok launch-phase
coverage (§8.1/8.2), openclaw enablement unification + the phantom every-launch refresh
and `analyticsIsStale` flip it killed (§8.3, pending sign-off), the enablement notice for
all twelve sources (§8.4), and filter-view search respecting enablement (§8.5). These are
fixes to *shipped* behavior (4.7/4.8), so the deploy skill's "never announce a bug the
user never had" rule does not exclude them.

**RepoHandover.md — stale-forward, not contradictory.** The newest entry (2026-08-14,
release-4.8) predates the program and closes with "Session-source registry refactor —
still the next real task." Nothing in it contradicts what the branch changed, but
CLAUDE.md routes every new agent through that entry first, and it now points at work that
is complete. Recommend a handover entry at program close (finding N2).

---

## C. Behavior-change audit

Sanctioned changes verified in place: §8.1 (twelve-source `launchPhase` fold,
`UnifiedSessionIndexer:803`), §8.2 (`updateLaunchState` covers all sources; inactive →
`.ready`), §8.3 (`openClawAgentEnabled` mirror seeds from `AgentEnablement.isEnabled`,
comment at `:409-411`), §8.4 (single `agentEnablementObserver` receiver,
`UnifiedSessionsView:667`, key list derived from `allCases`), §8.5
(`start(allowed: unified.allowedSearchSources())`, K9 signature confirmed at
`SearchCoordinator.swift:171`). Preserved behaviors verified: §8.6 OpenCode's
mode/trigger/profile drop now lives *in its own adapter* with a SPEC-tagged comment
(`OpenCodeSourceDescriptor.swift:88-92`) — better home, same behavior; §8.7 droid pane
still hidden (`sidebarHiddenSources`, backlogged); §8.8 kimi/grok cwd fallback
backlogged. All three preserved items are recorded in `docs/backlog.md` ("Three
per-source behaviors the registry refactor deliberately preserved").

**Sweep for unsanctioned changes: one residual cross-surface disagreement found, and it
is pre-existing bytes, not program drift (N1 below).** No other emergent behavior change
surfaced: pill/search/list/launch visibility all derive from one conjunction now, so the
class of disagreement the sweep targeted is structurally closed for every
registry-driven surface. The FirstRun `hasToolCallEvent` divergence was proven zero in
practice by the Task 8 reviewer (DB-hydrated sessions construct with `events: []` and
never mutate). `mergedAggregationResult`, progress aggregation, error preference and
archive/parse arms were verified identity-preserving arm-by-arm in their task reviews;
spot-checks here (archive capability reads, `SessionTerminalView` shortLabel,
`sourceAccent` fallback) matched.

## New findings

**N1 (low, residual — follow-up 6): absent-key enablement cohort sees a cross-surface
disagreement.** `AnalyticsView:7-26`, `FirstRunSetupView:21-32` and `PreferencesView`'s
binding defaults keep literal `@AppStorage` defaults (`hermes`/`cursor` `= true`,
`openclaw` `= false`) while pi/kimi/grok in the *same blocks* already use
`AgentEnablement.isEnabled(...)`. For an upgrade install whose seed ran before a
`.whenAvailable` source existed (key never written): with hermes not installed, the main
window now (post-Task-8) hides its pill and excludes it from search — correct — while
the Analytics picker still offers/gates on hermes as enabled; with openclaw installed,
the inverse. The bytes are identical to BASE (verified against `0e2cb747`) and the
indexer disagreed with these views at BASE too — the program did not introduce it, but
Task 8's sanctioned convergence made the main window correct and left these three
islands as the last dissenters, so the asymmetry is now *visible* rather than uniform.
Narrow cohort, view-local effect only. Fix is mechanical (the pi/kimi/grok pattern).

**N2 (info): RepoHandover.md needs a program-close entry.** Newest entry says the
registry refactor is "still the next real task"; every future agent reads that first.

**N3 (info): the guide-rot sentinel was named a backlog candidate but never filed** in
`docs/backlog.md` — a small breach of the Backlog rule this branch itself added to
agents.md.

**N4 (info): release-notes obligation** — the §8.1–8.5 fixes are user-visible and must be
captured at the next `deploy bump` (see CHANGELOG paragraph above). Nothing to do
on-branch.

---

## D. Merge verdict

**Approved-for-QA.** The program is complete: all sixteen constraints (K1–K16) verified
holding at HEAD in this pass or in the task reviews this pass re-spot-checked; the
acceptance criterion is proven twice (Task 0 fake-source spike, Task 9 #56 dry-run:
26 shared files → 8 shared Swift, wiring tax 14 → 0, every surviving edit enumerated);
the guide is accurate against `760382ed` and survived two review rounds; the test
sentinels form a genuine checklist (registry order → catalog → keys → transcript host →
analytics → preferences → sidebar). Zero must-fix items. The owner's batched smoke-run
list stands: column toggle, onboarding "N sessions found", Antigravity stale/unreadable
affordances, eager 12-runtime launch cost (Task 6), the enablement notice flashing for
every source (Task 8), plus explicit sign-off on the two pending widenings
(`analyticsIsStale` correction; upgrade-path enablement convergence). Follow-ups 1–6
above are all post-QA work; none blocks release.

### Program quality (one paragraph)

This is an unusually disciplined refactoring program. The SPEC's constraint ledger
(K1–K16) was treated as law and it shows: keys, orders, colors and semantics are pinned
by golden tests rather than asserted in prose; identity-preservation was proven
arm-by-arm where automated coverage was impractical (archive); the two proofs of the
acceptance criterion (spike before, dry-run rebase after) bracket the work honestly; and
when reality diverged from the SPEC — the six unenumerated §6 sites, the second hand
list — the program amended the SPEC in place with dated blocks instead of papering over
it. The ledger's deferred-minors hygiene is exemplary: six of the ~30 minors were
silently *resolved* by later tasks rather than accumulating, and the ones that remain
are genuinely minor. The one systemic residue — the three `@AppStorage` islands that
property-wrapper mechanics force to stay hand-written — is correctly documented as
irreducible rather than half-fixed. Cumulative drift across the ten tasks is essentially
zero; the seams between Tasks 4/7/8 (enablement), 6/7 (handles), and 5/7/8 (the single
`activeSources` policy) compose cleanly, and the guide a future contributor will
actually follow is the most accurate document in the set.
