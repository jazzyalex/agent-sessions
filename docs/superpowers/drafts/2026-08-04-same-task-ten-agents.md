---
layout: post
title: "One prompt, ten agents: session logs from 1.5 KB to 274 KB"
description: "We ran the identical one-line task through ten coding agents and measured what each wrote to disk — plus four months of weekly format-drift data across all of them."
date: 2026-08-04
summary: >-
  The same one-line prompt, run headless through every coding agent we support.
  Pi wrote 1.5 KB. Kimi wrote 101 KB, most of it a snapshot of its own tool
  catalog. Codex answered without running the tool at all, because its log had
  already recorded the answer. What each format writes for the smallest
  possible task, which formats broke in the last four months, and why one of
  them pre-answers your questions.
---

Here is the whole experiment: one prompt, "List the files in the current
directory, then say hello in one sentence," run headless through every coding
agent Agent Sessions supports, plus one guest. Then we measured what each
agent wrote to disk for that single exchange.

Pi wrote 1,463 bytes. Kimi Code wrote 101,351. Same task, same day, a 69×
spread — and almost all of it comes from what each format writes down before
the conversation even starts.

An earlier post measured six of these formats [observationally]({% post_url
2026-07-14-how-coding-agents-remember %}), across 3,096 accumulated real
sessions, and said plainly that a corpus comparison is not a controlled
experiment. This is the controlled experiment. It also extends the roster to
ten formats — Antigravity, OpenClaw, Pi, and Kimi have, as far as we can
find, never been comparatively documented anywhere — and adds a dataset
nobody else seems to keep: four months of weekly schema fingerprints for all
of them.

## Method, and two honest failures

We reused the harness that checks these formats for drift every week (more on
that below). Each agent ran the identical prompt in headless mode with a
sandboxed or real home directory as its tooling requires; Kimi has no harness
driver yet, so we ran its documented `-p` print mode by hand. We then measured
the session artifact each agent produced: total bytes, record count, and
bytes per event type.

Eight of ten produced a measurable log. Hermes's one-shot runtime has
returned "no final response was produced" for every provider since late June,
so it never writes the session, and OpenClaw refused auth with a
`refresh_token_reused` error. Both failures are themselves data about how
much these headless paths get exercised, and we would rather show eight real
measurements than ten massaged ones.

Two behavioral caveats. Working directories necessarily differ per agent, so
the listed output varies by a few hundred bytes. And two agents never ran the
tool: Pi simply answered, and Codex did something better, which gets its own
section.

## What the same task costs, per format

