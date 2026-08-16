# Session Source Registry & Provider Catalog — Specification

Date: 2026-08-14 (rev 2 — post-review)
Status: ready for planning
Review: rev 1 was rejected (no-go) with six findings, all verified against source at
`2099ab89`. This revision incorporates them: the object-graph refactor (provider catalog)
is now in scope, the logic-test target boundary is resolved by NOT touching
`SessionSource.swift`, `ProviderHandle` is respecified against the real private types
without self-capture, detection closures take an injected `AvailabilityContext`, the
search-gating helper moves to `UnifiedSessionIndexer`, and the test contracts are
strengthened (full order, full key table, emission-driven launch-state proof).
Supersedes: `2026-08-13-session-source-registry-PLAN.md` (historical record).
Companion: `2026-08-13-session-source-registry-DRAFT.swift.txt` (descriptor prototype —
still the seed for value data, minus the identity fields per §3.1).
Evidence base: five parallel exploration passes over `main` (2026-08-14) + the rev-1
review's verified findings.

---

## 1. Problem, measured on today's main

Adding a session source costs ~1,000 lines of legitimate source-specific code (parser,
discovery, indexer, settings, CLI environment, resume stack). It **also** costs edits to
a per-source integration surface that is pure tax, in two layers:

**Layer A — value/membership drift** (the switch/list census):

| Metric (measured 2026-08-14) | Value |
|---|---|
| Shared files containing hand-maintained per-source code | **44** |
| Distinct `switch` sites over `SessionSource` in shared code | **~65** |
| Non-switch hand lists (array/Set literals, `&&`/`\|\|` chains, parallel params, Combine pyramids, duplicated `@AppStorage` blocks) | **~35** |
| Doc comments narrating past drift incidents | **5** |

**Layer B — runtime object-graph wiring** (rev-1 review finding; the reason a registry
alone cannot deliver one-adapter onboarding):

- `AgentSessionsApp.swift:174-189` — 12 `@StateObject` indexers; 12-arg fan-out at
  L277-290 and L298-311.
- `UnifiedSessionsView.swift:330+` — 12 indexer properties; L516+ — a 12-entry
  `SearchSessionStore` adapter dictionary built inline (per-source `transcriptCache`,
  `update`, `parseFull(url:forcedID:)` closures capturing indexer instances).
- `AnalyticsService.swift:15-45` — 12 private indexer lets + 12-param init; L760-777
  readiness Combine pyramid; L779-821 hand 12-tuple array.
- `FirstRunSetupView.swift:12-23` — 12 indexer constructor properties.
- `UnifiedSessionIndexer.swift` — 12 params, 12 lets, ~20 hand-list sites.

The compiler-enforced switches stay correct; every observed failure was a `Set`, an array
literal, an `&&` chain, or a parallel parameter list. Local fixes already exist
(AnalyticsView, AnalyticsSourceSupport, TranscriptPlainView, TranscriptHostView) — this
program generalizes them AND migrates Layer B, without which the goal is unattainable.

### Live drift bugs found during exploration (current main)

Fixed *by* the refactor (derivation makes the omission impossible) or alongside it —
enumerated as deliberate behavior changes in §8:

1. `UnifiedSessionIndexer` `launchPhase` Combine chain subscribes **10 of 12** sources —
   `kimi.$launchPhase`/`grok.$launchPhase` never subscribed (`:1242-1252`).
2. `LaunchState.idle` seeds **8 of 12** sources (`:2996-3001`).
3. `openClawAgentEnabled` initializes from raw UserDefaults (default `false`) instead of
   `AgentEnablement.isEnabled(.openclaw)` (`:673`).
4. `UnifiedSessionsView` `.onChange(of: <x>AgentEnabled)` wired for **7 of 12** (`:736-748`).
5. `UnifiedSearchFiltersView`'s two `search.start` call sites gate only pi/kimi/grok on
   enablement; `restartSearch` gates all 12 (`:4401-4429, 4436-4466` vs `:3499-3528`).
6. `triggerRefresh` silently drops `mode`/`trigger`/`executionProfile` for OpenCode (`:2470-2488`).
7. Droid's Preferences pane is implemented but unreachable (`PreferencesView.swift:294-331, 1181`).
   **Preserve-and-flag** — owner decision.
