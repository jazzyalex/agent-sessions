# Qwen integration review — `7da5aca7..8c499ce7`

Read-only review, 2026-08-17. Range: `ef4e9253` (feat: add Qwen and harden session
indexing) + `8c499ce7` (docs: pin Qwen evidence snapshot). 79 files, +6430/−480.

**Verdict: follow-up fixes needed.** The registry program delivered — Qwen's own
integration is disciplined, well-tested and guide-conformant, and the guide honestly
amended itself where it was wrong. But `ef4e9253` bundles two unrelated programs with
Qwen, and the larger of them (DB-backed search identity) ships one reachable crash-class
defect and one hot-path performance regression that affect all thirteen sources.

---

## 1. Guide-conformance tally

| Bucket | Count |
|---|---|
| New files, Qwen-owned | **14** (9 Swift + 5 synthetic fixtures) |
| New files, not Qwen-owned | **3** (contributor-program docs) |
| Modified, enumerated by `docs/adding-a-session-source.md` | **27** |
| Modified, **unenumerated** | **35** |

### Qwen-owned new files (14)

`AgentSessions/Qwen/{QwenCLIEnvironment,QwenResume,QwenSettings,QwenSourceDescriptor}.swift`,
`AgentSessions/Services/{QwenSessionDiscovery,QwenSessionIndexer,QwenSessionParser}.swift`,
`AgentSessions/Views/Preferences/PreferencesView+Qwen.swift`,
`AgentSessionsTests/QwenIntegrationTests.swift`,
`Resources/Fixtures/stage0/agents/qwen/*.jsonl` (5).

### Enumerated shared edits (27) — every one maps to a guide row

- §6.A rows 1–25: `SessionSource.swift` (1) · `SessionSourceRegistry.swift` (2) ·
  `Session.swift` (3, 4) · `CodexSessionImagePayload.swift` (5) ·
  `ImageBrowserIndexCache.swift` (6) · `TranscriptPlainView.swift` (7) ·
  `UnifiedSessionIndexer.swift` (8, 9, 9b) · `UnifiedSessionsView.swift` (9c, 11, 11b,
  12, 13, 14, 15, 16) · `AgentUpdateService.swift` (10) · `PreferencesView.swift`
  (17–22, incl. 19b sidebar + 21b resetToDefaults) · `PreferencesView+General.swift`
  (22) · `AnalyticsDateRange.swift` (23) · `AnalyticsView.swift` (24) ·
  `FirstRunSetupView.swift` (25) — **14 files**
- §6.B sentinels: `WhatsNewCatalog.swift` teaser + `SessionSourceRegistryTests` ·
  `SessionProviderCatalogTests` · `SessionSourceKeyStabilityTests` ·
  `ViewRegistryDerivationTests` · `NewProviderDiscoverabilityTests` ·
  `OnboardingFeedbackTriggerTests` — **7 files**
- §7 pbxproj — **1 file** (all 9 new Swift files registered, 4 lines each)
- §6.D docs: `README.md` · `agent-support-matrix.yml` · `public-agents.json` ·
  `docs/CHANGELOG.md` · `docs/summaries/2026-08.md` — **5 files**

No row was missed. Spot-checks confirm the harder silent-failure rows were honoured:
`TranscriptHostView.coveredSources` gained `.qwen` and a real transcript layer;
`sidebarAgentSources` **and** the frozen `testSidebarAgentTabOrderIsFrozen` literal were
both updated; `resetToDefaults` clears the Qwen binary path and storage root and reprobes.

### Unenumerated shared edits (35) — classified

**(a) Legitimate generic seams the guide missed — guide amended in the same commit (7)**

| File | Why |
|---|---|
| `Model/SessionSourceDescriptor.swift` | `AvailabilityContext.environment` — genuinely required by Qwen (`QWEN_HOME`). Correct call: a source-agnostic seam, not a `.qwen` special case. |
| `Services/AgentEnablement.swift` | passes `ProcessInfo` environment into its in-file context (same seam) |
| `Support/FileProbing.swift` + `AgentSessionsTests/FakeFileProbe.swift` | `UserPathExpansion` + injected-home expansion (Qwen-relevant); the other 4 new probe methods are not (see (b)) |
| `Analytics/Utilities/AnalyticsColors.swift` | `agentColor(for sourceString:)` was a hidden per-source `if lower.contains(…)` chain the registry never absorbed — a real registry gap. **Fixed generically** (rawValue → registry first, legacy aliases preserved, pinned by a new test), so no future source touches it. Exactly the right response. |
| `AgentSessionsApp.swift` | comment-only ("twelve" → "every registered") |
| `docs/adding-a-session-source.md` | the guide amending itself — see §2 |

