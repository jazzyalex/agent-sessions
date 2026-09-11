# Session Info Inspector — Design Spec

**Date:** 2026-09-10
**Surface:** `TranscriptTelemetryView` (the right-hand "Session info" pane in the transcript)
**Visual reference (authoritative):** `docs/superpowers/plans/assets/2026-09-10-session-info-inspector-mockup.html` — open it in a browser before writing any view code. It carries the exact strings, sizes and colors.

---

## Why

The pane shipped with `d75d7138`. Three defects, all visible in one screenshot of a normal session:

1. **Duplicate rows.** The pricing-basis list at `TranscriptTelemetryView.swift:152` builds its `Set` key from `model · speed · region · contextInputTokens`. Context input changes on every request, so the set never collapses: a 23-request session renders 23 near-identical lines that differ only in a number the reader does not need. The distinct facts are one model, one speed, one region.
2. **No type hierarchy.** The whole pane is `.font(.caption)` (`TranscriptTelemetryView.swift:104`). The three-line pricing disclaimer is set at the same size and weight as the session's token total, so the least important content is the most prominent by area.
3. **Absent values are paragraphs.** `Weekly quota: Unavailable (no compatible account-window calibration)` wraps to three lines to say "we don't know". Same for cost and tokens.

A fourth issue is structural rather than cosmetic: the pane already computes the configuration-change history that the inline transcript markers render, but offers no way to move between the two.

## Non-goals

- No change to the session list (left pane).
- No change to the inline configuration-change markers in the transcript body — they stay exactly as they are.
- No change to any telemetry accumulator, parser, price table or quota calibration. **This is a presentation-only change.** If a number looks wrong, that is a separate bug; do not "fix" it here.
- No new persisted state beyond one disclosure-expansion flag.

---

## The design

One panel, no tab bar, four sections top to bottom.

### 1. Cost hero + token subhero

```
$12.37   API-equivalent
18,969,245 tokens                      23 requests
▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░                              ← 3-segment share bar
● Cached 17.9M   ● Fresh 1.0M   ● Output 56.3K
```

- **Exactly one hero.** Cost at 27 pt; the token count drops to 14 pt directly under it. Two large numbers read as two competing answers to different questions; cost is the figure compared across sessions and the token count is its explanation.
- Cost renders at **2 decimal places** (`$12.37`), not 4. The full-precision value goes in the `.help()` tooltip.
- The bar encodes cached / fresh / output as fractions of top-line tokens. In this real session, cache reads are 94.3% of all tokens — the single most useful fact in the pane, and today the reader has to divide two numbers to find it.
- Cache-write tokens fold into the **fresh** segment (they are input the request paid to write) and are named in the tooltip. They are almost always zero.
- Reasoning tokens are **never** a bar segment: both providers report them as a subset of output (`SessionTelemetry.swift`, `TelemetryUsageSlice.reasoningOutputTokens`). They appear only as a tooltip line on the Output segment.
- The bar is hidden entirely when `usageSummary?.hasComponentBreakdown != true`.

### 2. Facts

```
Model            gpt-5.6-sol · high
Weekly quota     —
Delegated        —
```

Right-aligned, tabular-figure values against secondary labels.

- Show **one** model line (the current configuration). Started/current only both appear when they differ, and then the "started" value lives in the History section, not here — a session whose configuration never changed must not carry two identical lines.
- `Delegated` shows `12.3M tokens · 5 subagents` when descendants exist, otherwise `—`.

### 3. History (always visible, no disclosure, no tab)

```
HISTORY
○  Started gpt-5.6-sol · medium
   3:12 PM · inferred                              ↗
●  Thinking effort medium → high
   3:47 PM                                         ↗
```

- Real sessions carry 0–3 configuration changes. At that size a disclosure control costs more height than the rows it would hide, so the timeline is simply a section.
- The first row is always the **started** configuration, drawn with a hollow pip because it is a baseline, not a change. When `initialConfiguration.provenance == .inferredFirstObservation` it is suffixed `· inferred` — the transcript never stated a session-start setting, and the pane must not imply it did.
- Each row is a button. Clicking scrolls the transcript to the block carrying that change's inline marker and flashes it, reusing the existing `scrollToBlock` / jump-token machinery.
- Empty state: `No changes recorded`, secondary, one line.
- More than 4 rows: the section scrolls internally at a fixed max height rather than growing the pane.

