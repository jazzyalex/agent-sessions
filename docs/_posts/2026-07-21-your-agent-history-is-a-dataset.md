---
layout: post
title: "Your agent history is a dataset. Almost nobody queries it."
description: "Eleven months of coding-agent transcripts, measured: what one typed instruction actually triggers, and five questions your own session history can answer about how you work."
date: 2026-07-21
summary: >-
  Every session with a coding agent leaves a complete machine-readable record
  on your disk. Measured over eleven months on one machine: a single typed
  instruction to Codex produces 34 logged events, including 11 tool calls.
  That corpus can answer real questions — what a feature cost, which commands
  keep failing, how your prompting changed — and it goes unqueried on almost
  every developer's machine.
---

For every instruction I typed into Codex over the last eleven months, it
logged an average of 34 events: 2.7 assistant messages, 10.7 tool calls, and
about 19 entries of bookkeeping around them. Claude Code's ratio is different
in shape but similar in scale — 13.5 assistant events and 5.7 tool results
per instruction. I know this because the full record of every session is
sitting on my disk in parseable form, 3.8 GB of it, and I finally parsed it.

<figure class="post-figure">
<div class="viz-root" style="--viz-ink:#0b0b0b; --viz-ink2:#52514e; --viz-muted:#898781; --viz-s1:#2a78d6; --viz-s2:#1baf7a; --viz-s3:#eda100; --viz-s4:#4a3aa7; --viz-surface:#fcfcfb;">
<style>
@media (prefers-color-scheme: dark) {
  .viz-root { --viz-ink:#ffffff; --viz-ink2:#c3c2b7; --viz-muted:#898781; --viz-s1:#3987e5; --viz-s2:#199e70; --viz-s3:#c98500; --viz-s4:#9085e9; --viz-surface:#1a1a19; }
}
.viz-root svg { max-width: 720px; width: 100%; height: auto; display: block; margin: 0 auto; }
.viz-root text { font-family: system-ui, -apple-system, "Segoe UI", sans-serif; }
</style>
<svg viewBox="0 0 720 250" role="img" aria-label="Stacked bar chart: events logged per typed user instruction. Codex: 2.7 assistant, 10.7 tool, 15.0 bookkeeping, 4.2 other, total 33.6. Claude Code: 13.5 assistant, 5.7 tool, 0.9 bookkeeping, 7.2 other, total 27.2.">
  <text x="12" y="20" font-size="14" font-weight="600" fill="var(--viz-ink)">Events logged per typed instruction</text>
  <text x="12" y="38" font-size="12" fill="var(--viz-ink2)">Corpus averages, Aug 2025 – Jul 2026, one machine</text>
  <!-- scale: 16 px per event; x0=110 -->
  <g font-size="12.5">
    <text x="102" y="86" text-anchor="end" fill="var(--viz-ink)">Codex</text>
    <!-- 2.7*16=43, 10.7*16=171, 15*16=240, 4.2*16=67 ; gaps 2px -->
    <rect x="110" y="70" width="43" height="24" rx="3" fill="var(--viz-s1)"/>
    <rect x="155" y="70" width="171" height="24" rx="3" fill="var(--viz-s2)"/>
    <rect x="328" y="70" width="240" height="24" rx="3" fill="var(--viz-s3)"/>
    <rect x="570" y="70" width="67" height="24" rx="3" fill="var(--viz-s4)"/>
    <text x="645" y="87" font-size="12" font-weight="600" fill="var(--viz-ink)">33.6</text>

    <text x="102" y="136" text-anchor="end" fill="var(--viz-ink)">Claude Code</text>
    <!-- 13.5*16=216, 5.7*16=91, 0.9*16=14, 7.2*16=115 -->
    <rect x="110" y="120" width="216" height="24" rx="3" fill="var(--viz-s1)"/>
    <rect x="328" y="120" width="91" height="24" rx="3" fill="var(--viz-s2)"/>
    <rect x="421" y="120" width="14" height="24" rx="3" fill="var(--viz-s3)"/>
    <rect x="437" y="120" width="115" height="24" rx="3" fill="var(--viz-s4)"/>
    <text x="560" y="137" font-size="12" font-weight="600" fill="var(--viz-ink)">27.2</text>
  </g>
  <!-- legend -->
  <g font-size="11.5" fill="var(--viz-ink2)">
    <rect x="110" y="176" width="10" height="10" rx="2" fill="var(--viz-s1)"/><text x="126" y="185">assistant messages</text>
    <rect x="260" y="176" width="10" height="10" rx="2" fill="var(--viz-s2)"/><text x="276" y="185">tool calls + results</text>
    <rect x="410" y="176" width="10" height="10" rx="2" fill="var(--viz-s3)"/><text x="426" y="185">bookkeeping / metadata</text>
    <rect x="590" y="176" width="10" height="10" rx="2" fill="var(--viz-s4)"/><text x="606" y="185">other</text>
  </g>
  <text x="110" y="212" font-size="11" fill="var(--viz-muted)">"Other" is mostly reasoning items. Codex logs turn context and token counts as separate</text>
  <text x="110" y="228" font-size="11" fill="var(--viz-muted)">events, hence the bookkeeping share.</text>
</svg>
</div>
<figcaption>One typed sentence, thirty-odd logged events. The tool-call block in the middle is where the actual work happened, and it's all on your disk.</figcaption>
</figure>

The point is not the volume. The point is that this is a *dataset* about how
you build software, generated as a free byproduct, complete with timestamps,
tool inputs and outputs, and (in the better formats) per-message model and
token accounting. Developers who would never dream of running a service
without metrics are sitting on months of their own engineering telemetry and
have never run a single query against it.

## Five questions your history can already answer

**What did that feature actually cost?** Sessions in the newer formats carry
token counts and sometimes dollar figures per message. Group by day or by
repo and you have cost-per-feature numbers that no dashboard gives you,
because the vendor dashboard doesn't know your project boundaries.

**Which commands keep failing?** Every failed build, every flaky test run,
every permission error is in the tool-output events, with timestamps. The
third time a session trips over the same broken script is visible in the
data before it is visible in your patience. This one has direct payoff: the
recurring failure is usually a one-line fix in the repo's agent
instructions.

**What did we decide, and when?** Search is the killer feature of an archive.
"The session where we rejected the geometry redesign" is findable by
keyword in seconds with an indexed browser, and the full context — what was
tried, what the output showed, why it died — is all there. Git remembers the
outcome; the transcript remembers the argument.

**How has your prompting changed?** Instructions from month one read
differently than month eleven: shorter, more specific, front-loaded with
constraints. Your own history is the before/after corpus, and skimming it is
a faster prompting course than most prompting courses.

**Where does the time go?** Timestamps on every event mean a session has a
measurable shape: how long between your instruction and the first tool call,
how long the agent spent in test loops, how much wall-clock a "quick fix"
session really took. Aggregate a month of that and you know which kinds of
tasks to delegate differently, or not at all.

## Why nobody does this

Three honest reasons. The formats are undocumented, so writing a parser
means reverse engineering six dialects of JSONL and SQLite (we covered the
details in [the field study]({% post_url 2026-07-14-how-coding-agents-remember %})).
The volumes are awkward: 3.8 GB is too big to grep casually and too small to
justify a data pipeline. And the tooling is young: the vendors treat these
files as crash-recovery state, not as a product surface, so nothing ships
with a search box over your own history.

The parsing problem, at least, is solved for the reading half.
[Agent Sessions](https://github.com/jazzyalex/agent-sessions) indexes all
six formats into one searchable, local-only browser — that's the "what did
we decide" and "which command failed" questions handled without writing a
line of code. The aggregate questions still need a script, and the one this
post's numbers came from is in the repo as a starting point.

A year of your engineering decisions is on your disk, already written down,
already machine-readable. That is more than most teams can say about their
human decisions. It seems worth a query or two.
