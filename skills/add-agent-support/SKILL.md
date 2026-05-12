---
name: add-agent-support
description: Plan, research, install, test, implement, validate, document, and market new AgentSessions agent/provider support. Use when adding, reviewing, or deciding whether to support a new local AI agent, CLI, IDE, transcript source, session parser, support-matrix entry, verified-version bump, release wording, or provider integration; requires pre-support research for region access, English usability, free-plan testability, approved binary install/auth, real local test-session capture, fixture evidence, format monitoring, discovery contracts, subagent evaluation when useful, implementation validation, and conservative marketing claims.
---

# Add Agent Support

## Core Rule

Treat provider support as unsupported until proven on this machine. Do not implement, merge, release, bump verified versions, or market a provider from docs, vendor claims, or synthetic fixtures alone.

Before coding, prove:
- The provider is usable from the user's region.
- The product/docs/UI are usable in English.
- A free or existing plan can create real test sessions.
- Installation and auth are practical on this Mac.
- Real local transcript/session data can be generated or obtained.
- Redacted fixtures preserve real keys, event names, timestamps, and content shape.

If a hard gate fails, recommend rejecting or deferring the provider politely.

For an existing supported provider, do not bump verified versions or public claims until the repo's `agent-session-format-check` evidence passes.

If a provider is rejected after installing test binaries or apps, remove the installed binary/app and its test-only support/state paths before finishing.

## Required Workflow

1. Create a pre-support report before implementation.
   - Run `scripts/new_agent_presupport_report.py` to create the report scaffold.
   - Fill the report with evidence, exact dates, URLs, command output, local paths, and blocker status.
   - Keep uncertainty labeled as `Hypothesis:` until verified.

2. Classify the work.
   - `new_provider`: no existing AgentSessions support. Run all pre-support gates before implementation.
   - `existing_provider_update`: provider already exists. Use `skills/agent-session-format-check/SKILL.md` to prove schema, usage probes, storage layout, and discovery contracts still match before bumping support.
   - `public_claim`: docs/release/social wording only. Verify implementation and format-check evidence before wording changes.

3. Research the environment fit.
   - Confirm region availability from official docs, live install/auth behavior, or vendor status.
   - Confirm English usability for docs, CLI help, UI, errors, auth flow, and support pages.
   - Confirm the free-plan path can create enough data to test parser behavior.
   - Ask before installing apps, logging in, connecting accounts, or running networked agent tasks.

4. Install or locate the agent binary only after the research gate is plausible.
   - Prefer official install paths and record exact URLs, package names, versions, checksums when available, binary paths, and app bundle IDs.
   - Ask before installing global packages, desktop apps, browser extensions, or anything requiring login.
   - Before installing or logging in, snapshot existing binary lookups, app bundles, package-manager ownership, and support/state roots so cleanup never deletes pre-existing user data.
   - Verify `--version` and `--help` when available.
   - Record whether uninstall/cleanup is possible and how to perform it.
   - If region, language, auth, or plan gates fail, stop and clean up test-only installs instead of continuing into parser work.

5. Run existing-provider format checks when applicable.
   - In `/Users/alexm/Repository/Codex-History`, run:
     ```bash
     ./scripts/agent_watch.py --mode weekly
     ```
   - If weekly says `recommendation == run_prebump_validator`, or before staging any `max_verified_version` bump, run:
     ```bash
     ./scripts/agent_watch.py --mode prebump --agent <name>
     ```
   - Treat exit `0` as format evidence, `2` as schema drift, `3` as driver/auth/discovery failure, and `4` as config/invariant failure.
   - Inspect `scripts/probe_scan_output/agent_watch/*/report.json` for `schema_matches_baseline`, `sample_freshness.is_stale`, probe health, and `discovery_path_contract`.

6. Create real test sessions.
   - Generate a tiny safe project under `/tmp`.
   - Run the provider against harmless files only, using read-only prompts when possible.
   - Create at least one normal session and one follow-up/continued session if the provider supports continuation.
   - Capture auth failures honestly; an auth-required transcript can prove storage shape but not full support.
   - Locate real session storage using scoped paths, not broad `$HOME` scans.
   - Inspect JSONL/JSON/SQLite/schema with structured tools.
   - Record session IDs, timestamp shapes, event names, role fields, content shapes, tool calls/results, cwd/model fields, and artifact directories.

7. Evaluate evidence, using subagents when useful.
   - Use subagents for independent, bounded work only when explicitly allowed by the user or when the current session already authorizes subagent-heavy work.
   - Good subagent splits: official-doc region/plan research, local format inspection, parser surface audit, fixture secret review, UI/docs claim review.
   - Do not delegate the immediate blocker if the main task depends on it next.
   - Ask subagents for evidence and paths, not conclusions alone.

