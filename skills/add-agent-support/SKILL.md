---
name: add-agent-support
description: Create and ship AgentSessions support for a new or changed local AI agent/provider. Use when adding, reviewing, testing, documenting, or marketing a provider integration, session parser, transcript source, support-matrix entry, verified-version bump, or provider UI surface; drives the full loop from pre-support research through binary install, real session capture, fixture redaction, parser/discovery/search/UI integration, QA, review/fix loops, support records, PR/release notes, and conservative marketing claims.
---

# Add Agent Support

## Mission

Use this skill to deliver maintainable AgentSessions provider support, not just to block bad providers. The gate phase exists to prevent unsupported work from entering the repo; when gates pass, continue through implementation, QA, review, documentation, and release-ready communication.

Do not implement, merge, release, bump verified versions, or market provider support from docs, vendor claims, or synthetic fixtures alone.

Before coding, prove:
- The provider is usable from the user's region.
- The product/docs/UI are usable in English, unless the user explicitly accepts a non-English support burden.
- A free or existing plan can create enough real sessions for parser QA.
- Installation and auth are practical on this Mac.
- Real local transcript/session data can be generated or obtained.
- Redacted fixtures can preserve real keys, event names, timestamps, and content shape.

If a hard gate fails, reject or defer politely and clean up test-only installs/state before finishing.

## Required Workflow

1. Start a support plan.
   - Run `scripts/new_agent_support_plan.py` to create the plan scaffold.
   - Fill it with evidence, exact dates, URLs, command output, local paths, and blocker status.
   - Keep uncertainty labeled as `Hypothesis:` until verified.
   - Use `references/agent-provider-gates.md` for hard gates and binary lifecycle details.
   - Use `references/agent-support-implementation.md` for implementation, QA, review, and release details.

2. Classify the work.
   - `new_provider`: no current AgentSessions support. Run all gates, capture real sessions, then implement.
   - `existing_provider_update`: provider exists. Use `skills/agent-session-format-check/SKILL.md` and `skills/agent-support-matrix/SKILL.md` before parser or version changes.
   - `public_claim`: docs/release/social wording only. Verify implementation and test evidence before changing wording.

3. Prove the provider can be supported.
   - Confirm region, language, account, plan, install, auth, and local-data availability.
   - Ask before global installs, GUI app installs, browser extensions, logins, account linking, or networked agent runs.
   - Snapshot pre-install binary/app/package/state paths before changing anything.
   - Install or locate the official binary/app only after the research gate is plausible.
   - Verify binary path, version, help output, app bundle metadata, auth behavior, and cleanup path.

4. Generate real test sessions.
   - Use a disposable project under `/tmp/as-agent-lab/<agent>-project`.
   - Run safe read-only prompts against harmless files unless edit behavior is explicitly under test.
   - Capture at least one normal session and one follow-up/continued session when supported.
   - Capture tool-call/tool-result behavior when the free or existing plan allows it.
   - If the provider supports subagents or child sessions, create a small session that exercises them.
   - If auth/region/plan blocks full creation, record the exact failure and do not fake fixture confidence.

5. Learn the real format.
   - Locate session storage with scoped paths only; do not scan all of `$HOME` blindly.
   - Inspect JSONL, JSON, SQLite, or multi-file stores with structured tools.
   - Record root layout, file patterns, session ID fields, timestamp shapes, event names, role fields, content shapes, model/cwd fields, tool call/result shapes, usage/limits records, artifact-only directories, and subagent relationships.
   - Decide whether unsupported surfaces should remain unsupported rather than half-wired.

6. Redact and add fixtures.
   - Add redacted real fixtures under `Resources/Fixtures/stage0/agents/<agent>/`.
   - Preserve real schema, event names, timestamps, and representative event families.
   - Remove names, emails, tokens, cookies, auth headers, private prompts, proprietary content, and absolute user paths.
   - Keep raw captures private under `scripts/agent_captures/<timestamp>/<agent>/`; do not commit raw sessions.
   - Run the fixture secret/path scan before review.

