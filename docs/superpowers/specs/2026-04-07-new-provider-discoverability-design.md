# New Provider Discoverability

**Date:** 2026-04-07
**Status:** Approved

## Problem

When a new session provider (e.g., Cursor) is added, existing users who upgrade the app have no way to discover it. Providers like Cursor default to `isAvailable()` for enablement, so users with Cursor installed get it silently enabled — but without any indication that it's new. Users without it installed never learn about the support at all.

## Goals

1. **Educate** existing users that a new provider is supported (update tour slide).
2. **Convert** users who have the provider installed but not yet enabled (detection banner).
3. **Generic** — adding the next provider requires only enum metadata, no new UI code.

## Design

### 1. SessionSource Metadata

Add two computed properties to `SessionSource`:

```swift
public var versionIntroduced: String
public var featureDescription: String
```

`versionIntroduced` is the single source of truth for when a provider was added. Both the update tour and the detection banner reference it.

**All cases must have values.** Existing providers use early version strings so they are never treated as "new" during upgrades:

```swift
public var versionIntroduced: String {
    switch self {
    case .codex, .claude:               return "1.0"
    case .gemini:                       return "2.5"
    case .opencode:                     return "2.8"
    case .copilot:                      return "2.11"
    case .droid:                        return "3.0"
    case .openclaw:                     return "3.1"
    case .cursor:                       return "3.2"
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

### 2. Update Tour — Auto-Generated "New Providers" Slide

`OnboardingContent` gains a static method:

```swift
static func newProviderScreens(for majorMinor: String) -> [Screen]
```

This filters `SessionSource.allCases` for sources where `versionIntroduced == majorMinor`. If any match, it returns a screen using the existing `Screen.agentShowcase` property with `AgentShowcaseItem` entries built from each provider's `iconName`, `displayName`, and `featureDescription`. If no providers match, it returns an empty array.

**Both catalog and fallback paths must include new-provider screens.** The current tour resolution is:

```swift
content = OnboardingContent.updateTour(for: majorMinor)
    ?? OnboardingContent.fallbackUpdateTour(for: majorMinor)
```

If a version has no explicit catalog entry (e.g., `"3.2"` is not in `updateCatalog`), the fallback tour is used. `newProviderScreens(for:)` must be appended in both paths:

- In `updateTour(for:)`: append to the catalog entry's screens before returning.
- In `fallbackUpdateTour(for:)`: append to the fallback screens before returning.

This ensures that a version with a new provider always shows the slide, even without a manually-authored catalog entry. No per-provider slide code needed.

### 3. Detection Banner — "Sessions Found, Enable?"

#### State

A new UserDefaults key `KnownAvailableProviders` stores a `[String]` of provider raw values the user has already been notified about.

#### Detection Logic

A static method on `AgentEnablement` computes the candidates. `UnifiedSessionIndexer` (which is already an `@ObservableObject` observed by the session list view) calls this method and publishes the result via a `@Published var newlyAvailableProviders: [SessionSource]` property.

After `seedIfNeeded()`, the detection logic runs:

1. Check `isAvailable()` for all providers.
2. Compare against the `KnownAvailableProviders` set.
3. A provider is a banner candidate if **all** of the following are true:
   - `isAvailable()` returns `true`
   - It is **not** in the `KnownAvailableProviders` set
   - It has **no explicit UserDefaults preference** stored (i.e., `defaults.object(forKey:) == nil` for its enablement key)

The third condition is critical: providers like Cursor default to `isAvailable()` inside `isEnabled()`, meaning an upgrading user with Cursor installed already has it implicitly enabled — but was never told. Checking for an explicit preference distinguishes "user consciously enabled this" from "it was auto-enabled by the fallback default." Providers with an explicit `true` or `false` stored have already been acted on by the user and should not trigger a banner.

#### Migration for Existing Users

`seedIfNeeded()` has a `didSeedEnabledAgents` guard that causes it to return early for existing users. The `KnownAvailableProviders` initialization must therefore be **independent** of the seed guard:

```swift
// Runs every launch, not gated by didSeedEnabledAgents
if defaults.object(forKey: PreferencesKey.Agents.knownAvailableProviders) == nil {
    // First time this feature runs — populate from currently-enabled providers
    // that have an explicit preference stored
    let known = SessionSource.allCases.filter { source in
        defaults.object(forKey: source.enablementKey) != nil
    }.map(\.rawValue)
    defaults.set(known, forKey: PreferencesKey.Agents.knownAvailableProviders)
}
```

This runs once (when the key is nil), is safe to re-run, and correctly seeds the known set for upgrading users without interfering with the existing seed logic.

#### Banner UI

Placed in the existing `topTrailingNotices` VStack in `UnifiedSessionsView`, matching the current `.regularMaterial` / `RoundedRectangle(cornerRadius: 12)` style:

- Provider icon (from `iconName`) + display name + "sessions found"
- **Enable** button: calls `AgentEnablement.setEnabled(provider, true)`, adds to known set, dismisses.
- **Dismiss** button: adds to known set, dismisses. Won't show again.
- Multiple new providers stack as separate banners, staggered with a slight delay (e.g., 0.3s) so simultaneous appearances don't feel jarring.
- Transition: `.move(edge: .top).combined(with: .opacity)`.

**Accessibility:** Enable and Dismiss buttons must have `.accessibilityLabel` values (e.g., "Enable Cursor" / "Dismiss Cursor notification"). The banner container should use `.accessibilityElement(children: .contain)` so screen readers announce it as a group.

#### Lifecycle

- Banner appears once per provider, ever.
- After Enable or Dismiss, the provider is added to the known set.

### 4. Startup Sequence

```
1. onboardingCoordinator.checkAndPresentIfNeeded()
   -> update tour includes auto-generated "New Providers" slide
