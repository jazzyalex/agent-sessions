# Agent Cockpit HUD — Implementation Guide

> For: Codex / Claude Code agents
> Companion to: `docs/cockpit-hud-mockup.html`, `docs/cockpit-ux-spec.md`
> Scope: New HUD window only. Does not modify the existing CockpitView (now "Agent Cockpit
> Table"). No existing file may be modified or removed — add only.

---

## Naming Conventions (enforced throughout)

| Surface                | Name                  | Notes                                      |
|------------------------|-----------------------|--------------------------------------------|
| New floating panel     | Agent Cockpit HUD     | Window title. Users call it "Cockpit".     |
| Existing table window  | Agent Cockpit Table   | Renamed in display only via window title.  |
| Window ID (SwiftUI)    | `"CockpitHUD"`        | Alongside existing `"Cockpit"`.            |
| Feature umbrella       | Agent Cockpit         | Used in menu items, preferences.           |

---

## State Model (v1 — keep it simple)

Two states only. No "waiting", no "error", no "needs attention".

```swift
enum HUDLiveState {
    case active  // agent is producing output / progressing
    case idle    // session is open but not active
}
```

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

---

## Step 2 — Session Data Shape

```swift
struct HUDRow: Identifiable {
    let id: String                // sessionId or normalized log path
    let agentType: HUDAgentType   // .codex, .claude, .shell
    let projectName: String       // repo basename (for grouping)
    let displayName: String       // session title or branch name
    let liveState: HUDLiveState   // .active | .idle
    let preview: String           // last output line, or "Last active Xm ago"
    let elapsed: String           // e.g. "12m", "3m", "2h"
    let itermSessionId: String?
    let revealUrl: String?
}

enum HUDAgentType {
    case codex, claude, shell
    var label: String {
        switch self { case .codex: "Codex"; case .claude: "Claude"; case .shell: "Shell" }
    }
}
```

Build `[HUDRow]` from `CodexActiveSessionsModel.presences` in a computed property.
Refresh whenever `activeMembershipVersion` changes. Sort: `.active` rows first,
then `.idle` rows. Within each group, sort by `lastSeenAt` descending.

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
- Chip labels show the live count, e.g. "3 active", "2 idle".

```swift
Button {
    chipFilter = chipFilter == .active ? nil : .active
} label {
    HStack(spacing: 4) {
        Circle().fill(Color.green).frame(width:5, height:5)
            // animate if active
        Text("\(activeCount) active")
    }
}
.buttonStyle(HUDChipStyle(isOn: chipFilter == nil || chipFilter == .active))
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
[visible rows, filtered by chipFilter and filterText, sorted active-first]
  ── visual divider between active and idle sections ──
```

Row numbering: assign 1-based indices over the *visible* sorted array after filters
are applied.

---

## Step 5 — Body: Grouped List

When `groupByProject == true`, group rows by `projectName`. Sort groups: groups with
any `.active` session appear before idle-only groups. Within each group, sort rows
`.active` first.

Each group has a collapsible header (`AgentCockpitHUDGroupHeader`):

- Clicking the header collapses/expands that group's rows.
- The header shows: project name + summary badge ("1 active · 1 idle" etc.).
- Collapsed state persists only for the current session (not to disk).

Chip and text filters still apply inside grouped view: rows that don't match are hidden,
and empty groups (all rows filtered out) are hidden too.

---

## Step 6 — AgentCockpitHUDRowView.swift

Fixed grid layout (8 columns):

```
[22px rnum] [9px dot] [auto badge] [120pt name] [110pt branch] [1fr preview] [auto time] [56pt kbd]
```

**Agent badge:** `Text(row.agentType.label)` at 9pt bold monospaced, with agent-specific
tint (Codex = indigo, Claude = orange, Shell = neutral).

**Status dot:**
- `.active` → green, `Circle().scaleEffect(pulse).opacity(pulseOpacity)` with
  repeating animation (scale 1.0→1.35, opacity 1.0→0.75, 1.4s easeInOut).
  Respect `accessibilityReduceMotion` — disable animation if true.
- `.idle` → solid neutral color, no animation.

**Idle row opacity:** apply `.opacity(0.55)` to the entire row when `liveState == .idle`.

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

## Step 8 — Footer

```swift
HStack {
    Button("⊟  Full window") { openWindow(id: "Cockpit") }
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

Add a toolbar button in the existing `CockpitView` (Agent Cockpit Table):

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
```

Persist `hudGroupByProject` immediately on toggle. Restore on launch.

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
- [ ] HUD opens via toolbar button in the Agent Cockpit Table window
- [ ] HUD floats above other app windows when another app is in focus
- [ ] HUD stays visible when switching to another Space (verify `canJoinAllSpaces`)
- [ ] HUD is draggable by clicking anywhere on the background
- [ ] Window position is restored correctly after quit and relaunch
- [ ] Closing the HUD does not close the main app or the Table window
- [ ] "Full window" footer button opens the Agent Cockpit Table window

### Session display
- [ ] Active sessions appear with a pulsing green dot
- [ ] Idle sessions appear with a static neutral dot and reduced opacity (~0.55)
- [ ] Active sessions sort above idle sessions in flat view
- [ ] Session name, branch, preview, and elapsed time all display correctly
- [ ] Preview text truncates with ellipsis and does not wrap
- [ ] Agent badge label reads "Codex", "Claude", or "Shell" (not CC/CX/$_)
- [ ] No "Waiting" state appears anywhere — only active or idle

### Chip filters
- [ ] Tapping "active" chip hides all idle rows; idle chip dims
- [ ] Tapping "idle" chip hides all active rows; active chip dims
- [ ] Tapping the active chip again (while it is the filter) restores all rows
- [ ] Row numbers re-index correctly after chip filtering (1, 2, 3… not gaps)
- [ ] The flat divider between active and idle sections hides when chip filter is active
- [ ] Chip counts update when sessions change state (active ↔ idle)

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
- [ ] Groups with active sessions appear above idle-only groups
- [ ] Group badge shows correct count summary ("1 active · 1 idle", "2 active", etc.)
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

### Live updates
- [ ] Freshness label updates: "just now" → "Ns ago" → "Nm ago"
- [ ] Sessions that become active update their dot from idle to pulsing without
      requiring a manual refresh
- [ ] Sessions that exit are removed from the list within the next poll cycle (≤ 2s)
- [ ] Chip counts update automatically as session states change

### Accessibility
- [ ] Status dots have accessibility labels ("Active" / "Idle")
- [ ] Pulsing animation is disabled when Reduce Motion is enabled in System Settings
- [ ] The HUD is fully navigable via VoiceOver (rows announced with name + state)

### Dark / Light mode
- [ ] HUD renders correctly in macOS Dark mode
- [ ] HUD renders correctly in macOS Light mode
- [ ] Switching Appearance in System Settings updates the HUD without relaunch

---

## What Not to Modify

| File                              | Reason                              |
|-----------------------------------|-------------------------------------|
| `CockpitView.swift`               | Existing Agent Cockpit Table — untouched |
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
