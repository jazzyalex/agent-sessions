---
layout: post
title: "Where AI coding agents store your session history: the real paths and formats"
description: "The exact on-disk locations and formats for Claude Code, Codex, Cursor, OpenCode, Copilot, and Hermes session history — real paths, JSONL vs SQLite, and the gotchas."
date: 2026-07-11
summary: >-
  Every coding agent writes a full transcript of each session to a local file,
  but no two agree on where it goes or what format it takes. This is a grounded
  tour of the actual paths and formats — Claude Code's per-project JSONL,
  Codex's date-sharded rollout files under ~/.codex/sessions, OpenCode's SQLite
  database, Cursor's two-store split, and a few others — with the parsing
  gotchas that bite when you try to read them yourself.
---

Every coding agent you run writes a full transcript of the session to a file on
your own disk. The prompts you typed, the tool calls it made, the command
output, the diffs it proposed, the reasoning it showed: all of it lands in a
local file the moment each turn completes. What differs, and differs wildly, is
where that file goes and what shape it takes. Claude Code writes
newline-delimited JSON, one file per session, filed under the project you were
working in. Codex writes a similar format but shards it by date under a
completely different root. OpenCode stopped writing loose files and moved the
whole history into a single SQLite database. Cursor splits one session across
two stores in two different formats. None of them agree, and almost none of it
is documented where you would think to look.

