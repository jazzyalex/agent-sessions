# Search Field Focus Bug - Unified Sessions View

## Problem
When user clicks the magnifying glass (loupe) button or presses ⌥⌘F keyboard shortcut to open the session search field in UnifiedSessionsView, the TextField does not receive focus. User has to manually click inside the field to start typing.

## Location
File: `AgentSessions/Views/UnifiedSessionsView.swift`
Struct: `UnifiedSearchFiltersView` (private nested struct, starts around line 405)

## Current Behavior
1. User clicks loupe button (line ~485) or presses ⌥⌘F
2. Search field appears (controlled by `showInlineSearch` state)
3. TextField is visible but cursor is NOT blinking inside it
4. User must manually click the TextField to begin typing

## Expected Behavior
1. User clicks loupe button or presses ⌥⌘F
2. Search field appears
3. TextField automatically receives focus with blinking cursor
4. User can immediately start typing

## What We've Tried (All Failed)

### Attempt 1: Direct `.task` on TextField
```swift
TextField("Search", text: $unified.queryDraft)
    .focused($searchFocus, equals: .field)
    .task { searchFocus = .field }
```
**Result**: No focus

### Attempt 2: `onChange(of: showInlineSearch)` with 50ms delay
```swift
.onChange(of: showInlineSearch) { _, shown in
    if shown {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            searchFocus = .field
        }
    }
}
```
**Result**: No focus

### Attempt 3: Multiple async attempts at different timings
```swift
.onChange(of: showInlineSearch) { _, shown in
    if shown {
        searchFocus = .field  // immediate
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { searchFocus = .field }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { searchFocus = .field }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { searchFocus = .field }
    }
}
```
**Result**: No focus

### Attempt 4: Bool instead of enum for @FocusState
Changed from `@FocusState private var searchFocus: SearchFocusTarget?` to `@FocusState private var isSearchFocused: Bool`
**Result**: No focus

### Attempt 5: `.focusable(false)` on Table
Added to prevent table from stealing focus
**Result**: No focus (and broke table interaction)

## Current Code State

**Focus state:**
```swift
@FocusState private var searchFocus: SearchFocusTarget?
private enum SearchFocusTarget: Hashable { case field, clear }
```

**TextField:**
```swift
TextField("Search", text: $unified.queryDraft)
    .textFieldStyle(.plain)
    .focused($searchFocus, equals: .field)
    .onSubmit { startSearch() }
    .frame(minWidth: 220)
```

**Button that triggers search field:**
```swift
Button(action: {
    showInlineSearch = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
        searchFocus = .field
    }
}) {
    Image(systemName: "magnifyingglass")
    // ...
}
.keyboardShortcut("f", modifiers: [.command, .option])
```

**Currently has these focus attempts:**
1. `.onAppear { searchFocus = .field }` on the HStack container
2. `.onChange(of: showInlineSearch)` with 4 delayed attempts
3. Button action with 150ms delayed attempt

## Investigation Notes

1. **This is NOT related to search auto-selection** - the bug exists even at commit de79be6 before we implemented auto-selection of first search result

2. **No search is running** when field appears - just showing/hiding the field with `showInlineSearch` state

3. **Working example exists** in `SearchFiltersView.swift` (Codex sessions view) which uses:
   ```swift
   DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { isSearchFocused = true }
   ```
   But that's for a popover, different UI pattern

4. **View hierarchy**: The search field is in a toolbar item:
   ```swift
   ToolbarItem(placement: .automatic) {
       UnifiedSearchFiltersView(unified: unified, search: searchCoordinator)
   }
   ```

5. **Possibly relevant**: The field uses conditional rendering `if showInlineSearch || !unified.queryDraft.isEmpty || search.isRunning` - maybe SwiftUI isn't recognizing the TextField as "new" when it appears?

## What We Need

A reliable way to set focus on the TextField when `showInlineSearch` changes from `false` to `true`, that works consistently whether triggered by button click or keyboard shortcut.

The focus must work in a toolbar context with conditional view rendering.

## Questions to Explore

1. Is there something specific about ToolbarItem placement that affects focus?
2. Does the conditional `if showInlineSearch` prevent @FocusState from working properly?
3. Should we use a different approach entirely (e.g., `.focusedValue` and FocusedValues)?
4. Is there an AppKit-level solution using NSTextField directly?
5. Could the issue be related to the window's key status or first responder chain?
