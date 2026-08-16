# Session Source Registry & Provider Catalog Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task.
> Steps use checkbox (`- [ ]`) syntax for tracking.
> Read `2026-08-14-session-source-registry-SPEC.md` (rev 2) first — this plan implements
> it and cites its constraints as K1…K16 and behavior changes as §8.x.

**Goal:** One source-local adapter per agent (value data + runtime factory) behind a
single registry and a lifecycle-owning provider catalog, so a 13th source needs only its
folder, its `SessionSource` case, one registry entry, one pbxproj edit, and the
enumerated semantic switch arms — zero unenumerated shared edits.

**Architecture:** `SessionSourceDescriptor` (value data, no identity fields) +
`SessionSourceAdapter.makeRuntime` → `SourceRuntime` (indexer + `ProviderHandle` +
`SearchSessionStore.Adapter`) + `SessionProviderCatalog` (one `@StateObject`, publishes
nothing post-init — K16). `SessionSource` and its metadata switches are untouched (K15).
Task 0 is a throwaway spike that proves the shape (fake 13th source) before migration.

**Tech Stack:** Swift 6 / SwiftUI / AppKit / Combine, XCTest (app + standalone logic
targets), xcodebuild.

## Global Constraints

- UserDefaults key strings FROZEN — never derived from `rawValue` (K1).
- `SessionSource.swift` is NOT modified — it compiles into the standalone
  `AgentSessionsLogicTests` target (pbxproj `3B12369C…`); no file compiled by that target
  (`Session.swift`, `FilterEngine.swift`, parsers — check pbxproj before flipping ANY
  file) may reference registry/adapter/catalog types (K15).
- `ProviderHandle` is nested inside `UnifiedSessionIndexer` (its closure signatures use
  private nested `FocusedReloadTrigger` — real name, verified `:95`). Handle closures
  capture concrete indexer instances only — NEVER `self`, never the catalog — so
  `deinit` (`:2979`) keeps running. Enablement guards live at call sites.
- All descriptor detection closures take `AvailabilityContext` (defaults + `FileProbing`
  + home dir + binary detect) — no `FileManager.default` inside closures (K5).
- Droid enablement disagreement preserved (K7); `seedIfNeeded` fallback stays `.codex` (K8).
- Brand color keeps `.calibrated`/`.system` forms (K6). ⌘-shortcuts transcribed, never
  derived (K10). Catalog publishes nothing post-init (K16).
- Every task ends: `xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug build`
  then `./scripts/xcode_test_stable.sh` — both green before the next task.
- New Swift files added via `scripts/xcode_add_file.rb` (4 pbxproj lines per file; new
  app-target files must NOT be added to the logic-tests target).
- Commits: Conventional Commits, no Claude co-author; **only at owner-approved
  checkpoints** — each task ends with report + approval request, never an autonomous commit.
- Behavior changes: ONLY SPEC §8.1–8.5; §8.6–8.8 explicitly preserved.
- Do not touch: `CodexActiveSessionsModel`, `AgentCockpitHUDView`,
  `CodexSessionImagesGalleryView`, live-session subsystem. `Session.computeIsHousekeeping`
  and the image-scanning switches keep their SEMANTICS untouched — the only permitted
  edit is Task 8 Step 2b's `default:`→exhaustive conversion (existing arms verbatim).

---

### Task 0: Architecture spike — prove the catalog shape with a fake 13th source

> **✅ COMPLETE (2026-08-15).** Executed on branch `spike/source-catalog` (@ `fde3c215`,
> kept as reference; worktree removed). Report: `2026-08-14-task0-spike-REPORT.md`.
> Gate outcome: SPEC §3 NOT falsified (two amendments applied); §6 rewritten from the
> forced-edit table; Tasks 6/7 reordered. Executing workers: do NOT re-run this task —
> resume at Task 1.

**Files (all throwaway — spike branch in an owner-approved worktree, deleted after):**
- Create: minimal `SessionSourceAdapter`/`SourceRuntime`/`SessionProviderCatalog`
- Create: `AgentSessions/Model/FakeSourceSpike/` — a deliberately minimal 13th source
  (fake `SessionSource` case `zzfake`, no-op parser/discovery/indexer conforming to the
  de-facto indexer surface)
- Produce (the ONLY merged artifact): `docs/superpowers/plans/2026-08-14-task0-spike-REPORT.md`

**Interfaces:**
- Produces: the verified, complete list of shared edits the fake source required —
  this list becomes the guide's enumerated-edits section and may adjust SPEC §6.

- [ ] **Step 1: Get owner approval** for a spike worktree (repo rule: no branches/worktrees
  without approval). `git worktree add ../Codex-History-spike -b spike/source-catalog`.
- [ ] **Step 2: Build the skeleton** — catalog + adapter structs per SPEC §3.2/3.3, wired
  for TWO real sources (codex, grok — oldest/newest) plus the fake source. Migrate ONE
  consumer path end-to-end: `AgentSessionsApp` constructs the catalog;
  `AnalyticsService` (smallest 12-param consumer) takes it.
- [ ] **Step 3: Add the fake source** and record EVERY file the compiler/tests force you
  to touch. Expected per SPEC §6: `SessionSource.swift` case + 4 metadata arms,
  `passesHasCommandsFilter`, 6 image switches, `storesAuthoritative*` (2),
  resume dispatchers (2), `TranscriptHostView` layer + `coveredSources`,
  `PreferencesTab` + mapping, registry entry, pbxproj. Anything OUTSIDE that list is a
  finding that must be either migrated by a later task or added to the enumerated list.