8. `effectiveWorkingDirectoryURL(for:)` covers 8 sources; kimi/grok fall to generic
   `session.cwd` (`UnifiedSessionsView.swift:3179-3204`). Preserve-and-flag.

### Out-of-scope defects (recorded, separate tasks)

- `CodexSessionImagesGalleryView` — legacy Codex/Claude-only image window, still reachable.
- `CodexActiveSessionsModel` — antigravity in 3 of 6 live-session switches.
- `AgentCockpitHUDView.HUDAgentType` — no antigravity case.

---

## 2. Goal, acceptance criterion, non-goals

**Goal.** One **source-local adapter** per agent supplies both value data and runtime
capabilities; the app wires providers through one lifecycle-owning catalog.

**Acceptance criterion (rewritten per review).** A new source consists of:
1. its source folder (parser/discovery/indexer/settings/resume + descriptor + adapter),
2. its `SessionSource` case **including that file's four metadata switch arms**,
3. one `SessionSourceRegistry.ordered` entry,
4. one pbxproj update,
5. the **explicitly enumerated semantic switch arms** (§6 list, reproduced in the
   new-source guide) that the compiler demands,
6. **zero unenumerated shared edits** — proven twice: by the Task-0 fake-source spike
   and by a dry-run rebase of PR #56.

**Non-goals / what does NOT change:**

- Per-source parsers, discoveries, indexers, settings, CLI environments, resume builders.
- `SessionSource` remains a `String`-raw enum; rawValue is durable on disk in four places
  (UserDefaults values, the search index `source TEXT` columns ×5 tables, archive folder
  names, `SessionArchiveInfo` Codable). No struct conversion, no rawValue changes.
- **`SessionSource.swift` is not modified by this program** (except a new source adding
  its case + metadata arms). Its four metadata switches (`displayName`, `iconName`,
  `versionIntroduced`, `featureDescription`) stay: they are compiler-exhaustive, live in
  the enum's own file, and the file is compiled directly into the standalone
  `AgentSessionsLogicTests` target (pbxproj `3B12369C…`), which must not grow app-target
  dependencies (registry/AppKit/parsers). This resolves the rev-1 target-boundary finding.
- Semantic per-format switches stay exhaustive switches (§6).
- UserDefaults key strings never change (K1).
- No visual changes except the enumerated fixes in §8.

---

## 3. Architecture

Three pieces: **descriptor** (value data), **adapter** (descriptor + runtime factory,
source-local), **catalog** (app-level lifecycle owner).

### 3.1 `SessionSourceDescriptor` — value data only

One file per source, living in that source's folder. Struct of verbatim-transcribed
values and pure closures. **Identity metadata (displayName/iconName/versionIntroduced/
featureDescription) is NOT in the descriptor** — it stays on `SessionSource` (§2);
descriptor consumers use `source.displayName` where needed.

Fields (all transcription rules and irregularities per §5):

- **Labels/badge**: `shortLabel` (row/legend, e.g. "Kimi Code"), `badgeInitials`.
- **Palette**: `brandHue: BrandHue` (`.calibrated(r,g,b)` → `adaptiveBrand`-wrapped, 10
  sources; `.system(NSColor)` passthrough — antigravity/opencode only, K6),
  `monochromeWhite: Double`, `onboardingAccent: (OnboardingPalette) -> Color`.
- **Keys** (named constants only, K1/K2): `enablementKey`, `cliAvailableKey: String?`
  (nil: openclaw, K4), `rootOverrideKeys: [String]` (droid: two, K3), `includeKey`.
- **Detection** (K5): `binaryNames: [String]`,
  `isBinaryInstalled: (AvailabilityContext) -> Bool`,
  `isAvailable: (AvailabilityContext) -> Bool`, where

```swift
struct AvailabilityContext {
    let defaults: UserDefaults
    let fileProbe: FileProbing        // the e6fc8212 seam — hermetic tests
    let homeDirectory: URL            // grok's ~/.grok gate, injected
    let detectBinary: (String) -> Bool
}
```

  Production builds the context from the live seams; tests inject `FakeFileProbe`
  (already in the test target). Grok's `~/.grok` requirement, cursor's chats root,
  opencode's SQLite probe, droid's projects-root fallback each live in their own
  source's closure, expressed through the context — no direct `FileManager.default`.
