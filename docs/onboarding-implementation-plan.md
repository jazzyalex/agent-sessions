# Onboarding System Implementation Plan - v2.9
## Agent Sessions

**Status**: Ready for Implementation  
**Target Release**: v2.9.0  
**Estimated Effort**: 3-4 days (24-32 hours)  
**Risk Level**: Low 🟢

---

## Executive Summary

Implement a dual-track onboarding system that:
- Shows **new user onboarding** (4 screens) for fresh installs and upgrades from <= 2.8.1
- Shows **"What's New" highlights** for existing users when major UI changes occur
- Defers interactive **tour** to v2.10 (reduced complexity)
- Leverages **Sparkle for changelogs**, focuses our system on visual walkthroughs

### Key Decisions Made:
✅ **Sparkle Integration**: Use Sparkle for release notes, our system for tours only  
✅ **Tour Scope**: Defer to v2.10 - ship v2.9 without coach marks  
✅ **Presentation**: Modal sheet (`.sheet()` modifier) over main window  
✅ **Simplified Scope**: SF Symbols only, no custom illustrations  

**This plan addresses all critical gaps identified in the original concept.**

---

## Critical Improvements to Original Plan

### 1. **Architecture Integration** ✅
- **Gap**: Original plan didn't specify integration with `AgentSessionsApp.swift`
- **Solution**: 
  - `OnboardingCoordinator` (@MainActor ObservableObject) manages state
  - Integrated via `.sheet()` modifier (SwiftUI standard pattern)
  - Respects indexing state (waits until `isIndexing == false`)
  - Handles menu bar-only mode (defers until window opens)

### 2. **Persistence Strategy** ✅
- **Gap**: Original plan didn't follow existing codebase patterns
- **Solution**:
  - `OnboardingDefaults.swift` follows existing `UpdateDefaults.swift` pattern
  - Uses `UserDefaults` extension (not raw strings)
  - Migrates old `UnifiedLegacyNoticeShown` flag (one-time)

### 3. **Version Detection Edge Cases** ✅
- **Gap**: Original plan didn't handle fresh install, downgrades, or parsing failures
- **Solution**:
  - Fresh install: `lastLaunchedVersion == nil` → show onboarding
  - Downgrade: `current < last` → skip gracefully
  - Invalid versions: Fail silently, don't crash
  - Reuses existing `SemanticVersion.swift`

### 4. **Manifest Implementation** ✅
- **Gap**: Original plan described concept but no concrete format
- **Solution**:
  - JSON structure: `onboarding-manifest.json` bundled with app
  - Simple parser: `OnboardingManifest.swift`
  - Local-only (no remote fetching for privacy)
  - Easy to update for future versions

### 5. **Sparkle Coordination** ✅
- **Gap**: Original plan didn't address Sparkle duplication
- **Solution**:
  - Sparkle shows detailed changelog (existing appcast.xml)
  - Our system shows visual highlights + tour teaser
  - No duplication: Sparkle = detailed bullets, Ours = high-level + CTA
  - "View Release Notes" button links to GitHub releases

### 6. **Tour Deferred** ✅
- **Gap**: Coach marks are complex in SwiftUI (2-3 days extra work)
- **Solution**:
  - Defer to v2.10 based on user decision
  - v2.9 "What's New" mentions "Tour coming soon"
  - Reduces risk and timeline

### 7. **File Structure Defined** ✅
- **Gap**: Original plan didn't specify where code lives
- **Solution**: Clear directory structure following existing patterns

