# Task 0 — Architecture spike report

Date: 2026-08-15
Worktree: `/Users/alexm/Repository/Codex-History-spike`, branch `spike/source-catalog`,
base `2099ab89`. Three commits, never pushed. Worktree is disposable after review.

**Status: DONE_WITH_CONCERNS.**

The SPEC §3 shapes survive intact — descriptor / adapter / `SourceRuntime` /
`SessionProviderCatalog` / `ProviderHandle` all compile and carry real traffic, and the
K16 no-republish property holds and is now test-enforced. Two structural adjustments are
required (§3.4 visibility, and a `SessionIndexerProtocol` conformance obligation), and
**SPEC §6's enumerated list is materially wrong in both directions** — it names three
things the compiler does *not* demand and misses nine that it (or the test suite) does.
That is the concern: the acceptance criterion in §2 item 5 is currently unachievable
because the list it points at is inaccurate.

Evidence: `xcodebuild … build` green; `./scripts/xcode_test_stable.sh` green
(**\*\* TEST SUCCEEDED \*\***) with the fake 13th source `zzfake` present in
`SessionSource` and both test targets — including the standalone `AgentSessionsLogicTests`
target, so **K15 held**: nothing added by the spike leaked into a logic-test-compiled file.

---

## 1. What was built

| Piece | File (spike worktree) | Notes |
|---|---|---|
| Descriptor (subset of §3.1) | `AgentSessions/SourceCatalog/SessionSourceAdapterSpike.swift` | `SpikeSourceDescriptor` — labels, badge, 4 key kinds, `defaultsOnOnlyWhenAvailable` |
| `SessionSourceAdapter` (§3.2) | same file | `descriptor` + `makeRuntime: @MainActor () -> SourceRuntime` — verbatim from SPEC |
| `SourceRuntime` (§3.2) | same file | `source`, `indexerObject: any ObservableObject`, `handle`, `searchAdapter` — verbatim |
| `SpikeSourceRegistry` (§3.3) | same file | 3 entries: codex, grok, zzfake |
| `SessionProviderCatalog` (§3.3) | same file | `let runtimes`, no `@Published`, subscript + typed `indexer(_:as:)` downcast |
| `ProviderHandle` (§3.4) | `AgentSessions/Services/UnifiedSessionIndexer.swift:104` | nested in the indexer, 7 publishers + 3 current-value getters + refresh + reloadFocusedSession |
| Handle factories | `AgentSessions/SourceCatalog/ProviderHandleFactories.swift` | one per source; capture only the concrete indexer |
| Fake 13th source | `AgentSessions/Model/FakeSourceSpike/ZZFake{Parser,Discovery,Indexer}.swift` | no-op parser/discovery; indexer with the de-facto published surface |
| K16 + registry tests | `AgentSessionsTests/SpikeCatalogInvalidationTests.swift` | 4 tests, all passing |

**Migration choice for `AnalyticsService` (recorded per the brief):** hybrid — the catalog
*owns* the codex, grok and zzfake indexer instances (their three `@StateObject`s in
`AgentSessionsApp` were replaced by one `@StateObject catalog` plus computed accessors),
and `AnalyticsService` takes `catalog:` as its first parameter while the other nine
indexers stay positional. Rejected alternative: a catalog that *wraps* indexers the app
still owns — that keeps two ownership stories alive and would not have exercised the
`@StateObject` → K16 question at all.

Net effect inside `AnalyticsService`: the two 12-line `if AgentEnablement.isEnabled(...)
{ append }` blocks collapsed to a 3-line registry-ordered `for` loop; the 12-publisher
`CombineLatest3(CombineLatest4 × 3)` pyramid became `MergeMany(handles.map(\.launchPhase))`
merged with the 9-source legacy remnant; the hand 12-tuple in `updateReadiness` became
`catalogRuntimes.map { ($0.source, $0.handle.currentLaunchPhase()) } + [legacy…]`.
**All three collapse cleanly and none of them needed a `zzfake` line.**

---

## 2. The forced-edit table

Every shared-code edit the fake source required, with why and how it classifies:

- **(a)** expected — already on SPEC §6's enumerated list
- **(b)** will be eliminated by a planned task (task named)
- **(c)** UNEXPECTED — neither enumerated nor scheduled

