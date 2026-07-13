---
layout: post
title: "How coding agents remember: a field study of six session-history formats"
description: "We measured 3,096 real sessions and 3.8 GB of transcripts across Claude Code, Codex, Cursor, Copilot, OpenCode, and Hermes — verbosity, telemetry, sealed reasoning, and search — with a scorecard and recommendations."
date: 2026-07-14
summary: >-
  Six coding agents on one Mac wrote 3,096 session transcripts over eleven
  months. We parsed all of them and measured what each format actually records:
  how many bytes it takes to remember one human sentence, which agents know
  what they cost, why most reasoning is now sealed even on your own disk, and
  which format can actually find anything again. With a feature scorecard and
  concrete recommendations for each vendor.
---

Over the last eleven months, the coding agents on one of our Macs wrote 3,096
session transcripts totaling 3.8 GB — roughly a million logged events across
Claude Code, Codex, Cursor, GitHub Copilot CLI, OpenCode, and Hermes. Every one
of those files is the complete record of a working session: what was asked,
what was tried, what broke, what shipped.

There is a useful way to think about these files. The model has no memory of
its own; when the session ends, everything it will ever be able to recall
about that refactor is what it managed to write down at the time. The session
file is the agent's dream journal, kept while the dream is happening. Six
agents keep six very different journals, and the differences are not
cosmetic. They decide what the agent can resume, what a tool like a history
browser can show you, what you can audit six months later, and what is
silently lost.

A [companion post]({% post_url 2026-07-11-where-agents-store-history %})
covers where these files live on disk. This one is about what is inside them.
We measured it.

## Method