**(b) Scope creep: separate concern bundled into the same commit — "harden session indexing" (26)**

`Indexing/DB.swift` · `Search/SearchIngestService.swift` · `Search/SearchCoordinator.swift` ·
`Services/SessionDiscovery.swift` · `Services/SessionProviderCatalog.swift` ·
`Model/SessionSourceRegistry.swift` (the `validateIdentityConfigurations` precondition) ·
`OpenCode/{OpenCodeBackendDetector,OpenCodeSqliteReader,OpenCodeSourceDescriptor}.swift` ·
`Services/{OpenCodeSessionDiscovery,OpenCodeSessionIndexer}.swift` ·
`Hermes/HermesSourceDescriptor.swift` · `Services/{HermesSessionDiscovery,HermesSessionIndexer,HermesSessionParser}.swift` ·
`Model/ClaudeSourceDescriptor.swift` · the **12 other source descriptors** (mechanical
`parseFullByIdentity: nil` / `searchUsesIdentityAtURL: nil` / `searchIdentitySnapshots: .notApplicable`) ·
`AgentSessionsTests/{SearchIngestTests,SessionParserTests}.swift`.

Qwen is file-backed (`parseFullByIdentity: nil`). **None of this is required by Qwen** —
roughly 1,100 of the ~1,250 non-Qwen lines are the OpenCode/Hermes SQLite-identity
program. It is real, valuable bug-fix work; it does not belong in the acceptance-test
commit for the registry, where it makes the "what did a 13th source cost?" question
unanswerable from the diff alone.

**(c) Scope creep: a third concern — contributor onboarding + an unrelated copy fix (2 modified + 3 new)**

`docs/CONTRIBUTING.md` (full rewrite) · `docs/guides/openclaw-local-agent-history.html`
(OpenClaw resume copy correction) · new `.github/ISSUE_TEMPLATE/new-agent-source.yml`,
`.github/PULL_REQUEST_TEMPLATE/agent-source.md`, `docs/prompts/add-an-agent-source.md`.

**Red flags: none.** No unenumerated shared edit is a `.qwen` special case bypassing the
registry, and no `default:` was reintroduced into any `SessionSource` switch. (The three
`default:` arms added in the range are all local to `QwenSessionParser.swift` — a byte
scanner and a record-type dispatch.)

---

## 2. The guide's own accuracy — it passed, by retracting

The guide was rewritten in the same commit and the changes are honest, not cosmetic. It
deleted the claims Qwen falsified:

- §1 obligation 6 "**Zero unenumerated shared edits**" → "**Zero un*explained* shared
  edits**", with the `AvailabilityContext.environment` case named as the worked example
  and a standing rule: smallest source-agnostic seam + hermetic test + guide amendment.
- §8's flattering file count ("a complete port is 20 files… 2 test files") is gone,
  replaced by an explicit retraction naming the Qwen pass as the disproof.
- §1 gained two obligations it was missing: source-local fixtures/tests, and §6.D docs.
- §6.B gained four sentinels that really do fire (`testRuntimeIdentitySnapshotCapabilityMatchesDescriptor`,
  the frozen palette/badge/label/shortcut goldens, the sidebar-order literal, the release teaser).
- §4.4 gained the environment-root rule; §5 gained the whole DB-backed identity recipe.

This is the right behaviour and the most valuable outcome of the exercise.

**Guide nits:** the header still says "this no-commit working pass deliberately does not
invent one" — the work is now committed as `ef4e9253`, so that provenance line is stale.
§2 still says "the shipped version is 4.8", which is correct today but is the kind of line
that rots.

---

## 3. Registry-contract compliance for Qwen — clean

- **Keys** follow the frozen conventions exactly and live in the descriptor file, not
  `PreferencesConstants.swift`: `AgentEnabledQwen` / `QwenCLIAvailable` /
  `QwenSessionsRootOverride` / `IncludeQwenSessions`. `SourceKeyTable.rows` gained the row
  and each string is asserted individually.