### 4. "How this was estimated" (collapsed by default)

Everything that says *where a number came from* rather than *what it is*:

```
Priced as     gpt-5.6-sol · standard
Region        not recorded
Context in    101K – 116K
Price table   2026-09-10
Revision      r…364686
Manifest      c0bcca4a…8a5d0

Cost is computed for each request from its model, speed, region and
context size, then summed at published API rates. "Standard" is a
pricing assumption, not an observed service tier.
```

- **One "Priced as" row per distinct `model · speed · region`,** with the context range across that group's requests. Two models produce two rows. Twenty-three requests of one model produce one row. This is the fix for defect 1.
- Long hashes truncate head-and-tail with the full value in the tooltip and `.textSelection(.enabled)` preserved.
- Quota calibration rows (`sourceFamily`, `quotaPrecision`, `calculatedAt`, `quotaObservedAt`, `quotaResetAt`) live here, not above the fold.
- The section is a `DisclosureGroup` whose expansion persists in `@AppStorage("SessionInfoBasisExpanded")`, default `false`.

### Footer

`Estimates, not billing` on the left; `Refresh` as a borderless text button on the right. The current full-width push-button footer is replaced.

---

## Copy rules

| Situation | Ship this | Never ship this |
|---|---|---|
| Value absent | `—`, with the reason in `.help()` | `Unavailable (no compatible account-window calibration)` |
| Section title for provenance | `How this was estimated` | `Usage details`, `Basis` |
| Cost caption | `API-equivalent` + footer `Estimates, not billing` | A sentence inside the value area |
| Inferred start | `· inferred` suffix, reason in tooltip | A separate warning paragraph |
| Empty history | `No changes recorded` | Hiding the section |

Prose is confined to the collapsed provenance group and the tooltips. The visible pane has no sentences.

## Type and color contract

Reproduced in full in the mockup's "Type and color contract" table. Summary:

| Role | Font | Color |
|---|---|---|
| Hero value | `.system(size: 27, weight: .semibold)` + `.monospacedDigit()` | `.primary` |
| Subhero value | `.system(size: 14, weight: .semibold)` + `.monospacedDigit()` | `.primary` |
| Section head | `.system(size: 10.5, weight: .semibold)`, uppercase, tracking `0.6` | `.secondary` |
| Row label | `.system(size: 11.5)` | `.secondary` |
| Row value | `.system(size: 11.5)` + `.monospacedDigit()`, trailing-aligned | `.primary`; `.secondary` when `—` |
| Provenance prose | `.system(size: 10.5)` | `.secondary` |

Bar segments: cached `Color.secondary.opacity(0.55)`, fresh `Color.accentColor`, output `Color.orange`. All spacing comes from `LayoutTokens` (`AgentSessions/Utilities/LayoutTokens.swift`) — no literal paddings.

Both light and dark must be checked. Every color is a semantic SwiftUI color or `NSColor` role; no literal hex anywhere in the Swift.

---

## Open decision (owner)

**The toolbar entry point.** `UnifiedSessionsView.swift:1985` puts an `info.circle` toggle in a trailing group that already holds ~10 icons plus a `»` overflow, immediately next to a `sidebar.right` toggle of identical weight. Two candidates:

- **A (recommended):** remove the toolbar toggle and put an `Info` control in the transcript's own header row, beside the `ID fc5a` button at `TranscriptPlainView.swift:1447`. That row is where the other transcript-scoped controls already live (`A- A+`, `Copy`, `Export`, `Find`), and the pane is transcript-scoped.
- **B:** keep the toolbar toggle as-is.

`⇧⌘I` and the `View ▸ Session info` menu item (`AgentSessionsApp.swift:423`) stay in both cases. **This is not decided.** The plan implements neither until the owner picks; Task 6 is written for A and must be skipped if the answer is B.
