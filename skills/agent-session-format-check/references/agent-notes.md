# Format-check reference: agent-notes

The [runbook](../SKILL.md) governs authority and run order. Historical incidents below
explain the checks; they do not authorize sign-ins, purchases, commits or releases.

Current corrections (2026-11-02): Cursor's probe validates ACP protobuf and SQLite
contracts as documented in `docs/agent-support/monitoring.md`; it is deeper than the
older metadata-only description below. Hermes weekly now unions five SQLite sessions.

## 2  Usage / Limits Drift (Codex + Claude)

Usage and limits tracking can drift **independently** of session schema. Monitor both.

### Codex
- **Passive channel:** session JSONL `token_count` / `rate_limits` event structure. This is
  covered by the schema fingerprint **only because codex is fingerprinted nested** (§5) —
  these events live under `event_msg.payload`, and the flat fingerprint that ran until
  2026-08-03 stopped at `{payload,timestamp,type}` and could never see them. If codex is
  ever moved back to the flat fingerprint, this channel goes unwatched again.
- **Active channel (weekly):** `codex_status_capture.sh` output schema — parsed as
  `codex_status_json` by `agent_watch.py`.
- Check: in `results.codex.weekly.probes` (a list), the entry with
  `label == "codex_status_probe"` returns `ok == true` and `exit_code == 0`.
  If not, investigate whether Codex changed its status output format.

### Claude
- **Active channel (weekly):** `claude_usage_capture.sh` output schema — parsed as
  `claude_usage_json`.
- **Context probe:** `./scripts/claude-status --json` records status.claude.com
  indicator/incidents (parsed as `claude_status_json`).
- Check: in `results.claude.weekly.probes` (a list), the entry with
  `label == "claude_usage_probe"` returns `ok == true` — if `false`, the usage API
  response format may have changed, or authentication may be required. The
  `label == "claude_status"` entry (parse `claude_status_json`) reports
  status.claude.com indicator/incidents.
- If probe health fails (`parsing_failed`, auth required, etc.), treat as **high severity**
  because the UI can break.

### Known issue: Claude usage probe exit 16 (parsing_failed)
`claude_usage_capture.sh` can fail with exit 16 when Claude auth tokens are exhausted.
The `/usage` TUI command itself stops working in this state. This is **not** a format
change — resolution requires `claude auth login`. The failure is intermittent and clears
after re-authentication. The Swift side silently retains the last known good snapshot.

### What to look for in upstream release notes
- New or renamed fields in usage/billing/token responses.
- Auth changes (new scopes, cookie rotation, API key requirements).
- Rate-limit header changes or new quota enforcement mechanisms.

---

## 2b  Codex Rollout Compression (`.jsonl.zst`)

Codex's `local_thread_store_compression` (upstream `codex-rs/rollout/src/compression.rs`)
replaces any rollout under `sessions/` or `archived_sessions/` that has not been modified
for **7 days** with `rollout-….jsonl.zst` (one zstd stream, level 3, mtime preserved)
and **deletes the plain file**. Resume restores plain `.jsonl` first. Readers prefer the
plain file when both exist. The flag is off by default in the CLI; the desktop app turns
it on (announced 2026-10-14 as "60% less disk").

The records inside are unchanged, so this is a container change, not schema drift, and
the schema fingerprint will not flag it. What to check instead:

- `results.codex.weekly.local_schema.compressed_files`: the number of compressed rollouts
  under the scanned roots. Zero means compression has not run on this machine yet.
- The discovery contract accepts both forms; a sampled `.jsonl.zst` is decoded with
  Python's `compression.zstd` (3.14+) in `_open_session_text`.
- App side, `CodexRolloutStorage` keeps every Codex session on its canonical `.jsonl`
  path (session ids hash that path), resolves the file that exists, streams `.zst` through
  `ZstdStreamDecoder`, and gives seek-based readers (image spans) a decoded cache copy.
  `CodexRolloutStorageTests` pins the behavior.

To reproduce compression without touching real history, copy a few old rollouts (keep
their mtimes) plus `auth.json` into a throwaway `CODEX_HOME` and run
`codex exec -c features.local_thread_store_compression=true "Reply with ok."` there.