We ran a read-only measurement harness over every session store on one
machine: 184 Claude Code sessions, 2,706 Codex rollouts, 14 Cursor Agent
transcripts, 20 Copilot CLI sessions, 61 OpenCode sessions, and 111 Hermes
sessions, spanning August 2025 to July 2026. The harness parses every event,
classifies it (user message, assistant message, tool activity, metadata), and
records aggregates only: counts, byte sizes, ratios, field coverage, timings.
No transcript content leaves the analysis, and the numbers below are corpus
totals, not excerpts. The script and the raw aggregates are [in the Agent
Sessions repo](https://github.com/jazzyalex/agent-sessions/tree/main/docs/superpowers/specs/data).

Honest caveats, stated up front. This is one machine and one user, so the
usage mix differs per agent: Codex did most of the daily work here, Cursor
saw fourteen sessions. Cross-agent comparisons are indicative, not a
controlled experiment. Where a number depends on usage rather than format, we
say so.

## Finding 1: the journal is almost all margin notes

The first thing the data shows is how expensive remembering is. Divide each
store's total size by the number of user-visible messages in it, and you get
the cost of remembering one human sentence:

<figure class="post-figure">
<div class="viz-root" style="--viz-ink:#0b0b0b; --viz-ink2:#52514e; --viz-muted:#898781; --viz-grid:#e1e0d9; --viz-axis:#c3c2b7; --viz-bar:#2a78d6;">
<style>
@media (prefers-color-scheme: dark) {
  .viz-root { --viz-ink:#ffffff; --viz-ink2:#c3c2b7; --viz-muted:#898781; --viz-grid:#2c2c2a; --viz-axis:#383835; --viz-bar:#3987e5; }
}
.viz-root svg { max-width: 720px; width: 100%; height: auto; display: block; margin: 0 auto; }
.viz-root text { font-family: system-ui, -apple-system, "Segoe UI", sans-serif; }
</style>
<svg viewBox="0 0 720 296" role="img" aria-label="Bar chart: kilobytes stored per user-visible message, by agent. Codex 126, OpenCode 114, Claude Code 113, Hermes 91, Copilot CLI 25, Cursor Agent 1.8.">
  <text x="12" y="20" font-size="14" font-weight="600" fill="var(--viz-ink)">Kilobytes stored per user-visible message</text>
  <text x="12" y="38" font-size="12" fill="var(--viz-ink2)">Store size ÷ user messages, measured per corpus</text>
  <!-- baseline -->
  <line x1="130" y1="52" x2="130" y2="270" stroke="var(--viz-axis)" stroke-width="1"/>
  <!-- bars: x=130, scale 4.3 px/KB, h=22, gap 36 -->
  <g font-size="12.5">
    <text x="122" y="70" text-anchor="end" fill="var(--viz-ink)">Codex</text>
    <rect x="130" y="58" width="542" height="22" rx="4" fill="var(--viz-bar)"/>
    <text x="664" y="74" text-anchor="end" font-size="12" font-weight="600" fill="#ffffff">126 KB</text>

    <text x="122" y="106" text-anchor="end" fill="var(--viz-ink)">OpenCode</text>
    <rect x="130" y="94" width="490" height="22" rx="4" fill="var(--viz-bar)"/>
    <text x="612" y="110" text-anchor="end" font-size="12" font-weight="600" fill="#ffffff">114 KB</text>

    <text x="122" y="142" text-anchor="end" fill="var(--viz-ink)">Claude Code</text>
    <rect x="130" y="130" width="486" height="22" rx="4" fill="var(--viz-bar)"/>
    <text x="608" y="146" text-anchor="end" font-size="12" font-weight="600" fill="#ffffff">113 KB</text>

    <text x="122" y="178" text-anchor="end" fill="var(--viz-ink)">Hermes</text>
    <rect x="130" y="166" width="391" height="22" rx="4" fill="var(--viz-bar)"/>
    <text x="513" y="182" text-anchor="end" font-size="12" font-weight="600" fill="#ffffff">91 KB</text>

    <text x="122" y="214" text-anchor="end" fill="var(--viz-ink)">Copilot CLI</text>
    <rect x="130" y="202" width="108" height="22" rx="4" fill="var(--viz-bar)"/>
    <text x="246" y="218" font-size="12" font-weight="600" fill="var(--viz-ink)">25 KB</text>

    <text x="122" y="250" text-anchor="end" fill="var(--viz-ink)">Cursor Agent</text>
    <rect x="130" y="238" width="8" height="22" rx="2" fill="var(--viz-bar)"/>
    <text x="146" y="254" font-size="12" font-weight="600" fill="var(--viz-ink)">1.8 KB</text>
  </g>
  <text x="130" y="288" font-size="11" fill="var(--viz-muted)">Database stores (OpenCode, Hermes) include their indexes. Cursor's transcript omits tool output entirely.</text>
</svg>
</div>
<figcaption>What it costs each agent to remember that you said one thing. Codex spends 126 KB per user message; Cursor spends 1.8 KB, but only because its transcript leaves the tool activity out.</figcaption>
</figure>

The headline ratio is starker than the bar chart. In the Claude Code corpus,
visible conversation text (what you typed plus what the model said to you) is
3.0% of the bytes. In Codex it is 2.6%. Everything else is tool calls, tool
output, reasoning items, metadata envelopes, and bookkeeping. The journal is
almost entirely margin notes about the dream, not the dream itself.

That is not waste, mostly. Tool output is the evidence of what actually
happened, and it is the part you grep for later. But the volumes are worth
knowing: the largest single Codex session on this machine is a 212 MB JSONL
file, and Claude Code's largest is 19 MB. Any tool that reads these naively
into memory will eventually meet one of those.

Cursor is the interesting outlier. At 1.8 KB per user message, with half its
bytes being visible text, its transcript is lean because it is incomplete: in
our corpus it records zero tool events and zero per-event timestamps. The
transcript reads well and remembers almost nothing about how the work was
done. It is a diary with the verbs removed.

## Finding 2: some agents know what they cost, and some have no idea

The second axis is self-knowledge: what the format records about its own
execution. The spread here is wide.

Copilot CLI is the quantified dreamer. Every assistant message carries the
model name, output token count, and request IDs; every tool execution carries
the model that requested it; and at shutdown it writes a full accounting
event: total conversation tokens, premium request count, API duration, even
the size of its own event file. Hermes keeps a ledger in the same spirit: its
sessions table has thirty-three columns, including input, output, cache-read,
cache-write, and reasoning token counts, plus `estimated_cost_usd` and
`actual_cost_usd`. OpenCode records tokens and a `cost` figure on each
message row. These three can answer "what did this session cost" from local
data alone.

The bigger names are thriftier. Codex writes turn-level `token_count` events
with cumulative usage, which is enough for totals but not for per-message
attribution, and no dollar figure. Claude Code stamps every assistant event
with the model and a usage block, which is genuinely good, and also the
occasion for a correction: our companion post claimed Claude Code writes no
per-event model. Wrong. In this corpus, all 36,376 assistant events carry
`message.model`. We measured our own claim and it failed; the fix is in both
posts.

Cursor's transcript records none of this. The model hint lives in a separate
metadata database, and the events themselves are undated. If you want to know
what a Cursor session cost, the answer is on the vendor's dashboard, not your
disk.

## Finding 3: the dreams they are no longer allowed to reread

Reasoning is where the field is converging, quietly, on the same policy:
sealed.

Codex is explicit about it. In the forty most recent rollouts here, all 7,339
reasoning items are opaque `encrypted_content` blobs. They sit on your disk,
in your file, and neither you nor the agent that wrote them can read them
back.

Claude Code turns out to have gone the same way, with less announcement. Its
thinking blocks have a `thinking` text field and a cryptographic `signature`.
In the thirty most recent sessions on this machine, 2,567 of 2,628 thinking
blocks have a signature and an empty text field. About 2.5% still carry
plaintext. The agent's private reasoning is now certified rather than
recorded: the file can prove the thinking happened, and cannot say what it
was.

The rest of the field is split. Copilot writes both a `reasoningText` and a
`reasoningOpaque` field, hedging per message. OpenCode stores reasoning as
first-class part rows, 743 of 1,207 with readable text, the rest empty
depending on the provider. Hermes keeps a plaintext `reasoning_content`
column.

There are real reasons for sealing: provider policies, distillation
concerns, resumability across stateless APIs. But it changes what your
archive is. A year of session history used to include why the agent did
things; increasingly it only includes what it did. If the why matters to you,
the readable summary the agent chooses to say out loud is now the only record
of it, which is worth knowing when you decide how much to trust that summary.

## Finding 4: remembering is not the same as being able to recall

The last measurement is retrieval. A memory you cannot search is barely a
memory, and this is where the two storage philosophies split cleanly.

The JSONL camp (Claude Code, Codex, Copilot, Cursor) has no index of any
kind. Finding a word in this machine's 3.4 GB of Codex history means reading
3.4 GB: a naive `grep -rl` takes 10.8 seconds, and a full structured parse of
the corpus takes 16.6 seconds. Do that on every keystroke of a search box and
you understand why history browsers build their own indexes.

Hermes answers the same class of question in 0.4 milliseconds, four orders
of magnitude faster, because it ships a trigram full-text index inside its
database. It pays for recall honestly: twelve of its eighteen tables are
search infrastructure, and actual message content is about 11% of the
database's bytes. Hermes spends most of its memory on being able to remember.
OpenCode sits in between: proper relational rows (a query away from anything)
but no full-text index, and reconstructing one message means joining an
average of 3.6 part rows.

Neither philosophy wins outright. JSONL survives crashes by construction (a
truncated last line is the entire failure mode), diffs cleanly, and can be
read by any tool ever written. Databases answer questions. The scorecard
shows how each agent actually trades this off:

<figure class="post-figure">
<div class="viz-root" style="--viz-ink:#0b0b0b; --viz-ink2:#52514e; --viz-muted:#898781; --viz-grid:#e1e0d9;">
<style>
@media (prefers-color-scheme: dark) {
  .viz-root { --viz-ink:#ffffff; --viz-ink2:#c3c2b7; --viz-muted:#898781; --viz-grid:#2c2c2a; }
}
</style>
<svg viewBox="0 0 720 420" role="img" aria-label="Scorecard matrix of nine capabilities across six agents. Full descriptions in the surrounding text.">
  <text x="12" y="20" font-size="14" font-weight="600" fill="var(--viz-ink)">What each session format actually records</text>
  <text x="12" y="38" font-size="12" fill="var(--viz-ink2)">● recorded &nbsp;&nbsp;◐ partial or indirect &nbsp;&nbsp;○ absent — measured on this corpus, July 2026</text>
  <g font-family="system-ui, -apple-system, 'Segoe UI', sans-serif">
    <!-- column headers -->
    <g font-size="11.5" font-weight="600" fill="var(--viz-ink)" text-anchor="middle">
      <text x="278" y="66">Claude</text>
      <text x="358" y="66">Codex</text>
      <text x="438" y="66">Cursor</text>
      <text x="518" y="66">Copilot</text>
      <text x="598" y="66">OpenCode</text>
      <text x="678" y="66">Hermes</text>
    </g>
    <!-- rows: y start 96, step 36 -->
    <g font-size="12.5" fill="var(--viz-ink)">
      <text x="12" y="100">Per-event timestamps</text>
      <text x="12" y="136">Model per message</text>
      <text x="12" y="172">Token counts</text>
      <text x="12" y="208">Cost in dollars</text>
      <text x="12" y="244">Readable reasoning</text>
      <text x="12" y="280">Tool calls + output</text>
      <text x="12" y="316">Thread / tree structure</text>
      <text x="12" y="352">Built-in search index</text>
      <text x="12" y="388">Documented schema</text>
    </g>
    <g font-size="15" fill="var(--viz-ink)" text-anchor="middle">
      <!-- timestamps -->
      <text x="278" y="101">●</text><text x="358" y="101">●</text><text x="438" y="101">○</text><text x="518" y="101">●</text><text x="598" y="101">●</text><text x="678" y="101">●</text>
      <!-- model per message -->
      <text x="278" y="137">●</text><text x="358" y="137">◐</text><text x="438" y="137">◐</text><text x="518" y="137">●</text><text x="598" y="137">●</text><text x="678" y="137">◐</text>
      <!-- tokens -->
      <text x="278" y="173">●</text><text x="358" y="173">●</text><text x="438" y="173">○</text><text x="518" y="173">●</text><text x="598" y="173">●</text><text x="678" y="173">●</text>
      <!-- cost -->
      <text x="278" y="209">○</text><text x="358" y="209">○</text><text x="438" y="209">○</text><text x="518" y="209">◐</text><text x="598" y="209">●</text><text x="678" y="209">●</text>
      <!-- readable reasoning -->
      <text x="278" y="245">○</text><text x="358" y="245">○</text><text x="438" y="245">○</text><text x="518" y="245">◐</text><text x="598" y="245">◐</text><text x="678" y="245">◐</text>
      <!-- tool i/o -->
      <text x="278" y="281">●</text><text x="358" y="281">●</text><text x="438" y="281">○</text><text x="518" y="281">●</text><text x="598" y="281">●</text><text x="678" y="281">●</text>
      <!-- tree -->
      <text x="278" y="317">●</text><text x="358" y="317">○</text><text x="438" y="317">○</text><text x="518" y="317">◐</text><text x="598" y="317">◐</text><text x="678" y="317">◐</text>
      <!-- search index -->
      <text x="278" y="353">○</text><text x="358" y="353">○</text><text x="438" y="353">○</text><text x="518" y="353">○</text><text x="598" y="353">○</text><text x="678" y="353">●</text>
      <!-- docs -->
      <text x="278" y="389">○</text><text x="358" y="389">○</text><text x="438" y="389">○</text><text x="518" y="389">○</text><text x="598" y="389">○</text><text x="678" y="389">○</text>
    </g>
    <!-- hairlines -->
    <g stroke="var(--viz-grid)" stroke-width="1">
      <line x1="12" y1="76" x2="708" y2="76"/>
      <line x1="12" y1="112" x2="708" y2="112"/>
      <line x1="12" y1="148" x2="708" y2="148"/>
      <line x1="12" y1="184" x2="708" y2="184"/>
      <line x1="12" y1="220" x2="708" y2="220"/>
      <line x1="12" y1="256" x2="708" y2="256"/>
      <line x1="12" y1="292" x2="708" y2="292"/>
      <line x1="12" y1="328" x2="708" y2="328"/>
      <line x1="12" y1="364" x2="708" y2="364"/>
      <line x1="12" y1="400" x2="708" y2="400"/>
    </g>
  </g>
</svg>
</div>
<figcaption>Nine things a session format can record, measured across six agents. Claude's timestamps cover conversation events (87.7% of all lines); Cursor's model hint and Hermes's model live outside the per-message record; Copilot counts premium requests but not dollars. Note the bottom row: nobody documents their schema.</figcaption>
</figure>

The bottom row deserves its own sentence. None of the six formats has public
schema documentation. Every parser of these files, including ours, is built
by reverse engineering, and every one of them breaks a little when a vendor
renames a field. For files this valuable, that is a strange industry norm.

## What a session format should be

Having read a million events written six different ways, here is the
standard we would hold any of them to, and how the field measures against it.

**Write like a log, read like a database.** Append-only JSONL for the write
path, because a crash mid-write should cost one line, not a database
recovery. A sidecar index (SQLite is fine) for the read path, rebuilt from
the log whenever it is stale. Today every agent picks exactly one half:
the JSONL camp cannot search and the database camp cannot `tail -f`. Hermes
is closest to the right shape, but the log half of it is inside the database
rather than beside it.

**Attribute every message.** Model, timestamps, token usage, and cost belong
on each message, not in a session header, because sessions switch models
mid-flight and post-hoc accounting depends on it. Claude Code and OpenCode
are closest here. Codex should move usage from turn level to message level.
Cursor should start writing timestamps into its own transcript, which in
2026 is a modest ask.

**Seal reasoning honestly.** If reasoning must be opaque, say so in the
format: a documented field, a stated policy, and a user-visible switch where
policy allows one. Claude Code's silent shift from plaintext thinking to
signature-only is the pattern to avoid, less because of the sealing than
because nothing announced it. Users planning to audit their own history a
year out deserve to know the why is no longer being kept.

**Publish the schema.** One versioned page per vendor, listing the event
types and stability guarantees. Codex already versions its files internally
and tolerates unknown fields, which is most of the work. The ecosystem that
wants to exist around these files — history browsers, usage analytics, team
knowledge tools — is currently built on guesswork.

The files themselves are the good news. Every agent in this study writes its
journal locally, completely, and by default, and none of it leaves your
machine on its own. The formats are six dialects of the same instinct, and
the instinct is right: the work is worth remembering.

[Agent Sessions](https://github.com/jazzyalex/agent-sessions) is a free,
local-only macOS browser for all six of these stores; it reads them read-only
and never writes back. The measurement script and raw aggregates behind
every number here are in the repo, and the companion post on the exact disk
locations is [here]({% post_url 2026-07-11-where-agents-store-history %}).
