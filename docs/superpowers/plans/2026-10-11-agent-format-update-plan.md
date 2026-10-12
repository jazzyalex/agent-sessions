# Agent format update plan — 2026-10-11

Source: weekly scan `scripts/probe_scan_output/agent_watch/20261011-164520-565109Z-p22271/report.json`
(previous scan: `20261009-173710-696188Z-p76638`). Skill: `skills/agent-session-format-check`.

No parser, fixture, or matrix file was changed to produce this plan.

## 0. Status after the first work pass (2026-10-11)

Done, uncommitted:
- **A1** Codex probe: launches with `-c check_for_update_on_startup=false`; exits with
  `startup_prompt_blocked` and sends no input if a startup menu still shows; reset text no
  longer keeps a trailing `)`. Two tests added in `CodexStatusProbeSuppressionTests`. Live
  probe returns `ok`. An Esc-to-skip fallback was tried and removed: it did not dismiss the
  menu under tmux.
- **A2** Claude probe: not a format change. `claude auth status` reports `loggedIn: false`,
  and the TUI header reads "API Usage Billing", so `/usage` has no limit bars. Needs
  `claude auth login` by the owner.
- **B** Value pass done with measured frequencies; entries filed in `docs/backlog.md`
  (one candidate, one watch list). Copilot `model.*` events render as meta rows, not
  duplicate messages.
- **C** `tools` added to the Codex opaque keys; fixtures rebuilt for Codex (+6), Claude
  (+23), Copilot (+13), Antigravity (+1). Rescan: no unknowns for all four.
- **F** Prices: OpenAI all match. Anthropic: Sonnet 5.5 cache read corrected 0.2 → 0.1 in
  both tables, `updated` advanced. Open: no `claude-haiku-5-5` key (page: $0.10/$0.50 up
  to 100K prompt tokens, $0.50/$2.50 above); it falls back to `claude-haiku` at $1/$5.

Second pass (decisions made):
- `claude-haiku-5-5` key added to both price tables: $0.10/$0.50, with a `longContext`
  tier at 100,000 prompt tokens (5x input and output). Test added.
- Full Swift suite after all changes: 3,430 run, 3 skipped, 0 failures. Python: 431 passed.
- No CLI updates and no version bumps: a bump needs a prebump session, and the prebump
  run (`--allow-real-home`) was blocked by the session permission classifier.
- Sol review through Repo MCP not run: unfinished coding task
  `agent-sessions-largelib-plan-20261007` (bound 2026-10-08 at `14af90fb`) owns this
  checkout, and the review flow must not freeze another agent's task.
- Patch release: recommended for the Codex probe fix, not started (no commit without an
  explicit request).

