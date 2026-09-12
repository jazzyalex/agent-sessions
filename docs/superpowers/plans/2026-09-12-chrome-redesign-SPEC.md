# Chrome Redesign — Design Spec

**Date:** 2026-09-12
**Scope:** Main toolbar, transcript toolbar, chrome surfaces, Session info row policy and icon.
**Presentation only.** No telemetry, parser, pricing or index change.

**Mockups (authoritative):**
- `docs/superpowers/plans/assets/2026-09-12-chrome-redesign-mockups.html` — full-window light and dark, both overflow menus, four transcript-toolbar states. **Open this before writing view code.**
- `docs/superpowers/plans/assets/2026-09-12-chrome-audit.html` — the rationale and the frequency ranking behind each move.

---

## Why

One cause behind five complaints: every control that has ever been useful is on screen at all times, at equal weight. The main toolbar carries 18 controls plus an overflow chevron; the transcript carries two rows; the view-mode dropdown is styled as a primary action for a choice made once a year.

The ranking rule used throughout: **a glyph earns permanent toolbar space by being reached for without thinking.** Anything you have to look for is more discoverable as a named menu row than as an unlabelled 16pt glyph.

Audience: someone running 10–50 agent sessions a day across Codex and Claude. They find a session, read what the agent did, and check what it cost. They do not read raw JSON, do not switch to Text view, and set the font size once.

---

## 1. Main toolbar — 18 controls to 6 plus a menu

Five groups, in order:

| Group | Contents |
|---|---|
| Sources | Codex / Claude / OpenCode / Hermes pills |
| Search | The field, taking the reclaimed width, with `Starred` and `Archived` as scope chips inside it |
| Actions | Quota Meter, Open in Terminal |
| View | Layout, Transcript pane, Session info |
| Menu | `⋯` |

**Archive stops being drawn four times.** Today each source pill carries its own archive icon; it becomes one scope chip in the search field.

**Into the `⋯` menu**, each gaining a name: Statistics, Reveal in Finder, Image Browser, Reindex now, Appearance ▸, Settings…

**Out of the toolbar entirely:** Collapse all / Expand all move into the session list's own header, next to the rows they affect.

Restored after review, with what each beat:

| Kept in toolbar | Over | Why |
|---|---|---|
| Quota Meter | Statistics | Checked several times a day against a weekly window; Statistics is a monthly look-back. Also the app's signature window. |
| Open in Terminal | Reveal in Finder | The move after reading a session is `cd` into that repo. Finder is the same intent for file-first users and stays one row down in the menu. |

## 2. Transcript toolbar — two rows to one

`[You] [Agent] [Tools] [Errors]  ·····  ⧉ a277 │ Copy  Export │ 🔍 ⌘F │ ⋯`

| Change | Detail |
|---|---|
| View mode leaves | Into `⋯ ▸ View as ▸ Session / Text / JSON`, plus ⌘1 / ⌘2 / ⌘3. This was the loudest control in the pane for the rarest choice. |
| `All` chip disappears | No filter selected already means all roles. The chip existed only to undo the other four. |
| ▲▼ arrows disappear | Jump-to-next stays on ⌘G / ⇧⌘G and appears on the active chip on hover. Four permanent arrow pairs served one action. |
| Errors chip carries a count | `Errors 2` tells you whether to press it. Zero errors: no count, dimmed chip. It is the only filter with real signal. |
| Text size leaves | `⋯ ▸ Text size`; ⌘+ / ⌘− already work. |
| Copy and Export stay | Same intent — get this out of the app — so they read as one group. Copy is a daily action. |
| ID keeps its place | `⧉ a277`. The one identity string a user actually copies. |

**Find-open state:** the field takes the row and the role filters collapse to a single `3 filters` chip. Drawn in the mockup.

## 3. Surfaces — one warm neutral for all chrome

Light mode currently reads as two apps stitched together: the inspector paints `controlBackgroundColor` (pure white) beside a warm-paper transcript. Dark mode hides the problem because every dark surface collapses toward the same near-black.

Three-step ramp, one warm bias:

| Level | Surface | Used by |
|---|---|---|
| 0 · Chrome | warm neutral | toolbars, session list, **inspector**, status bar |
| 1 · Paper | lifted, warmer | transcript body — the only lifted surface |
| 2 · Card | card fill on paper | message cards |

**The rule:** the transcript is the only thing that gets a lifted surface. Everything framing it sits at Level 0. The inspector is chrome, so it belongs at Level 0 — not above the paper it annotates.

Applied, not inverted, in dark: Level 1 is slightly **darker** than the chrome. A raised light surface in a dark UI reads as a modal.

## 4. Session info — row policy

| Case | Treatment |
|---|---|
| **Structurally impossible** — Delegated in any Codex session | Do not render the row. `CodexTelemetryAccumulator.swift:159` writes `ownership: .session` as a literal; `.descendant` is unreachable, so the em dash is permanent and teaches the reader to ignore the row. |
| **Possible, absent here** — Delegated in a Claude session with no subagents | Do not render it. "Delegated nothing" is the default; only the exception earns a row. |
| **Possible, blocked** — Weekly quota with no calibration | Keep the row, replace the em dash with an actionable `Calibrate ↗` that opens the Quota Meter. An absence you can act on is worth its line. |

Rename the row **Delegated to subagents** when it does appear — "Delegated" alone does not say to whom, which is the confusion that prompted this.

**This is the one item that makes a claim about data.** Hiding Delegated is correct for Codex today because the accumulator cannot produce delegated records; it must be revisited if Codex ever reports subagent usage. Gate it on the provider's capability, not on a hardcoded `source == .codex` check, so the claim stays true.

## 5. Session info icon

`info.circle` means "about this app" everywhere else in macOS and sits one slot from an identically-weighted `sidebar.right` toggle.

**Use `gauge.with.needle`.** The panel is about consumption, not help; nothing else in the toolbar is round-with-a-needle. `sidebar.trailing` is the strict macOS inspector idiom and would be correct in isolation, but is unusable while a near-identical sidebar glyph sits beside it.

Whichever ships, it must be the only right-side panel toggle at full weight.

---

## Build order

1. **Transcript toolbar to one row.** Self-contained, biggest visible weight drop, touches no data and no other view.
2. **Main toolbar to five groups** with the overflow menu. Relocation, not rewrite.
3. **One warm neutral for all chrome** plus the inspector surface. Token pass; own commit.
4. **Inspector row policy and icon.** Changes what is claimed about data; most review.

## Constraints

- No literal colors: semantic SwiftUI colors or `NSColor` roles only.
- No literal spacing: `LayoutTokens` only.
- Every string that reaches the UI goes through the localization catalog — the app ships Simplified Chinese, and `scripts/validate_localization_catalogs.py` gates it.
- Keyboard shortcuts survive every move: ⇧⌘I, ⌘F, ⌘G / ⇧⌘G, ⌘+ / ⌘−, ⌥⌘F, and the new ⌘1 / ⌘2 / ⌘3.
- Accessibility labels move with their controls; a control that becomes a menu row keeps its label as the row title.
