# Weekly agent-format drift scan

`docs/agent-support/monitoring.md` has described the format check as a weekly
cadence since it was written, but nothing ever scheduled it — the run dates
under `scripts/probe_scan_output/agent_watch/` are hand-run bursts with gaps of
up to three weeks. This directory is the missing scheduler.

It runs `./scripts/agent_watch.py --mode weekly`, which checks installed agent
CLI versions against upstream releases, fingerprints each agent's session schema
against the fixtures, runs the Codex and Claude usage probes, and validates the
discovery-path contracts.

## Install

    bash tools/agent-watch/install.sh

Installs `com.agentsessions.agent-watch` as a LaunchAgent that fires **Mondays
at 09:00 local**. A run missed because the Mac was asleep fires on the next
wake; this is a review task, not a deadline.

## Uninstall

    bash tools/agent-watch/uninstall.sh

## Reading a run

    ls -dt scripts/probe_scan_output/agent_watch/*/report.json | head -1
    cat tools/agent-watch/out/launchd.log

Then follow the decision matrix in `skills/agent-session-format-check/SKILL.md`:
triage each agent by `severity` / `recommendation`, run `--mode prebump` for
anything flagged `run_prebump_validator`, and bump the verified versions in
`docs/agent-support/agent-support-{matrix,ledger}.yml`.

## Two things that will surprise you

**Weekly mode always exits 0.** Findings live in `results.<agent>.severity`
inside `report.json`, not in the exit status, so launchd has nothing to flag.
Only `--mode prebump` uses meaningful exit codes (2 = schema mismatch,
3 = driver failure, 4 = config error). The job is a reminder to look, not an
alarm that fires on its own.

**PATH is baked in at install time.** `agent_watch.py` shells out to every agent
CLI it checks, and several of them live outside launchd's bare PATH. `install.sh`
resolves each one at install time and writes the result into the plist — so
**re-run `install.sh` after installing a new agent CLI**, or the scan will report
that agent as unavailable.

The wrapper (`run-weekly.sh`) also `cd`s to the repo root, because
`agent_watch.py` resolves its config, the support matrix, and its report root
relative to the working directory. It resolves a GitHub token from `gh auth
token` at run time rather than baking one into the plist, so no secret is
written to disk.

## Tests

    bash tools/agent-watch/tests/test_install.sh

Renders the plist to a tempdir and asserts every placeholder was substituted and
the resolved tool directories made it into the launchd PATH. Nothing is
installed or loaded.
