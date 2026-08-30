---
layout: post
title: "A 4 KB database, a megabyte of rows: which SQLite readers go blind to the WAL"
description: "A SQLite query says no such table while the writer holds a megabyte of committed rows. Measured: which WAL readers go blind, and why read-only isn't one."
date: 2026-08-29
summary: >-
  A SQLite database in WAL mode can hold a megabyte of committed rows while the
  main .db file is a 4,096-byte header page, and the readers that miss that
  data are not the ones folklore blames. We measured every reader configuration
  we could think of against a live writer: what decides the answer is whether
  the -wal file is there, not whether the connection is read-only, and the two
  readers that answer confidently with the wrong data are immutable=1 and a
  read-write connection to a .db copied without its log. Our own notes carried
  the wrong culprit for over a month, and the first correction was wrong too.
seo_title: "SQLite WAL missing rows: which readers go blind"
---

With checkpointing switched off, a SQLite database we had just filled with
5,000 committed rows measured 4,096 bytes on disk: one page, holding the file
header and nothing else. The real data, 1.1 MB of it, sat in the `-wal` file
beside it, including the `CREATE TABLE` statement. A reader that consults only
the main file therefore does not report zero rows out of that database; it
reports `no such table`, which is a strange thing to be told about a table you
just watched being created.

Which readers go blind that way is the useful question, and the answer we would
have given a week ago is wrong. We know exactly how wrong, because we wrote it
into our own engineering notes, believed it for over a month, and published it
on this blog. That post has been retracted. This one is the correction.

## Three files, one database

SQLite's write-ahead-log mode splits a database across three files. The main
`.db` file holds pages as of the last checkpoint. Committed transactions are
appended to `<name>-wal`, the write-ahead log, and folded back into the main
file only when a checkpoint runs. The third file, `<name>-shm`, holds the
wal-index: a shared map telling a reader which pages have newer versions
sitting in the log. In exchange for the extra files, readers do not block the
writer and the writer does not block readers, which is the point of the mode.

The arrangement has one consequence that surprises people the first time. A
committed row is durable, real, and possibly nowhere near the main database
file. We ran a writer with `PRAGMA wal_autocheckpoint=0` — checkpointing off,
which is just an exaggerated version of a busy writer that has not checkpointed
recently — and the entire 5,000-row table lived in the log. The `.db` held the
header page; every row and the schema itself sat in the `-wal`.