"Forced by" distinguishes **compiler** (switch exhaustiveness / missing memberwise-init
argument / protocol conformance / missing call argument) from **test** (suite fails) from
**silent** (compiles and runs, but the source is invisible or mis-handled — the drift
class §1 of the SPEC is about). *Silent* edits are the ones a new-source guide must call
out loudest, because nothing catches them.

Line numbers are post-edit, in the spike worktree.

### 2.1 Enumerated (a) — SPEC §6 was right

| File:line | Site | Forced by | Class |
|---|---|---|---|
| `Model/SessionSource.swift:17` | enum case | compiler | (a) §6.1 |
| `Model/SessionSource.swift:34,52,69,87` | `displayName` / `iconName` / `versionIntroduced` / `featureDescription` | compiler | (a) §6.1 |
| `Model/Session.swift:768` | `storesAuthoritativeLightweightCwd` | compiler | (a) §6.4 |
| `Model/Session.swift:793` | `storesAuthoritativeLightweightTitle` | compiler | (a) §6.4 |
| `Utilities/CodexSessionImagePayload.swift:255,314,331` | 3 image scan switches | compiler | (a) §6.3 |
| `Services/UnifiedSessionIndexer.swift:2869` | `passesHasCommandsFilter` (survivor) | compiler | (a) §6.2 |
| `Views/UnifiedSessionsView.swift:1688` | `copyResumeCommand` dispatcher | compiler | (a) §6.5 |
| `Views/UnifiedSessionsView.swift:4120` | `TranscriptHostView` layer | compiler¹ | (a) §6.6 |
| `Views/UnifiedSessionsView.swift:4142` | `coveredSources` | test² | (a) §6.6/K12 |
| `Views/PreferencesView.swift:1129` | `PreferencesTab` case | compiler³ | (a) §6.7 |

¹ Only because the layer needs `zzfakeIndexer`, a new stored property. The `ZStack` itself
is opacity-selected — omitting the layer is *silent*, exactly as the code comment warns.
² `testTranscriptHostCoversEverySource` — the sentinel works; it fired as designed.
³ Adding the case forces §2.3's four `PreferencesTab` switches below.

### 2.2 Scheduled for elimination (b)

Grouped by the task that removes them.

**Task 3 (palette + labels)** — all (b):
`Services/TranscriptColorSystem.swift:109` (compiler);
`Analytics/Utilities/AnalyticsColors.swift:33,51` (silent `static let`s), `:69,:89` (compiler);
`Onboarding/Components/OnboardingComponents.swift:116` badge initials (compiler);
`Onboarding/Components/OnboardingPalette.swift:283` `agentAccent` (compiler);
`Views/SessionTerminalView.swift:311` short label (compiler);
`Views/UnifiedSessionsView.swift:1760, 2981` two more short-label switches (compiler),
`:3577` `sourceAccent` (compiler).

**Task 4 (detection + enablement)** — all (b):
`Services/AgentEnablement.swift:97` `enablementKey` (compiler), `:301` `isAvailable` root
(compiler), `:378` `binaryInstalled` (compiler), `:436` `storedBinaryPresence` (compiler),
`:67` `isEnabled` default-group arm (**silent** — the switch has a `default: return true`,
so a new source silently becomes always-on), `:204,220,234` `seedIfNeeded` (**silent**, 3 hand lists);
`Analytics/Views/AnalyticsView.swift:21` `@AppStorage` (silent), `:58` `isEnabled` (compiler).

**Task 5 (search + archive)** — all (b):
`Search/SearchIngestService.swift:388` `parseFileFull` (compiler);
`Services/SessionArchiveManager.swift:480` backfill-URL discovery (compiler), `:515`
`resolveSessionForBackfill` (compiler).