- **Enablement**: `defaultEnabled: EnablementDefault` (`.always` vs `.whenAvailable`;
  droid's runtime/seed disagreement preserved, K7).
- **Search ingest**: `parseFullByPath: ((URL) -> Session?)?` — nil = DB-backed source
  declines path-identified parsing (Devin, §4).
- **Archive**: `archive: ArchiveCapability?` (`backfillURLs: (UserDefaults) -> [String: URL]`,
  `sessionForBackfill: (String, URL) -> Session?`) — nil = unsupported (Devin).
- **Resume gating**: `supportsResume: Bool` (false: droid/openclaw), `resumeAgentLabel: String?`.
- **Toolbar pill**: `otherAgentPill: PillSpec?` (`color: Color`, `shortcut: String?`;
  nil for codex/claude; shortcuts are frozen history, K10).

### 3.2 `SessionSourceAdapter` — descriptor + runtime factory (source-local)

```swift
struct SessionSourceAdapter {
    let descriptor: SessionSourceDescriptor
    /// Constructs this source's runtime once, at app startup, on the main actor.
    let makeRuntime: @MainActor () -> SourceRuntime
}

@MainActor
struct SourceRuntime {
    let source: SessionSource
    /// The retained concrete indexer (each self-injects its discovery from @AppStorage,
    /// exactly as today's 12 @StateObject initializers do).
    /// Spike amendment (c11): typed as `any SessionIndexerProtocol & ObservableObject` —
    /// UnifiedTranscriptView is generic over SessionIndexerProtocol (incl. settable
    /// `activeSearchUI`), so the conformance is a hard requirement for every source;
    /// requiring it here surfaces the failure at makeRuntime, not in the transcript layer.
    let indexerObject: any SessionIndexerProtocol & ObservableObject
    /// Type-erased pipeline surface for UnifiedSessionIndexer (§3.4).
    let handle: UnifiedSessionIndexer.ProviderHandle
    /// The SearchSessionStore adapter currently built inline at UnifiedSessionsView:516+
    /// (transcriptCache / update / parseFull(url:forcedID:)) — moves here, closures
    /// capture the concrete indexer, never a view or the unified indexer.
    let searchAdapter: SearchSessionStore.Adapter
}
```

`GrokSourceAdapter.swift` lives next to `GrokSessionIndexer.swift`; adding a source means
writing one of these, not editing five wiring sites.

### 3.3 `SessionSourceRegistry` + `SessionProviderCatalog`

```swift
enum SessionSourceRegistry {
    /// THE one remaining hand-maintained list. Order == SessionSource.allCases order.
    static let ordered: [SessionSourceAdapter]
    static let bySource: [SessionSource: SessionSourceAdapter]
    static func adapter(for source: SessionSource) -> SessionSourceAdapter   // precondition on gap
    static func descriptor(for source: SessionSource) -> SessionSourceDescriptor
}

@MainActor
final class SessionProviderCatalog: ObservableObject {
    /// Built once from the registry. Owns every SourceRuntime for the app's lifetime.
    /// Deliberately publishes NOTHING that changes after init — indexers remain
    /// independently-observed ObservableObjects, so view invalidation granularity is
    /// unchanged (AgentSessionsApp already avoids observing all 12 for exactly this
    /// reason, L219-227).
    let runtimes: [SessionSource: SourceRuntime]
    subscript(source: SessionSource) -> SourceRuntime
}
```

`AgentSessionsApp` holds one `@StateObject catalog` instead of twelve; `UnifiedSessionsView`,
`FirstRunSetupView`, `AnalyticsService`, and `UnifiedSessionIndexer` take the catalog (or
its runtimes) instead of 12 positional parameters. Where a consumer genuinely needs a
concrete indexer type (TranscriptHostView's per-source transcript views, the reload
switch), it downcasts `catalog[.codex].indexerObject` in one compiler-checked switch —
those sites are on the §6 enumerated list and guarded by `testTranscriptHostCoversEverySource`.

Bijection + order are test-enforced: `ordered.map(\.descriptor.source) == SessionSource.allCases`.

### 3.4 `ProviderHandle` — nested, no self-capture

Declared **inside `UnifiedSessionIndexer`** (the rev-1 separate-file shape cannot see the
private nested `FocusedSessionContext` / `FocusedReloadTrigger` — real names verified at
`UnifiedSessionIndexer.swift:89,95`):

```swift
// inside UnifiedSessionIndexer
struct ProviderHandle {
    let allSessions: AnyPublisher<[Session], Never>
    let isIndexing: AnyPublisher<Bool, Never>
    let isProcessingTranscripts: AnyPublisher<Bool, Never>
    let filesProcessed: AnyPublisher<Int, Never>
    let totalFiles: AnyPublisher<Int, Never>
    let indexingError: AnyPublisher<String?, Never>
    let launchPhase: AnyPublisher<LaunchPhase, Never>
    let currentSessions: @MainActor () -> [Session]
    let currentIsIndexing: @MainActor () -> Bool
    let currentLaunchPhase: @MainActor () -> LaunchPhase
    let refresh: @MainActor (IndexRefreshMode, IndexRefreshTrigger, IndexRefreshExecutionProfile) -> Void
    /// Maps the trigger to this indexer's own nominal ReloadReason enum internally.
    /// NO enablement guard here — callers guard (rev-1 finding: guards read self).
    let reloadFocusedSession: @MainActor (_ sessionID: String, _ force: Bool, _ trigger: FocusedReloadTrigger) -> Void
}
```

**Retain-cycle rule (rev-1 P1):** handles are built by each source's adapter (or, during
migration, in `UnifiedSessionIndexer.init` from the initializer *arguments* as locals).
Closures capture the concrete indexer instance ONLY — never `self`, never the catalog —
so `deinit` (`:2979`) keeps running. Enablement checks move to the call sites, which
already read `self`'s published state legally.

