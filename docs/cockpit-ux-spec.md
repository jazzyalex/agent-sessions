# Cockpit UI/UX Design Specification

> Design-only document. No code changes. For implementation planning and discussion.
> Last updated: 2026-02-26

---

## Vision

Cockpit is a purpose-built macOS surface for monitoring and commanding active coding agents.
It has two distinct use cases that demand two distinct modes:

1. **Dashboard mode** — you sit in front of it, read it, take action. Full window, full detail.
2. **HUD mode** — it lives in the corner of your screen while you work. Compact, always-on-top, ambient.

Both modes share the same data model. The design adapts the density and interaction affordances to the context.

---

## Mode 1: Full Window (Current Paradigm, Evolved)

### Layout Sketch

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│ Cockpit                              [Both ▾ Active  Open]   [⟳]  [— ⊟ HUD ✕] │
├─────────────────────────────────────────────────────────────────────────────────┤
│ ┌───────────────────────────────────────────────────────────────────────────┐   │
│ │  NEEDS ATTENTION  (1)                                             amber   │   │
│ │  ● my-api · auth-refactor     Waiting for input        iTerm2   [Focus]  │   │
│ └───────────────────────────────────────────────────────────────────────────┘   │
│                                                                                 │
│  ACTIVE  (3)                                                                    │
│ ┌─────────────────────────────────────────────────────────────────────────────┐ │
│ │ ● storefront    feature/cart   Refactoring checkout flow…  12m  [Focus]   │ │
│ │ ● my-api        fix/rate-limit Running tests (44/120)…      3m  [Focus]   │ │
│ │ ● design-sys    main           Updating token exports…      8m  [Focus]   │ │
│ └─────────────────────────────────────────────────────────────────────────────┘ │
│                                                                                 │
│  OPEN / IDLE  (2)                                                               │
│  ○ mobile-app   feat/onboard    Last: 47m ago                    [Focus]       │
│  ○ infra-mono   main            Last: 2h ago                     [Focus]       │
│                                                                                 │
│  COMPLETED  (1)  ·  last 10 min                                                 │
│  ✓ analytics    fix/events      Finished 4m ago · 23m run · 18 files changed   │
├─────────────────────────────────────────────────────────────────────────────────┤
│ [Codex ▓▓▓▓░░ 5h:62%  Wk:41% ↻3d] [Claude ▓▓░░░░ 5h:28%  Wk:19% ↻3d]        │
│                                                            3 active · just now  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### Key Changes from Current Design

#### Section-based grouping replaces flat filter

Instead of a segmented picker (Both / Active / Open), the window always shows all three
categories as labeled sections. This removes a decision ("which filter am I on?") and gives
you the full picture at a glance. Sections collapse when empty.

Order is fixed by urgency:
1. Needs Attention (amber, always top if non-empty)
2. Active (pulsing dot, green left accent)
3. Open / Idle (solid dot, neutral)
4. Completed (checkmark, greyed, auto-expires after 10 min)

The old segmented control is replaced by a search/filter field (see Keyboard section).

#### Status vocabulary expansion

| State           | Dot   | Color        | Label example                      |
|-----------------|-------|--------------|------------------------------------|
| Waiting         | ●     | Amber        | "Waiting for input"                |
| Active working  | ● (pulse) | Green   | Last-output preview (60 chars max) |
| Open / idle     | ○     | Secondary    | "Last: 47m ago"                    |
| Errored         | ● (static) | Red    | "Stopped — exit 1"                 |
| Just completed  | ✓     | Tertiary     | "Finished 4m ago · N files changed"|

#### Last-activity preview column

Each active-working row shows a 60-character truncated preview of:
- The agent's most recent terminal output line (for dumb terminal sessions), or
- The current tool call / task description when richer metadata is available (Claude Code,
  Cursor), or
- "Last: Xm ago" when the session is idle.

This is the single highest-value addition. It answers "what is it doing?" without switching.

#### Row interaction

- **Single click** on any part of the row → Focus that session's terminal. The Focus button
  remains as a visible affordance but is not the only target.
