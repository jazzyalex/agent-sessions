# Adding a session source

Verified against `main` at `760382ed` (2026-08-16), the commit that completed the
Session Source Registry program
([SPEC](superpowers/plans/2026-08-14-session-source-registry-SPEC.md)).

This is the whole cost of a thirteenth agent. It is deliberately a *closed* list: if the
compiler, a test, or the app surprises you with a site that is not written down here, that
is a bug in this document (or a regression in the registry) — please add it rather than
working around it.

---

## 1. What it costs

Adding a source is still ~1,000 lines of genuinely source-specific work (parser,
discovery, indexer, settings, CLI environment, resume stack). That part is honest and
lives entirely inside your own folder. On top of it you owe exactly six things:

1. **Your source folder** — parser / discovery / indexer / settings / resume, plus one
   `<Source>SourceDescriptor.swift` carrying the descriptor *and* the adapter.
2. **The `SessionSource` case** and its four metadata arms in
   [`SessionSource.swift`](../AgentSessions/Model/SessionSource.swift).
3. **One line** in `SessionSourceRegistry.ordered`.
4. **One pbxproj update**, via `scripts/xcode_add_file.rb`.
5. **The enumerated semantic switch arms** in §6 below — the ones the compiler or a test
   sentinel will demand, because they encode real per-source behavior rather than wiring.
6. **Zero unenumerated shared edits.** Nothing else in shared code should need to know
   your source exists.

Everything that used to be hand-wiring — brand colors, badge initials, short labels,
onboarding accents, enablement detection, seed defaults, UserDefaults key plumbing, the
search allow-list, archive backfill, the twelve `@StateObject` indexers, the Combine
pyramids, the preferences sidebar, the toolbar pills, the enablement notice — is derived
from your descriptor now. You do not touch those files at all.

---

## 2. Before you start

**Pick your `versionIntroduced` carefully.** It must be **the upcoming real app
version**, not a placeholder. What's New derives its provider-highlight rows from
`SessionSource.versionIntroduced`
([`WhatsNewCatalog`](../AgentSessions/Onboarding/Models/WhatsNewCatalog.swift)), so a
wrong value either hides your source's announcement or attaches it to a release that
already shipped. As of `760382ed` the shipped version is **4.8** (Grok), so a source
landing next declares **`"4.9"`**.

Do **not** use `"99.0"`. `NewProviderDiscoverabilityTests.testProviderHighlights_returnsEmptyForUnknownVersion`
pins that string as a version no provider claims; the Task-0 spike broke the suite by
picking it for a fake source.

**Check the `AgentSessionsLogicTests` boundary (K15).** `SessionSource.swift`,
`Session.swift`, `FilterEngine.swift` and the parsers compile into a standalone logic-test
target that must not gain app-target dependencies. The registry, descriptors, adapters and
the catalog are app-target only. If you find yourself wanting to `import` registry types
from one of those files, stop — that is the boundary, not an obstacle.

---

## 3. Your source folder

Standard shape, mirroring `AgentSessions/Grok/` and `AgentSessions/Kimi/`:

```
AgentSessions/<Source>/
  <Source>CLIEnvironment.swift
  <Source>Settings.swift
  <Source>SourceDescriptor.swift        ← descriptor + adapter (see §4)
AgentSessions/Services/
  <Source>SessionDiscovery.swift
  <Source>SessionIndexer.swift
  <Source>SessionParser.swift
AgentSessions/Views/Preferences/
  PreferencesView+<Source>.swift        ← your settings pane body
```

### 3.1 The `SessionIndexerProtocol` conformance contract

**Your indexer must conform to `SessionIndexerProtocol`**
([`SessionIndexer.swift:41`](../AgentSessions/Services/SessionIndexer.swift)). This is a
hard requirement, not a nicety: `SourceRuntime.indexerObject` is typed
`any SessionIndexerProtocol & ObservableObject`, and `UnifiedTranscriptView` is generic
over the protocol. If you write only the de-facto published surface, you get a compile
error deep in the transcript layer instead of at your adapter.

Required members:

