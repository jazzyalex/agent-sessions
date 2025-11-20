# Session Viewer v2 (Transcript | Terminal | Raw)

This doc summarizes the Session Viewer v2 changes (target v2.6.5) and how the code is wired.

## Modes
- **Transcript** (`SessionViewMode.transcript` → `.normal` render): conversation-focused output via `SessionTranscriptBuilder.buildPlainTerminalTranscript(..., mode: .normal)`.
- **Terminal** (`SessionViewMode.terminal` → `.terminal` render): CLI-style output that always uses terminal formatting. Prefers `buildTerminalPlainWithRanges` when tool commands + colorization are available; otherwise falls back to `buildPlainTerminalTranscript(..., mode: .terminal)` so markers like `[assistant]`, `[out]`, `[error]` remain.
- **Raw** (`SessionViewMode.raw`): First-class raw JSON view with Pretty/Raw toggle, rendered in the main surface rather than a sheet.

## Key UI Wiring
- `SessionViewMode` stored in `@AppStorage("SessionViewMode")`; legacy `TranscriptRenderMode` is kept in sync for compatibility.
- Segmented control: Transcript | Terminal | Raw. Shortcuts: ⌘⇧T toggles Transcript/Terminal, ⌥⌘J jumps to Raw. Cmd+F find UI still works across all modes.
- `contentView()` switches between transcript/terminal surface and the Raw JSON surface. Terminal preserves the inline “No commands recorded; Terminal matches Transcript” banner when sessions lack tool calls.

## Rendering Pipeline
- **Transcript mode**: always `.normal` render; no command/user highlighting.
- **Terminal mode**:
  - If tool calls exist: `buildTerminalPlainWithRanges` → `commandRanges` + `userRanges` + additional assistant/out/error detection for coloring.
  - If no commands or colorization off: `buildPlainTerminalTranscript(..., mode: .terminal)` to keep terminal markers even without ranges.
- **Raw mode**: uses `sessionPrettyJSON` (`PrettyJSON` over `[events.rawJSON]`) or `sessionRawJSON` (newline-joined). Basic JSON token coloring (keys, strings, literals) applied in `PlainTextScrollView`.

## Visuals
- `PlainTextScrollView` gains explicit mode hints:
  - Terminal: slightly darker background; strong colors for command (orange), user (blue), assistant (secondary), output (teal), errors (red).
  - Raw: light background with JSON token colors (blue keys, orange strings, purple numbers/bools).
- Background dimming while find highlights are active remains.

## Caching & Build Keys
- Cache keys now include `SessionViewMode` and timestamp toggle, ensuring Transcript/Terminal outputs don’t leak into Raw mode and vice versa.
- Raw mode sets a lightweight build key but bypasses transcript caches.

## Integration/QA checklist
- Run `xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug build` after changes.
- Validate with: (1) command-heavy Codex session, (2) Claude Code plan + shell session, (3) chat-only session. Compare Transcript vs Terminal vs Raw for clear differentiation.