## 3  OpenCode Storage Changes

OpenCode's current local backend is SQLite at `~/.local/share/opencode/opencode.db`.
Legacy installs may still have a multi-file JSON tree (`storage/session/`,
`storage/message/`, `storage/part/`). Monitoring is SQLite-first and falls back to
the legacy JSON tree when no database is present.

### Current layout
```
~/.local/share/opencode/opencode.db

# legacy fallback
~/.local/share/opencode/storage/session/<project>/ses_*.json
~/.local/share/opencode/storage/message/<sessionId>/msg_*.json
~/.local/share/opencode/storage/part/<messageId>/*.json
```

### What to watch for
- **New storage backends:** OpenCode is a Go application. Watch upstream releases for
  introduction of SQLite, BoltDB/bbolt, Badger, or other embedded databases alongside or
  replacing the JSON file tree.
- **Schema changes in any record type:** session, message, or part records can evolve
  independently. The fingerprinter tracks keys per record kind.
- **New record types or directories:** a new sibling to `session/message/part` would
  indicate a storage expansion.
- **Migration flags:** look for `version`, `migration`, `schema_version` fields in
  session records or new migration files in the OpenCode repo.

### OpenCode 2.x (2026-10)
OpenCode 2.0 keeps the v1 `session`/`message`/`part` tables in `opencode.db`, frozen, and
writes new sessions only to `session_v2` + `session_message` (typed rows ordered by `seq`:
user, assistant step, shell, system, synthetic, skill, compaction, idle, ...). It also copies
v1 sessions into the v2 tables with the same IDs, and that copy can drop assistant steps of
older sessions, which is why the app reads a v2 row only when it is newer than its v1 row.
- Upstream is npm `@opencode/cli`; GitHub Releases stop at 1.19.3 even though v2 tags exist.
- `opencode run` in 2.x has no `--pure`/`--dir`, and by default talks to a per-user
  background service on a fixed port. The `opencode_run` driver passes `--standalone --auto`
  on 2.x so the sandbox gets a private server that cannot collide with the owner's live one.
- The fingerprint buckets are `session_v2`, `session_message.<type>`,
  `session_message.assistant.content.<item>`, `session_message.assistant.tool_state.<status>`,
  `session_message.assistant.tokens`, `session_message.assistant.tokens.cache`,
  `session_message.assistant.model` and `session_message.user.file` (see
  `_opencode_v2_message_buckets`). The baseline is `Resources/Fixtures/stage0/agents/opencode/sqlite_v2/`,
  built from every 2.x row on disk with values redacted; `test_v2_fixture_values_follow_the_redaction_policy`
  allows only placeholders and discriminators. When a 2.x sample is clean, all v1 buckets show
  under `missing_keys`; that is expected, not drift.
- The 2.x store is sampled only when its newest session is strictly newer than the newest v1
  one. Equal timestamps mean an untouched migrated copy, which can be lossy, so v1 is sampled.
- The prebump's required buckets depend on the store the fresh session landed in
  (`required_schema_buckets_by_store`): 2.x needs `session_message.user`,
  `session_message.assistant` and `session_message.assistant.tool_state.completed`; 1.x needs
  `message.user`, `message.assistant` and `part.tool`. It counts physical rows, so a session
  header alone, or a reply without a completed tool call, fails.
- Every v2 bucket has a `.shape` companion (`<key>:<json type>`), so a type change such as
  `model` becoming a string is an unknown key, not just a missing nested bucket. Fields the app
  reader needs (`user.text`, `assistant.model.id`, the five token counts, a tool's `id`, `name`
  and `state.status`) are checked on every row; a row missing one is counted in
  `required_field_violations` and as a parse error.
- Parse errors (invalid JSON, non-object `data`, required-field violations) fail the prebump
  and, for every agent, the weekly schema verdict. They are summed across all sampled sessions,
  a clean prebump cannot replace a weekly verdict whose own sample has parse errors, and the
  compatibility verdict reports them as `format_drift_detected` with the
  `sample_unreadable_records` blocker. A store that could not be read at all (SQLite open or
  query failure such as a locked database, OS read error) is not a parse error: it is
  `read_failed`, reported as `monitoring_broken` with the `sample_read_failed` blocker.
  Qwen's glued-object lines, which the app parser
  recovers, count as `tolerated_glued_lines`, not parse errors (`_GLUED_OBJECT_AGENTS`).