### 8. **Testing Strategy** ✅
- **Gap**: Original plan didn't explain how to test without deleting UserDefaults
- **Solution**:
  - Debug menu with reset buttons (#if DEBUG)
  - Manual testing checklist (6 scenarios)
  - Unit tests for version detection logic

### 9. **Accessibility Plan** ✅
- **Gap**: Original plan mentioned keyboard support but not comprehensive
- **Solution**: Detailed accessibility checklist (VoiceOver, keyboard, large text, reduced motion)

### 10. **Error Handling** ✅
- **Gap**: Original plan didn't specify what happens on failures
- **Solution**: Graceful failures throughout, never crash or block app, feature flag for kill switch

---

## Architecture Overview

### Component Structure

```
AgentSessions/
  Onboarding/
    Models/
      OnboardingCoordinator.swift       ← @MainActor state manager
      OnboardingManifest.swift          ← JSON parsing & version lookup
      OnboardingType.swift              ← Enum: .newUser, .whatsNew
      OnboardingVersionChecker.swift    ← Classification logic
    Views/
      NewUserOnboarding/
        OnboardingContainerView.swift   ← Main flow with navigation
        OnboardingWelcomeScreen.swift   ← Screen 1
        OnboardingFirstStepsScreen.swift ← Screen 2
        OnboardingUIMapScreen.swift     ← Screen 3
        OnboardingFinishScreen.swift    ← Screen 4
      WhatsNew/
        WhatsNewSheet.swift             ← Compact highlights (v2.9)
        WhatsNewHighlightCard.swift     ← Individual cards
    Utilities/
      OnboardingDefaults.swift          ← UserDefaults extension
      OnboardingDesignTokens.swift      ← Shared styles
    Resources/
      onboarding-manifest.json          ← Version configs & content
```

---

## Implementation Phases (3-4 Days)

### ✅ Phase 1: Foundation (Day 1 - 6 hours)

**Goal**: Core logic and persistence

**Tasks**:
- [ ] Create `Onboarding/` directory structure
- [ ] Implement `OnboardingDefaults.swift` (UserDefaults extension)
- [ ] Implement `OnboardingType.swift` (enum)
- [ ] Implement `OnboardingVersionChecker.swift` with edge case handling
- [ ] Create `onboarding-manifest.json` (v2.9 + placeholder v2.10)
- [ ] Implement `OnboardingManifest.swift` (parsing logic)
- [ ] Write unit tests for version detection
- [ ] Add feature flag to `FeatureFlags.swift`

**Deliverable**: Logic compiles, tests pass, no UI yet

**Key Files**:
- `AgentSessions/Onboarding/Utilities/OnboardingDefaults.swift`
- `AgentSessions/Onboarding/Models/OnboardingVersionChecker.swift`
- `AgentSessions/Onboarding/Models/OnboardingManifest.swift`
- `AgentSessions/Onboarding/Resources/onboarding-manifest.json`
- `AgentSessionsTests/OnboardingVersionCheckerTests.swift`

---

### ✅ Phase 2: New User Flow (Day 2 - 8 hours)

**Goal**: Visual onboarding experience

**Tasks**:
- [ ] Implement `OnboardingCoordinator.swift` (@MainActor ObservableObject)
- [ ] Implement `OnboardingDesignTokens.swift` (reuse Analytics patterns)
- [ ] Create `OnboardingContainerView.swift` (navigation + progress dots)
- [ ] Create 4 individual screens:
  - [ ] `WelcomeScreen.swift` (icon + title + description)
  - [ ] `FirstStepsScreen.swift` (3-step guide)
  - [ ] `UIMapScreen.swift` (4 feature rows)
  - [ ] `FinishScreen.swift` (success state)
- [ ] Add keyboard shortcuts (Enter = Next, Esc = Skip)
- [ ] Add progress dots indicator
- [ ] Test navigation flow (Back/Next/Skip)

**Deliverable**: Full new user onboarding working in isolation

**Key Files**:
- `AgentSessions/Onboarding/Models/OnboardingCoordinator.swift`
- `AgentSessions/Onboarding/Views/NewUserOnboarding/OnboardingContainerView.swift`
- 4 individual screen files

---

### ✅ Phase 3: What's New Flow (Day 2-3 - 4 hours)

**Goal**: Existing user update notifications

**Tasks**:
- [ ] Implement `WhatsNewSheet.swift` (compact highlights sheet)
- [ ] Implement `WhatsNewHighlightCard.swift` (icon + title + body)
- [ ] Populate `onboarding-manifest.json` with v2.9 highlights:
  - "Onboarding Experience"
  - "Sparkle Auto-Updates"
  - "Tour Coming Soon" (teaser for v2.10)
- [ ] Add "View Release Notes" button (link to GitHub)
- [ ] Add "Continue" button (keyboard shortcut: Enter)
- [ ] Test with sample data

**Deliverable**: What's New sheet displays highlights from manifest

**Key Files**:
- `AgentSessions/Onboarding/Views/WhatsNew/WhatsNewSheet.swift`
- `AgentSessions/Onboarding/Views/WhatsNew/WhatsNewHighlightCard.swift`

---

### ✅ Phase 4: App Integration (Day 3 - 4 hours)

**Goal**: Hook into main app

**Tasks**:
- [ ] Add `onboardingCoordinator` to `AgentSessionsApp.swift`
- [ ] Add `.sheet(isPresented:)` presentation
- [ ] Trigger check on window `onAppear` (after indexing completes)
- [ ] Update `lastLaunchedVersion` on app termination
- [ ] Migrate `UnifiedLegacyNoticeShown` flag (one-time migration)
- [ ] Test menu bar-only mode (defer onboarding until window opens)
- [ ] Add Help → Onboarding menu item (manual re-open)
- [ ] Add Help → What's New menu item (force show)

**Deliverable**: Onboarding shows automatically on fresh install and upgrades

**Key Files**:
- `AgentSessions/AgentSessionsApp.swift` (modifications)

**Integration Code**:
```swift
@StateObject private var onboardingCoordinator = OnboardingCoordinator()

.onAppear {
    if !(unifiedIndexerHolder.unified?.isIndexing ?? true) {
        onboardingCoordinator.checkAndPresentIfNeeded()
    }
}
.sheet(isPresented: $onboardingCoordinator.shouldShow) {
    updateLastLaunchedVersion()
} content: {
    if let type = onboardingCoordinator.onboardingType {
        OnboardingRootView(type: type, coordinator: onboardingCoordinator)
    }
}
```

---

### ✅ Phase 5: Testing & Polish (Day 4 - 6 hours)

**Goal**: Production-ready

**Tasks**:
- [ ] Add debug menu items (reset, simulate scenarios)
- [ ] Manual testing checklist (all 6 scenarios):
  - [ ] Fresh install
  - [ ] Upgrade from 2.8.1
  - [ ] Upgrade from 2.9.0 → 2.10.0 (future)
  - [ ] Downgrade scenario
  - [ ] Menu bar-only mode
  - [ ] Accessibility
- [ ] Accessibility audit:
  - [ ] VoiceOver labels for all buttons/images
  - [ ] Keyboard navigation (Tab, Space, Enter, Esc)
  - [ ] Large text support (test at 200% zoom)
  - [ ] Reduced motion (disable animations if enabled)
- [ ] Performance check:
  - [ ] No launch time regression (< 50ms for onboarding check)
  - [ ] Use `LaunchProfiler` to measure
- [ ] Visual design review:
  - [ ] Alignment, spacing, colors match app theme
  - [ ] SF Symbols consistent
- [ ] Error handling review:
  - [ ] Graceful failures (no crashes)
  - [ ] Feature flag works
- [ ] Code review:
  - [ ] Follow existing patterns
  - [ ] Matches style of `UpdateChecker.swift`, `PreferencesWindowController.swift`

**Deliverable**: Ready to merge and release

---

## Critical Implementation Details

### 1. Persistence Layer

**File**: `AgentSessions/Onboarding/Utilities/OnboardingDefaults.swift`

```swift
import Foundation

extension UserDefaults {
    private enum OnboardingKeys {
        static let lastLaunchedVersion = "OnboardingLastLaunchedVersion"
        static let onboardingCompletedVersion = "OnboardingCompletedVersion"
        static let whatsNewShownVersion = "OnboardingWhatsNewShownVersion"
        // Note: tourCompletedVersion reserved for v2.10
    }
    
    /// Last app version that was launched (set on every launch)
    var lastLaunchedVersion: String? {
        get { string(forKey: OnboardingKeys.lastLaunchedVersion) }
        set { set(newValue, forKey: OnboardingKeys.lastLaunchedVersion) }
    }
    
    /// Version when full onboarding was completed
    var onboardingCompletedVersion: String? {
        get { string(forKey: OnboardingKeys.onboardingCompletedVersion) }
        set { set(newValue, forKey: OnboardingKeys.onboardingCompletedVersion) }
    }
    
    /// Last version for which "What's New" was shown
    var whatsNewShownVersion: String? {
        get { string(forKey: OnboardingKeys.whatsNewShownVersion) }
        set { set(newValue, forKey: OnboardingKeys.whatsNewShownVersion) }
    }
    
    /// One-time migration from old flag (v2.8.1)
    func migrateOnboardingFlags() {
        guard lastLaunchedVersion == nil else { return }
        
        // If user saw old "UnifiedLegacyNotice", treat as 2.8.1 user
        if bool(forKey: "UnifiedLegacyNoticeShown") {
            lastLaunchedVersion = "2.8.1"
        }
    }
}
```

---

### 2. Version Detection

**File**: `AgentSessions/Onboarding/Models/OnboardingVersionChecker.swift`

```swift
import Foundation

enum OnboardingType {
    case newUser(reason: NewUserReason)
    case whatsNew(highlights: [OnboardingManifest.Highlight])
    
    enum NewUserReason {
        case freshInstall
        case majorUpgrade  // from <= 2.8.1
    }
}

struct OnboardingVersionChecker {
    private let defaults = UserDefaults.standard
    
    /// Determine if and what type of onboarding to show
    func determineOnboardingType() -> OnboardingType? {
        // Get current app version
        guard let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
              let current = SemanticVersion(string: currentVersion) else {
            print("[Onboarding] Failed to parse current version")
            return nil  // Fail gracefully
        }
        
        // Migrate old flags (one-time)
        defaults.migrateOnboardingFlags()
        
        // Fresh install (no version ever recorded)
        guard let lastVersionString = defaults.lastLaunchedVersion else {
            return .newUser(reason: .freshInstall)
        }
        
        // Parse last version
        guard let lastVersion = SemanticVersion(string: lastVersionString) else {
            print("[Onboarding] Failed to parse last version: \(lastVersionString)")
            return nil
        }
        
        // Don't show onboarding on downgrades
        guard current >= lastVersion else {
            return nil
        }
        
        // Check for major upgrade threshold (2.8.1 → 2.9.0)
        let threshold = SemanticVersion(major: 2, minor: 8, patch: 1)
        if lastVersion <= threshold && current >= SemanticVersion(major: 2, minor: 9, patch: 0) {
            return .newUser(reason: .majorUpgrade)
        }
        
        // Check manifest for "What's New" (existing users)
        if let manifest = OnboardingManifest.load(),
           let highlights = manifest.highlights(for: currentVersion),
           defaults.whatsNewShownVersion != currentVersion {
            return .whatsNew(highlights: highlights)
        }
        
        return nil  // No onboarding needed
    }
}
```

**Edge Cases Handled**:
- ✅ Fresh install (`lastLaunchedVersion == nil`)
- ✅ Downgrade (`current < last` → skip)
- ✅ Invalid version strings (fail gracefully)
- ✅ Migration from `UnifiedLegacyNoticeShown`

---

### 3. Manifest System

**File**: `AgentSessions/Onboarding/Resources/onboarding-manifest.json`

```json
{
  "onboarding_version": 1,
  "versions": {
    "2.9.0": {
      "hasMajorUIChanges": true,
      "highlights": [
        {
          "icon": "sparkles",
          "title": "Onboarding Experience",
          "body": "New welcome flow and update notifications help you get started."
        },
        {
          "icon": "arrow.up.circle",
          "title": "Sparkle Auto-Updates",
          "body": "Automatic update checks keep Agent Sessions current."
        },
        {
          "icon": "questionmark.circle",
          "title": "Tour Coming Soon",
          "body": "Interactive UI tour arriving in v2.10 to guide you through key features."
        }
      ]
    },
    "2.10.0": {
      "hasMajorUIChanges": true,
      "highlights": [
        {
          "icon": "map",
          "title": "Interactive Tour",
          "body": "Step-by-step walkthrough of Agent Sessions' core features."
        }
      ]
    }
  }
}
```

**File**: `AgentSessions/Onboarding/Models/OnboardingManifest.swift`

```swift
import Foundation

struct OnboardingManifest: Codable {
    let onboardingVersion: Int
    let versions: [String: VersionConfig]
    
    struct VersionConfig: Codable {
        let hasMajorUIChanges: Bool
        let highlights: [Highlight]?
    }
    
    struct Highlight: Codable, Identifiable {
        let icon: String   // SF Symbol name
        let title: String
        let body: String
        
        var id: String { title }  // For SwiftUI ForEach
    }
    
    /// Load manifest from bundle (cached after first load)
    static func load() -> OnboardingManifest? {
        guard let url = Bundle.main.url(forResource: "onboarding-manifest", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            print("[Onboarding] Failed to load manifest")
            return nil
        }
        
        do {
            return try JSONDecoder().decode(OnboardingManifest.self, from: data)
        } catch {
            print("[Onboarding] Failed to parse manifest: \(error)")
            return nil
        }
    }
    
    /// Get highlights for a specific version (if any)
    func highlights(for version: String) -> [Highlight]? {
        guard let config = versions[version],
              config.hasMajorUIChanges else {
            return nil
        }
        return config.highlights
    }
}
```

**Add to Xcode**: Add `onboarding-manifest.json` to target (Copy Bundle Resources)

---

### 4. Coordinator (State Management)

**File**: `AgentSessions/Onboarding/Models/OnboardingCoordinator.swift`

```swift
import SwiftUI

@MainActor
final class OnboardingCoordinator: ObservableObject {
    @Published var shouldShow: Bool = false
    @Published var onboardingType: OnboardingType?
    
    private let checker = OnboardingVersionChecker()
    private let defaults = UserDefaults.standard
    private var hasChecked = false
    
    /// Call from AgentSessionsApp.onAppear (after indexing completes)
    func checkAndPresentIfNeeded() {
        guard FeatureFlags.enableOnboardingSystem else { return }
        guard !hasChecked else { return }
        hasChecked = true
        
        // Determine type
        guard let type = checker.determineOnboardingType() else {
            return  // No onboarding needed
        }
        
        // Show appropriate flow
        onboardingType = type
        shouldShow = true
    }
    
    /// User completed new user onboarding
    func markOnboardingComplete() {
        guard let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else {
            return
        }
        
        defaults.onboardingCompletedVersion = currentVersion
        defaults.lastLaunchedVersion = currentVersion
        shouldShow = false
    }
    
    /// User saw "What's New"
    func markWhatsNewShown() {
        guard let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else {
            return
        }
        
        defaults.whatsNewShownVersion = currentVersion
        defaults.lastLaunchedVersion = currentVersion
        shouldShow = false
    }
    
    /// User skipped (still record as shown)
    func skip() {
        switch onboardingType {
        case .newUser:
            markOnboardingComplete()
        case .whatsNew:
            markWhatsNewShown()
        case .none:
            break
        }
    }
}
```

---

### 5. App Integration

**File**: `AgentSessions/AgentSessionsApp.swift` (modifications)

```swift
@main
struct AgentSessionsApp: App {
    // ... existing @StateObject declarations ...
    
    // NEW: Add onboarding coordinator
    @StateObject private var onboardingCoordinator = OnboardingCoordinator()
    
    var body: some Scene {
        WindowGroup("Agent Sessions") {
            UnifiedSessionsView(...)
                .onAppear {
                    guard !AppRuntime.isRunningTests else { return }
                    
                    // Wait for indexing before showing onboarding
                    if !(unifiedIndexerHolder.unified?.isIndexing ?? true) {
                        onboardingCoordinator.checkAndPresentIfNeeded()
                    }
                }
                // NEW: Present onboarding as modal sheet
                .sheet(isPresented: $onboardingCoordinator.shouldShow) {
                    // When dismissed, update last launched version
                    updateLastLaunchedVersion()
                } content: {
                    if let type = onboardingCoordinator.onboardingType {
                        OnboardingRootView(type: type, coordinator: onboardingCoordinator)
                    }
                }
        }
        .commands {
            // ... existing commands ...
            
            CommandMenu("Help") {
                Button("Onboarding…") {
                    onboardingCoordinator.onboardingType = .newUser(reason: .freshInstall)
                    onboardingCoordinator.shouldShow = true
                }
                
                Divider()
            }
        }
    }
    
    // NEW: Update version on app termination
    private func updateLastLaunchedVersion() {
        guard let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else {
            return
        }
        UserDefaults.standard.lastLaunchedVersion = version
    }
}

// NEW: Root view that routes to appropriate onboarding flow
struct OnboardingRootView: View {
    let type: OnboardingType
    @ObservedObject var coordinator: OnboardingCoordinator
    
    var body: some View {
        switch type {
        case .newUser:
            OnboardingContainerView(coordinator: coordinator)
        case .whatsNew(let highlights):
            WhatsNewSheet(highlights: highlights, coordinator: coordinator)
        }
    }
}
```

**Also add**: Update `lastLaunchedVersion` on normal app termination (in `init()` or `.onAppear`)

---

### 6. Debug Menu (Testing)

**File**: `AgentSessions/AgentSessionsApp.swift`

```swift
#if DEBUG
.commands {
    CommandMenu("Debug") {
        Button("Reset Onboarding State") {
            UserDefaults.standard.lastLaunchedVersion = nil
            UserDefaults.standard.onboardingCompletedVersion = nil
            UserDefaults.standard.whatsNewShownVersion = nil
        }
        
        Button("Simulate Fresh Install") {
            UserDefaults.standard.lastLaunchedVersion = nil
        }
        
        Button("Simulate 2.8.1 → 2.9 Upgrade") {
            UserDefaults.standard.lastLaunchedVersion = "2.8.1"
            UserDefaults.standard.onboardingCompletedVersion = nil
        }
        
        Button("Force Show What's New") {
            UserDefaults.standard.whatsNewShownVersion = nil
        }
        
        Divider()
        
        Button("Show Onboarding Now") {
            onboardingCoordinator.onboardingType = .newUser(reason: .freshInstall)
            onboardingCoordinator.shouldShow = true
        }
    }
}
#endif
```

---

### 7. Feature Flag

**File**: `AgentSessions/Support/FeatureFlags.swift`

```swift
enum FeatureFlags {
    // ... existing flags ...
    
    /// Gate onboarding system (v2.9+)
    /// Set to false to disable onboarding if issues arise
    static let enableOnboardingSystem = true
}
```

---

## UI Implementation (Key Views)

### New User Onboarding Container

**File**: `AgentSessions/Onboarding/Views/NewUserOnboarding/OnboardingContainerView.swift`

- 600x500 modal sheet
- 4 screens with navigation (Back/Next/Skip)
- Progress dots indicator
- Keyboard shortcuts: Enter (Next), Esc (Skip)

**Screens**:
1. **WelcomeScreen**: App icon + title + description
2. **FirstStepsScreen**: 3-step guide (Browse, Search, Resume)
3. **UIMapScreen**: 4 feature rows (Search, Analytics, Saved, Settings)
4. **FinishScreen**: Success state + "Get Started" CTA

### What's New Sheet

**File**: `AgentSessions/Onboarding/Views/WhatsNew/WhatsNewSheet.swift`

- 500x550 compact sheet
- Header: Icon + "What's New" + version number
- 2-3 highlight cards from manifest
- Footer: "Continue" (primary) + "View Release Notes" (secondary)

---

## Testing Strategy

### Manual Testing Checklist

**Scenario 1: Fresh Install**
- [ ] Delete app, clear UserDefaults: `defaults delete com.triada.AgentSessions`
- [ ] Launch app → Should show new user onboarding
- [ ] Complete onboarding → Record `onboardingCompletedVersion = 2.9.0`
- [ ] Quit and relaunch → Should NOT show onboarding again

**Scenario 2: Upgrade from 2.8.1**
- [ ] Set version: `defaults write com.triada.AgentSessions OnboardingLastLaunchedVersion "2.8.1"`
- [ ] Launch app → Should show new user onboarding
- [ ] Skip onboarding → Still record as complete
- [ ] Relaunch → Should NOT show onboarding again

**Scenario 3: Upgrade from 2.9.0 → 2.10.0** (future)
- [ ] Set version to 2.9.0, launch, complete onboarding
- [ ] Bump version to 2.10.0 in manifest with `hasMajorUIChanges = true`
- [ ] Launch app → Should show "What's New" sheet (not full onboarding)
- [ ] Dismiss → Record `whatsNewShownVersion = 2.10.0`

**Scenario 4: Downgrade**
- [ ] Set `lastLaunchedVersion = 2.10.0`
- [ ] Launch app v2.9.0 → Should NOT show onboarding (graceful skip)

**Scenario 5: Menu Bar Only Mode**
- [ ] Enable menu bar mode (hide dock icon)
- [ ] Launch app → Onboarding should wait until main window opens

**Scenario 6: Accessibility**
- [ ] Enable VoiceOver → All buttons should have labels
- [ ] Test keyboard navigation: Tab, Space, Enter, Esc
- [ ] Test with large text (200% zoom)
- [ ] Test with "Reduce Motion" enabled (no animations)

### Automated Testing

**Unit Tests**: `AgentSessionsTests/OnboardingVersionCheckerTests.swift`

Test cases:
- Fresh install detection
- Upgrade from 2.8.1 detection
- Downgrade handling (skip)
- Invalid version parsing (graceful failure)
- Migration from `UnifiedLegacyNoticeShown`

---

## Accessibility Checklist

- [ ] **VoiceOver**: All buttons, images, navigation elements have labels
- [ ] **Keyboard Navigation**: Full support for Tab, Space, Enter, Esc
- [ ] **Focus Management**: Logical tab order (top-to-bottom, left-to-right)
- [ ] **Reduced Motion**: Disable/simplify animations if enabled
- [ ] **High Contrast**: Test with "Increase Contrast" setting
- [ ] **Large Text**: Test at 200% zoom (Dynamic Type)
- [ ] **Color Blindness**: Don't rely solely on color (use icons + text)

---

## Performance Considerations

- **Launch Time Impact**: Target < 50ms for onboarding check (non-blocking)
- **Manifest Loading**: Lazy load (only when needed), cache after first parse
- **Sheet Presentation**: Non-blocking (app is usable even if onboarding fails)
- **Memory**: All views should be lightweight (no heavy assets)

**Profiling**: Use existing `LaunchProfiler` to measure impact

---

## Sparkle Coordination

Since we're using **"Use Sparkle for changelogs, our system only for tour"**:

### Sparkle's Role:
- Shows release notes from `appcast.xml` on update
- Lists all changes (bug fixes, features, etc.)
- Standard macOS update UX

### Our System's Role (v2.9):
- **New users**: Show full onboarding (not Sparkle-related)
- **Existing users**: Show "What's New" highlights **after** Sparkle notes
  - Highlights are high-level (2-3 major changes)
  - Offer context and next steps (e.g., "Tour coming in v2.10")

### Coordination Flow:
1. User updates from 2.8.1 → 2.9.0 via Sparkle
2. Sparkle shows release notes (traditional changelog)
3. User closes Sparkle, opens app
4. Our system detects major upgrade, shows "What's New" sheet
5. "What's New" says: "View full changelog" → links to GitHub releases

**No duplication**: Sparkle = detailed changelog, Ours = visual highlights + tour teaser

---

## Risk Assessment

| Component | Risk Level | Mitigation |
|-----------|-----------|------------|
| Version detection | **Low** | Graceful fallback, unit tests |
| Manifest parsing | **Low** | Fail-safe (skip if invalid) |
| Sheet presentation | **Medium** | Test across window modes |
| Launch timing | **Medium** | Wait for indexing, test menu bar mode |
| Accessibility | **Low** | Follow macOS guidelines |
| Performance | **Low** | Lightweight views, lazy loading |

**Overall Risk**: **Low** 🟢

---

## Success Criteria

### Must Have (v2.9.0):
- ✅ Fresh install users see new user onboarding
- ✅ Upgrades from <= 2.8.1 see new user onboarding
- ✅ Upgrades from >= 2.9.0 see "What's New" (when manifest indicates)
- ✅ Onboarding can be skipped without errors
- ✅ Onboarding can be re-opened from Help menu
- ✅ No crashes or blocking issues
- ✅ Accessible (VoiceOver, keyboard)
- ✅ No launch time regression (< 50ms impact)

### Nice to Have (v2.9.0):
- ⚪ Beautiful animations (slide transitions)
- ⚪ Custom illustrations (SF Symbols acceptable)

### Deferred to v2.10:
- ⏸️ Interactive tour with coach marks
- ⏸️ Video walkthroughs
- ⏸️ Localization

---

## Future Enhancements (v2.10+)

### Tour with Coach Marks
- Implement overlay positioning for specific UI elements
- Use third-party library or custom SwiftUI solution
- Handle layout mode changes (horizontal ↔ vertical)
- Add "Take a Tour" button to What's New sheet

### Additional Features
- Localization (support for multiple languages)
- Custom illustrations (replace SF Symbols with branded assets)
- Video walkthroughs (embed in onboarding or link externally)
- Analytics tracking (track completion rates locally for improvement)

---

## Release Notes for v2.9.0

**Draft release notes** (for appcast.xml and GitHub release):

```markdown
## What's New in Agent Sessions 2.9.0

### 🎉 Onboarding Experience
- **New user welcome flow**: First-time users see a guided introduction to Agent Sessions
- **Update notifications**: Existing users get highlights of major UI changes
- **Keyboard-friendly**: Full support for keyboard navigation (Tab, Enter, Esc)
- **Accessible**: VoiceOver support and large text compatibility

### ⚙️ Under the Hood
- Improved version detection and upgrade handling
- Manifest-driven update notifications (easily customizable for future versions)
- Graceful handling of edge cases (downgrades, invalid versions)

### 🔮 Coming Soon
- **Interactive Tour** (v2.10): Step-by-step walkthrough of key features

---

**Note**: All users upgrading from v2.8.1 or earlier will see the new onboarding flow on first launch.
```

---

## Summary

**v2.9.0 Scope (Simplified)**:
- ✅ New user onboarding (4 screens)
- ✅ "What's New" highlights (compact sheet)
- ✅ Sparkle for changelogs, our system for tour teaser
- ✅ Manifest-driven (future-proof)
- ✅ Accessible, keyboard-friendly
- ✅ SF Symbols only (no custom illustrations)
- ❌ No coach mark tour (deferred to v2.10)

**Estimated Effort**: 24-32 hours (3-4 days)

**Risk Level**: Low 🟢

**Ready to Implement**: Yes ✅

---

**Next Step**: Begin Phase 1 (Foundation) implementation.
