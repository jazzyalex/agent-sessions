---
layout: post
title: "Agent-legible repositories: your repo now has two kinds of readers"
description: "Coding agents read your repository cold, dozens of times a week. How to structure instruction files, scripts, and handover state so every session starts competent instead of archaeological."
date: 2026-07-24
summary: >-
  Every agent session reads your repository from scratch, with no memory of
  the last one. That makes the repo itself the interface, and some repos are
  drastically more legible to agents than others. This post lays out the five
  memory surfaces of an agent-legible repo — instruction files, playbooks,
  executable scripts, handover state, and the transcript archive — with the
  failure modes each one prevents.
---

The highest-leverage file in this repository contains no code. It is an
instructions file that every agent session reads before touching anything,
and one line in it — use this script to register new Swift files with the
Xcode project — has prevented more broken builds than any test we have. Not
because agents are careless, but because a macOS project file is exactly the
kind of global, fragile, undocumented state a fresh session cannot infer
from the code around it.

That is the general situation now. A repository has two kinds of readers:
humans, who read it warm, with months of accumulated context, and agents,
who read it cold, from zero, dozens of times a week. Sessions are stateless;
the repo is the only memory they all share. Which means repo structure has
quietly become interface design, and the question "can a competent stranger
be productive here in ninety seconds" is no longer hypothetical. You are
running that experiment several times a day.

## The five memory surfaces

After a year of running multiple agents against the same repos daily, the
structure that works has settled into five layers, distinguished by when
they load and how long they stay true.