**Visibility amendment (spike):** because `SourceRuntime` lives outside
`UnifiedSessionIndexer.swift` and names `FocusedReloadTrigger` in the
`reloadFocusedSession` signature, that enum widens from `private` to internal — budgeted
in Task 7, with a check that nothing depended on the privateness. `FocusedSessionContext`
stays private (the handle takes a bare `sessionID: String`). The spike also validated a
typed downcast helper on the catalog (`indexer(_:as:) -> T?`) for the concrete-type call
sites — adopted in Task 6.

Combine pyramids collapse via `Publishers.combineLatestArray([AnyPublisher<T, Never>])`
(sequence-fold helper). All 12-source pyramids in `UnifiedSessionIndexer` AND
`AnalyticsService.setupObservers` (`:760-777`) become registry-ordered array folds —
structurally fixing §1 bugs 1–2.

**Testability win:** an internal init accepting `[SessionSource: ProviderHandle]` lets
tests construct a live `UnifiedSessionIndexer` with fake handles for the first time —
required for the emission-driven launch-state test (§10).

### 3.5 Search gating policy

`allowedSearchSources()` lives on **`UnifiedSessionIndexer`** (rev-1 P2: two of the three
call sites are in the separate private `UnifiedSearchFiltersView` type and cannot call a
`UnifiedSessionsView` private helper):

```swift
@MainActor func allowedSearchSources() -> Set<SessionSource> {
    Set(SessionSource.allCases.filter { isAgentEnabled($0) && isIncluded($0) })
}
```

All three `SearchCoordinator.start` call sites use it (deliberate behavior change §8.5).

---

## 4. The two capabilities Devin (PR #56) proves are needed

Measured fresh 2026-08-14: #56 open, `CONFLICTING`/`DIRTY`, 31 commits behind (arms
insert after `.kimi`), **26 shared-file edits + 14 new files**, zero reviews.

1. **Path-identified parsing must be declinable** — every Devin session shares one DB
   path; #56's arm is `case .devin: return nil`. → `parseFullByPath: nil`.
2. **Archiving must be declinable** — #56's arms: `break` (URL discovery) and
   `DevinSqliteReader.loadFullSession(databasePath:sessionID:)`. → `archive: nil`.

The forced-ID channel already exists for four file-based sources
(`parseFile(at:forcedID:)` on Copilot/Antigravity/Droid/OpenClaw) and in the
`SearchSessionStore.Adapter.parseFull(url:forcedID:)` shape — `SourceRuntime` carries it.

---

## 5. Constraints ledger (verified against current main)

**K1 — UserDefaults keys frozen.** Never derived from `rawValue`. Descriptors carry
literal-valued named constants; a test pins **every key of every kind for all 12 sources**
to its historical string (full table, not spot checks — rev-1 P2).

