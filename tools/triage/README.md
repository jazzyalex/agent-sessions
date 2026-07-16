# Repo triage

A daily digest of open issues/PRs across the Agent Sessions repos, with drafted
replies you can post with one confirm. A launchd job runs it each morning.

## How it works

`triage.sh` → `gather.sh` (lists open issues/PRs + recent comments via `gh`) →
`run-agent.sh` (a **tool-less** Claude call: the data goes in the prompt as
text, the agent returns a digest + suggested replies as text — it has no tools,
so attacker-controlled text in an issue body can't steer it into running shell,
fetching URLs, or posting) → a macOS notification.

You skim `out/<date>/digest.md`. To post one of the suggested replies, run
`reply.sh <id>` — it shows the exact target and text and asks `y/N`. **Nothing
posts without your yes.**

## Install

    bash tools/triage/install.sh        # needs jq + gh (authenticated) + claude CLI

It checks deps, verifies notifications work, runs the agent-confinement gate
against the real `claude` CLI, and installs a daily 08:00 LaunchAgent.

## Use

    open $(ls -dt tools/triage/out/*/digest.md | head -1)   # today's digest
    tools/triage/reply.sh R1                                 # post suggested reply R1

## Uninstall

    bash tools/triage/uninstall.sh

## Config — `policy.json`

`repos` (watched), `agent` (`claude` today; `codex` needs its adapter verified),
`agent_model`, `lookback_hours` (window for "recent comments").

## Tests

    for t in tools/triage/tests/test_*.sh; do bash "$t"; done

The confinement test drives the real `claude` CLI (skips if absent); the rest
use PATH-shadowing stubs. Design notes:
`../../docs/superpowers/specs/2026-07-16-repo-triage-automation-design.md`.
