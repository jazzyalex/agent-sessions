# Antigravity CLI JSONL Migration — Design

**Date:** 2026-06-26
**Status:** Approved (design); pending implementation plan
**Author:** Agent Sessions maintainer

## Problem

The Antigravity CLI (`agy`) changed its on-disk session storage. It used to write
markdown "brain" artifacts:

```
~/.gemini/antigravity/brain/<conversation-id>/*.md
```

As of `agy` builds running since ~2026-06-18 (current installed 1.0.12), it writes a
structured JSONL event stream instead:

```
~/.gemini/antigravity-cli/brain/<conversation-id>/.system_generated/logs/transcript.jsonl
```

(Per-conversation `~/.gemini/antigravity-cli/conversations/<id>.db` SQLite files also
exist but are out of scope — the JSONL transcript is sufficient.)

Consequences today:

1. **App regression.** The Agent Sessions app discovers and parses only the legacy
   markdown path (`GeminiSessionDiscovery`, `GeminiSessionParser`). It has been blind
   to every current `agy` CLI session since the migration.
2. **Monitor blind / false alarm.** `agent_watch.py` uses an
   `antigravity_markdown_newest` discovery that scans `~/.gemini/antigravity/brain/*/*.md`.
   The newest markdown artifact is from 2026-03-04, so the weekly scan reports
   `blocked_stale_sample`, and prebump reports `antigravity_no_brain_artifact`.

Critically, `agy -p`/`--print` (headless mode) **does** write a JSONL transcript to the
new location — confirmed by a prebump run whose transcript contains the injected
`AGENT_WATCH_PREBUMP_<token>` marker. The "no artifact" failure was purely that the
driver looked in the dead markdown path. Once discovery points at the new JSONL store,
headless `agy -p` is a fully functional evidence generator; no interactive sessions are
required.

## Goals

- Restore Antigravity support in the app: discover and parse the new JSONL transcripts
  into a real structured transcript (user / assistant / thinking / tool calls / tool
  results).
- Keep legacy markdown sessions visible (historical sessions up to 2026-03-04).
- Restore monitoring: discovery contract + schema fingerprint for the JSONL format, and
  a working headless `agy -p` prebump path.
- Bump verified Antigravity version 1.0.9 → 1.0.12 once fresh JSONL evidence matches the
  new baseline.

## Non-Goals

- Parsing the per-conversation `conversations/<id>.db` SQLite store.
- Any UI redesign.
- Changing the legacy markdown parser behavior.
- Resume command format changes (the existing `agy --conversation <id>` is correct).

## New JSONL Format

One JSON object per line under
`~/.gemini/antigravity-cli/brain/<id>/.system_generated/logs/transcript.jsonl`.
Common fields: `step_index`, `source`, `type`, `status`, `created_at` (ISO-8601 Z).
Observed `type` values and notable extra fields:

| `type`                 | `source`        | Extra fields            | Meaning |
|------------------------|-----------------|-------------------------|---------|
| `USER_INPUT`           | `USER_EXPLICIT` | `content`               | User prompt. `content` wraps the text in `<USER_REQUEST>…</USER_REQUEST>` plus optional `<ADDITIONAL_METADATA>` and `<USER_SETTINGS_CHANGE>` blocks (the latter names the model, e.g. "Gemini 3.5 Flash (Medium)"). |
| `CONVERSATION_HISTORY` | `SYSTEM`        | —                       | Marker. |
| `PLANNER_RESPONSE`     | `MODEL`         | `thinking`, `tool_calls`| Assistant turn. `thinking` is reasoning text. `tool_calls` is an array of `{name, args}` (args values are JSON-encoded strings, e.g. `DirectoryPath`, `toolAction`, `toolSummary`). |
| `LIST_DIRECTORY`       | `MODEL`         | `content`               | Tool result (directory listing). |
| `VIEW_FILE`            | `MODEL`         | `content`               | Tool result (file view). |
| `RUN_COMMAND`          | `MODEL`         | `content`               | Tool result (shell output). |
| `CHECKPOINT`           | `SYSTEM`        | `content`               | Compaction/checkpoint summary. |

`transcript.jsonl` and a sibling `transcript_full.jsonl` exist; they have matched line
counts in observed samples. We use `transcript.jsonl` as the primary source.

## Architecture

The existing Antigravity code lives under the `Gemini*` names (historical: Antigravity
was formerly surfaced via Gemini). We keep those names to match the codebase.

### 1. Discovery — dual root (`GeminiSessionDiscovery`)

Scan and merge results from both roots, returning a mixed URL list sorted by mtime desc:

- Legacy: `~/.gemini/antigravity/brain/*/*.md` (existing shallow scan, unchanged).
- New: `~/.gemini/antigravity-cli/brain/*/.system_generated/logs/transcript.jsonl`.

The new-root scan iterates conversation dirs under `~/.gemini/antigravity-cli/brain` and,
for each, resolves `<id>/.system_generated/logs/transcript.jsonl` if present.

Custom-root preference still overrides the legacy root. Add an optional CLI-root override
with default `~/.gemini/antigravity-cli/brain` (the General/CLI prefs that mention
`~/.gemini/antigravity/brain` are updated to reflect both).