**Task 6 (catalog)** — all (b), and all of them *disappeared for codex/grok/zzfake in this
spike*, which is the proof the increment works:
`AgentSessionsApp.swift` 15 hunks (`:174,193,293,317,403,501,570,584,804,1115,1125,1349,1369,1464,1490`);
`Views/UnifiedSessionsView.swift:344,494,513` (stored prop + init param + assign), `:591`
inline `SearchSessionStore` adapter dict (**silent**), `:4073` transcript-host prop, `:1735` call arg;
`Onboarding/Views/FirstRunSetupView.swift:24,41,112,362` (prop, `@AppStorage`, `onReceive`, `sessionsFromIndexer`), `:406` `isAgentEnabled`;
`Analytics/Services/AnalyticsService.swift:15,30,38,48,59` init/properties;
`Analytics/Views/AnalyticsView.swift:413,421,431` preview constructor;
`Services/UnifiedSessionIndexer.swift:722,769,841` stored indexer + init param + assign.

**Task 7 (pipelines)** — all (b), inside `Services/UnifiedSessionIndexer.swift` unless noted:
`:82` focused-refresh-interval dict (**silent**);
`:370` `focusedMonitorCapabilityBySource` (**silent**);
`:490` `AgentEnablementSnapshot` field, `:506,524,539` `SessionAggregationWork` field +
two construction sites (compiler, K11) + `AgentSessionsTests/CodexActiveSessionsRegistryTests.swift:3781,3796,3823,3838` (compiler, K11 test update);
`:855,892,908,913,921,942,957` the aggregation Combine pyramid and its 6-level tuple
destructuring (compiler, see §4 finding 1);
`:1399,1412` enablement-sync diff (**silent**), `:1466` enabled-source array (**silent**);
`:2283` `currentSessions(for:)` (compiler), `:2331` search-ingest readiness (compiler),
`:2451` `sourceAwareFocusedSignaturePath` (compiler), `:2556` `triggerRefresh` (compiler),
`:2575` `isSourceIndexing` (compiler), `:2792` `phases[...]` launch-state seed (**silent**),
`:2842` `mergedAggregationResult` append (**silent**).

**Task 8 (views)** — all (b):
`Services/UnifiedSessionIndexer.swift:1380` `isAgentEnabled` (compiler), `:2914`
include∧enabled arm (compiler);
`Views/UnifiedSessionsView.swift:702` search-restart `onChange` (**silent**), `:2553`
include-toggle reveal (compiler), `:2615` reload-on-select (compiler);
`Onboarding/Views/FirstRunSetupView.swift:452` the `passesHasCommandsFilter` copy (compiler; §6.2 already schedules the dedup);
`Views/PreferencesView.swift:294,306,1191` three sidebar hand lists (**silent**).

### 2.3 UNEXPECTED (c) — the spike's most important findings

| # | File:line | Site | Forced by | Why it is (c) |
|---|---|---|---|---|
| c1 | `Analytics/Models/AnalyticsDateRange.swift:65` | `AnalyticsAgentFilter` new case | **test** | §6 does not list it; §7 has no task touching `AnalyticsAgentFilter` |
| c2 | `Analytics/Models/AnalyticsDateRange.swift:111` | `AnalyticsAgentFilter.matches` arm | compiler (after c1) | same |
| c3 | `Analytics/Services/AnalyticsService.swift:438` | `sourcesFor(_:)` arm | compiler (after c1) | same |
| c4 | `Services/AgentUpdateService.swift:452` | `AgentUpdateProfile.profile(for:)` | compiler | Not in §6, not in any §7 increment. A brand-new per-source switch nobody has budgeted |
| c5 | `Views/PreferencesView.swift:1156` | `PreferencesTab.title` | compiler | §6.7 says "case + `PreferencesTab(source:)` mapping"; the real cost is four more switches |
| c6 | `Views/PreferencesView.swift:1183` | `PreferencesTab.iconName` | compiler | same |
| c7 | `Views/PreferencesView.swift:435` | tab-content `switch selectedTab` | compiler | same |
| c8 | `Views/PreferencesView.swift:918, 948, 991, 1491` | `scheduleProbe(for:)`, `resolvedBinaryPath(for:)`, `customBinaryPath(for:)`, probe-on-appear | compiler | 4 further `SessionSource`/`PreferencesTab` switches, unenumerated |
| c9 | `Views/Preferences/PreferencesConstants.swift:92, 109, 170` | 3 new key constants | compiler (referenced by name) | §2's acceptance list puts everything source-local except the case, the registry entry and pbxproj — but keys live in a shared file |
| c10 | `Views/TranscriptPlainView.swift:1101` | inline-image gate | compiler | §6.3 counts 6 image switches; this is a 7th |
| c11 | *(new type obligation)* `ZZFakeSessionIndexer` must conform to `SessionIndexerProtocol` | compiler | `UnifiedTranscriptView` is generic over it; §6.6 mentions the layer but not the conformance contract |

