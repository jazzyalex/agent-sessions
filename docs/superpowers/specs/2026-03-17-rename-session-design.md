# Rename Session Feature — Design Spec

## Problem

Session titles are auto-derived from content via heuristics (first user message, first assistant reply, fallback to "No prompt"). This produces unhelpful titles for many sessions — truncated prompts, generic openings, or missing context. Users have no way to label sessions for later retrieval or organization.

## Solution

Add user-editable custom names for sessions, stored in the SQLite database. Provide a global toggle to switch the entire UI between custom names and original heuristic titles, with a subtle visual indicator for sessions that haven't been renamed yet.

---

## Data Layer

### DB Schema Change

Add column to `session_meta`:

```sql
ALTER TABLE session_meta ADD COLUMN custom_name TEXT;
```

Migration uses the existing `tableHasColumn()` guard pattern in `DB.swift`.

### Session Model (`Session.swift`)

- Add `var customName: String?` stored property (mutable, like `isHousekeeping`)
- **Exclude from `CodingKeys`** — `customName` is persisted via DB, not Codable serialization (same pattern as `isFavorite`)
- `customName` participates in synthesized `Equatable` — this is intentional so SwiftUI re-renders when a name changes
- Add `func displayTitle(preferCustom: Bool) -> String`:
  - If `preferCustom` is true and `customName` is non-nil/non-empty, return `customName`
  - Otherwise fall back to `codexDisplayTitle` (which itself falls back to `title` for non-Codex sources). This preserves the existing Codex-specific preview title behavior for unrenamed sessions.
- Existing `title` and `codexDisplayTitle` computed properties remain unchanged

### SessionMetaRow DTO (`DB.swift`)

- Add `customName: String?` field to `SessionMetaRow`
- In `fetchSessionMeta()` SELECT: append `custom_name` as column index 15 (after `commands` at index 14). Read it at position 15 in the row reader.
- In `upsertSessionMeta()` INSERT: include `custom_name` with NULL value (so new rows get the column)
- **In the ON CONFLICT UPDATE SET clause: omit `custom_name` entirely.** The indexer never sets custom names — they are user-only data written exclusively by `updateCustomName()`. This is the safest approach to prevent re-indexing from erasing user-set names.

### Persistence Operations

New method on `IndexDB`:

```swift
func updateCustomName(sessionID: String, name: String?) async throws
```

UPDATE-only operation (session already exists). Setting `name` to `nil` or empty string clears the custom name.

### Session Hydration (`SessionMetaRepository.swift`)

`SessionMetaRepository.fetchSessions()` constructs `Session` objects through a multi-step init chain (create → enrich → finalize). Set `customName` as a mutable property **after** construction, following the same pattern as `isFavorite` (which is set post-construction in `UnifiedSessionIndexer`):

```swift
var session = Session(...)  // existing init
session.customName = metaRow.customName
```

### Search Integration

`SessionSearchTextBuilder.build(session:)` already receives the full `Session` object. Since `customName` is now a property on `Session`, the builder reads `session.customName` directly — no new parameter needed. When `customName` is non-nil, prepend it to the text blob before session content. This makes custom names searchable via FTS.

When `rename()` is called, the in-memory `Session.customName` is updated first, then the builder is invoked with the updated session to rebuild and update the FTS row — no full session re-parse needed.

---

## Global Toggle

### Storage

`@AppStorage("ShowCustomSessionNames")` — `Bool`, default `true`.

Default `true` because the feature is additive: unrenamed sessions just show italic heuristic titles, and renamed sessions immediately show their custom name. No filtering or recomputation is involved — this is purely a display preference.

**Note:** Unlike the favorites toggle (which uses `@Published` on `UnifiedSessionIndexer` because it triggers `recomputeNow()` for filtering), the custom names toggle is display-only and does not require recomputation. `@AppStorage` is the correct binding pattern here.

### Toolbar Toggle

Uses existing `ToolbarIconToggle` component (same pattern as favorites star toggle):

- **SF Symbols**: `tag.fill` (on) / `tag` (off)
- **Active color**: `#007acc` (selection accent)
- **Placement**: next to the favorites star toggle, before the divider
- **Tooltip**: "Show Custom Names" / "Show Original Names"

