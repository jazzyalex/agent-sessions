---
layout: post
title: "Projecting the Claude 5-hour limit: burn rate, not percent used"
description: "A '% used' number can't say when the Claude 5-hour limit will stop you. The burn-rate math behind projecting run-out for Claude and Codex usage limits."
date: 2026-07-09
---

The Claude 5-hour limit is a rolling window, not a daily allowance. It starts
counting when you start working, resets relative to your own activity rather
than at a fixed hour, and carries weekly caps on top. Codex meters its usage
limit the same way. That mechanism is what makes the standard readout, a static
percentage like "7% used," such a weak planning tool: whether you reach the
reset before the window fills depends on how fast you're burning, and a
percentage carries no information about speed. Two accounts can show the
identical number while one of them is twenty minutes from a hard stop.

[Agent Sessions](https://github.com/jazzyalex/agent-sessions) ships a Quota
Meter with a Session Runway drawer built to answer what the percentage can't:
how much of the Claude limit is left as a trajectory rather than a level, which
session is spending it, and when the current pace runs the window dry. The math
below is everything that view computes, including the places where the source
data forces some honesty about precision.


## What the percentage actually reports

Because both providers meter on rolling windows, the question of when the
Claude limit resets has no fixed daily answer; the reset lands five hours after
the window opened, wherever that happened to fall in your day. A moving target
already argues for tracking a rate. The raw reading argues harder, because it
is coarser than most people assume.

On Claude, Agent Sessions reads usage from the OAuth endpoint, and that payload
reports whole-percent values: `five_hour.utilization` and `limits[].percent`
move in steps of a full 1%. One percent of a 5-hour window is the finest change
the endpoint will ever show. The app polls every 60 seconds, but the fetch
underneath is cache-first: when the shared usage cache is younger than 180
seconds, the cached payload is served and the live API call is skipped. The
sharing is deliberate, and the second half of this post explains it. The
immediate consequence is that a raw Claude percentage is coarse and slightly
behind reality at the same time.

A perfectly fresh percentage would still be ambiguous, though, because a level
admits opposite explanations. As an illustration: "29% used" at 10:00 and
"29% used" at 10:30 are the same reading, and one can be a quiet morning while
the other is a session that consumed a quarter of the window in ten minutes and
just went idle. Nothing in the number separates those cases, because nothing in
the number involves time.

<figure class="post-figure">
<img src="{{ '/assets/quota-meter-light.png' | relative_url }}" alt="Agent Sessions Quota Meter showing Codex and Claude 5-hour and weekly percentages, with a Session Runway list below giving each active session's burn rate in quota-minutes per hour">
<figcaption>The Session Runway, under the raw percentages, lists each active session's burn rate in quota-minutes per hour. That per-session rate is the information the top-line percentage leaves out: it is what says which session is draining the window and how fast.</figcaption>
</figure>

## Turning token logs into a rate

The alternative is arithmetic on data every agent already writes to disk. It
takes three steps.

**Per-session tokens per second.** Every agent turn appends its token usage to
the session transcript. Agent Sessions tails those files and computes a recent
tokens-per-second figure for each session. Two adjustments come straight from
how the logs behave:

- Cache reads are billed at a steep discount, so the parser weights them at 10%
  of their raw count. Without the weighting, a session re-reading a large
  context looks like it is torching the quota while it is mostly paying the
  cache rate.
- Streaming writes duplicate usage rows that share a message id, so the parser
  dedupes on the id. Otherwise every burst would be counted several times.

There is also a bootstrap problem, since a measured rate needs two samples
spaced apart. The first completed turn therefore yields a provisional rate from
that turn's own duration, so a number appears immediately, and a measured burst
rate replaces it once a second sample lands. Provisional rates are additionally
capped at the largest measured rate among peer sessions, because a cache-heavy
first turn can read as tens of thousands of tokens per second and would
otherwise claim nearly the whole attribution split by itself.

**From tokens to quota.** Tokens per second is not quota. The account-level
percentage moving over time is the only ground truth for quota burn, so the app
distributes that account-wide rate across active sessions in proportion to
their token rates. Each session ends up with a percent-per-second figure,
displayed as quota minutes per hour. The unit is less exotic than it sounds:
100% of a 5-hour window is 300 quota minutes, so a session showing 40 m/h (an
illustrative number) spends forty of those minutes for every hour it keeps
running.


**Projecting run-out.** With a rate in hand, run-out is division: remaining
percent over burn rate. When the projected run-out lands before the reset, the
drawer can warn while there is still time to act. One implementation detail
deserves a warning label, because the obvious version is wrong. When no fresh
account projection exists, the tempting fallback is to assume run-out at the
reset time, which makes the implied rate `remaining / time-to-reset`. That
denominator shrinks toward zero as the reset approaches, so the per-session
numbers inflate at exactly the moment a calm reading matters most. Agent
Sessions anchors the fallback to average burn instead: percent used divided by
elapsed window time, with elapsed floored at 10 minutes so a heavy burst right
after a reset cannot inflate the early-window side by the mirror-image
mechanism. The average-burn rate never blows up, stays conservative by
construction, and hands over to measured velocity whenever a fresher projection
arrives.

## Coarse by design on Claude

The two providers do not give out equal data, and the app does not pretend
they do.

Codex writes fine-grained rate-limit samples into its own session logs and
serves account state over local CLI-RPC, updated frequently. Per-session burn
can be read directly, projections form readily, and a "fresh" indicator on
Codex genuinely means fresh. When the question is how fast you are approaching
the Codex usage limit, the transport supports a live answer.

Claude offers no equivalent. The only account signal is the OAuth usage
endpoint, and Agent Sessions reads it through a cache file shared with the
Claude Code statusline (`/tmp/claude/statusline-usage-cache.json`). A running
Claude Code session keeps that file warm, and the app re-serves it rather than
issuing its own request whenever the file is younger than 180 seconds. That is
cooperation rather than laziness: polling the endpoint aggressively earns a 429
with a retry clamp of about five minutes, and independent polling would compete
with the statusline for the same budget. The cost of cooperating is that
Claude's projection extras, the live ETA badge and the sharpening from average
burn to measured velocity, form far less often than they do for Codex. When the
underlying number has not moved, the app says it is waiting for a usable
sample. Inventing a trajectory from a flat number would produce a reading that
is confident, precise-looking, and made up.

The burn measurement survives all of this on purpose. Per-session burn comes
from token attribution in the transcripts, which the app reads directly and
continuously, so the Session Runway bars stay live on Claude regardless of how
stale the account projection is. An earlier version gated the burn display on a
fresh projection, and that gate was removed for Claude precisely because it
made the bars appear late and flicker. What degrades on Claude is projection
polish; the answer about which session is eating the window, and how fast, does
not degrade at all, and that answer is the reason the drawer exists.

## What the drawer shows

A session that is burning but projected to fit inside the window gets a small
smiling face in its run-out column, with a quieter dot available in Preferences
for anyone who wants less personality. A session on track to run past the reset
carries its projected run-out time and rises up the ranking. Freshness is
enforced per row as well: when the latest token sample is older than 30
seconds, the rate falls back to a waiting state rather than showing a stale
figure, so a stopped session clears quickly. By default the drawer appears only
when the runway is actually running low; it can also be pinned always on or
always off.


The practical difference, again with illustrative numbers: instead of
"7% used," the readout becomes "this session spends 40 quota minutes per hour,
it is the main drain on the window, and at this pace it runs out 25 minutes
before the reset." That sentence supports a decision. Pause the expensive
session, or let the small ones ride to the reset.

## Try it

Agent Sessions is a free, local-only macOS app for browsing and searching
Claude Code and Codex sessions; the Quota Meter and Session Runway ship with
it. There is no account and no telemetry, and it reads the same local logs your
agents already write. The code behind everything described above is public:
[download it or read the source on GitHub](https://github.com/jazzyalex/agent-sessions).