**c11 detail.** `UnifiedTranscriptView` is `generic struct … requires that <Indexer> conform
to 'SessionIndexerProtocol'`. The protocol demands `allSessions`, `sessions`, `isIndexing`,
`isLoadingSession`, `loadingSessionID`, `launchPhase` **and a settable
`activeSearchUI: SessionIndexer.ActiveSearchUI`**. A source author who writes only the
de-facto published surface gets a hard compile error at the transcript layer. This should
be stated as a contract in the new-source guide (and ideally in the SPEC's §3.2
`SourceRuntime` shape, so `makeRuntime` can require it statically).

### 2.4 SPEC §6 items the compiler did **not** demand

Three §6 entries are listed as compiler-enforced but are not. Each is a *silent* hole a
new source falls into:

| §6 item | Reality |
|---|---|
| §6.3 "3 in `ImageBrowserIndexCache`" | Only **1** is exhaustive (`ImageBrowserIndexCache.swift:264`). The two inner switches (`:126`, `:149`) have `default:` clauses, so a 13th source silently scans nothing and silently fails the payload filter |
| §6.4 `computeIsHousekeeping` | `Session.swift:656` ends in `default:` — **not** compiler-forced. A new source silently gets Codex-ish housekeeping semantics |
| §6.5 "`resume(_:)` … dispatchers (2)" | `copyResumeCommand` and `canCopyResumeCommand` are forced; **`resume(_:)` is not** — `UnifiedSessionsView.swift:~3470` ends in `default:`, so a new source silently has no working Resume action while Copy-Resume-Command refuses to compile without one |

Also: **`PreferencesTab(source:)` (§6.7) does not exist in the codebase.** There is no
`SessionSource → PreferencesTab` initializer at `2099ab89`; the SPEC names a symbol that
was never written. Replace that item with c5–c8.

### 2.5 Scale summary

| Metric | Value |
|---|---|
| Shared files edited for the 13th source | **27** (excludes the 3 new fake-source files, the 2 catalog files and the new test file) |
| Distinct edit hunks | **139** |
| Compiler-forced sites | ~46 |
| Test-forced sites | 3 (`AnalyticsAgentFilter` ×1 root cause, `coveredSources` ×1, and a version-string artifact — see below) |
| Silent (compiles + passes tests, source is wrong/invisible) | **~22** |
| pbxproj | 40 lines (6 files × 4, plus 2 new groups) |

**One test failure was an artifact, not a finding.**
`NewProviderDiscoverabilityTests.testProviderHighlights_returnsEmptyForUnknownVersion`
hard-codes `"99.0"` as a version no provider claims. My fake source initially declared
`versionIntroduced = "99.0"` and broke it. Changing it to `"4.9"` fixed it. Real 13th
sources will not hit this — but it is worth a one-line note in the guide that
`versionIntroduced` must be the *upcoming real* app version, since What's New derives
provider highlights from it.

---

## 3. Catalog shape verdict — does SPEC §3 survive?

**Yes, with two amendments.** Nothing in §3 was falsified.

- **§3.1 descriptor** — not stress-tested end-to-end (the spike carried a subset). No
  contradiction found. Task 2 proceeds as written.
- **§3.2 `SessionSourceAdapter` / `SourceRuntime`** — verbatim as specified; compiles and
  carries the codex/grok/zzfake runtimes. **Amendment:** add a documented conformance
  requirement that the concrete indexer satisfies `SessionIndexerProtocol` (finding c11),
  so the failure surfaces at `makeRuntime` rather than deep inside `TranscriptHostView`.
- **§3.3 `SessionProviderCatalog`** — verbatim. `let runtimes`, subscript, zero published
  state. One addition that proved necessary in practice: a typed downcast helper
  (`func indexer<T: ObservableObject>(_:as:) -> T?`), because `AgentSessionsApp` needs
  concrete `SessionIndexer` / `GrokSessionIndexer` values to feed the ten legacy call
  sites. Recommend adopting it in Task 6.