| Member | Notes |
|---|---|
| `var allSessions: [Session] { get }` | |
| `var sessions: [Session] { get }` | |
| `var isIndexing: Bool { get }` | |
| `var isLoadingSession: Bool { get }` | |
| `var loadingSessionID: String? { get }` | |
| `var launchPhase: LaunchPhase { get }` | |
| **`var activeSearchUI: SessionIndexer.ActiveSearchUI { get set }`** | **settable** — easy to miss, and the usual cause of the transcript-layer error |

`requestOpenRawSheet`, `requestCopyPlainPublisher` and `requestTranscriptFindFocusPublisher`
are Codex-only features with protocol default implementations; ignore them.

Five of the twelve existing indexers conform via a trailing `extension <X>: SessionIndexerProtocol`
rather than on the declaration — if you are auditing conformances, grep extensions too.

Your indexer also needs the published surface the adapter's `ProviderHandle` reads:
`$allSessions`, `$isIndexing`, `$isProcessingTranscripts`, `$filesProcessed`,
`$totalFiles`, `$indexingError`, `$launchPhase`, a
`refresh(mode:trigger:executionProfile:)`, and a `reloadSession(id:force:reason:)` with its
own nominal `ReloadReason` enum.

---

## 4. The descriptor and adapter

One file, in your source's folder. Copy
[`GrokSourceDescriptor.swift`](../AgentSessions/Grok/GrokSourceDescriptor.swift) — it is
the most recent and most complete example.

### 4.1 Descriptor fields

```swift
extension SessionSourceDescriptor {
    static let devin: SessionSourceDescriptor = {
        SessionSourceDescriptor(
            source: .devin,
            shortLabel: "Devin",                 // row/legend label
            badgeInitials: "DV",                 // two letters (droid's "D" is the exception)
            brandHue: .calibrated(red: …, green: …, blue: …),
            monochromeWhite: 0.62,               // Analytics monochrome mode
            onboardingAccent: { _ in … },        // MUST stay a closure — see §4.2
            enablementKey: "AgentEnabledDevin",  // literals, in THIS file — see §4.3
            cliAvailableKey: "DevinCLIAvailable",
            rootOverrideKeys: ["DevinSessionsRootOverride"],
            includeKey: "IncludeDevinSessions",
            binaryNames: ["devin"],
            isBinaryInstalled: { ctx in … },     // AvailabilityContext only — see §4.4
            isAvailable: { ctx in … },
            defaultEnabled: .whenAvailable,      // or .always
            parseFullByPath: { url in … },       // nil for DB-backed — see §5
            archive: ArchiveCapability(…),       // nil for DB-backed — see §5
            supportsResume: true,
            resumeAgentLabel: "Devin",
            otherAgentPill: PillSpec(color: …, shortcut: nil)
        )
    }()
}
```

Identity metadata (`displayName` / `iconName` / `versionIntroduced` / `featureDescription`)
is deliberately **not** here — it stays on `SessionSource` so that file keeps compiling
into the logic-test target (K15). Descriptor consumers read `source.displayName`.

### 4.2 Colors: keep them lazy

`onboardingAccent` is a closure and `PillSpec.color` takes an `@autoclosure` for a
load-bearing reason, not a stylistic one. Brand colors resolve *through the registry*
now; evaluating one while a descriptor's own `static let` is still initializing re-enters
the `swift_once` already running on that thread — a hard deadlock at first palette access,
not a warning. Leave both deferred.

For the accent value itself you have two options, and you do **not** need to touch
`AnalyticsColors.swift`:

```swift
// Preferred — no shared file edit:
onboardingAccent: { _ in Color(nsColor: SessionSourceRegistry.resolvedBrandAccent(for: .devin)) }
otherAgentPill: PillSpec(color: Color(nsColor: SessionSourceRegistry.resolvedBrandAccent(for: .devin)),
                         shortcut: nil)
```

The twelve `Color.agent<X>` statics in
[`AnalyticsColors.swift`](../AgentSessions/Analytics/Utilities/AnalyticsColors.swift) are
now thin aliases for `TranscriptColorSystem.agentBrandAccent(source:)`, which is itself
`SessionSourceRegistry.resolvedBrandAccent(for:)`. Adding one for your source is optional
convenience. The `agent<X>Gray` monochrome statics below them are superseded by
`monochromeWhite` — do not add one.

