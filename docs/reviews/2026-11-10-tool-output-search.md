# Tool-output search: diagnosis (2026-11-10)

Status: diagnosis only. No code changed. Owner report: "search seems not well in tool outputs" (seen on Codex, maybe all agents).

## Summary

The report is correct for all agents, and the causes differ by agent:

- **Claude: a bug.** Any Claude tool result over 8 KB is indexed as the text `[OMITTED bytes=N]`, not as the output. The index holds 12,440 of these placeholders in 2,933 of 4,445 Claude rows.
- **Codex (and all sources): by design.** Each session gets 48,000 characters of index text in total, and each tool output gets at most 12,000. Long sessions have megabytes of output, so almost all of it is never indexed.
- **Return does not help.** With default settings, Return re-scans only sessions that are *not* indexed. It never re-reads indexed sessions. The tooltip says "Press Return for full deep scan", which is not true.
- **In-session Find searches the full tool text.** So a user sees a word in a session, and list search does not find that session. The UI does not say that list search is incomplete.

## Reproduction

Script: picks tokens that occur **only** in tool outputs (never in messages or tool inputs), at the head (<10%), middle (40–60%) or tail (>90%) of one output. Then it asks the real FTS tables whether that session's row matches `token*` (the same prefix query Instant search uses). Only rows whose stored mtime/size match the file were used. The DB was opened with `mode=ro`.
Script and raw results: `/private/tmp/claude-501/-Users-alexm-Repository-Codex-History/1012b16e-cdf8-4e27-9dd1-93040b56933e/scratchpad/` (`repro.py`, `results.json`, `results_codex.json`).

Found rate = the session would appear in Instant results. "+Tool I/O" = also counting `session_tool_io_fts`, which the owner has turned on (`EnableRecentToolIOIndex = 1`).

| Agent | Session size | Probes | Found (main FTS) | Found (+Tool I/O) |
|---|---|---|---|---|
| Codex | < 300 KB | 12 (1 session) | 100% | 100% |
| Codex | 1–10 MB | 87 | 22% | 36% |
| Codex | 10–80 MB | 75 | 8% | 21% |
| Claude | < 300 KB | 40 | 80% | 80% |
| Claude | 1–10 MB | 96 | 38% | 45% |
| Claude | 10–80 MB | 95 | 3% | 7% |

By output size:

| Agent | Output length | Found (main) | Found (+Tool I/O) |
|---|---|---|---|
| Claude | ≤ 8K chars | 69% | 81% |
| Claude | 8–12K | 25% | 25% |
| Claude | > 12K | **2%** | **2%** |
| Codex, 10–80 MB sessions | ≤ 2K | 20% | 30% |
| Codex, 10–80 MB sessions | 2–12K | 0% | 0% |
| Codex, 10–80 MB sessions | > 12K | 3% | 20% |

Position inside a long output (head, middle or tail) changes little. Misses happen because whole events are skipped, not only because one output is sampled.

## Causes, ranked by impact

### 1. Claude outputs over 8 KB become `[OMITTED bytes=N]` (bug)

- `ClaudeSessionParser.swift:8` `maxRawJSONFieldBytes = 8_192`. `sanitizeLargeStrings` (`:1332`) replaces every string over 8 KB in the event's `rawJSON` with `[OMITTED bytes=N]`. The event's `toolOutput` still holds the full text (`:644`, `:815`).
- `ToolTextBlockNormalizer.normalizeOutput` (`ToolTextBlockNormalizer.swift:212`) parses `rawJSON`, finds the tool_result `content` with `extractTextBlocksDeep`, and sets `stdout` to the placeholder. The real `outputText` is used only when `stdout` and `stderr` are both nil (`:237`), so the full text is dropped.
- Both index builders use this normalizer: `SessionSearchTextBuilder.build` (`SessionSearchTextBuilder.swift:273`) and `buildToolIO` (`:374`).
- Reproduced case: a short Claude subagent session (46 KB of index text, under budget). Of four tool results, the 8,967-character one is stored in both tables as `[OMITTED bytes=8999]`.
- Scale: `session_search` has 12,440 placeholders (2,933 Claude rows). `session_tool_io` has 6,486 (1,056 of 1,185 Claude rows). `CursorSessionParser.swift:14` has the same 8 KB cap, so Cursor probably has the same problem (not reproduced).
- Not checked: whether the transcript view shows the same placeholder anywhere. `TranscriptToolCells.swift:1027` has an `omittedMarker`, so the view seems to handle it.

### 2. Per-session budget and event sampling (all sources, by design)

`SessionSearchTextBuilder.build` (`:164`):
- Total: 48,000 characters. Head events get 40%, tail events 40%, middle 20% (`:245`).
- Middle: at most 48 events, picked by stride, from the middle half of the session (`:310`). Every other middle event is skipped completely.
- One tool output: at most 12,000 characters (`FeatureFlags.instantToolOutputIndexMaxChars`), split into head + middle + tail thirds (`:192`).
- Tool inputs and messages share the same budget. Long `apply_patch`/Write inputs push outputs out.

