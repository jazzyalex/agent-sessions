# The Rollout post 3 + expert series — design

Date: 2026-07-11
Status: Approved direction from Alex ("A. and i go to sleep. answer your questions yourself now"), remaining decisions self-answered by agent. All output is **drafts only — nothing committed or published** until Alex reviews.

## Goal

1. A flagship deep-dive post: comparative analysis of AI coding agent session
   formats — anatomy, measured efficiency, feature scorecard, weaknesses, and
   forward-looking recommendations. Register: research paper crossed with an
   essay ("how your AI agent writes down its dreams"). Also adapted for LinkedIn.
2. 2–3 additional articles on agentic development to build Alex's public
   expert profile (supports the 1k-stars growth goal).

## Decisions (self-answered)

- **New post**, not a rewrite. Links to the paths post (2026-07-11) as the
  companion reference. Same `_posts` Jekyll pipeline, same layout.
- **Evidence = option A**: real measurements over Alex's own local corpora for
  all six agents (Claude Code, Codex, Cursor, OpenCode, Copilot CLI, Hermes —
  all present on this machine). Published numbers are aggregates only
  (counts, bytes, ratios, timings). No transcript content, no paths beyond the
  documented store roots, no project names.
- **Methodology section** in the post (research-paper half): corpus size,
  date range, how each metric is computed, honest caveats (n=1 machine, one
  heavy user, usage mix differs per agent so cross-agent comparisons are
  indicative, not controlled).
- **Dream framing** (essay half): the transcript as the agent's memory trace.
  Codex `encrypted_content` = dreams it isn't allowed to remember; Claude's
  `parentUuid` tree = dreams that branch; OpenCode parts rows = dreams shredded
  into a database. Used as a throughline, not a running bit — voice guardrails
  still apply (no fake hooks, lead with fact, sarcasm ≤2 dry lines).
- **Graphics, inline SVG** (dataviz conventions, light+dark):
  1. Bytes-per-user-visible-message bar chart (measured).
  2. Feature scorecard matrix (resume, fork/tree, per-event model, cost data,
     crash-durability, greppability, docs, schema stability).
  3. "Anatomy of one turn" side-by-side structural diagram (3 formats).
- **Recommendations section with teeth**: what a good session format should
  provide, who is closest today, what each vendor should fix. This is the
  shareable/arguable part.

## Additional articles (draft all 3, Alex picks)

1. **The handover problem** — passing state between agent sessions; the
   RepoHandover.md practice; why "context is the new build artifact."
2. **Mining your own transcripts** — what N sessions of real history reveal
   about how you actually work with agents (reuses the measurement harness).
3. **Agent-legible repositories** — CLAUDE.md/agents.md conventions, scripts
   and skills as institutional memory; designing a repo agents can navigate.

Each: The Rollout voice, ≥1 original SVG visual, soft one-line CTA.

## LinkedIn adaptations

One per post in `Marketing/linkedin/` (new folder): 150–250 words, fact-led
opener, no corporate mush, link to post. Not posted by the agent.

## Deliverables

- `scripts/` stays untouched; measurement harness lives in the session
  scratchpad; results JSON copied to `docs/superpowers/specs/data/` for
  reproducibility of the published numbers.
- Draft posts in `docs/_posts/` with future-ish dates for Alex to adjust.
- Morning summary in chat: decisions, headline numbers, file list, what needs
  his review before publishing.

## Out of scope

- Committing, pushing, publishing, posting to LinkedIn.
- Decoding Cursor protobuf blobs or Codex encrypted reasoning.
- Any per-session or per-project content in published numbers.
