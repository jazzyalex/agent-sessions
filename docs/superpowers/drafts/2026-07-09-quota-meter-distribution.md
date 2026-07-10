# Distribution kit — "Projecting the Claude 5-hour limit: burn rate, not percent used"

Companion to `2026-07-09-quota-meter-burn-rate.md`. All copy obeys
`docs/superpowers/the-rollout-voice.md`. Blog link resolves after publish; use the
GitHub link until then.

- Blog: https://jazzyalex.github.io/agent-sessions/blog/projecting-claude-5-hour-limit-burn-rate/ (placeholder slug — confirm at publish)
- Repo: https://github.com/jazzyalex/agent-sessions

---

## X thread

Each tweet ≤280 chars, lowercase register, one idea each. Attach the Session Runway
screenshot to tweet 4.

**1/**
claude's 5-hour limit is a rolling window: it resets relative to when you started
working, not at a fixed hour. codex meters the same way. so the "% used" number most
tools show can't predict when you'll get cut off, because it contains no time.

**2/**
"29% used" at 10:00 and "29% used" at 10:30 are the same reading. one can be a quiet
morning while the other is a session that just ate a quarter of the window in ten
minutes. a level can't tell those apart; only a rate can.

**3/**
agent sessions measures the rate instead: it tails your session logs, turns each
session's tokens into tokens/sec (cache reads weighted at 10%, streaming duplicates
deduped by message id), and splits the account-wide burn across sessions in
proportion.

**4/**
each session shows quota minutes per hour. 100% of a 5h window is 300 quota minutes,
so a session at 40 m/h spends 40 of them per hour of wall clock. run-out is then
remaining ÷ rate, and it shows up while you can still pause something.

**5/**
claude's usage api reports whole percents and we read it via the cache the claude
code statusline keeps warm (polling harder earns a 429), so claude's projection is
coarse by design. codex exposes fine-grained local data. we label the difference
instead of faking parity.

**6/**
the burn bars don't depend on that coarse api. they come from token attribution in
the local logs, so they stay live on both providers. free, local-only, no telemetry.

https://github.com/jazzyalex/agent-sessions

---

## LinkedIn

Claude meters usage on a rolling 5-hour window with weekly caps on top, and Codex
meters the same way. A rolling window makes the usual readout, a static "% used,"
a poor predictor: whether you reach the reset before the window fills depends on
the burn rate, and a percentage contains no time. "29% used" at 10:00 and at 10:30
is the same reading even when one is a quiet morning and the other is a session
that consumed a quarter of the window in ten minutes.

I wrote up how Agent Sessions, our free macOS app for browsing Claude Code and
Codex history, turns that into something you can act on:

- It tails the local session logs and computes a per-session token rate, weighting
  discounted cache reads at 10% of their raw count and deduping the duplicate rows
  streaming writes.
- It splits the account-wide burn across sessions in proportion to those rates and
  renders each as quota minutes per hour (100% of a 5-hour window is 300 quota
  minutes), plus a projected run-out time.
- It stays honest about data quality. Codex provides fine-grained local rate-limit
  data, so its projection is sharp. Claude's usage arrives as whole percents
  through a cache shared with the Claude Code statusline (polling harder gets you
  rate-limited), so its projection is coarse by design, and the app says so
  instead of simulating precision.

The per-session burn bars come from token attribution in the transcripts, not from
the coarse account number, so they stay live on both providers.

Free, local-only, no telemetry. Writeup and source:
https://github.com/jazzyalex/agent-sessions

---

## Reddit

**Suggested subs:** r/ClaudeAI, r/ChatGPTCoding, or a Codex/Claude Code community.
Check each sub's self-promo rules before posting; lead with the insight, keep the
link at the bottom. Verify the current rules on the day you post.

**Title:** Why "% used" can't predict when your Claude/Codex limit runs out, and
the burn-rate math that can

**Body:**

Claude's 5-hour limit and Codex's usage caps are rolling windows: they reset
relative to your own activity, not on a schedule. That detail makes the standard
"% used" readout close to useless for predicting a cutoff, because a percentage is
a level and the cutoff depends on a rate. "29% used" at 10:00 and at 10:30 read
identically even when one account is idle and the other has a session burning a
quarter of the window every ten minutes.

Building something actionable takes three steps, all computable from data your
agents already write locally:

1. Per-session token rate. Each agent turn logs its token usage to the session
   transcript. Tail the files and compute tokens/sec per session. Two gotchas from
   real logs: weight cache reads at a fraction of their raw count (they're billed
   at a steep discount, so a big context re-read isn't the fire it appears to be),
   and dedupe streaming's duplicate usage rows by message id.
2. Convert to quota burn. Split the account-level usage movement across active
   sessions in proportion to their token rates. Each session gets a
   percent-per-second, which displays nicely as quota-minutes-per-hour (100% of a
   5h window is 300 quota minutes).
3. Project run-out as remaining ÷ rate. One trap: with no fresh projection, don't
   fall back to assuming run-out at the reset time, because the implied rate
   `remaining / time-to-reset` explodes as the reset approaches. Anchor the
   fallback to average burn (used% ÷ elapsed, with elapsed floored) so it stays
   sane at both ends of the window.

A caveat if you build this yourself: the providers are not equally generous with
data. Codex writes fine-grained rate-limit samples locally, so projections form
readily. Claude's account usage is whole-percent and best read through the cache
the Claude Code statusline already maintains (hitting the OAuth endpoint hard gets
you a 429 with a multi-minute clamp), so its projection stays coarse no matter how
clever the client is. Label that honestly rather than rendering fake precision.

I implemented this in Agent Sessions, a free, local-only macOS app for browsing
Claude Code and Codex sessions (no telemetry, it reads the logs your agents
already write). Writeup and source if you want the details or just the approach:
https://github.com/jazzyalex/agent-sessions
