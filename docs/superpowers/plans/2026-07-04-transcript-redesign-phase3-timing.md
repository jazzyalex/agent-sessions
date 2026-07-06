# Transcript Redesign Phase 3 — Turn-Timing Badges Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) tracking.

**Goal:** Show per-turn duration + tool-call count on assistant cards (`4.8s · 1 call`), per-tool duration in collapsed tool rows (`· 1.2s`), and — perf permitting — a live "running Xs+" pulse on the open turn of an active session, all in the Rich block list.

**Architecture:** A pure `TranscriptTurnTiming` helper pairs coalesced `LogicalBlock`s into turns and tool call/output pairs using their `.timestamp`s, returning per-block timing keyed by `globalBlockIndex`. The block-list cell renders those values as small secondary-label chips in the SwiftUI card header / collapsed tool row. The live pulse (T20) is leaf-scoped (a single `TimelineView`/timer inside ONE running-turn badge, never invalidating the NSTableView or other rows) or deferred if it can't be made cheap.

**Tech Stack:** Swift, SwiftUI (card header chips), AppKit, XCTest.

## Global Constraints

- **NO commits/push/branches without the standing owner mandate** (2026-07-04 grants staged commits; each task = its own commit). NO push.
- **Subagents NEVER build/test.** ONE central verification: `./scripts/xcode_test_stable.sh` (currently 1333 green).
- **Token/cost badges are EXCLUDED** (owner decision 2026-07-03 — quota/Runway covers usage). Timing only.
- **macOS 14.0 floor.** New files via `RUBYOPT="-E UTF-8" ./scripts/xcode_add_file.rb`; verify grep=4.
- **Foreign files untouched:** AgentSessions/CodexStatus/*, ClaudeStatus/*, AgentCockpitHUDView.swift, Preferences/*, CodexUsageParserTests.swift.
- **PERF CONSTRAINT (load-bearing for T20):** the perf program (W6/W8, see 2026-07-01-perf-instant-master-plan.md) traced the macOS "Using Significant Energy" label to periodic UI-clock invalidations (leaf clocks / 1Hz timers invalidating large SwiftUI bodies). A live "running Xs+" badge is exactly that pattern. T20 MUST be leaf-scoped: only the single running-turn badge's own view updates on each tick; the NSTableView, its rows, and all other cards must NOT re-render or re-measure. If that can't be guaranteed, T20 ships DEFERRED (static badges only) with a note — do not reintroduce the energy regression.
- `LogicalBlock` carries `.timestamp: Date?`, `.kind`, `.globalBlockIndex`, `.eventID`, `.toolName`. Timestamps may be nil for some blocks/providers — every duration is optional; render nothing when unavailable.

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `AgentSessions/Services/TranscriptTurnTiming.swift` | create (T18) | Pure: pair blocks into turns + tool call/output pairs; compute durations + call counts keyed by globalBlockIndex |
| `AgentSessions/Views/TranscriptBlockListView.swift` | modify (T19, T20) | Render timing chips in the card header / collapsed tool row; live pulse |
| `AgentSessionsTests/TranscriptTurnTimingTests.swift` | create (T18) | Duration/pairing/edge-case tests |

---

### Task 18: `TranscriptTurnTiming` — pure duration computation

**Files:** Create `AgentSessions/Services/TranscriptTurnTiming.swift`, `AgentSessionsTests/TranscriptTurnTimingTests.swift`.

**Interfaces (produce, verbatim):**
- `struct TurnTiming: Equatable { var durationSeconds: Double?; var toolCallCount: Int }`
- `struct ToolTiming: Equatable { var durationSeconds: Double? }`
- `enum TranscriptTurnTiming { static func compute(blocks: [SessionTranscriptBuilder.LogicalBlock]) -> (turns: [Int: TurnTiming], tools: [Int: ToolTiming]) }` — keys are `globalBlockIndex`.

Definitions (implement + test):
- **Turn** = a user prompt block and everything after it up to (not including) the next user prompt. The `TurnTiming` is attached to the turn's ASSISTANT-response anchor block — the first `.assistant` block after the user prompt (if none, attach to the user block). `durationSeconds` = (timestamp of the LAST block in the turn) − (timestamp of the user prompt block); nil if either timestamp is nil or the result is negative. `toolCallCount` = number of `.toolCall` blocks in the turn.
- **Tool duration** = for each `.toolOut` block, `timestamp(toolOut) − timestamp(matching toolCall)`, keyed by the toolOut block's globalBlockIndex (and/or the toolCall's — pick what the collapsed row renders; document). Match a toolOut to the nearest preceding unmatched `.toolCall` (same discipline as the transcript's existing call/output pairing — check if a helper already exists; if `mergeToolRuns`/coalesce pairs them, reuse that pairing rather than re-deriving). nil if timestamps missing/negative.

**Steps:** TDD. Write `TranscriptTurnTimingTests` with synthetic timestamped blocks (use `TranscriptTestFixtures` — it builds timestamped events; if it doesn't set controllable timestamps, extend it): a turn user→assistant→toolCall→toolOut with known timestamps asserts durationSeconds + toolCallCount; a nil-timestamp block yields nil duration; a negative delta yields nil; multi-turn keys don't bleed; a tool pair yields its duration. Then implement. Register both files (verify grep=4). Central verify. Commit `feat(transcript): turn/tool duration computation (Phase 3 T18)`.

---

### Task 19: Static timing badges in the card UI

**Files:** Modify `AgentSessions/Views/TranscriptBlockListView.swift`.

**Interfaces:** Consumes `TranscriptTurnTiming.compute`. The controller computes timing once per snapshot (cache it next to the other derived per-block maps; recompute on the same seam as `findMatchesByRowID`/session change), and the cell reads `turns[rowID]` / `tools[rowID]`.

Render:
- **Assistant card header:** a small secondary-label chip after the role label/timestamp: `"\(fmt(duration)) · \(n) call\(n==1 ? "" : "s")"` when `durationSeconds != nil` (e.g. `4.8s · 1 call`); omit the `· N calls` part when `toolCallCount == 0` (just `4.8s`); render nothing when duration is nil. `fmt`: sub-60s → `"4.8s"` (one decimal < 10s, whole ≥ 10s); ≥60s → `"1m 12s"`.
- **Collapsed tool row:** append `· \(fmt(toolDuration))` to the existing one-line summary/header when the tool's `ToolTiming.durationSeconds != nil`. Keep it subordinate to the tool name/summary (secondary label, small).
- Match AS identity: `.secondary`/tertiary label color, small caption font, existing card spacing tokens. NO token/cost text. These are the same NSHostingView-hosted SwiftUI headers T5/T6 built — extend those, don't add new subviews outside the header.
- Height parity: adding a chip to the header changes card height — ensure the height measurement includes it (the header is in the hosting view whose fitting size feeds row height; verify the measure path accounts for the header content, same as T5/T6 did). A chip that renders but isn't measured = clip.

**Steps:** implement; if any pure formatting is factored (`fmt`), unit-test it. Central verify (watch height/measure). Commit `feat(transcript): turn + tool duration badges on Rich cards (Phase 3 T19)`.

---

### Task 20: Live "running Xs+" pulse (perf-gated — DEFER if not leaf-cheap)

**Files:** Modify `AgentSessions/Views/TranscriptBlockListView.swift`.

**Goal:** on an ACTIVE (live-tailing) session, the open/last turn shows a live-updating `"running 12s+"` badge that ticks ~1Hz.

**Binding perf constraint (see Global Constraints):** the tick MUST update ONLY that one badge's view. Use a leaf `TimelineView(.periodic(from:by:1))` (or a single self-contained timer) INSIDE the running-turn's NSHostingView header — so SwiftUI re-renders only that hosting view's small subtree, never the NSTableView row, never `noteHeightOfRows`, never other cards. The badge's width must be stable (monospaced-digit or fixed-width) so a tick never changes row height (no re-measure). Verify: does a tick trigger any `configure`/`reloadData`/`noteHeightOfRows`/`updateNSView` on the controller? If yes → NOT leaf-scoped → STOP and ship deferred.

**Determining "active" / "open turn":** reuse the existing live-session signal the block list already has (follow-tail / `isNearBottom` machinery from Task 7, or whatever `derivedState`/session exposes as "session is live"). The open turn = the last turn with no succeeding user prompt while the session is active. Only ONE badge is ever live at a time.

**Steps:**
1. Determine active-session + open-turn signal (read the code; reuse Phase-1/Task-7 live machinery).
2. Implement the leaf `TimelineView` badge; fixed-width digits.
3. **Perf self-check (report it):** trace that a tick invalidates ONLY the badge view — no controller callback, no row re-measure. If you cannot PROVE leaf-scoping from the code, implement the STATIC fallback (show the final duration once the turn closes; no live tick) and report T20 as DEFERRED with the specific reason.
4. Central verify. Commit `feat(transcript): live running-turn pulse (Phase 3 T20)` OR, if deferred, fold the deferral note into the T19 commit / a docs note — do NOT commit a perf-risky live timer.

**Owner runtime-QA (batched to the final acceptance session):** with a live session open in Rich mode, watch the energy impact (Activity Monitor / the "Significant Energy" label) over a few minutes idle-with-live-badge — the exact regression W6/W8 fought. If it reappears, the badge is not leaf-scoped and must be reverted.

---

### Task 21: Phase 3 gate

- [ ] Full suite green (`./scripts/xcode_test_stable.sh`).
- [ ] Timing badges render on completed sessions (owner QA, batched).
- [ ] Live pulse (if shipped) proven leaf-scoped; energy watched (owner QA, batched).
- [ ] Update the HANDOVER doc: Phase 3 status; note T20 shipped-or-deferred + why.
- [ ] Proceed to PR #48 merge → integrated review → deploy-ready (per the autonomous mandate).