**K2 — Bare-literal keys.** `AgentEnablement.isAvailable` reads bare literals for FOUR
sources (codex `"SessionsRootOverride"`, claude, antigravity, opencode — claude/opencode
*have* constants it bypasses). `SessionArchiveManager` repeats three;
`PreferencesView.swift:200,211` and `CodexStatusService` repeat two. Only codex and
antigravity lack constants entirely. Constants first, then descriptors reference them.
**Key-location decision (spike c9):** the existing 12 sources' constants stay in
`PreferencesConstants.swift` (frozen history, Task 1). A NEW source's keys live as
literals in its own descriptor file ONLY — it adds nothing to `PreferencesConstants` —
so keys are source-local and the §2 acceptance list stays honest. The key-stability
test covers both homes.

**K3 — Droid: two root keys** (+ projects-root fallback probe).
**K4 — OpenClaw: no CLI-available key**; unrelated `openClawBinaryOverride` (launch path).
**K5 — Detection needs injected filesystem access.** All probes go through
`AvailabilityContext` (defaults + `FileProbing` + home dir + binary detect). No
`FileManager.default` in descriptor closures (rev-1 P1).
**K6 — Brand color two forms** (`.calibrated` wrapped / `.system` passthrough).
**K7 — Droid enablement disagreement preserved** (runtime `.always`, seed from availability).
**K8 — `seedIfNeeded` fallback pins `.codex`** literally.
**K9 — `SearchCoordinator.start` signature** load-bearing for 4 positional test call
sites + 3 production call sites; becomes `allowed: Set<SessionSource>`; the Kimi-drift
regression test is rewritten against the Set.
**K10 — ⌘-shortcuts not derivable** (⌘3–⌘9 exhausted; hermes/kimi/grok nil). Transcribed.
**K11 — Test-pinned static shapes** (`SessionAggregationWork`, `AgentEnablementSnapshot`,
etc.) go dictionary-keyed **with their tests updated in the same task**.
**K12 — TranscriptHostView stays hand-built** (concrete view types; opacity-selection is
a perf choice); guarded by `coveredSources` + its test; on the §6 enumerated list.
**K13 — `PreferencesTab` naming irregular + persisted**; tab cases stay; sidebar lists
derive; droid stays hidden (§8.7).
**K14 — 9+3 split helpers** (`firstEnabledIndexingError`, `coreProviderSnapshots`)
collapse to array-driven forms.
**K15 — Logic-test target boundary** (rev-1 P1): `SessionSource.swift`, `Session.swift`,
`FilterEngine.swift`, parsers etc. compile standalone into `AgentSessionsLogicTests`.
Nothing this program adds may be imported by those files. Registry/adapter/catalog types
are app-target only; before flipping ANY shared file to registry reads, check its target
membership in the pbxproj.
**K16 — Catalog must not republish indexer churn** (§3.3): views keep observing concrete
indexers; the catalog publishes nothing post-init. Invalidation behavior is otherwise at
risk across the whole UI.

---

## 6. What stays an exhaustive switch (the enumerated semantic list)

**Rewritten after the Task-0 spike** (`2026-08-14-task0-spike-REPORT.md`), which compiled
a fake 13th source and recorded every forced edit. The original list was wrong in both
directions: it missed eleven forced sites and named three that are actually silent
`default:` holes. This list is spike-verified and is the acceptance criterion's item 5.

### 6.A Compiler-forced (the "the compiler will ask you" list)

1. `SessionSource.swift` — the case + its four metadata arms (K15).
2. `passesHasCommandsFilter` grouping (the `FirstRunSetupView.isVisibleSession` copy is
   deduplicated into a call; the survivor stays).
3. Image-scanning switches: 3 in `CodexSessionImagePayload`, the outer switch in
   `ImageBrowserIndexCache` (:264), and the inline-image gate in
   `TranscriptPlainView.swift:1101` (spike c10).
4. `Session.storesAuthoritativeLightweightCwd` / `storesAuthoritativeLightweightTitle`.
5. `copyResumeCommand` / `canCopyResumeCommand` dispatchers (gating collapses to
   `supportsResume`).
6. `TranscriptHostView` layer + its stored indexer property (K12), plus the
   concrete-indexer downcast switch(es) at catalog consumers (§3.3).
