# Product Hunt Relaunch Plan — Quota Meter + Session Runway

Status: draft for review · Owner: Alexander M · Product: [Agent Sessions](https://www.producthunt.com/products/agent-sessions)

---

## TL;DR

Relaunch the **existing** Agent Sessions PH page with **Quota Meter + Session Runway** as the single hero.
Do **not** create a separate product page. Lead with one sharp wedge — *"see which agent session
is burning your Claude/Codex limit before it locks you out"* — not the old bundled "history & usage" pitch.

---

## Why relaunch (and why now)

Launch #1 (~9 months ago) scored **3 points, 8 followers, 2 comments** under the tagline:

> "Unified history & usage for Codex CLI and Claude Code"

Two failure factors, both now fixable:

1. **Diffuse pitch.** History *and* usage glued together = no single hook. PH rewards one-breath value props.
2. **Thin product.** At the time it was only a passive usage readout in the menu bar — no burn rate,
   no runway, no Cockpit. QM, per-session Session Runway, and Agent Cockpit did not exist yet.

The relaunch fixes both: the product is now genuinely strong **and** the pitch is now sharp.

## PH eligibility (verified 2026-07-01)

Official rule: **≥6 months between launches** AND a **significant update** (new functionality / substantially
different use case; "new UIs, pricing changes" do *not* count). Relaunches are team-reviewed; approval does
**not** guarantee homepage featuring.

- **6-month gate:** ~9 months elapsed → clears comfortably.
- **Significant-update gate:** live Quota Meter + per-session burn rate + projected run-out + Cockpit =
  new functionality serving a new use case (live runway monitoring, not passive history). Qualifies.
- **Action:** email hello@producthunt.com to pre-confirm the relaunch qualifies before investing in assets.

Source: PH Help Center — "Can I relaunch my product?"

---

## Positioning thesis

"Token usage" is a muddled phrase that conflates two jobs:

- **Cost tracking** (API / pay-per-token users) — retrospective spend analysis. *Minority* for coding agents.
- **Lockout avoidance** (subscription users on Pro/Max/Plus) — flat rate, but hit the **5-hour and weekly
  caps** and get cut off mid-task. *This is 90%+ of non-corporate devs.*

AgentPeek already targets the lockout segment (it shows an aggregate 5h/7d gauge), so "targeting subs" is
**not** the differentiator. The differentiator is one level deeper:

> **Attribution + prediction.** Not "you've used 60% of your window" (a fuel gauge) but
> "*this* session is burning 3× faster; you'll hit the limit in ~35 min — kill it before it strands the others."

Per-session burn rate did not exist in the market 9 months ago and still isn't offered by the notch-monitor
crowd. That is a legitimately new category, not a me-too.

### Language: kill the word "token"

"Token" reads as cost/API and makes sub users think "not for me."

| Don't say      | Say                          |
| -------------- | ---------------------------- |
| token usage    | usage window / limit         |
| tokens left    | runway / minutes left        |
| cost / spend   | lockout / run-out / cut-off  |
| track usage    | see it coming                |

---

## Competitive context — AgentPeek

Direct live-monitor competitor (2nd PH launch hit ~#9, ~173 pts). Solo dev [@brenhubr](https://x.com/brenhubr)
(~69 followers — the result came from launch craft + a demoable notch, not audience).

| | AgentPeek | Agent Sessions |
| --- | --- | --- |
| Integration | **Installs hooks** into agent config | **Read-only**, reads transcripts on disk |
| Footprint | In the permission path | Writes nothing (restore is opt-in) |
| Usage view | Aggregate 5h/7d gauge | **Per-session burn rate + projected run-out** |
| Surfaces | Any terminal + desktop apps | **Desktop / VS Code / CLI** (QM); Cockpit is iTerm2-only |
| Approve from UI | Yes (bought with hooks) | No (by design) |

**Wedge to own:** *non-invasive* + *per-session runway*. AgentPeek structurally can't tell the non-invasive
story — its whole value prop requires the hooks.

---

## Launch copy (draft)

### Tagline finalists (≤60 chars reads best)

1. **See which agent session is burning your Claude/Codex limit** ← recommended (attribution = the moat)
2. Live runway for your Claude & Codex usage — before you get locked out
3. Know when Claude cuts you off — and which session caused it

### Maker's first comment

> When you run 3–4 Claude Code / Codex sessions at once, one of them silently eats your 5-hour window —
> and you find out the moment everything locks out mid-task.
>
> Agent Sessions now shows the wall coming. **Session Runway** gives every active session its own live
> burn-rate bar and a projected run-out, so you can see *which* session is draining your limit fastest
> and kill or pause it before it strands the others. The Quota Meter sits in your menu bar for Claude and
> Codex across **desktop, VS Code, and CLI** — not just the terminal.
>
> It's read-only and installs no hooks — nothing touches your agent config; it reads what's already on
> disk. Local-first, free.
>
> Nobody else shows you usage *per session*. That's the part I couldn't live without.

### Gallery order

1. **Session Runway gif** (motion first — the hero)
2. Quota Meter menu bar (still)
3. Agent Cockpit (still)
4. Session browser (last)

### Demo-gif shot list (6–10s loop)

Must show *rate + prediction*, not a static bar, or it looks like AgentPeek's gauge.

1. **0–2s:** QM in menu bar, 5h window healthy (~55%), calm.
2. **2–5s:** Expand → 3–4 Session Runway bars; one visibly steeper. Label: "run-out ~35 min at this rate."
3. **5–8s:** Steep one crosses threshold → projected run-out alert: "You'll hit your 5h limit before it resets."
4. **8–10s:** Eye lands on the culprit session. Loop.

Contrast baked in: AgentPeek's gauge would still read "60%" through all of that — yours predicted the wall
and named the cause.

---

## Pre-launch checklist

- [ ] Email hello@producthunt.com to pre-confirm relaunch eligibility.
- [ ] Rewrite page tagline → sharp wedge (kill "unified history & usage").
- [ ] Fix stale scope on page — say **desktop / VS Code / CLI**, not just "Codex CLI and Claude Code."
- [ ] Purge stale gallery assets (old menu-bar-usage screenshots undercut the "major update" story).
- [ ] Record + optimize the Session Runway gif (`ffmpeg` + `gifski`, <2 MB, trimmed loop).
- [ ] Grow PH followers now off current X/GitHub momentum — followers get pinged on relaunch day.
- [ ] Update description + first comment per drafts above.

## Sequencing across the 3-in-1

- **Now → next:** this launch (Quota Meter + Session Runway) — widest reach, strongest differentiation, demoable.
- **After perf fix:** session-browser launch ("instant search across every agent"). Do **not** headline the
  browser while it has perf/CPU/Energy issues — "why does a log viewer use 40% CPU" is an unrecoverable top comment.
- **Ongoing:** Agent Cockpit as targeted community content (r/ClaudeAI, iTerm2 crowd) — TAM too small to headline.

Keep the binary as one app; split the *messaging*, not the download.

## Open items

- Confirm exact current 5h/weekly limit wording for Claude + Codex before publishing (avoid stale numbers).
- Decide launch date (Tue–Thu typically strongest on PH).
- Line up launch-day supporters (the lever that got AgentPeek to #9 despite a tiny following).