7. Implement provider support.
   - Follow existing AgentSessions provider patterns before inventing abstractions.
   - Wire only surfaces backed by evidence: parser, discovery, search, settings/root overrides, unified sessions UI, analytics, resume/copy command, active/live status, and usage tracking.
   - Add visible Preferences controls when macOS app execution will not inherit shell environment overrides.
   - Keep stable app session IDs unless a format demands otherwise.
   - Treat unknown event types as metadata with raw JSON preserved where the model supports it.
   - Avoid feature flags unless the user explicitly asks for them.

8. Test and QA the integration.
   - Add focused parser, discovery, search, and discoverability tests.
   - Add golden/fixture harness coverage if that harness is intended to cover supported providers.
   - Run `git diff --check`.
   - Run focused tests first, then `./scripts/xcode_test_stable.sh` when Swift/project files changed.
   - Run a Debug build after Swift or project integration changes.
   - For UI changes, launch or render-check the app surface and verify filters, transcript rendering, settings, and search behavior.
   - Restore macOS Appearance to `System` if QA changes it.

9. Review and fix until release-ready.
   - Review the diff findings-first, focusing on fixture evidence, parser drift tolerance, secret leakage, unbounded scans, overclaiming, analytics mismatch, and performance.
   - If using automated review, run it after tests pass, fix actionable findings, and repeat until clean or only consciously accepted low-risk notes remain.
   - Re-run focused tests and the Debug build after substantive fixes.

10. Update support records and docs.
   - Update `docs/agent-support/agent-support-matrix.yml` only for verified behavior.
   - Append `docs/agent-support/agent-support-ledger.yml`.
   - Add `docs/agent-json-tracking.md` upstream-version evidence.
   - Add `[Unreleased]` changelog and `docs/summaries/YYYY-MM.md` bullets for user-visible support.
   - Update README/support matrix only for surfaces that tests and fixtures prove.

11. Prepare PR, release, and marketing wording.
   - Prefer a follow-up PR for hardening unless the user explicitly wants direct main work.
   - Credit contributors politely when relevant.
   - Use "browse/search local transcripts" unless resume, analytics, live status, or usage tracking are implemented and tested.
   - Say "transcripts stay local" only when indexing really reads local files and no cloud sync is involved.
   - Prepare release notes, screenshots/GIFs, and social copy only after implementation, fixtures, tests, and build pass.

12. Clean up rejected or deferred attempts.
   - Remove only test-created binaries/apps/state proven by the pre-install snapshot.
   - Close or comment on PRs/issues politely with the verified maintainability blocker.
   - Remove abandoned worktrees/branches when support is not planned.
   - Leave the repo clean or clearly report any remaining uncommitted work.

## Subagents

Use subagents only when the user explicitly authorizes subagent work or the current task already asks for parallel agents. Good splits are:
- Official-doc and market/access researcher.
- Local binary/session capture operator.
- Format/schema inspector.
- Parser/discovery implementation worker.
- Fixture redaction and secret-scan reviewer.
- UI/search/docs/marketing reviewer.

Do not delegate install/login approval, destructive cleanup approval, or the immediate blocker on the critical path.

## AgentSessions Standards

Use `/Users/alexm/Repository/Codex-History` as the normal repo root unless the user says otherwise.

Provider support must be based on real local data. A mergeable PR, green synthetic tests, or a plausible parser is not enough. If this Mac cannot install/auth/use the provider from the United States, or the product is not realistically usable in English, reject unless the user explicitly accepts that support burden.

Use repo-local skills/docs when present:
- `skills/agent-session-format-check/SKILL.md`: schema drift, usage/limits probes, storage backends, discovery path contracts, and prebump validation.
- `skills/agent-support-matrix/SKILL.md`: support matrix, ledger, and verified-version recording workflow.
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

## Bundled Resources

- `scripts/new_agent_support_plan.py`: generates an end-to-end support plan with gates, install/session capture, fixture, implementation, QA, review, support-record, PR, and marketing sections.
- `references/agent-provider-gates.md`: hard gates, evidence checklist, binary lifecycle, existing-provider monitoring, discovery contracts, and rejection wording.
- `references/agent-support-implementation.md`: implementation surface map, fixture strategy, QA commands, review loops, support records, and marketing/release guidance.
