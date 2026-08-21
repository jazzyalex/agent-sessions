## 2026-08-21 14:31 · format-check-2026-08-21 · Format sweep closed — QA stamped, release-ready
status: done

**State:** Release QA PASSED (version 5.0.1; all five checks green: git scope, Debug xcodebuild, stable XCTest wrapper, Python release tests, warning sweep). Swift 2098/0 failures, Python 186/186. All 12 agents report `unknown_types=[]` / `unknown_keys={}`, 12/12 discovery contracts pass, every usage probe ok. Seven versions bumped; matrix, ledger and tracking log all updated. Both self-review findings were then fixed (matrix header refreshed to 5.0.1/2026-08-21; antigravity `truncated_fields` restored to the real `["content"]` discriminator) and QA re-run. **The QA stamp binds to the exact HEAD it ran against — re-run `tools/release/deploy qa` after any further commit or it no longer certifies `main`.**

**Decided / don't redo:**
- QA found two real problems that two passing test runs and three weekly scans did NOT. Do not treat a clean weekly + green tests as release-ready; run `deploy qa`.
- `test_grok_discovery_and_version.py` read the LIVE matrix (agent_watch reads it from a hardcoded path), so bumping grok broke an unrelated test. Now pinned via `_read_verified_versions_from_matrix` — keyed by MATRIX key (`grok_cli`), not the agent name.
- Codex fixtures can go stale MID-SWEEP: the sampled rollout was a live session still appending. It added `item.changes` + `item.action.pattern` after the fixture was rebuilt and the version bumped. Re-verify codex last, after the bumps.
- `item_completed.item.changes` is keyed by absolute file path but is ALREADY in codex's `_NESTED_OPAQUE_KEYS`, so it emits as `{}` — no user paths leak. Do not remove it from that set.
- Gemini fixtures + `testGeminiFixturesAreIgnoredAfterAntigravityMigration` + the `scan_tool_formats.py` skip are RETAINED on purpose (live guard; 8 real Gemini sessions still under `~/.gemini/tmp/*/chats/`). Documented in the test.
- A new fixture file is invisible until its path is added to `evidence_fixtures` in the matrix — the baseline is that list, not the directory.
- `rebuild_stage0_baseline.py` ignores `db_roots` (swept the wrong OpenCode store) and cannot see sandboxed kimi prebump sessions. Filed in `docs/backlog.md`.

- Both self-review findings are CLOSED. The matrix header is the file a reader consults to identify the current snapshot; it was claiming `5.0-unreleased` after v5.0/v5.0.1 shipped. The antigravity `truncated_fields` placeholder was worse than cosmetic: the GENERIC record falls to the `default:` branch which calls `markTruncated`, so a redacted discriminator silently asserted the UNMARKED path. Redaction must preserve field-name discriminators, not just `type`/`role`/`subtype`/`model`.

**Key files:**
- `docs/agent-support/agent-support-ledger.yml` — newest entry has the full per-agent reasoning
- `docs/backlog.md` — 7 new entries (6 value-pass candidates + the rebuild-tool blind spot)

**Next:**
1. Do NOT install Hermes 0.20.5 (no one-shot to regenerate a session → would regress 0.17.0 to `blocked_stale_sample`). Qwen stays blocked on a paid plan.
2. Backlog candidates are filed but unimplemented — codex `memory_citation`/`parsed_cmd`, claude `bridge-session`, kimi `agentId`/`token_counting.*`.

## 2026-08-21 13:47 · format-check-2026-08-21 · Weekly format sweep + Gemini CLI removal
status: superseded-by:2026-08-21 14:31

**State:** Pushed `be348726` on main (two commits). Weekly `agent_watch` scan covered all 12 monitored agents — discovery contracts 12/12, usage probes all ok, all drift additive and parse-safe. Gemini CLI removed from the skills/scripts and uninstalled from the machine. Six value-pass entries filed in `docs/backlog.md`.

