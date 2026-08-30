---
layout: post
title: "One schema, fifteen transcript formats: what the agents disagree about"
description: "Fifteen coding agents write session history in three container types with no shared vocabulary. The normalization that gets them into one schema."
date: 2026-08-29
summary: >-
  Every coding agent writes its session history locally, and no two of them
  agree on what a message is. Getting fifteen of them into one searchable
  schema takes six event kinds, an alias table with eight spellings of "the
  model called a tool," and a standing willingness to be wrong about a format
  until you read its encoder.
seo_title: "One schema for 15 agent transcript formats"
---

Fifteen coding agents write session history to local disk. No two of them agree
on what a message is. Four of them do not agree that a session should be a file
at all.

That is the actual engineering problem behind a cross-agent session browser, and
it is more interesting than it sounds, because the disagreements are not
arbitrary. Each format is a reasonable answer to the question its authors were
asking. They were just asking different questions. What follows is the
normalization that gets all of them into one schema, the places where it stays
deliberately lossy, and the failure mode that costs the most time.

## The containers disagree first

Before any field-level parsing, the stores split three ways.

**Append-only JSONL, one file per session.** Codex, Claude Code, Cursor's agent
transcripts, and most of the newer CLIs. One JSON object per line, written as
the session happens, never rewritten. This is the format that has clearly won on
merit: it survives a crash mid-write with the loss of one line, it tails
cleanly, and you can answer most questions with `grep` before you write any code
at all.

**SQLite.** Four sources: OpenCode from v1.2 on (`opencode.db`), Hermes
(`state.db`), Devin, and Cursor's chat databases, which sit alongside its JSONL
transcripts rather than replacing them. A database buys real queries and
transactional writes. It costs you `grep`, and it introduces a reader problem
that has nothing to do with schemas, which I will come back to.

**Per-session JSON.** OpenCode before v1.2 wrote `storage/session/<projectID>/
ses_<id>.json` with messages in sibling directories. Both backends still exist
in the wild, so the adapter detects which one is on disk rather than assuming a
version.

A parser that assumes any one of these three shapes is the whole world will be
rewritten the first time it meets the other two.

