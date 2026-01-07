---
name: codex-session-format-check
description: Verify Codex CLI session JSONL format compatibility for Agent Sessions. Use when codex-cli updates, when daily monitoring flags Codex drift, or when bumping Codex max verified version (fixtures + docs + tests).
---

# Codex Session Format Check

This skill is for quickly verifying whether a newer Codex CLI version changes the local session
JSONL schema, and whether Agent Sessions can safely bump its verified support.

It is **evidence-first**:
- Gather a report + sample paths first.
- Do not change parsers/fixtures/docs without explicit user approval.

## Quick Start (Most common)

1. Run weekly monitoring and open the report:
   - `./scripts/agent_watch.py --mode weekly`
   - Report path prints to stdout, and is also written under `scripts/probe_scan_output/agent_watch/*/report.json`.
2. In `report.json`, check `results.codex`:
   - `verified_version`, `installed.parsed_version`, `upstream.parsed_version`
   - `weekly.local_schema.file` (the newest rollout JSONL used for comparison)
   - `weekly.schema_diff` and `evidence.schema_matches_baseline`

Interpretation:
- If `installed == verified` and `upstream == verified`: no action.
- If `installed/upstream > verified` and `schema_matches_baseline == true`: safe to bump verified version (after approval).
- If `schema_matches_baseline == false`: collect evidence and plan a parser/fixture update.

## What to collect as evidence (Codex)

From the weekly report:
- The path in `results.codex.weekly.local_schema.file` (the newest `rollout-*.jsonl`).
- The schema diff summary in `results.codex.weekly.schema_diff`:
  - `unknown_types`, `unknown_keys` (additive drift)
  - `missing_types`, `missing_keys` (may just mean “not observed in this sample”)

Optional (recommended when a bump is needed):
- Copy the newest session file into `scripts/agent_captures/<timestamp>/codex/` so it can be diffed locally.
  - Keep it private (do not commit raw sessions; they can contain paths and prompts).

## Verification update checklist (after approval)

1. Refresh Codex stage0 fixtures so they represent the current session shape:
   - `Resources/Fixtures/stage0/agents/codex/small.jsonl`
   - `Resources/Fixtures/stage0/agents/codex/large.jsonl`
2. Ensure fixtures include the “important” event families when present in real sessions:
   - `session_meta` payload keys (commonly grows over time)
   - `response_item` tool_call/tool_result and message events
   - usage/limits events (`token_count` / `rate_limits`) when emitted
   - optional event wrappers (e.g. compaction or context events) when present
3. Bump the verified version record:
   - `docs/agent-support/agent-support-matrix.yml` (`agents.codex_cli.max_verified_version`)
   - Append a new entry in `docs/agent-support/agent-support-ledger.yml`
   - Add a line to `docs/agent-json-tracking.md` under “Upstream Version Check Log”
4. Run tests locally:
   - `xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -destination 'platform=macOS' test`

## Redaction guardrails (fixtures)

Codex sessions can include user instructions, file paths, and other sensitive content.
When turning a real session into a committed fixture:
- Replace long instruction bodies with a short placeholder string (keep structure).
- Remove or truncate large base64/data-url blobs if present.
- Prefer keeping only minimal, deterministic message text (e.g., “List the files”).
- Keep the schema shape intact: do not delete keys just because values were redacted.