7. `PreferencesTab` case and its dependent switches (spike c5–c8): `title`, `iconName`,
   the `tabBody` routing switch, and the probe trio
   (`scheduleProbe`/`resolvedBinaryPath`/`customBinaryPath` + probe-on-appear) — Task 8
   reduces `title`/`iconName` to registry lookups via a new `PreferencesTab(source:)`
   mapping (which does NOT exist today; it is created by Task 8, K13), leaving the tab
   case, the mapping arm, `tabBody`, and the probe switches as the enumerated edits.
8. `AnalyticsAgentFilter` case + its `matches(_:)` arm (spike c1/c2 — the new-case need
   is caught by the pairing tests, the arm then by the compiler). Its third dependent,
   `AnalyticsService.sourcesFor(_:)` (c3), is derived from `matches` by Task 8 and
   drops off this list.
9. `AgentUpdateService.profile(for:)` (spike c4) — per-source update-feed semantics.
10. **Conformance contract (spike c11):** the source's indexer must conform to
    `SessionIndexerProtocol` (including settable `activeSearchUI`) because
    `UnifiedTranscriptView` is generic over it. Declared statically on `SourceRuntime`
    (§3.2) so the failure surfaces at `makeRuntime`, not deep in the transcript layer.

### 6.B Test-forced (sentinels that fire instead of the compiler)

- `TranscriptHostView.coveredSources` — `testTranscriptHostCoversEverySource`.
- `AnalyticsAgentFilter` new case — the analytics pairing tests.
- `versionIntroduced` must be the upcoming real app version — What's New derives provider
  highlights from it, and `testProviderHighlights_returnsEmptyForUnknownVersion` pins
  `"99.0"` as unclaimed (guide note).

### 6.C Silent holes → made exhaustive by this program

The spike found ~22 sites that compile and pass tests while leaving a new source wrong or
invisible. Most are eliminated by Tasks 3–8 (registry/catalog derivation). Four encode
real per-source semantics and stay switches — but today they end in `default:`, so Task 8
converts them to exhaustive switches (the codebase's own established fix, cf.
`TranscriptPlainView`): `resume(_:)` (a new source currently gets a dead Resume button
silently), `Session.computeIsHousekeeping` (silently inherits codex-ish semantics), and
the two inner `ImageBrowserIndexCache` switches (:126, :149 — silently scans nothing).
After Task 8 they move to list 6.A.

### 6.D Deliberately out of scope

Live-session subsystem opt-in (`CodexActiveSessionsModel`, HUD) — default: none; stays
`default:`-based by design (4-source subsystem).

Everything else per-source in shared code is registry/catalog-derived when this program
completes. Per the spike's scale summary, the fake source cost 27 shared files / 139
hunks on today's main; after Tasks 1–8 the §2 acceptance list is the whole cost.

---

## 7. Increments

0. **Architecture spike (throwaway, owner-approved worktree).** Build a minimal
   `SessionSourceAdapter`/`SourceRuntime`/`SessionProviderCatalog` skeleton + ONE
   migrated consumer path + a deliberately minimal fake 13th source (fake `SessionSource`
   case included — spike only, never merged). Deliverable: a findings report — the
   verified complete list of shared edits a 13th source still needs, catalog `@StateObject`
   invalidation check (K16), and go/adjust on §3 shapes. The spike is deleted; only the
   report lands.
1. **Keys.** Constants for every bare literal (K2) + `PreferencesKey.Include`; full-table
   key-stability test.
2. **Registry scaffolding.** Descriptor (no identity fields) + `AvailabilityContext` +
   registry + 12 descriptor files; bijection/order/key/parity tests.
3. **Palette + labels.** `TranscriptColorSystem`, `AnalyticsColors`, badges,
   `OnboardingPalette`, four short-label switches → registry. (`SessionSource.swift`
   untouched — K15.)
4. **Detection + enablement.** `AgentEnablement`'s five switches → registry via
   `AvailabilityContext`; K7/K8 preserved.
5. **Search + archive.** `parseFileFull` → descriptor; `start(allowed:)` (K9);
   `allowedSearchSources()` on `UnifiedSessionIndexer` (§3.5); archive switches →
   capability closures.
