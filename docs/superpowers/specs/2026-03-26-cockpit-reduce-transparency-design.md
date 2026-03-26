# Cockpit HUD: Reduce Transparency Option

## Problem

The Cockpit HUD uses `.ultraThinMaterial` for its background, which provides a glassy aesthetic but becomes hard to read on dark or busy wallpapers. Text, status dots, and agent names lose contrast and wash out, especially in pinned compact mode where the NSWindow is fully transparent.

## Design

Change the default material from `.ultraThinMaterial` to `.regularMaterial` for better out-of-box readability. Add a "Reduce transparency" toggle in Preferences that switches to `.thickMaterial` for users who want maximum readability. Also respect the macOS system-level "Reduce transparency" accessibility setting.

### Material Ladder

| Condition | Material | Effect |
|-----------|----------|--------|
| Default (new) | `.regularMaterial` | Denser frosted glass, readable on most wallpapers |
| "Reduce transparency" toggle ON | `.thickMaterial` | Near-opaque, maximum readability |
| macOS "Reduce transparency" ON | `.ultraThickMaterial` | Overrides app setting, fully opaque |

### Preference

- **Key:** `CockpitHUDReduceTransparency` (Bool, default `false`)
- **Location:** Preferences > Agent Cockpit, new "Appearance" section before "Live Sessions"
- **Label:** "Reduce transparency"
- **Help text:** "Uses a denser window background for better readability over dark or busy wallpapers."
- **Caption:** "Also respects macOS System Settings > Accessibility > Display > Reduce transparency."

### Files to Modify

1. **`AgentSessions/Views/Preferences/PreferencesConstants.swift`**
   - Add `hudReduceTransparency` to `PreferencesKey.Cockpit`

2. **`AgentSessions/Views/AgentCockpitHUDView.swift`** (line 713)
   - Add `@AppStorage` for the new key
   - Replace `.background(.ultraThinMaterial)` with computed material based on: macOS accessibility > app toggle > default
   - Add `@Environment(\.accessibilityReduceTransparency)` to read system setting

3. **`AgentSessions/Views/Preferences/PreferencesView+General.swift`** (`agentCockpitTab`)
   - Add new "Appearance" section with the toggle, placed before "Live Sessions + Cockpit BETA"

4. **`AgentSessions/Views/PreferencesView.swift`**
   - Add `@AppStorage` property for `hudReduceTransparency`
   - Add to `resetToDefaults()`

### What Does NOT Change

- `HUDLimitsDetailPanel` already uses `.regularMaterial` — no change needed
- Full mode window chrome (`isOpaque = true`, `.windowBackgroundColor`) — unaffected
- `CockpitView.swift` (legacy full-table view) — uses standard window, not affected
- No changes to text colors, status dot colors, or border/shadow values

## Verification

1. Build and run the app
2. Open the Cockpit in compact pinned mode
3. Verify the default material is visibly denser than before (`.regularMaterial`)
4. Toggle "Reduce transparency" ON in Preferences > Agent Cockpit — confirm near-opaque background
5. Toggle macOS System Settings > Accessibility > Display > Reduce transparency — confirm fully opaque
6. Test with light mode, dark mode, and various wallpapers (bright, dark, busy)
7. Confirm full mode appearance is unchanged
