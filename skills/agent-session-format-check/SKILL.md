---
name: agent-session-format-check
description: Verify agent session format compatibility for Agent Sessions. Use when any agent CLI updates, when monitoring flags drift, or when bumping max verified versions (fixtures + docs + tests). Covers session schema, usage/limits tracking, storage backends, and discovery path contracts for all supported agents.
---

# Agent Session Format Check

## Runbook: update format check

An explicit "update format check" authorizes stable CLI updates, real-home prebumps,
redacted fixtures, tests, driver fixes, parser fixes for proven defects, and records.
It does not authorize commits, pushes, tags, releases, sign-in, purchases, or beta installs.
Never print credential files: inspect key names and value types only.

Run in this order:
1. `./scripts/agent_watch.py --mode preflight`. Collect owner actions once; continue
   with other agents while sign-ins are pending. Credential presence does not prove auth.
2. Run `--mode weekly` for the initial snapshot; read `STEWARDS.md` for ownership.
3. Update every installed stable CLI behind upstream with `--mode update`; update Codex
   last. Re-read PATH after each update. Do not install absent steward agents or chase Qwen.
4. Run `--mode prebump --agent NAME --keep-sandbox` for every driver, including held
   agents. Add `--allow-real-home` for `real_home_session` agents. Keep failed direct reports.
   Confirm a real tool call and non-zero `baseline_type_count` for fresh sessions.
5. Triage every new key/type as handled, noise, watch or candidate (§1e). Handled needs
   a read path and a behavior test. Candidates belong in `docs/backlog.md`.
   Tests: do not add a test per sweep. When a new record's event kind matters to the user
   (it must not render as a prompt, reply or tool call), add one row to
   `testDriftRecordsParseAsTheirExpectedKind` in `Stage0GoldenFixturesTests.swift`. A
   field the parser only has to tolerate needs no test: the fixture and fingerprint cover it.
6. Run gated real-session replay and verify official prices for every table provider.
7. Fix proven defects; add positive and negative cases for each changed usage/parsing
   rule. Treat the first fix as a draft. Run Python and stable Xcode tests.
8. Recheck upstream after all updates; if a stable version moved, repeat update/prebump
   for that agent once. Install the weekly LaunchAgent after updates (PATH is baked in).
9. Run a final weekly. Write matrix, ledger, tracking log and append-only finding tracker
   from that report only. Set `as_of_commit` to `git rev-parse --short HEAD`.
10. Run final Python/Xcode checks, final weekly and `git status --short`; report from
    `--summary REPORT.json`, adding evidence-backed app changes and holds.

Done means every driver has current real evidence or a dated hold and reason; every new
field has a value bucket; replay has no unexplained failure; recent model slugs are priced;
tests pass without an unexplained count decrease; only intended paths changed.
Propose separate commits as path lists: tooling, app fixes, then records. Do not commit.
Records are written last, after review of fixes; `as_of_commit` names the audited baseline.
CHANGELOG Bug Fixes names defects in a released build only; workflow hardening is Maintenance.

Final report: per-agent table (agent, tier, old -> new version, format change, app change,
held/blocked, what clears it); proposal item status and corrected claims; replay/prices;
test totals and final report path; proposed commit paths; one list of required owner actions.

Answer one precise question for every supported agent:

> Can current Agent Sessions code support the latest available session/storage/usage
> format from the latest available agent build?

The answer must be layered. Do not collapse version checks, stale samples, schema
fingerprints, discovery contracts, and usage probes into a vague severity label.

**Evidence-first:**
- Gather a report + sample paths first.
- Do not change parsers/fixtures/docs without explicit user approval.

**Related skill:** `agent-support-matrix` — maintains the matrix YAML, ledger, and
update-checklist workflow. This skill focuses on *detection and evidence collection*;
`agent-support-matrix` focuses on *recording and gating version bumps*.

**Process doc:** `docs/agent-support/monitoring.md` — defines the compatibility verdicts,
legacy severity model, cadence, and escalation workflow that feed into this skill.

---

## Question and verdicts

Can current Agent Sessions read the latest available agent's session, storage and usage
formats? Treat schema, usage, discovery, sample freshness and version identity separately.

