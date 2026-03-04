## Quick Summary: Ghostty vs iTerm2 Support

Ghostty can be integrated into the same live-session framework as iTerm2, but it cannot currently match iTerm2's session-level control and probe precision in this codepath.

1. Exact tab/session focus

- iTerm2 gives a stable session identity (GUID + deep link).
- Ghostty currently has no equivalent session-target API in this codepath, so focus is app-level fallback.

2. High-confidence terminal-state probing

- iTerm2 exposes session-level probe signals (`is processing`, `is at shell prompt`, session contents).
- Ghostty path is heuristic (log/source activity), so active/idle is less precise.

3. Reliable tab-title enrichment

- iTerm2 lets us enumerate sessions and names for subtitle mapping.
- Ghostty has no confirmed equivalent enumeration here, so subtitle is only shown if metadata already exists.

4. Deep-link reveal behavior

- iTerm2 supports `iterm2:///reveal?...`.
- No comparable Ghostty deep-link/session reveal is wired here.

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

## V2: Ghostty Integration Delta (After V1)

### What Changed From V1
1. This v2 section narrows the integration strategy: Ghostty joins the same live-session framework, but does not reuse iTerm-specific probe and focus logic directly.
2. Focus UX is included for Ghostty as app-level fallback behavior, with explicit UI messaging for non-exact focus.
3. Subtitle fallback policy is now strict: if no real terminal-provided Ghostty tab title is available, show no subtitle.

### Final Architecture Decision
1. Keep one shared live-session pipeline in `CodexActiveSessionsModel`:
- discovery -> coalesce -> classify -> UI publish
2. Split terminal-specific behavior by capability:
- iTerm2 backend: existing high-fidelity probe/focus path
- Ghostty backend: heuristic classification + app-level focus fallback
3. Direct answer to the design question:
- Ghostty can share the framework with iTerm2, but should not keep iTerm2 logic unchanged.

### Public Interfaces / Types (Planned)
1. Add `TerminalKind` classification:
- `iterm2`, `terminalApp`, `ghostty`, `unknown`
2. Add explicit focus outcome model:
- `TerminalFocusResult { exact, appOnly, unavailable }`
3. Keep existing `CodexActivePresence.Terminal` fields backward-compatible while layering capability routing internally.

### Behavior Matrix: iTerm2 vs Ghostty
| Capability | iTerm2 | Ghostty v2 |
|---|---|---|
| Probe source | iTerm session metadata + tail/probe capture | Existing live heuristics (log/source activity windows) |
| Exact tab focus | Yes | No (not assumed) |
| Focus action in UI | Exact session focus | App activation fallback with explicit help text |
| Subtitle source | iTerm session/tab title | Only real Ghostty title metadata; otherwise blank |
| Fallback policy | Existing iTerm fallback rules | Heuristic-only, no iTerm probe call path |

### Implementation Delta (From Current Code)
1. Tighten iTerm candidate gating in `itermProbeCandidateKeys` and related eligibility checks so non-iTerm terminals (including Ghostty) are not routed into iTerm probe functions.
2. Preserve all current iTerm behavior once candidate routing is narrowed.
3. Add Ghostty terminal-kind inference from `termProgram` and use that to route classification/focus behavior.
4. Add Ghostty focus UX path that returns `appOnly` when app activation succeeds and `unavailable` when it does not.
5. Update Cockpit/HUD/Unified focus help text to reflect exact vs app-only vs unavailable behavior.

### Test and Validation Plan
1. Eligibility tests:
- Ghostty presences do not appear in iTerm probe candidate sets.
- iTerm presences still do.
2. Classification tests:
- Ghostty uses heuristic resolution and avoids iTerm tail/probe functions.
- iTerm classification remains unchanged.
3. Focus tests:
- iTerm returns exact path behavior.
- Ghostty returns app-only or unavailable, never false exact.
4. UI tests:
- Focus help text and button enablement match `TerminalFocusResult`.
- Ghostty subtitle remains hidden when no real title metadata exists.
5. Regression tests:
- Existing iTerm tests stay green.
- No duplicate live rows or unresolved ghost-row regressions.

### Out of Scope in V2
1. Exact Ghostty tab/session targeting.
2. Fabricated subtitle fallback values (session title or cwd) when terminal title metadata is absent.
3. Expanding live-session scope beyond Codex + Claude.

### Defaults and Assumptions
1. V1 content remains historical and unchanged; v2 is appended as the delta section.
2. No feature flags are introduced.
3. Ghostty integration is capability-aware, not iTerm-emulation.