### View Menu

Add toggle item to the existing View `CommandMenu`:

- Label: "Show Custom Names"
- Keyboard shortcut: Cmd-Opt-N
- Bound to same `@AppStorage` key
- Follows pattern of existing "Saved Only" toggle

---

## Visual Treatment

### Custom Names Mode (toggle ON)

- **Renamed sessions**: title in `.primary` color, `.regular` weight (standard appearance)
- **Unrenamed sessions**: heuristic title in `.secondary` color, `.italic` — subtle cue that the session hasn't been given a custom name

### Original Names Mode (toggle OFF)

- All sessions show heuristic titles in `.primary` color, `.regular` weight
- No visual difference from current behavior

---

## Rename Interaction

### Trigger

Context menu item: **"Rename..."** (with ellipsis indicating popover)

- **Unified window**: placed after "Save" / "Remove from Saved", before the first divider
- **Cockpit HUD**: placed after "Focus in iTerm2", before the divider to Reveal Log
- **Cockpit full window**: placed after "Focus in iTerm2", before divider
- **Saved Sessions window**: added to context menu in same position pattern

### Popover Design

Compact popover anchored to the session row, containing:

1. **Header**: "Rename Session" — `.system(size: 11)`, uppercase, secondary color
2. **Text field**: pre-filled with current custom name (or heuristic title if no custom name). Monospaced font `.system(size: 13, design: .monospaced)`. Auto-selects all text on appear.
3. **Original name preview**: below the text field — "Original: {heuristic title}" in `.system(size: 11)`, secondary color. Truncated with `...` if long.
4. **Buttons** (right-aligned):
   - "Reset to Original" — secondary style, ghost button. Clears custom name. Disabled if no custom name is set.
   - "Save" — primary style, `#007acc` background. Saves the text field value as custom name.
5. **Keyboard**: Return to save, Escape to cancel.

### Popover Width

280pt fixed width, matching typical macOS popover proportions for the session title column.

### Popover State Management

SwiftUI `Table` does not support `.popover` on individual rows. Use a view-level state pattern:

```swift
@State private var renamingSessionID: String?
```

Attach a single `.popover` to the table container (or an overlay), keyed on `renamingSessionID`. The context menu action sets `renamingSessionID = session.id` to trigger the popover. Position via anchor preferences or `.popover(item:)`.

---

## Surface-by-Surface Behavior

### Unified Session List (`UnifiedSessionsView`)

- `SessionTitleCell` calls `session.displayTitle(preferCustom: showCustomNames)` instead of `session.title`
- When `showCustomNames` is true and `session.customName == nil`: apply `.foregroundStyle(.secondary)` and italic font
- Context menu gets "Rename..." item
- **Sorting**: `TableColumn("Session", value: \Session.title)` continues to sort by the heuristic `title` key path regardless of toggle state. This is acceptable — `displayTitle()` is a method and cannot be a key path. Sorting by the underlying heuristic title provides stable, predictable ordering.

### Agent Cockpit HUD (`AgentCockpitHUDRowView`)

- Title text source changes from `row.preview ?? row.displayName` to incorporate custom name when toggle is on
- `HUDRow` model gets a `customName: String?` field populated from the session's `customName`. Include in `HUDRow`'s `Equatable` conformance so re-renders trigger on rename.
- Context menu gets "Rename..." item
- Same popover state pattern (view-level `@State`)

### Cockpit Full Window (`CockpitView`)

- `Row` struct gets `customName: String?` field, populated when building rows from sessions
- "Name" column displays `displayTitle(preferCustom:)` with the global toggle
- Context menu gets "Rename..." item

### Saved Sessions (`PinnedSessionsView`)

- Title column uses `displayTitle(preferCustom:)`
- Context menu gets "Rename..." item

### Additional Surfaces (display-only, no rename trigger)

These surfaces also use `session.title` or `session.codexDisplayTitle` and should use `displayTitle(preferCustom:)`:

- `CodexResumeSheet.swift` — uses `session.codexDisplayTitle` (in resume picker, show custom name if available)

