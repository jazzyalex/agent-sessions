# Format-Check Workflow: Proposal After the 2026-10-27 Sweep

**Status:** proposal, 2026-11-02. Not implemented.
**Covers:** `skills/agent-session-format-check/`, `.claude/skills/agent-session-format-check.md`,
`docs/agent-support/`, `scripts/agent_watch*.py`.
**Run it with:** [2026-11-02-format-check-codex-prompt.md](2026-11-02-format-check-codex-prompt.md).

## Summary

The sweep found real problems and shipped them fixed in 6.2. It also needed two corrections from
the owner, six review rounds and one more fix after the release. Three causes explain most of this:

1. **The run has no defined end.** The first pass stopped with CLIs behind and no per-agent answer.
2. **A clean verdict proves less than it says.** It proves the shape of a few sessions. It does not
   prove that the app reads real sessions correctly.
3. **The workflow is hard to follow.** `SKILL.md` is 63 KB of mixed rules and history. The only
   end-to-end run order is in a different file, and that file is stale.

The fix is a short runbook, a few focused checks and one new test. It is not a new pipeline.

## What happened

| # | Event | Cost |
|---|---|---|
| 1 | The first pass left Claude and OpenCode behind upstream. Owner: "you don't need for cli update from me - you do it." | A second sweep pass |
| 2 | OpenCode's weekly read only the newest session, and the report called the sample thin. Owner: "opencode had yesterday sessions." | A real bug stayed hidden: refused requests made Session Info usage and the Quota Meter rate unavailable |
| 3 | Five-session sampling then found 6 refused rows. Their keys were all known, so the schema check was clean. | The schema channel cannot see this class of bug |
| 4 | Review rounds covered that rule and ended in SHIP. Hours after the release, one Esc press blanked a live session's rate (`7d18b878`). | A fix after release, still unpushed |
| 5 | The richer Antigravity prompt wrote `probe.txt` into the repo root, because the driver had no working directory. | Stray file; eight drivers still have no `cwd` or workspace flag |
| 6 | The OpenCode driver copied a legacy `auth.json` with OAuth tokens, and an inherited `OPENCODE_DB` could reach the live database. | Two P1 review findings |
| 7 | Grok's sign-in had expired on 2026-10-14. The run found this part way through. Three Cline free models had also ended. | Failures appeared one at a time |
| 8 | `_classify_prebump_failure` matches "not logged in" but not Grok's "Not signed in", and has no model-unavailable class. | Failures report as generic `driver_failed` |
| 9 | Claude moved 2.1.310 -> 2.1.311 -> 2.1.312 and Codex moved 0.164.0 -> 0.165.0 during the run. | Records were written twice |
| 10 | The owner had to ask: "for what agents formats changes were made and what need changes but not posible?" | No standard final report |
| 11 | Inspecting `~/.cline/data/settings/providers.json` printed a token prefix into tool output. | A credential exposure |
| 12 | The owner had to point out the Codex price change. The scan does not check prices. | `gpt-6.1-terra` had no price row |

State on 2026-11-02, six days later:

| Agent | Installed | Verified ceiling |
|---|---|---|
| Codex | 0.166.0 | 0.165.0 |
| Claude | 2.1.316 | 2.1.312 |
| OpenCode | 2.2.5 | 2.2.0 |
| Copilot | 1.0.105 | 1.0.104 |
| Kimi | 2.4.1 | 2.3.3 |
| Pi | 1.5.0 | 1.4.0 |
| OpenClaw | 2026.10.9 | 2026.10.5 (held) |

No report told anyone. The last report is from 2026-10-27, because the weekly LaunchAgent is not
installed, although `docs/agent-support/monitoring.md` describes the schedule.

## Proposed changes

### P0: before the next sweep

**1. Give the run a fixed order, a scope of authority and an end.**
Put this at the top of `SKILL.md`:

1. Preflight (item 3).
2. Weekly snapshot.
3. Update every installed CLI that is behind.
4. Prebump every agent with a driver, including held agents.
5. Triage and value pass.
6. Replay real sessions (item 6) and check prices (item 8).
7. Fix what the run found. Run tests.
8. Check upstream again. If a version moved, repeat steps 3-4 for that agent once.
9. Final weekly. Write records from that report only.
10. Final report.

