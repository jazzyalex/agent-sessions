# Agent Sessions CLI: product evaluation and revised plan

Prepared 2026-10-24 by Claude (claude-opus-5-5) from `2026-10-24-claude-cli-research-transfer.md`. Research and planning only. No code, configuration, tests, branches, commits, outreach or private-history reads were performed.

## Verdict

**Do not build the 2026-10-23 six-slice CLI plan now. Run a short, zero-code validation first, then build at most a narrow `export`/`read` helper if it passes.** The prior PLAN READY verdict is sound for the architecture it reviewed. It does not show that the product deserves that architecture.

Three findings drive this:

1. **The external demand is for a different job.** Issue #80, the only outside request, asks for one command that saves a readable transcript of the current chat. The user says they "don't even need the list functions". The plan has no export command; its `read` returns paged JSONL with 4 KiB field truncation.
2. **A larger free competitor already ships the proposed interface.** AgentsView (6,262 stars, macOS/Linux/Windows, 50+ agents) has `agentsview session search/list/messages --json` and a read-only MCP server with paginated message reads, semantic/hybrid search and recall. The plan does not mention it.
3. **The phase-two premise has no owner.** The PR #77 contributor has not answered the maintenance question in 25 days, and the Linux console release assets show one download each.

## Part 1: Product findings

### Candidate jobs, reassessed

| Job | Evidence it recurs | Existing solutions | Assessment |
| --- | --- | --- | --- |
| J1. Developer finds an old decision | Strong for the GUI: 10 of 10 manual survey respondents use history and search (Feb–Jun cohort). | Agent Sessions GUI already; AgentsView; native resume pickers. | Already served by the product. A CLI adds little for humans who have the app. |
| J2. Coding agent retrieves evidence from earlier sessions | Owner direction (2026-09-29). No user request names it. | AgentsView MCP and session CLI; Codex native memories cite prior rollouts (`memory_citation.rolloutIds`, Codex 0.149, `docs/backlog.md:1390`); plain `rg` over JSONL. | Hypothesis. Plausible and fashionable, but contested by a stronger incumbent. |
| J3. Move context between providers | No request found. | Manual copy; AgentsView MCP is provider-neutral. | Hypothesis with no evidence. Do not design for it yet. |
| J4. Terminal/TUI browsing | One contributor prototype; no user request; 1 download per console asset. | AgentsView web UI; native pickers. | No evidence. Drop from the roadmap unless a maintainer and users appear. |
| J5. Export a session transcript on request, from inside an agent | Issue #80 (2026-09-30, explicit command shape). Issue #29 "Export and share session transcript" (2026-03-30). | GUI export (manual, app switching); `claude-code-log` for Claude only (the #80 user already uses it); AgentsView `export`. | The only job with direct external evidence. Narrow and cheap. Feasible for "current chat" (see U3). |

### Evidence ledger

Dates are when the fact was checked (2026-10-24) unless stated.

