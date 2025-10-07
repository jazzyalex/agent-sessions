# Focus Architecture Documentation

## Overview

This document describes the window-level focus coordination system implemented in Agent Sessions to manage mutually exclusive search UI states (Find and Search) following Apple Notes architecture patterns.

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                    UnifiedSessionsView                       │
│  ┌────────────────────────────────────────────────────────┐ │
│  │         WindowFocusCoordinator (window-scoped)         │ │
│  │                                                          │ │
│  │  @Published activeFocus: FocusTarget                    │ │
│  │  ├─ .sessionsList    (sessions table has focus)        │ │
│  │  ├─ .sessionSearch   (Cmd+Option+F search)             │ │
│  │  ├─ .transcriptFind  (Cmd+F find in transcript)        │ │
│  │  └─ .none            (no search UI active)             │ │
│  │                                                          │ │
│  │  perform(action: FocusAction)                           │ │
│  │  ├─ .selectSession(id) → .none  (FORCES cleanup)       │ │
│  │  ├─ .openSessionSearch → .sessionSearch                │ │
│  │  ├─ .openTranscriptFind → .transcriptFind              │ │
│  │  ├─ .closeAllSearch → .none                            │ │
│  │  └─ .focusSessionsList → .sessionsList                 │ │
│  └────────────────────────────────────────────────────────┘ │
│                                                               │
│  ┌─────────────────┐        ┌──────────────────────────┐    │
│  │   Sessions      │        │    Transcript Pane       │    │
│  │   List Pane     │        │                          │    │
│  │                 │        │  if Codex:               │    │
│  │  Table          │        │    TranscriptPlainView   │    │
│  │  selection      │        │    ↓                     │    │
│  │      ↓          │        │  UnifiedTranscriptView   │    │
│  │  onChange       │        │                          │    │
│  │      ↓          │        │  if Claude:              │    │
│  │  perform(       │        │    ClaudeTranscriptView  │    │
│  │   .selectSession│        │    ↓                     │    │
│  │  )              │        │  UnifiedTranscriptView   │    │
│  └─────────────────┘        └──────────────────────────┘    │
│                                                               │
│  ┌─────────────────────────────────────────────────────────┐│
│  │         UnifiedSearchFiltersView (Toolbar)              ││
│  │                                                          ││
│  │  Button(Cmd+Option+F)                                   ││
│  │      ↓                                                   ││
│  │  focusCoordinator.perform(.openSessionSearch)           ││
│  │      ↓                                                   ││
│  │  .onChange(focusCoordinator.activeFocus)                ││
│  │      ↓                                                   ││
│  │  if .sessionSearch: showInlineSearch = true             ││
│  └─────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────┘
```

## Focus Flow: Session Selection

```
User presses ↓ arrow in sessions table
        ↓
Table selection changes
        ↓
.onChange(selection) fires (UnifiedSessionsView.swift:138)
        ↓
focusCoordinator.perform(.selectSession(id: sessionID))
        ↓
WindowFocusCoordinator.perform(.selectSession)
        ↓
activeFocus = .none  (FORCES cleanup of all search UI)
        ↓
        ├─→ UnifiedSearchFiltersView observes .none
        │       ↓
        │   showInlineSearch = false
        │   searchFocus = nil
        │
        └─→ UnifiedTranscriptView observes .none
                ↓
            NO ACTION (neither if branch executes)
                ↓
            findFocused remains false
            allowFindFocus remains true (can be focused via Cmd+F)
```

## Focus Flow: Opening Find (Cmd+F)

```
User presses Cmd+F or clicks Find bar
        ↓
focusCoordinator.perform(.openTranscriptFind)
        ↓
WindowFocusCoordinator.perform(.openTranscriptFind)
        ↓
activeFocus = .transcriptFind
        ↓
UnifiedTranscriptView observes .transcriptFind
        ↓
.onChange(focusCoordinator.activeFocus) fires
        ↓