*The phrase "update format check" authorizes* CLI updates, real-home prebumps, redacted fixtures,
tests, driver fixes, parser fixes for defects the run proves, and records.
*It does not authorize* commit, push, release, signing in for the owner, buying a plan, or installing
a beta.

This replaces the §1b rule "install only if you can complete step 2". The owner's rule wins: update
first. If the new build cannot produce a session, record a hold.

*The run is finished when:* each agent with a driver is `supports_latest` at the final weekly or has
a hold with a reason; every new key or type has a value-pass bucket; replay has no unexplained
failure; every recent model slug has a price; Python and Xcode tests pass with no count decrease;
and `git status` shows only intended paths.

**2. Require a final per-agent table.**
Columns: agent, tier, old -> new version, format change, app change, held or blocked, and what would
clear it. Add a small `--summary <report.json>` so the table comes from the report, not from memory.
Steward agents follow §1g.

**3. Add `--mode preflight`.**
It starts no session. For each agent it reports: binary on PATH and its version, credential present
(type only, never a value), the pinned model when the CLI can list models offline, and whether the
latest version is reachable. Declare the checks in `agent-watch-config.json`. Print one list of
every owner action at the start of the run.

Presence is not proof, so the report must say "credential present", not "signed in". Prebump stays
the proof.

*Done when:* an expired Grok session and an ended Cline model appear in one list before any prebump
runs, and a test proves that no credential value reaches the output.

**4. Make updates a tool, and check that they took effect.**
Add an `install` block per agent (`argv` and `version_probe`) and `--mode update [--agent X]`.
After each update, the version on PATH must equal the target. If it does not, report
`update_not_effective`. This catches the Grok case, where `grok update` left `~/.local/bin/grok` on
the old binary.

**5. Isolate every driver.**
Close the [backlog entry](../../backlog.md) "Prebump drivers run in the caller's working directory":

- Set `cwd=sandbox` on all drivers and keep existing workspace flags.
- In `_run_prebump`, compare `git status --porcelain` before and after. A change fails the driver as
  `sandbox_breach`.
- Let config declare env names and prefixes to drop for each agent, and do this in `prepare_auth`,
  so `OPENCODE_*` is not a special case.

`claude_print` is recognised partly by running in the repo. After the `cwd` change, confirm that
`_is_prebump_session_file` still skips its sessions.

*Done when:* a test run with a driver that writes to the repo fails, and each driver test asserts
its `cwd`.

### P1: in the same run if time allows

**6. Add a real-session replay. This is the highest-value new check.**
Events 2, 3 and 4 in the table have one cause: the checks read keys, and the bug was in what the app
did with known keys. Add a gated test, `RealSessionReplayTests`, that does nothing unless
`AS_REAL_SESSION_REPLAY=1` is set. For the newest 20 sessions per agent it runs the production
discovery, parser and usage code. It writes a counts-only JSON file under the ignored
`scripts/probe_scan_output/replay/` folder:

`sessions_read`, `parse_failed`, `zero_events`, `usage_complete`, `usage_unavailable`, and a histogram
of `usage_unavailable` reasons by row type, `finish` value and `error.type`.

Start with Codex, Claude and OpenCode. Add other agents only where one call reaches the parser. No
session text, path or id goes in the output. Read SQLite stores in read-only mode. `AgentSessionsLogicTests`
does not compile the OpenCode reader, so this likely belongs in `AgentSessionsTests`. That test host
opens the real index at startup, so the test must not write to it, and it stays out of the normal
suite.

The histogram must list every failure value it sees, so a new value is a visible row. Today's
OpenCode store holds `provider.free-limit` (114 rows), `aborted` (37), `provider.error` (9) and
`unknown` (1). The `aborted` row that caused `7d18b878` is one row, and it may postdate the sweep, so
replay does not prove it would have caught that exact row. It would have shown `aborted` as a value
to rule on.

*Done when:* a fixture store with an unknown failure value shows that value as a named histogram
row, and a run on real stores leaves no unexplained row.

**7. Apply one sampling contract to all agents.**
Every local schema result reports `store_sessions`, `sampled_sessions`, `sampled_events` and
`sampled_versions`. The summary prints "sampled 5 of 162". A test goes through every agent and fails
if one samples a single session without a declared reason. Hermes samples one session today. Fix it
or declare why. A thin verdict must print the store count, so the report cannot blame the agent for
a sampler limit.