- [ ] **Step 4: K16 check** — with the catalog as `@StateObject`, verify (Instruments or
  `Self._printChanges()`) that toggling one source's include flag does not invalidate
  `AgentSessionsApp.body` or unrelated views any more than today.
- [ ] **Step 5: Write the report** (findings, adjusted enumerated list, go/adjust on §3
  shapes, K16 result). Delete the worktree. Checkpoint: commit the REPORT only —
  `"docs(spike): source-catalog architecture findings; enumerated 13th-source edit list"`
- [ ] **STOP: review gate.** If the spike falsifies a SPEC §3 shape, revise SPEC before
  Task 1 proceeds.

---

### Task 1: Freeze the key surface (constants for every bare literal)

**Files:**
- Modify: `AgentSessions/Views/Preferences/PreferencesConstants.swift` (Paths enum ~L153-166; new `Include` enum)
- Modify: `AgentSessions/Services/AgentEnablement.swift:239-307`
- Modify: `AgentSessions/Services/SessionArchiveManager.swift:370-483`
- Modify: `AgentSessions/Views/PreferencesView.swift:200,211`
- Modify: `AgentSessions/CodexStatus/CodexStatusService.swift` (bare `"SessionsRootOverride"`)
- Modify: `AgentSessions/Services/UnifiedSessionIndexer.swift:592-663` (12 `didSet` literals)
- Test: `AgentSessionsTests/SessionSourceKeyStabilityTests.swift` (new; app test target ONLY)

**Interfaces:**
- Produces: `PreferencesKey.Paths.codexSessionsRootOverride == "SessionsRootOverride"`,
  `PreferencesKey.Paths.antigravitySessionsRootOverride == "AntigravitySessionsRootOverride"`,
  `PreferencesKey.Include.codex…grok` (12 constants). Task 2 references named constants only.

- [ ] **Step 1: Write the failing full-table key-stability test** (SPEC §10.2 — all 12
  sources × every key kind, 48 literal assertions, no sampling). Before writing, confirm
  each literal against the live code (`grep -n '"Include' AgentSessions/Services/UnifiedSessionIndexer.swift`;
  the code is the truth, not this plan). Shape:

```swift
import XCTest
@testable import AgentSessions

/// K1/K2: every persisted key keeps its historical string forever. A failure here means
/// users' per-source preferences would silently reset on upgrade.
final class SessionSourceKeyStabilityTests: XCTestCase {
    // One row per source: (source, enablement, cliAvailable, rootOverrides, include)
    private let table: [(SessionSource, String, String?, [String], String)] = [
        (.codex, "AgentEnabledCodex", "CodexCLIAvailable", ["SessionsRootOverride"], "IncludeCodexSessions"),
        (.claude, "AgentEnabledClaude", "ClaudeCLIAvailable", ["ClaudeSessionsRootOverride"], "IncludeClaudeSessions"),
        (.antigravity, "AgentEnabledAntigravity", "AntigravityCLIAvailable", ["AntigravitySessionsRootOverride"], "IncludeAntigravitySessions"),
        (.opencode, "AgentEnabledOpenCode", "OpenCodeCLIAvailable", ["OpenCodeSessionsRootOverride"], "IncludeOpenCodeSessions"),
        (.hermes, "AgentEnabledHermes", "HermesCLIAvailable", ["HermesSessionsRootOverride"], "IncludeHermesSessions"),
        (.copilot, "AgentEnabledCopilot", "CopilotCLIAvailable", ["CopilotSessionsRootOverride"], "IncludeCopilotSessions"),
        (.droid, "AgentEnabledDroid", "DroidCLIAvailable", ["DroidSessionsRootOverride", "DroidProjectsRootOverride"], "IncludeDroidSessions"),
        (.openclaw, "AgentEnabledOpenClaw", nil, ["OpenClawSessionsRootOverride"], "IncludeOpenClawSessions"),
        (.cursor, "AgentEnabledCursor", "CursorCLIAvailable", ["CursorSessionsRootOverride"], "IncludeCursorSessions"),
        (.pi, "AgentEnabledPi", "PiCLIAvailable", ["PiSessionsRootOverride"], "IncludePiSessions"),
        (.kimi, "AgentEnabledKimi", "KimiCLIAvailable", ["KimiSessionsRootOverride"], "IncludeKimiSessions"),
        (.grok, "AgentEnabledGrok", "GrokCLIAvailable", ["GrokSessionsRootOverride"], "IncludeGrokSessions"),
    ]
    func testEverySourceKeyKeepsItsHistoricalString() {
        XCTAssertEqual(table.map(\.0), SessionSource.allCases, "table must cover every source, in order")
        for (source, enablement, _, _, _) in table {
            XCTAssertEqual(AgentEnablement.enablementKey(for: source), enablement, "\(source)")
        }
        // Include constants frozen DIRECTLY — no production key(for:) mapping exists or
        // may be added (it would be a new permanent 12-arm shared switch, violating K2's
        // "new keys stay source-local"). One assertion per constant:
        XCTAssertEqual(PreferencesKey.Include.codex, "IncludeCodexSessions")
        XCTAssertEqual(PreferencesKey.Include.claude, "IncludeClaudeSessions")
        // …all 12, values from the table above.
        // Root-override and CLI-available constants asserted individually the same way:
        XCTAssertEqual(PreferencesKey.Paths.codexSessionsRootOverride, "SessionsRootOverride")
        XCTAssertEqual(PreferencesKey.Paths.antigravitySessionsRootOverride, "AntigravitySessionsRootOverride")
        // …one line per remaining constant, values from the table above.
    }
}
```

  The `table` is the tests' shared source of truth — expose it as
  `enum SourceKeyTable { static let include: [SessionSource: String] … }` in the test
  target so Task 2's registry test reuses it. NO `key(for:)` switch is added to
  production code (reviewer erratum 1); a 13th source adds one row to this table, which
  the guide lists as a test-sentinel edit alongside `coveredSources`.