- Row types and `session_v2` columns the app handles but the disk has not produced yet (the
  `shell` row; fork, share, revert and workspace columns) are seeded in the fixture from the
  upstream schema, so their first appearance is not reported as drift.

### Detection in agent_watch.py
- `opencode_latest_session` fingerprints the newest 2.x session from `session_v2` +
  `session_message` when that store holds a strictly newer session; otherwise it checks
  `db_roots` and fingerprints `session`, `message`, and `part` rows from `opencode.db`.
- If no database is present, `_opencode_storage_session_tree_schema_fingerprint()`
  walks the legacy JSON tree for a session and reports keys per record kind.
- Risk keywords in `docs/agent-support/agent-watch-config.json` still flag release notes mentioning
  storage migrations such as SQLite, BoltDB/bbolt, Badger, or database changes.

---

## 3b  OpenClaw SQLite Store (2026.10.5+)

Transcripts live in `agents/<id>/agent/openclaw-agent.sqlite`. `transcript_events` rows
keep the JSONL record shapes, as `event_json` or one zstd frame (`event_zstd`, decoded
size in `event_utf8_bytes`). The startup import copied legacy JSONL under the same ids
and moved the originals to `session-sqlite-import-archive/`.
- `openclaw_latest_session` fingerprints the newest 5 sessions with the same nested
  alphabet as JSONL, plus `sqlite.<table>` column buckets; the baseline includes
  `Resources/Fixtures/stage0/agents/openclaw/sqlite/openclaw-agent.sql`.
- `details` is shallow (`_NESTED_SHALLOW_KEYS`): its first-level keys are watched
  (the app reads `exitCode`/`status`), its nested objects are not.
- The prebump driver finds its session by `--session-key` and needs the marker in an
  assistant or tool-result record (the prompt alone carries it).
- **Prebump sessions:** real-home prebump runs land in the store as the newest sessions.
  The weekly recognises them by their `:prebump-` session key and skips them while enough
  real sessions exist (§5). When `sampled_prebump_sessions` is non-zero, the store has too
  few real sessions, and a clean weekly says little beyond what the prebump already proved.

---

## 3a  Cursor Storage

Cursor uses two storage backends:

- **JSONL transcripts** (`~/.cursor/projects/<workspace>/agent-transcripts/<uuid>/<uuid>.jsonl`) — primary session data, parsed by Agent Sessions. Subagent transcripts live in a `subagents/` subdirectory.
- **SQLite chat databases** (`~/.cursor/chats/<workspace-hash>/<uuid>/store.db`) — supplementary metadata (session name, model, timestamps). Key "0" in the `meta` table contains hex-encoded JSON.

The weekly scan fingerprints JSONL transcripts only. The SQLite probe (`cursor_sqlite_probe.py`) verifies the `meta` table is readable — it does not deep-fingerprint the database schema.

**What to watch for:**
- New top-level keys on `role: user/assistant` lines.
- New content block types beyond `text`, `tool_use`, `tool_result`, `thinking`.
- The `agent-transcripts/` directory being renamed or moved.
- SQLite probe failures indicating `meta` table schema changes.

**Note:** Some machines may have a stale PATH shim for `cursor` even when Cursor.app is installed. The weekly monitor tries the PATH command first, then falls back to the embedded app CLI at `/Applications/Cursor.app/Contents/Resources/app/bin/cursor --version`.

Cursor CLI latest-source truth comes from the official installer script at
`https://cursor.com/install`, which embeds `downloads.cursor.com/lab/<build>/...`
agent CLI package URLs. The Homebrew `cursor-cli` cask page is a fallback. Do
not use the unrelated npm package named `cursor-agent`.

Cursor Desktop agent windows use the same local surfaces as Cursor CLI:
`~/.cursor/projects/*/agent-transcripts/**/*.jsonl` for transcript content and
`~/.cursor/chats/*/*/store.db` for chat metadata. The weekly
`cursor_sqlite_probe` must keep reporting the newest Desktop chat DB's
`agentId`, `createdAt`, mode/model fields, mtime, and meta-key schema so fresh
Desktop-only windows are visible even when their JSONL transcript is absent or
older.

