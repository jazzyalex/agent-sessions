# Steward program — rollout plan (2026-08-17)

Goal: sustainable multi-agent support. Contributors add agents; **stewards** (users of
that agent, named per agent) keep them format-verified — they already pay for the
subscription and generate sessions by using it; the ask is ~10 minutes, 2–3×/year.
Naming decided: *steward* (not "maintainer" — that word promises commit rights and
project-level responsibility; the maintainer is the owner).

Tiers: **Maintained** (owner) · **Steward-verified** (named steward) ·
**Best-effort** (no steward; descriptor stays, drift not chased).

## Track 1 — Repo (one PR, do first)
1. `STEWARDS.md`: agent → steward handle → last-verified date → tier. Linked from README.
2. README: Status column in the support matrix + short "Help add — and keep — your agent"
   section (no guilt copy).
3. `CONTRIBUTING.md`: "Become a steward" section (what it is / isn't / credit).
4. Templates: stewardship checkbox in `new-agent-source.yml` + agent-source PR template;
   new tiny `steward-signup.yml` for adopting an existing agent.
5. `steward-check` tooling: single-agent wrapper around `scripts/agent_watch.py` that
   audits the steward's local sessions and emits a redacted sample on drift.
6. Pinned "Stewards wanted" issue + `steward-wanted` labels for agents without one.

## Track 2 — In-app
- Contribute card is live (v4.9); its "How it works" CTA lands on CONTRIBUTING.md which
  now recruits stewards too. Later, own brief: in-app "Export sanitized format sample".

## Track 3 — GitHub Pages
- Support/matrix page with tier badges + steward credits; "Become a steward" page;
  nav/footer links; all promo links tagged per Marketing/LINK_TAGGING.md.

## Track 4 — Promo
- Launch on the 4.9 release (Qwen + contribute card). X post in Rollout voice (concrete
  fact lead), Reddit follow-ups. Per-steward credit posts on each verification (people
  reshare posts that name them). Coordinate via Marketing/STATUS.md; feeds the 1k-star goal.
- Direct recruiting beats broadcast: invite people who already asked.

## Launch cases (already in hand — use these first)
- **Grok Build issue** (open issue asking to support the unofficial Grok desktop app):
  the sample-provider path. Invite the reporter to the new-agent-source form with a
  sanitized sample; invite them to steward it once shipped.
- **Devin CLI PR #56** (working code, pre-registry architecture): the contributor path.
  Invite the author to redo against docs/adding-a-session-source.md (dry-run measured
  ~19 enumerated files vs 26+ pre-registry) and steward Devin after. Second real proof
  of the guide after Qwen.

Sequence: Track 1 → Pages → promo at 4.9 → in-app exporter once stewards exist.
Status: plan only — nothing implemented. Owner approved naming + direction in-session.
