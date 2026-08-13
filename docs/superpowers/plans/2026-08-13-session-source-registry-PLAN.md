# Session Source Registry — collapsing the per-source integration tax

Date: 2026-08-13
Status: in progress
Trigger: PR #55 (Grok) merged as `0da1075a`; PR #56 (Devin) open and colliding.

## Why

Adding a session source costs ~1,000 lines of genuinely new, source-specific code
(parser, discovery, indexer, settings, CLI environment, resume stack) — that part is
honest work and stays as it is.

It *also* costs **44 hand-edited switch arms across 14 shared files**. That half is
pure tax, and it is what makes two contributor PRs collide:

| | |
|---|---|
| Files touched by both #55 and #56 | **26** |
| `case .<source>:` arms per new source | **44** |
| `UnifiedSessionIndexer.swift` | **2,945 lines** |

The codebase has already diagnosed this locally. `AgentEnablement.allEnablementKeys`
carries the comment: *"Observers must use this rather than listing keys by hand: the
hand-written lists drifted every time a provider was added, and a missed key means
toggling that agent silently leaves dependent state stale."* Three call sites there
already derive from `SessionSource.allCases`. This plan generalizes that fix to the
rest of the integration surface.

## The tax is not hypothetical — #55 paid it and still lost

Mapping the surface turned up **three hand-maintained source lists that were already
silently incomplete on `main`**, two of them gaps in the freshly merged Grok work.
None of them failed a build or a test.

1. **Grok was missing from `AnalyticsSourceSupport.sources`.** #55 wired Grok into
   `AnalyticsService`, `AnalyticsColors` and `AnalyticsView` — three of the four
   required edits — but missed the one `Set<SessionSource>` that gates
   `enabledAnalyticsSources()`. Grok sessions would never have entered an analytics
   build. Fixed, along with the required `AnalyticsAgentFilter.grokOnly` case.
2. **Grok was missing from the General tab's "Active CLI agents" list**
   (`PreferencesView+General.swift`), so it could only be toggled from its own
   Preferences tab, and it was absent from the `enabledCount` that backs the
   "can't disable your last agent" guard. Fixed.
3. **`AnalyticsAgentFilter` has no `cursorOnly`** and Cursor is absent from
   `AnalyticsSourceSupport.sources`. Left alone deliberately — this predates Grok and
   may be intentional for DB-backed sources. Now recorded as an explicit exclusion
   rather than an invisible omission.

Added `testEverySourceIsEitherAnalyticsSupportedOrExplicitlyExcluded`, which closes
the reverse direction the existing pairing test never checked. A new source must now
declare which side it is on.

The pattern: the compiler-enforced switches all got updated correctly. Every failure
was a `Set`, an array literal, or a `&&` chain — the shapes the compiler cannot check.
That is the precise line the registry needs to move things across.

## What is NOT changing

- Per-source parsers, discoveries, indexers, settings, CLI environments, resume
  builders. These are already cleanly separated and are the legitimate cost of a
  source.
- `SessionSource` remains an enum (it is `Codable` and persisted by `rawValue` in
  UserDefaults, the search index, and archive folder names — it cannot become a
  struct without a data migration).
- No behavior change. Every increment must leave build + tests green.

## The shape

A `SessionSourceAdapter` descriptor bundles everything the app currently reaches
into via a switch. `SessionSourceRegistry.all` is the single ordered array;
`SessionSource` keeps its `rawValue` identity and gains a `var adapter` lookup.

Capability surface, derived from what the existing switches actually need:

- **Identity** — displayName, iconName, versionIntroduced, featureDescription
- **Palette** — brand color, monochrome color, onboarding palette token
- **Storage** — root-override UserDefaults key, discovery factory, indexer factory
- **Detection** — binary names, CLI-available key, custom availability probe
  (Grok's `~/.grok` requirement, Cursor's chats root, Droid's projects root,
  OpenCode's SQLite detector all live here as closures, not special cases)
- **Enablement** — enablement key, default-on vs default-on-if-available
- **Parsing for search** — `parseFull(url:) -> Session?`
- **Archiving** — backfill URL resolution + session resolution

## The two capabilities Devin (#56) proves are needed

PR #56 stores every session as rows in one shared 5.4 GB SQLite database, which
breaks two assumptions baked into the current switches:

1. **`SessionArchiveManager` maps session id → upstream path.** Devin has no
   per-session path, so archiving must be expressible as *unsupported*, not as a
   switch arm that fakes a path.
2. **`SearchIngestService.parseFileFull(url:source:)` identifies a session by
   path.** For Devin every session shares one path, so the adapter must be able to
   decline path-based parsing and route through the forced-id channel.

Both become optional adapter members with defaults, so a file-per-session source
says nothing and a database-backed source opts out explicitly. Designing these in
now is why #56 should land *after* the refactor rather than before it.

## Constraints found while prototyping the descriptor table

A full 12-source descriptor table was drafted against the real switches to test whether
the shape holds. It does, but reality is less uniform than the shape suggests, and each
of these has to be modelled rather than assumed:

- **Two sources have no `PreferencesKey` constant for their root override.**
  `AgentEnablement.isAvailable` reads the bare literals `"SessionsRootOverride"` (codex)
  and `"AntigravitySessionsRootOverride"` (antigravity). Both need constants added before
  the registry can reference keys by name.
- **Droid has two root keys** (sessions *and* projects), so the field must be a
  collection or the descriptor needs a second slot.
- **OpenClaw has no CLI-available key at all** — `storedBinaryPresence` returns `nil`
  outright — and has an unrelated `openClawBinaryOverride` (a binary *path*, not a root).
- **Binary detection is not reducible to a name list.** Grok additionally requires
  `~/.grok` to exist (the Homebrew `grok` formula is an unrelated regex tool), Cursor
  checks a second chats root, OpenCode probes a SQLite backend, Droid checks a projects
  root. These must be closures on the descriptor, not data.
- **Brand color has two distinct forms.** Ten sources are hand-tuned RGB triples wrapped
  in `adaptiveBrand(_:)`; antigravity and opencode pass system dynamic colors through
  *unwrapped*. Flattening this to a single `NSColor` field would silently change how two
  sources render in dark mode.
- **`isEnabled` and `seedIfNeeded` disagree for droid** — seed-time uses availability,
  runtime default is unconditionally `true`. The registry must not quietly pick one.
- **`seedIfNeeded`'s last-resort fallback pins `.codex` specifically**, not "the first
  registered source". It must stay pinned, not become `allCases.first`.
- **UserDefaults keys cannot be generated from `rawValue`.** Existing users have literal
  `"AgentEnabledKimi"`, `"GrokCLIAvailable"` etc. already persisted; generating them would
  silently reset every per-source preference on upgrade. Keys stay as referenced
  constants, with a test asserting each descriptor's key equals its historical string.

The draft itself is deliberately **not** committed. Unwired, it would be a second copy of
data the switches still own — two sources of truth is worse than one bad one. It lands
together with increment 2, which deletes the switches it replaces.

## Increments

Each step ends with `xcodebuild build` + the affected tests green before the next
one starts. Work happens on `main`, uncommitted, for the owner to review and commit.

1. **Scaffolding** — adapter protocol + registry + 12 descriptors. Purely additive;
   no existing call site changes. Verifies the descriptor shape compiles against all
   12 real sources before anything depends on it.
2. **Identity + palette** — `SessionSource`'s four metadata switches,
   `TranscriptColorSystem`, `AnalyticsColors`, `OnboardingPalette` read from the
   registry. 4 files.
3. **Detection + enablement** — `AgentEnablement`'s five switches collapse to
   registry fields plus per-source probe closures. 1 file, the highest arm count.
4. **Search + archive** — `SearchIngestService.parseFileFull` and
   `SessionArchiveManager`'s two backfill switches become adapter calls. This is
   where the Devin capabilities land. 2 files.
5. **UnifiedSessionIndexer** — the hard one. Twelve named indexer properties become
   a keyed collection; twelve duplicated reload blocks become one loop; the
   incrementally nested `.combineLatest($includeKimi)` chain and the
   `effectiveCodex && … && effectiveGrok` conjunction become registry-derived.
   Highest risk: Combine arity, `@Published` identity, `@MainActor` isolation.
6. **Views** — `UnifiedSessionsView`, `PreferencesView`, `FirstRunSetupView`,
   `OnboardingComponents`, `SessionTerminalView` iterate the registry. Per-source
   Preferences panes stay as separate view files, referenced by the descriptor.

## Definition of done

A thirteenth source is: one folder of source-specific files, one registry entry,
one pbxproj update. No shared-file edits. Verified by rebasing #56 onto the result
and measuring its shared-file count — target is the pbxproj and the registry only.

## Open items carried from #55

- `agent-support-ledger.yml` has no Grok entry. Deliberately not authored here: the
  ledger records *verified at version X on date Y* and is the owner's attestation.
  Release-time item.
- README "New in 4.8" section is the owner's voice; not written.
- `versionIntroduced: "4.8"` confirmed correct — `MARKETING_VERSION` is 4.7.