---

## 4a  Grok Sessions Are Directories

A Grok session is a directory, not a file: `chat_history.jsonl` holds the transcript and
the sibling `summary.json` holds everything discovery depends on (`info.id`, `info.cwd`,
`current_model_id`, `chat_format_version`). Fingerprinting only the transcript would leave
that half unwatched, so `_grok_session_schema_fingerprint()` merges the summary in as a
`summary` bucket — schema diffs on `summary`/`summary.info` are summary.json drift, not
transcript drift.

**The sidecar is a discovery precondition, not a schema nicety.**
`GrokSessionDiscovery.discoverSessionFiles()` skips any session directory whose
`summary.json` is absent, so losing that one file removes *every* Grok session from the
app. Merging it into the fingerprint does not protect it — see §4
`required_companion_files`, which is what actually flips the verdict. Grok declares it
with `must_parse: "json_object"`, deliberately stricter than the app's own `fileExists`
guard: a present-but-corrupt sidecar still lists the session but strips its id, cwd,
title and both timestamps. `_grok_session_schema_fingerprint()` also records a
`summary_error` (`missing` / `unreadable` / `invalid_json` / `not_json_object`) so the
fingerprint stops pretending it read a sidecar it could not.

**Grok's parser is tolerant of additive fields.** `GrokSessionParser` used to
decode `summary.json` through a `Codable` struct, so one field arriving with a new type
threw and `try?` dropped the *whole* sidecar — id, cwd, title, model and both timestamps
at once. It reads `JSONSerialization` dictionaries field by field now, so vendor
additions are ignored keys and a changed field costs exactly that field. Drift is
therefore an alert here (this scan), never a crash — pinned by
`GrokSessionParserTests.testUnknownNewFieldsAreIgnored` and
`testSidecarFieldOfTheWrongTypeCostsOnlyThatField`.

Grok is fingerprinted **nested** (§5). Flat would stop at `{type, content, ...}` and hide
the content-part types (`user.content:text`, `user.content:image`) and
`backend_tool_call.kind.action`, which is where its format actually moves. `arguments` is
opaque — it is a tool's parameter object, not Grok format.

The baseline is **two** session directories: `grok/` (top-level) and `grok/subagent/`.
That split is deliberate — `session_kind` appears *only* on subagent sessions and is
absent from top-level ones, so stamping it on the top-level fixture would have taught the
inverted semantics to anything that later classifies on it. Keys that belong to one kind
go in that kind's fixture; the baseline unions both.

**Latest version comes from two sources that disagree.** Grok ships a native x.ai binary
through the `grok-build` Homebrew cask, and the cask lags x.ai releases. The
`grok_update_check` probe declares `latest_version_key: "latestVersion"`, and
`_reconcile_latest_version_from_probes()` takes the **higher** of cask and CLI — max, not
replace, because the CLI answers only for its own pinned `channel`, so a lower CLI answer
must never hide a newer published release. The chosen number's origin is in
`upstream.parsed_version_provenance` (`cli_probe` / `upstream_source` / `both_agree` /
`cached_prior_report`), the full comparison in `upstream.reconciliation`, and any
disagreement prints on the weekly summary line as
`latest_disagree=probe:<v>/source:<v>/used:<v>`. Never read `upstream.parsed_version`
without its provenance.

Still unwatched: `subagents/<childId>/meta.json` — the parent's sidecar, and the only
place `parent_session_id` and `subagent_type` appear, so the hierarchy feature depends on
it (the `grok/subagent/` fixture is a subagent *session*, not that sidecar) — and the
`compaction/` subtree. No fixture covers either yet. Also unwatched: the app's 50 MB
`defaultFullParseMaxBytes` ceiling, above which `GrokSessionParser` silently declines to
parse a transcript, and a wholesale move of the `~/.grok/sessions` root, which surfaces
only as `local_schema.error: no_files_found` plus a stale sample rather than as a named
contract failure (`discovery_contract_failed` is gated on a file having been found).

---