That matters because this data is often the only durable record of how a piece
of work actually happened: the command that failed, the path you settled on, the
reason a function looks the way it does. It is genuinely valuable and genuinely
scattered. Most people assume old agent history is gone, or trapped somewhere
unreachable, when in fact it is sitting in a predictable file a couple of
directories deep. Here is where each major agent actually keeps it, grounded in
how [Agent Sessions](https://github.com/jazzyalex/agent-sessions) parses each
one.

## Claude Code — per-project JSONL

If you have wondered where Claude Code stores history, the answer is a tree of
JSONL files under your home directory:

```
~/.claude/projects/<encoded-cwd>/<session-id>.jsonl
```

The clever, occasionally confusing part is the folder name. Claude Code takes
the working directory you launched from and replaces every `/` with a `-`, so a
session run in `/Users/you/Repository/app` lands in a folder named
`-Users-you-Repository-app`. One directory per project, one `.jsonl` file per
session, named by the session UUID. Agent Sessions also honors the
`CLAUDE_CONFIG_DIR` and `CLAUDE_CONFIG_DIRS` environment variables and Claude
Desktop's local-agent-mode roots, because Claude Code will follow those when
they are set.

The format is JSON Lines: one JSON object per line, one line per event. If you
want to read Claude Code JSONL yourself, two details will trip you up. First,
the user's message text is not at the top level. It is nested inside
`message.content`, while Codex and others keep it flatter. Second, there is no
per-event model field. Claude Code records a `version` (like `2.0.5`), a `cwd`,
a `gitBranch`, and a `sessionId`, but which model answered is simply not written
per turn. Events also thread as a tree through `uuid` and `parentUuid`, and some
lines are metadata (`summary`, `file-history-snapshot`, or anything flagged
`isMeta`) rather than conversation. Parse for `type == "user"` and skip the meta
lines, or your transcript fills with noise.

## Codex — date-sharded rollout files

Codex session files live in a location that is easy to state and easy to get
wrong:

```
~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl
```

The gotcha is the environment variable. If `CODEX_HOME` is set, that entire tree
moves: the real root becomes `$CODEX_HOME/sessions`, and anything hard-coding
`~/.codex/sessions` quietly finds nothing. Inside, Codex shards by date into
`YYYY/MM/DD/` folders and writes one append-only JSONL file per session, named
`rollout-YYYY-MM-DDThh-mm-ss-<uuid>.jsonl`. The timestamp is baked into the
filename, which is why Codex's own resume picker sorts sessions newest-first by
the name rather than by file mtime.

Two more things worth knowing. Codex is deliberately tolerant of schema drift,
so field names vary between client versions and unknown fields should be
preserved rather than dropped. And when you run with the Responses API under
zero-data-retention or stateless mode, reasoning items come back as opaque
`encrypted_content` blobs. They are base64, they are not decryptable locally, and
a viewer should treat them as sensitive and leave them alone. CLI, Desktop, and
VS Code Codex all write into this same rollout corpus, which is convenient: one
location covers three surfaces.

## Cursor — one session, two stores

Cursor is the odd one out because it splits a single session across two files in
two formats. The readable transcript is JSONL:

```
~/.cursor/projects/<project>/agent-transcripts/<id>/<id>.jsonl
```

The per-session metadata lives in a small SQLite database next door:

```
~/.cursor/chats/<md5(project-path)>/<session-id>/store.db
```

That `<md5(project-path)>` is exactly what it looks like: the workspace folder is
the MD5 hash of the project path. To assemble complete Cursor Agent history you
read the JSONL for the actual events and the `store.db` for the session name,
model hint, timestamps, and workspace context. One without the other gives you
half the picture.

There is an honest boundary here, and it is worth stating plainly. This covers
Cursor Agent transcripts, the ones that produce a JSONL file. Cursor's older
IDE-chat history that lives only inside the database is stored as protobuf
message blobs, and those are not decoded into transcript events. If a chat never
produced an agent transcript, there is nothing readable to show.

## OpenCode — a session database, not files

OpenCode is the cleanest example of the industry drift toward databases. Recent
versions (v1.2 and up) keep the OpenCode session database at a single path:

```
~/.local/share/opencode/opencode.db
```

Older installs used per-file JSON under
`~/.local/share/opencode/storage/session`, and Agent Sessions still falls back to
that when no database is present. But the modern layout is one SQLite file. The
detector prefers it whenever `opencode.db` exists and actually contains a
`session` table, then reads session metadata, message rows, and — this is the
part people miss — separate `part` rows. A single message's content is spread
across multiple part rows, so reconstructing a turn means joining messages to
their parts and ordering by time. It is a real database schema, not a log you can
`tail`.

## The others — Copilot and Hermes

Two more worth a mention, because they show the same two patterns.

GitHub Copilot CLI writes JSONL under `~/.copilot/session-state/`, and it
recently changed its layout. Legacy installs wrote a flat
`<session-id>.jsonl`; current versions (v1.0.11+) write
`<session-id>/events.jsonl` inside a per-session directory, with the session name
living in a sibling `workspace.yaml`. Same format, moved one level deeper.

Hermes went the OpenCode route. Current versions store everything in
`~/.hermes/state.db`, a SQLite database, with a legacy
`~/.hermes/sessions/session_*.json` fallback for older installs. Check the
database first; fall back to JSON only when it is absent or empty.

## The whole map, in one table

<figure class="post-figure">
<style>
.storage-table-wrap { overflow-x: auto; -webkit-overflow-scrolling: touch; margin: 0 auto; max-width: 720px; }
.storage-table { border-collapse: collapse; width: 100%; font-size: 14px; line-height: 1.45; }
.storage-table th, .storage-table td { text-align: left; vertical-align: top; padding: 8px 12px; border-bottom: 1px solid #d0d7de; }
.storage-table thead th { border-bottom: 2px solid #d0d7de; font-weight: 600; white-space: nowrap; }
.storage-table code { font-size: 12.5px; white-space: nowrap; }
@media (prefers-color-scheme: dark) {
  .storage-table th, .storage-table td { border-bottom-color: #2c2c2e; }
  .storage-table thead th { border-bottom-color: #3a3a3c; }
}
</style>
<div class="storage-table-wrap">
<table class="storage-table">
<thead>
<tr><th>Agent</th><th>Location</th><th>Format</th><th>Notes</th></tr>
</thead>
<tbody>
<tr>
<td>Claude Code</td>
<td><code>~/.claude/projects/&lt;encoded-cwd&gt;/&lt;id&gt;.jsonl</code></td>
<td>JSONL, one event per line</td>
<td>Folder name is the cwd with <code>/</code> turned into <code>-</code>; user text is nested in <code>message.content</code>; no per-event model.</td>
</tr>
<tr>
<td>Codex</td>
<td><code>~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl</code></td>
<td>JSONL rollout, append-only</td>
<td><code>CODEX_HOME</code> relocates the whole tree; timestamp is in the filename; reasoning may be opaque <code>encrypted_content</code>.</td>
</tr>
<tr>
<td>Cursor Agent</td>
<td><code>~/.cursor/projects/.../agent-transcripts/&lt;id&gt;/&lt;id&gt;.jsonl</code> + <code>~/.cursor/chats/&lt;hash&gt;/&lt;id&gt;/store.db</code></td>
<td>JSONL transcript + SQLite metadata</td>
<td>Two stores per session; workspace hash is MD5 of the project path; DB-only IDE chat blobs are protobuf, not decoded.</td>
</tr>
<tr>
<td>OpenCode</td>
<td><code>~/.local/share/opencode/opencode.db</code></td>
<td>SQLite (session / message / part rows)</td>
<td>Moved from per-file JSON to one DB in v1.2; message content is split across <code>part</code> rows.</td>
</tr>
<tr>
<td>Copilot CLI</td>
<td><code>~/.copilot/session-state/&lt;id&gt;/events.jsonl</code></td>
<td>JSONL events</td>
<td>Layout changed from a flat <code>&lt;id&gt;.jsonl</code> to a per-session dir + <code>workspace.yaml</code> in v1.0.11.</td>
</tr>
<tr>
<td>Hermes</td>
<td><code>~/.hermes/state.db</code></td>
<td>SQLite</td>
<td>Current storage is a database; older installs kept <code>sessions/session_*.json</code>.</td>
</tr>
</tbody>
</table>
</div>
<figcaption>The same information every agent writes, filed six different ways. Two patterns dominate: newline-delimited JSON you can read line by line, and SQLite databases you have to query. Cursor manages to use both at once.</figcaption>
</figure>

## What to take from this

The pattern underneath the mess is a slow migration from flat JSONL to SQLite.
JSONL is trivial to append to and trivial to read one line at a time, which is
why the CLI-first agents started there. Databases give you indexed queries and
atomic writes, which is why OpenCode and Hermes moved. Both are honest choices.
Neither is documented as prominently as it should be, and every one of these
paths has at least one detail that quietly breaks a naive reader:
the encoded folder name, the relocating environment variable, the two-store
split, the message-versus-part rows.

None of this data leaves your machine unless you send it somewhere. It is all
sitting locally, and it is all readable if you know the path and the format.

Agent Sessions reads every one of the locations above into a single searchable
macOS app. It is free, local-only, and has no telemetry; it opens these files
read-only and never writes back into them. If you would rather not memorize six
paths and two schema quirks, [the source is on
GitHub](https://github.com/jazzyalex/agent-sessions), and more posts like this
one live at [/blog/]({{ '/blog/' | relative_url }}).