Rows are full: the average Codex row is 41,800 characters and the average Claude row is 40,700. Sampled long sessions have 2–9 M characters of tool output, so 1–2% of it can fit.

### 3. Tool I/O index reads from the start only

`buildToolIO` (`:348`) adds events in order until 120,000 characters (`toolIOIndexMaxCharsPerSession`), with each event cut to its first 32,000 (`toolIOIndexMaxCharsPerEvent`). In a long session, everything after the first ~120K characters is never indexed. It covers only sessions from the last 30 days (`toolIOIndexRecentDays`, `SearchIngestService.swift:378`, `:789`). It is off by default (`SearchCoordinator.swift:168`). For the owner it raises found rates by about 10–15 points on Codex.

### 4. Return does not re-read indexed sessions

- Return calls `startSearchImmediate()` with deep scan on (`UnifiedSessionsView.swift:4924`).
- With deep scan on, only sessions **not** in the index are scanned in full (`shouldIncludeUnindexedCandidate`, `SearchCoordinator.swift:947`).
- Indexed sessions are re-read only when `EnableDeepToolOutputSearch` is also on (`:505`, `:657`). It is off by default, and the owner has it off.
- So for the misses above, Return finds nothing new. The tooltip "Press Return for full deep scan" (`UnifiedSessionsView.swift:4927`, `:4978`) is wrong.
- With that setting on, the scan checks `event.toolOutput` only (`FilterEngine.swift:634`). Claude runtime errors keep their text in `event.text` (`ClaudeSessionParser.swift:651`), so the scan misses them.

Cost of deep scan when it is on: not measured in the app. It must parse every indexed session that has tool calls and is not already a hit: up to 7,344 sessions, 11.5 GB, including 207 files of 10 MB or more (6.1 GB) parsed one after another. A full Codex open of 78 MB takes ~0.6 s (2026-11-06 handover), so expect minutes, not seconds.

### 5. Smaller issues

- The Preferences help text says the Tool I/O index covers "the last 90 days" and keeps "up to 25 MB". The code uses 30 days and 8 MB (`FeatureFlags.swift:64-65`, `PreferencesView+General.swift:288`).
- The comment "Cursor sessions … have no FTS index" (`SearchCoordinator.swift:624`) is out of date: there are 34 Cursor rows.
- Changes to the builder reach existing rows only after `sessionSearchFormatVersion` (now 5) and `sessionToolIOFormatVersion` (now 1) are bumped (`FeatureFlags.swift:58-59`).

## Index size today (dbstat, read-only)

| Table | Size |
|---|---|
| `session_search` text (8,355 rows) | 336 MB |
| `session_search_fts` | 108 MB |
| `session_tool_io` text (1,837 rows, 30 days) | 120 MB |
| `session_tool_io_fts` | 83 MB |

The FTS index costs about 0.35–0.7 bytes per indexed character. Sampled sessions have 22–49% of their file bytes in tool output. Indexing all tool output (~4 GB of text) would therefore add several GB. That is not viable, so any fix must keep sampling.

## Fix options

**A. Fix the Claude placeholder bug (recommended, do first).**
In `normalizeOutput`, do not use `rawJSON` text that is an omitted marker; use the event's `outputText`. Check Cursor and Droid for the same pattern. Bump both format versions so that existing rows are rebuilt.
Cost: small code change and one background re-index of all rows (one full parse of ~11.5 GB). Index size stays about the same, because rows are already near the 48K budget.
Risk: low. The transcript tool view also uses this normalizer, so it needs a check for unwanted display changes; add a regression test with a >8 KB tool_result.

**B. Make Return do what it says, and tell the user (recommended, with A).**
On Return, also scan tool outputs of indexed sessions (the `EnableDeepToolOutputSearch` pass), but only on Return, never while typing. Include `.error` text in that scan. Show a short line under the results, for example "Instant search checks a sample of long sessions. Press Return to search all tool output." Fix the tooltip and the Preferences text.
Cost: no index growth. A Return search on large histories can take minutes; progress and Esc to cancel already exist.
Risk: medium for CPU and battery during a scan, but the user starts it on purpose.

**C. Better sampling in the Tool I/O index, then turn it on by default (follow-up).**
Spread the 120K budget over the whole session (head, middle and tail events, each output sampled at head/middle/tail), not only from the start. Possibly raise the cap for recent sessions.
Cost: about 200 MB for 30 days for this owner (same as today). Raising the cap grows it in proportion.
Risk: medium. Default-on adds disk use and ingest time for every user. It is still sampling, so B is still needed for exact recall.

## Recommendation

Do A and B together. A fixes the worst case (Claude outputs over 8 KB are never searchable, even in short sessions). B gives an honest, complete path for everything else without a larger index. Do C later, if Instant recall is still poor after A.
