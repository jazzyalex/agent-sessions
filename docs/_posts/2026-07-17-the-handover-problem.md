---
layout: post
title: "The handover problem: agent sessions end, projects don't"
description: "Coding agent sessions are stateless and projects outlive dozens of them. A practical pattern for carrying state across sessions: the dated handover file, and why it beats memory features and transcript mining."
date: 2026-07-17
summary: >-
  A long-running project outlives every agent session that works on it. Each
  new session starts with amnesia and re-derives context you already paid for.
  This post describes the handover file pattern we use in production — a
  dated, append-only log of state, decisions, and next steps — and compares it
  honestly against built-in memory features, transcript mining, and re-reading
  git history.
---

A coding agent session is bounded by its context window; a project is not.
On the repository this blog ships from, the last two months of work spans
well over a hundred agent sessions across two different agents. Every one of
those sessions started from zero. Whatever the previous session knew — which
approach was rejected and why, what was left half-done, which test is flaky
for an unrelated reason — was gone unless someone wrote it down somewhere the
next session would look.

That is the handover problem. It is the agentic version of shift change at a
hospital, and the industry mostly pretends it doesn't exist. New sessions
re-derive context by re-reading the codebase, which costs tokens and time,
and worse, re-derivation recovers facts but not decisions. The code shows
what it is; it does not show the two designs that were tried and abandoned
on Tuesday.

## What actually carries state today

There are four places session-to-session state can live, and they are not
interchangeable.

**Git history** carries what changed and, with disciplined commit messages,
why. It carries nothing about work in progress, rejected alternatives, or
intent. It is the official record, written after the fact, by the winner.

