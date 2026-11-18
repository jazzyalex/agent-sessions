# Hide Tool Work by Default — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **LEAN v1 (owner, 2026-11-08):** 6 tasks. Spec §0 overrides the rest of the spec. No live running-turn exception, no hint popover, no per-row Find reveal: Find landing on a hidden match turns Tools on.

**Goal:** The Session view shows each turn as prompt → answer by default; the Tools chip shows tool rows and the agent's in-between notes, and Find still reaches them.

**Architecture:** A pure per-snapshot turn index (`TranscriptTurns`) marks each turn's answer and notes. When Tools is off, row emission skips tool rows (today) and notes (new); Agent ▲▼, its count and the turn badge follow the rows actually emitted. Tools becomes an independent switch with a one-time migration to off. Find counts hidden matches and turns Tools on to reach one.

**Tech Stack:** Swift, AppKit (`NSTableView` via `BlockTableController`), SwiftUI toolbar, Combine, XCTest.

**Spec:** `docs/superpowers/specs/2026-11-08-transcript-hide-tool-work-design.md`

## Global Constraints

- Repo rule: **no commits, no branches, no worktrees** unless the owner says so. Work in the current checkout. Each task ends with its tests green and changes left uncommitted.
- Edit with the Edit tool, never inline python or heredoc rewrites.
- New Swift files: `./scripts/xcode_add_file.rb AgentSessions.xcodeproj <AgentSessions|AgentSessionsTests> <path> <group>`.
- Only one `xcodebuild` at a time (no parallel builds from subagents). Tasks run strictly in order: Tasks 2, 3 and 5 edit `BlockTableController`.
- Tests: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/<Class>` for a task; the full `./scripts/xcode_test_stable.sh` once, in Task 6. It opens the live index (memory "Tests mutate the live index").
- New localized strings: add to the xcstrings catalog, then update `EXPECTED_LOCALIZABLE_KEY_COUNT` and `EXPECTED_LOCALIZABLE_KEY_SHA256` in `scripts/validate_localization_catalogs.py` and the `(1657, 6, {"zh-Hans"})` literal in `scripts/tests/test_validate_localization_catalogs.py:163`.
- HIG tokens and design language from `agents.md`. No new toolbar control; no new row per turn.
- Perf: Session view Release open time within ±5% of main for Codex and Claude. Turn index computed once per snapshot, off the main thread, inside `TranscriptDerivedState.computeSnapshot`.
- Default `SessionRoleFilters` raw value: `user,assistant,errors`.
- Copy (exact): tooltip off → "Show tool calls and the agent's working notes"; tooltip on → "Hide tool calls and the agent's working notes".

## Review Focus

1. A session whose only agent text comes after an interrupt marker: nothing hidden, nothing lost (Task 1 test `testAgentTextAfterInterruptIsOutsideAnyTurn`).
2. Two identical consecutive agent messages merged into one row (`TranscriptMessageGroupIndex`) where one is a note and one is the answer: the row stays visible, and it is the Agent stop and badge anchor (Task 2 tests `testMergedRowWithAnswerMemberStaysVisible`, `testMergedNoteAnswerRowKeepsBadge`).
3. A session with tool calls but no agent text at all: prompt rows only, no badge (Task 2 test `testNoAgentTextTurnHasNoBadge`).
4. Find with Tools off and Agent off: a match in a note is not counted (Agent hides it on purpose); a match in tool output is (Task 5 test `testNoteMatchNotCountedWhenAgentOff`).
5. Search pill with Tools off and a raw-only tool hit: Tools turns on and the call opens (Task 5 test `testUnifiedRawOnlyHitTurnsToolsOnAndOpensCall`).

---

### Task 1: Turn index (pure) and snapshot field

**Files:**
- Create: `AgentSessions/Services/TranscriptTurns.swift`
- Modify: `AgentSessions/Services/TranscriptTurnTiming.swift:83-125` (use the shared segmentation)
- Modify: `AgentSessions/Services/TranscriptDerivedState.swift` (`Snapshot` gets `turnIndex`; set in `computeSnapshot`)
- Test: `AgentSessionsTests/TranscriptTurnsTests.swift` (create)

**Interfaces:**
- Produces:
  - `struct TranscriptTurn: Equatable, Sendable { let startIndex: Int; let endIndex: Int /* exclusive */; let endsWithInterrupt: Bool; let agentBlockIndices: [Int]; var answerIndex: Int? { agentBlockIndices.last }; var noteIndices: ArraySlice<Int> { agentBlockIndices.dropLast() } }`
  - `struct TranscriptTurnIndex: Equatable, Sendable { var turns: [TranscriptTurn]; var noteBlockIndices: Set<Int>; static let empty }`
  - `enum TranscriptTurns { static func isAgentText(_ block: SessionTranscriptBuilder.LogicalBlock, source: SessionSource) -> Bool; static func index(blocks: [SessionTranscriptBuilder.LogicalBlock], source: SessionSource) -> TranscriptTurnIndex }`
  - `TranscriptDerivedState.Snapshot.turnIndex: TranscriptTurnIndex`

- [ ] **Step 1: Write the failing tests** in `TranscriptTurnsTests` (reuse the block factory `TranscriptTurnTimingTests` uses):
  - `testAnswerIsLastAgentTextEvenWhenToolsFollow`: user, assistant(1), tool call, tool out, assistant(4), tool call → `turns[0].answerIndex == 4`, `noteBlockIndices == [1]`.
  - `testTurnWithoutAgentTextHasNoAnswer`: user, tool call, tool out → `answerIndex == nil`, `noteBlockIndices.isEmpty`.
  - `testBlocksBeforeFirstPromptAreNotNotes`: assistant(0), assistant(1), user(2), assistant(3) → `noteBlockIndices.isEmpty`, `turns.count == 1`, `turns[0].startIndex == 2`.
  - `testParentTaskStartsATurn`: a `.parentTask` user block starts a turn.
  - `testAgentTextAfterInterruptIsOutsideAnyTurn`: user, assistant(1), interrupt notice, assistant(3), assistant(4) → `turns[0].endIndex == 3`, `noteBlockIndices.isEmpty`.
  - `testGuardianVerdictEndingTurnIsTheAnswer`: Codex guardian source, verdict JSON as last assistant → `answerIndex` == its index.
  - `testSingleAgentMessageIsAnswerNotNote`.
  - `testContextAndPlaceholderBlocksAreNotAgentText`: hidden-context and placeholder assistant blocks are never in `agentBlockIndices`.

- [ ] **Step 2: Add the test file to the project and run it**

Run: `./scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessionsTests AgentSessionsTests/TranscriptTurnsTests.swift AgentSessionsTests` then `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/TranscriptTurnsTests`
Expected: build FAILS, `TranscriptTurns` not found.

- [ ] **Step 3: Implement `TranscriptTurns`** in the new file (add it with `xcode_add_file.rb … AgentSessions AgentSessions/Services/TranscriptTurns.swift AgentSessions/Services`). `isAgentText` is `TranscriptTurnTiming.isVisibleAgentMessage` moved verbatim (assistant kind, `rowStyle == .card`, origin `nil` or `.approvalVerdict`). Segmentation is the loop at `TranscriptTurnTiming.swift:87-102` moved verbatim (start at `startsTurn`; end before next `startsTurn` or right after `isInterruptControlMessage` / `ToolInvocationIndex.isTurnAbortedNotice`). Then give `TranscriptTurnTiming.compute(blocks:index:source:)` a new parameter `turnIndex: TranscriptTurnIndex? = nil`: it uses the given index for its segments and anchor (`agentBlockIndices.first`) and builds one with `TranscriptTurns.index` only when nil (standalone callers). Its output must not change. The table's call (`TranscriptBlockListView.swift:~1550`, main actor) passes the snapshot's `turnIndex` (Task 2 plumbs it into `apply`), so the Session path builds the index once, off-main.

- [ ] **Step 4: Add `turnIndex` to `Snapshot`** and set `snap.turnIndex = TranscriptTurns.index(blocks: blocks, source: source)` in `computeSnapshot`, next to the jump IDs.

- [ ] **Step 5: Run tests**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/TranscriptTurnsTests -only-testing:AgentSessionsTests/TranscriptTurnTimingTests`
Expected: all PASS (timing tests unchanged and green).

