# Transcript Color Reference

Last updated: February 19, 2026

This document maps the current transcript-related color system in Agent Sessions.
Scope is transcript and transcript-adjacent UI only:
- Session mode toolbar legend (`User`, agent, `Tools`, `Errors`)
- Session mode block accents and line styling
- Text mode syntax coloring
- Shared semantic and agent-brand color tokens

It does not attempt to catalog every color used in unrelated app areas.

## Why `Tools` Can Be Purple While Tool Output Is Green

This is currently by design.

- The toolbar `Tools` chip uses `toolInput` as its representative swatch.
  - `RoleToggle.tools -> .toolInput`
  - Source: `AgentSessions/Views/SessionTerminalView.swift:1651`
- `toolInput` accent is purple.
  - Source: `AgentSessions/Views/SessionTerminalView.swift:1742`
- `toolOutput` accent is green.
  - Source: `AgentSessions/Views/SessionTerminalView.swift:1748`
- The `Tools` toggle/navigation includes both tool calls and tool outputs.
  - Source: `AgentSessions/Views/SessionTerminalView.swift:909`
  - Source: `AgentSessions/Views/SessionTerminalView.swift:1145`

So one control (`Tools`) represents two semantic states:
- Tool call: purple
- Tool output success: green

## Core Semantic Tokens (Source of Truth)

From `TranscriptColorSystem.semanticAccent`.

| Semantic token | Color |
|---|---|
| `user` | `NSColor.systemBlue` |
| `toolCall` | `NSColor.systemPurple` |
| `toolOutputSuccess` | `NSColor.systemGreen` |
| `toolOutputError` | `NSColor.systemRed` |
| `error` | `NSColor.systemRed` |

Source: `AgentSessions/Services/TranscriptColorSystem.swift:22`

## Agent Brand Accent Tokens

From `TranscriptColorSystem.agentBrandAccent`.

| Agent | Color |
|---|---|
| Codex | `RGB(0.14, 0.30, 0.60)` |
| Claude | `RGB(0.74, 0.46, 0.22)` |
| Gemini | `NSColor.systemTeal` |
| OpenCode | `NSColor.systemPurple` |
| Copilot | `RGB(0.90, 0.20, 0.60)` |
| Droid | `RGB(0.16, 0.68, 0.28)` |
| OpenClaw | `RGB(0.95, 0.55, 0.15)` |

Source: `AgentSessions/Services/TranscriptColorSystem.swift:39`

## Session Toolbar Legend Correlation

| Toolbar item | Swatch role | Swatch accent | What it controls |
|---|---|---|---|
| `User` | `.user` | blue | user prompts |
| agent label (`Codex`, `Claude`, etc.) | `.assistant` | per-agent brand color | assistant lines |
| `Tools` | `.toolInput` | purple | tool call and tool output groups |
| `Errors` | `.error` | red | error lines |

Sources:
- `AgentSessions/Views/SessionTerminalView.swift:1042`
- `AgentSessions/Views/SessionTerminalView.swift:1651`
- `AgentSessions/Views/SessionTerminalView.swift:1738`
- `AgentSessions/Views/SessionTerminalView.swift:1744`

## Terminal Line Role Mapping

`TerminalBuilder` assigns transcript lines to roles that later drive color selection.

| Session block kind | Terminal line role |
|---|---|
| `.user` | `.user` |
| `.assistant` | `.assistant` |
| `.toolCall` | `.toolInput` |
| `.toolOut` (non-error) | `.toolOutput` |
| `.toolOut` (error-like) | `.error` |
| `.error` | `.error` |
| `.meta` | `.meta` |

Source: `AgentSessions/Services/TerminalModels.swift:68`

## Session Block Accent Correlation (Side Strips)

Layout block kinds use semantic accents in `TerminalLayoutManager`.

| Block kind | Accent source | Typical visible hue |
|---|---|---|
| `.toolCall` | `semanticAccent(.toolCall)` | purple |
| `.toolOutput` | `semanticAccent(.toolOutputSuccess)` | green |
| `.error` | `semanticAccent(.error)` | red |
| `.agent` | agent brand accent | brand-dependent |
| `.userPreamble` / `.userInterrupt` / `.localCommand` | `semanticAccent(.user)` | blue |
| `.systemNotice` | `NSColor.systemOrange` | orange |
| `.imageAnchor` | `NSColor.systemPurple` | purple |

Sources:
- `AgentSessions/Views/SessionTerminalView.swift:1899`
- `AgentSessions/Views/SessionTerminalView.swift:1907`
- `AgentSessions/Views/SessionTerminalView.swift:1915`
- `AgentSessions/Views/SessionTerminalView.swift:1883`

## Block Resolution Priority (Important Correlation Detail)

When a block contains mixed roles, priority determines the strip color.

| Condition | Resolved block kind | Accent hue |
|---|---|---|
| Block contains `.error` | `.error` | red |
| Else contains `.toolInput` | `.toolCall` | purple |
| Else contains `.toolOutput` | `.toolOutput` | green |
| Else contains `.user` | `.user` / `.userPreamble` | user styling |
| Else | `.agent` | brand |

Source: `AgentSessions/Views/SessionTerminalView.swift:4028`

## Session Mode Role Palette (Line Styling)

`TerminalRolePalette` defines foreground/background/accent for each role.

### Color Mode

| Role | Accent |
|---|---|
| `.user` | `NSColor.systemBlue` |
| `.assistant` | `agentBrandAccent(source:)` |
| `.toolInput` | `NSColor.systemPurple` |
| `.toolOutput` | `NSColor.systemGreen` |
| `.error` | `NSColor.systemRed` |
| `.meta` | `NSColor.secondaryLabelColor` |

Source: `AgentSessions/Views/SessionTerminalView.swift:1722`

### Monochrome Mode

| Role | Accent |
|---|---|
| `.user` | `NSColor(white: 0.30)` dark / `NSColor(white: 0.75)` light |
| `.assistant` | `NSColor(white: 0.4)` |
| `.toolInput` | `NSColor(white: 0.6)` |
| `.toolOutput` | `NSColor(white: 0.6)` |
| `.error` | `NSColor(white: 0.3)` |
| `.meta` | `NSColor.secondaryLabelColor` |

Source: `AgentSessions/Views/SessionTerminalView.swift:1676`

## Text Mode Syntax Colorization

From `TranscriptPlainView.applySyntaxColors`.

### Terminal Text Mode

| Category | Color |
|---|---|
| command ranges | orange |
| user ranges | blue |
| assistant ranges | secondary gray |
| tool output ranges | green |
| error ranges | red |

Source: `AgentSessions/Views/TranscriptPlainView.swift:3086`

### JSON Mode

| Category | Color |
|---|---|
| JSON keys | pink |
| JSON strings | blue |
| JSON numbers | green |
| JSON keywords (`true/false/null`) | purple |

Source: `AgentSessions/Views/TranscriptPlainView.swift:3021`

## Legacy Theme Colors (Compatibility Paths)

`TranscriptTheme` still defines legacy theme palettes used by attributed/ANSI builders.

| Field | `codexDark` |
|---|---|
| user | cyan |
| assistant | green |
| tool | purple |
| output | primary |
| error | red |
| dim | secondary |

Source: `AgentSessions/Services/TranscriptTheme.swift:20`

