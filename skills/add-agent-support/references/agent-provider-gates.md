# Agent Provider Gates

## Hard Gates

Use these gates before adding, accepting, or bumping AgentSessions provider support.

| Gate | Pass condition | Failure action |
| --- | --- | --- |
| Region | The user can install, authenticate, and create sessions from the United States. | Reject or defer. |
| English | Docs, CLI help, UI, and errors are usable in English. | Reject unless the user explicitly wants non-English support. |
| Plan | A free or existing plan can create real sessions for parser QA. | Defer until fixture data is supplied. |
| Local data | Real transcript/session files are readable locally. | Reject as unsupported for local-session browsing. |
| Fixtures | Redacted fixtures preserve real schema, event names, and timestamps. | Do not merge. |
| Format check | Existing providers pass weekly/prebump monitoring before verified-version bumps. | Do not bump. |
| Discovery contract | Storage root/path pattern still matches AgentSessions discovery. | Treat as high severity. |
| Binary lifecycle | Install, verify, and uninstall/clean up are known. | Do not leave test installs behind. |
| Marketing truth | Public claims match implemented/tested surfaces. | Do not publish. |
| Maintenance | The maintainer can reasonably re-test and explain support. | Reject or keep private/experimental outside public docs. |

## Evidence To Capture

- Official install/auth docs URL and access date.
- Region or account restrictions with source or exact observed error.
- CLI binary path, version, and help output.
- App bundle ID/version when testing a desktop app.
- Install command, source URL, package name, checksum if available, and uninstall/cleanup command.
- Exact command used to generate a safe session.
- Exact output for auth/region/plan failures.
- Exact local storage roots inspected.
- File names, extensions, and directory depth.
- JSON/SQLite schema summaries.
- Redaction notes for fixtures.
- `agent_watch.py` report path and recommendation for existing providers.
- Prebump exit code and report path before any verified-version bump.
- Discovery contract pass/fail status.
- Test-session commands and resulting transcript paths.
- Subagent evidence summaries if subagents were used.
- Tests and build commands run.

## Existing Provider Format Check

Use the repo-local `skills/agent-session-format-check/SKILL.md` workflow for already supported providers.

Run weekly monitoring:

```bash
./scripts/agent_watch.py --mode weekly
```

If the report recommends `run_prebump_validator`, or before staging any support-matrix `max_verified_version` bump, run:

```bash
./scripts/agent_watch.py --mode prebump --agent <name>
```

Exit code contract:
- `0`: fresh session produced and schema matches baseline. Safe to bump after approval.
- `2`: schema mismatch. Do not bump; refresh parser/fixtures after investigation.
- `3`: driver failed because of timeout, auth, missing CLI, or discovery contract failure.
- `4`: config/invariant failure, missing prebump block, credential hygiene issue, or sandbox breach.

In `scripts/probe_scan_output/agent_watch/*/report.json`, check:
- `results.<agent>.weekly.local_schema.file`
- `results.<agent>.weekly.schema_diff`
- `results.<agent>.evidence.schema_matches_baseline`
- `results.<agent>.evidence.sample_freshness.is_stale`
- `results.<agent>.probes[*].ok`
- `results.<agent>.weekly.discovery_path_contract`
- `results.<agent>.severity` and `recommendation`

## Discovery Contracts

Use these as the baseline for supported providers:

| Agent | Expected path pattern |
| --- | --- |
| Codex | `*/sessions/YYYY/MM/DD/rollout-*.jsonl` |
| Claude | `~/.claude/projects/**/*.{jsonl,ndjson}` |
| OpenCode | `*/opencode/storage/session/*/ses_*.json` |
| Hermes | `~/.hermes/sessions/session_*.json` |
| Gemini | `~/.gemini/tmp/<hash>/(chats/)?session-*.json` |
| Copilot | `~/.copilot/session-state/*.jsonl` |
| OpenClaw | `*/agents/<id>/sessions/*.jsonl` |
| Cursor | `~/.cursor/projects/*/agent-transcripts/*/*.jsonl` |