6. **Catalog.** `combineLatestArray` lands FIRST (spike finding 1: the tuple pyramids are
   coupled — one shared `agentEnabledFlags` feeds five consumers, so a 13th source there
   costs super-linearly; consumers must be written against the array fold once, not
   rewritten twice). Then `SessionSourceAdapter.makeRuntime` for all 12;
   `SessionProviderCatalog` (+ typed downcast helper); `AgentSessionsApp` 12
   `@StateObject`s → 1; `UnifiedSessionsView` / `FirstRunSetupView` / `AnalyticsService`
   (incl. its `#Preview` call site) / `UnifiedSessionIndexer` inits take the catalog;
   `SearchSessionStore` adapter dictionary comes from runtimes. `AnalyticsService`
   readiness uses `combineLatestArray` (not `MergeMany`) from the start.
7. **Pipelines.** `ProviderHandle` wiring inside `UnifiedSessionIndexer` (no
   self-capture; `FocusedReloadTrigger` widens to internal, §3.4); pyramids →
   `combineLatestArray`; aggregation structs dictionary-keyed (K11 — the spike showed
   named struct fields are optional-and-silent to ADD, which is why dictionaries are
   right); K14 collapse; §8.1–8.3 fixes + emission test.
8. **Views.** Notice predicate, single enablement observer (§8.4), pill derivation,
   preferences/sidebar/first-run lists (+ new `PreferencesTab(source:)` mapping deriving
   `title`/`iconName`), resume gates; derive `AnalyticsService.sourcesFor` from
   `AnalyticsAgentFilter.matches`; convert the four §6.C silent `default:` switches to
   exhaustive.
9. **Proof.** `docs/adding-a-session-source.md` (acceptance list §2); #56 dry-run rebase
   with before/after shared-file counts; backlog + old-plan reconciliation.

## 8. Deliberate behavior changes (complete list)

1. Kimi/Grok launch-phase transitions update launch state (was: missed).
2. `LaunchState.idle` covers all 12 sources.
3. OpenClaw enablement reads `AgentEnablement.isEnabled`.
4. Toggling hermes/droid/openClaw/cursor/pi flashes the enablement notice like the rest.
5. Filter-view searches respect enablement for all 12 sources.
6. *(Preserved)* OpenCode refresh still drops mode/trigger/profile — flagged follow-up.
7. *(Preserved)* Droid Preferences tab stays hidden — owner decision requested.
8. *(Preserved)* kimi/grok working-directory fallback — owner decision requested.

Everything else is bit-for-bit, enforced by the §10 test set.

## 9. Definition of done

- Increments 0–9 complete; `./scripts/xcode_test_stable.sh` green throughout.
- Acceptance criterion (§2) proven twice: fake-source spike report + #56 dry-run rebase
  showing only enumerated edits.
- Zero remaining hand lists in the census except: the registry, §6 semantic switches,
  and the out-of-scope subsystems.
- `docs/adding-a-session-source.md` accurate; backlog entry updated.

## 10. Test contracts (strengthened per rev-1 P2)

1. **Bijection AND order**: `SessionSourceRegistry.ordered.map(\.descriptor.source) ==
   SessionSource.allCases` (exact array equality, not set membership).
2. **Full key table**: all 12 sources × {enablement, cliAvailable, rootOverride(s),
   include} pinned to literal historical strings — 48 assertions, no sampling.
3. **Palette parity**: registry-resolved brand accent equals
   `TranscriptColorSystem.agentBrandAccent` for all 12 before the flip; golden literals after.
4. **Emission-driven launch state**: construct `UnifiedSessionIndexer` with injected fake
   handles (§3.4); send a `launchPhase` change through the KIMI handle only; assert the
   published launch state updates. This proves §8.1, not just `LaunchState.idle` coverage.
5. **Enablement semantics** (K7): `defaultEnabled` table pinned for all 12.
6. **Search allow-list**: rewritten Kimi regression + `allowedSearchSources` unit test
   (enabled ∧ included, all 12).
7. **Catalog completeness**: `catalog.runtimes.keys == Set(SessionSource.allCases)`;
   every runtime's `searchAdapter` and `handle` non-crashing on construction.
8. **Existing sentinels stay green**: `testTranscriptHostCoversEverySource`,
   `NewProviderDiscoverabilityTests`, `AgentBinaryDetectionTests` (hermetic via
   `AvailabilityContext`), analytics pairing tests, aggregation-struct tests (updated K11).