- `supports_latest`: latest known build is covered by
  `evidence.fresh_evidence_source == "latest_prebump_report"` and
  `compatibility.latest_real_session_evidence == true` with
  `compatibility.latest_status == "current_fetch_known"`. This verdict is not a clean
  bill by itself: also require the **current** `weekly.schema_diff.unknown_types == []`,
  `weekly.schema_diff.unknown_keys == {}`, healthy probes, and a passing discovery
  contract. The compatibility layer can reuse an older clean prebump report while a newer
  weekly sample has already drifted; in that case report and investigate the current drift
  rather than repeating `supports_latest`.
- `supports_installed_only`: installed build is covered by non-stale real local
  evidence, but latest is newer, cached from a prior report, unknown, or lacks
  fresh real-session proof.
- `latest_unknown`: no configured/reachable latest source or no real-session
  driver exists; do not claim latest support. **Check `STEWARDS.md` before calling this
  a finding** — for a steward-verified agent not installed here, this verdict is the
  expected output and the agent belongs to its steward, not to you (§1g).
- `blocked_stale_sample`: evidence predates the installed CLI; run prebump before claiming support.
- `blocked_no_fresh_evidence`: a version changed but no fresh matching sample proves support.
- `format_drift_detected`: unknown schema/storage/usage fields appeared; update fixtures/parsers.
- `blocked_thin_sample`: the sample was both narrow and tiny, so it evidenced nothing either
  way (§5). Generate a session that actually uses tools — not a one-line prompt.
- `monitoring_broken`: latest source, usage probe, or discovery contract failed.
- `real_session_auth_failed` in blockers: the real-session driver ran but the
  sandboxed agent was not authenticated; re-auth or provide the configured env
  token, then rerun prebump.


## Evidence and safety

A read-only check gathers reports first and changes nothing without explicit authority.
An authorized update sweep uses the authority above; no extra approval is needed for its
specified fixes, fixtures or records. Never expand that into external publication.

Use production discovery, full parsers and usage code for replay. Run:
`AS_REAL_SESSION_REPLAY=1 ./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/RealSessionReplayTests`.
The normal suite skips real stores. Output is counts plus schema-discriminator histogram
keys in `scripts/probe_scan_output/replay/counts.json`: no text, paths, IDs or names.
The replay launches `scripts/replay_watchdog.py`: a separate process kills the test host
after 180 seconds even if a parser blocks. Counts are saved between sessions so a timeout
keeps partial evidence. Finish Codex, Claude and OpenCode first; report omitted sources.

No real-store edits or session deletion. SQLite reads use read-only mode. Never print
credential files; list key names and value types only. Presence is not proof of sign-in.
Use `--allow-real-home` for configured real-home drivers. Keep their sandbox cwd and
workspace flags; repository status and content changes fail as sandbox_breach, including
rewrites of existing dirty or untracked files. A breach stops model fallback.
Fallback models are tried only for model_unavailable, never for auth, quota or timeout.

Use patches for code. Add Swift files with scripts/xcode_add_file.rb. Run one xcodebuild
at a time; use the stable wrapper and xcresult totals. Restore System appearance after
any QA that forces Dark. Positive and negative cases precede every usage/parsing fix.

Read rebuild reports before --emit. Put redacted verified drift in normal fixtures;
speculative adversarial shapes stay outside the baseline. Preserve the old key superset.
Do not infer handled from tolerance: cite a read path and a behavior test.

## References and records

Read the relevant reference before making a claim:

- [Drivers, auth, installs and latest claims](references/prebump-drivers.md)
- [Fingerprint, discovery, value pass and fixture guardrails](references/fingerprint.md)
- [Per-agent storage and usage notes](references/agent-notes.md)
- [Prices, all tables and official-source checks](references/prices.md)
- [Steward ownership and communication](references/stewards.md)
- [Incidents and unavailable agents](references/incidents.md)

[Section map](references/section-map.json) gives every original ## section a home.
Historical instructions in references yield to the current runbook and explicit user scope.

The matrix holds current ceilings, holds and a short note. The ledger holds claim, scope
and evidence paths, with at most three sentences of notes. The tracking log gets one
format-change paragraph. Append one finding row to agent-format-tracker.jsonl with bucket
and confidence; retain historical rows unchanged. See
[record ownership](../../docs/agent-support/workflow.md). All four derive from the final
weekly after the last update. A structured hold records version, reason and since, and
is retried next sweep. Records never substitute for fresh native evidence.
