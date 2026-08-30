---
layout: post
title: "Recovering an AI coding-agent session you thought you lost"
description: "A practical, honest guide to getting back a Claude Code, Codex, OpenCode, or Cursor session that vanished — archived, moved by path, or deleted."
date: 2026-07-17
summary: >-
  A session that disappears from your agent's resume picker is almost never
  actually gone. It was archived, or it's filed under a project path that no
  longer matches where you're standing. Here is how to tell the two apart, get
  each one back, and what to do in the one case that is genuinely unrecoverable.
seo_title: "Recovering an AI coding-agent session you lost"
---

A session that vanishes from your agent's resume picker is almost never gone.
Three things usually happened instead: you archived it, you moved or renamed the
project folder, or the file actually left the disk. Only the last one is
unrecoverable, and even then the recovery runs through your backups, not the
agent. The first two look identical from inside the tool — an empty picker, a
session that was there yesterday — but the fix is completely different, and
neither one touches the transcript itself. Knowing which case you're in is the
whole job. This is how to check, and how to get each one back.

## 1. It's archived, not deleted

Archive is the most common way a session "disappears," because the agents that
ship an archive action rarely make it obvious that the data survives. Archiving
sets a flag or moves a file. It never deletes the transcript.

**OpenCode.** In the `/sessions` picker, `Ctrl+d` reads like a delete key and
behaves like one — the session drops off the list. It's a soft archive. It sets
a `time_archived` timestamp on that session's row in
`~/.local/share/opencode/opencode.db`, and the picker simply filters archived
rows out. The full transcript is still in the database. Set `time_archived` back
to `NULL` for that row in the `session` table and the session comes back. Credit
where it's due: that recipe is community knowledge, posted by Loocos in
[opencode#23468](https://github.com/anomalyco/opencode/issues/23468), not
something any viewer invented. Don't expect a GUI to spare you the SQL here,
either: a tool reading that same table with the same `time_archived IS NULL`
filter the picker uses will hide exactly what the picker hides. For OpenCode,
the database edit is the reliable fix.

**Codex.** Codex Desktop's Archive action doesn't delete either. It moves the
session's rollout file out of `~/.codex/sessions/` and into a sibling folder,
`~/.codex/archived_sessions/`. Same append-only `.jsonl`, same content, one
directory over. To restore a Codex session, move the `rollout-*.jsonl` file back
under `~/.codex/sessions/YYYY/MM/DD/` (matching the date in its filename), or
just open it where it sits — an archived rollout is a completely normal Codex
log.

**Claude Desktop.** Archiving is a Desktop feature here, not a Claude Code CLI
one, and the flag is stored nowhere near the transcript. Desktop keeps a small
metadata sidecar per conversation under `~/Library/Application
Support/Claude/claude-code-sessions/`, as `local_*.json` files that point back at
the CLI transcript through a `cliSessionId` field. (Cowork sessions use a
parallel tree, `local-agent-mode-sessions/`, with the same sidecar shape.)
Archiving sets `isArchived` to `true` in that sidecar. Your JSONL under
`~/.claude/projects/` is not touched at all. Claude Desktop ships a native
unarchive action — easy to miss in the UI, but reach for it first. Editing by
hand means setting `isArchived` back to `false` in the sidecar; searching the
transcript for the flag will turn up nothing, because it was never in there.

The pattern across all three: archive is a filter, not a shredder. The bytes you
wrote are still on disk. You're changing which of them the picker chooses to
show you.

If you need the full layout of the store you're digging through, there is a guide
per agent: [OpenCode]({{ '/guides/opencode-sqlite-history.html' | relative_url }}),
[Codex]({{ '/guides/codex-local-history.html' | relative_url }}), and
[Claude Code]({{ '/guides/claude-code-jsonl-history.html' | relative_url }}).

## 2. The project folder moved or renamed

This one is sneakier, because nothing was archived and nothing was deleted, yet
`claude --resume` from your project shows an empty list. The cause is how Claude
Code files sessions: one folder per project, and the folder is named after the
working directory you launched from, with every `/` turned into a `-`. A project
at `/Users/you/app` lands in `~/.claude/projects/-Users-you-app/`. The resume
picker keys on your *current* directory. Rename the project to `app-v2` and
launch Claude from it, and the picker looks in `-Users-you-app-v2`, a folder
that doesn't exist yet. Nothing matches, so nothing shows. This is the classic
"find lost Claude Code history" panic, and the history was never lost — it's
sitting in the folder named for the old path.

Two facts make recovery easy once you know the mechanic. First, the old folder
is still there under `~/.claude/projects/`, named for wherever the project used
to live. Second, each event line in the JSONL records its own `cwd`, so the
original path travels with the data even if you rename the folder. To get the
sessions back, you have a few honest options: resume from the old path if it
still exists, or copy (don't move, until you've confirmed it works)
`~/.claude/projects/<old-encoded-cwd>/` into a folder named for the new path so
the picker matches again. A handful of community tools — the "teleport" and
"folder-move" helpers people pass around — automate exactly this folder rename,
which is the whole reason they exist. There's nothing magic inside them; they
reconcile the encoded folder name with where your project now lives.

Cursor falls into the same trap, with one cosmetic difference in the encoding.
Its agent transcripts live under `~/.cursor/projects/`, one folder per project
path with the separators turned into dashes and no leading dash — the project
above becomes `Users-you-app`, where Claude Code would write `-Users-you-app`.
Inside it, `agent-transcripts/<session-id>/<session-id>.jsonl`. Rename the repo
and the old transcripts stay filed under the old name, exactly as with Claude
Code. Cursor's chat databases are a separate surface: per-session SQLite files
under `~/.cursor/chats/`, in directories named by a workspace hash rather than
by path, so renaming the project doesn't disturb those.

Codex behaves a little differently and it's worth being precise about why. Codex
shards sessions by date under `~/.codex/sessions/YYYY/MM/DD/`, not by project
path, so moving your repo never relocates the log file. The original working
directory is recorded inside the rollout's `session_meta` line instead. Moving
the folder doesn't hide a Codex session by path the way it does for Claude Code
or Cursor — you locate it by date or ID, not by browsing from the new directory.

## 3. The file was genuinely deleted

Sometimes the honest answer is that the session is gone. A `rm`, an overzealous
cleanup script, or an emptied Trash took the `.jsonl` file or the SQLite database
off the disk. No session viewer can recover that, and any tool that claims it can
is either reading a backup or misleading you. A read-only viewer opens these
files; it does not resurrect them. That boundary is worth stating plainly,
because it's the one place the reassuring "it's probably just archived" story
stops being true.

What actually recovers a deleted file is a backup that predates the deletion, and
your operating system almost certainly has one running:

- **macOS — Time Machine.** If it's on, it snapshots your home directory,
  including `~/.claude/`, `~/.codex/`, and
  `~/.local/share/opencode/opencode.db`. Enter Time Machine, navigate to the
  exact path, pick a date before the deletion, and restore the file. For the
  SQLite-backed agents (OpenCode, Hermes), you're restoring the whole database
  to that point in time, so you'll get every session that existed then, not just
  the one you lost.
- **Windows — Volume Shadow Copies.** The "Previous Versions" tab on a folder,
  and File History if you've enabled it, expose shadow copies of the session
  directory. Same idea: pick a version from before the delete and restore.

If neither is enabled, there's no clean recovery, and that's the real cost of
running without backups. This is the case to prevent, not the one to fix.

## Where a viewer actually helps

Two of the three failure modes above are findability problems, not data-loss
problems, and that's exactly where a read-only session browser earns its place.
The path case is the one it flattens completely: read every project folder under
`~/.claude/projects/` and `~/.cursor/projects/` at once and it stops mattering
which directory you happen to be standing in, which is the entire mechanism
behind the renamed-repo panic. Archive is a partial win. A browser that walks
`~/.codex/archived_sessions/` and reads Claude Desktop's sidecars will show you
the Codex and Claude sessions their own pickers hide.

Be skeptical of anything broader. Upstream archive flags are easy for a viewer
to inherit and awkward to override, and a tool that reads OpenCode's `session`
table the obvious way inherits `time_archived IS NULL` along with it — so it
hides the same rows the picker does, mine included. "Reads the store" and
"shows you everything in the store" are different claims, and the second one is
worth checking rather than assuming.

What none of them can do is invent bytes that aren't on disk. A truly deleted
session is a backup problem, full stop. Honest tools tell you that instead of
pretending otherwise.

<figure class="post-figure">
<style>
.recovery-table-wrap { overflow-x: auto; -webkit-overflow-scrolling: touch; margin: 0 auto; max-width: 760px; }
.recovery-table { border-collapse: collapse; width: 100%; font-size: 14px; line-height: 1.45; }
.recovery-table th, .recovery-table td { text-align: left; vertical-align: top; padding: 8px 12px; border-bottom: 1px solid #d0d7de; }
.recovery-table thead th { border-bottom: 2px solid #d0d7de; font-weight: 600; }
.recovery-table code { font-size: 12.5px; }
@media (prefers-color-scheme: dark) {
  .recovery-table th, .recovery-table td { border-bottom-color: #2c2c2e; }
  .recovery-table thead th { border-bottom-color: #3a3a3c; }
}
</style>
<div class="recovery-table-wrap">
<table class="recovery-table">
<thead>
<tr><th>How it "disappeared"</th><th>What actually happened</th><th>How to get it back</th></tr>
</thead>
<tbody>
<tr>
<td>OpenCode session gone after <code>Ctrl+d</code> in <code>/sessions</code></td>
<td>Soft archive: a <code>time_archived</code> timestamp is set on the row in <code>~/.local/share/opencode/opencode.db</code>; the transcript is still in the DB.</td>
<td>Set <code>time_archived</code> back to <code>NULL</code> in the <code>session</code> table. Viewers generally inherit the same filter, so this one really is the SQL edit.</td>
</tr>
<tr>
<td>Codex session missing from the list after Archive</td>
<td>The <code>rollout-*.jsonl</code> was moved to <code>~/.codex/archived_sessions/</code>, one folder over from <code>~/.codex/sessions/</code>.</td>
<td>Move the rollout back under <code>~/.codex/sessions/YYYY/MM/DD/</code>, or just open it where it is.</td>
</tr>
<tr>
<td>Claude session hidden from Claude Desktop</td>
<td><code>isArchived=true</code> in a <code>local_*.json</code> sidecar under <code>~/Library/Application&nbsp;Support/Claude/claude-code-sessions/</code>, not in the transcript.</td>
<td>Use Claude Desktop's native unarchive, or set <code>isArchived=false</code> in that sidecar.</td>
</tr>
<tr>
<td><code>claude --resume</code> shows nothing after you renamed the repo</td>
<td>Sessions are filed under the <em>old</em> path, encoded as a folder name (<code>/</code>&nbsp;&rarr;&nbsp;<code>-</code>); the picker keys on your current directory.</td>
<td>Resume from the old path, or copy <code>~/.claude/projects/&lt;old-encoded-cwd&gt;/</code> into a folder named for the new path.</td>
</tr>
<tr>
<td>Cursor transcripts missing after the same rename</td>
<td>Same mechanic, same encoding minus the leading dash: transcripts stay under <code>~/.cursor/projects/&lt;old-encoded-path&gt;/agent-transcripts/</code>.</td>
<td>Copy the old folder to one named for the new path. Chat DBs under <code>~/.cursor/chats/</code> are hash-named and unaffected.</td>
</tr>
<tr>
<td>The file is simply not there anymore</td>
<td>A delete, a cleanup script, or an emptied Trash removed the <code>.jsonl</code> or the database from disk.</td>
<td>Restore from Time Machine (macOS) or Volume Shadow Copies / Previous Versions (Windows). No app can recover what's off disk.</td>
</tr>
</tbody>
</table>
</div>
<figcaption>Six ways a session "disappears," and the honest fix for each. Five of them never left your disk. The last one is a backup problem, and no viewer can pretend otherwise.</figcaption>
</figure>

## The one habit that makes all of this moot

Before you trust any recovery step, decide which case you're in. Empty picker
but the file's timestamp is recent? Archived. Empty picker right after you moved
the project? Path mismatch. File genuinely missing from disk? Backups or
nothing. Guessing wastes the time you'd spend just looking at the path.

Agent Sessions is a free, local-only macOS app with no telemetry that opens all
of these stores read-only in one window. It searches every project folder at
once, so a renamed repo stops hiding your history, and it surfaces the archived
Codex rollouts and archived Claude Desktop sessions that the agents' own pickers
filter out. It does not list archived OpenCode rows — that one is still the SQL
edit above — and it cannot recover a deleted file, because nothing can. The only
write it will ever make is the Claude unarchive, and that ships switched off
until you turn it on.

[Download it](https://jazzyalex.github.io/agent-sessions/?campaign=blog&ref=recovering-a-lost-session),
and if it hands back a session you'd already written off,
[star the repo](https://github.com/jazzyalex/agent-sessions) — that's the whole
ask. More posts like this one live at [/blog/]({{ '/blog/' | relative_url }}).