### 2. Parser — dispatch by file type (`GeminiSessionParser`)

`parseFile` / `parseFileFull` dispatch on extension:

- `.md` → existing `parseAntigravityMarkdown` (untouched).
- `.jsonl` → new structured parse. Implemented in a focused helper
  (`AntigravityTranscriptParser`) so the JSONL logic is isolated and independently
  testable; `GeminiSessionParser` delegates to it.

Event mapping (JSONL `type` → `SessionEvent`):

| JSONL `type`            | `SessionEvent.kind` | Notes |
|-------------------------|---------------------|-------|
| `USER_INPUT`            | `.user`             | Text = `content` with the `<USER_REQUEST>` wrapper stripped; metadata blocks dropped from display text (kept in `rawJSON`). |
| `PLANNER_RESPONSE`      | `.assistant`        | Assistant text from any narrative; `thinking` surfaced as reasoning. Emit one `.tool_call` event per `tool_calls[]` entry (toolName = `name`, toolInput = decoded `args`). |
| `RUN_COMMAND` / `VIEW_FILE` / `LIST_DIRECTORY` | `.tool_result` | toolOutput = `content`; toolName carried from the most recent preceding `tool_call` when resolvable. |
| `CHECKPOINT` / `CONVERSATION_HISTORY` | `.meta` | Preserved as metadata; not primary transcript content. |

Preview parse (`includeEvents == false`) produces a lightweight session with
`eventCount` set and empty `events`, matching the existing preview/full split.

Derived session fields:
- **id**: conversation ID (the `<id>` brain dir component); fall back to sha256(path).
- **title**: first line of the first `USER_INPUT` (wrapper stripped).
- **model**: parsed from the `USER_SETTINGS_CHANGE` block when present, else `nil`.
- **cwd**: reuse existing git-root inference over embedded `file://` / absolute paths and
  `tool_calls` `DirectoryPath` args.
- **startTime/endTime**: first/last `created_at` (fall back to file ctime/mtime).

### 3. Resume (`GeminiResumeTypes`)

Extend `conversationID(fromArtifactURL:)` to recognize the new nested path and return the
`brain/<id>` component. The resume command (`agy --conversation <id>` / `--continue`) and
coordinator are unchanged.

### 4. Monitor (`agent_watch.py` + `agent-watch-config.json`)

- Config: point antigravity `discover_session` / weekly `local_schema` at the new JSONL
  store (kind e.g. `antigravity_cli_transcript_newest`, root
  `~/.gemini/antigravity-cli/brain`, glob `*/.system_generated/logs/transcript.jsonl`),
  and add a `discovery_path_contract` for it. Keep the legacy markdown discovery as a
  fallback so historical evidence still resolves.
- Add `_antigravity_cli_transcript_schema_fingerprint(path, max_lines)` that buckets keys
  by top-level `type`, mirroring the cursor/JSONL fingerprinters.
- Prebump `discover_session` resolves the newest new-format transcript; the existing
  `agy -p` driver then produces fresh evidence headlessly.

### 5. Fixtures + version record

- Add redacted `Resources/Fixtures/stage0/agents/antigravity/cli_small.jsonl` covering all
  observed `type` values (incl. a `PLANNER_RESPONSE` with `thinking` + `tool_calls` and a
  `RUN_COMMAND`/`VIEW_FILE`/`LIST_DIRECTORY` result). Generated from a tool-triggering
  `agy -p` prompt, then redacted per the fixture guardrails.
- Add `cli_schema_drift.jsonl` for the drift detector (excluded from baseline).
- Keep existing `small.md`.
- Register fixtures in `agent-support-matrix.yml` `evidence_fixtures`.
- Bump `max_verified_version` 1.0.9 → 1.0.12 in matrix + ledger + tracking once a fresh
  `agy -p` prebump matches the new baseline.

## Testing

- **Swift golden fixtures** (`Stage0GoldenFixturesTests`): parse `cli_small.jsonl` and
  assert presence of `.user`, `.assistant`, `.tool_call`, and `.tool_result` events and
  a non-empty title; assert the legacy `small.md` still parses unchanged.
- **Swift resume**: `conversationID(fromArtifactURL:)` returns the right `<id>` for a new
  nested path and for a legacy markdown path.
- **Monitor (python)**: fingerprint test over `cli_small.jsonl` vs `cli_schema_drift.jsonl`;
  discovery-contract pass for the new path.
- **Live verification**: `agy -p` prebump matches the new baseline; final weekly scan
  reports `supports_latest` (or at least `supports_installed_only`) with
  `matches_baseline=True` for antigravity.

## Risks / Notes

- The `Gemini*` naming is retained to match the codebase; new JSONL logic is isolated in
  `AntigravityTranscriptParser` to avoid bloating `GeminiSessionParser`.
- `tool_calls[].args` values are JSON-encoded strings (double-encoded); decode defensively.
- Print-mode transcripts are thinner than interactive ones (fewer tool types); the fixture
  is generated from a tool-triggering prompt so the baseline covers the richer set.
  "Missing types" in a thin live sample are treated as sampling noise by the diff, not drift.
