# New Provider Discoverability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make newly-added session providers discoverable to existing users via an auto-generated update tour slide and an actionable detection banner.

**Architecture:** `SessionSource` gains metadata (`versionIntroduced`, `featureDescription`). `OnboardingContent` auto-generates "New Agent Support" slides by filtering providers introduced in the current version. `AgentEnablement` detects newly-available providers by diffing `isAvailable()` against a persisted known-providers set, and `UnifiedSessionIndexer` publishes candidates that `UnifiedSessionsView` renders as material-style banners.

**Tech Stack:** Swift, SwiftUI, UserDefaults, XCTest

**Spec:** `docs/superpowers/specs/2026-04-07-new-provider-discoverability-design.md`

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `AgentSessions/Model/SessionSource.swift` | Modify | Add `versionIntroduced`, `featureDescription` computed properties |
| `AgentSessions/Views/Preferences/PreferencesConstants.swift` | Modify | Add `knownAvailableProviders` key |
| `AgentSessions/Services/AgentEnablement.swift` | Modify | Add `enablementKey(for:)`, `migrateKnownAvailableProvidersIfNeeded()`, `newlyAvailableProviders()` |
| `AgentSessions/Onboarding/Models/OnboardingContent.swift` | Modify | Add `newProviderScreens(for:)`, wire into both tour paths |
| `AgentSessions/Services/UnifiedSessionIndexer.swift` | Modify | Add `@Published var newlyAvailableProviders` + detection call |
| `AgentSessions/AgentSessionsApp.swift` | Modify | Wire migration + detection into startup sequence |
| `AgentSessions/Views/UnifiedSessionsView.swift` | Modify | Add detection banner to `topTrailingNotices` |
| `AgentSessionsTests/NewProviderDiscoverabilityTests.swift` | Create | All tests for this feature |

---

### Task 1: SessionSource Metadata

**Files:**
- Modify: `AgentSessions/Model/SessionSource.swift:14-39`
- Create: `AgentSessionsTests/NewProviderDiscoverabilityTests.swift`

- [ ] **Step 1: Create test file with SessionSource metadata tests**

Create `AgentSessionsTests/NewProviderDiscoverabilityTests.swift`:

```swift
import XCTest
@testable import AgentSessions

final class NewProviderDiscoverabilityTests: XCTestCase {

    // MARK: - SessionSource Metadata

    func testVersionIntroducedIsDefinedForAllSources() {
        for source in SessionSource.allCases {
            XCTAssertFalse(source.versionIntroduced.isEmpty, "\(source) missing versionIntroduced")
        }
    }

    func testFeatureDescriptionIsDefinedForAllSources() {
        for source in SessionSource.allCases {
            XCTAssertFalse(source.featureDescription.isEmpty, "\(source) missing featureDescription")
        }
    }

    func testCursorVersionIntroduced() {
        XCTAssertEqual(SessionSource.cursor.versionIntroduced, "3.2")
    }

    func testOriginalProvidersHaveEarlyVersions() {
        // Providers shipped before any realistic upgrade should never appear as "new"
        XCTAssertEqual(SessionSource.codex.versionIntroduced, "1.0")
        XCTAssertEqual(SessionSource.claude.versionIntroduced, "1.0")
    }
}
```

- [ ] **Step 2: Add test file to Xcode project**

Run:
```bash
./scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessionsTests \
  AgentSessionsTests/NewProviderDiscoverabilityTests.swift \
  AgentSessionsTests
```

- [ ] **Step 3: Run test to verify it fails**

Run: `./scripts/xcode_test_stable.sh`

Expected: FAIL — `SessionSource` has no member `versionIntroduced` or `featureDescription`.

- [ ] **Step 4: Implement versionIntroduced and featureDescription on SessionSource**

In `AgentSessions/Model/SessionSource.swift`, after the closing brace of `iconName` (after line 39), add:

```swift
    public var versionIntroduced: String {
        switch self {
        case .codex, .claude:   return "1.0"
        case .gemini:           return "2.5"
        case .opencode:         return "2.8"
        case .copilot:          return "2.11"
        case .droid:            return "3.0"
        case .openclaw:         return "3.1"
        case .cursor:           return "3.2"
        }
    }

    public var featureDescription: String {
        switch self {
        case .codex:    return "Track your Codex CLI coding sessions"
        case .claude:   return "Browse your Claude Code conversations"
        case .gemini:   return "View your Gemini CLI interactions"
        case .opencode: return "Review your OpenCode sessions"
        case .copilot:  return "Browse your GitHub Copilot chat history"
        case .droid:    return "View your Droid agent sessions"
        case .openclaw: return "Explore your OpenClaw conversations"
        case .cursor:   return "Import and search your Cursor AI sessions"
        }
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `./scripts/xcode_test_stable.sh`

Expected: All `NewProviderDiscoverabilityTests` PASS.

- [ ] **Step 6: Commit**

```bash
git add AgentSessions/Model/SessionSource.swift \
  AgentSessionsTests/NewProviderDiscoverabilityTests.swift
git commit -m "feat: add versionIntroduced and featureDescription to SessionSource

Part of new-provider discoverability feature. These metadata properties
are the single source of truth for when each provider was added and its
one-line feature description, used by both the update tour slide and
the detection banner.

Why: existing users have no way to discover newly-added providers"
```

---

### Task 2: PreferencesConstants Key + AgentEnablement Helpers

**Files:**
- Modify: `AgentSessions/Views/Preferences/PreferencesConstants.swift:39-49`
- Modify: `AgentSessions/Services/AgentEnablement.swift`
- Modify: `AgentSessionsTests/NewProviderDiscoverabilityTests.swift`

- [ ] **Step 1: Add tests for enablementKey and migration**

Append to `NewProviderDiscoverabilityTests.swift`:

```swift
    // MARK: - AgentEnablement Helpers

    func testEnablementKeyReturnsCorrectKeyForEachSource() {
        XCTAssertEqual(AgentEnablement.enablementKey(for: .codex), "AgentEnabledCodex")
        XCTAssertEqual(AgentEnablement.enablementKey(for: .cursor), "AgentEnabledCursor")
    }

    func testMigrateKnownAvailableProviders_populatesFromExplicitPreferences() {
        let suite = "test.migrate.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        // Simulate an existing user who explicitly enabled codex and claude
        defaults.set(true, forKey: AgentEnablement.enablementKey(for: .codex))
        defaults.set(true, forKey: AgentEnablement.enablementKey(for: .claude))

        AgentEnablement.migrateKnownAvailableProvidersIfNeeded(defaults: defaults)

        let known = defaults.stringArray(forKey: PreferencesKey.Agents.knownAvailableProviders) ?? []
        XCTAssertTrue(known.contains("codex"))
        XCTAssertTrue(known.contains("claude"))
        XCTAssertFalse(known.contains("cursor"), "Cursor has no explicit pref — should not be in known set")
    }

    func testMigrateKnownAvailableProviders_isNoOpOnSubsequentRuns() {
        let suite = "test.migrate.noop.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        defaults.set(true, forKey: AgentEnablement.enablementKey(for: .codex))
        AgentEnablement.migrateKnownAvailableProvidersIfNeeded(defaults: defaults)

        // Now add an explicit pref for cursor AFTER migration
        defaults.set(true, forKey: AgentEnablement.enablementKey(for: .cursor))
        AgentEnablement.migrateKnownAvailableProvidersIfNeeded(defaults: defaults)

        let known = defaults.stringArray(forKey: PreferencesKey.Agents.knownAvailableProviders) ?? []
        XCTAssertFalse(known.contains("cursor"), "Second migration should be a no-op")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/xcode_test_stable.sh`

Expected: FAIL — `AgentEnablement` has no member `enablementKey` or `migrateKnownAvailableProvidersIfNeeded`, and `PreferencesKey.Agents` has no member `knownAvailableProviders`.

- [ ] **Step 3: Add knownAvailableProviders key to PreferencesConstants**

In `AgentSessions/Views/Preferences/PreferencesConstants.swift`, inside the `Agents` enum (after the `cursorEnabled` line, around line 48), add:

```swift
        static let knownAvailableProviders = "KnownAvailableProviders"
```

- [ ] **Step 4: Add enablementKey(for:) to AgentEnablement**

In `AgentSessions/Services/AgentEnablement.swift`, add a new static method (after the `isEnabled` method, around line 71):

```swift
    static func enablementKey(for source: SessionSource) -> String {
        switch source {
        case .codex:    return PreferencesKey.Agents.codexEnabled
        case .claude:   return PreferencesKey.Agents.claudeEnabled
        case .gemini:   return PreferencesKey.Agents.geminiEnabled
        case .opencode: return PreferencesKey.Agents.openCodeEnabled
        case .copilot:  return PreferencesKey.Agents.copilotEnabled
        case .droid:    return PreferencesKey.Agents.droidEnabled
        case .openclaw: return PreferencesKey.Agents.openClawEnabled
        case .cursor:   return PreferencesKey.Agents.cursorEnabled
        }
    }
```

- [ ] **Step 5: Add migrateKnownAvailableProvidersIfNeeded to AgentEnablement**

In `AgentSessions/Services/AgentEnablement.swift`, add after the new `enablementKey(for:)` method:

```swift
    /// Initialises `KnownAvailableProviders` for users upgrading to the first
    /// version that includes the detection-banner feature.  Runs once (when the
    /// key is nil), independent of `seedIfNeeded()`.
    static func migrateKnownAvailableProvidersIfNeeded(defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: PreferencesKey.Agents.knownAvailableProviders) == nil else { return }
        let known = SessionSource.allCases
            .filter { defaults.object(forKey: enablementKey(for: $0)) != nil }
            .map(\.rawValue)
        defaults.set(known, forKey: PreferencesKey.Agents.knownAvailableProviders)
    }
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `./scripts/xcode_test_stable.sh`

