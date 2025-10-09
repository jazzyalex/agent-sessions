# macOS 13 Ventura Compatibility Requirements

## Current Status

**Agent Sessions v2.2**
- **Minimum macOS:** 14.0 (Sonoma)
- **Intel Mac Support:** 2018+ (8th-gen Intel or Xeon-W)
- **Deployment Target:** `MACOSX_DEPLOYMENT_TARGET = 14.0`

## Why macOS 14 is Currently Required

The app uses **SwiftUI's two-parameter `.onChange(of:)` syntax**, which was introduced in macOS 14.0 (iOS 17.0):

```swift
// macOS 14+ syntax (CURRENT)
.onChange(of: value) { oldValue, newValue in
    // Handle change with access to both old and new values
}
```

This syntax appears **44 times** across the codebase in 9 files.

## Compatibility Analysis for macOS 13 Ventura

### ✅ Compatible APIs

All other SwiftUI features used in the app are **already compatible** with macOS 13:

| API | Availability | Status |
|-----|--------------|---------|
| `Table` with `sortOrder` | macOS 12.0+ | ✅ Compatible |
| `HSplitView` / `VSplitView` | macOS 11.0+ | ✅ Compatible |
| `ProcessInfo.isLowPowerModeEnabled` | macOS 12.0+ | ✅ Already wrapped in `#available` |
| Standard SwiftUI views | macOS 11.0+ | ✅ Compatible |

### ⚠️ Blocker: `.onChange()` Syntax