**Transcripts** carry everything, which is their problem. The full record of
a working session on our machines averages hundreds of events per user
message; the signal about "where we left off" is diffused across megabytes.
Transcripts are for audit and search (that is [what Agent Sessions is
for](https://github.com/jazzyalex/agent-sessions)), not for briefing the next
shift.

**Built-in memory features** (CLAUDE.md auto-memory, agent memory stores)
carry durable preferences and hard-won facts well. They are the wrong shape
for project state: memory is organized by topic and persists indefinitely,
while project state is organized by time and is mostly obsolete in a week.
Writing "task 3 is half-done" into long-term memory is how you get haunted
by it in August.

**The handover file** carries exactly the shift-change payload: current
state, open decisions, next steps. It is the only one of the four that is
written *for* the next session, at the moment the context still exists.

## The pattern

What we run in production is one file at the repo root, `RepoHandover.md`,
append-only, newest entry first, each entry dated and written at the end of
a working session. Three sections, no more:

<figure class="post-figure">
<div class="viz-root" style="--viz-ink:#0b0b0b; --viz-ink2:#52514e; --viz-muted:#898781; --viz-grid:#e1e0d9; --viz-accent:#2a78d6; --viz-box:#f0efec;">
<style>
@media (prefers-color-scheme: dark) {
  .viz-root { --viz-ink:#ffffff; --viz-ink2:#c3c2b7; --viz-muted:#898781; --viz-grid:#2c2c2a; --viz-accent:#3987e5; --viz-box:#26262a; }
}
.viz-root svg { max-width: 720px; width: 100%; height: auto; display: block; margin: 0 auto; }
.viz-root text { font-family: system-ui, -apple-system, "Segoe UI", sans-serif; }
</style>
<svg viewBox="0 0 720 300" role="img" aria-label="Diagram: three agent sessions over time, each ending by writing to a handover file which the next session reads at start. Context windows end; the handover file bridges them.">
  <text x="12" y="22" font-size="14" font-weight="600" fill="var(--viz-ink)">Sessions end. The handover file is the bridge.</text>
  <!-- session boxes -->
  <g>
    <rect x="20" y="52" width="180" height="64" rx="8" fill="var(--viz-box)"/>
    <text x="110" y="78" font-size="12.5" font-weight="600" fill="var(--viz-ink)" text-anchor="middle">Session A</text>
    <text x="110" y="98" font-size="11.5" fill="var(--viz-ink2)" text-anchor="middle">context dies at the end</text>

    <rect x="270" y="52" width="180" height="64" rx="8" fill="var(--viz-box)"/>
    <text x="360" y="78" font-size="12.5" font-weight="600" fill="var(--viz-ink)" text-anchor="middle">Session B</text>
    <text x="360" y="98" font-size="11.5" fill="var(--viz-ink2)" text-anchor="middle">different day, zero memory</text>

    <rect x="520" y="52" width="180" height="64" rx="8" fill="var(--viz-box)"/>
    <text x="610" y="78" font-size="12.5" font-weight="600" fill="var(--viz-ink)" text-anchor="middle">Session C</text>
    <text x="610" y="98" font-size="11.5" fill="var(--viz-ink2)" text-anchor="middle">maybe a different agent</text>
  </g>
  <!-- handover file -->
  <rect x="180" y="190" width="360" height="72" rx="8" fill="none" stroke="var(--viz-accent)" stroke-width="2"/>
  <text x="360" y="216" font-size="12.5" font-weight="600" fill="var(--viz-ink)" text-anchor="middle">RepoHandover.md — newest entry first</text>
  <text x="360" y="236" font-size="11.5" fill="var(--viz-ink2)" text-anchor="middle">State · Decisions (with the why) · Next steps</text>
  <text x="360" y="252" font-size="11" fill="var(--viz-muted)" text-anchor="middle">written at session end, read at session start</text>
  <!-- arrows -->
  <g stroke="var(--viz-accent)" stroke-width="1.6" fill="none">
    <path d="M 110 116 C 110 160, 220 175, 250 190"/>
    <path d="M 330 190 C 340 160, 350 140, 356 120"/>
    <path d="M 360 116 0 0 0 0" opacity="0"/>
    <path d="M 400 190 C 420 160, 440 145, 452 120"/>
    <path d="M 470 190 C 520 170, 580 150, 606 120"/>
  </g>
  <g fill="var(--viz-accent)">
    <path d="M 250 190 l -10 -1 l 6 8 z"/>
    <path d="M 356 120 l -6 8 l 9 1 z"/>
    <path d="M 452 120 l -6 8 l 9 1 z"/>
    <path d="M 606 120 l -7 7 l 9 2 z"/>
  </g>
  <g font-size="10.5" fill="var(--viz-muted)">
    <text x="130" y="160">writes</text>
    <text x="300" y="150">reads</text>
    <text x="430" y="150">writes</text>
    <text x="540" y="150">reads</text>
  </g>
</svg>
</div>
<figcaption>Each session writes the briefing the next one reads. The file outlives every context window that contributed to it.</figcaption>
</figure>

The entry format matters less than the discipline around it. Ours:

- **State**: what is done, what is half-done, what is verified vs merely
  written. "Code-complete, QA pending" is a state; "made progress" is not.
- **Decisions**: choices made and the reason, especially rejected paths.
  This is the section git cannot give you. "Hover-resize approach rejected;
  made jumping worse; next attempt must start with runtime tracing" saves
  the next session a day.
- **Next**: the first three things the next session should do, in order.

Then one line in the repo's agent instructions file: *before starting work,
read the newest entry.* Both major agents honor that reliably, and a session
that starts with the briefing skips the archaeology.

Two rules keep it working. Entries are written at session end, when the
context is still hot; a handover reconstructed the next morning is fiction
with good intentions. And the file is a log, not a wiki: nobody edits old
entries, they only supersede them. When an entry stops being true, the new
entry says so.

## Why not just resume the session?

Resume features are real and improving, and they solve a different problem.
Resuming reopens *one* conversation with its old context; it does not brief
a *different* session, a different agent, or a teammate. It also drags the
whole transcript back in, including the parts that were wrong. A handover
entry is small on purpose: it is the distillation the resumed transcript
never got.

The honest cost of the pattern is that it takes two minutes at the end of a
session, which is exactly when nobody wants to spend two minutes. Automate
the nudge if you can (a session-end hook that drafts the entry works well;
the agent writes a decent first draft of its own shift report). The payoff
compounds: on this repo, the handover file plus instructions file is now the
de facto onboarding document, and it cost nothing beyond the discipline.

Session transcripts remain the ground truth underneath all of this. When a
handover entry says "we rejected the geometry redesign," the transcript is
where the details live, searchable months later. That layering — terse
briefing on top, full record below — is the whole system, and each layer is
bad at the other's job.