<figure class="post-figure">
<div class="viz-root" style="--viz-ink:#0b0b0b; --viz-ink2:#52514e; --viz-muted:#898781; --viz-grid:#e1e0d9; --viz-accent:#2a78d6; --viz-box:#f0efec;">
<style>
@media (prefers-color-scheme: dark) {
  .viz-root { --viz-ink:#ffffff; --viz-ink2:#c3c2b7; --viz-muted:#898781; --viz-grid:#2c2c2a; --viz-accent:#3987e5; --viz-box:#26262a; }
}
.viz-root svg { max-width: 720px; width: 100%; height: auto; display: block; margin: 0 auto; }
.viz-root text { font-family: system-ui, -apple-system, "Segoe UI", sans-serif; }
</style>
<svg viewBox="0 0 720 330" role="img" aria-label="Diagram: a WAL-mode SQLite database split across three files. The main live.db is 4,096 bytes and holds only the header page; live.db-wal is 1.1 MB and holds every committed row plus the schema; live.db-shm holds the wal-index. An upper reader opened on the plain path or read-only consults the wal-index, merges the main file with the log, and sees all 5,000 rows. A lower reader opened with immutable=1, or on a .db copied without its -wal, never reaches the log: it answers from the header page, or fails outright with error 14.">
  <text x="12" y="22" font-size="14" font-weight="600" fill="var(--viz-ink)">Where the rows actually are, and who can see them</text>
  <!-- file boxes -->
  <g>
    <rect x="20" y="48" width="220" height="58" rx="8" fill="var(--viz-box)"/>
    <text x="130" y="72" font-size="12.5" font-weight="600" fill="var(--viz-ink)" text-anchor="middle">live.db — 4,096 bytes</text>
    <text x="130" y="92" font-size="11.5" fill="var(--viz-ink2)" text-anchor="middle">header page only</text>

    <rect x="20" y="122" width="220" height="66" rx="8" fill="none" stroke="var(--viz-accent)" stroke-width="2"/>
    <text x="130" y="148" font-size="12.5" font-weight="600" fill="var(--viz-ink)" text-anchor="middle">live.db-wal — 1.1 MB</text>
    <text x="130" y="168" font-size="11.5" fill="var(--viz-ink2)" text-anchor="middle">all 5,000 rows + the schema</text>

    <rect x="20" y="204" width="220" height="58" rx="8" fill="var(--viz-box)"/>
    <text x="130" y="228" font-size="12.5" font-weight="600" fill="var(--viz-ink)" text-anchor="middle">live.db-shm</text>
    <text x="130" y="248" font-size="11.5" fill="var(--viz-ink2)" text-anchor="middle">wal-index: which pages are in the log</text>
  </g>
  <!-- reader boxes -->
  <g>
    <rect x="460" y="56" width="240" height="80" rx="8" fill="none" stroke="var(--viz-accent)" stroke-width="2"/>
    <text x="580" y="80" font-size="12.5" font-weight="600" fill="var(--viz-ink)" text-anchor="middle">plain path · mode=ro · -readonly</text>
    <text x="580" y="100" font-size="11.5" fill="var(--viz-ink2)" text-anchor="middle">consults the wal-index, merges both</text>
    <text x="580" y="122" font-size="12" font-weight="600" fill="var(--viz-accent)" text-anchor="middle">sees all 5,000 rows</text>

    <rect x="460" y="196" width="240" height="80" rx="8" fill="none" stroke="var(--viz-muted)" stroke-width="2" stroke-dasharray="5 4"/>
    <text x="580" y="220" font-size="12.5" font-weight="600" fill="var(--viz-ink)" text-anchor="middle">immutable=1 · a .db copied without its -wal</text>
    <text x="580" y="240" font-size="11.5" fill="var(--viz-ink2)" text-anchor="middle">never reaches the log</text>
    <text x="580" y="262" font-size="12" font-weight="600" fill="var(--viz-muted)" text-anchor="middle">"no such table", or error 14</text>
  </g>
  <!-- arrows: upper reader to all three files -->
  <g stroke="var(--viz-accent)" stroke-width="1.6" fill="none">
    <path d="M 460 78 C 380 70, 320 70, 244 76"/>
    <path d="M 460 96 C 380 110, 320 130, 244 148"/>
    <path d="M 460 114 C 390 150, 330 190, 244 222"/>
  </g>
  <!-- arrow: lower reader to main db only -->
  <g stroke="var(--viz-muted)" stroke-width="1.6" fill="none" stroke-dasharray="5 4">
    <path d="M 460 232 C 350 220, 300 150, 244 96"/>
  </g>
  <text x="352" y="316" font-size="11" fill="var(--viz-muted)" text-anchor="middle">Measured 2026-08-29: SQLite 3.43.2 (macOS CLI) and 3.53.4 (Python), identical results.</text>
</svg>
</div>
<figcaption>The database during the measurement. The main file is a 4 KB header; the megabyte is in the log. The upper reader goes through the wal-index and merges the two; the lower one never reaches the log and answers from the header page alone.</figcaption>
</figure>

## The folk claim, measured

The folk claim goes like this: open a WAL database read-only and you can only
see what has been checkpointed, because rows still in the `-wal` are invisible
to a read-only connection. A version of that sentence sat in our own notes,
written in July after a verification query against our app's index database
came back empty while the app was mid-write. The explanation fit the symptom,
sounded like a known WAL subtlety, and survived unchallenged for over a month.

It fails a thirty-second test. Below is what every reader configuration
actually returned, opened fresh against a live writer holding 5,000 committed,
deliberately uncheckpointed rows. Fresh connections matter: none of these
readers can be holding a stale snapshot, so whatever each one reports is a
property of how it opened the file. The macOS system CLI (SQLite 3.43.2) and
the SQLite 3.53.4 inside Python's `sqlite3` module agree on every row of it.

| Reader | Result |
|---|---|
| plain path, `-wal` present | 5,000 — correct |
| `file:…?mode=ro`, `-wal` present | 5,000 — correct |
| `sqlite3 -readonly`, `-wal` present | 5,000 — correct |
| read-only, `-shm` missing but `-wal` present | 5,000 — correct; the reader builds the index itself |
| read-only, `-shm` present but `-wal` missing | hard error: `unable to open database file` (14) |
| read-only on a copy of the `.db` alone | hard error 14 |
| read-write on a copy of the `.db` alone | wrong — answers from the header page |
| `file:…?immutable=1`, even with the `-wal` there | wrong — the WAL is ignored |

Read-only is not the problem. The determining factor is much simpler and it is
easy to get backwards: **the `-wal` file's presence is necessary and
sufficient.** The `-shm` is neither. Given the log, a read-only connection
builds the wal-index it needs — writing a `-shm` if the directory allows, and
otherwise keeping the index in its own memory. Take the log away and no
permission or flag saves you.

That reframes which failures are dangerous. A read-only reader that cannot
reach the log fails *loudly*, with error 14 at the first query rather than at
`open`, because SQLite opens lazily. Only two configurations answer confidently
with the wrong data: `immutable=1`, which promises the file cannot change and
so skips the log entirely, and a read-*write* connection to a copied `.db`,
which is allowed to start a fresh empty log and then reports what the header
page alone contains.

One practical trap follows from this. A `-wal` is often zero bytes, which makes
it look like an empty file not worth copying. Copying it is precisely what
makes the read work.

## The two readers that actually lie

`immutable=1` is a URI parameter that asserts the database file cannot change.
It exists for databases on read-only media, and SQLite responds by skipping
locking, change detection, and the WAL. Point it at a live database and the
assertion is false: in the run above it ignored 1.1 MB of committed data and
answered `no such table` from the header page. The parameter did exactly what
it promises, on a file that broke the promise, and nothing anywhere warned us.

The copied `.db` is the same failure without the URI, and it is the one people
actually hit: a quick `cp` before poking at a live app's data, a backup script
globbing `*.db`, a database attached to a bug report. The log stays behind.
Opened read-write, that copy is allowed to begin a fresh empty log, so it opens
cleanly, parses correctly, and answers from whatever the last checkpoint wrote
— which can be a single header page.

Opened read-only, the same copy fails instead, with `unable to open database
file` at the first query. That asymmetry is worth internalising, because it is
the source of a recurring false bug report: *"this app's database won't open
read-only, error 14."* Nearly always the repro copied the `.db` without its
`-wal`. Re-test against the live path before concluding anything is broken. We
managed to file that exact false report against our own app while writing this
post.

What to do instead is short. To inspect a live database, query the real path
with plain `SELECT`s; readers do not block a WAL writer, so the caution behind
reaching for a read-only flag is already satisfied by the mode itself. To take
a copy, take the set — `.db`, `-wal`, `-shm` — and copy the `-wal` **even when
it is zero bytes**, because its absence is what turns a read-only open into
error 14. And when you own the database, `PRAGMA wal_checkpoint(TRUNCATE);`
folds the log into the main file first, after which the single file means what
it appears to mean.

## The whole test, runnable

The measurement fits in one script, and running it beats trusting us:

```sh
#!/bin/sh
# A live writer commits 5,000 rows in WAL mode with checkpointing off,
# then every reader opens fresh.
W=$(mktemp -d); DB="$W/live.db"

python3 - "$DB" <<'PY' &
import sqlite3, sys, time
c = sqlite3.connect(sys.argv[1])
c.execute("PRAGMA journal_mode=WAL")
c.execute("PRAGMA wal_autocheckpoint=0")   # park everything in the -wal
c.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, body TEXT)")
c.executemany("INSERT INTO t (body) VALUES (?)", [("x"*200,) for _ in range(5000)])
c.commit(); print("committed", flush=True); time.sleep(60)
PY
WRITER=$!; sleep 2
ls -l "$W"                                 # live.db is 4096 bytes

q() { printf '%-22s %s\n' "$1" "$(sqlite3 "$2" 'select count(*) from t;' 2>&1)"; }
q "plain path"          "$DB"
q "mode=ro"             "file:$DB?mode=ro"
q "immutable=1"         "file:$DB?immutable=1"
# Each copy gets its own file: opening one read-write CREATES an empty -wal
# beside it, which would then let a later read-only probe succeed.
cp "$DB" "$W/ro.db"; cp "$DB" "$W/rw.db"   # the .db WITHOUT its -wal
q ".db copy, read-only"  "file:$W/ro.db?mode=ro"
q ".db copy, read-write" "$W/rw.db"

kill $WRITER 2>/dev/null; wait $WRITER 2>/dev/null; rm -rf "$W"
```

On this machine the first two probes answer `5000`. `immutable=1` and the
read-write copy both answer `Error: in prepare, no such table: t` — confidently
wrong. The read-only copy answers `Error: in prepare, unable to open database
file` — wrong, but honestly so. All of it with the writer alive and a megabyte
of its committed rows sitting in `live.db-wal`.

## The clock freezes too

There is a second, quieter consequence of writes landing in the sidecar: the
main `.db` file's modification time moves at checkpoint time, not at commit
time. Watch that file to learn when the database changes — a file watcher, an
mtime comparison, a backup tool's is-it-newer check — and nothing appears to
happen while a busy writer streams commits into the `-wal` next door.

We ship a tool that has to get both blind spots right.
[Agent Sessions](https://jazzyalex.github.io/agent-sessions/?campaign=blog&ref=sqlite-wal-missing-rows)
opens other programs' SQLite session stores read-only — OpenCode's
`opencode.db`, Hermes's `state.db`, Devin's session database, Cursor's chat
store — while the agent that owns each one may still be writing to it.
OpenCode's is WAL-mode and live, which is where these traps first bit us. Its
change monitor,
`UnifiedSessionIndexer.fileSignature`, treats a `.db` file's signature as the
newest mtime across the database *and* its `-wal`/`-shm` sidecars, so a live
database still registers as changed between checkpoints. For Hermes the
freshness check skips file stats entirely:
`HermesStateDBReader.sessionActivitySignature` asks the database itself what a
session's latest activity is, because the honest source for "did anything
change" is a query, not a timestamp. The read path, meanwhile, leans on the
corrected fact from the table above: those readers all pass
`SQLITE_OPEN_READONLY`, and read-only is not the limitation folklore makes it
out to be.

## Why this keeps coming up

Local software keeps drifting into SQLite. Browsers keep history in it,
messaging apps archive into it, Electron apps persist state in it, and the
newest arrivals are coding agents, whose on-disk session stores we mapped in
[an earlier post]({{ site.baseurl }}{% post_url 2026-07-11-where-agents-store-history %}) —
OpenCode and Hermes both moved their entire history into WAL-mode databases.
The situation that produces these traps, a database owned by a program that is
running right now and read by a tool that did not write it, gets more common
every year.

The failure shape is worth naming, because it is not specific to SQLite.
`immutable=1` and the lone copy both fail by succeeding: valid connection,
clean parse, wrong data, no error anywhere. An instrument that cannot fail
loudly will report success while measuring the wrong thing, and the defense is
a positive control — confirm the reader can see data you know exists before
trusting what it says is absent. We had over a month between writing down the
wrong cause and testing it; the test took thirty seconds. As for the July
incident that started all this, the honest answer is that we no longer know
what caused it. The explanation we wrote down at the time is the one part we
can now disprove.

Agent Sessions is a free, local-only macOS app with no telemetry that makes
every coding agent's session history searchable, including the WAL-mode
databases above, all opened read-only.
[Download it](https://jazzyalex.github.io/agent-sessions/?campaign=blog&ref=sqlite-wal-missing-rows),
or read the database readers yourself —
[the source is on GitHub](https://github.com/jazzyalex/agent-sessions), and a
star there helps the next person doubting a healthy writer find this page.
More posts like this one live at [/blog/]({{ '/blog/' | relative_url }}).