<figure class="post-figure">
<div class="viz-root" style="--viz-ink:#0b0b0b; --viz-ink2:#52514e; --viz-muted:#898781; --viz-accent:#2a78d6; --viz-box:#f0efec; --viz-grid:#e1e0d9;">
<style>
@media (prefers-color-scheme: dark) {
  .viz-root { --viz-ink:#ffffff; --viz-ink2:#c3c2b7; --viz-muted:#898781; --viz-accent:#3987e5; --viz-box:#26262a; --viz-grid:#2c2c2a; }
}
.viz-root svg { max-width: 720px; width: 100%; height: auto; display: block; margin: 0 auto; }
.viz-root text { font-family: system-ui, -apple-system, "Segoe UI", sans-serif; }
</style>
<svg viewBox="0 0 720 330" role="img" aria-label="Stack diagram of five repo memory surfaces: instruction files (always loaded), playbooks and skills (loaded on demand), executable scripts (run, not read), handover file (temporal state), transcript archive (ground truth).">
  <text x="12" y="22" font-size="14" font-weight="600" fill="var(--viz-ink)">The five memory surfaces of an agent-legible repo</text>
  <g>
    <rect x="60" y="44" width="480" height="44" rx="7" fill="var(--viz-box)"/>
    <text x="76" y="63" font-size="12.5" font-weight="600" fill="var(--viz-ink)">1 · Instruction files</text>
    <text x="76" y="79" font-size="11.5" fill="var(--viz-ink2)">CLAUDE.md / agents.md — rules, invariants, pointers</text>
    <text x="556" y="70" font-size="11" fill="var(--viz-muted)">every session, automatically</text>

    <rect x="60" y="96" width="480" height="44" rx="7" fill="var(--viz-box)"/>
    <text x="76" y="115" font-size="12.5" font-weight="600" fill="var(--viz-ink)">2 · Playbooks &amp; skills</text>
    <text x="76" y="131" font-size="11.5" fill="var(--viz-ink2)">deploy, release-notes, QA flows — procedures with steps</text>
    <text x="556" y="122" font-size="11" fill="var(--viz-muted)">loaded when relevant</text>

    <rect x="60" y="148" width="480" height="44" rx="7" fill="var(--viz-box)"/>
    <text x="76" y="167" font-size="12.5" font-weight="600" fill="var(--viz-ink)">3 · Executable scripts</text>
    <text x="76" y="183" font-size="11.5" fill="var(--viz-ink2)">the fragile operations, wrapped — run, not re-derived</text>
    <text x="556" y="174" font-size="11" fill="var(--viz-muted)">invoked, never inferred</text>

    <rect x="60" y="200" width="480" height="44" rx="7" fill="var(--viz-box)"/>
    <text x="76" y="219" font-size="12.5" font-weight="600" fill="var(--viz-ink)">4 · Handover file</text>
    <text x="76" y="235" font-size="11.5" fill="var(--viz-ink2)">dated entries: state, decisions, next steps</text>
    <text x="556" y="226" font-size="11" fill="var(--viz-muted)">read at start, written at end</text>

    <rect x="60" y="252" width="480" height="44" rx="7" fill="var(--viz-box)"/>
    <text x="76" y="271" font-size="12.5" font-weight="600" fill="var(--viz-ink)">5 · Transcript archive</text>
    <text x="76" y="287" font-size="11.5" fill="var(--viz-ink2)">every past session, searchable — the ground truth</text>
    <text x="556" y="278" font-size="11" fill="var(--viz-muted)">queried when history matters</text>
  </g>
  <!-- side axis -->
  <g stroke="var(--viz-accent)" stroke-width="1.5">
    <line x1="34" y1="48" x2="34" y2="292"/>
  </g>
  <g fill="var(--viz-accent)"><path d="M 34 292 l -4 -8 l 8 0 z"/></g>
  <text x="24" y="170" font-size="10.5" fill="var(--viz-muted)" transform="rotate(-90 24 170)" text-anchor="middle">cheaper to load → richer detail</text>
</svg>
</div>
<figcaption>Top layers load every session and must stay terse; bottom layers hold the detail and load only when asked. Most repos have layer 1 at best.</figcaption>
</figure>

**Instruction files** are the always-loaded layer, which means every line in
them taxes every session. The discipline is the same as for any hot path:
rules and invariants only, with pointers down the stack for detail. "Read
the newest handover entry before starting" is one line; it makes layer 4
work. The common failure is treating this file as documentation and letting
it grow until the agent's attention budget is spent before the work starts.

**Playbooks and skills** hold multi-step procedures — how a release ships,
how QA runs, what the deploy gate checks. They only load when the task
matches, so they can afford detail the instruction file cannot. The test for
whether something belongs here: it has steps, and doing the steps wrong has
a blast radius.

**Executable scripts** are the layer people underrate. An agent asked to add
a file to an Xcode project will, from first principles, edit the pbxproj —
sometimes correctly. A script removes the "sometimes." Anything global,
fragile, or full of tribal knowledge (project registration, code signing,
notarization, database migrations) should be a script the agent runs rather
than a procedure it re-derives. Scripts are the difference between telling
every new hire how the coffee machine works and just labeling the buttons.

**The handover file** carries time: what is half-done, what was rejected and
why, what comes next. It deserves its own discussion, and has one in
[the handover problem]({% post_url 2026-07-17-the-handover-problem %}).

**The transcript archive** is the layer you already have whether you
maintain it or not: every agent writes complete session logs to your disk
([here, exactly]({% post_url 2026-07-11-where-agents-store-history %})).
Unqueried, it is dead weight. Searchable, it is the answer to "have we hit
this error before" and "what did we decide in May" — questions the other
four layers are too terse to answer. A local browser like
[Agent Sessions](https://github.com/jazzyalex/agent-sessions) makes this
layer usable without any setup.

## The test

The measure of an agent-legible repo is what a cold session does in its
first two minutes. In a repo with these layers: reads the rules, reads the
briefing, and starts the actual task. In a repo without them: greps around,
re-derives the build system, makes a reasonable-but-wrong assumption about
the one fragile thing, and spends your review cycle discovering what the
last session already knew.

None of this is agent-specific, which is the quietly satisfying part. Terse
rules, written procedures, wrapped operations, shift-change notes, and a
searchable record are what good teams do for humans; agents just remove the
option of pretending the onboarding docs are fine when they are not. The
stateless reader was always coming. Now it reads your repo before lunch,
every day, and it grades the structure by how much of your money it burns
on archaeology.