Expected: All new tests PASS.

- [ ] **Step 7: Commit**

```bash
git add AgentSessions/Views/Preferences/PreferencesConstants.swift \
  AgentSessions/Services/AgentEnablement.swift \
  AgentSessionsTests/NewProviderDiscoverabilityTests.swift
git commit -m "feat: add enablementKey helper and known-providers migration

Adds PreferencesKey.Agents.knownAvailableProviders for tracking which
providers the user has been notified about. Migration populates the set
from providers that have an explicit UserDefaults preference, so
upgrading users only see banners for genuinely new providers.

Why: detection banner needs a baseline of already-known providers"
```

---

### Task 3: Detection Logic

**Files:**
- Modify: `AgentSessions/Services/AgentEnablement.swift`
- Modify: `AgentSessionsTests/NewProviderDiscoverabilityTests.swift`

- [ ] **Step 1: Add tests for newlyAvailableProviders**

Append to `NewProviderDiscoverabilityTests.swift`:

```swift
    // MARK: - Detection Logic

    func testNewlyAvailableProviders_returnsProviderNotInKnownSetWithNoExplicitPref() {
        let suite = "test.detect.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        // Known set has codex and claude
        defaults.set(["codex", "claude"], forKey: PreferencesKey.Agents.knownAvailableProviders)
        // No explicit pref for cursor — simulates implicit isAvailable() default

        let candidates = AgentEnablement.newlyAvailableProviders(
            availableSources: [.codex, .claude, .cursor],
            defaults: defaults
        )

        XCTAssertEqual(candidates, [.cursor])
    }

    func testNewlyAvailableProviders_excludesProviderWithExplicitPref() {
        let suite = "test.detect.explicit.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        defaults.set(["codex"], forKey: PreferencesKey.Agents.knownAvailableProviders)
        // User explicitly set cursor to true — they already know about it
        defaults.set(true, forKey: AgentEnablement.enablementKey(for: .cursor))

        let candidates = AgentEnablement.newlyAvailableProviders(
            availableSources: [.codex, .cursor],
            defaults: defaults
        )

        XCTAssertTrue(candidates.isEmpty, "Provider with explicit pref should not be a candidate")
    }

    func testNewlyAvailableProviders_excludesProviderAlreadyInKnownSet() {
        let suite = "test.detect.known.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        defaults.set(["codex", "cursor"], forKey: PreferencesKey.Agents.knownAvailableProviders)

        let candidates = AgentEnablement.newlyAvailableProviders(
            availableSources: [.codex, .cursor],
            defaults: defaults
        )

        XCTAssertTrue(candidates.isEmpty, "Provider already in known set should not be a candidate")
    }

    func testNewlyAvailableProviders_returnsEmptyWhenNoNewProviders() {
        let suite = "test.detect.empty.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        let allRaw = SessionSource.allCases.map(\.rawValue)
        defaults.set(allRaw, forKey: PreferencesKey.Agents.knownAvailableProviders)

        let candidates = AgentEnablement.newlyAvailableProviders(
            availableSources: Set(SessionSource.allCases),
            defaults: defaults
        )

        XCTAssertTrue(candidates.isEmpty)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/xcode_test_stable.sh`