if oldFocus != .transcriptFind && newFocus == .transcriptFind:
        ↓
    allowFindFocus = true
    findFocused = true  ← SwiftUI focuses Find TextField
```

## Focus Flow: Opening Search (Cmd+Option+F)

```
User presses Cmd+Option+F or clicks search button
        ↓
focusCoordinator.perform(.openSessionSearch)
        ↓
WindowFocusCoordinator.perform(.openSessionSearch)
        ↓
activeFocus = .sessionSearch
        ↓
        ├─→ UnifiedSearchFiltersView observes .sessionSearch
        │       ↓
        │   showInlineSearch = true
        │   searchFocus = .field (focuses search field)
        │
        └─→ UnifiedTranscriptView observes .sessionSearch
                ↓
            else if newFocus != .transcriptFind && newFocus != .none:
                ↓
            findFocused = false
            allowFindFocus = false  ← Find becomes unfocusable
```

## Key Components

### WindowFocusCoordinator.swift

**Location**: `AgentSessions/Services/WindowFocusCoordinator.swift`

**Purpose**: Window-level focus coordinator for mutually exclusive search UI states. Matches Apple Notes architecture where Find and Search are window-scoped, not global.

**Key Features**:
- Action-based API with transition guards
- Enforces mutual exclusion (only one search UI active)
- Selecting session FORCES cleanup (Apple Notes behavior)
- DEBUG logging for focus transitions

**Usage**:
```swift
// In UnifiedSessionsView:
@StateObject private var focusCoordinator = WindowFocusCoordinator()

// Pass to child views:
.environmentObject(focusCoordinator)

// Respond to user actions:
focusCoordinator.perform(.openTranscriptFind)
focusCoordinator.perform(.selectSession(id: id))
```

### UnifiedTranscriptView

**Location**: `AgentSessions/Views/TranscriptPlainView.swift`

**Focus Management**:
```swift
@FocusState private var findFocused: Bool
@State private var allowFindFocus: Bool = false
@EnvironmentObject var focusCoordinator: WindowFocusCoordinator

// Observe coordinator state:
.onChange(of: focusCoordinator.activeFocus) { oldFocus, newFocus in
    if oldFocus != .transcriptFind && newFocus == .transcriptFind {
        allowFindFocus = true
        findFocused = true
    } else if newFocus != .transcriptFind && newFocus != .none {
        findFocused = false
        allowFindFocus = false
    }
}

// Keyboard shortcut:
Button(action: { focusCoordinator.perform(.openTranscriptFind) }) { EmptyView() }
    .keyboardShortcut("f", modifiers: .command)
```

### UnifiedSearchFiltersView

**Location**: `AgentSessions/Views/UnifiedSessionsView.swift:410`

**Focus Management**:
```swift
@ObservedObject var focus: WindowFocusCoordinator
@FocusState private var searchFocus: SearchFocusTarget?
@State private var showInlineSearch: Bool = false

// Observe coordinator state:
.onChange(of: focus.activeFocus) { _, newFocus in
    if newFocus == .sessionSearch {
        showInlineSearch = true
        searchFocus = .field
    } else if newFocus == .none || newFocus == .transcriptFind {
        if query.isEmpty && !search.isRunning {
            showInlineSearch = false
            searchFocus = nil
        }
    }
}

// Keyboard shortcut:
Button(action: { focus.perform(.openSessionSearch) })
    .keyboardShortcut("f", modifiers: [.command, .option])