8. Decide before coding.
   - `ACCEPT`: all hard gates pass and real fixture-backed parsing is feasible.
   - `DEFER`: blocked by auth, paid plan, missing fixture data, stale samples, or unclear storage.
   - `REJECT`: region, language, licensing, support burden, or product fit makes maintenance impractical.

9. Implement only after `ACCEPT`.
   - Follow the existing AgentSessions provider patterns.
   - Add redacted real fixtures, not representative synthetic fixtures.
   - Add parser, discovery, search, settings, analytics, resume/copy command, active/live status, and UI wiring only for surfaces truly supported.
   - Make Preferences/root overrides visible when shell environment variables will not reach macOS apps.
   - Avoid feature flags unless explicitly requested.
   - Keep public wording limited to verified behavior.

10. Update support records only after evidence passes.
   - Refresh fixtures under `Resources/Fixtures/stage0/agents/<agent>/`.
   - Update `docs/agent-support/agent-support-matrix.yml` only for verified behavior.
   - Append `docs/agent-support/agent-support-ledger.yml`.
   - Add `docs/agent-json-tracking.md` upstream-version log entry.
   - Keep raw captures private under `scripts/agent_captures/<timestamp>/<agent>/`; do not commit raw sessions.

11. Validate before merge.
   - Run focused parser/discovery/search/provider tests.
   - Run `git diff --check`.
   - Run the stable test wrapper when Swift/project files changed: `./scripts/xcode_test_stable.sh`.
   - Run a Debug build.
   - Scan fixtures for secrets and absolute user paths.

12. Write docs and marketing only after validation.
   - Add `[Unreleased]` changelog and `docs/summaries/YYYY-MM.md` bullets for user-visible support.
   - Update README/support matrix only for verified capabilities.
   - Use wording such as "browse/search local transcripts" unless resume, analytics, live status, or usage tracking are implemented and tested.
   - Include "transcripts stay local" only when indexing really reads local files and no cloud sync is involved.
   - Prepare social/release copy after the code and tests land, not before.

## AgentSessions-Specific Standards

Use `/Users/alexm/Repository/Codex-History` as the normal AgentSessions repo root unless the user says otherwise.

Provider support must be based on real local data. Prior examples showed that repo architecture can host providers, but storage readability and product availability must be proven separately. Do not infer support just because a parser can be written.

Lessons from prior provider attempts:
- A mergeable PR and green synthetic tests are not enough. Require real fixture-backed compatibility before release or marketing.
- If the local machine cannot install/auth/use the provider from the United States, do not claim support.
- If the product is not realistically usable in English, reject unless the user explicitly accepts that support burden.
- If an installed test app or CLI is rejected, remove it and its test-only local state.
- Do not keep experimental provider branches alive after deciding support is not planned; close follow-ups politely.

Use these repo-local skills/docs as supporting inputs when present:
- `skills/agent-session-format-check/SKILL.md`: schema drift, usage/limits probes, storage backends, discovery path contracts, and prebump validation.
- `skills/agent-support-matrix/SKILL.md`: support matrix, ledger, and version-bump recording workflow.
- `docs/agent-support/monitoring.md`: severity model and monitoring cadence.

Known discovery contracts from the format-check workflow:
- Codex: `*/sessions/YYYY/MM/DD/rollout-*.jsonl`
- Claude: `~/.claude/projects/**/*.{jsonl,ndjson}`
- OpenCode: `*/opencode/storage/session/*/ses_*.json`
- Hermes: `~/.hermes/sessions/session_*.json`
- Gemini: `~/.gemini/tmp/<hash>/(chats/)?session-*.json`
- Copilot: `~/.copilot/session-state/*.jsonl`
- OpenClaw: `*/agents/<id>/sessions/*.jsonl`
- Cursor: `~/.cursor/projects/*/agent-transcripts/*/*.jsonl`

For public closeout, release notes, README, docs, and social copy:
- Say only what was actually implemented and tested.
- Prefer "browse/search local transcripts" unless resume, analytics, live status, or usage tracking are implemented.
- If support is rejected, thank contributors and state the maintainability reason plainly.
- Avoid "fully supported" unless install, auth, real sessions, parser, discovery, UI, tests, docs, and support matrix all pass.

## Bundled Resources

- `scripts/new_agent_presupport_report.py`: generates a Markdown research report with local command/root probes, hard-gate sections, format-check evidence fields, and support-record update sections.
- `references/agent-provider-gates.md`: detailed gate checklist, existing-provider monitoring workflow, discovery contracts, support-record updates, and rejection wording templates.