- **§3.4 `ProviderHandle`** — the shape is right and the retain-cycle rule is achievable:
  every factory closure captures only the concrete indexer, so `UnifiedSessionIndexer`'s
  `deinit` is untouched. **Amendment (required):** declaring `ProviderHandle` publicly
  inside `UnifiedSessionIndexer` forces `FocusedReloadTrigger` to widen from `private` to
  internal, because `SourceRuntime` lives in another file and must name it in the
  `reloadFocusedSession` signature. `FocusedSessionContext` can stay private (the handle
  takes a bare `sessionID: String`, per the SPEC's own signature). Task 7 must budget that
  visibility change and confirm nothing else depended on the `private`ness.
- **§3.5 search gating** — not exercised by this spike.

---

## 4. Two structural findings that change effort estimates

**Finding 1 — `agentEnabledFlags` is shared by five downstream pyramids.**
In `UnifiedSessionIndexer.init`, `agentEnabledFlags` is built once and then consumed by the
session-aggregation pyramid *and* the `isIndexing`, `isProcessingTranscripts`,
`indexingError` and source-filter pyramids. Appending the 13th source's
`.combineLatest($zzfakeAgentEnabled)` to it produced **8 simultaneous type errors** in
those other four consumers, each a 400-character Combine type mismatch. The local fix in
the spike was a dedicated `agentEnabledFlagsWithZZFake` used only by the one pyramid that
needed it — which is precisely the kind of workaround that turns into the next drift bug.
This is strong, concrete support for Task 7's `combineLatestArray` fold: today the tuple
pyramids are not merely verbose, they are *coupled*, and the cost of a 13th source there is
super-linear, not linear.

**Finding 2 — struct fields are a two-edged classification.**
`AgentEnablementSnapshot.zzfake` and `SessionAggregationWork.zzfakeList` become
compiler-forced at every construction site *once you add the field* — but adding the field
is itself optional and silent. A 13th source that skips it compiles, passes the suite, and
simply never appears in the unified list. K11's dictionary-keying in Task 7 removes the
choice, which is the right call.

---

## 5. K16 result

**PASS, statically and behaviourally, with one behaviour change to review.**

Static analysis:
- `SessionProviderCatalog` declares **zero** `@Published` properties and never calls
  `objectWillChange.send()`. `runtimes` is a `let` populated in `init`.
- Grep across the app target: the catalog is observed in exactly **one** place —
  `AgentSessionsApp.swift:176` `@StateObject private var catalog`. No view takes it as
  `@ObservedObject`, no `.environmentObject(catalog)` exists. So no view outside
  `AgentSessionsApp` can be invalidated by it, and `AgentSessionsApp.body` cannot be either
  (nothing ever emits).

Behavioural (new, passing): `AgentSessionsTests/SpikeCatalogInvalidationTests.swift`
- `testCatalogHasNoPublishedStoredProperties` — Mirror-based, no `Published` children.
- `testCatalogDoesNotEmitWhenAnIndexerChurns` — sinks `catalog.objectWillChange`, then runs
  a full `handle.refresh(...)` and directly mutates a `@Published` on the concrete indexer;
  asserts **zero** emissions.
- `testCatalogCoversEveryRegisteredAdapter`, `testRegistryOrderMatchesAllCasesOrder` — §10.1/§10.7 in miniature.

**Behaviour change needing owner verification.** Replacing
`@StateObject private var indexer = SessionIndexer()` with a computed
`catalog.indexer(.codex, as:)` means `AgentSessionsApp` **no longer observes `SessionIndexer`
directly**. That strictly *reduces* App-body invalidation (today every codex index tick
re-evaluates `AgentSessionsApp.body`), so it is favourable for K16 — but it is a real
change, and I could not confirm from static analysis that the old observation was not
load-bearing for something in `body` that reads `indexer.<published>`. **Needs owner
verification in a running app** (the brief forbids launching the GUI here). Task 6 should
either re-establish an explicit observation for the specific properties `body` reads, or
prove by inspection that `body` reads none.

Not checked (and not checkable without running the app): whether toggling one source's
*include* flag invalidates unrelated views more than today. The include flags live on
`UnifiedSessionIndexer`, not the catalog, and were untouched by the catalog change — so
there is no mechanism by which the catalog could have made it worse. Flagging as
**needs owner verification** rather than claiming it.

---

## 6. `AnalyticsService` migration notes — what real Task 6 should do differently

1. **Take the catalog, not indexers, and take it first.** `init(catalog:…)` worked with no
   friction. Once all 12 are in the catalog the other 11 parameters vanish and the two
   `if isEnabled { append }` blocks become a 3-line loop over `SessionSourceRegistry.ordered`.
2. **Drive session gathering off `handle.currentSessions()`, not `indexerObject`.** The
   spike never downcasts inside `AnalyticsService` — the type-erased handle was sufficient
   for every read it does. Keep it that way; downcasts should exist only at
   `TranscriptHostView` and the concrete-view sites §3.3 already carves out.
3. **`MergeMany` is the wrong fold for readiness; use `combineLatestArray`.** The spike used
   `Publishers.MergeMany(handles.map(\.launchPhase))` because it is trivially variadic, but
   it drops the combined-latest semantics the original `CombineLatest3(CombineLatest4×3)`
   had. It happens not to matter here (the sink ignores its value and re-reads current
   phases via `currentLaunchPhase()`), but Task 7's `combineLatestArray` helper is the
   correct primitive and should land **before** this migration so `AnalyticsService` uses it
   from the start rather than being rewritten twice.
4. **Do `updateReadiness`'s phase table as `registry.ordered.map { ($0, handle.currentLaunchPhase()) }`.**
   That single change structurally fixes the class of bug in SPEC §1 (a hand 12-tuple that
   can silently omit a source) for this file.
5. **The `AnalyticsView` preview is a real call site.** `AnalyticsView.swift:419` constructs
   an `AnalyticsService` in a `#Preview`; it is compiled and must be migrated with the rest.
   Easy to miss when grepping for production wiring.
6. **`sourcesFor(_:)` is a hidden per-source switch inside `AnalyticsService` (finding c3)** —
   it switches on `AnalyticsAgentFilter`, not `SessionSource`, so it does not show up in a
   `switch source` census. Task 6 should fold it into whatever resolves c1–c3.

---

## 7. Recommended SPEC changes before Task 1 proceeds

1. **Rewrite §6.** Add c1–c11 (analytics agent filter ×3, `AgentUpdateService.profile(for:)`,
   `PreferencesView`'s six switches, `PreferencesConstants` keys, `TranscriptPlainView`
   image gate, `SessionIndexerProtocol` conformance). Correct the three overcounts in §2.4
   and delete the nonexistent `PreferencesTab(source:)`.
2. **Decide where a new source's UserDefaults key constants live** (finding c9). Either
   accept `PreferencesConstants.swift` as an enumerated shared edit, or let Task 1 move
   per-source keys into per-source files so §2's acceptance list stays honest.
3. **Amend §3.2** with the `SessionIndexerProtocol` conformance obligation.
4. **Amend §3.4** to note the `FocusedReloadTrigger` visibility widening.
5. **Consider promoting the `AnalyticsAgentFilter` gap into Task 8** (or a new small task) —
   it is currently orphaned across §7's increments and is the only (c) item that a *test*,
   not the compiler, catches.
6. **Reorder Task 6/7 slightly:** land `combineLatestArray` (Task 7 head) before the catalog
   migration (Task 6) so consumers are written once.

---

## 8. Worktree state

Branch `spike/source-catalog` at `fde3c215`, three commits on top of `2099ab89`:

| Commit | Subject |
|---|---|
| `8f8a07de` | spike(source-catalog): fake 13th source + catalog skeleton; app target compiles |
| `dd66b388` | spike(source-catalog): satisfy the test suite with the fake 13th source |
| `fde3c215` | spike(source-catalog): K16 catalog invalidation + registry order tests |

Nothing pushed. Nothing committed, edited or built in `/Users/alexm/Repository/Codex-History`
other than this report. `.deriveddata-build/` was added to the spike's `.gitignore`; the
worktree can be deleted once this report is reviewed.