<figure class="post-figure">
<div class="viz-root" style="--viz-ink:#0b0b0b; --viz-ink2:#52514e; --viz-muted:#898781; --viz-grid:#e1e0d9; --viz-accent:#2a78d6; --viz-box:#f0efec;">
<style>
@media (prefers-color-scheme: dark) {
  .viz-root { --viz-ink:#ffffff; --viz-ink2:#c3c2b7; --viz-muted:#898781; --viz-grid:#2c2c2a; --viz-accent:#3987e5; --viz-box:#26262a; }
}
.viz-root svg { max-width: 720px; width: 100%; height: auto; display: block; margin: 0 auto; }
.viz-root text { font-family: system-ui, -apple-system, "Segoe UI", sans-serif; }
</style>
<svg viewBox="0 0 720 330" role="img" aria-label="Diagram: three container families — append-only JSONL, SQLite databases, and per-session JSON — all pass through one normalizer that emits six event kinds: user, assistant, tool_call, tool_result, error, meta.">
  <text x="12" y="20" font-size="14" font-weight="600" fill="var(--viz-ink)">Three container families, one normalizer, six kinds.</text>

  <g>
    <rect x="14" y="44" width="184" height="70" rx="8" fill="var(--viz-box)"/>
    <text x="106" y="68" font-size="12.5" font-weight="600" fill="var(--viz-ink)" text-anchor="middle">Append-only JSONL</text>
    <text x="106" y="86" font-size="11" fill="var(--viz-ink2)" text-anchor="middle">Codex · Claude Code · Cursor</text>
    <text x="106" y="102" font-size="11" fill="var(--viz-ink2)" text-anchor="middle">one object per line</text>

    <rect x="14" y="130" width="184" height="70" rx="8" fill="var(--viz-box)"/>
    <text x="106" y="154" font-size="12.5" font-weight="600" fill="var(--viz-ink)" text-anchor="middle">SQLite</text>
    <text x="106" y="172" font-size="11" fill="var(--viz-ink2)" text-anchor="middle">OpenCode ≥1.2 · Hermes</text>
    <text x="106" y="188" font-size="11" fill="var(--viz-ink2)" text-anchor="middle">Devin · Cursor chat DBs</text>

    <rect x="14" y="216" width="184" height="70" rx="8" fill="var(--viz-box)"/>
    <text x="106" y="240" font-size="12.5" font-weight="600" fill="var(--viz-ink)" text-anchor="middle">Per-session JSON</text>
    <text x="106" y="258" font-size="11" fill="var(--viz-ink2)" text-anchor="middle">OpenCode &lt; 1.2</text>
    <text x="106" y="274" font-size="11" fill="var(--viz-ink2)" text-anchor="middle">messages in sibling dirs</text>
  </g>

  <g stroke="var(--viz-accent)" stroke-width="1.6" fill="none">
    <path d="M 198 79 C 240 79, 250 140, 288 158"/>
    <path d="M 198 165 L 288 165"/>
    <path d="M 198 251 C 240 251, 250 190, 288 172"/>
  </g>
  <g fill="var(--viz-accent)">
    <path d="M 288 158 l -9 -3 l 3 9 z"/>
    <path d="M 288 165 l -8 -4 l 0 9 z"/>
    <path d="M 288 172 l -3 -9 l 9 3 z"/>
  </g>

  <rect x="292" y="120" width="140" height="90" rx="8" fill="none" stroke="var(--viz-accent)" stroke-width="2"/>
  <text x="362" y="150" font-size="12.5" font-weight="600" fill="var(--viz-ink)" text-anchor="middle">normalizer</text>
  <text x="362" y="170" font-size="11" fill="var(--viz-ink2)" text-anchor="middle">alias table +</text>
  <text x="362" y="186" font-size="11" fill="var(--viz-ink2)" text-anchor="middle">role fallback</text>

  <g stroke="var(--viz-accent)" stroke-width="1.6" fill="none">
    <path d="M 432 165 L 512 165"/>
  </g>
  <path d="M 512 165 l -8 -4 l 0 9 z" fill="var(--viz-accent)"/>

  <g>
    <rect x="516" y="44" width="190" height="242" rx="8" fill="var(--viz-box)"/>
    <text x="611" y="70" font-size="12.5" font-weight="600" fill="var(--viz-ink)" text-anchor="middle">SessionEventKind</text>
    <g font-size="12" fill="var(--viz-ink2)" font-family="ui-monospace, SFMono-Regular, Menlo, monospace">
      <text x="548" y="100">user</text>
      <text x="548" y="130">assistant</text>
      <text x="548" y="160">tool_call</text>
      <text x="548" y="190">tool_result</text>
      <text x="548" y="220">error</text>
      <text x="548" y="250">meta</text>
    </g>
    <text x="611" y="274" font-size="10.5" fill="var(--viz-muted)" text-anchor="middle">everything unrecognized lands in meta</text>
  </g>
</svg>
</div>
<figcaption>The whole pipeline. The interesting work is the small box in the middle, and the honest part is the last line: anything the alias table does not recognize becomes <code>meta</code> rather than being dropped.</figcaption>
</figure>

## Then the vocabulary disagrees

Once you are past the container, every format still has its own word for the
same event. The normalizer that resolves this is not clever, and it should not
be. It is a lookup table, and its contents are the most honest description of
the problem I can give you:

| Concept | Spellings actually seen on disk |
|---|---|
| the model called a tool | `tool_call`, `tool-call`, `toolcall`, `tool_use`, `tool-use`, `function_call`, `web_search_call`, `custom_tool_call` |
| the tool answered | `tool_result`, `tool-result`, `toolresult`, `function_result`, `function_call_output`, `web_search_call_output`, `custom_tool_call_output` |

Eight ways to say a tool was called. Seven to say it answered. Nobody designed
this; it accumulated, the way vocabulary does when fifteen teams solve the same
problem at the same time without talking to each other.

The type field is checked first, and when a format does not carry one, the
parser falls back to `role` — `user`, `assistant`, `tool`, `system`. When
neither resolves, the event becomes `meta` and keeps its raw JSON. That last
rule is the one that matters. An unknown event is never discarded, because the
alternative is a transcript with a silent hole in it, and a silent hole is worse
than an unstyled line: the reader cannot tell that anything is missing.

Everything collapses into six kinds: `user`, `assistant`, `tool_call`,
`tool_result`, `error`, `meta`. Six is not a design target, it is what survived.
Every attempt to add a seventh has turned out to be a rendering preference
rather than a real distinction.

## And they disagree about where a session lives

The third disagreement is about identity and place, and it is the one users
actually feel, because it decides whether the agent can find its own history
after you rename a folder.

Claude Code files sessions by project path, encoding the working directory into
a folder name with every `/` replaced by `-`, so `/Users/you/app` becomes
`~/.claude/projects/-Users-you-app/`. Cursor does the same thing with the same
substitution and no leading dash: `~/.cursor/projects/Users-you-app/`. Two
independent implementations of one idea, differing by a single character, which
is exactly the kind of detail that makes "just handle the general case"
expensive.

Codex ignores paths for filing entirely and shards by date under
`~/.codex/sessions/YYYY/MM/DD/`, recording the working directory inside the
rollout's `session_meta` line instead. Cursor's chat databases go a third way
and are named by a workspace hash. All three are defensible. Only one of them
survives a `mv`, which is why renaming a repo makes Claude Code and Cursor
history vanish from the picker while Codex history does not — a mechanic worth
[its own post]({% post_url 2026-07-17-recovering-a-lost-session %}).

## What the unified schema gives up

A shared schema is a lossy projection, and pretending otherwise is how you ship
a viewer that quietly lies. Ours keeps an `id`, a source, a start and end time,
a model, a path, an event count, and the events. Each event keeps a timestamp, a
kind, a role, text, tool name, tool input and output, delta-grouping fields, and
`rawJSON`.

That last field is the pressure valve. Any provider-specific richness the six
kinds cannot express survives verbatim, so the projection is recoverable rather
than destructive. Provider-specific concepts that earn a real column get one —
subagent parentage, for instance, because a Claude Workflow subagent and an
OpenCode child session are genuinely the same idea with different id shapes. But
the default answer to "should the shared model learn this provider's concept" is
no, and it stays no until a second provider independently needs it. One
provider's vocabulary in a shared schema is how a shared schema stops being
shared.

## The failure mode that costs the most

Here is the part I would tell anyone attempting this.

The expensive mistake is not a hard parse error. Those announce themselves. The
expensive mistake is a format that parses cleanly and is *incomplete*, because
nothing anywhere reports a problem. When the `fx` source was contributed, the
parser handled two of the four turn kinds in that format's history array. The
missing two were not exotic: an interrupted turn dropped its partial reply and
its tool steps, and a compacted-summary turn rendered as an empty block, so an
auto-compacted session showed an unexplained gap in the middle. Build green,
tests green, fixtures green — because the fixtures only contained the two kinds
the parser already handled.

What surfaced it was not review of the pull request. It was shallow-cloning the
upstream agent and reading its encoder, at which point the four kinds are
enumerated in the source and the gap is obvious. Every other claim in that
contribution held up under the same check. The lesson generalizes past this
project: for a format question, the format's own encoder is the primary source,
and a description of it — a doc, a PR body, a previous session's notes — is
hearsay.

The SQLite equivalent of this trap is not even a schema problem. A database in
WAL mode, opened read-only, silently returns only what has been checkpointed
into the main file; rows sitting in the `-wal` sidecar are invisible. No error,
no warning, just a query that reports zero rows while the writer is working
perfectly. Both failures share a shape: the tool says everything is fine and the
data is wrong, which is precisely the case a percentage-style status indicator
cannot help you with.

## Is it worth it

Fifteen sources is the count in the registry today, up from the two the app
shipped with. Each new one costs roughly a thousand lines of genuinely
source-specific work — parser, discovery, indexer, settings, resume — on top of
a fixed list of registry obligations that a test enforces rather than a
convention.

We will claim support for fourteen of them. Droid is in the registry and stays
out of the marketing, because nobody has volunteered to keep it verified against
upstream changes, and an unverified source is a claim with an expiry date on it.
That gap between "the code handles it" and "we will tell you it works" is not a
rounding error in the count. It is the whole difference between a parser and a
product.

The reason to absorb this cost is that the alternative is worse. Your agent
history is the only complete record of how a decision got made, and it is
currently scattered across three container types, fifteen dialects, and four
naming schemes for the same directory. Normalizing it is unglamorous, and it is
the only thing that turns fifteen private logs into something you can actually
search.

Agent Sessions is a free, local-only macOS app with no telemetry that does the
normalization described above and opens every store read-only.
[Download it](https://jazzyalex.github.io/agent-sessions/?campaign=blog&ref=parsing-fifteen-transcript-formats),
or read the parser and judge the schema yourself — [it's all on
GitHub](https://github.com/jazzyalex/agent-sessions). If a format here is wrong,
that is a bug worth filing. More posts like this one live at
[/blog/]({{ '/blog/' | relative_url }}).