**8. Make price coverage part of the weekly.**
For slugs seen in the last 30 days, resolve each against `prices-v2.json` with the app's longest-prefix
rule and report `price_coverage` with any unpriced slugs. Keep `<synthetic>` as a documented exemption.
Fix §2a, which still says two tables and `updated`. The real set is `docs/prices-v2.json`,
`docs/prices.json` and `RunwayPriceTable.bundledJSON`, with `sequence`, `updated` and
`prices-v2.released.json`. It also lists only Anthropic and OpenAI, though Session Info prices more
agents.

**9. Classify driver failures correctly.**
Add `not signed in`, session-expired text and `model_unavailable` to the failure classifier, with a
fixture line per CLI. Add `fallback_models` to the Cline, Pi and OpenCode config, and try the next
model only on `model_unavailable`.

**10. Make holds expire.**
Add a structured hold to the matrix: `version`, `reason`, `since`. The sweep retries every held agent
on the newest build. OpenClaw's hold was written for 2026.10.7, and 2026.10.9 is installed.

### P2: docs

**11. Split `SKILL.md`.**
Keep `SKILL.md` under 200 lines: the question, authority, run order, verdicts, done rule, report
format and hard safety rules. Move the rest, unchanged in meaning, into
`skills/agent-session-format-check/references/`: `prebump-drivers.md`, `fingerprint.md`,
`agent-notes.md`, `prices.md`, `stewards.md` and `incidents.md`. No rule may be lost.

**12. Keep one source.**
- `.claude/skills/agent-session-format-check.md` shrinks to a pointer. Its decision matrix still sorts
  by legacy `severity`, and its contract table still lists Droid and the old OpenCode path.
- Add `.agents/skills/agent-session-format-check/` as a pointer, so Codex finds the skill.
- `docs/agent-support/workflow.md`, both `update-checklist.md` files and `tools/agent-watch/README.md`
  link to the runbook and stop repeating it.
- Fix `monitoring.md` so it says the schedule works only after `install.sh`.

**13. Give each record one job, and shorten them.**

| Record | Job |
|---|---|
| Matrix | Current ceiling, hold, one-line note |
| Ledger | Claim, scope, evidence paths; note of three sentences at most |
| `agent-json-tracking.md` | One paragraph of format changes |
| `agent-format-tracker.jsonl` | One row per finding, with bucket and `confidence` |

The longest 2026-10-27 ledger lines run to about 1,700 characters and repeat the tracking log. The
tracker has 165 rows, but the skills, the scripts and `docs/agent-support/*.md` do not mention it. Document it in
the runbook and add one pytest check that each row parses and has the required fields.

**14. Order the commits so review does not rewrite records.**
Commit driver and app fixes first, and review them. Commit records last, from the final weekly.
`as_of_commit` is the audited code baseline. Add to the runbook: a usage rule needs positive and
negative replay cases before review, and a CHANGELOG Bug Fixes entry names only defects in a released
build.

**15. Add a credential rule.**
Never print a credential file to learn its shape. List key names and value types only. Preflight is
the normal way to check credentials.

**16. Install the weekly LaunchAgent.**
Run `bash tools/agent-watch/install.sh` after the CLI updates, because it bakes PATH into the plist.
`tools/agent-watch/uninstall.sh` reverses it.

## Dropped from the 2026-08-31 spec

[That spec](2026-08-31-format-sweep-automation-SPEC.md) was marked ready two months ago. Its
`--mode preflight`, `install` blocks, `agent_format_tracker.py` and `build_plan` do not exist. This
proposal keeps the preflight and install ideas in a smaller form and drops the rest:

- Patch manifests with hash checks (`build_plan`, `apply_plan`). Reading the rebuild report before
  `--emit` already caught every map problem.
- The tracker renderer and generated doc section.
- Backlog patch proposals with stable markers.
- Rollback events and refusal rules for installs.
- The rule that refuses a prebump on thin stores. Real-session preference now handles that.

This is a personal tool with one maintainer. More machinery would again sit unbuilt.

## Expected result

A sweep runs once, end to end, with owner input only for sign-ins. The final table answers the
owner's question without a follow-up. A session that the app reads wrongly shows up as a replay
failure, before review.
