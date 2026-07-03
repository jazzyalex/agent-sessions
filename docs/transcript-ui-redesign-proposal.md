# Transcript UI Redesign — Proposal (AgentsView-informed)

**Date:** 2026-07-02 · **Status:** proposal, not scheduled
**Inputs:** AgentsView source analysis (frontend/Svelte), AS transcript code audit, AV screenshots (Normal + Focused), [competitive-agentsview.md](competitive-agentsview.md), [perf-transcript-virtualization-plan.md](perf-transcript-virtualization-plan.md)

---

## 1. The gap in one paragraph

AS renders a transcript as **one flat monospaced string** in a single `NSTextView` with role-colored spans (TranscriptPlainView.swift). AV renders **structured message cards**: left accent bar per role, header row (avatar, role, token/turn/timestamp badges), GFM markdown bodies (tables, code fences, inline-code chips), **collapsed-by-default tool blocks** grouped into "N tool calls" cards with per-call duration badges, and a **Focused mode** that reduces the transcript to user prompts + final assistant answers. That structure — not the web stack — is why AV's transcript reads dramatically better. Everything AV shows is derivable from data AS already parses (`SessionEvent`, `LogicalBlock`), except token/duration badges which need parser additions.

## 2. What AV does, concretely (from source)

| Element | AV implementation | AS today |
|---|---|---|
| Message cards | 4px left accent bar, role-tinted bg, rounded right corners (`MessageContent.svelte`) | color spans in flat text |
| Role header | 22px round avatar letter + role label + copy/pin buttons | none |
| Metadata badges | `12k ctx / 340 out`, `4.8s · 1 call` turn chip, timestamp, off-main model pill; live "running Xs+" pulse | none |
| Tool calls | collapsed by default; chevron; tool name + one-line summary + duration; expanded = param tag pills + content; >20 lines truncated with "Show all N lines"; separate collapsible Output section; consecutive tool-only turns merged into one "N tool calls" amber card | full inline dump |
| Focused mode | drops tool groups and intermediate assistant turns that end in a tool call; keeps user + final answers (`transcript-mode.ts`) | none |
| Density modes | default / compact / stream (chat-like) / skim | Text vs Terminal vs JSON |
| Markdown | `marked` GFM + DOMPurify, LRU-cached per message; tables, fences, inline-code chips | none (export-only) |
| Code highlighting | **Shiki 4.2.0** (verified in package.json + `highlight-fences.ts`): async post-render pass on *labeled* fences only; unlabeled fences stay plain | none |
| Header bar | provider pill, date, grade, resume menu, id, ctx/out totals, **cost $**, model | mode menu, id chip, find/export |
| Virtualization | @tanstack/virtual-core, ~120px estimates, measure-on-render, infinite loadOlder | single NSTextView (windowed-build scaffolding exists but off) |
| Search interplay | search hit auto-expands collapsed tool sections | highlight only |

## 3. Personas — how each wants to read a transcript

**P1 — The Archaeologist (debugging a past run).** "What did the agent actually do to my repo?" Needs: tool calls scannable but not dominant → collapsed tool rows with one-line summary + duration; expand only what matters; diff-colored Edit output; file-path links. Today they scroll through walls of green tool output. *Primary win: collapse + summaries.*

**P2 — The Skimmer (recovering context / reviewing outcome).** "What did I ask and what did I get?" Needs: Focused mode — prompts + final answers, rendered markdown (the answer often IS a table). Today tables are ASCII pipes in monospace. *Primary win: Focused mode + markdown.*

**P3 — The Cockpit Operator (watching a live session).** AS's differentiator (HUD, Runway, resume). Needs: follow-latest tail, "running 12s+" pulse on the open turn, per-turn durations to spot stalls. *Primary win: turn-duration badges + live states.*

**P4 — The Quota Auditor (cost/context watcher).** Uses Runway/quota strips already. Needs: per-message ctx/out badges and header totals — "which turn blew up my context?" Today: nothing. *Primary win: token badges (requires parser work).*

**P5 — The Purist (current power user).** Likes the terminal-log aesthetic, ⌘F, whole-transcript select/copy, monospace. Must not lose anything. *Constraint: keep Terminal/Session mode untouched; new view is a new mode, selection/Find/copy must work across blocks.*

## 4. Proposed solution

**Design stance: borrow the structure, not the identity.** We adopt AV's load-bearing ideas (cards, collapse, focused filtering, badges) but keep AS's own naming, toolbar, and HIG language:
- **One unified style, no Normal/Focused split** (user decision 2026-07-03). The new rich rendering becomes the presentation of the existing "Text" mode (or a sibling entry) inside the current Session/Text/JSON view-mode menu — no new toolbar controls.
- Keep AS's existing toolbar layout (mode menu, id chip, A−/A+, Copy/Export/Find, identity strip) — the redesign changes only the content area, not the chrome. No duplicate header metadata (date/model/tokens/resume already live in the main toolbar or are session-list concerns; model can change mid-session).
- Keep AS role palette and agent brand accents (`TranscriptColorSystem`), monospace-leaning identity, and shared spacing tokens per agents.md; no Inter-style webfont look, no avatar-letter circles if they read as web-chat (evaluate against HIG — a small role glyph or just the accent bar + label may be more Mac-native).