- **`versionIntroduced: "4.9"`** — correct. `MARKETING_VERSION` is 4.8, so 4.9 is the real
  upcoming release; `"99.0"` was not used; the 4.9 `WhatsNewCatalog` teaser was added and
  pinned by a new test that also asserts the generated highlight row.
- **Goldens updated with real values**, not placeholders: brand accent aqua/darkAqua
  quadruples, pill colors, `badgeInitials: "QW"`, `shortLabel: "Qwen Code"`,
  `monochromeWhite: 0.61`, `shortcut: nil`. The shortcut golden also gained a
  completeness assertion against `allCases`.
- **Registry order** test updated; `.qwen` is last, matching `allCases`.
- **K16 intact** — the catalog gained no `@Published` member; its silence tests are unchanged.
- **No `AvailabilityContext.live()` callers introduced** (the only two mentions in the tree
  remain explanatory comments).
- **ProviderHandle closures capture only the local `indexer`** — no `self`, no catalog, no
  view. `deinit` safety preserved.
- **Exhaustive switches** all gained a real `.qwen` arm, including the three image switches,
  the inline-image gate, `passesHasCommandsFilter`, `canResumeSession`, `resume(_:)`, and
  the three `@AppStorage` consumers.
- **Colors stay lazy** — `onboardingAccent` is a closure, `PillSpec.color` an autoclosure
  routed through `SessionSourceRegistry.resolvedBrandAccent(for: .qwen)`. No `swift_once`
  re-entrancy hazard.

---

## 4. Findings by severity

### Critical

- **C1 — Reachable `fatalError` in `QwenSessionParser`: a malformed hook-context part
  crashes the whole indexing pass.** `QwenSessionParser.swift:529-531`. `prefix` is 34
  characters and `suffix` 35; a part whose text is exactly
  `<qwen:user-prompt-submit-context>\n</qwen:user-prompt-submit-context>` (68 chars — the
  newline is shared) satisfies **both** `hasPrefix` and `hasSuffix`, giving
  `bodyStart = 34 > bodyEnd = 33` and `Fatal error: Range requires lowerBound <= upperBound`.
  Reached from the lightweight scan path (`userDisplayText` → `build()` →
  `parseFile`), so it takes down the indexing pass, not just one session. Fix: guard
  `trimmed.count >= prefix.count + suffix.count` before forming the range. The existing
  malformed/nested-wrapper test (`QwenIntegrationTests.swift:94-144`) covers everything
  except the empty body.

- **C2 — `LIMIT -1` on every production FTS query.** `DB.swift:2318` and `:2401` set
  `sqlLimit = eligibleSessionIDs == nil ? limit : -1`, but `SearchCoordinator.swift:348`
  always passes a non-nil `Set`, so the SQL `LIMIT` is disabled on the app's hottest path
  for all thirteen sources. SQLite can no longer use its bounded top-N sorter for
  `ORDER BY bm25(...)`; it must materialize and fully sort every matching row before the
  first `sqlite3_step` returns, so the Swift-side `ids.count == limit` early return cannot
  save it. Unbounded work and sorter memory on large corpora, introduced for a currency
  problem only OpenCode and Hermes have. Keep the SQL `LIMIT` (or paginate with the
  `offset` parameter that was added alongside it).

### Important

- **I1 — Three unrelated programs in one commit.** `ef4e9253` is Qwen + the DB-identity
  search hardening (~1,100 lines, zero Qwen dependency) + the contributor-onboarding docs
  program + an OpenClaw copy correction. This defeats the commit's own purpose as the
  registry acceptance test and makes bisection of the search changes impossible.
- **I2 — `precondition` in `static let` initializers ships a launch crash.**
  `SessionSourceRegistry.swift:57` and `SessionProviderCatalog.swift:66`. `precondition`
  is not stripped at `-O`, so a descriptor misconfiguration becomes an unrecoverable crash
  for users. The invariant is compile-time-constant and already fully covered by
  `testRuntimeIdentitySnapshotCapabilityMatchesDescriptor`; `assert` gives identical
  coverage without shipping the trap.