`brandHue` has two forms (K6). Use `.calibrated(red:green:blue:)` for a hand-tuned
light-mode triple (it goes through `adaptiveBrand`, which derives the dark variant); use
`.system(NSColor)` only if you are passing an AppKit dynamic system color straight through
(antigravity and opencode are the only two).

**⌘-shortcuts are frozen history (K10).** ⌘3–⌘9 are exhausted; hermes, kimi and grok have
`shortcut: nil`. So does yours.

### 4.3 UserDefaults keys stay in your file (K2)

**Do not edit `PreferencesConstants.swift`.** The twelve existing sources' key constants
live there as frozen history; a new source declares its keys as **literals in its own
descriptor file only**. That is what keeps the §1 acceptance list honest — otherwise every
new source would edit a shared file for four strings.

Follow the historical naming so the key table stays legible:
`AgentEnabled<Source>`, `<Source>CLIAvailable`, `<Source>SessionsRootOverride`,
`Include<Source>Sessions`.

Keys are permanent (K1). They are never derived from `rawValue`, and the rawValue itself
is durable on disk in four places (UserDefaults values, the search index's `source TEXT`
columns across five tables, archive folder names, and `SessionArchiveInfo`'s Codable
form). Pick both carefully; you cannot change them later.

You **do** add one row to
[`SessionSourceKeyStabilityTests`](../AgentSessionsTests/SessionSourceKeyStabilityTests.swift)'s
table — it asserts `table.map(\.0) == SessionSource.allCases`, so it fails until you do.
See §7.

### 4.4 Detection goes through `AvailabilityContext` (K5)

Descriptor closures never touch `FileManager.default`. Every existence check goes through
`ctx.fileProbe` (use the `ctx.directoryExists(_:)` helper), every home-relative path
through `ctx.homeDirectory`, every PATH lookup through `ctx.detectBinary`, and every
custom-root read through `ctx.customRoot(_:)` (which normalizes `""` to nil). That is what
makes `AgentBinaryDetectionTests` hermetic instead of dependent on whoever runs it.

Grok is the worked example of a non-trivial gate: a bare `devin` on PATH may not be
evidence of your agent, so require a home directory alongside it.

`defaultEnabled` (K7) is `.always` (on regardless of availability) or `.whenAvailable`
(off unless detected). Prefer `.whenAvailable` for a new source.

### 4.5 The adapter

Below the descriptor, in the same file:

```swift
extension SessionSourceAdapter {
    static let devin = SessionSourceAdapter(
        descriptor: .devin,
        makeRuntime: {
            let indexer = DevinSessionIndexer()
            return SourceRuntime(
                source: .devin,
                indexerObject: indexer,
                handle: UnifiedSessionIndexer.ProviderHandle( … ),
                searchAdapter: .init(
                    transcriptCache: indexer.searchTranscriptCache,
                    update: { indexer.updateSession($0) },
                    parseFull: { url, forcedID in … }
                )
            )
        }
    )
}
```

**Retain-cycle rule (SPEC §3.4).** Every closure in `handle` and `searchAdapter` captures
the local `indexer` and **nothing else** — never `self`, never the catalog, never a view.
`UnifiedSessionIndexer` owns the runtimes and has a `deinit` that must keep running; a
closure capturing it back would strand that teardown.

`makeRuntime` runs exactly once per source, on the main actor, from
`SessionProviderCatalog.init`. There is no enablement guard inside `reloadFocusedSession` —
callers guard.

---

## 5. Recipe: a DB-backed source