- **Double-click** → Focus + bring terminal app to foreground.
- **Right-click** → Context menu (unchanged from current, plus: "Send to background",
  "Copy last output line").
- **Hover** → Tooltip shows last 5 lines of terminal output in a monospaced popover.

---

## Mode 2: Mini HUD (New)

### Purpose

Always-on-top floating panel for ambient awareness while working. Answers the question
"are my agents still going?" without breaking focus.

### Layout Sketch — Default state

```
┌────────────────────────────────────────┐
│ ◉ 3 active  ○ 2 idle  ⚠ 1 waiting  [⊞]│
├────────────────────────────────────────┤
│ ● storefront   Refactoring checkout…   │
│ ● my-api       Running tests (44/120)… │
│ ● design-sys   Updating token exports… │
│ ○ mobile-app   Last: 47m              │
│ ⚠ my-api/auth  Waiting for input       │
└────────────────────────────────────────┘
```

Width: ~320px. Height: auto (max ~240px with scroll).
No title bar chrome. Uses NSPanel with `.floating` level.
Background: vibrancy material (`.hudWindow` or `.underWindowBackground`).

The `[⊞]` button in the header expands to full Cockpit window.

### Layout Sketch — Minimal / collapsed state

When toggled to minimal (double-click header or keyboard shortcut):

```
┌──────────────────────────────┐
│ ◉ 3  ○ 2  ⚠ 1   Cockpit  [⊞]│
└──────────────────────────────┘
```

Single-line strip. Positioned at top or bottom edge of screen (user-draggable, snaps to
edges). Shows only counts. Expands on hover or click.

### HUD Visual Language