---

## Rename Store

Add rename methods on `UnifiedSessionIndexer` (not a separate store — keeps session mutation co-located):

- `func renameSession(_ sessionID: String, to name: String)` — updates `Session.customName` in the `allSessions` array, calls `IndexDB.updateCustomName()`, calls `SessionSearchTextBuilder` to rebuild and update the FTS row for that session
- `func clearCustomName(_ sessionID: String)` — sets `customName` to nil, same DB + FTS update
- On session hydration from DB: `customName` is loaded from `SessionMetaRow` and set on the `Session` struct post-construction

---

## Edge Cases

- **Empty string rename**: `updateCustomName()` normalizes empty/whitespace-only strings to `nil` internally — single normalization point prevents storing `""` in the DB
- **Very long names**: truncated with `.lineLimit(1).truncationMode(.tail)` like heuristic titles
- **Session re-indexed**: `custom_name` omitted from ON CONFLICT UPDATE — preserved automatically
- **Session file deleted**: custom name persists in `session_meta` row (cleaned up only via explicit DB cleanup)
- **Rename in cockpit for live session**: works — the custom name is set on the `Session` in the unified indexer, visible across all views immediately via `@Published` session list
- **Multiple windows showing same session**: all update simultaneously since they read from the same `@Published` data source and `@AppStorage` toggle

### Deferred

- **Undo (Cmd-Z)**: `UndoManager` integration for rename is deferred to a future iteration
- **Double-click to rename**: deferred — context menu is the sole trigger for v1

---

## Files to Modify

| File | Change |
|------|--------|
| `AgentSessions/Model/Session.swift` | Add `customName` property (excluded from CodingKeys), `displayTitle()` method |
| `AgentSessions/Indexing/DB.swift` | Add column migration, `updateCustomName()`, update upsert (omit from ON CONFLICT) and fetch (column index 15) |
| `AgentSessions/Indexing/SessionMetaRepository.swift` | Map `customName` from DTO, set post-construction on Session |
| `AgentSessions/Search/SessionSearchTextBuilder.swift` | Read `session.customName`, prepend to text blob when non-nil |
| `AgentSessions/Views/UnifiedSessionsView.swift` | Toolbar toggle, context menu, popover state, display logic |
| `AgentSessions/Views/CockpitView.swift` | Row struct customName, context menu, display logic |
| `AgentSessions/Views/AgentCockpitHUDView.swift` | Context menu, popover state |
| `AgentSessions/Views/AgentCockpitHUDRowView.swift` | Display logic, customName on HUDRow |
| `AgentSessions/Views/PinnedSessionsView.swift` | Context menu, display logic |
| `AgentSessions/Resume/CodexResumeSheet.swift` | Use `displayTitle()` instead of `codexDisplayTitle` |
| `AgentSessions/Services/UnifiedSessionIndexer.swift` | Rename/clear methods, hydration |
| `AgentSessionsApp.swift` | View menu toggle item |

### New Files

| File | Purpose |
|------|---------|
| `AgentSessions/Views/SessionRenamePopover.swift` | Reusable rename popover view |

---

## Verification

1. **Build**: `xcodebuild -scheme AgentSessions -configuration Debug build`
2. **DB migration**: launch app, verify `custom_name` column exists via SQLite inspector
3. **Rename flow**: right-click session → Rename... → enter name → Save → verify name appears
4. **Toggle**: click tag toolbar icon → renamed sessions show custom name, unrenamed show italic heuristic → click again → all revert to heuristic titles
5. **Persistence**: rename a session, quit app, relaunch → custom name preserved
6. **Re-index**: trigger refresh (Cmd-R) → custom names survive
7. **Search**: search for custom name text → session appears in results
8. **Cockpit**: rename from cockpit context menu → name appears in cockpit and unified window
9. **Reset**: rename popover → "Reset to Original" → custom name cleared
10. **View menu**: View → Show Custom Names toggle works, synced with toolbar icon
11. **Sorting**: in custom names mode, sort by Session column → sorts by heuristic title (stable)
12. **Resume sheet**: custom name appears in Codex resume picker