## Fixture Rules

- Preserve real keys and event type names.
- Replace user paths with `/tmp/as-agent-fixture/project`.
- Remove names, emails, tokens, cookies, auth headers, private prompts, and proprietary content.
- Keep enough events to validate title, cwd, model, timestamps, user/assistant text, tool calls, tool results, and unknown metadata.
- Preserve important event families when present: session metadata, tool calls/results, usage/limits, compaction/context/delta wrappers, and multi-file references.
- For OpenCode-style multi-file stores, preserve session/message/part relationships and redact each file independently.
- Keep raw captures private under `scripts/agent_captures/<timestamp>/<agent>/`; do not commit raw sessions.
- Scan fixtures with:

```bash
rg -n "/Users/|@|token|secret|cookie|authorization|api[_-]?key|BEGIN PRIVATE" Resources/Fixtures
```

## Binary And Test-Session Lifecycle

Before install:
- Prefer official docs and official package names.
- Ask before global installs, GUI app installs, login, account linking, or networked agent runs.
- Record the install command and source.
- Snapshot existing state before changing anything:
  - `which <binary>` or equivalent command lookup.
  - Existing app bundle path, bundle identifier, and version.
  - Existing provider support/state roots and immediate entry counts.
  - Existing package-manager ownership such as `brew list`, `npm list -g`, or app metadata when applicable.
  - Snapshot timestamp and exact paths inspected.

After install:
- Record `which <binary>`, `<binary> --version`, and first-page help output.
- For apps, record bundle path, bundle identifier, and version.
- Create test sessions in `/tmp/as-agent-lab/<agent>-project` only.
- Use prompts that read tiny fixture files and do not edit files unless edit behavior is explicitly under test.
- Locate transcripts using expected roots and scoped `find`; avoid broad home-directory scans.

If support is rejected:
- Remove test-only binaries/apps installed during the attempt.
- Remove test-only provider state such as `~/.provider` only when the pre-install snapshot proves it did not exist before the attempt.
- Verify command lookup and scoped filesystem lookup return empty.

## Subagent Evaluation Pattern

Use subagents only when the user authorized subagent work or when parallel review is explicitly requested.

Good independent tasks:
- Official-doc research: region, language, free plan, install/auth limits.
- Local format inspection: summarize real transcript schema without editing code.
- Parser audit: identify code surfaces needed for provider integration.
- Fixture review: check redaction and schema preservation.
- Docs/marketing review: verify no overclaim against implemented surfaces.

Do not use subagents to bypass install/login approval or destructive cleanup approval.

## Support Record Updates

After approval and passing format evidence:

- Update `docs/agent-support/agent-support-matrix.yml` for the verified capability/version.
- Append `docs/agent-support/agent-support-ledger.yml`.
- Add an entry to `docs/agent-json-tracking.md` under "Upstream Version Check Log".
- Keep docs and public wording limited to behavior that tests and fixtures prove.

## Marketing Gate

Marketing can start only after implementation, fixture-backed tests, Debug build, and docs land.

Allowed wording when only local transcript surfaces are implemented:
- "Added local transcript browsing and search for <provider> sessions."
- "Transcripts stay local; AgentSessions indexes local session files."

Do not mention analytics, resume, live status, usage tracking, or full support unless those exact surfaces are implemented and validated.

## Polite Rejection Template

```text
Thanks for the contribution. After maintainer review, I do not plan to support <provider> in AgentSessions at this time.

I cannot reliably verify <provider> compatibility from my environment, and <specific blocker: region/language/paid plan/no local transcripts> makes ongoing QA and support impractical for this project. I do not want to ship provider support that I cannot maintain or describe accurately.

I appreciate the work here, but I am keeping provider support limited to tools I can verify and support locally.
```