**Decided / don't redo:**
- `~/.gemini` is SHARED with Antigravity (`agy` reads `~/.gemini/config/`, `config/mcp_config.json`, `config/hooks.json`, `config/projects/`, `antigravity-cli/settings.json`). Only the npm app `@google/gemini-cli` was removed. Never delete that tree.
- `scan_tool_formats.py`'s `agent == "gemini"` skip stays until the gemini fixtures go — removing it while they exist ADDS scanning.
- Antigravity `truncated_fields` is already handled (`AntigravityTranscriptParser.swift:43`); it's a JSON array in all 39 records. Fixture gap only, not a UI gap — don't re-open it as one.
- Gemini CLI was dropped from the app 2026-06-24 on purpose; its presence on disk was not a monitoring miss.
- Deleted root `GEMINI.md` (stale: claimed 4 agents, listed Gemini CLI, cited the dropped Git Context Inspector). Safe because `agy` treats `GEMINI.md` and `AGENTS.md` as interchangeable rules files and the FS is case-insensitive, so Antigravity now falls through to the real `agents.md` playbook instead of a stale duplicate.
- No new agents missed: 12 monitored = matrix = public-agents = STEWARDS; droid is legacy-only by design; fx (#59) + Devin (#56) still unmerged.

**Key files:**
- `scripts/probe_scan_output/agent_watch/20260821-202239Z/report.json` — the weekly evidence
- `scripts/probe_scan_output/agent_watch/20260821-202457Z-prebump/report.json` — copilot clean, kimi drift
- `docs/backlog.md` — the six new entries, stamped `verified 2026-08-21`

**Next:**
1. Bump versions backed by today's evidence: grok 1.0.4→1.0.5, copilot 1.0.79→1.0.80 (matrix + ledger + `docs/agent-json-tracking.md`, §6).
2. Refresh fixtures for the five drift agents (codex 0.149 `item_completed`, claude 5 new types, opencode `part.patch`, antigravity `truncated_fields`, kimi `agentId`/`token_counting.*`), then re-run weekly.
3. Clear the gemini leftovers together: `Resources/Fixtures/stage0/agents/gemini/`, `Stage0GoldenFixturesTests.swift:285`, the `scan_tool_formats.py` skip — needs a build + test run.
4. Do NOT install Hermes 0.20.5 — no working one-shot to regenerate a session, so it would regress 0.17.0 to `blocked_stale_sample` (§1b). Qwen stays blocked on a paid plan.

## 2026-08-21 13:21 · db-source-liveness · OpenCode/Hermes/Copilot session fixes shipped
status: done

**State:** Committed + pushed `46d6110c` on main: real session IDs in OpenCode/Copilot toolbar, WAL-aware focused-session monitor + DB row probes so live OpenCode/Hermes sessions re-hydrate, subagent reports unwrapped (OpenCode `task`, Hermes `delegate_task`, Qwen `{"output"}`), OpenClaw copy-ID prefix strip, Pi subagent nesting, Cursor store.db tick waste removed. Full suite 2098/0. Owner has a fresh Debug build running for visual QA.

**Decided / don't redo:**
- OpenCode cannot get a CLI/Desktop badge: both clients share `opencode.db` and nothing stamps the client; desktop's `.dat` map only proves "opened in Desktop". Don't build on it.
- Hermes tool rows have an EMPTY `tool_name` on disk — never gate Hermes tool handling on the name; gate on payload shape.
- `task` cards keep the 20-line "Show all" fold on purpose (consistent with other tool cards).
- Search ingest has no parser-version stamp; unwrap fixes improve search text only for sessions reindexed after the change (noted in backlog).

**Key files:**
- `AgentSessions/Services/UnifiedSessionIndexer.swift` `fileSignature` — `-wal/-shm` fold; the gate every DB-backed source depends on
- `AgentSessions/Services/HermesSessionIndexer.swift` / `OpenCodeSessionIndexer.swift` — pre-parse freshness probes
- `docs/backlog.md` → "OpenCode parent sessions are unsearchable for their own subagent reports"

**Next:**
1. Owner visual QA: Copilot ID chip; OpenCode live session grows while selected; Qwen/Hermes tool cards show plain text.
2. If QA passes, consider a 5.0.2 patch release (user-visible OpenCode regressions since v1.2 SQLite backend).

## 2026-08-18 16:22 · grok-review-round-two · External review acted on; 5.0.1 shipped
status: done

**State:** Grok reviewed the day's resume/provenance work; 4 of its 5 findings held and are fixed. **5.0.1 (build 69) is live and verified** — `deploy verify 5.0.1`: 0 errors, 0 warnings. GitHub release, appcast on Pages, Homebrew cask, tags local+remote. Both notarization submissions Accepted, both artifacts stapled. Suite at ship: 2094 tests / 3 skipped / 0 failures. Issue #58 was already closed by the owner; a "shipped in 5.0.1" follow-up is posted.

**Decided / don't redo:**
- **Refuted, don't "fix" it:** `waitForExit()` is this repo's `BoundedProcessWait` (10s → SIGTERM → SIGKILL), not Foundation's. Grok read the call site and assumed the stdlib. There is no unbounded probe wait.
- Qwen's custom-path branch needed *both* a capability guard and a load-time heal — the guard alone changes nothing, since the plan returned nil either way. `warmResolvedBinaryPathIfNeeded` now also warms a custom path; nothing else ever reprobes one.
- `versionManagerPrefixes` reads nvm/fnm default aliases from disk. The pty fix for `[ -t 0 ]`-guarded rc files is **parked** in `docs/backlog.md`, not wanted before someone hits it.
- The login-shell reorder saves a spawn only when the CLI runs on the inherited PATH. Finder-launched Node CLIs still spawn one via `run()`'s widening — do not claim otherwise in release copy.
- Two of my own 5.0-era tests were vacuous, proved by mutation: deleting Pi's reader guard leaves both green. Seed `UserDefaults` directly to reach that guard.

**Key files:**
- `AgentSessions/Qwen/QwenSettings.swift` — load-time heal + custom-path warm
- `AgentSessions/Indexing/DB.swift` — `upsertSessionMeta` now COALESCEs all six provenance columns
- `AgentSessions/Resume/CLIProbeEnvironment.swift` — `versionManagerPrefixes`

**Also settled during the release:**
- The generated Sparkle notes came out as full changelog prose again — the 5.0 mistake. Fixed at the source (`docs/CHANGELOG.md`), not in the notes: 5.0.1's section is now six one-to-three-sentence bullets, ~210 words. The rest of the preview is the auto-generated 5.0 reminder, deliberately left as shipped history.
- `docs/_preview/` is now gitignored — release QA demands a clean tree and those are local page mockups, not release content.
- A patch release needs no new `WhatsNewCatalog` entry: it is keyed by major.minor, so 5.0's entry covers 5.0.1.

**Next:**
1. Owner manual checks: Sparkle auto-update from 5.0, clean-machine Gatekeeper, `brew upgrade agent-sessions`.
2. PR #56 (Devin CLI source) is still open and untouched — owner declined to act on it this session.
3. Backlog candidates: the cooldown-lockout entry, and the pty-based CLI discovery entry filed today.

## 2026-08-18 14:52 · finder-path-resume + codex-provenance · #58 fixed for four agents; Codex surface stopped being erased
status: done

**State:** Ten code commits on `main` (`7d8f4feb`…`469dd5f2`), pushed, tree clean, suite **2089 tests / 3 skipped / 0 failures**. Two separate programs landed:

1. **Issue #58 — resume dies when the app is launched from Finder.** LaunchServices hands the app `PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin`, so a `#!/usr/bin/env node` CLI in `/opt/homebrew/bin` exits 127. New shared `AgentSessions/Resume/CLIProbeEnvironment.swift` owns login-shell PATH discovery (one `$SHELL -lic` per probe, sentinel-marked, stdout only), lazy widening (inherited env first, widen only on a non-zero exit), flag matching, `which`, and the did-not-execute rule. Pi/Kimi/Qwen/Grok all route through it (−146/+53 across the four). Cache side: a probe that could not execute reported a real binary with every capability false, and the cache only refreshes while the resolved path is empty — so one bad probe disabled resume forever. Both writer and reader now reject a capability-free entry, which heals what 5.0 already wrote.
2. **Codex surface attribution.** `classifyCodexSurface` reordered so `source: cli|exec` wins over the pinned `originator: "Codex Desktop"` (161 sessions reclassified); side chats derive provenance from the parent rollout instead of hardcoding Desktop; the side-chat pill reads `side`, not `desk`.

**Decided / don't redo:**
- **`source: "vscode"` is NOT proof of VS Code** — 76 such rollouts sit in Codex Desktop's own generated `~/Documents/Codex/<date>/<name>` workspaces. Only `cli`/`exec` were promoted. Backlog entry rewritten accordingly (sev med / urg low, verified 2026-08-18).
- **`Process.environment = nil` empties the child, it does not inherit.** Foundation-verified with a standalone probe: untouched → full login PATH; nil → `/usr/gnu/bin:/usr/local/bin:/bin:/usr/bin:.`. `CommandExecutor` guards the write (`if let environment`). A mock executor cannot catch this — test against a real `Process`. Caught by external review, not by me; nearly shipped as a repo-wide PATH regression.
- **Retry breadth stays broad** in `CLIProbeEnvironment.run` — it widens on any non-zero exit, not just 126/127. pi/kimi/qwen/grok all exit 0 for both `--help` and `--version`; the real failure is 127. Narrowing buys nothing any current agent needs and costs the safety margin.
- **Issue #58 stays OPEN on purpose.** Fixed on `main`, not released; closing now tells the reporter to go try a build that does not exist.
- **5.0.1 in the next few days, not a hotfix today.** Codex/Claude were never affected (both probe via `$SHELL -lic`); Pi resume landed 2026-05-12 so this is not a 5.0 regression; poisoned caches self-heal. The one argument for moving soon is that Qwen was 5.0's headline agent and its resume was broken for the default launch method.
- **The projectless-thread store has zero overlap with the reclassified sessions** — `~/.codex/.codex-global-state.json` holds 66 `projectless-thread-ids`; of 231 cli/exec-sourced rollouts, **0** appear there. No session's "Codex Desktop Chats" project label moved.
- **Gemini Flash is a changelog generator, not a reviewer.** Zero findings, "all 8 commits" when there were 15, two wrong code citations, stale test count. Grok found the `Process.environment` defect nobody had described. Keep Grok in the review slot.

**Root cause worth keeping (only in `469dd5f2`'s message otherwise):** `SearchIngestService` omitted provenance from `SessionMetaRow` while `upsertSessionMeta` assigned the `codex_*` columns unconditionally — every ingest pass wiped what the indexer had written (3,568 of 3,578 rows had NULL surface). Fixed by carrying the already-parsed values (zero extra I/O), `COALESCE` on both upserts, and a one-time `codex_provenance_reindex_v1` migration. Post-fix: subagent 993, desktop 466, cli 231, vscode 45 — all 1,735 Codex rows carry surface.

**Second round, from an external Grok review (uncommitted at time of writing):** four of its five findings held. (1) Qwen's *custom-path* branch skipped the capability guard — #58's failure mode surviving in one corner; healed at load now, and `warmResolvedBinaryPathIfNeeded` warms a custom path too, since nothing else ever reprobes one. (2) `upsertSessionMeta` still assigned `originator`/`origin_source`/`surface` unconditionally while `upsertSessionMetaCore` COALESCEd them — the same defect I had just fixed for `codex_*`, left half-applied. (3) An rc file guarded on `[ -t 0 ]` defeats discovery (the probe shell's stdin is a pipe; verified); `versionManagerPrefixes` now reads nvm's `~/.nvm/alias/default` and fnm's default alias from disk, and the pty fix is filed in `docs/backlog.md`. (4) Two of my own tests were vacuous — proved by mutation: deleting Pi's reader guard leaves both old tests green and kills only the new seeded-`UserDefaults` one. **Refuted:** "no timeout" — `waitForExit()` is `BoundedProcessWait`, 10s then SIGTERM/SIGKILL, not Foundation's. Suite 2094/3 skipped/0 failures.

**Next:**
1. Cut **5.0.1** (Finder-PATH fix + the Codex provenance repairs + the round-two fixes above). Not started — awaiting owner go.
2. Decide whether the cooldown-lockout backlog entry ("Transient-failure cooldowns lock out both live sources with no reachable bypass", `docs/backlog.md`) rides along with 5.0.1. Recommended; undecided.
3. Close **#58** when 5.0.1 ships.

## 2026-08-18 09:32 · release-5.0-notes · Sparkle notes republished short; skill rule added
status: done

**State:** 5.0 live and healthy. The shipped Sparkle/GitHub notes were full changelog prose; rewritten to ~250 words with some personality, republished into `docs/appcast.xml` + the v5.0 GitHub release, committed and pushed (`1912cad2`).

**Decided / don't redo:**
- Sparkle notes are SHORT: highlights 2–4 sentences, bullets 1–2, ~250-word cap, dry fun allowed, absolute links only. Hard rule + republish recipe now live in `.claude/skills/deploy/SKILL.md` ("Sparkle Notes Are Short and Fun").
- Changelog entries feed the notes verbatim — overweight changelog entries get tightened in `docs/CHANGELOG.md` first, not worked around.

**Next:**
1. Owner manual checks: Sparkle auto-update from 4.8 (now shows the short notes), clean-machine Gatekeeper, `brew upgrade agent-sessions`.
2. Watch #57 (Grok Build) / PR #56 (Devin) for replies to the contribute-or-steward invitations; post the drafted stewards-wanted issue when ready.
3. 5.0 launch post + steward site pages (Marketing/STATUS.md first); Qwen paid-plan decision for 0.21.x verification.

## 2026-08-17 20:13 · release-5.0 · 5.0 shipped: adapter architecture, Qwen, steward program
status: done

**State:** 5.0 live and verified (`deploy verify 5.0`: 0 errors/warnings) — GitHub release v5.0 (build 68), appcast, Homebrew. Suite at ship: 2093 + 186 script tests, 0 failures. Headline: agents are plug-in adapters (26→12 shared-file edits per new agent, measured on PR #56); Qwen Code is the thirteenth source (verified vs 0.14.3 transcripts — 0.21.x needs a paid Qwen plan); contribute-an-agent card + steward program shipped.

**Decided / don't redo:**
- Steward (not "maintainer") = per-agent format re-verifier; STEWARDS.md is the record, `./scripts/steward_check.py <agent>` is the one command (redacted sample, withheld on any leak-scan hit). Labels `steward`/`steward-wanted` exist; the prepared pinned issue (docs/superpowers/plans/2026-08-17-stewards-wanted-ISSUE.md) is NOT posted — owner said skip for now.
- Invitations posted: issue #57 (Grok Build, rodion-m) and PR #56 (Devin, thedavidweng) — contribute-or-steward, both link the guide.
- Grok parser is dictionary-tolerant now (last Codable gone); contribute card: full body always visible, statement titles everywhere ("Leave a star if this helps", "Help make Agent Sessions better", "Help add your agent").
- Release copy leads with the adapter architecture, never "shared foundation"; pre-release fixes stayed folded per the 4.8 rule.

**Next:**
1. Manual post-release checks only the owner can do: Sparkle auto-update from 4.8, clean-machine Gatekeeper, `brew upgrade agent-sessions`.
2. Watch #57/#56 replies; post the stewards-wanted issue when ready.
3. Steward program Track 3 (site tier badges + become-a-steward page) and the 5.0 launch post — Marketing/STATUS.md first.
4. Backlog: "Registry program follow-ups" entry (6 items) + preserved-behavior rulings; Qwen paid-plan decision for 0.21.x verification.

## 2026-08-16 20:28 · session-source-registry · Registry program complete, approved for owner QA
status: done

**State:** All 10 tasks (0–9) of the session-source registry refactor are implemented, task-reviewed, and committed on `main` (`0e2cb747..48276c72`, 11 commits, 57 files, +4662/−2411). Final whole-branch review (Fable): **approved for QA, 0 must-fix**. Suite: 1949 + 55 logic tests, 0 failures. Proof: PR #56 dry-run — 26 shared files → 12 (shared Swift 22 → 8, wiring-tax 14 → 0).

**Decided / don't redo:**
- Two behavior widenings accepted pending owner sign-off: §8.3 also removes the launch-time `analyticsIsStale` flag (phantom openclaw flip, strictly corrective); Task 8's enablement reads converge upgrade installs on the registry rule (views were the last holdout; pills were already inert for that cohort).
- PreferencesTab title/icon stay hand-written on purpose — deriving changes 4 rendered values; needs a new descriptor field + goldens if ever wanted.
- Two hand lists survive by design, test-enforced: `SessionSourceRegistry.ordered`, `PreferencesTab.sidebarAgentSources`.
- Six follow-up residues filed in `docs/backlog.md` → "Registry program follow-ups"; three preserved behaviors (OpenCode refresh, hidden droid pane, kimi/grok cwd) filed as their own entry awaiting owner rulings.

**Key files:**
- `docs/adding-a-session-source.md` — THE contributor guide (29 edit rows, 10 sentinels), review-verified against code
- `docs/superpowers/plans/2026-08-14-session-source-registry-SPEC.md` — K1–K16 + dated §6.A′ amendment
- `AgentSessions/Services/SessionProviderCatalog.swift` — the one lifecycle owner (K16: publishes nothing)

**Next:**
1. Owner batched visual QA: source toggles + "Sources ready" indicator (§8.1–8.3), onboarding "N sessions found", column toggle, Antigravity stale/unreadable affordances, pills/colors/shortcuts, sidebar (droid hidden), droid/openclaw resume menus, launch-time feel (eager 12-runtime init).
2. Owner sign-off on the two accepted widenings above.
3. At next `deploy bump`: §8.1–8.5 are user-visible fixes — they belong in the CHANGELOG/What's New then (nothing owed on-branch).

## 2026-08-14 13:55 · release-4.8 · 4.8 shipped, then release notes corrected twice
status: done

**State:** 4.8 live and verified (`deploy verify 4.8`: 0 errors/warnings) — GitHub release, appcast on Pages, Homebrew cask, tag `v4.8`, build 67. Post-release corrections pushed through `2099ab89`. Tree clean, 1904 Swift + 172 python tests green.

**Decided / don't redo:**
- **Pre-release fixes to a feature shipping in the same release are NOT Bug Fixes.** 4.8's notes initially listed four Grok defects users never had. Removed from changelog, appcast, GitHub release body and README. Now a hard rule with a worked example in `.claude/skills/deploy/SKILL.md`.
- **Session-Bench is not an AS feature** — the v0.3 poster was wrongly filed under Improvements. Removed; wants an in-app **chip**, backlogged.
- Three review findings fixed pre-ship, all mutation-tested: monitoring false-clean on a lost Grok `summary.json` (worse than reported — sibling-union sampling left *zero* trace), image line-vs-event mis-placement (live but hidden by luck — the one real attachment sits in the only local Grok session with zero drift; 12 of 13 drift), and the unused authoritative Grok version (reconciles by **max**, never replace — a CLI answers only for its pinned channel).
- The two copies of the nearest-user rule are now **one** (`ImageUserTurnResolver`); mutating it fails both surfaces. Antigravity's empty-session fallback is preserved as a flag, not smoothed away.
- `_md_inline_html` never rendered markdown links — the panel showed raw `[@name](url)` on contributor credits. Fixed. Only 4.8 was affected in the appcast (my "every past release" claim was wrong).
- In-app What's New needs a per-version entry; `hasContent` goes true on the auto-generated provider row alone, so a forgotten release ships one generic line. Never author a row for a new source by hand — `providerHighlights(for:)` already generates it.

**Key files:**
- `AgentSessions/Utilities/CodexSessionImagePayload.swift` — `GrokImageUserTurns` + `ImageUserTurnResolver`, both image surfaces call them
- `.claude/skills/deploy/SKILL.md` — the "Never Announce a Bug the User Never Had" rule + What's New checklist item
- `docs/agent-support/agent-watch-config.json` — `required_companion_files` on `discovery_path_contract`
- `AgentSessions/Onboarding/Models/WhatsNewCatalog.swift` — 4.8 teaser + bundled entries

**Next:**
1. Manual post-release checks only I can't do: Sparkle auto-update from 4.7, clean-machine Gatekeeper, `brew upgrade agent-sessions`.
2. Backlog, newest first: Session-Bench in-app chip; inert image extraction for Kimi/Pi/Hermes/Cursor.
3. Optional: `f3ea6f90` swept the owner's Cross-Surface Session Storage backlog section into my commit — offered to split it out, would need a rewrite of a pushed commit.
4. Session-source registry refactor — still the next real task, unchanged since 2026-08-13.

## 2026-08-13 15:56 · test-hermeticity · Presence seam verified, then the same defect fixed in four more tests
status: done

**State:** Merge `7293faf9` (hermetic PresenceEngine discovery) verified — test target compiled for the first time, 7 consecutive clean runs. Then fixed the same class of defect in the four tests that failed for an outside contributor. Committed `d97d4df1` + `e6fc8212`, pushed.

**Decided / don't redo:**
- **The 15:32 grok-source entry above is stale on one point:** `PresenceEngineTests`/`PresenceEngineRegressionTests` no longer fail on clean `main`. 21/21 isolated (3x) and 1894 full-suite (2x), with live `claude` CLI sessions writing transcripts throughout — the condition that used to break them.
- **CI green proved nothing about these tests.** The scheme's BuildAction holds only `AgentSessions.app`, so `xcodebuild build` never compiled the test target. Use `build-for-testing` to get a real compile signal.
- **`AgentEnablement`'s defect was not the filesystem** — `AppRuntime.isHostedByTooling` is true whenever `isRunningTests`, so `binaryInstalled(for:)` is a `UserDefaults` read under XCTest. The test named for `claude-code` name matching never reached that logic; it passed on a stored `ClaudeCLIAvailable`. Its PATH/temp-dir setup was dead code. Use `binaryInstalled(for:pathOverride:)` in tests.
- **Two tests asserted nothing meaningful** before this; the hyphen one said so in its own comment and fell back to re-testing `/tmp`.
- `~/.codex/active` was empty for every run, so the Codex runway root is untested-under-load (unread in tests either way, via the seam).

**Key files:**
- `AgentSessions/Support/FileProbing.swift` — new shared seam, counterpart to `PresenceRootsResolving`; `DefaultFileProbe` = `FileManager.default`, all params defaulted, production behavior unchanged
- `AgentSessionsTests/FakeFileProbe.swift` — file-scope + `Sendable` with no actor isolation, same reason as `PresenceFixtureRoots`
- `AgentSessions/Services/AgentEnablement.swift` — `binaryInstalled(for:pathOverride:)` skips both the tooling gate and the PATH cache; `.grok` still reads real `~/.grok`, so don't assert `.grok` hermetically through it

**Next:**
1. Session-source registry refactor (increments 1–6) — unchanged, still the next real task.
2. Optional: extend `FileProbing` to `.grok`'s home lookup if a hermetic Grok availability test is ever wanted.
3. Watch for the same defect shape when wiring new sources — production code branching on `fileExists`/`isExecutableFile` with no seam.

## 2026-08-13 15:32 · grok-source · Grok CLI merged, then fixed against real sessions

status: in-progress

**State:** PR #55 (Grok CLI, contributor `thedavidweng`) merged and hardened against real 1.0.3 sessions; all work pushed through `b68f1710`, tree clean. PR #56 (Devin) still open and deliberately not taken.

**Decided / don't redo:**
- **Every bug this session was a hand-maintained per-source list the compiler can't check** — a `Set`, an array literal, an `&&` chain, or a `default:` arm. Twelve instances. Every exhaustive `switch` was already correct. When wiring a new source, hunt for `default:` and array literals, not switches.
- **Grok's subagent parentage is in the PARENT's tree**, `<parent>/subagents/<childId>/meta.json` — the child's `summary.json` has no `parent_session_id`. Don't look in the child.
- **Grok flattens delegation** — a subagent asked to delegate produced more subagents under the root, none owning their own `subagents/`. One-level lookup is correct; don't build chain-walking.
- **`grok sessions list` hides subagents**; Agent Sessions surfaces them. Not a discrepancy — a capability.
- **Registry refactor is planned, not started.** Do it before taking #56 (Devin's shared 5.4 GB SQLite store breaks archive-by-path and search-by-path). Plan + descriptor draft committed under `docs/superpowers/plans/2026-08-13-session-source-registry-*`.
- `PresenceEngineTests`/`PresenceEngineRegressionTests` fail on clean `main` (12–14, count drifts per run) — environment-coupled, proven by stash-and-rerun, owned by a separate spun-off session. Not caused by this work.
- Analytics now rolls up **every** source (`allCases`); Cursor and OpenClaw were excluded by omission, not design.

**Key files:**
- `AgentSessions/Services/GrokSessionDiscovery.swift` — `subagentLink(forSessionID:inBucket:)`, the sideways parentage lookup
- `AgentSessions/Model/Session.swift` — `storesAuthoritativeLightweightTitle` (Grok-only; sidecar owns the title)
- `AgentSessions/Utilities/CodexSessionImagePayload.swift` — 3 of the 4 image gates; all now exhaustive
- `docs/agent-support/agent-support-matrix.yml` — records what is still **unexercised**: the truncated-preview count fallback (no session has hit the 200-line cap; largest 167) and the `compaction/` subtree

**Next:**
1. Session-source registry refactor — increments 1–6 in the plan doc; target is "new source = one folder + one registry entry".
2. Rebase and merge PR #56 (Devin) onto the registry shape; do the rebase yourself rather than asking the contributor.
3. Backlog: inline images lost their right-click menu everywhere (`docs/backlog.md`, top entry) — needs its own bisect, not caused by the image work.
4. Unverified: image extraction for Kimi/Pi/Hermes/Cursor is wired on an assumption — no local session for any of them contains a `data:image/` URI.

## 2026-08-04 10:35 · agent-session-formats-check · Full format check: parser + pricing fixes, and a rebuilt monitor

status: in-progress

**State:** Full 10-agent session-format check done and merged to `main` (`b5bd45d2` merge + `fcc446f8`). Weekly reports no drift on any agent; 1837 Swift + 135 python tests green. Verified: Codex 0.146.0, Claude 2.1.220, OpenCode 1.18.11, Pi 0.83.0, Copilot 1.0.77. *(Pushed since this was written, and shipped in 4.7 — the parser and pricing fixes from this check are in that release.)*

**Decided / don't redo:**
- **`attachment:date_change` and the `queued_command` keys were NEVER upstream drift.** They predate the verified versions (2026-07-09 / 2026-07-06); the fixture was just incomplete. Don't re-open as a Claude regression.
- **Never build a fixture from ~5 recent sessions** — rare families are missed by construction (Claude covered 11/24 attachment subtypes). Use `scripts/rebuild_stage0_baseline.py`, and **read its report before `--emit`**: that step caught `collab_waiting_end.statuses` (keyed by thread UUID) and `system.error.headers` (keyed by HTTP header, carries `set-cookie`) before they reached committed fixtures.
- **OpenClaw prebump needs a fresh sign-in, not a retry** — it shares the Codex OAuth token store; sandbox gives `missing-provider-auth`, real HOME gives `refresh_token_reused` 401.
- Copilot's driver was broken by a deprecated `--config-dir` *and* a credential file (`~/.copilot/hosts.json`) that no longer exists; it now uses `COPILOT_HOME` + a `gh auth token` fallback.
- Prebump passing is a floor, not a ceiling — its one-line prompt yields ~4 event types. A `--allow-real-home` prebump session once masked real antigravity drift by becoming the newest sample.

**Key files:**
- `scripts/rebuild_stage0_baseline.py` — full-sweep baseline rebuilder (report → review → `--emit`)
- `scripts/agent_watch.py` — nested fingerprinting, `_NESTED_OPAQUE_KEYS`, 5-session union, `blocked_thin_sample`
- `skills/agent-session-format-check/SKILL.md` §5a — what the fingerprint can and cannot see

**Next:**
1. ~~Push `main`~~ — done, and shipped in 4.7.
2. OpenClaw: fresh sign-in, then prebump → bump 2026.6.11 → 2026.7.1.
3. Antigravity: generate one tool-using session under 1.1.10, then bump 1.1.1 → 1.1.10.
4. Re-price check due ~2026-08-14 (rates last verified 2026-07-14; `codex-auto-review` was a missing-key fix, not a re-pricing).
5. Untracked `docs/superpowers/specs/2026-08-04-agent-format-comparison-post-design.md` is **not mine** — left untouched.

## 2026-08-03 12:41 · star-ask-agent-watch · Two stale branches reviewed, salvaged, and retired
status: done

**State:** 13 commits on `main`, pushed (`1998dbf9..9a36dcd7`). Full suite green. Branches `star-ask` and `auto/launch-kit` deleted — both fully absorbed or dead, nothing left to recover. This also pushed the three unpushed Kimi commits from the 11:03 entry.

**Decided / don't redo:**
- **`auto/launch-kit`'s transcript commits were already in main** — `InlineImageThumbnailGridView.swift` on the branch was byte-identical to main's copy (landed as `b392f48b` the same day). Its "conflicts" in `TranscriptBlockListView`/`TranscriptPlainView`/`MarkdownBodyRenderer` were pure staleness; merging would have *deleted* 600+/241/237 lines. Only `launch-kit/` was worth taking.
- **The star-ask README rewrite was dropped on purpose.** It repositions the product back to session-history-first; main leads with the Quota Meter. Both "unbacked claim" fixes in it were moot — those sentences were introduced *and* fixed inside the branch's own rewrite and never existed in main. Only the star CTA carried over.
- **`starAskOutranksQuotaMeterCard()` is NOT dead code** — it looks unreferenced from the view but is wired via a guard at the top of `shouldShowQuotaMeterCard()`. Checked; don't "fix" it.
- **`run-weekly.sh`'s `[ -n "$token" ] && export ...` does not abort under `set -e`** — the failing test isn't the last command of the AND-list, so `-e` exempts it. Verified empirically; don't re-flag.
- Launch-kit numbers re-pulled from the GitHub API (674→750 stars, 9,240→11,431 downloads, 9→10 sources). Growth-cadence claim *survived* verification (133 Mar / 100 Apr / 78 May / 80 Jun / 76 Jul), so "~80/mo since" stands. `~700 WAU` still unverifiable, flagged in `launch-kit/REPORT.md`.

**Key files:**
- `scripts/agent_watch.py` — token now via 0600 curl config, never argv; `_run_cmd` strips `GITHUB_TOKEN`/`GH_TOKEN` from every spawned agent CLI
- `tools/agent-watch/` — weekly launchd job + `tests/test_token_hygiene.sh` (9/9), `tests/test_install.sh` (10/10)
- `AgentSessions/Onboarding/Models/OnboardingCoordinator.swift` — star-ask state machine; ceiling is 6 impressions total whatever the user does
- `scripts/xcode_add_file.rb` — now self-pins UTF-8; a correct run adds exactly 4 pbxproj lines (good sanity check)

**Next:**
1. Nothing outstanding. The weekly agent-watch LaunchAgent is committed but **not installed** — run `tools/agent-watch/install.sh` if you want it actually scheduled.
2. Optional, carried over from 11:03: the five missing `.onChange` observers + Kimi filter pill (`docs/backlog.md` → "Agent Source Plumbing").

## 2026-08-03 11:03 · kimi-sessions-list-plumbing · Kimi made searchable; enablement notice fixed (committed, unpushed)
status: done

**State:** Three commits on `main`, unpushed: `f23c4cf7` (fix), `3e44b673` (backlog), `1ac08fb0` (two parallel-session handover entries). Suite 1786/0/3 green.

**Decided / don't redo:**
- The reported bug (`kimiAgentEnabled` missing from the notice's `&&` chain) was **not the whole fix** — nothing observed the flag either, so the corrected predicate never ran. Both the chain and a `.onChange` were needed.
- Bigger find in the same region: `SearchCoordinator.start` had **no `includeKimi` parameter at all**, so `.kimi` never entered the allowed source set and Kimi was absent from every search result since it shipped. Fixed + regression-tested.
- Kimi **is** FTS-ingested (`SearchIngestService.parseFileFull` has a `.kimi` arm; the ingest driver is source-generic), so unlike Cursor it needs **no** exclusion from the FTS allow-list. Checked — don't re-litigate.
- Regression test verified non-vacuous: removing `set.insert(.kimi)` makes it fail with `Got []`.
- Deliberately left out of scope: the notice is still unobserved for `hermes`, `droid`, `openClaw`, `cursor`, `pi`, and Kimi still has no filter pill in `enabledOtherAgentSpecs`. Both recorded in the backlog, not bugs to rediscover.

**Key files:**
- `AgentSessions/Views/UnifiedSessionsView.swift` — notice chain + `onChange` block + the two `@AppStorage` enablement blocks
- `AgentSessions/Search/SearchCoordinator.swift` — `start()`'s per-source `Bool` list → `allowed: Set<SessionSource>`
- `docs/backlog.md` → "Agent Source Plumbing" — the refactor that stops this recurring

**Next:**
1. Push the three commits.
2. Optional, pre-approved shape: add the five missing `.onChange` observers and Kimi's filter pill (`shortcut: nil`, 1–9 are taken).
3. The Apple Development cert was renewed at 10:39, so the `CODE_SIGN_IDENTITY="-"` override is no longer needed.

## 2026-08-03 10:39 · signing-identity-expiry · Apple Development cert expiry diagnosed + renewed; derived data purged
status: done

**State:** Signing is fully restored on `main`. Renewed Apple Development cert `EE5E303C…` verified through the standard no-override test command (1786 tests, 3 skipped, 0 failures), binary signed `Authority=Apple Development: Alexander Malakhov (H8VKVRRMC3)`, `TeamIdentifier=24NDRU35WD`, satisfies its Designated Requirement. Two expired identities purged; all twelve `.deriveddata-*` dirs deleted (7.3 GB).

**Decided / don't redo:**
- **"Certs present but no private keys" was a misdiagnosis.** `security find-identity` only ever lists cert+key *pairs* — if an expired cert appears at all, its key is intact. Run without `-v` and read the reason (`CSSMERR_TP_CERT_EXPIRED`). Fix is renew, never hunt for a lost `.p12`.
- **Expired dev cert never blocks a release.** Only Debug uses Apple Development. Release is committed as `CODE_SIGN_IDENTITY = "-"` / Manual (since `e927fef0`), built ad-hoc then deep-re-signed with Developer ID by `tools/release/build_sign_notarize_release.sh:142`. Developer ID valid to 2027-02-01.
- Root cause of "Failed to retrieve development teams" was simply **not being signed in to Xcode** — `com.apple.dt.Xcode` listed `alex@combil.com` with no portal token in any keychain. Not keychain damage; network was clean (200s across Apple endpoints).
- No provisioning profile is needed anywhere — `AgentSessions.entitlements` is an empty dict.
- Verified fallback if the dev cert lapses again: Debug builds clean under `CODE_SIGN_IDENTITY="Developer ID Application: Alex M (24NDRU35WD)" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=24NDRU35WD`, keeping a real TeamIdentifier and `get-task-allow`. Better than ad-hoc, whose unstable DR makes TCC re-key FDA every rebuild.

**Next:**
1. Next build is cold (all caches gone) and needs an **FDA re-grant** — the rebuilt `.deriveddata-manual` app will be Apple Development-signed, not the Developer ID signature the old grant was attached to.
2. Cert expires again ~2027-08-01. Captured in memory as `project_signing_identity_expiry`.
3. Optional tidy: `.gitignore:91-94` lists four paths already covered by the `.deriveddata-*/` glob on line 89, one of which (`.deriveddata-audit/`) no longer exists.
4. Uncommitted parallel work left untouched: `SearchCoordinator.swift`, `UnifiedSessionsView.swift`.

## 2026-08-03 10:34 · kimi-code-tier2 · Kimi Code shipped as 11th agent; loop-event defect fixed (pushed)
status: done

**State:** Kimi Code tier-2 support is on `origin/main` at `cea8cc0e` — discovery, parser, indexer, UI, copy-resume, weekly monitoring. Tree clean, 0 unpushed. Swift 1785/0/3, python 128/0, weekly scan `verified = installed = upstream = 0.31.1`, severity low.

**Decided / don't redo:**
- **Assistant output is NOT in `context.append_message`** — that carries user turns only. Everything the model produces (`content.part` text/think, `tool.call`, `tool.result`) arrives as `context.append_loop_event`. Reading only append_message rendered transcripts with user turns and nothing else. This is the single most important fact about the format.
- Two more source-vs-reality gaps: emitted `protocol_version` is **1.4** (source HEAD says 1.5), and `config.update` carries **`modelAlias`**, never a bare `model`. Verify against emitted journals, never against Kimi's TS types.
- Adding a JSONL agent to `agent_watch.py` is **not config-only** — four hardcoded maps need the name (`verified_map`, two `matrix_key` maps, the tuple in `_baseline_type_keys_for_agent`), or the scan silently degrades to "no baseline compared".
- **Do not replace `small.jsonl`** — it is the only fixture carrying `turn.cancel`, `turn.steer`, `permission.set_mode`; dropping them re-arms a resolved drift alert. The funded capture lives beside it as `assistant_tools.jsonl`.
- `minidb` is a derived read model behind a default-false flag — read `wire.jsonl`, never write a minidb reader. Kimi Desktop shares `~/.kimi-code/`, so it's a surface label, not a source.
- Three parallel worktrees were merged and deleted; their branches are gone. Nothing outstanding there.

**Key files:**
- `AgentSessions/Services/KimiSessionParser.swift` — loop-event mapping lives here
- `scripts/agent_watch.py` → `_kimi_wire_schema_fingerprint` — walks *into* loop events; a top-level fingerprint is blind to the whole renderable surface
- `docs/agent-json-tracking.md` → "Kimi Code" — the format memory bank
- `docs/backlog.md` → "Kimi Code" — the two deferred items

**Next:**
1. **Host blocker, not code:** no valid "Mac Development" signing identity (certs present, private keys missing). All verification used ad-hoc signing; a release/notarized build fails until it's restored in Xcode → Settings → Accounts.
2. Backlog: capture a media round-trip (`ReadMediaFile`) so the `image_url`/`audio_url`/`video_url` branches stop being unexercised.
3. Backlog: build a `kimi_prompt` prebump driver (`kimi -p` works) — but weekly real-session scanning stays the primary drift signal regardless.

## 2026-08-01 14:16 · claude-cloud-sessions-and-codex-meter · Cloud sessions in QM + Codex "reconnecting" fixed (pushed)
status: in-progress

**State:** Claude cloud sessions now render in the Quota Meter as runway rows showing "Cloud", and the Codex meter's permanent "reconnecting…" is fixed (owner-verified: Codex row populates with the app backgrounded). 25 commits pushed to origin/main (e881b78a..2d698b3f). Suite 1776/0/3.

**Decided / don't redo:**
- Cloud sessions leave ZERO local trace — no filesystem indexer can ever reach them. They ARE reachable at `GET claude.ai/v1/code/sessions` with `anthropic-version` / `anthropic-beta: ccr-byoc-2025-07-29` / `anthropic-client-feature: ccr` / `x-organization-uuid`. `/api/organizations/.../chat_conversations_v2` is the CHAT list and contains no code sessions — wrong namespace, don't retry it.
- Filter on `environment_kind == "anthropic_cloud"`, NOT the `cse_` prefix (all rows are `cse_`; 168 are `bridge`, which the local indexer already shows — verified).
- Presence = `status == active` AND (worker running OR `last_event_at` within 1h). `status == active` alone means only "not archived" — two sessions were idle 14h and 116 days.
- The pinned QM strip renders `RunwayPauseImpactRow` from the runway snapshot, NEVER raw `HUDRow`. Appending HUDRows renders nowhere — this cost ~6 rebuild cycles.
- Codex snapshot persistence (planned Task 3) was reviewed and DROPPED, not deferred — see plan for why.
- Tooling traps: os_log never reaches `log show` for this app; `strings` on the main binary is a 58KB stub (code is in `AgentSessions.debug.dylib`); curl is Cloudflare-403'd where URLSession gets 200. Use the DEBUG file write in `ClaudeCloudLiveModel.note()` for runtime evidence.
- Builds must be Developer-ID signed or the app is denied the claude.ai keychain item; tests need `CODE_SIGN_IDENTITY=- ... CODE_SIGN_ENTITLEMENTS=` (no Mac Development cert on this machine).

**Key files:**
- `AgentSessions/ClaudeCloud/` — client, catalog, live model, HUDRow mapper
- `AgentSessions/Views/AgentCockpitHUDView.swift` — `appendingClaudeCloudRows`, `cloudStatusLine`, runway slot budget
- `docs/superpowers/plans/2026-08-01-codex-meter-and-cloud-row-fixes.md` — task outcomes + why Task 3 was dropped
- `docs/backlog.md` — the three deferred items below

**Next:**
1. Decide the cloud-session SURFACE: presence badge on the Claude provider row vs runway rows. Owner questioned whether a rate-less row belongs in a consumption-ranked widget — likely right, since account quota already includes cloud usage. ~80 lines to switch; endpoint/filter/model unaffected.
2. Codex OAuth failure cooldown has no user-initiated bypass (30 min, `refreshNow` hits the same gate) — largest remaining real Codex defect.
3. Only if a Codex-side 429 is ever observed: make the `.idle` promotion reason-aware.

## 2026-07-22 13:09 · agent-format-check-2026-07-22 · Codex 0.145.0 verified; full format check + agent_watch hardening (pushed)
status: done

**State:** Triggered by "big change in Codex CLI session formats." Confirmed AS already supports Codex 0.145.0 — rollout JSONL unchanged; new `session_meta` fields (thread_source/session_id/structured source.subagent) parsed+tested; the state_5.sqlite thread index (now under `~/.codex/sqlite/`) is NOT read by AS. Ran full format check: **8 of 9 agents verified fresh**, 0 drift except Copilot (covered). All 4 commits pushed to origin/main (…→3b1a0cf0).

**Decided / don't redo:**
- Copilot 1.0.65 drift = two additive event types (`session.auto_mode_resolved`, `session.usage_checkpoint`); non-breaking (parser default→.meta). Covered in copilot schema_drift fixture + `testCopilotAutoModeAndUsageCheckpointEventsSurviveParsing`. Verified stays 1.0.65 (no version change).
- Hermes 0.17.0 IS verified at installed version via weekly local-schema evidence (state.db matches baseline, not stale). Do NOT install 0.19.0 — its `-z` oneshot is broken (returns "no final response" for EVERY provider, not auth; doctor shows core healthy), so updating would regress it to blocked_stale_sample.
- Bumped: Codex 0.145.0, Claude 2.1.217, OpenCode 1.18.4, Pi 0.81.1, Antigravity 1.1.1, Cursor 2026.7.20.
- Fixed two env issues (outside repo): broken `opencode` npm install (ran its postinstall.mjs → 1.18.4) and crashing `~/.local/bin/cursor` shim (`"$1"`→`"${1:-}"`).

**Key files:**
- `scripts/agent_watch.py` — `_run_cmd` now catches OSError (rc 126) so one unexecutable agent binary can't abort the weekly scan
- `docs/agent-support/agent-support-{matrix,ledger}.yml`, `docs/agent-json-tracking.md` — 2026-07-22 verification records

**Next:**
1. OpenClaw is the only truly-unresolved agent — needs a fresh OpenClaw/Codex OAuth sign-in, then `agent_watch.py --mode prebump --allow-real-home --agent openclaw`.
2. To push Hermes to supports_latest: repair its `-z` runtime → `hermes update` (0.19.0) → fresh prebump.

## 2026-07-21 10:08 · perf-program-close · Perf program closed & merged; release recommended over chasing AV parity
status: done

**State:** The 2026-07 perf program is fully closed: W7 list-feel accepted by owner, search click-through auto-jump landed (9456faa3, Opus-approved clean), close-out review MERGE-READY, and `main` fast-forwarded 7bf60ebd→9456faa3 (95 commits, suite 1,183/0, Release green) — unpushed at merge time. The Swift-6 `didApplyStage1Window` fix was spun off as a chip and landed separately (68cb0c34).

**Decided / don't redo:**
- NSTableView list spike DEFERRED on evidence (SwiftUI Table = 18/5,228 main-thread samples; the AgentsView gap is platform-layer, not a bug). Re-open condition documented in the W7 plan — don't re-chase without it.
- Strategy call answered: **release now**; resume perf only on real-world triggers (W8 = FSEvents + HUD leaf clocks, trigger = energy label sticking on a Release build).
- Energy-label flap explained, not a defect: 8–10 min energy-impact averaging + timer wakeups + Debug build; it cleared on its own.

**Key files:**
- `docs/perf-master-plan.md` — W2/W6/W7 outcome notes (the program index)
- `docs/superpowers/plans/2026-07-02-w7-list-feel.md` — Task 0 evidence, gate table, spike re-open condition

**Next:**
1. Push `main` when owner says push.
2. Release pass (`/deploy` flow: QA sweep → CHANGELOG/appcast → notarize) — offered, pending owner GO.
3. W8 only if the energy label sticks during normal use on a Release build.

## 2026-07-20 15:19 · growth-discovery-program · Blog + analytics live; discovery constraint identified as top-of-funnel
status: in-progress

**State:** Marketing/growth session (no app code touched). The Rollout blog is live with 6 posts + 2 future-scheduled, GoatCounter analytics is wired into all 8 site pages and collecting, and measurement finally shows *why* stars aren't moving.

**Decided / don't redo:**
- **Star rate did NOT move** across the whole campaign (~2.6/day = pre-campaign baseline). Constraint is **top-of-funnel: only ~30 repo visitors/day**; visitor→star is a healthy ~9%. Need 2.3× traffic, not better conversion.
- Downloads (+440/5d) are mostly **Sparkle auto-updates**, not new users — do NOT read them as acquisition, and don't build an in-app star nudge on that basis.
- Referrers: **Google 103 (SEO, #1), hermesatlas 16, chatgpt 11; Reddit/LinkedIn/X = 0.** Social is for credibility/ratio, NOT stars.
- **Directories are a spent lever** — Hermes Atlas works and is done; Claudetory/ToolHunter never published (7wk); rest are plugin-gated (no MCP feature). Don't submit more.
- **HN parked** (2 karma, 2 of 3 Show HNs flagged). awesome-opencode #381 is **maintainer-gated** (fork-PR CI needs maintainer approval) — stop poking it.
- OpenCode ecosystem PR auto-closed by a template bot → **re-submitted clean as #37567** (open, passing).
- X reply post-mortem: parent 34.8K views, our reply **4 views** — posted 5.5h late, buried in ~200 replies, no hook/image. Nested self-replies under someone else's thread are near-invisible. Fix = fast (<30min), top-level, with screenshot.
- Tooling (global, already written): `agent-browser` over CDP is now the default browser path (MCP chrome bridge is fallback + `~/.claude/bin/ensure-chrome-bridge.sh`); plus a hard rule never to ask the user to paste fetchable content.

**Key files:**
- `Marketing/STATUS.md` — read-first/update-last coordination dashboard + **content-pipeline registry** (two parallel Rollout threads collided on the 07-11/07-14 formats posts; registry prevents recurrence)
- `Marketing/GROWTH_TRACKER_1k-summer.md` — goal math + `stars-log.csv` (launchd daily logger)
- `Marketing/GROWTH_ANGLES.md` — strategy reset + answer-first reply drafts
- `Marketing/PRODUCT_HUNT_KIT.md` — **finalized**: tagline locked, maker comment, paint-by-numbers video storyboard

**Next:**
1. **Goal reality check:** 721 stars, 47 days, ~2.6/day → lands ~843. 1k by Sept 1 needs a *spike*, not compounding content.
2. **PH launch** is the only controllable spike — owner records 4 short clips per the storyboard + picks a Tue/Wed/Thu.
3. Owner sends queued drafts: 3 answer-first Reddit replies, 2 expansion posts (r/ChatGPTCoding = discussion format, no link), comparison-article outreach.
4. Optional build: X watcher to catch high-reach limit/cost posts within ~10 min (the fix for the 4-view problem).

## 2026-07-19 21:15 · subagent-grandchildren-drop · Grandchild sessions no longer dropped from the list
status: done

**State:** Fixed the pre-existing `SubagentHierarchyBuilder` bug where a session that is BOTH a child and a parent had its own children silently dropped from the session list (not nested, not flattened — absent). Flatten loop replaced with an iterative DFS over the whole subtree. TDD: 3 tests written and watched fail first (failure was exactly `["root","review-child"]` missing the grandchild), then full suite green 1725/0/3-skipped. Committed `d1d8de2e` on main, unpushed.

**Decided / don't redo:**
- `depth` now carries the true level (2+) instead of clamping to 1 — every UI consumer tests `depth > 0` / `== 0`, so it renders correctly today and keeps real structure available.
- Nested parents get honest `hasChildren`/`childCount` (also makes them collapsible); `collapsedParents` honored at every level.
- `emitted` set is a cycle guard only — a cycle is NOT constructible through the public API (role-only index excludes subagents as candidate parents; explicit chains follow real spawns). Don't write a test for it.
- Census caveat: `parent_thread_id` lives at `source.subagent.thread_spawn.parent_thread_id`, NOT at payload root. A root-level probe returns a false 0. Corrected census confirms 150 grandchildren, all `('thread_spawn','review')`.
- Left `docs/summaries/2026-07.md` uncreated — that `agents.md` convention has been dormant since 2026-06; didn't restart it unilaterally.

**Key files:**
- `AgentSessions/Services/SubagentHierarchyBuilder.swift:124` — the DFS flatten
- `AgentSessions/Views/UnifiedSessionsView.swift:3919` — indent moved out of the chevron's `else` branch (nested rows can now have children and would have rendered flush-left)
- `AgentSessionsTests/SessionParserTests.swift:1735` — 3 new tests (grandchild survives, collapse root, collapse mid-level)

**Next:**
1. Owner visual QA: a `review` subagent row with thread children should now show a chevron + count and indent one level in.

## 2026-07-19 21:15 · codex-live-status-parent-thread · QM/Runway now read top-level parent_thread_id
status: done

**State:** Committed `cb1c44f2` on main, unpushed. Closes follow-up 2 of the `codex-guardian-subagent` entry below: `CodexActiveSessionsModel.parseActiveSubagentSessionMeta` and `CodexRunwayModel.parentSessionID(from:)` now fall back to `payload.parent_thread_id`, so a RUNNING guardian is attributed to its parent instead of showing as an independent active session. Full suite 1725/3 skipped/0 failures.

**Decided / don't redo:**
- Neither live path classifies subagent *type* — they only ever read the parent link — so `{"subagent":{"other":"guardian"}}` needed no dedicated branch here, just the top-level fallback.
- Gate widened from dict-only to any `subagent` value, so the string form `{"subagent":"review"}` now resolves a parent too. Intentional: matches `SessionIndexer` (f7de3891). Real behavior change beyond guardians.
- Fallback stays gated on a subagent source. Corpus check: 961 rollouts carry `parent_thread_id`, **all** subagent-sourced, 0 non-subagent — so the guardrail is defensive only, kept to keep the 3 parse sites textually aligned.
- Attribution is verified by test against a fixture confirmed field-identical to the real guardian `session_meta`, NOT by observing a live guardian. That gap is open.

**Key files:**
- `AgentSessions/Services/CodexActiveSessionsModel.swift:1295` / `AgentSessions/CodexStatus/CodexRunwayModel.swift:1755` — the two fixed reads
- `AgentSessionsTests/CodexActiveSessionsRegistryTests.swift` + `CodexUsageParserTests.swift` — 6 new tests (guardian, string-form, non-subagent guardrail × both paths)

**Next:**
1. Owed: `docs/CHANGELOG.md` bullet — skipped because a parallel session has an unstaged bullet in that file and `git commit -- <path>` would sweep it in. Add after their work lands.
2. Strike "Live-status guardian attribution" from the out-of-scope list in `docs/superpowers/plans/2026-07-19-codex-guardian-subagent-fix.md:472`.
3. Owner QA on the next real guardian to confirm live behavior.

## 2026-07-19 21:14 · codex-guardian-subagent · Cowork/work badges + guardian duplicate-row fix; all committed, unpushed
status: in-progress

**State:** Two features + one bug fix landed on main, 9 commits `57655242..e1312475`, NOT pushed. (1) Claude Cowork sessions now carry a `cowork` badge with live sidecar titles/archive parity (second overlay root); (2) Codex Desktop sandboxed tasks (cwd `~/Documents/Codex/<date>/<slug>`) carry a `work` badge — label chosen from Codex's own `codex_work_desktop` marker, deliberately NOT reusing Anthropic's "Cowork" branding for an OpenAI surface; (3) Codex guardian (approval-reviewer) subagents stopped duplicating their parent's row. Full suite 1716/3 skipped/0 failures. Opus whole-branch review READY TO MERGE. Verified end-to-end on the real corpus after reindex: 3321 codex rows, exactly 70 `guardian`, reported pair resolves parent→child, 0 guardians holding the parent's internal id.

**Decided / don't redo:**
- Codex needs no Cowork-equivalent ingestion: all 83 `~/Documents/Codex` threads already point `rollout_path` back into `~/.codex/sessions`. Nothing separate to discover.
- ChatGPT desktop chats + claude.ai web chats are NOT locally readable (encrypted `.data` blobs / fragmentary LevelDB). Don't re-investigate.
- Nesting via transcript-body `Reviewed Codex session id:` text = rejected; `payload.parent_thread_id` + existing cwd inference already suffice.
- All classifiers are path-/cwd-/subagent_type-keyed because hydrated rows have NULL surface metadata.
- Two commits here (`1ca28990`, `e1312475`) are a *parallel* session's stale work, committed on owner request; that session was still running.

**Key files:**
- `AgentSessions/Services/SessionIndexer.swift` — guardian `{"subagent":{"other":…}}` branch, BOTH parse sites (required: SearchIngest writes meta via `parseFileFull`)
- `AgentSessions/Indexing/DB.swift` — `codex_guardian_subagent_reindex_v1` corpus-preserving marker
- `docs/superpowers/plans/2026-07-19-codex-guardian-subagent-fix.md` + `…-claude-cowork-labeling.md` — executed plans

**Next:**
1. Owner QA, then push on GO.
2. Two follow-ups running as separate sessions: grandchild rows silently dropped in `SubagentHierarchyBuilder` flatten (~150 rows, pre-existing); QM/Runway not reading top-level `parent_thread_id`.
3. Still queued, untouched: Runway should read the Cowork sidecar root (`ClaudeRunwaySnapshotLoader:23` → `defaultRoots()`); fix stale "account is not Premium" line in `docs/superpowers/the-rollout-voice.md`.

## 2026-07-19 18:32 · usage-connection-resilience · QM "reconnecting forever" root-caused + fixed; QA/push pending
status: in-progress

**State:** Diagnosed today's recurrence: NOT the 4.3.1 expired-token bug — (1) Cloudflare edge 429 on `api.anthropic.com/api/oauth/usage` (Retry-After up to ~47 min; dev relaunch churn burns the tiny quota) and (2) stale-cached-token 401 race (CLI refreshes Keychain, manager 401s with 10-min-cached copy, delegated refresh sees "no change", credential-gates). Fixes on local main, commits ad3ebc04..57655242 via SDD: immediate 401 retry with re-read Keychain token; web fallback activates during 429-with-cache; all reconnecting cells (QM/menu bar/footer) now render the real cause via `QuotaData.reconnectingCaption`; socketless orphan sweep testable + ps-timeout no longer silently skips (3-day orphan probe PID 46300 killed manually). Suite 1706/0 GREEN; Opus whole-branch review READY TO MERGE. NOT pushed; owner visual QA pending (build in `.deriveddata-manual`).

**Decided / don't redo:**
- Non-goals locked: no dimmed stale meters, no `.idle` copy change, no retry-cadence change vs Retry-After.
- Accepted minors: UsageMenuBar caption magic-string compare; single-hash 401-retry guard (oscillation not field-reachable).
- Diagnostics that work: `/usr/bin/log show --info --predicate 'subsystem == "com.triada.AgentSessions" AND category == "ClaudeOAuth"'` (`log` is shell-shadowed — full path); Keychain mdat via `security find-generic-password -s "Claude Code-credentials"`; `/tmp/claude/statusline-usage-cache.json` mtime = last endpoint 200.

**Key files:**
- `AgentSessions/ClaudeStatus/ClaudeOAuth/ClaudeUsageSourceManager.swift` — 401 fast path + 429 web-fallback kick
- `docs/superpowers/plans/2026-07-19-claude-usage-connection-resilience.md` — executed plan

**Next:**
1. Owner QA: relaunch from `.deriveddata-manual`, confirm captions + fast recovery.
2. Push on owner GO; fold into next release notes.

## 2026-07-19 13:49 · qm-hard-probe · Probe feature + usage-accuracy fixes shipped; 4.6.1 release pending
status: in-progress

**State:** All pushed to `main` (ef7bd125..644f3446): QM toolbar probe button + provider menu backed by new `ProbeCoordinator` (single acceptance gate for ALL probe surfaces; QM double-click removed), in-row probing/failed feedback at 3 render sites, entry points rewritten busy-first/always-completing; plus burn-rate provisional-path cap (subagent sessions overstated ~1.6-3.6x) and the idle-latch fix (web-fallback data was hidden behind "no active session" forever). Suite 1690/0; owner QA passed; 3 Codex reviews + Opus whole-branch review clean (last P2 fixed in 644f3446). Owner decided 4.6.1 (patch), 2026-07-19 — despite the removed QM double-click gesture arguing for a minor bump.

**Decided / don't redo:**
- AS-owned OAuth (P2) re-confirmed CANCELLED (ban risk). Desktop-app sessions do NOT refresh the CLI keychain token — only a terminal `claude` run does (proven live 2026-07-18).
- Probe = manual only; auth-suppressed probes render as no-op, never "probe failed"; `.alreadyRunning` = silent no-op everywhere.
- Kept "dead" `CodexUsageModel.hardProbeNow(Bool)` — its tests pin the entry-point contract. Strip double-click no longer refreshes reset credits (accepted).

**Key files:**
- `AgentSessions/Shared/ProbeCoordinator.swift` — acceptance gate; buffering/generation/one-shot semantics documented in header.
- `docs/superpowers/specs/2026-07-18-qm-hard-probe-design.md` + plan — the contract source of truth.
- `.superpowers/sdd/progress-qm-probe.md` — SDD ledger for the 6-task run.

**Next:**
1. Release 4.6.1: `deploy bump patch` → changelog → `deploy qa` (stamp) → notarize → appcast; notes drafted via release-notes skill (headline: idle-latch fix + probe button + burn-rate accuracy; note QM double-click removed).

## 2026-07-18 12:31 · site-chrome-unification · Landing header + style unified across guides & blog
status: done

**State:** Guides and The Rollout blog now use the landing page's sticky nav header, design tokens, and full light+dark mode. Committed `6f0c96ec`, pushed to `main`, GitHub Pages built (no errors), verified live on blog + guides.

**Decided / don't redo:**
- Chose Approach A (rework the shared stylesheet + swap header markup); rejected Approach B (Jekyll-ify the 6 static guides + extract landing CSS) as out of scope.
- Accepted trade-off: design tokens are duplicated between `docs/index.html` (inline `<style>`) and `guides/guide.css` — a future landing redesign needs a matching `guide.css` edit. Kept to hold zero risk on the landing page. Landing page + `guide.js` intentionally untouched.
- Sub-page nav is the **simplified** variant (brand + The Rollout + GitHub★), reusing `guide.js`'s `#github-stars` IDs — not the landing's full nav.
- Local `jekyll build` needs `LANG=en_US.UTF-8` (theme-injected `style.scss` trips US-ASCII); pre-existing, non-issue on Pages.

**Key files:**
- `docs/guides/guide.css` — now the shared design system (tokens + `.nav` + tokenized body + footer band).
- `docs/blog/blog.css` — trimmed to blog-only rules; bespoke dark-mode block removed (global via tokens).
- `docs/_layouts/blog.html` + `docs/guides/*.html` ×6 — header swapped to unified `.nav`.
- `docs/superpowers/specs/2026-07-18-site-chrome-unification-design.md` — design record.

**Next:**
1. Nothing required — shipped. Optional future: fully DRY the landing/guide tokens (Approach B) if the site gets a bigger redesign.

## 2026-07-18 10:59 · agent-support-format-check · Weekly format check (Claude mode event) + OpenClaw auth wall
status: done

**State:** Weekly `agent_watch.py` check done and committed+pushed (`b65aa748` format-check, `21a8738b` handover) — Claude went high/format_drift_detected → medium. OpenClaw is the one open item: session **format verified drift-free**, but version pin stays at 2026.6.11 (can't mint a fresh sample — auth wall). Full suite green (1650/0). Blog drafts from the earlier session are already committed+pushed (`38225903`); the flagship still needs the rewrite (see Next).

**Decided / don't redo:**
- Claude 2.1.211 `mode` event ({type,mode,sessionId}, mode=normal, 3638×) is **non-breaking** — resolves to `.meta` via the `SessionEventKind.from` fallback. Pinned by `testClaudeSchemaDriftModeEventSurvivesParsing`. Not a hotfix; already-shipped 4.6 handles it.
- Prebump is **blind to interactive-only event families** (`mode`) — one-shot `-p` never emits them; trust the weekly scan for those. Recorded in ledger/tracking.
- OpenClaw `refresh_token_reused` is NOT a sandbox artifact — a real `openclaw agent --local` fails too. Its OpenAI token store (`openclaw-agent.sqlite`) is separate from Codex's and its token is dead. Fix is **user-side re-auth** of OpenClaw's openai provider (or static `OPENAI_API_KEY`) — don't retry-thrash, don't chase the gateway.
- **`openclaw update` bricked the gateway** (Memory Core legacy→canonical index migration conflict); `doctor --fix` did NOT clear it. User doesn't use the gateway — left **stopped/quiesced** on purpose. Don't run `openclaw update` casually.
- Corrected stale metadata: matrix+ledger said 4.3.2 though app shipped 4.6 → set to 4.6.
- Also used the existing `skills/agent-session-format-check` + `agent_watch.py` — don't hand-roll a session parser (I did once this session; wasteful).

**Key files:**
- `docs/agent-support/{agent-support-matrix.yml,agent-support-ledger.yml}`, `docs/agent-json-tracking.md` — verified-version records (append-only ledger).
- `Resources/Fixtures/stage0/agents/claude/{small,schema_drift}.jsonl` + `AgentSessionsTests/Stage0GoldenFixturesTests.swift` — `mode` fixture + test.
- `docs/_posts/2026-07-14-how-coding-agents-remember.md` + 3 sibling Rollout drafts — committed but flagship needs rewrite.

**Next:**
1. (Optional) OpenClaw version-pin bump to 2026.7.1: user re-auths OpenClaw openai provider → `openclaw agent --local --agent main -m hi` → weekly scan → bump matrix/ledger/tracking. Format itself already verified.
2. Rewrite the flagship blog post (9 agents incl. Antigravity protobuf + Qwen/Factory; three storage philosophies; refresh stale Codex 126→136 KB number; "withdrawal of legibility" thesis).
3. Correct the model-field claim in the published `2026-07-11-where-agents-store-history.md` (Claude DOES write per-event `message.model`) — task chip still open.

## 2026-07-16 22:54 · claude-auth-idle-webapi · Calm idle-token QM state + Web API FDA fix
status: done

**State:** All committed on `main`: idle-token state `3e170854`, Web API cause-aware path `8076b058`, Debug signing `6160a591`, Opus review fixes `0c9457a8`. App relaunched from `.deriveddata-manual` (now Apple Development-signed). Full test suite green. Only user step left: one-time FDA re-grant to the debug app, then "Test Web API" in Preferences → Usage Tracking.

**Decided / don't redo:**
- QM "Claude auth expired" after ~24h inactivity is a routine token lapse → new non-alarming `UsageAuthState.idle` ("no active session" moon cells); alarm only if CLI reports signed-out or a *fresh* token still 401s (per-episode token fingerprint).
- `claude auth status` (CLI 2.1.207) does NOT refresh tokens — the delegated-refresh assumption is false; only a real Claude session refreshes the keychain token. AS-owned token refresh stays cancelled (2026-07-08 spec §1).
- Web API path was dead from TCC: app can't read Safari Cookies.binarycookies without Full Disk Access, and ad-hoc Debug signing invalidated FDA grants on every rebuild (cdhash-pinned). Debug now signs with Apple Development (team 24NDRU35WD) → grants survive rebuilds.

**Key files:**
- `AgentSessions/ClaudeStatus/ClaudeOAuth/ClaudeUsageSourceManager.swift` — idle publication + web fetch loop
- `AgentSessions/ClaudeStatus/ClaudeOAuth/ClaudeWebCookieResolver.swift` — typed ReadOutcome (.permissionDenied/.noSession)
- `AgentSessions/Views/Preferences/PreferencesView+Usage.swift` — "Test Web API" self-test callout

**Next:**
1. User: remove stale FDA rows, add `.deriveddata-manual/.../AgentSessions.app`, restart, run "Test Web API".
2. Visual QA of the idle state happens at the next natural token lapse (~1 day without Claude sessions).
3. Consider Safari Profiles limitation (non-default profile login reads as .noSession) if users report false "no session".

## 2026-07-16 22:37 · release-4.6 · Ship 4.6 (Claude paste-a-cookie usage) + app-staple notarization fix
status: done

**State:** 4.6 fully deployed, verified, and announced. `main` level with `origin/main`; GitHub Release, appcast (4.6), and Homebrew cask all live. Issue #50 closed.

**What shipped:** Headline = paste-a-cookie Claude web usage (already coded pre-session). This session's real work = committing the uncommitted **app-staple notarization fix** (Info.plist `CFBundleExecutable`/`CFBundlePackageType`; build script now notarizes+staples the .app *then* the DMG — 2x notary submissions, normal not a hang) and running the deploy. First release carrying that fix.

**Decided / don't redo:**
- Manual smoke was **skipped** per owner ("deploy anyway"); automated gates (build, 1649 tests, 116 py release tests, no warnings) were GO. Notary auth comes from ignored `tools/release/.env` (App Store Connect API key) — not env vars in the shell.
- Verified the fix end-to-end on the shipped DMG: `stapler validate` passes on the app *inside* the DMG + on the DMG; `spctl --assess --type execute` → "accepted / Notarized Developer ID". This is the #50 diagnostic.

**Next:**
1. Nothing required — release done. Watch for any @efenex reply on #50 (closed; they can reopen). Optional post-release: Sparkle auto-update + `brew upgrade` smoke on a clean machine.

## 2026-07-16 17:58 · qm-lens-highlight-recurring-hint · QM recurring right-click hint + active-lens underline
status: done

**State:** Both QM UX fixes implemented, build green, 2 enum tests pass, app relaunched for QA. Uncommitted on `main`.
1. On-Demand chrome: `Right-click for controls` hint no longer retires — recurs on every hover (right-click is the only route back to the toolbar). 2. Agent row underlines the `5h`/`Wk` symbol matching the active runway lens (subtle grey, 1pt, symbol-only — not the `: `); token/$ underline neither; picked-but-absent window underlines nothing.

**Decided / don't redo:**
- Rejected a hover reveal *button* (drag-target fight) — kept right-click + recurring text hint. Underline chosen over a separate lens badge (owner: reuse existing `5h:/Wk:` labels, no new chrome). Final underline style: grey `.secondary.opacity(0.6)`, symbol-only, NOT bright accent (walked back from accent 1.5pt).
- Removed dead `quotaMeterChromeRevealedOnce` plumbing entirely (AppStorage + PreferencesKey + reset + `retired`/`hintRetired` params).

**Key files:**
- `AgentSessions/CodexStatus/UsageDisplayMode.swift` — `QuotaMeterChrome.showsRightClickHint`/`armsDwellTimer` (params dropped)
- `AgentSessions/Views/AgentCockpitHUDView.swift` — file-scope `RunwayLensWindow`/`activeRunwayLensWindow`/`runwayLensLabel`; applied at 6 label sites (`HUDLimitsProviderText` aligned+nonaligned+bottleneck, `HUDLimitsDetailPanel.detailRow`)
- `docs/superpowers/specs/2026-07-16-qm-lens-highlight-recurring-hint-design.md` — spec

**Next:**
1. Owner visual QA (both compact + Full cockpit); then commit when asked.

## 2026-07-16 17:49 · repo-triage-automation · Daily GitHub triage tool (built, right-sized, live)
status: done

**State:** `tools/triage/` shipped + installed as a daily 08:00 LaunchAgent: gathers open issues/PRs/comments + recent releases via `gh` → drafts a digest + suggested replies with a TOOL-LESS `claude -p` (data inlined in the prompt, replies parsed from stdout) → macOS notification. You skim `out/<date>/digest.md` and post with `reply.sh <id>` (shows text, y/N). Full suite green (7 files); real-claude confinement gate 9/9; verified end-to-end THROUGH launchd. Pushed to origin/main through `626dfbe6`. Posted R2 live on homebrew-agent-sessions#3.

**Decided / don't redo:**
- Flag-based agent confinement (`--allowed/--disallowedTools`) is a pre-approval list, NOT a sandbox — proven inadequate (reads/writes outside not blocked; Task/Agent/Skill still available → injection could spawn an unrestricted subagent). Fix = the TOOL-LESS architecture; do NOT reintroduce file-tool scoping.
- Right-sized from an over-engineered build: cut auto-ack tier + guardrails, apply.sh tiers, lock, status.json/catch-up, retention, idempotency ledger, state.json. Keep it minimal for a tool the user approves everything on. (memory: feedback_right_size_personal_tools)
- launchd runs a bare PATH and `claude` is in `~/.local/bin` — install.sh bakes resolved tool dirs into the plist PATH. Always verify installed jobs by triggering THROUGH launchd, not just manually.

**Key files:**
- `tools/triage/README.md` — how it works + install/use; `run-agent.sh` — tool-less agent + stdout delimiter parse; `reply.sh` — hardened manual post path
- `docs/superpowers/specs/2026-07-16-repo-triage-automation-design.md` — design + security findings (right-sized banner)

**Next:**
1. Nothing required — runs tomorrow 08:00; skim the digest, `reply.sh <id>` as needed. Uninstall: `bash tools/triage/uninstall.sh`.
2. Product (not tool): issue #50 (notarization) still open — confirm whether v4.5 contains the stapling fix, then close the loop with the reporter.

## 2026-07-16 14:34 · claude-web-manual-cookie · Claude web usage via pasted session cookie
status: done

**State:** Paste-a-cookie Claude web usage shipped and owner-QA-confirmed working (Settings → Usage Tracking → Data source "Web API only" → paste sessionKey → Test now = "Working"). Committed to local `main` (`33fcda27` feature + `95e73b43` review fixes), NOT pushed. Full suite 1649 pass.

**Decided / don't redo:**
- Root cause proven on-machine: claude.ai `sessionKey` is NOT in any readable binarycookies file on modern Safari; path-fix / SweetCookieKit can't rescue Safari. Chose SAFE MANUAL COOKIE PASTE (CodexBar's actual Claude approach), NOT embedded WKWebView login (spec Plan A — rejected as heavier/riskier).
- sessionKey stored in Keychain (never plaintext UserDefaults). `extractSessionKey` is name-anchored (split on ';', match pair named exactly `sessionKey`); self-test uses `ClaudeWebUsageClient.fetch(bypassCache:)` so it validates live, not from the 3-min /tmp cache.

**Key files:**
- `AgentSessions/ClaudeStatus/ClaudeOAuth/ClaudeManualWebCookie.swift` — extractor + Keychain store (PRIMARY web source).
- `AgentSessions/ClaudeStatus/ClaudeOAuth/ClaudeWebCookieResolver.swift` — 7 typed outcomes + value-free diagnostics (Safari reader now legacy fallback).
- `AgentSessions/Views/Preferences/PreferencesView+Usage.swift` — paste UI + Test-now self-check.

**Next:**
1. Push when the parallel work lands (both commits are local-only on `main`).
2. Optional, deferred code-review findings: source-manager tests read real Keychain via `.shared` (non-hermetic); `save()` conflates keychain-write-fail with invalid-paste message; bare token containing `=` rejected; synchronous Keychain read on the actor.

## 2026-07-16 14:34 · claude-usage-wedge-fix · Claude usage stuck-until-relaunch + FDA flap diagnosis
status: done

**State:** 4.5 shipped/pushed earlier this session. Claude-usage fixes pushed to `origin/main` (`4d81b789`). Bug 1 (usage wedges on "no active session" for hours until relaunch) fixed + self-heals; Bug 2 (web cookie path) handled by a parallel session; FDA flap diagnosed as a dev artifact (no code).

**Decided / don't redo:**
- **Bug 1 root cause = one-shot `didAttemptDelegatedRefresh` latch** (reset only by OAuth success). Fixed by replacing with a 10-min throttle (`shouldAttemptDelegatedRefresh`/`lastDelegatedRefreshAt`), cleared on `refreshNow` (double-click QM / wake force it). Commit `6a9242a3`, mutation-verified test.
- **Bug 2** (Safari cookie path broken on macOS 14/15 — sessionKey not in the legacy binarycookies file): parallel session shipped **manual cookie paste** (`33fcda27`, `95e73b43`), NOT the embedded-WKWebView login in the spec. Spec is marked superseded.
- **FDA flap** = dev builds share bundle id `com.triada.AgentSessions` with the official app; TCC keys FDA to signature so the grant flaps. NOT a shipping bug. Do NOT do the Debug-bundle-id split — coupled to `AppRuntime.isHostedByTooling` (would disable filesystem probing in all debug builds) + hardcoded self-probe ids. Fix = build-only, don't `open` dev builds.

**Next:**
1. User: one-time FDA cleanup — remove "AgentSessions" from Full Disk Access, re-add only `/Applications/AgentSessions.app`.
2. Optional follow-ups from Codex on Bug 1: hidden-surface OAuth recovery (credential-watch never wakes OAuth) and `.expired` tmux suppression — left intact, not needed for the fix.

## 2026-07-16 11:27 · notarization-staple-50 · Fix Gatekeeper "could not verify free of malware" (issue #50)
status: in-progress

**State:** Root-caused issue #50 by inspecting the shipped 4.4/4.5 DMGs: the app is signed **and notarized** (cdhash registered), but the release only stapled the **DMG**, never the **.app** inside it → Gatekeeper does an online check at first launch that fails offline/behind proxies. Fix applied to the release pipeline + Info.plist; **uncommitted on `main`, not yet released**. Replied to reporter on GitHub with a safe workaround, promised a fixed build today.

**Decided / don't redo:**
- The app WAS notarized — proven: `stapler staple AgentSessions.app` fetches a live ticket. Do NOT resubmit from scratch; it was purely a missing staple step.
- Pipeline now notarizes+staples **both** the app zip AND the DMG → **two `notarytool` submissions per release (~2x notary wait). That's expected, not a hang.**
- Sync path (`NOTARIZE_SYNC=1`) left un-hardened on purpose: the `stapler staple` step after each notarize is the real Accepted-gate (no ticket → hard fail under `set -e`).
- Missing `CFBundleExecutable`/`CFBundlePackageType` also made code identity fall back to the bundle filename (renaming breaks cdhash) → added both to Info.plist.

**Key files (all uncommitted):**
- `tools/release/build_sign_notarize_release.sh` — new order: sign → zip → notarize → staple+validate app → DMG → notarize → staple+validate DMG.
- `tools/release/deploy-agent-sessions.sh` — smoke test now asserts `stapler validate` on BOTH the app and the DMG (covers resume paths); pipeline comment updated.
- `AgentSessions/Info.plist` — added `CFBundleExecutable`=AgentSessions, `CFBundlePackageType`=APPL.
- Reference doc for the user's *other* macOS app: scratchpad `macos-notarization-staple-check.md` (portable check).

**Next:**
1. User is doing other bug fixes, then cutting a new release today — these staple changes ride along automatically (deploy → build script). Expect the doubled notary wait.
2. After release, update issue #50 and confirm the shipped app passes `stapler validate`.

## 2026-07-14 21:21 · runway-dollar-burn · Session Runway $ burn: correct, stable, all pushed
status: in-progress

**State:** `$` burn (Phase 1+2) is complete and all pushed to `main` (`f09241b5`), suite green at 1601 — but **committed, not released**: 4.4 shipped without it, so no user has it yet. Four review passes fed it (Fable, Codex@low, /code-review, Codex@high — only the high-effort Codex pass earned its keep).

**Decided / don't redo:**
- **Route B**: price what we can, DROP what we can't; nil only when nothing is priceable. Do not revert to "any unpriced model → whole provider falls back" — that caused the $/tk flap on every 5s refresh.
- **Reasoning is already inside `output_tokens`** (verified: `total == input + output`) and is billed at the output rate. Codex@high raised subtracting it as a P1 — it's wrong; subtracting understates. Don't "fix" it.
- **`<synthetic>`** (Claude) is not a model; it carries usage but all zeros → zero-rate slice, exempt by design. Do NOT add a price key. (If Claude ever gives it real tokens, every Claude session would drop from `$`.)
- **One `>=` acceptance rule** for prices. Strict-cache (`>`) was tried and reverted: it discarded same-date corrections on relaunch. Editing `docs/prices.json` MUST advance `updated`, or clients ignore it.
- **Opus is $5/$25**, not $15/$75 (was 3x over). Fable/Mythos $10/$50 — pricier than Opus.
- Model resolution: **last** `turn_context`, not the first, via a scan frontier. Cache-first was the bug; a warm cache masked a `/model` switch.
- Sonnet 5 intro $2/$10 ends 2026-08-31 — we deliberately bundle the stable **$3/$15**. No action at expiry.

**Key files:**
- `AgentSessions/CodexStatus/CodexRunwayModel.swift` — `RunwayModelComponent` (per-model pricing), `dollarSnapshot`, model resolution + frontier cache.
- `AgentSessions/CodexStatus/RunwayPriceTable.swift` + `docs/prices.json` — must stay **identical**; Pages serves the latter to shipped apps.
- `skills/agent-session-format-check/SKILL.md` §2a — price-freshness maintenance (monthly + any model launch); the scan cannot catch price drift.

**Next:**
1. **Release it** — `$` burn is unreleased; the "your session is burning $X/h at API rates" meter is a strong release-notes story.
2. Open by choice: one unknown-model subagent drops the whole session from `$` (Codex finding #3 — fails safe, benign today since subagents run priced models).
3. Owner QA of `$` across a fan-out session (opus parent + sonnet subagents) — measured 1.13x overstatement before the per-model fix; should now read ~$28.52 not ~$32.11.

## 2026-07-14 14:19 · opencode-qm-usage · Research: OpenCode usage/limits in Quota Meter
status: in-progress

**State:** Research/eval only, no code changes. OpenCode is already first-class for history (parser + `opencode.db` SQLite reader + JSON) AND already in the QM live-session list (`supportsLiveSessionSource(.opencode)==true`; PresenceEngine discovers opencode via ps/lsof; Cockpit `supportedSources` includes `.opencode`). The ONLY missing piece vs Codex/Claude is **usage** (5h/week limits + Session Runway).

**Decided / don't redo:**
- The blocker for an opencode usage bar is the **consumption number**, NOT the runway. Codex reads logged `rate_limit` events from its own jsonl; Claude reads `api.anthropic.com/api/oauth/usage`. OpenCode exposes neither — no local window-consumption, and the Zen balance API is still an open/unscheduled request ([sst/opencode #10448](https://github.com/anomalyco/opencode/issues/10448)). CodexBar got the same ask ([#1006](https://github.com/steipete/CodexBar/issues/1006)) and closed it without shipping.
- OpenCode Go/Zen has the same window shape ($12/5h, $30/wk, $60/mo) but usage is dashboard-only. BYO-key users (the majority, incl. this repo owner — `~/.local/share/opencode/auth.json` = anthropic only) have **no window to meter at all**.
- Local message files DO carry per-msg `tokens{input,output,reasoning,cache}` + `cost` + `time`+`sessionID` (verified on disk) → a token-burn meter is computable offline. BUT observed `cost:0` on a Zen (`providerID:opencode`, `big-pickle`) msg → local cost may not populate for Go; token→$ conversion would drift. Any locally-computed bar is an ESTIMATE, not provider-authoritative like Codex/Claude — reputational risk with this accuracy-minded audience.
- Growth verdict: don't build the meter for stars. The high-leverage free move is a community post about EXISTING opencode support (history+search+resume+live sessions). Reserve the usage-meter build for when #10448 ships (then "first authoritative opencode usage tracker" is a real headline; CodexBar punted).

**Next:**
1. If pursuing: $5 Go spike to verify whether opencode writes non-zero local `cost` for Go usage — that single fact decides estimate-bar viability vs wait-for-#10448.
2. Marketing: reusable OC-outreach prompt was drafted in-chat (accurate do-not-claim block: NO opencode usage/quota/runway claims). Offer to save as `Marketing/PROMPT_opencode-outreach.md` and/or run it to produce Reddit + X drafts.
3. Parser note if building token-burn: `OpenCodeSessionParser`/`OpenCodeSqliteReader` read message PARTS, not message-level `tokens`/`cost` — that's the extension point.

## 2026-07-13 18:58 · codex-usage-window · Codex 5h-drop: length-based window routing
status: done

**State:** Shipped to main (pushed): `44339507` (main fix) + `982350ae` (follow-up); full suite green (1571). OpenAI temporarily dropped Codex's 5h window (weekly now arrives in `primary`, `secondary` null) → parsers mislabeled weekly as "5h". Now routed by `window_minutes` length (not slot) via new `CodexRateLimitWindowClassifier` across all 4 parse sites; drift guardrail; runway re-pointed to weekly when 5h absent; 3-state display (real% / "no limit" / "can't verify"). Auto-recovers when the 5h window returns.

**Decided / don't redo:**
- Route by length, NOT slot. No-length response → historical positional fallback; reset-distance deliberately unused (it broke length-less CLI-RPC fixtures).
- "can't verify" is ONLY partial drift (one good + one drifted). Fully-unplaceable response → nil → **reconnecting**, never the alarm (`982350ae` reverted the over-eager zero-window surfacing that misfired during the normal Codex connect window; length-less lone CLI-RPC window was the trigger).
- Claude "no active session" after (re)launch = transient token-refresh reconnect, NOT a regression (chased hard; keychain/signature theories were wrong; `ClaudeStatus/` unchanged since v4.3.2). Wait it out before diagnosing.
- Keep the 5h m/h "yardstick" via `RunwayProviderBaseline.windowMinutes` (default 300 → Claude untouched).

**Key files:**
- `AgentSessions/CodexStatus/CodexRateLimitWindowClassifier.swift` — shared length classifier + guardrail.
- 4 parse sites: `CodexStatusService`, `CodexCLIRPCProbe`, `CodexOAuth/CodexOAuthUsageFetcher`, `CodexRunwayModel`.
- `AgentSessions/Views/{CockpitFooterView,AgentCockpitHUDView}.swift` — display states + presentationState reconnecting guard.
- `docs/superpowers/specs/2026-07-13-codex-usage-window-classification-design.md` — design + known limitations.

**Next:**
1. Confirm the CLI-RPC `window_minutes` field name against a live `/status` RPC (currently guessed camelCase; length-less path falls through safely).
2. Optional: weekly-projection precision — thread exact-Double remaining-% through the snapshot so the ▸ run-out token fires on the weekly window (deferred; rows still render).
3. `CHANGELOG.md` [Unreleased] entry for this fix (left to owner; still uncommitted along with `RepoHandover.md`).

## 2026-07-13 18:01 · migration-corpus-guardrail · Corpus-preserving reindex primitive + guardrail
status: done

**State:** Shipped to main (pushed). Schema-migration wipe markers no longer need to nuke the FTS corpus: added `reindexSessionMeta(sources:)` that re-derives `session_meta` only, plus a guardrail comment at the marker site and `MigrationCorpusPreservationTests`. 1554 tests green. Commits: `3e549ca3` (code), `38225903` (parallel blog/spec docs), `2246d81a` (parallel perf handover).

**Decided / don't redo:**
- Scope kept deliberately minimal (owner's call): helper + guardrail test ONLY. NO rewrite of the 5 existing wipe markers (one-time, already applied — near-zero value) and NO progress UI.
- Root insight: only `session_meta` must be wiped to force a re-derive — the core indexer's "missing hydrated" supplement repopulates it. Wiping `session_search`/`session_tool_io` was pure collateral and the actual cause of "search returns nothing" after an upgrade.
- Only Claude/Codex/OpenClaw have core `session_meta` writers; the other 7 sources get meta from the search-ingest pass (reparse in place, corpus never emptied). So no source's sessions vanish after a meta-only wipe.
- Guardrail is by-example + at-site comment, NOT mechanical. A dev bypassing the primitive with a raw corpus DELETE won't trip the test — mechanical enforcement would need a typed migration registry (the refactor the owner declined).

**Key files:**
- `AgentSessions/Indexing/DB.swift` — `reindexSessionMeta` (instance + `private static` bootstrap-callable form), guardrail comment at the marker block (~L375), `rowCountForTesting` (DEBUG).
- `AgentSessionsTests/Indexing/MigrationCorpusPreservationTests.swift` — corpus-preservation contract test.

**Next:**
1. Future parse-derived `session_meta` column → add a marker that calls `try reindexSessionMeta(db, sources:)` in bootstrap; do NOT copy the old wipe markers.
2. If the corpus-wipe footgun recurs, escalate to a typed migration registry (each marker declares scope; a test asserts none wipes the corpus).

## 2026-07-13 11:33 · agent-support · 2026-07-13 weekly session-format check + subagent fixture
status: done

**State:** Committed & pushed to main as `62a4ef12` (dad7c4e7..62a4ef12). Two additive, non-breaking drifts handled; 5 verified versions bumped; 136 tests green; monitor re-run clean (codex+claude schema_matches_baseline=True, unknown_keys=[]).

**Decided / don't redo:**
- Codex 0.144.x `world_state` event → parser reads `type` from payload, resolves to `.meta` (non-breaking). In codex small.jsonl (baseline) + schema_drift.jsonl.
- Claude subagent keys (agentId/attributionAgent): did NOT sprinkle onto main small.jsonl — built an authentic subagent fixture pair under `claude/subagent/<uuid>/subagents/` + `.meta.json` sidecar, which also covers the previously-untested `ClaudeSessionParser.detectSubagentInfo`. small.jsonl reverted to pristine.
- Bumps (all fresh real-session evidence): Codex 0.142.5→0.144.3, Claude 2.1.202→2.1.207, OpenCode 1.17.13→1.17.18, Pi 0.80.3→0.80.6, Antigravity 1.0.14→1.0.16. Usage probes all healthy.
- Baseline = evidence_fixtures minus `schema_drift.jsonl`; to clear a monitor flag the new type/keys MUST be in a non-drift fixture listed in evidence_fixtures.

**Key files:**
- `skills/agent-session-format-check/SKILL.md` — the workflow source of truth
- `docs/agent-support/agent-support-matrix.yml` / `-ledger.yml`, `docs/agent-json-tracking.md` — version records
- `Resources/Fixtures/stage0/agents/claude/subagent/` — new subagent fixture trio

**Next:**
1. Nothing outstanding for this task. Follow-up triggers per SKILL.md decision matrix on next weekly run.
2. NOTE: main checkout has a parallel session's uncommitted work (Codex usage-window classification: CodexStatus/*, pbxproj, CHANGELOG.md, new CodexRateLimitWindowClassifier.swift + design spec) — NOT this session's; left untouched.

## 2026-07-12 19:08 · perf-instant · Runway idle-CPU fix landed on main; strategy doc; xhigh review
status: done

**State:** perf/instant-2026-07-12 merged to main `bf403fe8` (c14be03b + auth fixes; 1,552 tests green; NOT pushed). QM-visible idle CPU 25–41% → ~11% median, runway parse weight ~75× down.

**Decided / don't redo:**
- Runway cache design: only bytes-derived artifacts cached (key = path+mtime+size); ALL now-dependent state recomputed per cycle — verified byte-identical by 4 independent reviewers. Don't "optimize" the per-call filter/finalize into the cache.
- Refuted: 0.08s filter debounce is a sound trade (not a regression); RunwayFileSignature≠SessionFileStat duplication is justified (sub-second mtime needed).
- Strategy (Marketing/STRATEGY_2026-07-12_wow-and-1k.md, untracked): NO standalone meter spinout (CodexBar/steipete 17.8k owns it), NO Tauri/Rust port; wedge = per-session burn attribution; wow = Wrapped card + shareable transcripts + Memory Inspector; growth = upstream-issue comments, awesome-claude-code #1726, homebrew-cask.

**Key files:**
- `docs/perf-2026-07-12-runway-idle-fix.md` — measurements + cache invariant
- Worktree `/Users/alexm/Repository/Codex-History-perf` still exists (merged; removable)

**Next:**
1. Before next release: CHANGELOG/summaries bullets (shimmer/Reduce-Motion is user-visible) + inline the 3 new FeatureFlags gates per agents.md policy (~10 min).
2. Optional review one-liners: Codex cache self-prune, `Value: Sendable`, shimmer `.tolerance` (15 findings filed, none blocking).
3. Push main when ready. DB migration-wipe fix runs in its own task session (task_8773aec9).
4. Careful committing in main checkout: a parallel session has uncommitted edits there (usage-auth files + pbxproj) — not this session's work.

## 2026-07-10 18:28 · usage-auth-surfacing · Unified auth surfacing + guided Fix flow across all usage meters
status: done

**State:** Shipped to `main` this session: burn-meter zombie fix `9e521e51`, then the auth-surfacing redesign `f9e476eb` (amended). Full suite green (1534). Not pushed. Live-verified in the running `.deriveddata-run` build; user re-authed Claude so meters are OAuth-live again.

**Decided / don't redo:**
- Burn-projection zombie: fix is retention-expiry ONLY (3-min), in the shared `UsageLimitProjectionTracker`. The "re-baseline on long idle" idea is UNSOUND — integer-percent Codex can't tell a slow burn from idle-then-resume (breaks pinned slow-burn tests).
- All 4 usage surfaces (footer strip, menu-bar face, menu-bar dropdown, Cockpit HUD "QM") now share `QuotaData.presentationState` (live / reconnecting / needsAction). Never render a raw `0%` for untrustworthy data.
- "QM" = the Agent Cockpit HUD in Meter mode (`HUDLimitsRowsPanel`/`Bar`/`DetailPanel`) — a separate 4th surface, easy to miss.
- Expired escalation is timer-driven (~90s), independent of poll cadence.

**Key files:**
- `Shared/Views/AuthRemediationBanner.swift` — shared banner (chip/compact/full) + guided `AuthFixView` dialog + `AuthFixWindowController`.
- `Views/CockpitFooterView.swift` — `QuotaData.presentationState`, `FooterRetryChip`, footer bg removed.
- `ClaudeStatus/ClaudeOAuth/ClaudeUsageSourceManager.swift` — 90s escalation one-shot timer; `refreshNow()`/credential-watch now `invalidateCache()` so `claude auth login` recovers WITHOUT relaunch.
- `Views/AgentCockpitHUDView.swift` — QM presentationState + `HUDLimitsRetryCell`.

**Next:**
1. Token-cache-invalidation recovery is logic-verified only (token currently valid) — confirm live next lapse.
2. Test-hygiene bug flagged as task_230de850: `ClaudeUsageSnapshotStoreTests` writes fixture (`deadbeef`) to the REAL `~/Library/Application Support/.../claude_usage_latest.json`, polluting the running app's cache. Fix pending in a separate session.
3. Parallel work left UNCOMMITTED in the tree (not mine): `CodexRunwayModel`, `FirstRunSetupView`, `CodexUsageParserTests` (+175), `docs/*`, `CLAUDE.md`.
4. Consider push + version bump/release notes if shipping.

## 2026-07-09 16:49 · runway-auth · Cause-aware degradation, no-CLI ladder, probe hardening + CLI-logout runway fix
status: in-progress
branch: main @ 99ab8a03 (dirty: 2 files — pre-existing untracked REDDIT_*.md, not this work)

**State in one line:** Runway-auth P1–P5 shipped to origin/main (through bf0a6a2e), 1506 tests green; owner elected to skip live 15-min confirmation + in-app QA, so deploy is gated only on version bump + release notes.

### Already decided / don't redo
- AS is a READ-ONLY usage reader — NEVER mint/refresh its own subscription token (no PKCE / in-app OAuth). Owner-cancelled (ToS/ban risk).
- No-CLI rung-1 = existing claude.ai Web API mode (ClaudeWebCookieResolver + claudeWebApiEnabled), NOT a "reopen Claude Desktop" hint (Desktop uses its own encrypted store).
- Auto-mode interactive tmux fallback is default-OFF / opt-in (behavior change — must be release-noted). Delegated refresh (CLI refreshing its OWN token) is retained.
- Don't spawn `claude`/`claude auth` in loops or relaunch spuriously (ban risk). os_log is a black box from stdout — profile via direct-binary-launch.
- ClaudeUsageStripView was dead code (deleted); live surfaces = Cockpit HUD/footer + menu bar.

### Key files
- `AgentSessions/ClaudeStatus/ClaudeOAuth/ClaudeUsageSourceManager.swift` — successAdvisory (healthy fetch always `.ok` + gentle caption), first401At debounce, captionOnly emits, cold-start fallback deferral, tmuxFallbackPermitted opt-in.
- `AgentSessions/ClaudeStatus/ClaudeUsageModel.swift` — transientReason/captionOnly, currentSource, cliPresent wiring, lastSuccessAt spinner fix, refresh-request observer.
- `AgentSessions/Shared/UsageAuthStatus.swift` + `Views/AuthRemediationBanner.swift` — Remediation.noCLILadder + Web-API/install alert.
- `AgentSessions/Resources/claude_usage_capture.sh` — auth-check-before-send-keys + BROWSER suppression (symlinked to tools/).
- Root-cause anchor: `AgentSessions/Views/AgentCockpitHUDView.swift:4945` — HUD blanks meters on ANY alarming verdict (no freshness check).

### Verified
- 1506 tests, 0 failures (full suite, 2026-07-09). All runway commits on origin/main; HEAD 99ab8a03, 0 unpushed.
- OAuth usage API returns HTTP 200 with the valid keychain token (~8h left, refresh token present).
- QM works with CLI logged out on the fixed build (user-confirmed — right after relaunch).

### Believed / unverified
- The runway fix HOLDS past the ~15-min reprobe mark — argued from code/tests, NOT a long live run. Owner accepted this as risk (skipped).
- No-Safari probe path, no-CLI ladder alert, opt-in toggle not owner-QA'd in-app (ladder proven via a DEBUG test seam). Owner accepted as risk (skipped).

### Next steps (prioritized)
1. DECIDE: version bump (still 4.2 / build 55) + user-facing release notes (default-OFF fallback is a behavior change) via the release-notes skill.
2. DECIDE: confirm the release intentionally bundles other sessions' work (transcript-selection fix, handover skill) or cut a scoped release.
3. Deploy via the `deploy` skill (re-runs QA via the stamp).
4. Optional (deferred, owner may skip): 15-min live confirmation / stub `{"loggedIn":false}` repro; diagnostics-pane observability (currentAuthState + cliStatusCache age); the 2 low review findings.

### Risks / landmines
- Deploy would ship other sessions' work too (transcript-selection fix, handover skill) — confirm intended for this release.
- os_log uncapturable from stdout — diagnose OAuth via direct-binary-launch or add a diagnostics ring buffer.
- Runway fix's post-15-min behavior is unproven live (accepted risk) — if runway ever blanks again, the anchor is the HUD render at AgentCockpitHUDView.swift:4945 + any new alarming-verdict source.

### How to verify
- `xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO test`