```

## Historical Bug: Legacy Publisher Focus Stealing

### Problem

When navigating between **Codex sessions only** (not Claude), focus would jump to the Find bar on every selection change.

### Root Cause

The legacy `requestTranscriptFindFocusPublisher` in `SessionIndexer.swift` was implemented as a **computed property**:

```swift
var requestTranscriptFindFocusPublisher: AnyPublisher<Void, Never> {
    $requestTranscriptFindFocus.map { _ in () }.eraseToAnyPublisher()
}
```

This created a **new publisher on every access**. When `.onReceive()` re-subscribed during session navigation, the `@Published` property emitted its current value to the new subscriber, triggering:

```swift
.onReceive(indexer.requestTranscriptFindFocusPublisher) { _ in
    if allowFindFocus { findFocused = true }  // ← Focus stolen!
}
```

**Why Codex-specific?**
- Codex (`SessionIndexer`): Real publisher from `@Published` → emits on subscription
- Claude (`ClaudeSessionIndexer`): Protocol extension returns `Empty<Void, Never>()` → never emits

### Solution

Removed the obsolete `.onReceive(indexer.requestTranscriptFindFocusPublisher)` handler entirely. Focus is now managed exclusively through `WindowFocusCoordinator`.

**Commit**: `fix(focus): remove legacy publisher causing Codex-specific focus stealing`

## Design Principles

### 1. Window-Scoped State
Focus state lives in `WindowFocusCoordinator` per window, not in global indexers. This matches Apple Notes architecture.

### 2. Action-Based API
Use `perform(action:)` instead of direct state mutation. Actions are semantic and enforce transition guards.

### 3. Mutual Exclusion
Only one search UI can be active at a time:
- `.sessionSearch` (search sessions)
- `.transcriptFind` (find in transcript)

### 4. Forced Cleanup
Selecting a session **always** forces cleanup of all search UI (`.none` state). This prevents focus conflicts.

### 5. Observable Focus
Child views observe `focusCoordinator.activeFocus` and react accordingly. No imperative focus control.

## Debug Logging

Enable DEBUG build to see focus transitions:

```
🎯 FOCUS: none → sessionSearch (action: openSessionSearch)
🎯 FOCUS: sessionSearch → none (action: selectSession(id: "abc123"))
🎯 FOCUS: none → transcriptFind (action: openTranscriptFind)
```

Additional transcript-specific logging:
```
🔍 FIND FOCUSED CHANGED: true (allowFindFocus=true)
🔓 ALLOW FIND FOCUS CHANGED: true
👁️ FIND BAR ON APPEAR: Setting allowFindFocus=true
```

## Testing Checklist

- [ ] Navigate Codex sessions with arrow keys → focus stays in table
- [ ] Navigate Claude sessions with arrow keys → focus stays in table
- [ ] Navigate mixed Codex/Claude → focus stays in table
- [ ] Press Cmd+F → Find bar receives focus
- [ ] Press Cmd+Option+F → Search bar receives focus
- [ ] Open Find, then select session → Find closes, table keeps focus
- [ ] Open Search, then select session → Search closes, table keeps focus
- [ ] Open Find, then press Cmd+Option+F → Search opens, Find closes
- [ ] Open Search, then press Cmd+F → Find opens, Search closes

## Migration Notes

### Deprecated APIs

`WindowFocusCoordinator` provides legacy compatibility methods marked as deprecated:

```swift
@available(*, deprecated, message: "Use perform(_:) instead")
func requestFocus(_ target: FocusTarget)

@available(*, deprecated, message: "Use perform(.closeAllSearch) instead")
func clearFocus()
```

### Removed Legacy Systems

1. **Removed**: `.onReceive(indexer.requestTranscriptFindFocusPublisher)` from `TranscriptPlainView.swift`
2. **Deprecated**: `indexer.activeSearchUI` (still exists for protocol compatibility but not used in new code)
3. **Future**: Consider removing `requestTranscriptFindFocusPublisher` from `SessionIndexerProtocol` once confirmed unused

## References

- [Apple Human Interface Guidelines - Focus and Selection](https://developer.apple.com/design/human-interface-guidelines/focus-and-selection)
- [SwiftUI FocusState Documentation](https://developer.apple.com/documentation/swiftui/focusstate)
- [Combine Publishers and Subscribers](https://developer.apple.com/documentation/combine/publishers-and-subscribers)