- Row height: 22px (tighter than full window's ~32px)
- Font: 12pt system, session name semibold, preview secondary color
- No column headers in HUD
- No footer / quota bar in HUD (available in full window only)
- Status dots identical to full window (same CodexLiveStatusDot component, smaller diameter)

### Window management

- Stored as an NSPanel (not NSWindow), which allows `.floating` level independently of
  app focus.
- Pin toggle: toolbar button in full window mode. When pinned, full window also floats.
- Position and mode (full vs. HUD vs. minimal) persisted in UserDefaults under
  `PreferencesKey.Cockpit.hudMode`.
- Keyboard shortcut to toggle HUD: `Option+Command+C` (no existing shortcut conflicts).
- HUD is a second window type alongside full Cockpit, not a replacement.

---

## Keyboard-First Navigation (Both Modes)

### Type-to-filter

When the Cockpit window is focused, pressing any letter character immediately activates an
inline search field at the top of the session list. Typing narrows visible sessions in real
time. `Escape` clears and dismisses the field.

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│ Cockpit                              [ 🔍 my-api_______________ ✕ ]  [⟳]  [HUD] │
```

The segmented filter is hidden when the search field is active.

### Row shortcuts

Visible session rows are numbered 1–9 (shown as small secondary labels when the window
is frontmost). `Command+1` through `Command+9` focus that row's terminal.

```
│ 1  ● storefront   Refactoring checkout flow…     12m  [Focus] │
│ 2  ● my-api       Running tests (44/120)…          3m  [Focus] │
```

`Return` when a row is selected (arrow keys navigate) triggers Focus.

---

## Agent Type Identity

As Cockpit extends to Claude Code, Cursor, generic terminals, and SSH sessions, each row
needs a type indicator before the session name.

```
│ [C] ● storefront   feature/cart   Refactoring checkout flow…  │  ← Codex
│ [⌘] ● my-api       fix/auth       Waiting for input…           │  ← Claude Code
│ [>] ○ infra-mono   main           Last: 2h ago                 │  ← generic terminal
```

The icon is a small 14×14 monochrome glyph, consistent with the provider icons already
used in the footer quota widgets. The same icon set is reused — no new assets needed for
Codex and Claude.

The footer quota bar already tracks per-provider. This change surfaces provider identity
at the session level, making the two layers consistent.

---

## Needs Attention State (Priority 0)

This is the most actionable new state. When an agent pauses and waits for user input —
either via an interactive prompt or because it hit an ambiguous state — it should not
silently sit in the "active" bucket.

Detection heuristics (without protocol changes):
- Terminal output ends with a `?` or prompt-like suffix and no new output in >30s while
  pid is still alive.
- Agent-specific signals when available (e.g., Claude Code exposes a "waiting" status).

Visual treatment:
- Amber left border accent on the row (matches amber dot).
- The HUD header count `⚠ N` appears and is bolded when non-zero.
- macOS notification sent: "my-api is waiting for input" with a "Focus" action button.
  One notification per session per waiting event; not repeated until session goes active
  again.

---

## Completed Sessions

Sessions that finish (process exits) do not disappear immediately. They move to a
"Completed" section that:

- Shows for 10 minutes after completion (configurable, stored in preferences).
- Displays: session name, project, duration, exit status (success / exit N), and files-
  changed count when available.
- Rows are visually muted (secondary text color throughout, no dot).
- Right-click offers: "Open Working Directory", "Reveal Log", "Copy Summary".
- Section is hidden entirely if no completed sessions in window.

This closes the loop for quick review: you can see at a glance that a session finished
successfully without going to the main session list.

---

## Project Grouping (Optional, Progressive Disclosure)

When 6+ sessions are visible, an optional "Group by project" toggle appears in the toolbar.
When active, sessions are grouped under collapsible project headers.

```
│  storefront  (2 active)                               [▾]  │
│    ● feature/cart   Refactoring checkout flow…             │
│    ○ feat/search    Last: 1h ago                           │
│                                                            │
│  my-api  (1 active, 1 waiting)                    [▾]  │
│    ⚠ fix/auth       Waiting for input                      │
│    ● fix/rate-limit Running tests (44/120)…                │
```

Group headers show aggregate counts. Collapsing a group hides its rows.
This mode is off by default and remembered per-window in preferences.

---

## Summary of New Preference Keys

| Key                              | Type    | Default | Description                          |
|----------------------------------|---------|---------|--------------------------------------|
| `Cockpit.hudEnabled`             | Bool    | false   | Whether HUD window is open           |
| `Cockpit.hudMode`                | String  | "panel" | "panel" / "minimal"                  |
| `Cockpit.hudPosition`            | NSPoint | —       | Last HUD window position             |
| `Cockpit.pinned`                 | Bool    | false   | Full window always-on-top            |
| `Cockpit.groupByProject`         | Bool    | false   | Group sessions by repo               |
| `Cockpit.completedVisibleSecs`   | Int     | 600     | How long completed sessions show     |
| `Cockpit.notifyOnWaiting`        | Bool    | true    | macOS notification when agent waits  |
| `Cockpit.notifyOnComplete`       | Bool    | false   | macOS notification on session end    |

---

## What Does Not Change

- Polling cadence (2s foreground / 15s background) — already well-tuned.
- iTerm2 AppleScript focus mechanism.
- Session joining logic (log path primary, session ID fallback).
- Footer quota widget layout and logic.
- Window autosave for position/size.
- CodexLiveStatusDot component (reused in HUD at smaller scale).

---

## Open Questions

1. **Last-output preview source.** The active presence model (`CodexActivePresence`) does
   not currently include terminal output. Options: (a) read the session JSONL log for the
   last assistant message, (b) subscribe to a new heartbeat field, (c) use the tty device
   to sample output directly (fragile). Option (a) is the least invasive.

2. **Needs-attention detection accuracy.** Heuristic detection (output ends with `?`,
   idle >30s) will produce false positives for long-running subprocesses that happen to
   end in `?`. A more reliable signal would require Codex/Claude Code to write an explicit
   `status: waiting` field to the heartbeat file.

3. **HUD window level.** `NSFloatingWindowLevel` keeps the HUD above normal windows but
   below system UI. `.screenSaverWindowLevel` or `.statusBarWindowLevel` would be higher
   but may conflict with other tools. Default to `.floating`; expose as a preference.

4. **Completed session data.** Duration and files-changed require joining with the session
   log after exit. This is a post-hoc read and should be done lazily on first display of
   the completed row, not in the polling hot path.
