---
layout: blog
title: "Adding a session source"
seo_title: "Adding a session source to Agent Sessions"
description: "What it costs to add a coding agent as a searchable session source: the closed list of sites to touch, the fixtures, and the evidence a PR needs."
image: /assets/marketing/screenshots/agent-sessions-codex-claude-history.png
last_modified_at: 2026-08-29
---
# Adding a session source

Verified against the Qwen Code source dogfood pass on 2026-08-17, after the Session
Source Registry program completed
([SPEC](https://github.com/jazzyalex/agent-sessions/blob/main/docs/superpowers/plans/2026-08-14-session-source-registry-SPEC.md)). Update the base
commit in your PR evidence; this no-commit working pass deliberately does not invent one.

This is the whole cost of the next agent. It is deliberately a *closed* list: if the
compiler, a test, or the app surprises you with a site that is not written down here, that
is a bug in this document (or a regression in the registry) — please add it rather than
working around it.

---

## 1. What it costs

Adding a source is still ~1,000 lines of genuinely source-specific work (parser,
discovery, indexer, settings, CLI environment, resume stack). That part is honest and
lives mostly inside your own folder. On top of it you owe eight baseline things:

1. **Your source folder** — parser / discovery / indexer / settings / resume, plus one
   `<Source>SourceDescriptor.swift` carrying the descriptor *and* the adapter.
2. **Source-local fixtures and tests** — at minimum positive and malformed-or-unsupported
   discovery / parser coverage, plus settings and resume eligibility tests when those capabilities
   exist. Synthetic fixtures belong under `Resources/Fixtures/stage0/agents/<source>/`.
   A single-SQLite-file source may build its schema in-test instead — see the carve-out in §5.
3. **The `SessionSource` case** and its four metadata arms in
   [`SessionSource.swift`](https://github.com/jazzyalex/agent-sessions/blob/main/AgentSessions/Model/SessionSource.swift).
4. **One line** in `SessionSourceRegistry.ordered`.
5. **Project membership for every new Swift file**, via one `scripts/xcode_add_file.rb`
   invocation per file. The invocations all update the same pbxproj.
6. **The enumerated semantic switch arms** in §6 below — the ones the compiler or a test
   sentinel will demand, because they encode real per-source behavior rather than wiring.
7. **The user-facing support and release docs** in §6.D.
8. **Zero unexplained shared edits.** A provider can require a genuinely generic seam the
   registry did not need before — Qwen's environment-selected data root added
   `AvailabilityContext.environment`. Add the smallest source-agnostic seam, a hermetic
   regression test, and the missing obligation to this guide. Do not bypass the seam from
   source-specific code.

Most former hand-wiring — brand colors, badge initials, short labels, onboarding accents,
enablement detection, seed defaults, archive backfill, the former per-source `@StateObject`
indexers, the Combine pyramids, descriptor-backed toolbar pills, and the enablement notice —
is derived from your descriptor now. Source-specific include storage, active-search restart
observation, preferences tab/sidebar/reset/probe behavior, and SwiftUI `@AppStorage` bindings
remain the explicit semantic edits in §6; do not assume those files are untouched.

---

## 2. Before you start

**Pick your `versionIntroduced` carefully.** It must be **the upcoming real app
version**, not a placeholder. What's New derives its provider-highlight rows from
`SessionSource.versionIntroduced`
([`WhatsNewCatalog`](https://github.com/jazzyalex/agent-sessions/blob/main/AgentSessions/Onboarding/Models/WhatsNewCatalog.swift)), so a
wrong value either hides your source's announcement or attaches it to a release that
already shipped. The shipped version is **4.8** (Grok), while Qwen is currently recorded
for the upcoming **5.0** release. Confirm the intended release with the maintainer; another
source landing in the same release can also use `"5.0"`.

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
AgentSessionsTests/
  <Source>IntegrationTests.swift        ← discovery/parser/settings/resume regressions
Resources/Fixtures/stage0/agents/<source>/
  small.<format> + unsupported.<format> ← synthetic or fully sanitized evidence
```

The exact test split may follow an established source instead of using one integration-test
file, but the behavior coverage and fixtures are required. Shared sentinel tests in §6.B do
not replace source-local format, malformed-or-unsupported input, path-classification, or
resume tests.

### 3.1 The `SessionIndexerProtocol` conformance contract

**Your indexer must conform to `SessionIndexerProtocol`**
([`SessionIndexer.swift:41`](https://github.com/jazzyalex/agent-sessions/blob/main/AgentSessions/Services/SessionIndexer.swift)). This is a
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

Some existing indexers conform via a trailing `extension <X>: SessionIndexerProtocol`
rather than on the declaration — if you are auditing conformances, grep extensions too.

Your indexer also needs the published surface the adapter's `ProviderHandle` reads:
`$allSessions`, `$isIndexing`, `$isProcessingTranscripts`, `$filesProcessed`,
`$totalFiles`, `$indexingError`, `$launchPhase`, a
`refresh(mode:trigger:executionProfile:)`, and a `reloadSession(id:force:reason:)` with its
own nominal `ReloadReason` enum.

If the format supports rewind/branch replacement, a successful full reload is authoritative
for every branch-derived field: rendered events, non-metadata count, title, custom title, cwd,
and model. Do not merge those fields with `max` or stale non-nil fallbacks from the old row;
that preserves discarded-branch metadata beside the newly parsed transcript. Add a regression
that reloads a shorter active branch whose discarded branch carried the previous title.

---

## 4. The descriptor and adapter

One file, in your source's folder. Start from the closest current storage shape:
[`GrokSourceDescriptor.swift`](https://github.com/jazzyalex/agent-sessions/blob/main/AgentSessions/Grok/GrokSourceDescriptor.swift) is a complete
file-backed example, while `OpenCodeSourceDescriptor.swift` demonstrates identity-backed
shared storage. Do not copy a descriptor without re-answering every capability field.

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
            parseFullByPath: { url in … },       // nil for DB-only — see §5
            parseFullByIdentity: nil,            // required when sessions share a path
            searchUsesIdentityAtURL: nil,        // selects those shared-storage URLs
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

The existing `Color.agent<X>` statics in
[`AnalyticsColors.swift`](https://github.com/jazzyalex/agent-sessions/blob/main/AgentSessions/Analytics/Utilities/AnalyticsColors.swift) are
now thin aliases for `TranscriptColorSystem.agentBrandAccent(source:)`, which is itself
`SessionSourceRegistry.resolvedBrandAccent(for:)`. Adding one for your source is optional
convenience. The `agent<X>Gray` monochrome statics below them are superseded by
`monochromeWhite` — do not add one.

`brandHue` has two forms (K6). Use `.calibrated(red:green:blue:)` for a hand-tuned
light-mode triple (it goes through `adaptiveBrand`, which derives the dark variant); use
`.system(NSColor)` only if you are passing an AppKit dynamic system color straight through
(antigravity and opencode are the only two).

**⌘-shortcuts are frozen history (K10).** ⌘3–⌘9 are exhausted; hermes, kimi, grok and qwen
have `shortcut: nil`. So does yours.

### 4.3 UserDefaults keys stay in your file (K2)

**Do not edit `PreferencesConstants.swift`.** The pre-registry sources' key constants
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
[`SessionSourceKeyStabilityTests`](https://github.com/jazzyalex/agent-sessions/blob/main/AgentSessionsTests/SessionSourceKeyStabilityTests.swift)'s
table — it asserts `table.map(\.0) == SessionSource.allCases`, so it fails until you do.
See §7.

### 4.4 Detection goes through `AvailabilityContext` (K5)

Descriptor closures never touch `FileManager.default`. Every existence check goes through
`ctx.fileProbe` (use the `ctx.directoryExists(_:)` helper), every home-relative path
through `ctx.homeDirectory`, every PATH lookup through `ctx.detectBinary`, and every
custom-root read through `ctx.customRoot(_:)` (which normalizes `""` to nil). That is what
makes `AgentBinaryDetectionTests` hermetic instead of dependent on whoever runs it.

If the upstream CLI selects its data root through an environment variable, read it from
`ctx.environment`, not `ProcessInfo` inside the descriptor, and pass the same environment
into discovery. Add a test with an injected home, filesystem, and environment proving that
availability and discovery resolve the identical root. Qwen's `QWEN_HOME` path is the
worked example. A process-local variable that the app cannot reliably inherit must instead
be documented and exposed as a custom-root setting.

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
parseFullByIdentity: { url, sessionID in
    DevinSqliteReader.loadFullSession(databasePath: url.path, sessionID: sessionID)
},
searchUsesIdentityAtURL: { $0.pathExtension == "db" },
archive: nil,           // archiving is a no-op for this source
```

`parseFullByPath: nil` means path-only parsing is unavailable. Search ingest carries the
lightweight session ID alongside the shared database path and calls
`parseFullByIdentity(url, sessionID)`, so every database row can receive its own FTS entry.
It also keys freshness and removal cleanup by the lightweight session revision, rather than
the shared database file stat. `searchUsesIdentityAtURL` matters for hybrid sources such as
Hermes, whose JSON sessions must retain ordinary path-based freshness.
The interactive search adapter uses the same non-optional identity:

```swift
searchAdapter: .init(
    transcriptCache: indexer.searchTranscriptCache,
    update: { indexer.updateSession($0) },
    parseFull: { _, forcedID in
        DevinSqliteReader.loadFullSession(databasePath: dbPath, sessionID: forcedID)
    }
)
```

OpenCode and Hermes demonstrate both routes: their legacy file formats use
`parseFullByPath`, while their current database formats use `parseFullByIdentity` and
`searchUsesIdentityAtURL`.

The runtime handle must also expose the provider's authoritative identity snapshot:

```swift
searchIdentitySnapshots: .provider { indexer.searchIdentitySnapshot },
```

File-backed providers must instead declare `searchIdentitySnapshots: .notApplicable`.
There is deliberately no default: catalog construction rejects a descriptor/runtime mismatch,
so copying an adapter cannot silently leave removed database identities in search and Analytics.

The snapshot contains the authoritative **live** database path and the IDs returned by the
completed lightweight enumeration. Keep the live path in `storagePaths` even when the file
has disappeared or the provider switched to a file-backed backend; that is how the last
persisted live identities are removed. Pinned/archive database copies do not belong in the
provider snapshot. Their identity-bearing `FileRef`s declare the IDs that are current at
each archive path instead.

Search freshness for an identity-backed session is `(source, sessionID, contentRevision,
storagePath)`. A live database copied or moved into the archive is not current merely
because its ID and revision are unchanged: it must be ingested at the new path before the
old live-path row can be retired.

The search index persists the previously owned storage paths for each source and reconciles
the union of previous and current paths one path at a time. This retires sessions from an
old custom root and removes an archive after it is unpinned, while preserving archives that
are still surfaced. Never infer ownership from arbitrary `files` or `session_meta` rows.

An empty ID set means the live database was read successfully and has no sessions; `nil`
means the open/query failed. Keep those states distinct. Only a completely successful pass
with a non-`nil` snapshot may delete or retire identities. A failed or partial pass still
records the current identity-bearing `FileRef` paths as owned, but only by unioning them
with prior ownership; it performs no deletion and does not become an ingest early-out
baseline. This preserves the last healthy live corpus and lets a later healthy pass retire
an archive even if the app restarted in between. See
`OpenCodeSqliteReader.listSessionsIfReadable`, `HermesStateDBReader.listSessionsIfReadable`,
and `IndexDB.reconcileSearchIdentityStorage`.

`IndexDB.purgeSource` removes the corpus, identity ownership, and advances the per-source
ingest generation in one transaction. The in-memory aggregate early-out is valid only for
the same generation, so **Rebuild Core Index** cannot purge unchanged files and then skip
re-ingesting them. Keep this transaction/generation invariant when adding another rebuild
or destructive maintenance path.

`archive: nil` means the source participates in neither pin/archive backfill **nor pinning
itself** — `SessionArchiveManager.pin` returns early for it. Current sources supply an
`ArchiveCapability`; a new database-only source may decline it.

That gate was added on 2026-08-21, after the devin review found the two halves had drifted
apart: `archive` was consulted only by the two backfill resolvers, so a declining source still
went through `pin` → `ensureSynced`, which single-file-copies `upstreamPath`. For a source
whose sessions all report the same shared-database path that meant copying the whole store
once per starred session, re-copied whenever the live CLI moved its stat. If you are reading
this because you declined `archive`, starring still works — `toggleFavorite` records it
before `pin` is reached — you simply get no filesystem archive, which is what the field means.

**Fixtures for a database-backed source (§1 item 2, §3).** Do not commit a binary `.db`.
Excerpting one session out of a multi-gigabyte store means reconstructing the schema anyway,
and a `.db` blob is worse evidence than records a reviewer can read in the diff. Split it the
way opencode and devin do:

- **Tests** build the schema in-test — `DevinSqliteReaderTests.buildFixture` is the worked
  example. This is what covers the positive and malformed-or-unsupported cases.
- **`Resources/Fixtures/stage0/agents/<source>/` still gets a fixture**, as JSON: the logical
  projection of the records your reader consumes, one file for the normal shape and a
  `schema_drift` one for the sentinel. `agents/devin/small.json` is the sessions row plus its
  main-chain `message_nodes` payloads.

The second half is not optional and an earlier revision of this section wrongly implied it
was. `scripts/agent_watch.py` diffs the live store against **fixture-derived** baseline
type-keys (`_baseline_type_keys_for_agent`), so a source with no fixture can be fingerprinted
but never drift-checked — which silently disqualifies it from weekly monitoring and therefore
from the `Steward-verified` tier, since a steward's whole job is running that check. Skipping
the fixture does not save work, it removes the feature.

So a DB-backed source owes two fingerprint functions in `agent_watch.py`, both normalizing
into the same buckets: `_<source>_fixture_file_schema_fingerprint` for the JSON baseline and
`_<source>_sqlite_latest_session_schema_fingerprint` for the live database, plus a
`local_schema` kind wiring them together. Bucket by the unit drift actually matters in —
devin uses `session` and `node.<role>`, opencode uses `session` / `message.<role>` /
`part.<type>` — so a new record kind shows up as an unknown type rather than vanishing into a
generic bucket. Walk the live store exactly as the app does: devin's fingerprint follows
`main_chain_id` back through `parent_node_id`, because fingerprinting every row would report
drift from abandoned branches the app never renders.

The support-matrix entry needs an `evidence_fixtures` key naming both the JSON fixtures and
the in-test builder, so the row is not silently missing a field every other source has.

---

## 6. The enumerated semantic edits

These stay hand-written on purpose: each encodes real per-source behavior that a value
table cannot express. They are grouped by what will tell you about them.

### 6.A Behavior-bearing source edits

Many rows are compiler-forced because their switches are exhaustive; others are silent UI,
reset, convention, or test obligations and say so inline. A green build alone does not prove
this table is complete.

| # | File | Site |
|---|---|---|
| 1 | [`Model/SessionSource.swift`](https://github.com/jazzyalex/agent-sessions/blob/main/AgentSessions/Model/SessionSource.swift) | the case + `displayName` / `iconName` / `versionIntroduced` / `featureDescription` |
| 2 | [`Model/SessionSourceRegistry.swift`](https://github.com/jazzyalex/agent-sessions/blob/main/AgentSessions/Model/SessionSourceRegistry.swift) | one line in `ordered`, in `allCases` position |
| 3 | [`Model/Session.swift:656`](https://github.com/jazzyalex/agent-sessions/blob/main/AgentSessions/Model/Session.swift) | `computeIsHousekeeping(source:events:)` |
| 4 | `Model/Session.swift:775, 798` | `storesAuthoritativeLightweightCwd`, `storesAuthoritativeLightweightTitle` |
| 5 | [`Utilities/CodexSessionImagePayload.swift:223, 263, 323`](https://github.com/jazzyalex/agent-sessions/blob/main/AgentSessions/Utilities/CodexSessionImagePayload.swift) | three image-scan switches |
| 6 | [`Utilities/ImageBrowserIndexCache.swift:103, 107, 143`](https://github.com/jazzyalex/agent-sessions/blob/main/AgentSessions/Utilities/ImageBrowserIndexCache.swift) | outer scanner switch + the two inner ones (made exhaustive by Task 8; they used to fall through `default:` and silently scan nothing) |
| 7 | [`Views/TranscriptPlainView.swift:1097`](https://github.com/jazzyalex/agent-sessions/blob/main/AgentSessions/Views/TranscriptPlainView.swift) | the inline-image gate — a seventh image switch, easy to miss |
| 8 | [`Services/UnifiedSessionIndexer.swift:2172`](https://github.com/jazzyalex/agent-sessions/blob/main/AgentSessions/Services/UnifiedSessionIndexer.swift) | `passesHasCommandsFilter` — say whether your source is judged on tool-call evidence or on an unparsed-means-command-free rule |
| 9 | `Services/UnifiedSessionIndexer.swift` (`include<Source>` block, ~`:372-402`) | one `@Published var include<Source>` with its `applyInclude` `didSet`. Forced *transitively*: `includeBinding(for:)` (item 13) and `ensureSourceIncludedForCockpitNavigation` (item 14) are exhaustive and can only be satisfied by naming this property |
| 9b | `Services/UnifiedSessionIndexer.swift` (`<source>AgentEnabled` block, ~`:412-423`; `applyEnablement` `:902`) | **Convention-forced, not compiler-forced** — the only row in this table that is. `isAgentEnabled(_:)` is dictionary-backed, so the build succeeds without these; but every existing arm of `reloadSessionForSource` (item 15) reads `unified.<source>AgentEnabled`, so omitting the mirror leaves your source out of step with the other sources. Add the `@Published private(set) var` and the matching line in `applyEnablement` |
| 9c | `Views/UnifiedSessionsView.swift` (`include<Source>` `.onChange` block, ~`:590-620`) | restart an in-flight search when the source include toggle changes. The session list reads the new value immediately, but an existing search keeps its old allow-list unless this observer calls `restartSearchIfRunning()` |
| 10 | [`Services/AgentUpdateService.swift:372`](https://github.com/jazzyalex/agent-sessions/blob/main/AgentSessions/Services/AgentUpdateService.swift) | `profile(for:)` — your update-feed semantics, or `nil` (see grok's arm for why "there is a Homebrew formula" is not sufficient) |
| 11 | [`Views/UnifiedSessionsView.swift:1453, 1490`](https://github.com/jazzyalex/agent-sessions/blob/main/AgentSessions/Views/UnifiedSessionsView.swift) | `canCopyResumeCommand`, `copyResumeCommand`. The registry's `supportsResume` is a pre-filter; these arms exist because several are *narrower* than it |
| 11b | `Views/UnifiedSessionsView.swift:3141` (switch at `:3143`) | `canResumeSession` — the third member of the resume family, and the one items 11 and 12 are written against. `descriptor.supportsResume` guards it first, but the switch is exhaustive with no `default:`, so declare your per-session rule (droid/openclaw spell out an unreachable `return false` rather than inherit one) |
| 12 | `Views/UnifiedSessionsView.swift:3164` | `resume(_:)` — made exhaustive by Task 8. Before that, a new source silently got a dead Resume button |
| 13 | `Views/UnifiedSessionsView.swift:1924` | `includeBinding(for:)` — which include toggle your pill flips |
| 14 | `Views/UnifiedSessionsView.swift:2427` | `ensureSourceIncludedForCockpitNavigation` |
| 15 | `Views/UnifiedSessionsView.swift:2477` | `reloadSessionForSource` — needs your concrete indexer |
| 16 | `Views/UnifiedSessionsView.swift:3933` | `TranscriptHostView`: a stored indexer property + your transcript layer. **The layers are selected by `opacity`, not by a switch**, so omitting the layer is not a compile error — it renders an empty transcript. Grok shipped exactly that way once |
| 17 | [`Views/PreferencesView.swift:1103`](https://github.com/jazzyalex/agent-sessions/blob/main/AgentSessions/Views/PreferencesView.swift) | the `PreferencesTab` case |
| 18 | `Views/PreferencesView.swift:1128, 1154` | `PreferencesTab.title`, `PreferencesTab.iconName` |
| 19 | `Views/PreferencesView.swift:1192, 1212` | `PreferencesTab.init(source:)` and `configuredSource` — the bijection the sidebar derives from |
| 19b | `Views/PreferencesView.swift:1242` | `PreferencesTab.sidebarAgentSources` — **a hand-maintained literal, the second one in the codebase after `SessionSourceRegistry.ordered`**. It is *not* registry order: the rows are frozen sidebar history, so membership is test-enforced but sequence is not derivable. Append your source (unless you are deliberately hiding it, like droid, via `sidebarHiddenSources`) |
| 20 | `Views/PreferencesView.swift:394` | `tabBody` — route your tab case to your pane |
| 21 | `Views/PreferencesView.swift:904, 921, 950, 1536` | the probe quartet: `reprobeAgentBinary(_:)`, `resolvedBinaryPath(for:)`, `customBinaryPath(for:)`, `maybeProbe(for:)` |
| 21b | `Views/PreferencesView.swift` (`resetToDefaults`, ~`:735-812`) | clear every source-specific binary/root override, revalidate the corresponding fields, and reprobe availability. This is not descriptor-derived; omission leaves custom settings active after Reset to Defaults |
| 22 | `Views/PreferencesView.swift:~81` + [`Views/Preferences/PreferencesView+General.swift:459`](https://github.com/jazzyalex/agent-sessions/blob/main/AgentSessions/Views/Preferences/PreferencesView+General.swift) | one `@AppStorage` property on `PreferencesView` + one arm in `agentEnablementBinding(for:)` |
| 23 | [`Analytics/Models/AnalyticsDateRange.swift:51, 82`](https://github.com/jazzyalex/agent-sessions/blob/main/AgentSessions/Analytics/Models/AnalyticsDateRange.swift) | `AnalyticsAgentFilter` case + its `matches(_:)` arm. Two-stage: `matches(_:)` switches over `self`, not over `SessionSource`, so the *case* is test-forced (§6.B) and only once you add it does the compiler demand the arm. `AnalyticsService.sourcesFor(_:)` derives from `matches` and needs nothing |
| 24 | [`Analytics/Views/AnalyticsView.swift`](https://github.com/jazzyalex/agent-sessions/blob/main/AgentSessions/Analytics/Views/AnalyticsView.swift) (`@AppStorage` block ~`:8-20`; `isEnabled(_:)` `:43`) | one `@AppStorage` property + one arm |
| 25 | [`Onboarding/Views/FirstRunSetupView.swift`](https://github.com/jazzyalex/agent-sessions/blob/main/AgentSessions/Onboarding/Views/FirstRunSetupView.swift) (`@AppStorage` block ~`:20-32`; `isAgentEnabled(_:)` `:369`) | one `@AppStorage` property + one arm |
| 26 | your indexer | `SessionIndexerProtocol` conformance (§3.1) — surfaces at `makeRuntime` |

Items 22, 24 and 25 are the same shape three times: SwiftUI's `@AppStorage` is a property
wrapper, so the named blocks cannot collapse into an array. Each of the three switches
that consume them is exhaustive with no `default:` on purpose, so the compiler stops you
rather than the source going silently missing — which is exactly what happened to Kimi,
Grok, Cursor and OpenClaw before the exhaustiveness was introduced.

Archive support and resume support are separate decisions. If a CLI can discover archived
history but its resume command only opens active storage, classify transcript locations
relative to the normalized configured root and reject non-active sessions in all three resume
sites (items 11, 11b and 12). Reuse one classifier in discovery and resume eligibility; a
suffix or immediate-parent check is insufficient. For example, if the valid shape is exactly
`<root>/<one-project>/chats/<id>`, then `<root>/<one-project>/backup/chats/<id>` is a nested
lookalike, not an active session.

If CLI lookup also depends on a relocated/custom root, both copied and launched commands must
propagate the exact, shell-quoted provider root/environment, while default-root commands remain
unchanged. If that root cannot be derived safely, mark the session browse-only. Qwen exposed
both gaps: a source-level `supportsResume` value alone cannot distinguish active chats,
native archives, Agent Sessions archive fallbacks, nested copies, and relocated runtime roots.
Add hardcoded regressions for all of those path shapes plus exact default-root and custom-root
copy/launch commands.

Copy Resume and launch must also choose `--resume`, `--continue`, or unsupported from the same
probed capabilities for the exact resolved binary. Do not assume that a nonempty session ID
means a custom/older binary supports `--resume`; test a custom binary that advertises only the
safe fallback and one that advertises neither flag.

Installed help and reader behavior can justify an explicitly **untested** resume integration
when authentication blocks a disposable run. Do not call it **verified** until that end-to-end
run succeeds, and keep the limitation identical in the README, support matrix, release notes,
and handoff.

### 6.B Test-forced — sentinels that fire instead of the compiler

| Test | What it wants |
|---|---|
| `SessionSourceRegistryTests.testRegistryOrderEqualsSessionSourceAllCases` | your `ordered` entry, in the right position |
| `SessionProviderCatalogTests.testCatalogCoversEverySourceWithRuntimes` | a `makeRuntime` that builds |
| `SessionProviderCatalogTests.testTypedIndexerLookupMatchesRuntimeObject` | one explicit source-to-concrete-indexer golden; runtime `source` alone cannot catch a copied wrong class |
| `SessionProviderCatalogTests.testRuntimeIdentitySnapshotCapabilityMatchesDescriptor` | `.provider` for identity-backed descriptors and explicit `.notApplicable` for file-backed ones |
| `TranscriptHostCoverageTests.testTranscriptHostCoversEverySource` | your source in `TranscriptHostView.coveredSources` (`UnifiedSessionsView.swift:4011`) — the only guard against the silent opacity hole in item 16 |
| `SessionSourceKeyStabilityTests.testEverySourceKeyKeepsItsHistoricalString` | one row in the key table, plus a frozen `Include` assertion |
| `AnalyticsIndexerTests.testEverySourceResolvesToADedicatedFilterForThePicker` | the `AnalyticsAgentFilter` case (item 23) |
| `ViewRegistryDerivationTests.testEverySourceMapsToADistinctPreferencesTab` / `…testEverySourcePaneHasTitleAndIcon` | items 17–19 |
| `ViewRegistryDerivationTests.testSidebarAgentSourcesAreEveryRegistrySourceExceptTheHiddenOnes` | item **19b** — your entry in `sidebarAgentSources`. Items 17–19 do **not** satisfy this one |
| `ViewRegistryDerivationTests.testSidebarAgentTabOrderIsFrozen` | item **19b** again, from the other side: this pins the exact ordered array literal, so **you must also update the expectation inside `ViewRegistryDerivationTests.swift:131-133`** |
| `KimiIntegrationSurfaceTests.testEveryNonCodexSourceKeepsItsLightweightCwdAfterParsing` | constrains *which answer* item 4 gives: every non-codex source must keep its lightweight cwd through a full parse |
| `NewProviderDiscoverabilityTests.testEveryVersionIntroducedProducesValidProviderHighlight` | a real `versionIntroduced` (§2) |
| `NewProviderDiscoverabilityTests.testIsEnabled_availabilityGatedSourceIsOffWhenUnavailable` | add a `.whenAvailable` source to the explicit gated cohort |
| `WhatsNewCatalogTests` release teaser assertion | add a concise teaser for the upcoming release in `WhatsNewCatalog.teasers`; provider highlights are generated, but the session-list card's teaser is not |
| `SessionSourceRegistryTests` frozen palette, badge, label, shortcut and archive sets | explicit source values; do not derive expectations from the descriptor under test |

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
`docs/agent-support/agent-support-matrix.yml`, `docs/agent-support/public-agents.json`, a
bullet under `[Unreleased]` in `docs/CHANGELOG.md`, and a 1–2 bullet note in the current
`docs/summaries/YYYY-MM.md`. Keep evidence limits and unsupported capabilities consistent
across all five surfaces.

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

Repeat the command for every parser, discovery, indexer, settings, resume, preferences,
and test Swift file. A successful invocation for one file does not add its siblings.

The script pins its own UTF-8, so no `LANG` wrapper is needed. A correct run adds exactly
four pbxproj lines per file. It is also the clean way to resolve a pbxproj merge conflict:
take one side, then re-run the script for the missing files.

Then run the complete final gate:

```bash
git diff --check
xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions \
  -configuration Debug build
./scripts/xcode_test_stable.sh
```

Work the failures in this order — the sentinels are designed to be a checklist:
registry order → catalog runtimes → key table → transcript-host coverage → analytics
filter → preferences derivation → sidebar membership and frozen order.

Finally inspect every fixture and the complete diff for private data, generated artifacts,
unrelated changes, and support claims not established by local evidence. Confirm that the
README, changelog, monthly summary, support matrix, and public-agents data describe the same
capabilities and limitations.

A green suite proves the fixtures parse; it does not prove the app reads your agent. Before
marking the PR ready, run the app against your own sessions and answer the checklist in
[docs/CONTRIBUTING.md](https://github.com/jazzyalex/agent-sessions/blob/main/docs/CONTRIBUTING.md) → "Testing your source against your own sessions".
Most of it nobody else can do for you — a maintainer without the agent installed cannot tell
whether Resume actually reopens a session.

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
| `Search/SearchIngestService.swift` | descriptor identity parser/predicate for shared storage, otherwise `parseFullByPath` |
| `Services/AgentEnablement.swift` | descriptor keys + `AvailabilityContext` detection + `defaultEnabled` |
| `Services/SessionArchiveManager.swift` | descriptor `archive` |
| `Services/TranscriptColorSystem.swift` | descriptor `brandHue` |
| `Views/SessionTerminalView.swift` | descriptor `shortLabel` |
| `Views/Preferences/PreferencesConstants.swift` | K2 — new sources keep keys in their own descriptor |
| `AgentSessionsTests/CodexActiveSessionsRegistryTests.swift` | K11 — aggregation structs are dictionary-keyed, so no new field per source |
| `AgentSessionsTests/SessionParserTests.swift` | same |

That historical edit set still demonstrates the architectural result: lifecycle ownership,
aggregation, search allow-lists, archive dispatch, colors, labels, and enablement no longer
grow another positional parameter or Combine arm for each source.

The Qwen dogfood pass also disproved the old claim that only two shared test files and no
generic seam could change. A complete current source must update the explicit test goldens
listed in §6.B, and a provider-selected environment root may need the source-agnostic
`AvailabilityContext.environment` seam described in §4.4. Those are real contracts, not
hand-wiring, and this guide now names them instead of hiding them in a flattering file count.

The useful acceptance rule is therefore: **no unexplained shared edit and no silent
surface**. Every shared edit must either be one of §6's explicit semantic decisions or a
new generic seam with a hermetic test and a corresponding guide update.
