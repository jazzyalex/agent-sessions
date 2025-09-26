# Agent Sessions as a Codex IDE Wrapper — Vision & Options

## Why

Agent Sessions already solves the hardest part of returning to flow with Codex CLI:

- Find the exact session by searching the rendered transcript (not raw JSON)
- Preview context to confirm you’ve got the right thread
- Resume Codex in the correct working directory with a single click
- Diagnose resume issues with a copyable “Resume Log”

The next step is to make the app feel like a focused IDE wrapper where the “document” is a session — historical or live — so developers can navigate and continue work without leaving the app.

## Options (from low effort → high capability)

1) Terminal Orchestrator (recommended first)
- Keep launching Codex in Terminal.app, but Agent Sessions is the “brain”.
- Stable actions: focus the new tab/window, bring a running tab to front for an already‑live session, open the working directory.
- Add: “Copy Launch Command” (cwd‑aware chain) as a power‑user affordance.
- Pros: Low risk, retains user terminal muscle memory. Works today.
- Cons: Not single‑window; automation is best‑effort.

2) Live Transcript Mirror
- Tail the session JSONL while Codex runs in Terminal; render a live transcript in the app.
- Search & navigate the live record; keep Terminal for interaction.
- Pros: Vibe coders get a consistent, searchable “doc”.
- Cons: Two UIs for one session (Terminal + mirror).

3) Embedded Terminal (spike later)
- Integrate a VT100/ANSI emulator (e.g., SwiftTerm) and run Codex inside the app.
- Pros: True single‑window IDE feel.
- Cons: Heavy lift (PTY, key handling, colors, scrollback, perf); compatibility overhead with Codex TUI changes.

4) Workflow Recipes (vibe‑first comfort)
- Curated quick actions after resume (e.g., DMG build, notarize, changelog).
- Snippets per repo/session; optional “Run after resume” or “Insert into Codex”.
- Pros: Adds value without building a terminal.

## Phased Roadmap (lean)

- Phase 1: Orchestrate + Mirror
  - Keep Terminal launch/focus; add “Bring to running tab” heuristic.
  - Live transcript tail for the active session (toggleable).
  - “Copy Launch Command” next to Launch (documented as TODO).
  - Pin/favorite sessions; recent searches.

- Phase 2: Workflow Comfort
  - Quick Commands per repo; saved searches; subtle “may not resume” indicator (no blocking).

- Phase 3 (spike): Embedded Terminal behind a flag
  - Integrate SwiftTerm; prove Codex TUI parity (text I/O, selection, colors); exit if parity is insufficient.

## Non‑Goals (for the near term)

- Full terminal parity (all key chords, multiplexing, profiles) — only if we validate demand.
- Proprietary Codex internals — keep to CLI surfaces and on‑disk JSONL.

## Risks

- Terminal emulation complexity and maintenance cost.
- Codex CLI resume behavior evolves; diagnostics remain essential.
- Performance: multiple live tails + large libraries; mitigate with lazy loading & background indexing.

## Success Criteria

- “Search → Preview → Resume → Continue” is consistently faster than /resume alone.
- Users can navigate and recall across projects; pinned sessions save time.
- Diagnostics explain non‑resumable logs; no silent failures.

## Open Questions

- Default for live transcript mirror: on globally, or opt‑in per session?
- Where to surface Quick Commands (toolbar vs. context menu)?
- Should “Copy Launch Command” include the full fallback chain by default? (Likely yes, to match Terminal behavior.)

