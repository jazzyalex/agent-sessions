## Verified Plan: Terminal.app + Ghostty Live/Idle + Cockpit (Codex + Claude)

### Verification Snapshot (2026-03-03)
1. `Terminal.app` scripting dictionary exposes what we need for probe metadata:
- `tab.tty`
- `tab.busy`
- `tab.contents`
- `tab.custom title`
- `do script`
(verified via local `sdef`)

2. Ghostty upstream source confirms:
- `TERM_PROGRAM=ghostty` and `TERM_PROGRAM_VERSION` are exported (`src/termio/Exec.zig`)
- title and shell-integration title features exist (`src/config/Config.zig`)
- `new-window` IPC is explicitly “Only supported on GTK” (`src/cli/new_window.zig`)
- no AppleScript-related hooks found in `src` (`rg applescript/osascript/nsappleevent/scriptingbridge` => 0 hits)

3. Current app code is still iTerm-centric for probe/focus flow:
- iTerm probe candidate path and focus helpers live in [`CodexActiveSessionsModel.swift`](/Users/alexm/Repository/Codex-History/AgentSessions/Services/CodexActiveSessionsModel.swift)
- current live scope is Codex + Claude only in that same file

### Summary
Yes, we should support `Terminal.app` and `Ghostty` for active/idle sessions in Cockpit, with parity-by-capability rather than iTerm emulation.

| Capability | iTerm2 | Terminal.app | Ghostty |
|---|---|---|---|
| Discover live session terminal identity | High | Medium | Medium |
| Probe active vs idle from terminal surface | High | Medium/High | Low/Medium (heuristic-driven) |
| Focus exact tab/session | High | Best-effort | Not assumed (app-level fallback) |
| Reliable tab subtitle | High | Medium | Optional/low |

### Public Interface / Type Changes
1. Extend terminal metadata model in [`CodexActiveSessionsModel.swift`](/Users/alexm/Repository/Codex-History/AgentSessions/Services/CodexActiveSessionsModel.swift):
- add `terminalKind` (`iterm2`, `terminalApp`, `ghostty`, `unknown`)
- add `terminalSessionKey` (generic app session identity)
- keep existing fields (`termProgram`, `itermSessionId`, `revealUrl`, `tabTitle`) for backward compatibility

2. Replace bool-only focus semantics with explicit result:
- `enum TerminalFocusResult { exact, appOnly, unavailable }`

3. Split probe/focus logic by backend strategy:
- iTerm backend
- Terminal.app backend
- Ghostty backend

### Implementation Plan
1. Correct probe eligibility first:
- Restrict iTerm probe candidates so non-iTerm terminals are not forced through iTerm tail/probe paths.
- Keep current iTerm behavior unchanged for iTerm rows.

2. Add Terminal.app live-state probe:
- Query tab by TTY using AppleScript.
- Read `busy`, `contents`, `custom title`.
- Classification order: `busy` -> active, clear prompt -> idle, else mtime heuristic fallback.

3. Add Ghostty live-state strategy:
- Use existing process/log-path/session-id joins.
- Use activity heuristic for active/idle.
- Treat terminal introspection as unavailable by default unless future official API appears.

4. Focus behavior by terminal kind:
- iTerm2: existing exact focus logic.
- Terminal.app: attempt TTY-based tab targeting; return `exact` on success, else `appOnly` if app can be activated.
- Ghostty: app activation fallback only (`appOnly`) unless future API enables exact tab focus.

5. Tab subtitle policy:
- iTerm2: keep session name-based subtitle.
- Terminal.app: use `custom title` (fallback to tab/window title if present).
- Ghostty: show subtitle only when metadata provides it; do not synthesize misleading pseudo-tab titles.

6. Update Cockpit/Unified messaging:
- Terminal-specific focus help text and button state derived from `TerminalFocusResult`.
- Remove iTerm-only wording where backend isn’t iTerm.

7. Keep anti-ghost safeguards:
- Continue requiring actionable joins (`session_id`, log path, workspace match).
- Do not surface unresolved TTY-only placeholders for non-iTerm terminals.

### Files to Change
1. [`CodexActiveSessionsModel.swift`](/Users/alexm/Repository/Codex-History/AgentSessions/Services/CodexActiveSessionsModel.swift)
2. [`CockpitView.swift`](/Users/alexm/Repository/Codex-History/AgentSessions/Views/CockpitView.swift)
3. [`UnifiedSessionsView.swift`](/Users/alexm/Repository/Codex-History/AgentSessions/Views/UnifiedSessionsView.swift)
4. [`AgentCockpitHUDView.swift`](/Users/alexm/Repository/Codex-History/AgentSessions/Views/AgentCockpitHUDView.swift)
5. [`AgentCockpitHUDRowView.swift`](/Users/alexm/Repository/Codex-History/AgentSessions/Views/AgentCockpitHUDRowView.swift)
6. [`CodexActiveSessionsRegistryTests.swift`](/Users/alexm/Repository/Codex-History/AgentSessionsTests/CodexActiveSessionsRegistryTests.swift)
7. [`docs/CHANGELOG.md`](/Users/alexm/Repository/Codex-History/docs/CHANGELOG.md)
8. [`docs/summaries/2026-03.md`](/Users/alexm/Repository/Codex-History/docs/summaries/2026-03.md)

### Test Cases and Acceptance Criteria
1. Probe routing:
- non-iTerm terminals are excluded from iTerm-only probe functions
- iTerm rows still use existing iTerm paths

2. Terminal.app classification:
- `busy=true` => active
- prompt-at-bottom => idle
- ambiguous output => mtime fallback

3. Ghostty classification:
- no iTerm probe attempt without iTerm identity
- active/idle derived from heuristic and stable over refresh cycles

4. Focus behavior:
- result enum correctly maps to UI state/help text
- iTerm exact focus unchanged
- Terminal app-only fallback works when exact tab targeting fails
- Ghostty app-only fallback is explicit

5. Subtitle behavior:
- iTerm subtitle unchanged
- Terminal subtitle from `custom title`
- Ghostty subtitle absent unless metadata exists

6. Regression:
- existing iTerm tests remain green
- no duplicate or ghost unresolved rows introduced

7. Verification command set:
- build: `xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug build`
- tests: `./scripts/xcode_test_stable.sh` (plus targeted `CodexActiveSessionsRegistryTests`)

### Assumptions and Defaults
1. Scope is Codex + Claude only.
2. “Full parity” means maximum parity supported by each terminal’s real interfaces.
3. Ghostty exact tab/session focus is not assumed until an official control API is available.
4. No feature flags are added unless explicitly requested.