| # | Claim | Source | Observed fact | Limitation | Decision |
| --- | --- | --- | --- | --- | --- |
| E1 | Owner wants agent retrieval first | [PR #77 comment](https://github.com/jazzyalex/agent-sessions/pull/77#issuecomment-5899242742), 2026-09-29 | Owner prioritizes "coding agents finding and reading previous sessions". | Maintainer intent, not user demand. | Treat J2 as the hypothesis to test. |
| E2 | Outside users want an agent-callable CLI | [Issue #80](https://github.com/jazzyalex/agent-sessions/issues/80) | One user (kupietools). Wants `--archive [sessionID] --format md --location`. Goal: look back at decision-making. Already uses claude-code-log for Claude; wants Codex. No reactions, no other participants. | n = 1. | Supports a narrow export command, not search/index. |
| E3 | Linux/TUI demand | PR #77; [fork releases](https://github.com/shurrman/agent-sessions/releases/tag/console-v0.1.0) | Contributor-built. `console-v0.1.0` (2026-09-20): 7 assets, 1 download each. Fork's last commit 2026-09-21. No reply to the 2026-09-29 maintenance question; companion PR has no comments or reviews. | Download counts may include the contributor. | No demand, no maintainer. Remove Linux and Go TUI from the plan. |
| E4 | Survey signal | `docs/product-feedback/2026-09-14-google-form-survey-report.md` | 9 unique actionable submissions; none mention CLI, terminal access or agent access. History and search are universal in the manual cohort. | Old cohort and form; small n; absence is weak evidence. | Users value the GUI search job. No CLI signal. |
| E5 | Issue-tracker signal | `gh search issues` for cli, terminal, headless, search, retrieve, MCP, export, markdown, linux, tui, memory | Only #80 asks for a CLI. Export recurs: #29, #80. No Linux, TUI, MCP or headless requests. | Keyword search can miss phrasing. | Export is the recurring outside request. |
| E6 | The proposed interface already exists elsewhere | [kenn-io/agentsview](https://github.com/kenn-io/agentsview): `docs/session-api.md`, `docs/mcp.md` on main | 6,262 stars; v0.46.1 on 2026-10-23; pushed 2026-10-25. `session search "…" --json --limit 10`, `session messages <id> --from 0 --limit 20 --json`. MCP tools include `search_sessions`, `get_messages`, `search_content` (semantic/hybrid), `query_recall`, `get_recent_edits`. MCP doc first committed 2026-06-25. | Docs read, not runtime-tested. | The plan's J2 product is a subset of a shipped, free, cross-platform competitor. Any build needs a stated reason to choose Agent Sessions instead. |
| E7 | Providers are adding native recall | `docs/backlog.md:1390` (verified 2026-08-21) | Codex 0.149 `memory_citation` lists the other rollouts a turn drew on. | One session deep in the local corpus. | J2 within one provider is being absorbed by the provider. |
| E8 | Agents can identify their own session | Claude Code [CHANGELOG](https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md) line ~5970; openai/codex `codex-rs/core/src/exec_env.rs` | Claude Code sets `CLAUDE_CODE_SESSION_ID` in the Bash tool environment. Codex source references `CODEX_THREAD_ID` in its exec environment. | Not executed here; exact Codex conditions unverified. | "Export this chat" can work without the user copying IDs. |
| E9 | Growth context | GitHub API | 913 stars (850 on 2026-09-09). Owner goal: 1k by end of 2026. | Stars are not retention. | Opportunity cost: a CLI is not shown to move the goal. |
| E10 | Launch copy | `Marketing/STATUS.md:3` | Drafts assume a shipped CLI at the owner's request. | Hypothetical by design. | Not evidence. |

**Verified demand:** one user wants agent-invoked transcript export (E2), and one earlier user wanted export/share (E5). **Inference:** existing Agent Sessions users might let their agents query the history the app already indexes, with no extra setup. **Unknown:** whether anyone wants J2 enough to choose Agent Sessions over AgentsView or native recall, and whether agents reliably use such a tool.

### Alternatives (dated 2026-10-24)

Stars and push dates from the GitHub API on 2026-10-24/25. Interface facts are from each project's README or docs, not runtime tests.

| Tool | Stars / last push | Jobs covered | Agent-facing form | Platforms |
| --- | --- | --- | --- | --- |
| [AgentsView](https://github.com/kenn-io/agentsview) | 6,262 / 10-25 | J1, J2, J4 (web UI), J5 | `session … --json`, read-only MCP, Claude/Codex plugins | macOS, Linux, Windows; Homebrew cask |
| [Entire CLI](https://github.com/entireio/cli) | 5,214 / 10-24 | J1, J2 (git checkpoints, semantic search) | `entire agent-help`, search skill, `--json` | macOS, Linux, Windows |
| [claude-mem](https://github.com/thedotmack/claude-mem) | 102,842 / 10-25 | J2 (AI-compressed observations, not raw transcripts) | Plugin, `mem-search` skill, MCP | Cross-platform |
| [SpecStory CLI](https://github.com/specstoryai/getspecstory) | 1,356 / 10-23 | J5 (auto-saves Markdown), J1 | Partial | Homebrew |
| [deja-vu](https://github.com/vshulcz/deja-vu) | 1,303 / 10-24 | J1, J2, J4 | MCP | macOS, Linux, Windows |
| [claude-code-log](https://github.com/daaain/claude-code-log) | 1,250 / 10-09 | J4, J5 (HTML/Markdown; Codex marked beta) | `--format md` for feeding LLMs; no MCP | PyPI/uvx |
| [cass](https://github.com/Dicklesworthstone/coding_agent_session_search) | 1,190 / 10-24 | J1, J2, J4 (Rust TUI) | Robot mode `--json`, SKILL.md | macOS, Linux, Windows |
| [episodic-memory](https://github.com/obra/episodic-memory) | 493 / 09-10 | J2 (local embeddings) | MCP, skill, Claude/Codex/OpenCode plugins | npm |

Native tools (official docs, 2026-10-24): Claude Code `/resume` picker with search and `/export` to plain text ([sessions docs](https://code.claude.com/docs/en/sessions)); Codex `codex resume` and opt-in memories (`memories = true`); OpenCode `opencode session list --format json` and `opencode export` to JSON ([CLI docs](https://opencode.ai/docs/cli/)); Cursor `agent ls`/`agent resume`. None crosses providers. None exports Markdown natively except via third-party tools.

Upstream demand for recall exists but centers on continuity after compaction, not a history CLI: anthropics/claude-code #15542 (98 reactions), #27242 (91), #11455 (26). Direct "search past sessions" requests there (#30744, #72574) have zero reactions and were closed as duplicates.

Agent discovery: Claude Code and Codex both load `SKILL.md` skills chosen by description ([Claude skills](https://code.claude.com/docs/en/skills), [Codex skills](https://learn.chatgpt.com/docs/build-skills)). Directories differ: `~/.claude/skills` versus `~/.agents/skills`.

**Reading:** J2 and J4 are crowded with active, cross-platform, free tools that already have JSON modes, MCP servers and skills. J5 is partly covered (claude-code-log, SpecStory), but Codex-from-inside-Codex Markdown export is the gap the #80 user named. J3 has only small converters and no evidence of demand here.

### Where Agent Sessions could still differ

These are hypotheses to test, not established advantages:

- **Zero setup for existing users.** The app already maintains an FTS index at `~/Library/Application Support/AgentSessions/index.db` (`AgentSessions/Indexing/DB.swift:144-146`, tables `session_search`/`session_search_fts` at `:419-470`, `session_meta` at `:212-235`). An agent could query that without a second indexer or daemon.
- **Native Mac distribution and parsers already qualified for 17 sources**, including compressed Codex, which competitors may handle differently (unverified).
- **Trust posture:** no telemetry, read-only toward provider stores. AgentsView is also read-only toward stores, so this is not unique.

### Opportunity cost

The plan's slices 1–6 touch the shared parsers, a new SwiftPM package, a new cache store, release signing and the Homebrew generator. That competes with GUI retrieval-correctness work, provider format drift (weekly sweeps, stewards) and the 1k-star goal. None of those slices has user evidence behind it beyond E2, which they do not serve.

## Part 2: Technical findings

### Source drift since the reviewed main

- Reviewed main `3c5a3324`; current HEAD and `origin/main` are both `a3e3fb35` (`git ls-remote`, 2026-10-24). Two commits landed: `2044e3c5` and `a3e3fb35`, OpenCode live-presence identification.
- They touch `UnifiedSessionIndexer.swift` (+57 lines in presence paths), two new OpenCode presence files, `CodexActiveSessionsModel.swift`, `PresenceEngine.swift` and `SessionRowsBuilder.swift`. No parser, `SearchIngestService`, `DB.swift`, resume-builder or release-script changes.
- Effect: architecture conclusions still hold. Line citations into `UnifiedSessionIndexer.swift` after line ~695 have shifted; for example the identity snapshot hand-off cited at `1885-1919` is now near `1940-2018`.
- Uncommitted work in the checkout (CodexStatus, MenuBar, QuotaStrip, Cockpit views, one test, CHANGELOG, backlog, monthly summary) is unrelated to the CLI and was not touched.

### Confirmed defects in the plan

1. **Evidence misread (plan line 11).** It cites #80 as independent support for agent retrieval. #80's actual job is export of the current session; the plan serves it with nothing.
2. **No agent-discovery artifact.** The plan states the agent is the primary user, yet ships no skill, AGENTS.md snippet or MCP entry. An agent will not call a CLI it is not told about. Both Claude Code and Codex now load Agent Skills (see alternatives section), so a skill file is the cheapest integration.
3. **Phase two depends on an absent maintainer** (E3). The plan notes no commitment is assumed, but still schedules a Go TUI and Linux path. Without the contributor, that is a second language and packaging stream owned by the owner.
4. **Competitive position omitted** (E6). A plan whose rationale is agent retrieval must say why an agent user picks this over AgentsView MCP.

### Design tradeoffs: where the complexity comes from

Most of the plan's mass follows from one choice: **a standalone CLI with its own persistent cache, built from an extracted SwiftPM core.** That choice requires root-scope hashing, `CLIIndexStore`, ownership/version guards, a cross-process writer lock, connection-lifetime leases, SQLite-safe rebuild cutover, a shared refresh planner, worker supervision and a second build path for shared sources. Each contract is correct given the choice. The choice itself is not justified by evidence:

- The CLI ships inside `AgentSessions.app` anyway (plan line 153). Its users therefore have the app, and the app already maintains an index.
- Linux is out of phase one, removing the main reason for a GUI-free SwiftPM core.

**Smaller coherent alternative (hypothesis, needs a spike before commitment):**

- `read` and `export` parse the selected session file directly with the existing app parsers, plus the strict-outcome fix the reviews identified (Codex `readSucceeded`, Claude JSONL I/O termination, OpenCode v1 completion). Always fresh; no cache.
- `search` and `list` (only if J2 survives validation) open the app's existing `index.db` read-only and report its freshness from `index_state`/`session_search.updated_at`. No second cache, so no writer lock, leases or rebuild cutover.
- Host: either a headless entry point in the app executable, or a small helper target compiling the needed parser files. The spike decides which.
- Keep from the reviewed plan: strict ParseOutcome, `contentTrust: untrusted_history`, bounded pages, explicit truncation, typed resume argv, no app-cache mutation, read-only opens, explicit JSON errors and exit codes.
- Drop for now: scope hashing and multi-root namespaces, `CLIIndexStore`, writer lock, leases, rebuild cutover, refresh-planner extraction, SwiftPM package, worker re-exec, stats, Go TUI, Linux.

Costs of the alternative, stated plainly:

- `search` is only as fresh as the app's last ingest. Quiet period is 120 s; re-ingest cooldown is 15 min for 2–20 MB files and 45 min above that (`SearchIngestService.swift:232-240,268`). Results must report index time.
- Requires the app to have run at least once. Fine for the stated audience (existing users); wrong for agent-first users without the GUI. If validation finds that audience, revisit the standalone cache.
- Couples the CLI to an internal schema. Acceptable because both ship in one bundle and version; needs one schema-version check.
- The app's index text is sampled (48k characters per session). A no-match result is inconclusive; say so in output. The same limit applies to the original plan.

### Distribution notes

- Helper inside the app plus a Homebrew `binary` stanza is still the right channel if anything ships. Update `tools/release/deploy-agent-sessions.sh` cask generation (currently `app` only, around line 863) and `verify-deployment.sh`.
- Unknown U4: whether users who update through Sparkle rather than `brew upgrade` get the new link. Document a manual `ln -s` regardless.

## Part 3: Revised research and planning recommendation

### Gate 0: validate with no production code (owner-run, about two weeks)

All actions below need the owner's go-ahead where marked. None reads or uploads private history on Claude's behalf.

| Step | What | Owner action needed | Measures |
| --- | --- | --- | --- |
| V1 | Incident diary. Owner logs each time they or an agent needed something from a past session: job (J1–J5), provider, how solved, minutes spent, whether the GUI sufficed. | Owner keeps the log. | Frequency of J2/J5 versus J1. |
| V2 | Skill pilot, no code. A `SKILL.md` teaching an agent to (a) query the app index read-only with `sqlite3 "file:…/index.db?mode=ro"` over `session_search_fts` joined to `session_meta`, and (b) read raw session files with `rg`/`jq`/`zstd -dc`. Use in the owner's own Claude Code and Codex sessions. | Owner installs the skill locally and chooses tasks. | Retrieval success, failure types (compressed files, noise, huge lines, schema confusion, stale index), tokens and time. |
| V3 | Baseline against AgentsView MCP on the same V2 tasks. | Owner installs AgentsView (not authorized for Claude). | Whether Agent Sessions has any real advantage. |
| V4 | Reply on #80 asking whether `agent-sessions export --current --format md --out <path>` for Codex and Claude covers the need. Draft below. | Owner posts. | Confirmation or correction from the only outside requester. |
| V5 (optional) | Add "Let my coding agent search or export sessions" to the feedback form's feature list. | Owner edits the form. | Unprompted interest over the following month. |

Draft #80 reply (for the owner to post or edit):

> Thanks again for the details. I'm scoping the smallest useful version. Would this cover it: `agent-sessions export --current --format md --out ~/notes/chat.md` from inside a Codex or Claude Code session, with no app window opening? `--current` would use the session ID that Codex and Claude Code already pass to shell commands. You could also give a session ID or file path. Anything missing for your workflow?

**Proposed decision rules (for the owner to accept, change or reject; not agreed):**

- Build the narrow export helper (Gate 1) if V4 confirms the shape, or V1 shows at least a few J5 incidents per week for the owner.
- Consider agent search (Gate 2) only if V2 shows repeated failures that a structured `read`/`search` would fix, and V3 shows a concrete reason to prefer Agent Sessions over AgentsView.
- Defer all CLI work if V2 succeeds with the skill alone (then publish the skill, not a CLI), or if V3 shows AgentsView fully covers the job.

### Gate 1: narrow `export` and `read` (only after Gate 0 and owner approval to code)

Scope: Codex and Claude Code. OpenCode only if V1/V2 show use.

Acceptance criteria:

1. `agent-sessions export (--current | <session-id> | <path>) --format md|json [--out <path>]` writes a readable transcript equivalent to the GUI export for the same session.
2. `--current` resolves `CLAUDE_CODE_SESSION_ID` or `CODEX_THREAD_ID`; when neither is set it fails with a usage error that tells the agent how to pass an ID.
3. `agent-sessions read <ref> --offset --limit` keeps the companion PR's bounded-page contract (event IDs, explicit truncation, `contentTrust: untrusted_history`).
4. Compressed-only Codex `.jsonl.zst` sessions work.
5. Incomplete reads fail with a nonzero exit and a typed error; no file is written as if complete.
6. Runs with the app closed. Creates and changes nothing in the app index, preferences, ImageBrowser cache or provider stores, proven by before/after hashes against a temporary HOME fixture.
7. Ships signed inside the app at `Contents/Helpers/agent-sessions`, linked by the Homebrew cask, with a manual symlink documented.
8. Ships a `SKILL.md` and an AGENTS.md snippet so agents can find it.
9. Full app test suite passes with the test count unchanged or the drop explained; new fixture tests cover 1–6.

Dependencies: the strict-outcome parser fix; the host spike (U1); release-script and cask-generator changes.

### Gate 2: agent search (only if Gate 0 rules say so)

`search`/`list` over the app index read-only, with freshness and "no match is inconclusive" in every response. Revisit the reviewed standalone-cache design only if validation finds users who want the CLI without the GUI.

### Phase two (TUI, Linux): removed from the active plan

Re-open only with (a) a named maintainer for Go and Linux packaging, and (b) user requests for terminal browsing. The reviewed TUI fixes in the shipping plan remain valid reference if that happens.

### Unknowns and the evidence that resolves them

| ID | Unknown | Resolves with | Changes the recommendation if |
| --- | --- | --- | --- |
| U1 | Can the app executable run a headless subcommand without AppKit start-up side effects (probes, Dock icon, single-instance), or is a separate helper target cheaper? | A throwaway spike, after approval to code. | A clean headless entry makes Gate 1 much smaller. |
| U2 | Does a read-only open of the live app index behave while the app writes (WAL)? | Spike on a copy that includes `-wal`; existing note: `mode=ro` works when the `-wal` file is present. | Failure pushes Gate 2 back toward a separate cache. |
| U3 | Are `CLAUDE_CODE_SESSION_ID` and `CODEX_THREAD_ID` set in all relevant contexts (Desktop, IDE, exec, subagents)? | Owner runs `env | grep -E 'CLAUDE_CODE_SESSION_ID|CODEX_THREAD_ID'` in each surface. | Missing variables make `--current` unreliable; fall back to `list --cwd`. |
| U4 | Do Sparkle-updated installs get the Homebrew binary link? | Release-candidate install test. | Documentation only. |
| U5 | How often does the 48k sampled index miss what agents search for? | V2 failure log. | Frequent misses argue for raw-file search in `read`, not a bigger index. |
| U6 | Does anyone prefer Agent Sessions over AgentsView for agent access? | V3, V4, V5. | No preference: defer CLI and invest in the GUI. |

### Documents this evaluation supersedes or qualifies

- `2026-10-23-macos-cli-shipping-plan.md`: architecture contracts remain valid reference. Its product rationale (line 11) and phase sequencing are superseded by this document.
- `docs/backlog.md` "CLI follow-ons" entry: still accurate that nothing is merged. Not edited here because the file has concurrent uncommitted changes from another session.