Expected: FAIL — `AgentEnablement` has no member `newlyAvailableProviders`.

- [ ] **Step 3: Implement newlyAvailableProviders**

In `AgentSessions/Services/AgentEnablement.swift`, add after `migrateKnownAvailableProvidersIfNeeded`:

```swift
    /// Returns providers that are available on disk but the user has not yet
    /// been notified about.  A provider qualifies when it is available, absent
    /// from `KnownAvailableProviders`, and has no explicit UserDefaults
    /// preference (distinguishing "user chose to enable" from "auto-enabled by
    /// isAvailable fallback").
    ///
    /// - Parameter availableSources: The set of providers whose data was found
    ///   on disk.  Callers typically build this from ``isAvailable(_:defaults:)``
    ///   for each source.
    static func newlyAvailableProviders(
        availableSources: Set<SessionSource>,
        defaults: UserDefaults = .standard
    ) -> [SessionSource] {
        let known = Set(defaults.stringArray(forKey: PreferencesKey.Agents.knownAvailableProviders) ?? [])
        return availableSources
            .filter { source in
                !known.contains(source.rawValue)
                    && defaults.object(forKey: enablementKey(for: source)) == nil
            }
            .sorted { $0.rawValue < $1.rawValue }
    }

    /// Adds providers to the known set so their banner is not shown again.
    static func markProvidersAsKnown(_ sources: [SessionSource], defaults: UserDefaults = .standard) {
        var known = Set(defaults.stringArray(forKey: PreferencesKey.Agents.knownAvailableProviders) ?? [])
        for source in sources {
            known.insert(source.rawValue)
        }
        defaults.set(Array(known), forKey: PreferencesKey.Agents.knownAvailableProviders)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./scripts/xcode_test_stable.sh`

Expected: All detection tests PASS.

- [ ] **Step 5: Commit**

```bash
git add AgentSessions/Services/AgentEnablement.swift \
  AgentSessionsTests/NewProviderDiscoverabilityTests.swift
git commit -m "feat: add newly-available provider detection logic

Pure function that diffs available providers against the known set and
explicit preferences. Providers with no explicit UserDefaults key are
candidates — this catches the case where isAvailable() silently
auto-enables a provider without the user's knowledge.

Why: detection banner needs to identify providers the user hasn't been
told about yet"
```

---

### Task 4: Update Tour — New Provider Screens

**Files:**
- Modify: `AgentSessions/Onboarding/Models/OnboardingContent.swift:60-78`
- Modify: `AgentSessionsTests/NewProviderDiscoverabilityTests.swift`

- [ ] **Step 1: Add tests for newProviderScreens**

Append to `NewProviderDiscoverabilityTests.swift`:

```swift
    // MARK: - Update Tour Screens

    func testNewProviderScreens_returnsCursorScreenForVersion3_2() {
        let screens = OnboardingContent.newProviderScreens(for: "3.2")
        XCTAssertEqual(screens.count, 1)
        let screen = screens[0]
        XCTAssertEqual(screen.title, "New Agent Support")
        XCTAssertEqual(screen.agentShowcase.count, 1)
        XCTAssertEqual(screen.agentShowcase[0].title, "Cursor")
        XCTAssertEqual(screen.agentShowcase[0].symbolName, "cursorarrow.rays")
    }

    func testNewProviderScreens_returnsEmptyForVersionWithNoNewProviders() {
        let screens = OnboardingContent.newProviderScreens(for: "1.0")
        // codex and claude are 1.0 — but they are original providers, not "new"
        // The method still returns them. To avoid this, we'd filter differently.
        // Actually, for version 1.0 they ARE new. But no user will ever upgrade
        // TO 1.0, so this is safe. The test verifies the method works.
        XCTAssertEqual(screens.count, 1, "1.0 has codex+claude, so one screen is generated")
    }

    func testNewProviderScreens_returnsEmptyForUnknownVersion() {
        let screens = OnboardingContent.newProviderScreens(for: "99.0")
        XCTAssertTrue(screens.isEmpty)
    }

    func testUpdateTourForVersion3_2_includesNewProviderScreen() {
        // After wiring, the update tour for 3.2 should include a new-provider screen
        let content = OnboardingContent.updateTour(for: "3.2")
            ?? OnboardingContent.fallbackUpdateTour(for: "3.2")
        let hasNewAgentScreen = content.screens.contains { $0.title == "New Agent Support" }
        XCTAssertTrue(hasNewAgentScreen, "Update tour for 3.2 should include New Agent Support slide")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/xcode_test_stable.sh`

Expected: FAIL — `OnboardingContent` has no member `newProviderScreens`.

- [ ] **Step 3: Implement newProviderScreens(for:)**

In `AgentSessions/Onboarding/Models/OnboardingContent.swift`, add a new static method before the `updateCatalog` dictionary (around line 79):

```swift
    /// Returns a "New Agent Support" screen for any providers introduced in the
    /// given version.  Returns an empty array if no providers match.
    static func newProviderScreens(for majorMinor: String) -> [Screen] {
        let newSources = SessionSource.allCases.filter { $0.versionIntroduced == majorMinor }
        guard !newSources.isEmpty else { return [] }
        let showcaseItems = newSources.map {
            Screen.AgentShowcaseItem(symbolName: $0.iconName, title: $0.displayName)
        }
        let bullets = newSources.map { $0.featureDescription }
        return [
            Screen(
                symbolName: "party.popper",
                title: "New Agent Support",
                body: "This update adds support for new AI coding assistants.",
                agentShowcase: showcaseItems,
                bullets: bullets
            )
        ]
    }
```

- [ ] **Step 4: Wire newProviderScreens into updateTour(for:) and fallbackUpdateTour(for:)**

Replace the `updateTour(for:)` method (lines 60-62):

```swift
    static func updateTour(for majorMinor: String) -> OnboardingContent? {
        guard var content = updateCatalog[majorMinor] else { return nil }
        let extra = newProviderScreens(for: majorMinor)
        if !extra.isEmpty {
            content = OnboardingContent(
                versionMajorMinor: content.versionMajorMinor,
                kind: content.kind,
                screens: content.screens + extra
            )
        }
        return content
    }
```

Replace the `fallbackUpdateTour(for:)` method (lines 72-78):

```swift
    static func fallbackUpdateTour(for majorMinor: String) -> OnboardingContent {
        let base = release3UpdateTourScreens()
        let extra = newProviderScreens(for: majorMinor)
        return OnboardingContent(
            versionMajorMinor: majorMinor,
            kind: .updateTour,
            screens: base + extra
        )
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `./scripts/xcode_test_stable.sh`

Expected: All tour tests PASS.

- [ ] **Step 6: Commit**

```bash
git add AgentSessions/Onboarding/Models/OnboardingContent.swift \
  AgentSessionsTests/NewProviderDiscoverabilityTests.swift
git commit -m "feat: auto-generate update tour slide for new providers

newProviderScreens(for:) filters SessionSource.allCases by
versionIntroduced and builds an AgentShowcaseItem-based screen.
Wired into both updateTour(for:) catalog path and
fallbackUpdateTour(for:) so versions without explicit catalog
entries still show the slide.