<figure class="post-figure">
<div class="viz-root" style="--viz-ink:#0b0b0b; --viz-ink2:#52514e; --viz-muted:#898781; --viz-grid:#e1e0d9; --viz-axis:#c3c2b7; --viz-bar:#2a78d6; --viz-bar2:#9db9d8;">
<style>
@media (prefers-color-scheme: dark) {
  .viz-root { --viz-ink:#ffffff; --viz-ink2:#c3c2b7; --viz-muted:#898781; --viz-grid:#2c2c2a; --viz-axis:#383835; --viz-bar:#3987e5; --viz-bar2:#3d5a7a; }
}
.viz-root svg { max-width: 720px; width: 100%; height: auto; display: block; margin: 0 auto; }
.viz-root text { font-family: system-ui, -apple-system, "Segoe UI", sans-serif; }
</style>
<svg viewBox="0 0 720 396" role="img" aria-label="Bar chart: bytes written for the identical one-line task, by agent. OpenCode 274 KB as a fresh database file, Kimi 101 KB, Codex 78 KB, Copilot 67 KB, Claude Code 40 KB, Antigravity 6.8 KB, Cursor 1.9 KB, Pi 1.5 KB.">
  <text x="12" y="20" font-size="14" font-weight="600" fill="var(--viz-ink)">Bytes on disk for the identical one-line task</text>
  <text x="12" y="38" font-size="12" fill="var(--viz-ink2)">"List the files in the current directory, then say hello in one sentence." — measured 2026-08-04</text>
  <line x1="140" y1="52" x2="140" y2="356" stroke="var(--viz-axis)" stroke-width="1"/>
  <!-- scale: 1.95 px/KB, x0=140 -->
  <g font-size="12.5">
    <text x="132" y="72" text-anchor="end" fill="var(--viz-ink)">OpenCode</text>
    <rect x="140" y="60" width="535" height="22" rx="4" fill="var(--viz-bar2)"/>
    <rect x="140" y="60" width="10" height="22" rx="3" fill="var(--viz-bar)"/>
    <text x="667" y="76" text-anchor="end" font-size="12" font-weight="600" fill="var(--viz-ink)">274 KB (~5 KB of rows)</text>

    <text x="132" y="108" text-anchor="end" fill="var(--viz-ink)">Kimi</text>
    <rect x="140" y="96" width="198" height="22" rx="4" fill="var(--viz-bar)"/>
    <text x="346" y="112" font-size="12" font-weight="600" fill="var(--viz-ink)">101 KB</text>

    <text x="132" y="144" text-anchor="end" fill="var(--viz-ink)">Codex</text>
    <rect x="140" y="132" width="153" height="22" rx="4" fill="var(--viz-bar)"/>
    <text x="301" y="148" font-size="12" font-weight="600" fill="var(--viz-ink)">78 KB</text>

    <text x="132" y="180" text-anchor="end" fill="var(--viz-ink)">Copilot CLI</text>
    <rect x="140" y="168" width="131" height="22" rx="4" fill="var(--viz-bar)"/>
    <text x="279" y="184" font-size="12" font-weight="600" fill="var(--viz-ink)">67 KB</text>

    <text x="132" y="216" text-anchor="end" fill="var(--viz-ink)">Claude Code</text>
    <rect x="140" y="204" width="79" height="22" rx="4" fill="var(--viz-bar)"/>
    <text x="227" y="220" font-size="12" font-weight="600" fill="var(--viz-ink)">40 KB</text>

    <text x="132" y="252" text-anchor="end" fill="var(--viz-ink)">Antigravity</text>
    <rect x="140" y="240" width="14" height="22" rx="3" fill="var(--viz-bar)"/>
    <text x="162" y="256" font-size="12" font-weight="600" fill="var(--viz-ink)">6.8 KB</text>

    <text x="132" y="288" text-anchor="end" fill="var(--viz-ink)">Cursor Agent</text>
    <rect x="140" y="276" width="5" height="22" rx="2" fill="var(--viz-bar)"/>
    <text x="153" y="292" font-size="12" font-weight="600" fill="var(--viz-ink)">1.9 KB</text>

    <text x="132" y="324" text-anchor="end" fill="var(--viz-ink)">Pi</text>
    <rect x="140" y="312" width="4" height="22" rx="2" fill="var(--viz-bar)"/>
    <text x="152" y="328" font-size="12" font-weight="600" fill="var(--viz-ink)">1.5 KB</text>
  </g>
  <text x="12" y="352" font-size="11" fill="var(--viz-muted)">Hermes and OpenClaw failed to run headless (broken one-shot runtime; auth error). OpenCode's number is a fresh</text>
  <text x="12" y="368" font-size="11" fill="var(--viz-muted)">SQLite file: ~5 KB of session rows, the rest is table and index structure that later sessions amortize.</text>
</svg>
</div>
<figcaption>Eight formats, one identical exchange. The light OpenCode bar is the cost of creating its database; the small dark sliver is the session data actually in it.</figcaption>
</figure>

The per-event breakdown explains the spread better than the totals do. For
each format, the largest single item in the log:

- **Kimi (101 KB):** a 70 KB `llm.tools_snapshot` line — the full schema of
  every tool the agent could have used — plus 25 KB of `config.update`.
  Conversation content is 0.9% of the file. Kimi's wire log is a replayable
  op journal, and it pays for that fidelity up front, on every session.
- **Copilot CLI (67 KB):** one 52 KB `system.message` event. Copilot writes
  its entire system prompt into every session log; 78% of the file is that
  one line.
- **Codex (78 KB):** a three-way split between wire-format message items
  (37%), a `world_state` directory snapshot (25%), and the session header
  (23%).
- **Claude Code (40 KB):** `attachment` records at 68% — context the CLI
  injected around a one-line prompt.
- **Cursor Agent (1.9 KB) and Pi (1.5 KB):** 70–80% of the bytes are the
  actual messages. Cursor is lean mostly because it is minimal: as the July
  post measured, its transcript records no timestamps, no model, and no ids,
  so there is little bookkeeping left to bloat.

The pattern generalizes past this one experiment: a session file's size is
dominated by what the format writes *per session*, not per message. For a
long working session those fixed costs wash out. For the thousands of short
sessions a heavy CLI user accumulates, they are most of the archive.

## The format that answered the prompt

Codex never ran `ls`. Its rollout format writes a `world_state` event at
session start, a context snapshot that includes the working directory
listing, and the model answered the question by reading its own session log.

Sit with that one for a second: the log is usually a record of what the agent
did, and here it is part of how the agent did it. A format that snapshots
environment state makes some tool calls unnecessary. That is a real design
choice with real costs (those snapshots are a fifth of every Codex session)
and a real payoff (resume and replay see the world as it was, and
occasionally the answer is already on disk).

## Ten formats, three families

Reading all ten side by side, they sort into three families plus one outlier.

<figure class="post-figure">
<div class="viz-root" style="--viz-ink:#0b0b0b; --viz-ink2:#52514e; --viz-muted:#898781; --viz-grid:#e1e0d9; --viz-axis:#c3c2b7; --viz-accent:#2a78d6;">
<style>
@media (prefers-color-scheme: dark) {
  .viz-root { --viz-ink:#ffffff; --viz-ink2:#c3c2b7; --viz-muted:#898781; --viz-grid:#2c2c2a; --viz-axis:#383835; --viz-accent:#3987e5; }
}
.viz-root svg { max-width: 720px; width: 100%; height: auto; display: block; margin: 0 auto; }
.viz-root text { font-family: system-ui, -apple-system, "Segoe UI", sans-serif; }
</style>
<svg viewBox="0 0 720 332" role="img" aria-label="Diagram grouping ten session formats into three families: nested-envelope event logs (Codex, Claude Code, Copilot CLI, Antigravity); flat parent-linked JSONL (Cursor Agent, OpenClaw, Pi); database-backed (OpenCode, Hermes, plus Cursor's metadata database); and Kimi as a separate op journal.">
  <text x="12" y="20" font-size="14" font-weight="600" fill="var(--viz-ink)">Ten formats, three families</text>

  <!-- Family 1 -->
  <rect x="12" y="40" width="222" height="176" rx="8" fill="none" stroke="var(--viz-axis)"/>
  <text x="24" y="64" font-size="12.5" font-weight="600" fill="var(--viz-ink)">Nested-envelope event logs</text>
  <text x="24" y="82" font-size="11" fill="var(--viz-muted)">JSONL; typed payload inside a wrapper</text>
  <g font-size="12.5" fill="var(--viz-ink)">
    <text x="24" y="110">Codex</text>
    <text x="24" y="134">Claude Code</text>
    <text x="24" y="158">Copilot CLI</text>
    <text x="24" y="182">Antigravity</text>
  </g>
  <g font-size="10.5" fill="var(--viz-ink2)">
    <text x="120" y="110">logs every turn twice</text>
    <text x="120" y="134">parentUuid DAG</text>
    <text x="120" y="158">event-sourced chain</text>
    <text x="120" y="182">one type per tool</text>
  </g>

  <!-- Family 2 -->
  <rect x="250" y="40" width="222" height="176" rx="8" fill="none" stroke="var(--viz-axis)"/>
  <text x="262" y="64" font-size="12.5" font-weight="600" fill="var(--viz-ink)">Flat parent-linked JSONL</text>
  <text x="262" y="82" font-size="11" fill="var(--viz-muted)">role/type lines; id → parentId</text>
  <g font-size="12.5" fill="var(--viz-ink)">
    <text x="262" y="110">Cursor Agent</text>
    <text x="262" y="134">OpenClaw</text>
    <text x="262" y="158">Pi</text>
  </g>
  <g font-size="10.5" fill="var(--viz-ink2)">
    <text x="358" y="110">no timestamps</text>
    <text x="358" y="134">chat-channel origins</text>
    <text x="358" y="158">per-turn dollar cost</text>
  </g>

  <!-- Family 3 -->
  <rect x="488" y="40" width="222" height="176" rx="8" fill="none" stroke="var(--viz-axis)"/>
  <text x="500" y="64" font-size="12.5" font-weight="600" fill="var(--viz-ink)">Database-backed</text>
  <text x="500" y="82" font-size="11" fill="var(--viz-muted)">SQLite; rows, not lines</text>
  <g font-size="12.5" fill="var(--viz-ink)">
    <text x="500" y="110">OpenCode</text>
    <text x="500" y="134">Hermes</text>
    <text x="500" y="158">Cursor's store.db</text>
  </g>
  <g font-size="10.5" fill="var(--viz-ink2)">
    <text x="580" y="110">row per text chunk</text>
    <text x="580" y="134">trigram search index</text>
    <text x="590" y="171">protobuf + hex JSON</text>
  </g>

  <!-- Kimi -->
  <rect x="250" y="236" width="222" height="72" rx="8" fill="none" stroke="var(--viz-accent)"/>
  <text x="262" y="260" font-size="12.5" font-weight="600" fill="var(--viz-ink)">Kimi — op journal</text>
  <text x="262" y="278" font-size="11" fill="var(--viz-ink2)">wire ops, retries, steering, cancels;</text>
  <text x="262" y="294" font-size="11" fill="var(--viz-ink2)">declares protocol_version (wrongly)</text>
</svg>
</div>
<figcaption>The ten formats by family. The dashed line is Cursor keeping a plain transcript and a binary metadata database at the same time; Kimi sits alone because it logs operations, not messages.</figcaption>
</figure>

**Nested-envelope event logs** — Codex, Claude Code, Copilot, Antigravity.
JSONL where each line is an envelope (`{timestamp, type, payload}` or
similar) and the payload carries its own type system. Codex logs each turn
twice by design: once as a UI-facing event, once as the exact wire-format
item, which is why replay is bit-faithful. Copilot's is a textbook
event-sourced chain, every line linked to its parent id, with router scores
and token accounting as first-class events. Antigravity gives every tool its
own event type (`LIST_DIRECTORY`, `VIEW_FILE`), a closed vocabulary rather
than a generic `tool_call`.

**Flat parent-linked JSONL** — Cursor, OpenClaw, Pi. Role-or-type lines with
`id`/`parentId` pointers. OpenClaw and Pi share a visible lineage (both write
`{type: "session"}` then `{type: "message"}` records); Pi adds per-turn
dollar cost and first-class `compaction` events, and its files can contain
abandoned branches that a reader has to walk the parent chain to skip.

**Databases** — OpenCode and Hermes, plus half of Cursor. OpenCode's store is
a session/message/part row hierarchy where every text chunk is its own
addressable record. Hermes keeps a 33-column session ledger with a trigram
full-text index, the only format here that can search itself. Cursor splits
the difference and keeps a lean JSONL transcript next to a metadata database
of protobuf blobs and hex-encoded JSON, which makes it the only format in
the set that is not plaintext-readable at rest.

And then there is **Kimi**, an operations journal rather than a message
log: `turn.prompt`, `llm.request` (with a visible
`attempt: "2/10"` retry counter), `turn.steer`, `turn.cancel`. Retries,
steering, and permission changes are all in the record. It is the only
format we track that declares a `protocol_version` in the file itself, and,
in a detail we genuinely enjoy, the version it emits (1.4) does not match
the constant in its own published source (1.5).

## Four months of watching them change

Since 2026-03-31 we have fingerprinted the schema of every one of these
formats roughly weekly, because Agent Sessions breaks when they drift. That
monitoring ledger is, as far as we can tell, the only longitudinal record of
how coding-agent formats actually evolve. Four months of it says:

- **Four of ten had a structural break.** Copilot moved its storage layout
  wholesale at v1.0 (flat files to per-session directories). OpenCode
  migrated from a JSON file tree to SQLite. Hermes migrated from JSON
  session files to SQLite. Antigravity made the biggest jump of all, from
  markdown "brain artifacts" to JSONL transcripts.
- **Additive churn is constant and mostly harmless.** Claude Code added
  fields or event types at least fifteen times in the window (attachment
  types, attribution metadata, a nested usage struct) without breaking
  anything; a parser that ignores unknown keys survived all of it.
- **Version markers are rare.** Codex stamps its CLI version in every file
  and Claude writes a per-line `version`; Kimi declares a protocol version,
  incorrectly. The other seven formats carry no version marker at all, so a
  parser learns about changes by breaking.
- **Watching is harder than parsing.** Two confessions from our own ledger:
  weekly single-session sampling undercounted Claude's drift (a full sweep
  found 43 unseen keys), and our Codex baseline fixture silently aged for
  months while the scanner reported it clean. Both instruments are fixed,
  and both failures are now test cases.

## None of this is documented

Every number in this post exists because we reverse-engineered ten formats
and re-verify them weekly. No vendor documents their session format. A
GitHub issue asking Copilot to formalize `events.jsonl` as a stable surface
sits open; a developer who built a five-agent session manager concluded the
same thing we did. These files hold months of your working history, they
are the raw material for resuming, auditing, and searching your own work,
and their schemas are private implementation details that change without
notice.

The good news has not changed since July: every one of these agents writes
its history locally and completely, and none of it leaves your machine on
its own. [Agent Sessions](https://github.com/jazzyalex/agent-sessions) is a
free, local-only macOS browser that reads all of these stores read-only; the
measurement scripts and the drift ledger behind every number here are in the
repo.