**Primary Issue:**
- **44 instances** of two-parameter `.onChange(of:)` across 9 files
- Only **2 instances** actually use the `oldValue` parameter
- **42 instances** ignore `oldValue` (use `_` placeholder or don't read it)

**Files Requiring Changes:**

1. `AgentSessions/Views/PreferencesView.swift`
2. `AgentSessions/Views/UnifiedSessionsView.swift`
3. `AgentSessions/Views/TranscriptPlainView.swift`
4. `AgentSessions/Views/SearchFiltersView.swift` (uses `oldValue`)
5. `AgentSessions/Views/ClaudeSessionsView.swift` (uses `oldValue`)
6. `AgentSessions/AgentSessionsApp.swift`
7. `AgentSessions/Views/SessionsListView.swift`
8. `AgentSessions/MenuBar/SettingsUpdateProxy.swift`
9. `AgentSessions/Resume/CodexResumeSheet.swift`

## Benefits of Supporting macOS 13 Ventura

### Extended Hardware Compatibility

Lowering the deployment target to macOS 13 would add support for:

| macOS Version | Intel Mac Support | Years |
|---------------|-------------------|-------|
| **macOS 14 Sonoma** (current) | 2018+ (8th-gen Intel) | 7 years old |
| **macOS 13 Ventura** (target) | 2017+ (7th-gen Intel) | 8 years old |

**Additional Supported Models:**
- MacBook Pro 2017 (13" and 15")
- iMac 2017 (21.5" and 27")
- MacBook 2017
- MacBook Air 2017

### macOS 13 Support Timeline

- **Current Status:** Still receives security updates from Apple
- **Active Support:** Until late 2026 (expected)
- **User Base:** Significant number of 2017-2018 Intel Mac users

## Required Changes for macOS 13 Support

### 1. Update Xcode Project Configuration

**File:** `AgentSessions.xcodeproj/project.pbxproj`

Change deployment target in both Debug and Release configurations:

```diff
- MACOSX_DEPLOYMENT_TARGET = 14.0;
+ MACOSX_DEPLOYMENT_TARGET = 13.0;
```

(Appears in lines ~640 and ~709)

### 2. Update `.onChange()` Syntax

Convert from two-parameter to single-parameter syntax:

```swift
// BEFORE (macOS 14+)
.onChange(of: value) { oldValue, newValue in
    handleChange(newValue)
}

// AFTER (macOS 13+)
.onChange(of: value) { newValue in
    handleChange(newValue)
}
```

**Scope:** 44 instances across 9 files

### 3. Handle Cases Using `oldValue`

For the **2 instances** that actually use `oldValue`, add manual state tracking:

#### Example: SearchFiltersView.swift:46

```swift
// BEFORE
.onChange(of: indexer.activeSearchUI) { oldValue, newValue in
    if oldValue != .sessionSearch && newValue == .sessionSearch {
        showSearchPopover = true
    }
}

// AFTER (with manual tracking)
@State private var previousSearchUI: SearchUI = .none

// ...
.onChange(of: indexer.activeSearchUI) { newValue in
    if previousSearchUI != .sessionSearch && newValue == .sessionSearch {
        showSearchPopover = true
    }
    previousSearchUI = newValue
}
```

#### Example: ClaudeSessionsView.swift:285

```swift
// BEFORE
.onChange(of: tableSelection) { oldSel, newSel in
    if newSel.count > 1 {
        let newItem = newSel.subtracting(oldSel).first ?? newSel.first
        tableSelection = Set([newItem].compactMap { $0 })
    }
}

// AFTER (with manual tracking)
@State private var previousSelection: Set<String> = []

// ...
.onChange(of: tableSelection) { newSel in
    if newSel.count > 1 {
        let newItem = newSel.subtracting(previousSelection).first ?? newSel.first
        tableSelection = Set([newItem].compactMap { $0 })
    }
    previousSelection = newSel
}
```

## Impact Assessment

### Development Impact

| Area | Impact | Notes |
|------|--------|-------|
| **Code Changes** | Moderate | 44 changes across 9 files |
| **Complexity** | Low | Straightforward syntax conversion |
| **Testing** | Minimal | No functional changes |
| **Maintenance** | None | Uses stable, proven API |

### Functional Impact

- ✅ **No functionality loss**
- ✅ **No performance impact**
- ✅ **No UI changes**
- ✅ **No behavior changes**

### Future Considerations

#### API Stability

The single-parameter `.onChange(of:perform:)` syntax:
- ✅ Available since macOS 11.0 (Big Sur)
- ✅ Proven stable over 4+ years
- ⚠️ Deprecated in macOS 14.0, but **NOT removed**
- ✅ Apple maintains deprecated SwiftUI APIs for many years
- ✅ Still compiles on macOS 14+ (with deprecation warnings)
- ✅ No risk of removal in foreseeable future

#### Deprecation Policy

Apple's historical pattern with SwiftUI:
- Deprecated APIs remain functional indefinitely
- Removal would break thousands of apps
- Backward compatibility is prioritized
- Example: Many iOS 13-era APIs still work in iOS 18+

## Alternative Approach: Dual Support (NOT RECOMMENDED)

It's possible to maintain both syntaxes using availability checks, but this adds unnecessary complexity:

```swift
// Complex approach - NOT RECOMMENDED
if #available(macOS 14, *) {
    view.onChange(of: value) { oldValue, newValue in
        handleChange(newValue)
    }
} else {
    view.onChange(of: value) { newValue in
        handleChange(newValue)
    }
}
```

**Why NOT recommended:**
- Adds 88 lines of conditional compilation (44 instances × 2)
- No functional benefit
- Harder to maintain
- Only 2 cases actually use `oldValue`
- Manual tracking is simpler and clearer

## Recommendation

**Best path forward for macOS 13 support:**

1. ✅ Lower deployment target to `macOS 13.0`
2. ✅ Convert all 44 `.onChange` calls to single-parameter syntax
3. ✅ Add `@State` tracking for 2 cases using `oldValue`
4. ❌ Skip availability checks (unnecessary complexity)

**Benefits:**
- ✅ Supports 2017+ Intel Macs (wider compatibility)
- ✅ Uses stable, proven API (no future deprecation concerns)
- ✅ Simpler codebase (no conditional compilation)
- ✅ Zero impact on functionality
- ✅ No maintenance burden

**Trade-offs:**
- None - the two-parameter syntax offers no real advantage for this codebase

## References

### SwiftUI API Documentation

- [Table (macOS 12.0+)](https://developer.apple.com/documentation/swiftui/table)
- [HSplitView (macOS 11.0+)](https://developer.apple.com/documentation/swiftui/hsplitview)
- [onChange(of:perform:) - Deprecated in macOS 14.0](https://developer.apple.com/documentation/swiftui/view/onchange(of:perform:))

### macOS Compatibility

- [macOS Sonoma - Compatible Computers](https://support.apple.com/en-us/105113)
- [macOS Ventura - System Requirements](https://support.apple.com/en-us/HT213264)

### Related Documentation

- `docs/deployment.md` - Release and deployment process
- `AgentSessions.xcodeproj/project.pbxproj` - Build configuration
- `README.md` - Installation and compatibility information

---

**Document Version:** 1.0
**Last Updated:** 2025-10-08
**Agent Sessions Version:** 2.2
**Author:** Technical Documentation