- [ ] **Step 2: Run — FAIL** (missing constants/members).
- [ ] **Step 3: Add the constants** (`Paths.codexSessionsRootOverride`,
  `Paths.antigravitySessionsRootOverride`, `enum Include` with 12 statics — NO
  `key(for:)` mapping, see Step 1).
- [ ] **Step 4: Repoint every bare literal** (values identical → zero behavior change).
  The full file list (verified by grep 2026-08-15, reviewer erratum 2 — the original
  four-file list was incomplete): `AgentEnablement.swift` (L249/252/257/260),
  `SessionArchiveManager.swift` (L383/395/407), `PreferencesView.swift` (L200/211),
  `CodexStatusService.swift`, `UnifiedSessionIndexer.swift` (**both** the init read AND
  the `didSet` write of all 12 include properties — 24 literals, L592-663),
  `SessionIndexer.swift`, `ClaudeSessionIndexer.swift`, `OpenCodeSessionIndexer.swift`,
  `PresenceEngine.swift`, `CodexActiveSessionsModel.swift`.
  **K15 guard per file:** before repointing a file, check its target membership
  (`grep '<filename> in Sources' AgentSessions.xcodeproj/project.pbxproj`); a file also
  compiled by `AgentSessionsLogicTests` must NOT gain a `PreferencesKey` reference —
  leave its literal with a `// K15: literal stays; constant lives in PreferencesConstants`
  comment and list it in the task report.
  Verify sweep: `grep -rn '"SessionsRootOverride"\|"AntigravitySessionsRootOverride"\|"ClaudeSessionsRootOverride"\|"OpenCodeSessionsRootOverride"\|"Include[A-Z][A-Za-z]*Sessions"' AgentSessions/`
  → hits only in `PreferencesConstants.swift` plus any K15-exempted files from the guard
  above (each carrying its comment).
- [ ] **Step 5: Build + tests green.**
- [ ] **Step 6: Checkpoint** — `"refactor(prefs): name every per-source UserDefaults key; freeze strings with a stability test"`

---

### Task 2: Registry scaffolding — descriptors, bijection/order test, parity harness

**Files:**
- Create: `AgentSessions/Model/SessionSourceDescriptor.swift` (`BrandHue`,
  `EnablementDefault`, `PillSpec`, `ArchiveCapability`, `AvailabilityContext`,
  `SessionSourceDescriptor`) — app target only (K15)
- Create: `AgentSessions/Model/SessionSourceRegistry.swift`
- Create: 12 descriptor files in each source's folder (fall back to `Model/` where no
  folder exists — codex, claude, antigravity, openclaw; verify with `ls AgentSessions/`)
- Test: `AgentSessionsTests/SessionSourceRegistryTests.swift` (new)

**Interfaces:**
- Produces (types per SPEC §3.1; identity fields deliberately ABSENT — consumers keep
  using `source.displayName` etc., K15):

```swift
struct AvailabilityContext {
    let defaults: UserDefaults
    let fileProbe: FileProbing
    let homeDirectory: URL
    let detectBinary: (String) -> Bool
    @MainActor static func live() -> AvailabilityContext   // production seams
}
struct SessionSourceDescriptor {
    let source: SessionSource
    let shortLabel: String; let badgeInitials: String
    let brandHue: BrandHue; let monochromeWhite: Double
    let onboardingAccent: (OnboardingPalette) -> Color
    let enablementKey: String; let cliAvailableKey: String?
    let rootOverrideKeys: [String]; let includeKey: String
    let binaryNames: [String]
    let isBinaryInstalled: (AvailabilityContext) -> Bool
    let isAvailable: (AvailabilityContext) -> Bool
    let defaultEnabled: EnablementDefault
    let parseFullByPath: ((URL) -> Session?)?          // nil = DB-backed (Devin)
    let archive: ArchiveCapability?                    // nil = unsupported (Devin)
    let supportsResume: Bool; let resumeAgentLabel: String?
    let otherAgentPill: PillSpec?                      // nil = codex/claude
}
enum SessionSourceRegistry {
    static let ordered: [SessionSourceAdapter]          // Task 2: adapter = descriptor only;
    static func descriptor(for source: SessionSource) -> SessionSourceDescriptor
    static func adapter(for source: SessionSource) -> SessionSourceAdapter
}
struct SessionSourceAdapter { let descriptor: SessionSourceDescriptor }  // makeRuntime added in Task 6
```

- [ ] **Step 1: Write the failing registry tests** — SPEC §10.1/10.2/10.3/10.5 exactly:

```swift
func testRegistryOrderEqualsSessionSourceAllCases() {
    XCTAssertEqual(SessionSourceRegistry.ordered.map(\.descriptor.source), SessionSource.allCases)
}
func testDescriptorKeysMatchTheStabilityTable() {
    for s in SessionSource.allCases {
        let d = SessionSourceRegistry.descriptor(for: s)
        XCTAssertEqual(d.enablementKey, AgentEnablement.enablementKey(for: s), "\(s)")
        XCTAssertEqual(d.includeKey, SourceKeyTable.include[s], "\(s)")   // Task 1's test table
    }
    XCTAssertNil(SessionSourceRegistry.descriptor(for: .openclaw).cliAvailableKey)          // K4
    XCTAssertEqual(SessionSourceRegistry.descriptor(for: .droid).rootOverrideKeys,
                   [PreferencesKey.Paths.droidSessionsRootOverride,
                    PreferencesKey.Paths.droidProjectsRootOverride])                        // K3
}
func testDescriptorBrandHueMatchesTranscriptColorSystem() {   // parity, deleted at Task 3 flip
    for s in SessionSource.allCases {
        XCTAssertEqual(SessionSourceRegistry.resolvedBrandAccent(for: s),
                       TranscriptColorSystem.agentBrandAccent(source: s), "\(s)")
    }
}
func testSystemPassthroughSourcesAreExactlyAntigravityAndOpencode() { /* K6, as rev 1 */ }
func testDefaultEnablementSemanticsPreserved() {              // K7 pinned table
    let alwaysOn: Set<SessionSource> = [.codex, .claude, .antigravity, .opencode, .copilot, .droid]
    for s in SessionSource.allCases {
        XCTAssertEqual(SessionSourceRegistry.descriptor(for: s).defaultEnabled,
                       alwaysOn.contains(s) ? .always : .whenAvailable, "\(s)")
    }
}
func testResumeGatingMatchesLegacyBehavior() {
    for s in SessionSource.allCases {
        XCTAssertEqual(SessionSourceRegistry.descriptor(for: s).supportsResume,
                       !(s == .droid || s == .openclaw), "\(s)")
    }
}
```

