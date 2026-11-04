# Codex Prompt: Format-Check Workflow + Update Format Check

Start Codex at the repo root with no sandbox. The run must update global CLIs, use the Keychain and
write to real agent stores, and the workspace sandbox blocks this:

```bash
codex --dangerously-bypass-approvals-and-sandbox
```

Then send everything below the line.

---

Work in `/Users/alexm/Repository/Codex-History` on `main`. Do two jobs in order: improve the
agent-session format-check workflow, then run a full update format check with it.

Read first:
1. `AGENTS.md`
2. The newest entry in `RepoHandover.md`
3. `docs/superpowers/plans/2026-11-02-format-check-workflow-proposal.md` (your task list)
4. `skills/agent-session-format-check/SKILL.md`
5. `docs/agent-support/monitoring.md`

Verify each claim in the proposal against the code before you act on it. If the code disagrees, the
code wins. Say so in your final report.

## Hard rules

- Do not commit, push, tag, release or create a branch. I decide that after your report.
- HEAD `7d18b878` is unpushed. Leave it as it is.
- `docs/backlog.md` has my uncommitted #87 entry. Keep it as it is. You may add new entries.
- Do not sign in for me, enter credentials, buy a plan or install a beta build. If a CLI needs a
  sign-in, put it on one list and ask me once. Continue with the other agents in the meantime.
- Never print a token, key or credential file. To inspect one, list key names and value types only.
- Add new Swift files with `scripts/xcode_add_file.rb`.
- Do not delete sessions or edit real agent stores by hand.
- Use the Edit tool or patches for code changes. Do not use inline Python to rewrite files.
- Run one `xcodebuild` at a time. Use `./scripts/xcode_test_stable.sh`, and read totals from the
  `.xcresult`. The baseline file is `tools/release/test-count-baseline.txt`. A lower count is a
  failure unless you can explain it.
- If a test forces macOS Appearance to Dark, restore `System` at the end.
- Do not change app behavior beyond defects this run proves. New ideas go to `docs/backlog.md`.

## Job 1: workflow

Do the proposal's P0 items 1-5, then P1 items 6-10, then P2 items 11-16.

Rules:
- Write a failing test first for each script change. Baseline:
  `python3 -m pytest -q scripts/tests tools/agent-watch/tests` gives 573 passed. The count must not
  drop.
- Do item 11 (the `SKILL.md` split) last, so it records what you learned. Move text and keep its
  meaning. After the split, confirm that each `##` section of the old file has a home.
- Item 5 changes every driver. Check that `claude_print` sessions are still recognised as prebump
  sessions after its `cwd` changes.
- Item 6 reads real sessions. Its output must hold counts only: no text, paths, ids or names. Keep it
  skipped unless `AS_REAL_SESSION_REPLAY=1`. Time-box it: if all agents do not fit, finish Codex,
  Claude and OpenCode and report the rest.
- Item 16 changes launchd. Do it after the CLI updates in Job 2, and report the plist path.

Before Job 2, all Python tests must pass and `./scripts/agent_watch.py --mode preflight` must run.

## Job 2: update format check

Follow the new runbook from start to end. Expect this to be a real sweep: on 2026-11-02 Codex,
Claude, OpenCode, Copilot, Kimi, Pi and OpenClaw are installed past their verified ceilings.

- Update every installed CLI that is behind upstream yourself. Re-read the version on PATH after each
  update. Update Codex last: your own process keeps running on the old binary.
- Use `--allow-real-home` for `real_home_session` agents.
- OpenClaw was held at 2026.10.5 because 2026.10.7 could not complete a turn through its Codex
  harness. Retry it on the installed build.
- Qwen, Devin and fx have no drivers. Follow the steward rules. Do not install them or chase them.
  Issue #83 already asks for the fx re-check.
- Keep each failed prebump's direct `report.json` as evidence.
- For a fresh session, confirm a real tool call and a non-zero `baseline_type_count`.
- Give every new key or type a value-pass bucket: handled, noise, watch or candidate. Prove `handled`
  with a read path and a test. Candidates go to `docs/backlog.md`.
- Add redacted drift to the normal fixtures with a survive-parsing test. Read the rebuild report
  before any `--emit`.
- Check prices against the official pages for every provider in the tables, not just OpenAI and
  Anthropic. If you edit a table, edit all three and raise `sequence` and `updated`. Do not edit
  `docs/prices-v2.released.json`; the release flow owns it.
- Run the replay. Explain every `usage_unavailable` reason, or report it as a finding.
- A changed usage or parsing rule needs positive and negative cases. Treat the first fix as a draft:
  on 2026-10-27 a rule that was too broad cost two review rounds.
- Write the matrix, ledger, tracking log and tracker only from the final weekly report, after the last
  CLI update. `as_of_commit` is `git rev-parse --short HEAD`.

## Finish

Before you report, run the full Python suite, `./scripts/xcode_test_stable.sh`, one final weekly, and
`git status --short`.

Then send one report:

1. Per-agent table: agent, tier, old -> new version, format change, app change, held or blocked, what
   would clear it.
2. Proposal items: done, partly done or skipped, with the reason. Include any proposal claim that was
   wrong.
3. Findings from the replay and from prices.
4. Test totals, and the path of the final weekly report.
5. A proposed commit split, as path lists: tooling first, then app fixes, then records. Mark my
   `docs/backlog.md` entry as separate.
6. Anything you need from me, as one short list.

Do not end the run on an offer of more work. If a step could not run, say so and say why.