Third pass (after the owner's sign-ins and prebump run):
- Claude usage probe returns `ok`. Final weekly
  (`scripts/probe_scan_output/agent_watch/20261011-181703-371999Z-p65090/report.json`):
  no unknown schema for any agent, all probes `ok`.
- Bumped from fresh prebump sessions: Codex 0.160.1, Copilot 1.0.91, Pi 1.0.3 (matrix,
  ledger, tracker, tracking log, `STEWARDS.md`). Pi needed a fixture refresh first.
- Held: Claude 2.1.289 (no prebump run), Antigravity (self-updated to 1.3.3 during
  prebump; sample stale), Cursor (account usage limit), OpenCode (xAI refresh token
  invalid), OpenClaw (monitoring reads JSONL, 2026.9.8 writes SQLite; backlog entry
  filed), Grok and Hermes (not in the run).
- Full Swift suite on the final tree: 3,430 run, 3 skipped, 0 failures. Python: 431.

The list below is superseded where the third pass covers it.

Owner actions:
1. `claude auth login`.
2. Prebump: `./scripts/agent_watch.py --mode prebump --allow-real-home --agent codex --agent copilot --agent antigravity --agent cursor --agent opencode --agent openclaw --agent pi`
3. `grok login`; set a Hermes provider token or switch its provider.
4. Finish or release the Repo MCP task above, then request the review.
5. Post the fx ping (draft below), then say "commit".

Draft fx steward ping (@thedavidweng):
> fx has shipped 0.0.8 through 0.0.13 since the last verified version (0.0.7). Could you
> run `./scripts/steward_check.py fx` against your sessions and post what it prints? It
> takes about 10 minutes. No rush.

New after the rescan: Antigravity is `blocked_thin_sample` (its newest sessions are
small); it needs a tool-using session before a bump.

## 1. Scan result

| Agent | Verified | Installed | Upstream | Verdict | Tier |
|---|---|---|---|---|---|
| Codex | 0.159.0 | 0.160.1 | 0.162.1 | `monitoring_broken` + drift | Maintained |
| Claude | 2.1.285 | 2.1.289 | 2.1.296 | `monitoring_broken` + drift | Maintained |
| Copilot | 1.0.89 | 1.0.91 | 1.0.95 | `format_drift_detected` | Best-effort |
| Antigravity | 1.1.27 | 1.2.17 | 1.3.3 | `format_drift_detected` | Best-effort |
| OpenCode | 1.18.29 | 1.18.34 | 1.19.0 | `blocked_stale_sample` | Best-effort |
| OpenClaw | 2026.7.1 | 2026.9.8 | 2026.10.1 | `blocked_stale_sample` | Best-effort |
| Pi | 0.85.1 | 1.0.3 | 1.1.0 | `blocked_stale_sample` | Best-effort |
| Grok | 1.0.24 | 1.0.44 | 1.0.50 | `blocked_stale_sample`, driver failed 09-29 | Best-effort |
| Hermes | 0.21.1 | 0.21.5 | 0.21.6 | `supports_installed_only`, driver failed 09-29 | Best-effort |
| Cursor | 2026.9.8 | 2026.10.1 | 2026.10.1 | `supports_installed_only`, clean | Best-effort |
| Kimi | 2.1.1 | 2.1.1 | 2.1.1 | `supports_latest` | Best-effort |
| Qwen | 0.14.3 | 0.25.0 | 0.25.1 | `blocked_stale_sample`, no driver, no paid plan | Best-effort |
| Cline | 3.0.62 | 3.0.70 | 3.0.70 | `blocked_stale_sample`, no driver | Best-effort |
| DeepSeek Harness | 0.2.0-rc.2 | 0.2.0-rc.2 | 0.2.1-alpha.2 | `supports_installed_only`, clean | Best-effort |
| Devin | 3000.6.7 | not installed | unknown | `latest_unknown` (expected) | Steward-verified |
| fx | 0.0.7 | not installed | 0.0.13 | `blocked_no_fresh_evidence` | Steward-verified |

All discovery path contracts pass (fx has no local files, which is expected).

Changes since the 10-09 scan:
- Claude went from drift-only to `monitoring_broken`: `claude_usage_probe` now fails.
- Codex gained `compacted.payload.resume_metadata.turn_attribution` and `world_state.payload.state.tools`.
- Claude gained `assistant.requestedModel` and `deferred_tools_delta.removedByBlock`.
- Cline installed moved to 3.0.70.

## 2. Phase A — fix the usage probes (do first)

### A1. Codex `/status` probe — root cause found
`AgentSessions/Resources/codex_status_capture.sh` exits 124 (45 s timeout) or 16 (`parsing_failed`).
Debug capture shows the TUI stops on a new start screen:

```
Update available · 0.160.1 → 0.162.1
› 1. Update now (runs `npm install -g @openai/codex`)
  2. Skip
  3. Skip until next version
  enter continue · esc skip
```

The script only handles `Press enter to continue` and `OpenAI Codex (v`. It never reaches the prompt.

- This script ships inside the app. The active `/status` channel probably fails for every user who has a Codex update pending. Confirm in the app before sizing the release.
- Risk to check: the script then types `/status` and sends Enter while this menu is open. The default selection is "Update now". The installed version is still 0.160.1, so no update ran, but the path is not proven safe.

Fix:
1. Detect `Update available` in the startup loop and send `Esc` (skip). Do not send Enter.
2. Check whether Codex has a config or flag that disables the update check, and prefer it for the probe launch if it exists.
3. Add a fixture-pane test for the update screen next to the existing capture-script tests.
4. After the fix, confirm the `/status` text still matches `5h limit:` / `weekly limit:`. The current parse was not reached, so its state is unknown. OpenAI dropped the 5h limit on 2026-07-13.
5. Verify on the failing path: run the probe with an update pending and confirm `ok: true`.

### A2. Claude `/usage` probe — cause not confirmed
`claude_usage_capture.sh` exits 16. The captured `/usage` pane shows only the Session block (cost, duration, token counts) and the plugin footprint. It has no `Current session` or `Current week` limit bars. The probe passed on 10-09 with the same CLI version 2.1.289.

Possible causes, in order of likelihood:
1. Limits failed to load. status.claude.com reports "Partially Degraded Service" (incident open since 10-07), and the edge 429 case is known.
2. Auth state of the probe session changed (skill §2 known issue: needs `claude auth login`).
3. Layout change delivered server-side.

Steps:
1. Rerun the probe 2–3 times over a day. Run `/usage` by hand once and compare.
2. If the bars appear by hand but not in the probe: fix the wait or scroll logic.
3. If the bars are absent by hand too: re-auth, then retest.
4. If the layout changed: update the anchors and add a pane fixture.

## 3. Phase B — value pass on the drift (skill §1e)

Buckets below are proposed. Each needs the proof listed before it is final.

### Codex
| Field | Proposed bucket | Note |
|---|---|---|
| `world_state.payload.state.tools` (keyed by tool name) | noise + **add to `_NESTED_OPAQUE_KEYS`** | free-form map; today it creates one bucket per MCP server |
| `world_state.payload.state.model_catalog` | noise | check shape; add to opaque keys if keyed by model id |
| `task_started.turn_attribution`, `task_complete.root_turn_id`, `compacted…resume_metadata.turn_attribution` | watch | names the parent turn and the agent that started a turn; possible subagent hierarchy source. No Swift reads today |
| `response_item.metadata.sender_user_messages`, `compacted…sender_deliveries` | watch | cross-agent message delivery; check that transcript text is not lost or duplicated |

### Claude
| Field | Proposed bucket | Note |
|---|---|---|
| `assistant.thinkingDurationMs` | **candidate** | a duration a user would ask about; measure how often it occurs first |
| `assistant.requestedModel` | **candidate** / watch | requested vs served model; matters for `$` pricing if they differ |
| `user.permissionDecision` (`decision`, `reasonType`, `source`) | candidate / watch | a state transition the UI hides; measure frequency |
| `serverClassifierRequest`, `user.serverClassifierContext.*` | noise | classifier plumbing; confirm `git_state` holds nothing the transcript shows |
| `deferred_tools_delta.surfacedDefinitions`, `removedByBlock`, `deferred_tools_record.toolInputCopies`, `prompt_snapshot.inlineTools`, `toolChangeHeader`, `attachment.renderedBesideToolResult` | noise | tool-definition bookkeeping; `definition.input_schema` is tool-defined, so consider an opaque key |

### Copilot
A new `model.*` event family in `events.jsonl`: `turn_started/ended/failed`, `model_call_started/success/failure`, `message`, `messages_snapshot`, `response`, `captured_assignment_context`. No Swift code reads it.

| Field | Proposed bucket | Note |
|---|---|---|
| `model.model_call_success.data.responseUsage`, `copilotUsage` (`total_nano_aiu`, `token_details`) | **candidate** | per-call token and cost data; Copilot has no usage surface in the app today |
| `…quotaSnapshots.{chat,completions,premium_interactions}` (`remainingPercentage`, `resetDate`) | **candidate** | live quota in the session file; a Copilot limits source with no probe |
| `modelCallDurationMs`, `ttftMs`, `interTokenLatencyMs` | watch | latency numbers |
| `model.message`, `model.response`, `model.messages_snapshot` | **check first** | these carry message content. Confirm the parser does not render duplicate transcript rows or oversized `.meta` rows. This is the one item that can be a visible bug |
| `modelInfo.*` (`billing.token_prices`, `capabilities`) | watch | upstream-supplied prices per model |
| `session.model_change.data.{autoTier,cause,source}`, `session.resume.data.{autoTier,contextTier,eventsFileSizeBytes,sessionLimits}` | watch | |

Also check file growth: `messages_snapshot` and `requestMessages` can make `events.jsonl` much larger. Compare against the parser's size limits.

### Antigravity
| Field | Proposed bucket | Note |
|---|---|---|
| `PLANNER_RESPONSE.{input_tokens,output_tokens,cache_read_tokens}` | **handled** | `AntigravityTelemetryAccumulator.swift` reads them. Cite the test, then refresh the normal fixture only |

Output of Phase B: final buckets recorded in the ledger note, and each candidate filed in `docs/backlog.md`. `docs/backlog.md` has uncommitted edits by the owner; add entries without touching those.

## 4. Phase C — fixtures and fingerprint

1. `scripts/agent_watch.py` → `_NESTED_OPAQUE_KEYS`: add Codex `tools` (and `model_catalog` if keyed), and Claude `input_schema` if confirmed tool-defined.
2. For Codex, Claude, Copilot, Antigravity: `./scripts/rebuild_stage0_baseline.py --agent <a>` (read the report), then `--emit`. Sweep all sessions, not the newest five.
3. New types go in the **normal** fixtures, as a superset of the old key sets. Check redaction by hand before commit.
4. Rerun weekly. Expect `unknown_types == []` and `unknown_keys == {}` for all four.

## 5. Phase D — fresh evidence and version bumps (skill §1b)

Order per agent: install latest → prebump → confirm exit 0 and `fresh_matches_baseline` → re-read the installed version → bump. Prebump starts live CLIs and can open OAuth flows, so run it with the owner present.

| Group | Agents | Action |
|---|---|---|
| Driver works | Codex, Claude, Copilot, Antigravity, Cursor, OpenCode, OpenClaw, Pi | update CLI, then `./scripts/agent_watch.py --mode prebump --agent <a>` (add `--allow-real-home` for real-home agents). Codex and Claude only after Phase A and C |
| Driver failed 09-29 | Grok, Hermes | read the saved `stderr` from the failed prebump reports first. Classify per §1c (install, config, or account) before any retry. Do not update Hermes unless the one-shot run works |
| No driver | Cline, Qwen | Cline: build a driver (§1d) or stay at `supports_installed_only`. Qwen: blocked on a paid plan; owner decision, no engineering work |
| Nothing to do | Kimi, DeepSeek Harness | DeepSeek upstream is an alpha; leave the ceiling |

Then per bumped agent: `agent-support-matrix.yml`, a ledger entry, a line in `docs/agent-json-tracking.md`, and the `STEWARDS.md` "Last verified" cell (several rows are behind the matrix).

## 6. Phase E — stewards

- fx: upstream 0.0.13, matrix 0.0.7, `STEWARDS.md` says 0.0.5. Ask @thedavidweng to run `./scripts/steward_check.py fx`. Include the version gap in the ask. Fix the 0.0.5 / 0.0.7 mismatch.
- Devin: last check 2026-09-01. Not due. No upstream source is configured; add one if a release feed exists.

## 7. Phase F — price table (skill §2a, monthly)

Not run in this scan. Compare `docs/prices.json` and `RunwayPriceTable.bundledJSON` to the Anthropic and OpenAI pricing pages. List the model slugs the local Codex and Claude sessions emitted in the last 7 days and confirm each resolves to a key.

## 8. Verification and release

1. `./scripts/xcode_test_stable.sh`; read the total from the XCResult and explain any drop. The test host opens the real `index.db`.
2. Final weekly scan: both usage probes `ok`, no unknowns, verdicts as expected.
3. Release sizing: A1 is a script fix inside the app bundle. If the app is affected, ship it as a patch release. Fixture, matrix, and monitoring changes need no release.

## 9. Order and owner decisions

Order: A1 → A2 → Copilot `model.message` duplicate check → B → C → D → E → F.

Decisions needed from the owner:
1. Approve the Codex probe fix (A1) and whether it ships as a patch release.
2. Approve fixture and opaque-key changes (Phase C).
3. Which Phase B candidates to file now: Copilot usage and quota, Claude `thinkingDurationMs`, Claude `requestedModel`.
4. Cline driver: build or leave.
5. Send the fx steward ping.