- [ ] **Step 2: Run — FAIL** (types don't exist).
- [ ] **Step 3: Implement.** Start from the committed draft
  (`2026-08-13-…-DRAFT.swift.txt`), applying: drop the four identity fields; split into
  per-source files; `rootOverrideKeys: [String]` with Task-1 constants; add
  `shortLabel` (from `UnifiedSessionsView.swift:2949-2962`), `badgeInitials`,
  `onboardingAccent` (verbatim closures from `OnboardingPalette.swift:257-284`);
  `isBinaryInstalled`/`isAvailable` transcribed from `AgentEnablement.swift:239-370`
  **rewritten against `AvailabilityContext`** (roots exist via `ctx.fileProbe`, grok's
  home gate via `ctx.homeDirectory`, opencode SQLite probe stays a call into
  `OpenCodeBackendDetector` — record any probe that cannot go through the seam in the
  task report rather than silently widening the context);
  `parseFullByPath` from `SearchIngestService.swift:362-389`;
  `archive` closures from `SessionArchiveManager.swift:370-514` (forced-ID parsers
  preserved; extract `minimalSession` into an internal helper with identical body);
  `supportsResume`/`resumeAgentLabel` from `UnifiedSessionsView.swift:3225-3254`;
  `otherAgentPill` transcribed by READING `UnifiedSessionsView.swift:1989-2026` (K10).
  Add `SessionSourceRegistry.resolvedBrandAccent(for:)` exactly as rev 1 (make
  `adaptiveBrand` internal static if private).
- [ ] **Step 4: Run — PASS.** Transcription mismatches resolve in favor of the LIVE code.
- [ ] **Step 5: Checkpoint** — `"feat(registry): SessionSourceRegistry with 12 verbatim descriptors and parity tests"`

---

### Task 3: Palette + labels read the registry (SessionSource.swift untouched — K15)

**Files:**
- Modify: `AgentSessions/Services/TranscriptColorSystem.swift:65-110`
- Modify: `AgentSessions/Analytics/Utilities/AnalyticsColors.swift:51-88`
- Modify: `AgentSessions/Onboarding/Components/OnboardingComponents.swift:102-117`
- Modify: `AgentSessions/Onboarding/Components/OnboardingPalette.swift:257-284`
- Modify: `AgentSessions/Views/SessionTerminalView.swift:297-312`
- Modify: `AgentSessions/Views/UnifiedSessionsView.swift:1732-1745, 2949-2962` (the TWO
  short-label switches here — Task 2 erratum: there are three label switches total, not
  four) and `:3544-3557` — which is `sourceAccent(_:)`, a COLOR switch whose palette is
  byte-for-byte the pill palette plus `Color.agentCodex`/`agentClaude`; derive it from
  `descriptor.otherAgentPill?.color` with a `Color(nsColor: SessionSourceRegistry.resolvedBrandAccent(for:))`
  fallback for codex/claude (Task 2 review confirmed `Color.agentX` is defined as exactly
  that)

- [ ] **Step 1: Target-membership check** (K15): confirm none of the six files above is
  compiled by `AgentSessionsLogicTests` (`grep '<filename> in Sources' AgentSessions.xcodeproj/project.pbxproj`
  → each must appear once, app target only). If any appears twice, STOP and take the
  target-boundary question to the owner.
- [ ] **Step 2: Flip.** `agentBrandAccent` body → `SessionSourceRegistry.resolvedBrandAccent(for:)`;
  `AnalyticsColors` 2 switches → registry; `AgentBadge.initials` →
  `descriptor.badgeInitials`; `OnboardingPalette.agentAccent` →
  `descriptor.onboardingAccent(self)`; four label switches → `descriptor.shortLabel`
  (diff each site's strings first; a differing site keeps its switch + report note).
- [ ] **Step 3: Convert the brand-hue parity test to golden literals** (12 pinned
  values captured from the pre-flip switch) — the parity form is circular post-flip.
  Capture goldens PER-APPEARANCE as RGBA components (aqua + darkAqua) — dynamic NSColors
  from `adaptiveBrand` never compare equal as objects (Task 2 finding; its parity test
  shows the working comparison pattern). Extend the goldens to `shortLabel` (all 12) and
  the 10 pill colors (Task 2 review I2 — these fields currently have no automated
  parity, and this flip is the moment they become load-bearing).
- [ ] **Step 4: Build + tests green** (`testTranscriptHostCoversEverySource`,
  `NewProviderDiscoverabilityTests` sentinels).
- [ ] **Step 5: Checkpoint** — `"refactor(palette): brand colors, badges and labels read the registry"`

---

### Task 4: Detection + enablement (`AgentEnablement` collapses via AvailabilityContext)

**Files:**
- Modify: `AgentSessions/Services/AgentEnablement.swift` (five switches: `enablementKey`
  L81-96, `isEnabled` L50-70, `isAvailable` L239-307, `binaryInstalled` L342-370,
  `storedBinaryPresence` L399-426; `seedIfNeeded` L172-237 loops)
- Test: existing `NewProviderDiscoverabilityTests` + `AgentBinaryDetectionTests` must
  stay green (they inject `FakeFileProbe`/detect seams — `AvailabilityContext` must
  compose from the SAME seams so hermeticity is preserved, K5)

- [ ] **Step 1: Flip the five switches** to registry reads, public API unchanged:
  `enablementKey` → descriptor; `isEnabled` → explicit-key read then
  `defaultEnabled == .always ? true : isAvailable(...)` (K7);
  `isAvailable(source:defaults:)` → builds `AvailabilityContext` from its existing
  parameters/seams, calls `descriptor.isAvailable(ctx)`;
  `binaryInstalled(for:detect:)` → context with injected `detect`;
  `storedBinaryPresence` → `guard let key = descriptor.cliAvailableKey else { return nil }` (K4).
  `seedIfNeeded`: both branches loop `SessionSourceRegistry.ordered`; legacy branch
  keeps its four frozen toolbar-pref reads in a local `[SessionSource: String]`;
  fallback stays `setEnabledInternal(.codex, …)` (K8).
- [ ] **Step 2: Build + full tests green** (migration/seed + hermetic detection tests
  are the sentinels; if any detection test now touches the real filesystem, the context
  wiring is wrong — fix the wiring, not the test).
- [ ] **Step 3: Checkpoint** — `"refactor(enablement): AgentEnablement reads the registry via AvailabilityContext"`

---

### Task 5: Search + archive

**Files:**
- Modify: `AgentSessions/Search/SearchIngestService.swift:362-389`
- Modify: `AgentSessions/Search/SearchCoordinator.swift:165-204`
- Modify: `AgentSessions/Services/UnifiedSessionIndexer.swift` (add `isIncluded(_:)` +
  `allowedSearchSources()`)
- Modify: `AgentSessions/Views/UnifiedSessionsView.swift:3499-3528, 4401-4429, 4436-4466`
- Modify: `AgentSessions/Services/SessionArchiveManager.swift:370-514`
- Test: `AgentSessionsTests/SessionParserTests.swift:411,450,476-510` (4 call sites rewritten)

**Interfaces:**
- Produces: `SearchCoordinator.start(query:filters:allowed:enableDeepScan:all:)` (K9);
  `UnifiedSessionIndexer.isIncluded(_ source:) -> Bool` (12-arm exhaustive switch bridge,
  deleted in Task 7) and `UnifiedSessionIndexer.allowedSearchSources() -> Set<SessionSource>`
  (SPEC §3.5 — on the indexer, NOT the view; `UnifiedSearchFiltersView` can reach
  `unified.allowedSearchSources()` where it cannot reach a view-private helper).

- [ ] **Step 1: Rewrite the Kimi regression test** against the Set (same assertions, new
  shape; keep + update its doc comment) and add the successor guards:

```swift
// included:  allowed: Set(SessionSource.allCases)
// excluded:  allowed: Set(SessionSource.allCases).subtracting([.kimi])
@MainActor
func testAllowedSearchSourcesIsEnabledAndIncluded() {
    // SPEC §8.5 — one policy for all 12; previously two call sites gated only pi/kimi/grok.
    // Uses the Task 7 handle-injection harness once available; until then, assert via
    // the UserDefaults-backed include/enablement seams on a scratch defaults suite.
    ...
}
```

- [ ] **Step 2: Change `start`'s signature**, delete the 12 Bools + insert-chain; update
  4 test + 3 production call sites; production sites call
  `unified.allowedSearchSources()` (behavior change §8.5 — note in report).
- [ ] **Step 3: Flip `parseFileFull`** → `descriptor.parseFullByPath?(url)`;
  `SessionArchiveManager` switches → `descriptor.archive?.backfillURLs(defaults) ?? [:]`
  and `descriptor.archive?.sessionForBackfill(id, url)` with existing `minimalSession`
  fallback at the call site.
- [ ] **Step 4: Build + full tests green** (SearchIngestTests + rewritten SessionParserTests).
- [ ] **Step 5: Checkpoint** — `"refactor(search): Set<SessionSource> allow-list; archive reads the registry"`

---

### Task 6: SessionProviderCatalog — one lifecycle owner replaces positional fan-out

**Files:**
- Create: `AgentSessions/Utilities/CombineLatestArray.swift` (moved here from Task 7 —
  spike finding 1: consumers must be written against the array fold once)
- Create: `AgentSessions/Services/SessionProviderCatalog.swift` (+ `SourceRuntime`)
- Modify: 12 adapter files gain `makeRuntime` (each next to its descriptor)
- NOTE (reviewer erratum 3): ALL 12 indexers already conform to `SessionIndexerProtocol`
  — five via trailing extensions the exploration pass missed (`SessionIndexer.swift:2860`,
  `ClaudeSessionIndexer.swift:1014`, `AntigravitySessionIndexer.swift:492`,
  `OpenCodeSessionIndexer.swift:410`, `OpenClawSessionIndexer.swift:696`). Do NOT add
  conformances — that is a redundant-conformance error. `SourceRuntime.indexerObject:
  any SessionIndexerProtocol & ObservableObject` therefore needs zero indexer edits;
  the c11 contract matters only for FUTURE sources (guide item).
- Modify: `AgentSessions/AgentSessionsApp.swift:174-189, 277-311, 548-578`
- Modify: `AgentSessions/Analytics/Services/AnalyticsService.swift:15-45` (init takes catalog)
- Modify: `AgentSessions/Views/UnifiedSessionsView.swift:330+, 481+, 516+` (12 props +
  `SearchSessionStore` adapter dict → catalog/runtimes)
- Modify: `AgentSessions/Onboarding/Views/FirstRunSetupView.swift:12-23, 345-360`
- Modify: `AgentSessions/Services/UnifiedSessionIndexer.swift:709-804` (init takes catalog)
- Test: `AgentSessionsTests/SessionProviderCatalogTests.swift` (new — SPEC §10.7)

**Interfaces:**
- Produces: `SessionSourceAdapter.makeRuntime: @MainActor () -> SourceRuntime`;
  `SessionProviderCatalog(runtimes:)` + `@MainActor convenience init()` looping the
  registry; `catalog[source] -> SourceRuntime`.
- Consumes: Task 0's spike report — apply its shape adjustments FIRST if any.

- [ ] **Step 1: Failing catalog tests:**

```swift
@MainActor
func testCatalogCoversEverySourceWithWorkingRuntimes() {
    let catalog = SessionProviderCatalog()
    XCTAssertEqual(Set(catalog.runtimes.keys), Set(SessionSource.allCases))
    for s in SessionSource.allCases {
        XCTAssertEqual(catalog[s].source, s)
        _ = catalog[s].searchAdapter   // constructing must not crash / not be a stub
    }
}
```

- [ ] **Step 2: Land `combineLatestArray` first** (implementation exactly as SPEC §3.4 /
  the spike's helper), then **implement `makeRuntime` per source** — each constructs its
  concrete indexer (same no-arg init the `@StateObject`s use today), wraps it into the
  handle (closures capture the local `indexer` variable only) and transcribes its
  `SearchSessionStore.Adapter` entry verbatim from `UnifiedSessionsView.swift:516+`
  (transcriptCache/update/parseFull-with-forcedID). Adopt the spike-validated typed
  downcast helper `catalog.indexer(_:as:)` for concrete-type call sites.
  `SourceRuntime.indexerObject` is `any SessionIndexerProtocol & ObservableObject` —
  all 12 indexers already conform (see NOTE above), so no indexer edits. Reference
  implementation: branch
  `spike/source-catalog` (`fde3c215`), files `AgentSessions/SourceCatalog/*` — adapt,
  don't cargo-cult; it covered only codex/grok/zzfake.
- [ ] **Step 3: Adopt.** `AgentSessionsApp`: one `@StateObject catalog`; fan-out call
  sites pass `catalog`. `AnalyticsService.init(catalog:)` replaces 12 params (internally
  keeps per-source access via `catalog[...]`; its pipelines collapse in Task 7).
  `UnifiedSessionsView`/`FirstRunSetupView` take the catalog; TranscriptHostView and the
  reload/`sessionsFromIndexer` switches obtain concrete indexers via ONE compiler-checked
  downcast switch each (enumerated, SPEC §6.A.6). `AnalyticsView.swift:413-431` `#Preview`
  constructs an `AnalyticsService` — it compiles and must migrate too (spike §6.5).
  `AnalyticsService` internals: session gathering via `handle.currentSessions()` (no
  downcasts inside the service), readiness via `combineLatestArray` (NOT `MergeMany` —
  wrong semantics), phase table via `registry.ordered.map { ($0.source, handle.currentLaunchPhase()) }`.
  `UnifiedSessionIndexer.init(catalog:)` stores runtimes; its internals stay switch-based
  until Task 7 (the 12 concrete lets remain, assigned from downcasts, so this task stays
  mechanical).
- [ ] **Step 4: K16 verification** — port the spike's 4 invalidation tests
  (`SpikeCatalogInvalidationTests` shape: no `@Published` stored props, zero
  `objectWillChange` emissions under indexer churn, catalog completeness, registry
  order). Build + full tests + owner smoke run (owner runs the app per repo QA rule).
  **Owner-verification item from the spike:** `AgentSessionsApp` no longer observes
  `SessionIndexer` directly (strictly less invalidation, but confirm `body` reads no
  `@Published` off it — inspect first; if `body` does read one, re-establish a scoped
  observation for exactly that property).
- [ ] **Step 5: Checkpoint** — `"refactor(catalog): one provider catalog replaces twelve-way positional wiring"`

---

### Task 7: Pipelines — ProviderHandle everywhere, no pyramids, emission-tested

**Files:**
- Modify: `AgentSessions/Services/UnifiedSessionIndexer.swift` (sites: 107-348 deleted,
  437-498, 666-677, 830-1268, 1295-1361, 1388-1407, 1439-1515, 2204-2266, 2356-2387,
  2470-2506, 2707-2778, 2825-2842, 2996-3001; `FocusedReloadTrigger` widens `private` →
  internal — SPEC §3.4 amendment; verify nothing relied on the privateness)
- Modify: `AgentSessions/Analytics/Services/AnalyticsService.swift:760-821`
  (readiness pyramid → `combineLatestArray`, helper already landed in Task 6)
- Test: `CodexActiveSessionsRegistryTests` + `SessionParserTests:2848-2873` updated (K11);
  new emission test (SPEC §10.4)

**Interfaces:**
- Produces: `Publishers.combineLatestArray` (rev-1 implementation, unchanged);
  `UnifiedSessionIndexer` internal init `init(handles: [SessionSource: ProviderHandle], …)`
  for tests; `SessionAggregationWork.lists: [SessionSource: [Session]]`,
  `AgentEnablementSnapshot.enabled: [SessionSource: Bool]` (tests updated same task).

- [ ] **Step 1: Failing emission test** (THE §8.1 proof — construct with fake handles;
  verify exact `LaunchPhase` case names from `UnifiedSessionIndexer.swift` before writing):

```swift
@MainActor
func testKimiLaunchPhaseEmissionUpdatesLaunchState() {
    var handles = FakeProviderHandles.allReady()          // test helper: 12 fake handles
    let kimiPhase = CurrentValueSubject<LaunchPhase, Never>(.indexing)
    handles[.kimi] = FakeProviderHandles.handle(launchPhase: kimiPhase)
    let unified = UnifiedSessionIndexer(handles: handles, …)
    kimiPhase.send(.ready)
    // The launchPhase pipeline (not the includes side-channel) must recompute:
    XCTAssertEqual(unified.launchState.sourcePhases[.kimi], .ready)
}
```

- [ ] **Step 2: Collapse.** Delete `focusedMonitorCapabilityBySource` (L107-348 —
  handles carry `reloadFocusedSession`; enablement guard moves to
  `refreshFocusedSession`'s call site); every pyramid →
  `combineLatestArray(orderedSources.map { handles[$0]!.x })` zipped with
  `orderedSources` downstream — **launchPhase now covers all 12 (§8.1)**; `LaunchState.idle`
  seeds `SessionSource.allCases` (§8.2); `openClawAgentEnabled` → `AgentEnablement.isEnabled` (§8.3);
  aggregation structs dictionary-keyed + their tests (K11); `firstEnabledIndexingError`/
  `coreProviderSnapshots` array-driven (K14); method-level switches → handle/dictionary
  reads (`currentSessions`, `shouldRefreshSource`, `triggerRefresh` — OpenCode wrapper
  preserves §8.6 —, `isSourceIndexing`, `sourceAwareFocusedSignaturePath`,
  `updateLaunchState`, `mergedAggregationResult`, `applyFiltersAndSort`,
  `syncAgentEnablementFromDefaults`, `refresh(trigger:)`). Keep the 12 `@Published`
  `includeX`/`xAgentEnabled` properties (views bind; dictionary-backed internally);
  `isIncluded(_:)` from Task 5 becomes a dictionary read.
  `AnalyticsService.setupObservers`/`updateReadiness` → same helper over catalog runtimes.
- [ ] **Step 3: Build + FULL suite + owner smoke** (toggle each source; watch the
  "Sources ready" indicator — exercises §8.1-8.3 by hand once).
- [ ] **Step 4: Checkpoint** — `"refactor(pipelines): registry-ordered arrays replace Combine pyramids; launch state covers all sources"`

---

### Task 8: Views read the registry

**Files:**
- Modify: `AgentSessions/Views/UnifiedSessionsView.swift` (notice chain 3530-3541,
  onChange 736-748, pills 1989-2026, resume gates 1528-1560/1573-1704/3225-3254)
- Modify: `AgentSessions/Views/PreferencesView.swift:294-331, 1181` + `PreferencesView+General.swift:73-86`
- Modify: `AgentSessions/Onboarding/Views/FirstRunSetupView.swift:388-403, 445-457`
- Test: `AgentSessionsTests/ViewRegistryDerivationTests.swift` (new — pill derivation
  test exactly as rev 1, plus registry-order assertion)

- [ ] **Step 1: Failing pill test** (rev-1 Step 1 verbatim: all non-codex/claude carry a
  `PillSpec`, order preserved, hermes shortcut nil, antigravity "3").
- [ ] **Step 2: Derive.** Pills via `ordered.compactMap` + one exhaustive
  `binding(for:)` switch; notice chain →
  `SessionSource.allCases.contains { !unified.isAgentEnabled($0) }`; 7-of-12 `.onChange`
  → one `FilteredDefaultsObserver(keys: AgentEnablement.allEnablementKeys)` receiver
  (§8.4, pattern from `AgentSessionsApp.swift:359-363`); resume gates prepend
  `descriptor.supportsResume` guard, labels → `descriptor.resumeAgentLabel ?? "CLI"`,
  dispatchers keep exhaustive switches with explicit droid/openclaw `break` arms.
  **Task 2 review I1 — `supportsResume` is strictly WEAKER than the live predicate:**
  `canResumeSession` is per-SESSION for three sources (codex: `canResumeCodexInCLI` —
  side-chat/VS Code exclusion; claude: `!isClaudeWorkflowSubagent`; antigravity: ID
  derivability). The descriptor guard is a source-level PRE-gate only — prepend it,
  never substitute it, or those session subtypes sprout broken Resume affordances.
  Likewise `resumeAgentLabel ?? "CLI"` is load-bearing (droid/openclaw + any future
  label-less source), not cosmetic;
  Preferences sidebar groups + `visibleTabs` derive via a NEW `PreferencesTab(source:)`
  mapping (it does not exist today — create it, one exhaustive switch, K13/spike c5-c8;
  derive `PreferencesTab.title`/`iconName` for source tabs through it from the
  registry), **droid still filtered out** (§8.7); `PreferencesView+General` toggles →
  `ForEach` over `ordered`; `FirstRunSetupView.isVisibleSession` second switch → call
  `UnifiedSessionIndexer.passesHasCommandsFilter` (dedup, SPEC §6.A.2).
- [ ] **Step 2b: Analytics filter + silent-hole conversions** (spike c1-c3 + SPEC §6.C).
  Derive `AnalyticsService.sourcesFor(_:)` from `AnalyticsAgentFilter.matches` over
  `allCases` (deletes the 13-arm switch; pairing tests stay the sentinel for the enum
  case itself). Convert four `default:` switches to exhaustive with explicit per-source
  arms and a comment carrying the old default's semantics: `resume(_:)`
  (`UnifiedSessionsView.swift:~3470`), `Session.computeIsHousekeeping`
  (`Session.swift:656` — logic-target file, exhaustive switch adds no dependencies, K15
  safe), `ImageBrowserIndexCache.swift:126,149`. Zero behavior change — every existing
  source keeps its current arm; the point is a 13th source can no longer fall through
  silently.
- [ ] **Step 3: Build + tests + owner visual QA list** (pills/colors/shortcuts; notice
  flashes for EVERY source; sidebar unchanged incl. hidden droid; first-run grid;
  droid/openclaw resume menus unchanged).
- [ ] **Step 4: Checkpoint** — `"refactor(views): pills, notices and preferences lists derive from the registry"`

---

### Task 9: Proof, guide, and reconciliation

**Files:**
- Create: `docs/adding-a-session-source.md`
- Modify: `docs/backlog.md` (the "Hand-maintained per-source lists drift…" entry)
- Modify: `docs/superpowers/plans/2026-08-13-session-source-registry-PLAN.md` (stale-notice header)

- [ ] **Step 1: Write the guide** from the SPEC §2 acceptance list + the Task-0 report's
  verified enumerated edits (registry path, §6.A/6.B semantic arms, DB-backed recipe:
  `parseFullByPath: nil`, `archive: nil`, forced-ID ingest). Include the spike's guide
  notes: `versionIntroduced` must be the upcoming REAL app version (What's New derives
  provider highlights from it; `"99.0"` is test-pinned as unclaimed); the
  `SessionIndexerProtocol` conformance contract (incl. settable `activeSearchUI`); new
  sources define their UserDefaults keys in their descriptor only (K2 decision — no
  `PreferencesConstants` edit).
- [ ] **Step 2: #56 dry-run** in an owner-approved throwaway worktree: `gh pr checkout 56`,
  rebase onto refactored main, `git diff --name-only main...` → classify; record
  before(26)/after counts in the guide + task report. No pushes.
- [ ] **Step 3: Reconcile docs** — backlog Direction → SPEC; old plan header:
  `> Superseded 2026-08-14 by …-SPEC.md (rev 2) + …-PLAN.md.`
- [ ] **Step 4: Checkpoint** — `"docs: adding-a-session-source guide; reconcile backlog"`

---

## Self-review notes (spec coverage, rev 2)

- Review findings → tasks: P1 wiring → Tasks 0/6/7 (AnalyticsService, SearchSessionStore
  dict, FirstRun, App all migrate); P1 logic-target → K15 constraint + Task 3 Step 1
  membership check + no SessionSource.swift edits anywhere; P1 ProviderHandle → nested
  type, real `FocusedReloadTrigger` name, no-self-capture rule, guards at callers
  (Task 7 Step 2); P1 K5 → `AvailabilityContext` (Tasks 2/4); P2 helper scope →
  `UnifiedSessionIndexer.allowedSearchSources` (Task 5); P2 test rigor → order equality,
  48-assertion key table, emission test (Tasks 1/2/7).
- SPEC §8.1→T7 Steps 1-2; §8.2/8.3→T7; §8.4→T8; §8.5→T5; §8.6 preserved (T7 wrapper);
  §8.7/8.8 preserved (T8).
- K1→T1/T2; K2→T1; K3/K4→T2; K5→T2/T4; K6→T2; K7→T2/T4; K8→T4; K9→T5; K10→T2/T8;
  K11→T7; K12→untouched+sentinel; K13→T8; K14→T7; K15→global+T3 Step 1; K16→T0 Step 4+T6 Step 4.
- Acceptance criterion proven twice: T0 fake source + T9 #56 dry-run.