2. AppReadyGate.waitUntilReady()
3. AgentEnablement.seedIfNeeded()
   -> existing seed logic (gated by didSeedEnabledAgents)
4. AgentEnablement.migrateKnownAvailableProvidersIfNeeded()
   -> independent of seed guard
   -> if KnownAvailableProviders is nil, populates from explicit preferences
5. AgentEnablement.checkForNewlyAvailableProviders()
   -> diffs isAvailable() against KnownAvailableProviders
   -> checks for absent explicit preferences
   -> returns [SessionSource] candidates
6. unified.newlyAvailableProviders = candidates
7. unified.syncAgentEnablementFromDefaults()
8. unified.refresh(trigger: .launch)
   -> banner appears in session list if candidates exist
```

The tour educates first, then the user lands on the session list and sees the actionable banner.

## Files Changed

| File | Change |
|------|--------|
| `SessionSource.swift` | Add `versionIntroduced`, `featureDescription` |
| `OnboardingContent.swift` | Add `newProviderScreens(for:)`, wire into both `updateTour(for:)` and `fallbackUpdateTour(for:)` |
| `PreferencesConstants.swift` | Add `KnownAvailableProviders` key |
| `AgentEnablement.swift` | Add `checkForNewlyAvailableProviders()`, `migrateKnownAvailableProvidersIfNeeded()` |
| `UnifiedSessionsView.swift` | Extend `topTrailingNotices` with new-provider banners (with accessibility labels) |
| `UnifiedSessionIndexer.swift` | Add `@Published var newlyAvailableProviders: [SessionSource]`, call detection on init |

## Testing

- `newProviderScreens(for:)` returns correct providers for a given version string.
- `newProviderScreens(for:)` returns empty array for versions with no new providers.
- Newly-available detection correctly diffs available vs. known sets.
- Providers with explicit `true`/`false` preferences are excluded from candidates.
- Providers with no explicit preference but `isAvailable() == true` are included as candidates.
- `migrateKnownAvailableProvidersIfNeeded()` populates known set from explicit preferences on first run.
- `migrateKnownAvailableProvidersIfNeeded()` is a no-op on subsequent runs.
- Enable action enables the provider and removes the banner.
- Dismiss action suppresses the banner without enabling.
- Banner does not reappear after dismissal.
- New-provider slide appears in both catalog and fallback tour paths.