- **I3 — Broad identity deletion path guarded only by nil-vs-empty discipline.**
  `DB.swift:2031-2071`: `staleIDs = persisted.subtracting(allCurrentIDs)`. The only thing
  preventing a transient SQLite read failure from wiping a user's whole OpenCode or Hermes
  corpus is `listSessionsIfReadable` returning `nil` rather than `[]`.
  `OpenCodeSessionIndexer.swift:187-211` weakens it by synthesizing `.authoritativeEmpty`
  on the legacy-JSON and no-backend branches from a bare `FileManager.fileExists`. Also,
  `deleteSessionsByIdentity` is `internal` and starts no transaction of its own — it is
  safe only because of where it is called from.
- **I4 — Analytics schema migration forces a full re-derive for every existing user, with
  no version guard.** `session_days.meta_size` (`DB.swift:239`, `:453-465`). The
  `schema_migrations` marker handles forward migration adequately, but there is no
  `user_version` bump and no downgrade guard, the migration is not wrapped in a
  transaction, and an `IndexDB()` init throw is swallowed by `try?` at
  `SearchCoordinator.swift:19` — a failed migration silently disables search.
- **I5 — The 50 MB parse guard is dead in production.**
  `QwenSessionParser.swift:89,133` define it, but `parseFile` (`:118`) and
  `QwenSessionIndexer.reloadSession` (`:217`) both pass `allowLargeFile: true`. No call
  site takes the guarded path, so an arbitrarily large transcript is fully materialized
  (records + every raw line's `rawJSON`).
- **I6 — Qwen was not wired into the session-format audit pipeline.**
  `docs/agent-support/agent-watch-config.json` lists 11 agents and Qwen is the only public
  agent missing; `scripts/agent_watch.py` has zero Qwen references. Self-declared in the
  matrix (`unsupported_surfaces: weekly session-format monitoring`), so it is a knowing
  gap — but `monitoring.md:20` still says "all 11 active agents" and `update-checklist.md`
  was not updated, so nothing outside the matrix records that the newest source is
  unmonitored for drift.
- **I7 — `session_search.mtime` now carries two units.** Seconds for file sources,
  milliseconds for identity sources (`SearchIngestService.swift:509-523`). The DB-level
  `indexedSessionIDsCurrent` / `indexedToolIOSessionIDsCurrent` predicates therefore never
  mark an identity row current; `SearchCoordinator.swift:304-315` compensates. The
  DB-level predicate is now silently wrong for identity sources — a trap for any future caller.
- **I8 — Evidence claims are stronger in code comments than in the pinned snapshot.** The
  matrix sets `max_verified_version: "0.14.3"` and states plainly that 0.21.13 was
  authentication-blocked, yet `QwenSessionParser.swift:517`, `QwenSessionDiscovery.swift:42`
  and `QwenCLIEnvironment.swift:8` each say "exactly" / "verified locally against 0.21.13".
  Only the `--help` surface was observed at 0.21.13; the display-projection and filename-
  pattern claims rest on reading upstream source. README/CHANGELOG/matrix/summary are
  otherwise consistent about the untested-resume limitation — good discipline, undercut by
  the comments.

### Minor

- **M1 — `IngestAggregate` now retains a full per-file snapshot per source for the process
  lifetime** (`SearchIngestService.swift:88-104`), replacing three scalars. Tens of MB at
  50k sessions, plus an O(n) `Equatable` compare per kick — paid by all sources for a
  change two need.
- **M2 — Hermes lost `.skipsHiddenFiles`.** `FileProbing.contentsOfDirectory` passes
  `options: []` (`FileProbing.swift:74-80`), so dot-files under `~/.hermes/sessions` are
  now enumerated.
- **M3 — O(n²) line assembly on a newline-free file.** `QwenSessionParser.swift:261-266`
  rescans a growing buffer after each 64 KB append; `QwenJSONL.objects` then makes two more
  copies of the line. `QwenSessionDiscovery.hasValidHead:135` bounds itself at ~1 MB; the
  parser does not.
- **M4 — `AvailabilityContext.environment` defaults to `[:]`** (`SessionSourceDescriptor.swift:106`).
  Any memberwise caller that omits it silently makes `QWEN_HOME` invisible. Only `.live()`
  supplies it.
- **M5 — Undocumented root widening.** `QwenSessionDiscovery.normalizedProjectsRoot:92-100`
  falls back to scanning the supplied root itself when it has no `projects/` child, so
  `QWEN_HOME=~/foo` recursively scans `~/foo`. Not stated in the matrix.
- **M6 — README puts the Qwen bullet under a "New in 4.8:" heading** while Qwen is 4.9.
- **M7 — `matrix: version_field: "record.version"` is never read** — the parser ignores
  the `version` key entirely.
- **M8 — Stale doc comments.** `FileProbing.swift:10-25` still says "Both users below" with
  a 6-method protocol and many callers. `SessionSourceKeyStabilityTests`'s cross-pin
  degraded to `XCTAssertEqual(SourceKeyTable.include.count, allCases.count)` — a tautology
  now that both sides derive from `rows` (the per-string freezing is preserved elsewhere,
  so this is cosmetic).

### Not findings — verified clean

- **Privacy: clean.** All 5 fixtures are fully synthetic (`019f0000-…` UUIDs,
  `/tmp/as-qwen-fixture/*` cwds, `synthetic-*` models, self-describing text). A sweep of
  the whole range for `/Users/`, `sk-`, `api_key`, `Bearer`, `token"`, `password`, `secret`
  returns one hit: the new CONTRIBUTING checklist forbidding exactly those. The retained
  local 0.14.3 transcript referenced by the matrix is **not** committed anywhere.
- **Tests: genuine pins, not tautologies.** 26 Qwen methods plus ~15 elsewhere (~41
  functions; the "~47" figure counts assertions/cases). All 5 fixtures are exercised —
  none dead. Assertions are literal event-kind arrays, exact golden shell commands, exact
  tool inputs and counts. Adversarial coverage is real: glued `}{` objects with junk
  adjacency, cyclic `parentUuid`, dangling parent, missing key, unknown record type,
  filename/`sessionId` mismatch. Weakest tier is the three `QwenSettings` probe-staleness
  tests, which re-derive expectations from the API under test. **Uncovered:** truncated
  files, non-UTF8 bytes, the oversized thresholds, and — the one that matters — the empty
  hook-context wrapper of C1. Note `SessionParserTests.swift`'s +983 lines in this range
  are entirely OpenCode/SQLite work, not Qwen.
- **Matrix ↔ parser: accurate** on every behavioural claim checked — glued-object
  recovery, repeated-UUID fragment aggregation in physical order, active parent-chain
  reconstruction with cycle/gap breaks, artifact exclusion from leaf/cwd/counts,
  `systemPayload.displayText` precedence, `goal_runtime`/`cron`/`notification` demoted to
  `.meta`, no image/subagent/live support, resume restricted to
  `projectsRoot/<project>/chats/<id>.jsonl` with archives browse-only, renamed copied roots
  browse-only.

---

## 5. Did the registry program deliver?

Yes, for the part it promised. Qwen's own integration cost 14 new files and 27 enumerated
shared edits, every one of them a guide row — no source-specific edit leaked into shared
code, no `default:` came back, and the one genuine gap Qwen found
(`AvailabilityContext.environment`) was closed as a source-agnostic seam with a hermetic
test and a guide amendment rather than a `.qwen` special case. The guide's retraction of
its own "zero unenumerated edits / 20 files / 2 test files" claims is the honest result of
a real acceptance test.

What the commit does not demonstrate is *cost*, because 35 unenumerated shared edits sit in
the same commit and only 7 of them have anything to do with Qwen. The next source's
acceptance test should land alone.

---

## 6. Suggested follow-ups, in order

1. Fix **C1** (length guard + a regression test for the empty wrapper).
2. Fix **C2** (restore the SQL `LIMIT`, or paginate with the existing `offset`).
3. Downgrade **I2**'s two `precondition`s to `assert`.
4. Harden **I3**: make `deleteSessionsByIdentity` private or transaction-asserting, and
   tighten the OpenCode `.authoritativeEmpty` synthesis on the non-SQLite branches.
5. Decide **I6**: either add Qwen to `agent-watch-config.json`, or record the exclusion in
   `monitoring.md` and `update-checklist.md` so the matrix is not the only place it exists.
6. Soften the three "verified/exactly 0.21.13" code comments to match the pinned evidence (**I8**).
7. Housekeeping: **I5**, **M2**, **M4**, **M6**, and the stale guide provenance line.