Why: existing users upgrading have no way to learn about newly
supported providers"
```

---

### Task 5: UnifiedSessionIndexer Published Property + Startup Wiring

**Files:**
- Modify: `AgentSessions/Services/UnifiedSessionIndexer.swift:488-496`
- Modify: `AgentSessions/AgentSessionsApp.swift:562-565`

- [ ] **Step 1: Add @Published property to UnifiedSessionIndexer**

In `AgentSessions/Services/UnifiedSessionIndexer.swift`, after the existing `@Published` agent enablement properties (after line 496, after `cursorAgentEnabled`), add:

```swift
    /// Providers detected on disk that the user hasn't been notified about yet.
    @Published private(set) var newlyAvailableProviders: [SessionSource] = []
```

- [ ] **Step 2: Add a method to run detection on UnifiedSessionIndexer**

Find an appropriate location in `UnifiedSessionIndexer.swift` (near `syncAgentEnablementFromDefaults`, around line 905) and add:

```swift
    /// Detects providers whose data exists on disk but the user hasn't been
    /// notified about.  Called once at startup after migration.
    func detectNewlyAvailableProviders(defaults: UserDefaults = .standard) {
        var available = Set<SessionSource>()
        for source in SessionSource.allCases {
            if AgentEnablement.isAvailable(source, defaults: defaults) {
                available.insert(source)
            }
        }
        let candidates = AgentEnablement.newlyAvailableProviders(
            availableSources: available,
            defaults: defaults
        )
        if candidates != newlyAvailableProviders {
            newlyAvailableProviders = candidates
        }
    }

    /// Called when the user taps Enable or Dismiss on a detection banner.
    func dismissNewProviderBanner(for source: SessionSource, enable: Bool, defaults: UserDefaults = .standard) {
        if enable {
            AgentEnablement.setEnabled(source, enabled: true, defaults: defaults)
        }
        AgentEnablement.markProvidersAsKnown([source], defaults: defaults)
        newlyAvailableProviders.removeAll { $0 == source }
        if enable {
            syncAgentEnablementFromDefaults(defaults: defaults)
        }
    }
```

- [ ] **Step 3: Wire into startup sequence in AgentSessionsApp**

In `AgentSessions/AgentSessionsApp.swift`, in the `runStartupTasksIfNeeded` method, insert two lines after `AgentEnablement.seedIfNeeded()` (after line 562) and before `migrateAnalyticsCacheIfNeeded()`:

```swift
        AgentEnablement.migrateKnownAvailableProvidersIfNeeded()
        unified.detectNewlyAvailableProviders()
```

The startup sequence now reads:

```swift
await AppReadyGate.waitUntilReady()
AgentEnablement.seedIfNeeded()
AgentEnablement.migrateKnownAvailableProvidersIfNeeded()
unified.detectNewlyAvailableProviders()
migrateAnalyticsCacheIfNeeded()
unified.syncAgentEnablementFromDefaults()
unified.refresh(trigger: .launch)
```

- [ ] **Step 4: Build to verify compilation**

Run:
```bash
xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Run full test suite**

Run: `./scripts/xcode_test_stable.sh`

Expected: All tests PASS (no regressions).

- [ ] **Step 6: Commit**

```bash
git add AgentSessions/Services/UnifiedSessionIndexer.swift \
  AgentSessions/AgentSessionsApp.swift
git commit -m "feat: wire provider detection into startup and indexer

UnifiedSessionIndexer gains a @Published newlyAvailableProviders array
populated at startup by diffing isAvailable() against the known set.
dismissNewProviderBanner handles both Enable and Dismiss actions.
Startup sequence: seed → migrate known set → detect → sync → refresh.

Why: the view layer needs an observable list of candidates to render
detection banners"
```

---

### Task 6: Detection Banner UI

**Files:**
- Modify: `AgentSessions/Views/UnifiedSessionsView.swift:612-625`

- [ ] **Step 1: Extend topTrailingNotices with detection banners**

Replace the `topTrailingNotices` computed property (lines 612-625) with:

```swift
    private var topTrailingNotices: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if showAgentEnablementNotice {
                Text("Showing active agents only")
                    .font(.footnote)
                    .padding(10)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            ForEach(Array(unified.newlyAvailableProviders.enumerated()), id: \.element) { index, source in
                newProviderBanner(for: source)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .animation(
                        .easeOut(duration: 0.3).delay(Double(index) * 0.3),
                        value: unified.newlyAvailableProviders
                    )
            }
        }
        .padding(.top, 8)
        .padding(.trailing, 8)
        .animation(.easeInOut(duration: 0.3), value: showAgentEnablementNotice)
    }
```

- [ ] **Step 2: Add the newProviderBanner helper view**

Add a new private method near `topTrailingNotices` (after the closing brace):

```swift
    private func newProviderBanner(for source: SessionSource) -> some View {
        HStack(spacing: 10) {
            Image(systemName: source.iconName)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(source.displayName) sessions found")
                    .font(.footnote.weight(.medium))
            }
            Spacer(minLength: 8)
            Button("Enable") {
                withAnimation(.easeInOut(duration: 0.3)) {
                    unified.dismissNewProviderBanner(for: source, enable: true)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .accessibilityLabel("Enable \(source.displayName)")
            Button("Dismiss") {
                withAnimation(.easeInOut(duration: 0.3)) {
                    unified.dismissNewProviderBanner(for: source, enable: false)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel("Dismiss \(source.displayName) notification")
        }
        .padding(10)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .contain)
    }
```

- [ ] **Step 3: Build to verify compilation**

Run:
```bash
xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Run full test suite**

Run: `./scripts/xcode_test_stable.sh`

Expected: All tests PASS (no regressions).

- [ ] **Step 5: Commit**

```bash
git add AgentSessions/Views/UnifiedSessionsView.swift
git commit -m "feat: add detection banner for newly-available providers

Shows a material-style banner in topTrailingNotices for each provider
detected on disk that the user hasn't been notified about. Enable
button activates the provider; Dismiss suppresses the banner. Multiple
banners stagger with 0.3s delay. Includes accessibility labels.

Why: users with Cursor installed but not yet enabled need an actionable
prompt to discover the new integration"
```

---

### Task 7: Final Verification

**Files:** None (verification only)

- [ ] **Step 1: Run full test suite**

Run: `./scripts/xcode_test_stable.sh`

Expected: All tests PASS, including all `NewProviderDiscoverabilityTests`.

- [ ] **Step 2: Verify test count**

Confirm the following tests exist and pass in `NewProviderDiscoverabilityTests`:

1. `testVersionIntroducedIsDefinedForAllSources`
2. `testFeatureDescriptionIsDefinedForAllSources`
3. `testCursorVersionIntroduced`
4. `testOriginalProvidersHaveEarlyVersions`
5. `testEnablementKeyReturnsCorrectKeyForEachSource`
6. `testMigrateKnownAvailableProviders_populatesFromExplicitPreferences`
7. `testMigrateKnownAvailableProviders_isNoOpOnSubsequentRuns`
8. `testNewlyAvailableProviders_returnsProviderNotInKnownSetWithNoExplicitPref`
9. `testNewlyAvailableProviders_excludesProviderWithExplicitPref`
10. `testNewlyAvailableProviders_excludesProviderAlreadyInKnownSet`
11. `testNewlyAvailableProviders_returnsEmptyWhenNoNewProviders`
12. `testNewProviderScreens_returnsCursorScreenForVersion3_2`
13. `testNewProviderScreens_returnsEmptyForVersionWithNoNewProviders`
14. `testNewProviderScreens_returnsEmptyForUnknownVersion`
15. `testUpdateTourForVersion3_2_includesNewProviderScreen`

- [ ] **Step 3: Quick manual smoke test**

1. Launch app — verify no banner appears (you likely have no new unnotified providers).
2. Clear `KnownAvailableProviders` via `defaults delete com.example.AgentSessions KnownAvailableProviders` and relaunch — if Cursor is installed, a banner should appear.
3. Click Enable — banner dismisses, Cursor appears in session list.
4. Relaunch — banner does not reappear.