---

### Task 2: Hide notes when Tools is off; badge and Agent ▲▼ follow visible rows

**Files:**
- Modify: `AgentSessions/ToolRendering/TranscriptToolRows.swift` (`emit`)
- Modify: `AgentSessions/Views/TranscriptBlockListView.swift` (`apply`, `emitRows`, `rowsWithTelemetry`, timing call ~1550, `turnChipText` ~786, `handleRoleJumpIntent` ~3724; representable passes `derivedState.snapshot.turnIndex`)
- Modify: `AgentSessions/Services/TranscriptTurns.swift` (badge anchor helper)
- Modify: `AgentSessions/Views/TranscriptPlainView.swift` (`roleOccurrenceCount(.assistant)` from the controller's callback)
- Test: `AgentSessionsTests/TranscriptToolCellsTests.swift` (Harness computes `turnIndex` in `apply()`), `AgentSessionsTests/TranscriptTurnsTests.swift`

**Interfaces:**
- Consumes: `TranscriptTurnIndex`, `Snapshot.turnIndex` (Task 1).
- Produces:
  - `TranscriptToolRows.emit(…, hiddenNoteBlocks: Set<Int> = [])`: a message row is skipped when **all** its `representedBlockIndices` are in `hiddenNoteBlocks`.
  - `BlockTableController.apply(…, turnIndex: TranscriptTurnIndex = .empty)`; controller computes `hiddenNoteBlocks = toolsShown ? [] : turnIndex.noteBlockIndices` where `toolsShown = activeRoleFilters.isEmpty || activeRoleFilters.contains(.tools)`. The timing call passes `turnIndex:`.
  - **Visibility is per row:** a message row (id = group owner from `TranscriptMessageGroupIndex.groupIDByBlock`) is visible when any represented block is not hidden. Agent stops and the badge use these row ids.
  - `static func TranscriptTurns.chipAnchors(timing: [Int: TurnTiming], turnIndex: TranscriptTurnIndex, rowIDByBlock: [Int: Int], visibleRowIDs: Set<Int>) -> [Int: TurnTiming]` — keyed by row id: for each turn with timing, the row id of its first agent block whose row is visible; none → no entry.
  - `BlockTableController.onAgentStopCountChange: (Int) -> Void` (representable property, same pattern as `onBottomProximityChange`); `TranscriptPlainView` stores it in `@State` and uses it for `roleOccurrenceCount(.assistant)`.
  - When the anchor map changes, reload the rows whose chip text changed (old and new anchors); the badge is not part of the row model, so `rowEditScript` (~2746) would not reload them.

- [ ] **Step 1: Write the failing tests:**
  - `testToolsOffHidesNotesAndToolRows`: user(0), assistant(1), bash(2), assistant(3); `[.user, .assistant, .errors]` → `rowIDs == [0, 3]`.
  - `testToolsOnShowsNotes`: all roles → rows include 1 and 3.
  - `testAgentOffHidesAnswersRegardlessOfTools`: `[.user, .tools]` → no assistant rows.
  - `testMergedRowWithAnswerMemberStaysVisible`.
  - `testErrorsOnShowsFailedInvocationWithToolsOff` (unchanged behavior pinned). Superseded by owner QA 2026-11-09 (spec §0): renamed `testToolsOffHidesFailedInvocationEvenWithErrorsOn`; failed calls now follow Tools.
  - `testAgentJumpSkipsHiddenNotes`: Tools off, ▼ from top lands on 3, never 1; stop count callback reports 1, then 2 after Tools on.
  - `testTurnChipSitsOnAnswerWithToolsOffAndReturnsWithToolsOn`: read the chip text from the rendered cell (`table.view(atColumn:row:makeIfNecessary:)`), not from `turnChipText(forRowID:)`.
  - Pure (`TranscriptTurnsTests`): `testChipMovesToAnswerWhenFirstAgentMessageIsHidden`, `testChipStaysWhenNothingHidden`, `testNoAgentTextTurnHasNoBadge`, `testMergedNoteAnswerRowKeepsBadge` (anchor key == merged row id).
- [ ] **Step 2: Run, expect FAIL** (`-only-testing:AgentSessionsTests/TranscriptToolCellsTests -only-testing:AgentSessionsTests/TranscriptTurnsTests`).
- [ ] **Step 3: Implement.** A change of `turnIndex` or of Tools membership must re-emit rows.
- [ ] **Step 4: Run, expect PASS** (also `TranscriptTurnTimingTests`).

---

### Task 3: Tool groups open by default

**Files:**
- Modify: `AgentSessions/Views/TranscriptBlockListView.swift` (`seedAndCarryToolOpenState`, `carryOpenState`, ~2600-2660); `AgentSessions/ToolRendering/TranscriptToolRows.swift` (`seedOpenState` doc)
- Test: `AgentSessionsTests/TranscriptToolCellsTests.swift`

**Interfaces:**
- Rule: a group id seen for the first time with no older key opens unless one of its invocations is in `userToggledGroupMembers`. Re-keyed groups keep their carried state. Failed-invocation L2 seeding unchanged. No invocation opens at L2 by this rule.

- [ ] **Step 1: Failing tests:** `testFirstToolsOnOpensEveryUntouchedGroupAtL1` (two runs of 2+ tools; Tools off → on → all invocation ids in `rowIDs`; `openInvocations` holds only failed ids); `testGroupClosedByHandStaysClosedAcrossToolsCycle`.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.** Existing tests that rely on a fresh group starting folded (e.g. `testJumpIntoClosedGroupOpensIt`, `TranscriptToolCellsTests.swift:683`) keep testing a **closed** group: close it by hand with `toggleGroup(groupID:allRows: false)` first. Change an expectation to "open" only where the test is about the default itself. List every changed test in the report.
- [ ] **Step 4: Run `TranscriptToolCellsTests`, expect PASS.**

---

### Task 4: Tools chip — independent switch, migration, count, tooltip

**Files:**
- Create: `AgentSessions/Services/SessionRoleFilters.swift`
- Modify: `AgentSessions/Views/TranscriptPlainView.swift` (`@AppStorage("SessionRoleFilters")` default, `loadRoleFilters`, `toggleRoleFilter`, `roleFilterChipHelp`, chip count rule ~1441)
- Modify: `AgentSessions/Resources/Localizable.xcstrings`; `scripts/validate_localization_catalogs.py`; `scripts/tests/test_validate_localization_catalogs.py`
- Test: `AgentSessionsTests/SessionRoleFiltersTests.swift` (create)

**Interfaces:**
- Produces: `enum SessionRoleFilters { static let defaultRaw = "user,assistant,errors"; static let migrationKey = "SessionRoleFiltersToolsHiddenMigrated"; static func toggled(_ active: Set<TranscriptRoleFilter>, role: TranscriptRoleFilter) -> Set<TranscriptRoleFilter>; static func migratedRaw(_ raw: String) -> String; static func migrateIfNeeded(defaults: UserDefaults) }`
  - `toggled`: `.tools` flips membership only. For You/Agent/Errors, today's focus-then-restore rule with base `[.user, .assistant, .errors]`, computed on the set without `.tools`, then `.tools` put back unchanged. Never returns a set with none of the three.
  - `migratedRaw`: removes `tools`; empty result → `defaultRaw`. `migrateIfNeeded`: if `migrationKey` unset, rewrite a stored `SessionRoleFilters` value with `migratedRaw` (absent value: nothing to write) and set the key `true`.
- Task 5 turns Tools on by inserting `.tools` and calling the existing `persistRoleFilters()`.

- [ ] **Step 1: Failing tests:** `testToolsClickOnlyFlipsTools`; `testFocusRuleIgnoresTools` (from all four, Agent → `[.assistant, .tools]`; Agent again → all four); `testMigratedRaw` (`"user,assistant,tools,errors"`→`"user,assistant,errors"`, `"user,tools"`→`"user"`, `"tools"`→`defaultRaw`, `"user"`→`"user"`); `testMigrateIfNeededRunsOnce` (suite `UserDefaults`).
- [ ] **Step 2: Add files to project, run, expect FAIL.**
- [ ] **Step 3: Implement and wire:** `migrateIfNeeded(defaults: .standard)` at the top of `loadRoleFilters`; `toggleRoleFilter` calls `toggled`; `@AppStorage` default `SessionRoleFilters.defaultRaw`; an empty parse falls back to the default set, not `allCases`.
- [ ] **Step 4: Chip count and tooltip:** Tools chip shows `snap.toolJumpIDs.count` in `.secondary` while off and count > 0; nothing while on. Tooltips from Global Constraints into the catalog; update the three localization pins.
- [ ] **Step 5: Run** `-only-testing:AgentSessionsTests/SessionRoleFiltersTests`, `python3 -m unittest scripts/tests/test_validate_localization_catalogs.py`, `python3 scripts/validate_localization_catalogs.py`. Expected PASS / exit 0.

---

### Task 5: Find reaches hidden rows by turning Tools on

**Files:**
- Modify: `AgentSessions/Views/TranscriptBlockListView.swift` (`matchesUnderActiveRoleFilter` ~3979, `scrollToCurrentFindMatch` ~4063, `jumpToRawOnlyToolMatch` ~4208; representable gets `onRequestToolsShown`)
- Modify: `AgentSessions/Views/TranscriptPlainView.swift` (`UnifiedTranscriptView` handles the callback)
- Modify: `docs/CHANGELOG.md` (`[Unreleased]`)
- Test: `AgentSessionsTests/TranscriptToolCellsTests.swift`

**Interfaces:**
- Eligibility in `matchesUnderActiveRoleFilter`: a match in an invocation's block (call, output, paired `.error`) is always eligible; a match in a note is eligible iff Agent is shown; every other block keeps today's rule.
- `BlockTableController.onRequestToolsShown: () -> Void`. When the navigated match (⌘F/⌘G or search pill) sits in a row that is not emitted only because Tools is off, the controller calls it, keeps the match as pending, and scrolls to it on the next `apply` that emits its row. `UnifiedTranscriptView` inserts `.tools` into `activeRoleFilters` and calls `persistRoleFilters()` (same as a chip click).
- `jumpToRawOnlyToolMatch`: drop the Tools guard; when Tools is off, request Tools on and complete the jump on the next apply. Its zero-matches trigger is unchanged.
- CHANGELOG `[Unreleased]` → Features: "The Session view now shows each turn as your prompt and the agent's answer. Tool calls and the agent's working notes sit behind the Tools chip, and Find still searches them."

- [ ] **Step 1: Failing tests:**
  - `testFindCountsHiddenToolMatchAndRequestsToolsOn`: Tools off; `applyFind(… shouldJump: true)` → `total == 1`, callback fired once; after `activeRoleFilters` gains `.tools` and reapply → invocation row visible and flashed/targeted.
  - `testFindOnHiddenNoteRequestsToolsOn`.
  - `testNoteMatchNotCountedWhenAgentOff`: `[.user, .errors]`, matches in a note and in tool output → `total == 1`.
  - `testUnifiedRawOnlyHitTurnsToolsOnAndOpensCall`: `source: .unified`, zero decoded matches, raw hit in a hand-closed 2-call group → callback fired; after reapply with Tools on the call is in `rowIDs` and open at L2.
  - Update `testFindUnderErrorsOnlyKeepsMatchesInShownFailedRows` (~1584): Find now counts both matches (`total == 2`, was 1).
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement**, then the CHANGELOG line.
- [ ] **Step 4: Run `TranscriptToolCellsTests`, expect PASS.**

---

### Task 6: Verification

- [ ] **Step 1:** Full suite: `./scripts/xcode_test_stable.sh -resultBundlePath /tmp/hide-tools.xcresult > /tmp/hide-tools.log 2>&1; echo "exit=$?"` (no pipe). Totals from `xcrun xcresulttool get test-results summary --path /tmp/hide-tools.xcresult`. Expected: exit 0, 0 failures, passed ≥ 4391 + added tests. Name the Task 3 tests that still exercise a closed group.
- [ ] **Step 2:** Release open-time gate with `TranscriptToolCorpusCheckTests.testMessageOpenPerformance`.
  - Baseline SHA **`cd50564afe24f06109584e039612c8c019b7cfb3`**: `git archive cd50564a | tar -x -C /tmp/hide-tools-baseline`.
  - Both runs use the Release invocation in `.superpowers/sdd/2026-11-07-transcript-message-readability/task-9-performance-final-manifest.json` (argv ~line 15) with both `AS_MESSAGE_PERF_*` and `TEST_RUNNER_AS_MESSAGE_PERF_*` (CHECK=1, INPUTS, OUTPUT, VARIANT=baseline|candidate). The candidate measurement applies the snapshot's `turnIndex` with roles `[.user, .assistant, .errors]`.
  - Each run must write its JSON; a missing JSON is a failed gate. Expected ratio candidate/baseline per source within 0.95–1.05.
- [ ] **Step 3:** QA build to `.deriveddata-run` (`xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug -derivedDataPath .deriveddata-run build`). Owner manual list: prompts and answers only; "Tools N" count; Tools shows everything open at L1; ⌘F on a word only in tool output turns Tools on and lands on it; same from the session-list search.
- [ ] **Step 4:** Report changed files; leave everything uncommitted.