If your agent stores every session in one SQLite database rather than a file per session
(Devin, PR #56), two descriptor capabilities exist precisely so you can decline them:

```swift
parseFullByPath: nil,   // every session shares one DB path — path-identified parsing is meaningless
archive: nil,           // archiving is a no-op for this source
```

`parseFullByPath: nil` means the search ingest will not try to reconstruct a session from
its file URL. Instead, ingest through the **forced-ID channel**: your
`searchAdapter.parseFull` receives `(url, forcedID)` and should use the ID, not the path:

```swift
searchAdapter: .init(
    transcriptCache: indexer.searchTranscriptCache,
    update: { indexer.updateSession($0) },
    parseFull: { _, forcedID in
        guard let id = forcedID else { return nil }
        return DevinSqliteReader.loadFullSession(databasePath: dbPath, sessionID: id)
    }
)
```

That channel already exists for four file-based sources (Copilot, Antigravity, Droid,
OpenClaw all take `parseFile(at:forcedID:)`), so nothing new is needed to support it.

`archive: nil` means the source does not participate in pin/archive backfill. All twelve
current sources are file-based and supply an `ArchiveCapability`; yours is the first that
may not.

---

## 6. The enumerated semantic edits

These stay hand-written on purpose: each encodes real per-source behavior that a value
table cannot express. They are grouped by what will tell you about them.

### 6.A Compiler-forced — the build will not succeed without them

(Two rows are flagged inline as exceptions: **9b** is convention-forced only, and **23** is
test-forced first and compiler-forced second.)

| # | File | Site |
|---|---|---|
| 1 | [`Model/SessionSource.swift`](../AgentSessions/Model/SessionSource.swift) | the case + `displayName` / `iconName` / `versionIntroduced` / `featureDescription` |
| 2 | [`Model/SessionSourceRegistry.swift`](../AgentSessions/Model/SessionSourceRegistry.swift) | one line in `ordered`, in `allCases` position |
| 3 | [`Model/Session.swift:656`](../AgentSessions/Model/Session.swift) | `computeIsHousekeeping(source:events:)` |
| 4 | `Model/Session.swift:775, 798` | `storesAuthoritativeLightweightCwd`, `storesAuthoritativeLightweightTitle` |
| 5 | [`Utilities/CodexSessionImagePayload.swift:223, 263, 323`](../AgentSessions/Utilities/CodexSessionImagePayload.swift) | three image-scan switches |
| 6 | [`Utilities/ImageBrowserIndexCache.swift:103, 107, 143`](../AgentSessions/Utilities/ImageBrowserIndexCache.swift) | outer scanner switch + the two inner ones (made exhaustive by Task 8; they used to fall through `default:` and silently scan nothing) |
| 7 | [`Views/TranscriptPlainView.swift:1097`](../AgentSessions/Views/TranscriptPlainView.swift) | the inline-image gate — a seventh image switch, easy to miss |
| 8 | [`Services/UnifiedSessionIndexer.swift:2172`](../AgentSessions/Services/UnifiedSessionIndexer.swift) | `passesHasCommandsFilter` — say whether your source is judged on tool-call evidence or on an unparsed-means-command-free rule |
| 9 | `Services/UnifiedSessionIndexer.swift` (`include<Source>` block, ~`:372-402`) | one `@Published var include<Source>` with its `applyInclude` `didSet`. Forced *transitively*: `includeBinding(for:)` (item 13) and `ensureSourceIncludedForCockpitNavigation` (item 14) are exhaustive and can only be satisfied by naming this property |
| 9b | `Services/UnifiedSessionIndexer.swift` (`<source>AgentEnabled` block, ~`:412-423`; `applyEnablement` `:902`) | **Convention-forced, not compiler-forced** — the only row in this table that is. `isAgentEnabled(_:)` is dictionary-backed, so the build succeeds without these; but every existing arm of `reloadSessionForSource` (item 15) reads `unified.<source>AgentEnabled`, so omitting the mirror leaves your source out of step with all twelve. Add the `@Published private(set) var` and the matching line in `applyEnablement` |
| 10 | [`Services/AgentUpdateService.swift:372`](../AgentSessions/Services/AgentUpdateService.swift) | `profile(for:)` — your update-feed semantics, or `nil` (see grok's arm for why "there is a Homebrew formula" is not sufficient) |
| 11 | [`Views/UnifiedSessionsView.swift:1453, 1490`](../AgentSessions/Views/UnifiedSessionsView.swift) | `canCopyResumeCommand`, `copyResumeCommand`. The registry's `supportsResume` is a pre-filter; these arms exist because several are *narrower* than it |
| 11b | `Views/UnifiedSessionsView.swift:3141` (switch at `:3143`) | `canResumeSession` — the third member of the resume family, and the one items 11 and 12 are written against. `descriptor.supportsResume` guards it first, but the switch is exhaustive with no `default:`, so declare your per-session rule (droid/openclaw spell out an unreachable `return false` rather than inherit one) |
| 12 | `Views/UnifiedSessionsView.swift:3164` | `resume(_:)` — made exhaustive by Task 8. Before that, a new source silently got a dead Resume button |
| 13 | `Views/UnifiedSessionsView.swift:1924` | `includeBinding(for:)` — which include toggle your pill flips |
| 14 | `Views/UnifiedSessionsView.swift:2427` | `ensureSourceIncludedForCockpitNavigation` |
| 15 | `Views/UnifiedSessionsView.swift:2477` | `reloadSessionForSource` — needs your concrete indexer |
| 16 | `Views/UnifiedSessionsView.swift:3933` | `TranscriptHostView`: a stored indexer property + your transcript layer. **The layers are selected by `opacity`, not by a switch**, so omitting the layer is not a compile error — it renders an empty transcript. Grok shipped exactly that way once |
| 17 | [`Views/PreferencesView.swift:1103`](../AgentSessions/Views/PreferencesView.swift) | the `PreferencesTab` case |
| 18 | `Views/PreferencesView.swift:1128, 1154` | `PreferencesTab.title`, `PreferencesTab.iconName` |
| 19 | `Views/PreferencesView.swift:1192, 1212` | `PreferencesTab.init(source:)` and `configuredSource` — the bijection the sidebar derives from |
| 19b | `Views/PreferencesView.swift:1242` | `PreferencesTab.sidebarAgentSources` — **a hand-maintained literal, the second one in the codebase after `SessionSourceRegistry.ordered`**. It is *not* registry order: the rows are frozen sidebar history, so membership is test-enforced but sequence is not derivable. Append your source (unless you are deliberately hiding it, like droid, via `sidebarHiddenSources`) |
| 20 | `Views/PreferencesView.swift:394` | `tabBody` — route your tab case to your pane |
| 21 | `Views/PreferencesView.swift:904, 921, 950, 1536` | the probe quartet: `reprobeAgentBinary(_:)`, `resolvedBinaryPath(for:)`, `customBinaryPath(for:)`, `maybeProbe(for:)` |
| 22 | `Views/PreferencesView.swift:~81` + [`Views/Preferences/PreferencesView+General.swift:459`](../AgentSessions/Views/Preferences/PreferencesView+General.swift) | one `@AppStorage` property on `PreferencesView` + one arm in `agentEnablementBinding(for:)` |
| 23 | [`Analytics/Models/AnalyticsDateRange.swift:51, 82`](../AgentSessions/Analytics/Models/AnalyticsDateRange.swift) | `AnalyticsAgentFilter` case + its `matches(_:)` arm. Two-stage: `matches(_:)` switches over `self`, not over `SessionSource`, so the *case* is test-forced (§6.B) and only once you add it does the compiler demand the arm. `AnalyticsService.sourcesFor(_:)` derives from `matches` and needs nothing |
| 24 | [`Analytics/Views/AnalyticsView.swift`](../AgentSessions/Analytics/Views/AnalyticsView.swift) (`@AppStorage` block ~`:8-20`; `isEnabled(_:)` `:43`) | one `@AppStorage` property + one arm |
| 25 | [`Onboarding/Views/FirstRunSetupView.swift`](../AgentSessions/Onboarding/Views/FirstRunSetupView.swift) (`@AppStorage` block ~`:20-32`; `isAgentEnabled(_:)` `:369`) | one `@AppStorage` property + one arm |
| 26 | your indexer | `SessionIndexerProtocol` conformance (§3.1) — surfaces at `makeRuntime` |

Items 22, 24 and 25 are the same shape three times: SwiftUI's `@AppStorage` is a property
wrapper, so the twelve blocks cannot collapse into an array. Each of the three switches
that consume them is exhaustive with no `default:` on purpose, so the compiler stops you
rather than the source going silently missing — which is exactly what happened to Kimi,
Grok, Cursor and OpenClaw before the exhaustiveness was introduced.

### 6.B Test-forced — sentinels that fire instead of the compiler

| Test | What it wants |
|---|---|
| `SessionSourceRegistryTests.testRegistryOrderEqualsSessionSourceAllCases` | your `ordered` entry, in the right position |
| `SessionProviderCatalogTests.testCatalogCoversEverySourceWithWorkingRuntimes` | a `makeRuntime` that builds |
| `TranscriptHostCoverageTests.testTranscriptHostCoversEverySource` | your source in `TranscriptHostView.coveredSources` (`UnifiedSessionsView.swift:4011`) — the only guard against the silent opacity hole in item 16 |
| `SessionSourceKeyStabilityTests.testEverySourceKeyKeepsItsHistoricalString` | one row in the key table, plus a frozen `Include` assertion |
| `AnalyticsIndexerTests.testEverySourceResolvesToADedicatedFilterForThePicker` | the `AnalyticsAgentFilter` case (item 23) |
| `ViewRegistryDerivationTests.testEverySourceMapsToADistinctPreferencesTab` / `…testEverySourcePaneHasTitleAndIcon` | items 17–19 |
| `ViewRegistryDerivationTests.testSidebarAgentSourcesAreEveryRegistrySourceExceptTheHiddenOnes` | item **19b** — your entry in `sidebarAgentSources`. Items 17–19 do **not** satisfy this one |
| `ViewRegistryDerivationTests.testSidebarAgentTabOrderIsFrozen` | item **19b** again, from the other side: this pins the exact ordered array literal, so **you must also update the expectation inside `ViewRegistryDerivationTests.swift:131-133`**. It is the second of the two test files a new source edits |
| `KimiIntegrationSurfaceTests.testEveryNonCodexSourceKeepsItsLightweightCwdAfterParsing` | constrains *which answer* item 4 gives: every non-codex source must keep its lightweight cwd through a full parse |
| `NewProviderDiscoverabilityTests.testEveryVersionIntroducedProducesValidProviderHighlight` | a real `versionIntroduced` (§2) |

### 6.C Optional / deliberately out of scope

- `UnifiedSessionIndexer.focusedSessionRefreshIntervalsBySource` (`:55`) — a dictionary
  with a `?? defaultFocusedSessionRefreshIntervals` fallback at `:1753`. Add an entry only
  if your source needs a non-default focused-refresh cadence; codex and claude are the
  only two that do.
- `AnalyticsColors.agent<Source>` — optional alias, see §4.2.
- The live-session subsystem (`CodexActiveSessionsModel`, `AgentCockpitHUDView.HUDAgentType`)
  is a deliberate four-source opt-in and stays `default:`-based. Your source is not in it
  unless you choose to add it as separate work.

### 6.D User-facing docs

Not code, but part of shipping a source: `README.md`,
`docs/agent-support/agent-support-matrix.yml`, `docs/agent-support/public-agents.json`.

---

## 7. Xcode project and verification

**Add every new Swift file to the project**, or it will not compile into the target:

The script takes **four** positional arguments — `PROJ TARGET FILE GROUP`
(`scripts/xcode_add_file.rb:15`), the form documented in `agents.md`. Passing fewer aborts
with `usage: PROJ TARGET FILE GROUP`.

```bash
./scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessions \
  AgentSessions/Devin/DevinSourceDescriptor.swift \
  AgentSessions/Devin

./scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessionsTests \
  AgentSessionsTests/DevinSqliteReaderTests.swift \
  AgentSessionsTests
```

The script pins its own UTF-8, so no `LANG` wrapper is needed. A correct run adds exactly
four pbxproj lines per file. It is also the clean way to resolve a pbxproj merge conflict:
take one side, then re-run the script for the missing files.

Then:

```bash
./scripts/xcode_test_stable.sh
```

Work the failures in this order — the sentinels are designed to be a checklist:
registry order → catalog runtimes → key table → transcript-host coverage → analytics
filter → preferences derivation → sidebar membership and frozen order.

---

## 8. Proof: what the registry actually removed

Measured 2026-08-16 by dry-run-rebasing **PR #56 (Devin CLI)** — authored against
`4dd63d3f`, before any of this landed — onto `main` at `760382ed`.

**As authored, PR #56 touched 26 shared files** (20 app Swift, 2 test Swift, the pbxproj,
README and two support-matrix docs) plus 14 new source-local files.

Of those 26, **14 no longer need to be touched at all**:

| File | Replaced by |
|---|---|
| `AgentSessionsApp.swift` | `SessionProviderCatalog` — one `@StateObject`, not twelve |
| `Analytics/Services/AnalyticsService.swift` | catalog + registry-ordered array folds |
| `Analytics/Utilities/AnalyticsColors.swift` | descriptor `brandHue` / `monochromeWhite` (§4.2) |
| `Onboarding/Components/OnboardingComponents.swift` | descriptor `badgeInitials` |
| `Onboarding/Components/OnboardingPalette.swift` | descriptor `onboardingAccent` |
| `Search/SearchCoordinator.swift` | `start(allowed: Set<SessionSource>)` (K9) — no more one `Bool` parameter per source |
| `Search/SearchIngestService.swift` | descriptor `parseFullByPath` |
| `Services/AgentEnablement.swift` | descriptor keys + `AvailabilityContext` detection + `defaultEnabled` |
| `Services/SessionArchiveManager.swift` | descriptor `archive` |
| `Services/TranscriptColorSystem.swift` | descriptor `brandHue` |
| `Views/SessionTerminalView.swift` | descriptor `shortLabel` |
| `Views/Preferences/PreferencesConstants.swift` | K2 — new sources keep keys in their own descriptor |
| `AgentSessionsTests/CodexActiveSessionsRegistryTests.swift` | K11 — aggregation structs are dictionary-keyed, so no new field per source |
| `AgentSessionsTests/SessionParserTests.swift` | same |

**The Swift-file count for that same edit set falls from 22 to 8** — a 64% reduction, and
every one of the eight is a §6 semantic site rather than wiring.

A *complete* port on today's `main` is **20 files**, every one of them enumerated — the
Swift and test files in §6, the docs in §6.D, and the pbxproj as §1 obligation 4:

| Bucket | Count | Files |
|---|---|---|
| Shared app Swift (§6.A) | **14** | `SessionSource.swift` · `SessionSourceRegistry.swift` · `Session.swift` · `CodexSessionImagePayload.swift` · `ImageBrowserIndexCache.swift` · `TranscriptPlainView.swift` · `UnifiedSessionIndexer.swift` · `AgentUpdateService.swift` · `UnifiedSessionsView.swift` · `PreferencesView.swift` · `PreferencesView+General.swift` · `AnalyticsDateRange.swift` · `AnalyticsView.swift` · `FirstRunSetupView.swift` |
| Test files (§6.B) | **2** | `SessionSourceKeyStabilityTests.swift` (a table row) · `ViewRegistryDerivationTests.swift` (the frozen sidebar-order literal) |
| Project file | **1** | `AgentSessions.xcodeproj/project.pbxproj` |
| User-facing docs (§6.D) | **3** | `README.md` · `agent-support-matrix.yml` · `public-agents.json` |

(§6.A item 26 — your indexer's `SessionIndexerProtocol` conformance — is source-local, not
shared, so it is not counted here.)

That total is larger than the 12 surviving files above because PR #56 was itself an
incomplete port. Against **today's** `main` it would owe edits in five more shared files
it does not touch: `AnalyticsDateRange.swift` (no `AnalyticsAgentFilter` case),
`CodexSessionImagePayload.swift`, `ImageBrowserIndexCache.swift`, `TranscriptPlainView.swift`
and `PreferencesView+General.swift`. Note the honest version of this: at the PR's own
merge-base three of those image switches still ended in `default:`, so skipping them was
*then* correct — Task 8 converted them to exhaustive switches precisely so the next source
cannot skip them silently. `AnalyticsDateRange` and `PreferencesView+General` were real
omissions even then (the latter carried an 11-entry hand-listed count array PR #56 never
joined).

The composition matters more than the total: **hand-wiring tax went from 14 files to
zero.** What remains is the behavior a new agent genuinely has to describe.