Add a new **"Rich" view mode** (becoming the default `.transcript` mode) built as a virtualized block list over the existing `LogicalBlock` layer — this is Option B from the virtualization plan, which that doc itself says to pick "if richer transcript formatting is on the roadmap." Terminal and JSON modes stay as-is (P5).

### Phase 0 — TranscriptDerivedState (shared with perf program W6)
Extract the derived-state owner planned as W6 in `plans/2026-07-01-perf-instant-master-plan.md` (coalesced blocks, lines, nav/semantic indices, computed off-main, key-invalidated). The block-list view consumes this instead of growing its own derived paths; the Terminal view shrinks to rendering + intents. Write the W6 plan and Phase 1 plan together.

### Phase 1 — Block list + cards + collapse (pure UI, data already exists)
- SwiftUI `List`/`LazyVStack` (or NSTableView if selection demands) over windowed `LogicalBlock`s, reusing `globalBlockIndex` / `TranscriptWindow` scaffolding (`FeatureFlags.transcriptWindowedBuild`).
- Message cards: 3px left accent bar + subtle role-tinted background; role palette reused (`TranscriptColorSystem.semanticAccent`, agent brand accent for assistant); role header with timestamp.
- Tool blocks collapsed by default: tool name + one-line summary (derive from `toolInput` — command/description/file path) + chevron; consecutive tool-only blocks merged into one "N tool calls" card; long output truncated at ~20 lines with Show all.
- Acceptance gates from the perf plan: ⌘F with highlight/next-prev, cross-block selection+copy, follow-tail, markdown export unchanged. This kills the whole-document recolor problem as a side effect (per-block rendering).

### Phase 2 — markdown
- ~~Focused/Conversation mode~~ — dropped per user decision (one unified style). If demand returns, AV's filter rule is trivial over `LogicalBlock`s.
- Markdown rendering for user/assistant bodies: `AttributedString(markdown:)` for inline + a light block renderer for tables/fences (or swift-markdown-ui dependency — decide then). Code fences monospace on inset background; inline-code chips; GFM tables as real tables. Cache rendered output per block (extend `TranscriptCache`).
- Search auto-expands collapsed tool blocks containing a match.

### Phase 3 — Turn timing badges (parser work)
- Compute per-turn durations from event timestamps (and tool-call counts) on `LogicalBlock`; turn chip (`4.8s · 1 call`), per-tool duration in the collapsed row, live "running Xs+" pulse for active sessions (ties into cockpit).
- ~~Per-message/header token badges (`Xk ctx / Y out`)~~ — dropped per user decision 2026-07-03 (token info judged not useful in the transcript; quota/Runway already covers usage). Revisit only if a concrete need appears.

### Explicitly not doing (now)
- **Per-language syntax highlighting of code fences.** AV uses Shiki (VS Code TextMate grammars, JS-only — not portable to native). ~80% of the visual win is the dark inset code-card styling; ship styled monospace fences in Phase 2, evaluate Splash or tree-sitter as a tier-2 follow-up.
- Stream/skim density modes, pin/bookmark, inline subagent conversations, health grades, cost engine — candidates later; don't berserk.

## 5. Risks / constraints
- **Prior art check (2026-07-03):** `perf-fable-review.md` §1.3 rejected per-block view virtualization — "kills cross-block text selection, breaks the single-storage Find/highlight/linkify pipeline, doesn't attack the measured cost (model build)." That rejection was made *as a perf fix for the Terminal view* and stands for that purpose. This redesign proposes block views for a different goal (rich formatting of the Text mode, which the review's cost argument doesn't address), and the two risks the review names are exactly this proposal's acceptance gates. Terminal mode (single-storage, full selection/Find) is retained untouched as the fallback until parity is proven.
- Selection + ⌘F across a virtualized SwiftUI list is the hard part (AV gets it free from the DOM). Mitigation: keep Text mode available until parity; consider per-block NSTextViews with a custom find coordinator, or Option A (TextKit 2 viewport) fallback if block list proves painful.
- Perf tests to keep green: TranscriptWindowedBuildTests, TranscriptBuilderTests, GoldenFixture, TranscriptCache, RenderGenerationGate, Stage0PerfHarness.
- Coordinate with the in-flight perf branches — Phase 1 replaces the same hot path the virtualization plan targets; do it once, not twice.

## 6. Mockup
Interactive HTML mockup (Normal/Focused toggle, expandable tool rows): `as-transcript-redesign-mockup.html` (session scratchpad; move to docs/assets if kept).
