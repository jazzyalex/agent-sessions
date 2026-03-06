# Agent Cockpit HUD — Implementation Guide

> For: Codex / Claude Code agents
> Companion to: `docs/cockpit-hud-mockup.html`, `docs/cockpit-ux-spec.md`
> Scope: New HUD window only. Does not modify the existing CockpitView (now "Agent Cockpit
> Table"). No existing file may be modified or removed — add only.

---

## Naming Conventions (enforced throughout)

| Surface                | Name                  | Notes                                                         |
|------------------------|-----------------------|---------------------------------------------------------------|
| New floating panel     | Agent Cockpit HUD     | Window title. Users call it "Cockpit".                        |
| Existing sessions window | Session List        | Main Agent Sessions window — all sessions, idle, and past.    |
| Window ID (SwiftUI)    | `"CockpitHUD"`        | Alongside existing `"Cockpit"`.                               |
| Feature umbrella       | Agent Cockpit         | Used in menu items, preferences.                              |
| Footer button          | "Session List →"      | Opens the main Agent Sessions window, not a separate table.   |

---

## State Model (v1 — keep it simple)

Two states only. No "waiting", no "error".

```swift
enum HUDLiveState {
    case active  // agent is working — no action needed, all good
    case idle    // waiting for user input — NEEDS ATTENTION ("Waiting" in UI copy)
}
```

**Visual hierarchy (CRITICAL):**
- `waiting` (`idle` state) = needs user attention → loud amber pulsing dot (the loudest element)
- `active` = agent is working fine → calm static green dot (visible but not demanding)

Detection maps directly from `CodexActiveSessionsModel`:
- `.activeWorking` → `HUDLiveState.active`
- `.openIdle` → `HUDLiveState.idle`

Do not add any additional state inference, heuristic detection, or process probing
beyond what the existing model already provides.

---

## Files to Create

```
AgentSessions/Views/
  AgentCockpitHUDView.swift          Main panel view (header + body + footer)
  AgentCockpitHUDRowView.swift       Single session row
  AgentCockpitHUDGroupHeader.swift   Project group header row
  AgentCockpitHUDWindow.swift        NSPanel subclass + window controller
```

Register all four with `scripts/xcode_add_file.rb` under `AgentSessions/Views` before
building. Do not add them directly to `project.pbxproj`.

---

## Step 1 — NSPanel (AgentCockpitHUDWindow.swift)

```swift
final class AgentCockpitHUDPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 644, height: 320),
            styleMask: [.nonactivatingPanel, .titled, .closable,
                        .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        level                       = .floating
        collectionBehavior          = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        hidesOnDeactivate           = false
        titleVisibility             = .hidden
        titlebarAppearsTransparent  = true
        setFrameAutosaveName("AgentCockpitHUDWindow")
    }
}
```

Host `AgentCockpitHUDView` in an `NSHostingView` as the panel's `contentView`.

### Window resize behavior

The window NEVER auto-resizes when sessions are added or removed. The user sets the
window size manually and it stays fixed. Overflow uses a scrollbar.

- **Full mode:** user-resizable, default 644x320. Scrollbar appears when rows exceed
  the visible area. When sessions are removed, the list gets shorter and space is empty.
  When sessions are added, a brief highlight animation on the new row draws attention.
- **Compact mode:** user-resizable height, fixed width. Default shows 5 rows.
  Minimum 3 rows. Scrollbar for overflow.

### Empty state

- **Full mode:** centered empty state message — "No active sessions"
- **Compact mode:** single muted line — "No sessions" with a muted dot

---

## Step 2 — Session Data Shape

```swift
struct HUDRow: Identifiable {
    let id: String                // sessionId or normalized log path
    let agentType: HUDAgentType   // .codex, .claude, .shell
    let projectName: String       // repo basename (for grouping)
    let displayName: String       // session title or branch name
    let liveState: HUDLiveState   // .active | .idle (idle = needs attention)
    let preview: String           // last output line, or "Waiting for input — 47m"
    let elapsed: String           // e.g. "12m", "3m", "2h"
    let itermSessionId: String?
    let revealUrl: String?
    var manualOrder: Int?         // nil = auto-sort; set by drag-to-reorder
}

enum HUDAgentType {
    case codex, claude, shell
    var label: String {
        switch self { case .codex: "Codex"; case .claude: "Claude"; case .shell: "Shell" }
    }
}
```

Build `[HUDRow]` from `CodexActiveSessionsModel.presences` in a computed property.
Refresh whenever `activeMembershipVersion` changes.

### Sort order

Idle first (needs user attention), then active (working, no action needed).
Within each group, sort by recency descending (most recently changed state on top).

**Recency-stable ordering:** do NOT re-sort while the Cockpit window is visible/focused.
Only re-sort when the window reappears after being hidden or minimized. This prevents
the list from jumping around while the user is looking at it. (Same pattern as chat apps
with unread ordering.)

### Manual reordering

Support drag-to-reorder rows. When the user drags a row to a new position, store the
custom order as an array of session IDs in UserDefaults (`cockpitHUDRowOrder`). Sessions
that have been manually positioned keep their slot. New sessions that haven't been manually
positioned fall back to the recency sort and appear at the top of their state group.

If a manually-positioned session ends, its slot stays reserved for one poll cycle (show
"ended" in the preview column), then remove it and compact the list.

### No row numbers

Do NOT display a `#` column. Row numbers change when sessions come and go, making them
useless for muscle memory. Keyboard shortcuts (`⌘1`–`⌘9`) bind to the current visual
order, which is stable while the window is visible.

---

## Step 3 — Header View

```
┌ Agent Cockpit                    [● 3 active] [○ 2 idle] ┐
│ [⌕ Filter sessions…         ⌘K] [⊞ By Project]          │
└──────────────────────────────────────────────────────────┘
```

### Count chips — interactive filters

The chips (active / idle) are toggle buttons that filter the visible row list.

```swift
@State private var chipFilter: HUDLiveState? = nil
// nil  → show all
// .active → show only active rows
// .idle   → show only idle rows
```

- Tapping a chip that is off: sets `chipFilter` to that state.
- Tapping the active chip again: sets `chipFilter = nil` (shows all).
- Both chips are always visible; the non-selected chip renders at reduced opacity.
- Chip labels show the live count, e.g. "3 active", "2 waiting".

```swift
// Active chip — static green dot (working, all good)
Button {
    chipFilter = chipFilter == .active ? nil : .active
} label {
    HStack(spacing: 4) {
        Circle().fill(Color(hex: "#30d158")).frame(width:5, height:5)
        Text("\(activeCount) active")
    }
}
.buttonStyle(HUDChipStyle(isOn: chipFilter == nil || chipFilter == .active))

// Waiting chip — pulsing amber dot (needs attention)
Button {
    chipFilter = chipFilter == .idle ? nil : .idle
} label {
    HStack(spacing: 4) {
        Circle().fill(amberColor).frame(width:5, height:5)
            // pulse animation matching row dots
        Text("\(idleCount) waiting")
    }
}
.buttonStyle(HUDChipStyle(isOn: chipFilter == nil || chipFilter == .idle))
```

### Search field

Plain `TextField` with a magnifying glass icon. The field is always visible — do not
hide it or make it a separate "mode". When text is non-empty, the visible rows narrow
to those whose `projectName` or `displayName` contains the query (case-insensitive).
Show an `esc` badge inside the field when text is present. `⌘K` focuses the field and
selects all text. `Escape` clears text and returns focus to the row list.

Chip filtering and text filtering are composable: if a chip filter is active and the
user types, both constraints apply simultaneously.

### By Project toggle

A small button that persists `groupByProject` in UserDefaults. When on, the body
switches from a flat list to a grouped list. The toggle state is independent of
chip and text filters.

---

## Step 4 — Body: Flat List (default)

When `groupByProject == false`:

```
[visible rows, filtered by chipFilter and filterText, sorted idle-first (needs attention)]
  ── visual divider between idle and active sections ──
```

No row number column. Keyboard shortcuts `⌘1`–`⌘9` bind to the current visual order.

---

## Step 5 — Body: Grouped List

When `groupByProject == true`, group rows by `projectName`. Sort groups: groups with
any `.idle` session (needs attention) appear before active-only groups. Within each
group, sort rows `.idle` first (needs attention on top).

Each group has a collapsible header (`AgentCockpitHUDGroupHeader`):

- Clicking the header collapses/expands that group's rows.
- The header shows: project name + summary badge ("1 active · 1 waiting" etc.).
- Collapsed state persists only for the current session (not to disk).

Chip and text filters still apply inside grouped view: rows that don't match are hidden,
and empty groups (all rows filtered out) are hidden too.

---

## Step 6 — AgentCockpitHUDRowView.swift

Fixed grid layout (7 columns — no row number column):

```
[9px dot] [auto badge] [120pt name] [110pt branch] [1fr preview] [auto time] [56pt kbd]
```

**Agent badge:** `Text(row.agentType.label)` at 9pt bold monospaced, with agent-specific
tint. Light mode: Codex text `#5856d6` on `rgba(94,92,230,0.09)` bg with `0.16` border,
Claude text `#c47700` on `rgba(255,149,0,0.09)` bg with `0.16` border, Shell text
`#8e8e93` on `rgba(0,0,0,0.05)` bg. Dark mode: Codex `#9e9cf8`, Claude `#ffb340`,
Shell `#6e6e73`.

**Status dot (7pt diameter, no outer frame):**
- `.active` → static green `#30d158`, NO animation. Agent is working, no action needed.
- `.idle` → pulsing amber, NEEDS ATTENTION (waiting for user input).
  Amber color: light `#e08600`, dark `#ffb340`.
  Animation: `Circle().scaleEffect(pulse).opacity(pulseOpacity)` with repeating
  animation (scale 1.0→1.25, opacity 1.0→0.85, halo opacity peak 0.65, 1.4s easeInOut).
  Respect `accessibilityReduceMotion` — disable animation if true (show static amber).

**Idle row opacity:** apply `.opacity(0.60)` to the entire row when `liveState == .idle`.

**Drag handle:** support `onMove` for drag-to-reorder. Use a `≡` drag indicator that
appears on hover at the leading edge of the row (before the dot).

**Row interaction:**
- `.onTapGesture { focusSession(row) }` — single tap focuses the terminal (primary
  action, full row is the target).
- No right-click context menu. No secondary buttons.

**`focusSession`:** mirrors the existing `CockpitView` iTerm2 AppleScript focus logic.
Attempt `itermSessionId` first, fall back to `revealUrl`. No-op if neither is available.

---

## Step 7 — Keyboard Navigation

```swift
// ⌘1–⌘9: jump to visible row by index
.keyboardShortcut(KeyEquivalent(Character(String(n))), modifiers: .command)
// Wraps a hidden Button per index, guarded by visibleRows.indices.contains(n-1)

// Up/Down: move selection within list
.onKeyPress(.upArrow)   { selectPrevious(); return .handled }
.onKeyPress(.downArrow) { selectNext();     return .handled }

// Enter: focus selected row
.onKeyPress(.return) { if let sel = selectedRow { focusSession(sel) }; return .handled }

// ⌘K: focus search field
.keyboardShortcut("k", modifiers: .command) // on a hidden Button that calls focusSearchField()

// Esc: clear filter (handled in TextField .onExitCommand)
```

Use `@FocusState` to track whether the search field is focused vs. the row list.
When the search field is focused, Up/Down and Enter operate on the filtered row list
(not the field). `Tab` moves focus from field to first row.

---

## Step 8 — Compact Mode

Compact mode hides the filter bar and the footer, leaving only the topbar (title, chips,
pin/compact buttons) and the session list. It is the minimal "ambient glance" state.

**Compact window sizing:** Fixed height showing 5 rows by default. The user can drag the
window edge to show more (up to all sessions) or fewer (minimum 3 rows). The window does
NOT auto-resize when sessions are added/removed — overflow shows a scrollbar.

### View changes

Bind a `@State var isCompact: Bool` (restored from `PreferencesKey.Cockpit.hudCompact`).

```swift
VStack(spacing: 0) {
    AgentCockpitHUDHeaderView(isCompact: $isCompact, isPinned: $isPinned, ...)
    Divider()
    AgentCockpitHUDBodyView(...)
    if !isCompact {
        Divider()
        AgentCockpitHUDFooterView()
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
.animation(.easeInOut(duration: 0.18), value: isCompact)
```

Apply the same `transition` + `animation` to the filter bar inside the header view:

```swift
if !isCompact {
    AgentCockpitHUDFilterBar(...)
        .transition(.move(edge: .top).combined(with: .opacity))
}
```

### Compact toggle button

Place in the trailing edge of the header topbar, to the right of the pin button:

```swift
Button {
    withAnimation(.easeInOut(duration: 0.18)) { isCompact.toggle() }
    UserDefaults.standard.set(isCompact, forKey: PreferencesKey.Cockpit.hudCompact)
} label: {
    Image(systemName: isCompact ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
        .font(.system(size: 11, weight: .medium))
}
.buttonStyle(HUDIconButtonStyle(isOn: isCompact))
.help(isCompact ? "Show filter and navigation" : "Compact mode")
```

Use `.keyboardShortcut("m", modifiers: [.command, .shift])` for discoverability.

---

## Step 8b — Pin Window

Pin keeps the HUD floating above all other windows, including full-screen apps. It
changes `NSPanel.level` at runtime — no window recreation needed.

```swift
func setPinned(_ pinned: Bool) {
    guard let panel = NSApp.windows.first(where: { $0.identifier?.rawValue == "CockpitHUD" })
            as? AgentCockpitHUDPanel else { return }
    panel.level = pinned ? .screenSaver : .floating
    // .screenSaver floats above full-screen apps; .floating is standard always-on-top
    // Prefer .floating as default; only elevate to .screenSaver if user explicitly pins
    UserDefaults.standard.set(pinned, forKey: PreferencesKey.Cockpit.hudPinned)
}
```

Restore on launch: call `setPinned(true)` after window creation if `hudPinned == true`.

### Pin button

Place at the trailing edge of the topbar, left of the compact button:

```swift
Button {
    isPinned.toggle()
    setPinned(isPinned)
} label: {
    HStack(spacing: 4) {
        Image(systemName: isPinned ? "pin.fill" : "pin")
            .font(.system(size: 10, weight: .medium))
        Text(isPinned ? "Pinned" : "Pin")
            .font(.system(size: 10.5, weight: .semibold))
    }
}
.buttonStyle(HUDIconButtonStyle(isOn: isPinned, tint: isPinned ? .orange : nil))
.help(isPinned ? "Unpin — stop keeping on top" : "Pin — keep above all windows")
```

`HUDIconButtonStyle` is a custom `ButtonStyle` matching the small rounded pill shape
shown in the mockup. When `tint` is non-nil (pinned state), it applies an orange-tinted
background to distinguish pin from the blue accent used by By Project and compact.

---

## Step 9 — Footer

```swift
HStack {
    Button("Session List →") { openWindow(id: "Cockpit") }
        .buttonStyle(HUDFooterButtonStyle())
    Spacer()
    Text(freshnessLabel)
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.secondary.opacity(0.5))
}
```

`freshnessLabel`: derives from `Date()` minus last poll timestamp from
`CodexActiveSessionsModel`. Update via `Timer.publish(every: 5, ...)`.
Format: "just now" (< 5s), "Ns ago" (< 60s), "Nm ago" (≥ 60s).

---

## Step 9 — Window Registration (AgentSessionsApp.swift)

Add alongside the existing `WindowGroup("Cockpit", id: "Cockpit")`:

```swift
WindowGroup("Agent Cockpit", id: "CockpitHUD") {
    AgentCockpitHUDView(codexIndexer: indexer)
        .environmentObject(activeCodexSessions)
}
.windowStyle(.plain)
.windowResizability(.contentSize)
.defaultSize(width: 644, height: 320)
```

After window creation, promote to `NSPanel` level using a `WindowAccessor` helper view
that captures the `NSWindow` reference and calls `panel.level = .floating`, or use
`AgentCockpitHUDPanel` initialized via `AppDelegate` outside SwiftUI's WindowGroup.

Add a **View menu** item:

```
View → Agent Cockpit     ⌥⌘C
```

Add a toolbar button in the existing `CockpitView` (Session List):

```swift
ToolbarItem { Button("HUD") { openWindow(id: "CockpitHUD") } }
```

---

## Step 10 — Consumer Visibility

```swift
private let consumerID = UUID()

.onAppear    { activeCodexSessions.setCockpitConsumerVisible(true,  consumerID: consumerID) }
.onDisappear { activeCodexSessions.setCockpitConsumerVisible(false, consumerID: consumerID) }
```

This keeps polling at the 2s foreground cadence while the HUD is open.

---

## Step 11 — New Preference Keys

Add to `PreferencesConstants.swift` under `PreferencesKey.Cockpit`:

```swift
static let hudOpen           = "cockpitHUDOpen"           // Bool,   default false
static let hudGroupByProject = "cockpitHUDGroupByProject" // Bool,   default false
static let hudCompact        = "cockpitHUDCompact"        // Bool,   default false
static let hudPinned         = "cockpitHUDPinned"         // Bool,   default false
static let hudRowOrder       = "cockpitHUDRowOrder"       // [String], default [] (session IDs for manual order)
```

Persist all four immediately on toggle. Restore on launch.

`hudCompact` controls whether the filter bar and footer are hidden.
`hudPinned` controls `NSPanel.level` (see Pin section below).

---

## Step 12 — Build Checklist

Before presenting results:

1. Add all four Swift files via `scripts/xcode_add_file.rb`.
2. Build: `xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug build`
3. Confirm zero build errors and zero new warnings.

---

## Step 13 — QA Checklist

Test every item below after the build succeeds. Report pass/fail for each.

### Window behavior
- [ ] HUD opens via View → Agent Cockpit (⌥⌘C)
- [ ] HUD opens via toolbar button in the Session List window
- [ ] HUD floats above other app windows when another app is in focus
- [ ] HUD stays visible when switching to another Space (verify `canJoinAllSpaces`)
- [ ] HUD is draggable by clicking anywhere on the background
- [ ] Window position is restored correctly after quit and relaunch
- [ ] Closing the HUD does not close the main app or the Session List window
- [ ] "Session List →" footer button opens the Session List window

### Session display
- [ ] Active sessions appear with a static green (#30d158) dot — NO pulse
- [ ] Idle sessions appear with a pulsing amber dot (light: #e08600, dark: #ffb340)
- [ ] Idle pulse is clearly visible in light mode (scale 1.25, halo opacity 0.65)
- [ ] Idle rows have opacity 0.60 (not 0.55)
- [ ] Idle sessions sort ABOVE active sessions in flat view (needs attention first)
- [ ] No row number (#) column is displayed
- [ ] Session name, branch, preview, and elapsed time all display correctly
- [ ] Preview text truncates with ellipsis and does not wrap
- [ ] Agent badge label reads "Codex", "Claude", or "Shell" (not CC/CX/$_)
- [ ] No stale `Idle` copy appears anywhere user-facing; non-active rows read as `Waiting`

### Chip filters
- [ ] Tapping "active" chip hides all waiting rows; waiting chip dims
- [ ] Tapping "waiting" chip hides all active rows; active chip dims
- [ ] Tapping the active chip again (while it is the filter) restores all rows
- [ ] Keyboard shortcuts re-map correctly after chip filtering
- [ ] The flat divider between active and waiting sections hides when chip filter is active
- [ ] Chip counts update when sessions change state (active ↔ waiting)

### Text filter
- [ ] Typing in the search field narrows rows in real time (no separate "mode")
- [ ] Matching text in session name is bolded/highlighted
- [ ] The list shows all sessions again when filter text is cleared
- [ ] `⌘K` focuses the search field and selects all existing text
- [ ] `Escape` clears the filter and returns to the previous view state
- [ ] Chip filter and text filter compose correctly (both constraints apply)
- [ ] Filtering while "By Project" is on hides non-matching rows and collapses
      project groups that have no matching sessions

### Grouping
- [ ] "By Project" toggle groups sessions under their repo name
- [ ] Groups with active sessions appear above waiting-only groups
- [ ] Group badge shows correct count summary ("1 active · 1 waiting", "2 active", etc.)
- [ ] Clicking a group header collapses its rows; clicking again expands them
- [ ] Collapsed state does not persist across HUD close/reopen
- [ ] "By Project" preference is saved and restored after quit/relaunch

### Keyboard navigation
- [ ] `⌘1` through `⌘9` focus the terminal for the corresponding visible row
- [ ] `Up` / `Down` arrow keys move selection through visible rows
- [ ] `Return` on a selected row focuses that session's terminal
- [ ] `⌘K` shortcut works even when the search field is not visible/focused
- [ ] Keyboard shortcuts re-map correctly after chip or text filtering changes visible rows

### Row interaction
- [ ] Single click anywhere on a row calls `focusSession` (brings iTerm2 tab to front)
- [ ] Rows with no valid `itermSessionId` or `revealUrl` do not crash on click
- [ ] No right-click context menu appears anywhere in the HUD

### Session ordering and drag-reorder
- [ ] Idle sessions appear above active sessions (needs attention first)
- [ ] List does NOT re-sort while the Cockpit window is visible/focused
- [ ] List re-sorts when the window reappears after being hidden
- [ ] Drag-to-reorder works: user can drag a row to a new position
- [ ] Manually reordered sessions keep their position across poll cycles
- [ ] New sessions (not manually positioned) appear at the top of their state group
- [ ] Custom row order is persisted in UserDefaults and restored on relaunch
- [ ] When a manually-positioned session ends, it shows "ended" briefly then removes

### Window resize behavior
- [ ] Window NEVER auto-resizes when sessions are added or removed
- [ ] Full mode: scrollbar appears when rows overflow the visible area
- [ ] Full mode: removing sessions leaves empty space (no collapse)
- [ ] Full mode: adding a session shows a brief highlight animation on the new row
- [ ] Compact mode: fixed height showing 5 rows by default
- [ ] Compact mode: user can drag to resize (minimum 3 rows)
- [ ] Compact mode: scrollbar for overflow

### Empty state
- [ ] Full mode: shows centered "No active sessions" message when list is empty
- [ ] Compact mode: shows single muted line "No sessions" when list is empty

### Live updates
- [ ] Freshness label updates: "just now" → "Ns ago" → "Nm ago"
- [ ] Sessions that become active update their dot from pulsing amber to static green
      without requiring a manual refresh
- [ ] Sessions that become waiting update their dot from static green to pulsing amber
- [ ] Sessions that exit are removed from the list within the next poll cycle (≤ 2s)
- [ ] Chip counts update automatically as session states change

### Accessibility
- [ ] Status dots have accessibility labels ("Active" / "Waiting")
- [ ] Pulsing animation is disabled when Reduce Motion is enabled in System Settings
- [ ] The HUD is fully navigable via VoiceOver (rows announced with name + state)

### Compact mode
- [ ] Clicking the compact button hides the filter bar and footer with a smooth animation
- [ ] Clicking again restores them with the reverse animation
- [ ] Compact state is saved to preferences and restored after quit/relaunch
- [ ] Session list, chips, pin button, and compact button remain fully visible and
      interactive in compact mode
- [ ] Chip filters still work in compact mode
- [ ] `⌘⇧M` keyboard shortcut toggles compact mode
- [ ] Window stays at fixed size when entering compact mode (does not auto-shrink)

### Pin window
- [ ] Clicking "Pin" floats the HUD above all other windows including other apps
- [ ] Clicking "Pinned" (same button) restores normal floating level
- [ ] Pin state is saved to preferences and restored after quit/relaunch
- [ ] Pin button shows filled icon + "Pinned" label with orange tint when active
- [ ] Pinned HUD remains visible when switching to a full-screen app in another Space
- [ ] Unpinning does not close or reposition the window

### Dark / Light mode
- [ ] HUD renders correctly in macOS Dark mode
- [ ] HUD renders correctly in macOS Light mode
- [ ] Switching Appearance in System Settings updates the HUD without relaunch

---

## What Not to Modify

| File                              | Reason                              |
|-----------------------------------|-------------------------------------|
| `CockpitView.swift`               | Existing Session List — untouched |
| `CockpitFooterView.swift`         | Untouched                           |
| `CodexLiveStatusDot.swift`        | Reuse as-is in HUD rows             |
| `CodexActiveSessionsModel.swift`  | No new state, no new polling logic  |
| `AgentSessionsApp.swift`          | Add only: new WindowGroup + menu item |
| `PreferencesConstants.swift`      | Add only: two new keys              |

---

## New Symbols Summary

| Symbol                        | File                              | Kind             |
|-------------------------------|-----------------------------------|------------------|
| `AgentCockpitHUDPanel`        | AgentCockpitHUDWindow.swift       | NSPanel subclass |
| `AgentCockpitHUDView`         | AgentCockpitHUDView.swift         | SwiftUI View     |
| `AgentCockpitHUDRowView`      | AgentCockpitHUDRowView.swift      | SwiftUI View     |
| `AgentCockpitHUDGroupHeader`  | AgentCockpitHUDGroupHeader.swift  | SwiftUI View     |
| `HUDRow`                      | AgentCockpitHUDView.swift         | struct           |
| `HUDLiveState`                | AgentCockpitHUDView.swift         | enum (2 cases)   |
| `HUDAgentType`                | AgentCockpitHUDView.swift         | enum (3 cases)   |
| `PreferencesKey.Cockpit.hudOpen`          | PreferencesConstants.swift | static let |
| `PreferencesKey.Cockpit.hudGroupByProject`| PreferencesConstants.swift | static let |
| `PreferencesKey.Cockpit.hudCompact`       | PreferencesConstants.swift | static let |
| `PreferencesKey.Cockpit.hudPinned`        | PreferencesConstants.swift | static let |
| `PreferencesKey.Cockpit.hudRowOrder`      | PreferencesConstants.swift | static let |
