# Agent Session Format Check

Verify agent session format compatibility for Agent Sessions. Use when any agent CLI
updates, when monitoring flags drift, or when bumping max verified versions.

Covers: session schema, usage/limits tracking, storage backends, and discovery path
contracts for all supported agents.

## How to use

Read and follow `skills/agent-session-format-check/SKILL.md` — it is the single source
of truth for this workflow.

## Quick reference

Run monitoring (evidence-first, no code changes without approval):

```bash
# Full weekly scan (checks versions, schema fingerprints, probes, discovery contracts)
./scripts/agent_watch.py --mode weekly

# Skip agent CLI updates (already updated locally)
./scripts/agent_watch.py --mode weekly --skip-update

# Daily (quiet on success)
./scripts/agent_watch.py --mode daily
```

Report is written to `scripts/probe_scan_output/agent_watch/*/report.json`.

Key fields per agent in the report:
- `severity` / `recommendation` — action needed?
- `evidence.schema_matches_baseline` — does the session format still match fixtures?
- `probes[*].ok` — did usage/status probes succeed?
- `weekly.discovery_path_contract` — does the storage layout still match expectations?
