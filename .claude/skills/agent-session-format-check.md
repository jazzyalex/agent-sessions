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
- `evidence.sample_freshness.is_stale` — does the sample predate the installed CLI?
- `probes[*].ok` — did usage/status probes succeed?
- `weekly.discovery_path_contract` — does the storage layout still match expectations?

## Full auto-update workflow

Use this prompt in a new session to run the complete cycle:

> Run skill update agent formats

This triggers the following automated sequence:

1. **Weekly scan** — `./scripts/agent_watch.py --mode weekly`
2. **Triage results** by severity:
   - `low` + `bump_verified_version` → safe to bump (if sample is fresh)
   - `medium` + `run_prebump_validator` → sample is stale, run prebump first
   - `medium` + `run_weekly_now` → needs investigation (schema drift or probe issue)
   - `high` + `prepare_hotfix` → discovery contract or probe failure, investigate
3. **Prebump gate** for any agent flagged `run_prebump_validator`:
   ```bash
   ./scripts/agent_watch.py --mode prebump --agent <name> [--agent <name2> ...]
   ```
   Exit 0 = safe to bump. Exit 2 = schema mismatch. Exit 3 = driver failed. Exit 4 = config error.
4. **Bump verified versions** in matrix/ledger/tracking docs (only for agents that passed prebump or have fresh weekly evidence).
5. **Investigate** medium/high agents that need fixture work or re-auth.

### Decision matrix

| Weekly recommendation | Sample fresh? | Action |
|---|---|---|
| `bump_verified_version` | yes (`is_stale=false`) | Bump matrix/ledger/tracking |
| `bump_verified_version` | no (`is_stale=true`) | Run `--mode prebump` first, then bump if exit 0 |
| `run_prebump_validator` | — | Run `--mode prebump`, then bump if exit 0 |
| `run_weekly_now` | — | Investigate schema drift or probe failure |
| `prepare_hotfix` | — | Investigate discovery contract or monitoring failure |

### Parallel subagent dispatch pattern

For efficiency, dispatch work in parallel by independence:
- **Low-severity bumps** (shared yml/md files) → one agent, sequential edits
- **Medium-severity investigations** (claude, copilot, etc.) → one agent per provider, read-only
- **High-severity root cause** (e.g. openclaw discovery) → opus agent, may need code fixes
- **Prebump runs** → one agent per provider (after investigation clears)
