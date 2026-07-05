# Transcript Render Redesign — Session Handover

**Date:** 2026-07-03 · **From:** planning/review session (v4.1 release) · **Status:** ~~approved direction, no code started~~ **PHASE 0+1 CODE-COMPLETE (2026-07-04)** — see status block below

> **STATUS 2026-07-04 — Phases 0+1 implemented, awaiting owner acceptance QA.**
> Executed via subagent-driven development on branch `feature/transcript-redesign-v5` (all work UNCOMMITTED by owner rule; plan + ledger: [2026-07-03-transcript-redesign-phase0-1.md](2026-07-03-transcript-redesign-phase0-1.md), `.superpowers/sdd/progress.md`).
> - **Phase 0 done:** `TranscriptDerivedState` (@Observable block-space owner) extracted; `SessionTerminalView` consumes it; behavior parity pinned by tests.
> - **Phase 1 done:** new **"Rich"** view mode (`SessionViewMode.blocks`, listed first in the mode menu; Terminal/Text/JSON untouched; Text remains default until parity is accepted): NSTableView card list, collapsible tool cards with one-line summaries + "N tool calls" merge + ShowAll truncation, windowing (load-older/widen/follow-tail), jump intents, cross-block selection+copy, ⌘F + unified search + auto-jump-on-open, toolbar Copy/Export parity.
> - **macOS floor stays 14.0** — the briefly-approved 15 bump was implemented then reverted same day (owner call; the memo's `@Observable`-needs-15 claim was wrong — Observation is macOS 14+; no chosen API needs 15).
> - Suite 1209 → **1269 green** (60 new tests). Final whole-branch review (Opus): no Critical/Important; ready to merge after owner QA.
> - **Phase 1 committed** (113db5ba) + review fixes (80464b96) + cleanup (b3f9d7dd).
> - **Phase 2 COMPLETE (2026-07-04):** markdown in Rich mode via swift-markdown — inline styles/headers (eae3ca73), code-fence dark cards + inline-code chips (f2ef10d3), lists (b2d70d96), GFM tables (50f29a1a), search-auto-expand of collapsed tool cards (0b70563a). Dep pinned by revision (5baf769f). Source map keeps ⌘F/selection intact; `.disableSmartOpts` keeps find working on prose; export path unchanged (reads block.text, not RenderedBody). Suite 1333 green; each task reviewed (Opus for T12/T15, Sonnet others). All UNPUSHED.
> - **Phase 3 COMPLETE (2026-07-04):** turn/tool duration computation (f580577f) + static badges on cards — `4.8s · 1 call` on turn anchors, `· 1.2s` on solo tool cards (b0fa0a23). Token/cost badges excluded per owner. **T20 live "running Xs+" pulse DEFERRED** (deliberate): the only session-liveness signal is `CodexActiveSessionsModel` (polling, the documented session-list beachball root cause), so a live ticking badge would risk the "Significant Energy" regression the perf program (W6/W8) killed; a block-heuristic has no clean stop condition. Static badges deliver the core value; revisit only with a safe leaf-scoped liveness signal. Suite 1356 green.
> - **Next:** merge PR #48 (kickSearchIngest crash fix) → integrated review of the whole transcript body + PR #48 → deploy-ready. Owner acceptance QA batched at the very end (feedback_qa_only_when_feature_ready).
> - Flagged repo follow-up (do separately): pbxproj contains THREE duplicate `AgentSessionsLogicTests` targets (live: `9E29F9AF3D49DDA01A884CB7`); `xcode_add_unit_test_target.rb` lacks an existence check.
**Read first:** [docs/transcript-ui-redesign-proposal.md](../../transcript-ui-redesign-proposal.md) (the full proposal — personas, AV analysis, phases). This handover adds decisions, repo state, and marching orders.

## Goal

Replace the flat monospaced NSTextView "Text" presentation with a structured block-based transcript: role-accented message cards, collapsed-by-default tool blocks with one-line summaries, rendered markdown (tables, code fences, inline-code chips). This is the v5 headline feature. Terminal ("Session") and JSON modes stay untouched.

## Decisions already locked (do not re-litigate with the user)

1. **One unified style.** No Normal/Focused (or Full/Conversation) split — the filter idea was explicitly dropped 2026-07-03. Rich rendering becomes the presentation of the existing "Text" mode (or a sibling entry) inside the current **Session/Text/JSON** view-mode menu. No new toolbar controls.
2. **No token/cost badges, no header metadata chips.** Date/model/tokens/id/resume chips were rejected (main toolbar already covers these; model can change mid-session). Keep: per-turn duration chips (`4.8s · 1 call`), per-tool durations, timestamps, live "running Xs+" pulse (Phase 3).
3. **Borrow AV's structure, not its identity.** No Inter webfont look; keep AS role palette (`TranscriptColorSystem`), agent brand accent for assistant, monospace-leaning identity, shared spacing tokens per agents.md. Evaluate avatar-letter circles against HIG — accent bar + role label may be more Mac-native.
4. **Syntax highlighting of code fences is a non-goal now.** AV uses Shiki (JS-only, verified in its source). Ship styled monospace code cards first; Splash/tree-sitter is a tier-2 follow-up.
5. **v5 versioning:** 4.1 (perf) shipped 2026-07-03. v5 is reserved for this redesign; cut it only when Phases 0–2 are in and Find/selection parity is verified (see proposal §"v5 evaluation" discussion — bar agreed with owner).

## Phases (from the proposal, aligned with the perf program)

- **Phase 0 — TranscriptDerivedState extraction.** This is W6 in [2026-07-01-perf-instant-master-plan.md](2026-07-01-perf-instant-master-plan.md) (see its alignment note). Write the W6 plan and Phase 1 plan together; the block-list view consumes the derived-state owner, the Terminal view shrinks to rendering + intents.
- **Phase 1 — Block list + cards + collapsible tool groups.** Virtualized list over windowed `LogicalBlock`s reusing `globalBlockIndex` / `TranscriptWindow` / slice `buildLines` scaffolding (all shipped, flags default ON since 4.1). Tool-only consecutive blocks merge into "N tool calls" cards; >20-line output truncated with "Show all".
- **Phase 2 — Markdown.** `AttributedString(markdown:)` + light table/fence renderer (or swift-markdown-ui — decide then). Cache rendered output per block (extend `TranscriptCache`, now backed by the generic `LRUCache`). Search hits auto-expand collapsed tool blocks.
- **Phase 3 — Turn timing badges.** Compute per-turn durations from event timestamps on `LogicalBlock`; live pulse ties into the cockpit. (Parser work; token extraction explicitly out.)

## Hard constraints / acceptance gates

- ⌘F Find with highlight + next/prev; cross-block text selection + copy; follow-tail on live sessions; markdown export unchanged (exporter already consumes `LogicalBlock`, not the view).
- Perf suites stay green: TranscriptWindowedBuildTests, TranscriptBuilderTests, TranscriptGoldenFixtureTests, TranscriptCacheTests, TranscriptRenderGenerationGateTests, Stage0PerfHarnessTests, PerfQuickWinsTests. Full suite is currently 1209 green.
- **Prior-art conflict, answered in proposal §5:** `docs/perf-fable-review.md` §1.3 rejected per-block views *as a perf fix* (selection/Find risks, didn't attack model-build cost). This redesign's goal is formatting, not perf; the named risks are the acceptance gates above; Text mode stays available until parity. Cite this, don't re-argue it.
- Keep the old Text path selectable until the rich view proves parity (the Purist persona).
- Repo rules: `agents.md` is authoritative; new Swift files via `scripts/xcode_add_file.rb` (note: `AgentSessionsLogicTests` compiles some app sources directly — a new file used by Session/FilterEngine may need adding to that target too, see LRUCache precedent in pbxproj); never commit without explicit user request; no branches/worktrees without approval.
- Subagent rules (owner-set): Sonnet for mechanical work, Opus for hard synthesis; **agents edit in parallel but never run xcodebuild — one central verification in the main session** (or `tools/release/deploy qa` when a release is next).

## Key code pointers

- Flat-string render path being replaced: `UnifiedTranscriptView` + `PlainTextScrollView` in [TranscriptPlainView.swift](../../../AgentSessions/Views/TranscriptPlainView.swift) (~:465 container, :3145 NSViewRepresentable, whole-doc `applySyntaxColors`).
- Model layer to build on: `SessionTranscriptBuilder.LogicalBlock` (+ `coalescedBlocks` memoized via `NSCacheMemo`), `TranscriptWindow`, `TerminalBuilder.buildLines(from:blockRange:)`, `TerminalLineID`, two-stage open in [SessionTerminalView.swift](../../../AgentSessions/Views/SessionTerminalView.swift) (`buildRebuildResult`, `widenWindowForJump` — new since 4.1, resolves off-window jumps).
- Colors: `TranscriptColorSystem` (semantic + agent brand accents); reference doc [transcript-color-reference.md](../../transcript-color-reference.md).
- Parked, related: [2026-06-30-transcript-phase4-find-jump.md](2026-06-30-transcript-phase4-find-jump.md) (⛔ banner explains why; re-evaluate after Phase 1 decisions).

## Mockup

[docs/mockups/transcript-redesign-mockup.html](../../mockups/transcript-redesign-mockup.html) — approved by owner (dark mode, unified style, AS toolbar preserved, clickable collapse on tool rows). Treat as directional, not pixel spec.

## Suggested first moves for the new session

1. Read the proposal + this handover + master-plan W6 entry.
2. Brainstorm/confirm only genuinely open questions with the owner (e.g. SwiftUI `LazyVStack` vs `NSTableView` for the block list; Find/selection architecture; whether the rich mode replaces "Text" or sits beside it). Owner expects ambitious, deep design work, not parameter tweaks.
3. Write the Phase 0+1 implementation plan (superpowers:writing-plans), then execute with subagents per the rules above.
