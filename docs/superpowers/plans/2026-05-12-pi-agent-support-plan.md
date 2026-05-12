# Pi Agent Support Plan

Date: 2026-05-12
Repository: `/Users/alexm/Repository/Codex-History-pi-support`
Branch: `codex/pi-dev-support`
Region under test: United States
Required language: English
Required plan path: free or existing plan

## Decision

Work type: new provider
Status: IMPLEMENTED AND LOCALLY VALIDATED FOR TIER-2 SUPPORT

Summary:
- Accept Pi coding-agent support for local JSONL transcript discovery, browsing, search, Preferences controls, provider colors, and resume/copy-resume commands.
- Resume support is limited to verified command construction and launcher plumbing for `pi --session <id>` with a `pi --continue` fallback when configured.
- Do not claim Agent Cockpit/live-session support, usage/rate-limit tracking, analytics parity, separate subagent hierarchy, or full remote-provider auth coverage.

## Delivery Phase Checklist

| Phase | Status | Evidence / Output |
| --- | --- | --- |
| 0. Provider support gates | Passed | Official English docs are available at `https://pi.dev/docs/latest/quickstart`, `https://pi.dev/docs/latest/usage`, and `https://pi.dev/docs/latest/session-format`; local session data was generated on this Mac. |
| 1. Binary/app lifecycle | Passed | Global `pi` was absent before support testing; temporary install used `/tmp/as-agent-lab/pi-cli` with `@earendil-works/pi-coding-agent` `^0.74.0`; `/tmp/as-agent-lab/pi-cli/node_modules/.bin/pi --version` returned `0.74.0`. |
| 2. Real session capture | Passed | Real session: `/tmp/as-agent-lab/pi-agent/sessions/2026-05-12T01-02-27-657Z_019e19b4-eb48-746a-aa6b-8dfcfa37954b.jsonl`; generated from `/tmp/as-agent-lab/pi-project` against a local OpenAI-compatible mock. |
| 3. Format evaluation | Passed | Official docs state JSONL sessions live under `~/.pi/agent/sessions/--<path>--/<timestamp>_<uuid>.jsonl` and current sessions use v3 tree entries with `id`/`parentId`; local sample has `session`, `model_change`, `thinking_level_change`, `message`, and `compaction` entries. |
| 4. Fixture creation | Passed | Redacted fixture checked in at `Resources/Fixtures/stage0/agents/pi/small.jsonl`. |
| 5. Integration | Passed | Parser, discovery, indexer, Preferences, colors, Unified Sessions, search, resume command builder, and terminal launcher plumbing are implemented in the files listed below. |
| 6. QA | Passed | Debug build succeeded; focused Pi/parser/resume/provider-discoverability tests succeeded with 30 tests and 0 failures. |
| 7. Review/fix loop | Clean | Review loop artifacts in `.codex-review-artifacts/20260511-183207/` reported three actionable findings; configured Pi session roots, Pi tree-path parsing, and generated DerivedData cleanup were fixed and revalidated. Follow-up review artifacts in `.codex-review-artifacts/20260511-194010/` found two actionable findings; Pi progress updates were marshaled to the main actor and live JSONL parsing now tolerates only an unterminated trailing record. Final retry `.codex-review-artifacts/20260511-194801/` completed clean. |
| 8. Docs/support records | Passed | Matrix, ledger, JSON tracking, changelog, May summary, and this support plan are updated with tier-2 wording. |
| 9. PR/release/marketing | Ready for branch handoff | Release copy must keep the tier-2 boundary and avoid Cockpit/live/usage/analytics claims. |

## Official Sources

- `https://pi.dev/docs/latest/quickstart`: npm install command `npm install -g @earendil-works/pi-coding-agent`; first run via `pi`; auth via `/login` or API-key providers.
- `https://pi.dev/docs/latest/usage`: sessions save automatically to `~/.pi/agent/sessions/`; session CLI options include continue/resume/fork/session-dir.
- `https://pi.dev/docs/latest/session-format`: sessions are JSONL; each line has a `type`; entries form a tree via `id`/`parentId`; current version is v3; file layout is `~/.pi/agent/sessions/--<path>--/<timestamp>_<uuid>.jsonl`.
- `https://pi.dev/docs/latest/settings`: settings live at `~/.pi/agent/settings.json` globally and `.pi/settings.json` per project; `PI_CODING_AGENT_DIR` and `PI_CODING_AGENT_SESSION_DIR` can override local state/session locations.

## Hard Gates

| Gate | Status | Evidence | Blocker |
| --- | --- | --- | --- |
| Region availability | Passed | Official docs were reachable from this environment; temporary CLI generated a local session using a mock provider. | None for tier-2 local support. |
| English docs/UI/CLI | Passed | Official docs pages are English. | None. |
| Free or existing-plan testability | Passed | Test used local OpenAI-compatible mock, not a paid remote provider. | Real provider auth not exercised. |
| Install/auth feasible on this Mac | Passed | `/tmp/as-agent-lab/pi-cli` package install and `pi --version` succeeded. | Global install intentionally not performed. |
| Real local transcript/session data generated | Passed | `/tmp/as-agent-lab/pi-agent/sessions/2026-05-12T01-02-27-657Z_019e19b4-eb48-746a-aa6b-8dfcfa37954b.jsonl` has 9 JSONL lines. | None. |
| Redacted fixture possible without secrets | Passed | `Resources/Fixtures/stage0/agents/pi/small.jsonl` is checked in and covered by `PiSessionParserTests`. | None. |
| Discovery contract matches implementation | Passed | `PiSessionDiscovery`, `PiSessionIndexer`, `UnifiedSessionIndexer`, and focused tests cover local root handling and aggregation wiring. | None. |
| Binary lifecycle known | Passed | Package source `@earendil-works/pi-coding-agent`; temp install under `/tmp/as-agent-lab/pi-cli`; no global binary on PATH. | Global uninstall path not needed because no global install was done. |
| Marketing claims match validated surfaces | Passed | Wording limited to tier-2 local support, Preferences, colors, and resume/copy command construction. | Do not broaden without implementation/test evidence. |
| Maintainer can re-test later | Passed | Re-test with temp npm install plus `PI_CODING_AGENT_DIR`/`PI_CODING_AGENT_SESSION_DIR` overrides and the checked-in fixture. | None. |

## Local Command Probes

| Item | Result | Evidence |
| --- | --- | --- |
| Global `pi` | Missing in current shell | `command -v pi` produced no path. |
| Temp Pi binary | Found | `/tmp/as-agent-lab/pi-cli/node_modules/.bin/pi --version` returned `0.74.0`. |
| Package version | Found | `npm view @earendil-works/pi-coding-agent version dist.tarball bin repository --json` returned version `0.74.0` and bin `{ "pi": "dist/cli.js" }`. |
| Default real-home session root | Present but not used for fixture | The implementation defaults to `~/.pi/agent/sessions`; support evidence uses the override root under `/tmp/as-agent-lab/pi-agent/sessions`. |

## Binary Install And Cleanup Plan

Install commands or official package references:
- `npm install -g @earendil-works/pi-coding-agent`
- Official docs also list `curl -fsSL https://pi.dev/install.sh | sh`; prefer npm for controlled version pinning in AgentSessions support checks.

Pre-install inventory recorded:
- Existing binary lookup: global `pi` missing.
- Existing support/state roots: no real-home Pi session files were used for evidence.
- Snapshot timestamp: 2026-05-12 local support pass.

Verification recorded:
- Binary path: `/tmp/as-agent-lab/pi-cli/node_modules/.bin/pi`
- Version: `0.74.0`
- Auth/login requirements: official docs describe `/login` and provider API-key auth, but this support pass used a local mock and did not validate remote provider auth.
- Cleanup path: remove `/tmp/as-agent-lab/pi-cli`, `/tmp/as-agent-lab/pi-agent`, `/tmp/as-agent-lab/pi-project`, and `/tmp/as-agent-lab/pi-mock-server.mjs` if the temp lab is no longer needed.

## Real Format Notes

Verified facts from official docs and local sample:

- Storage layout: JSONL files under `~/.pi/agent/sessions/--<path>--/<timestamp>_<uuid>.jsonl`; the temp capture used an override root under `/tmp/as-agent-lab/pi-agent/sessions`.
- Session ID fields: header `type=session` entry has UUID-like `id`; non-header entries have short hex `id`; entries link with `parentId`.
- Timestamp shapes: entry `timestamp` is ISO-8601 text; message payloads also include numeric millisecond timestamps.
- Event type names observed locally: `session`, `model_change`, `thinking_level_change`, `message`, `compaction`.
- Role fields observed locally: message payload roles include `user` and `assistant`.
- Content shapes observed locally: user/assistant `message.content` arrays with `text` blocks.
- Assistant metadata observed locally: `api`, `provider`, `model`, `responseId`, `usage`, `stopReason`.
- Tool call/result shapes: official docs define `toolCall`, `toolResult`, `bashExecution`, and `custom`, but the local mock capture did not exercise tools.
- cwd/model fields: header has `cwd`; assistant message has `provider` and `model`; local session does not log the Pi CLI package version.
- Subagent/session hierarchy behavior: Pi docs state sessions form an in-file tree via `id`/`parentId`; no separate child-session/subagent fixture was generated.

## Integration Implementation

Implemented surfaces:
- Parser and fixture: `AgentSessions/Services/PiSessionParser.swift`, `Resources/Fixtures/stage0/agents/pi/small.jsonl`, `AgentSessionsTests/PiSessionParserTests.swift`.
- Discovery/indexing/search: `AgentSessions/Services/PiSessionDiscovery.swift`, `AgentSessions/Services/PiSessionIndexer.swift`, `AgentSessions/Services/UnifiedSessionIndexer.swift`, `AgentSessions/Search/SearchCoordinator.swift`.
- Preferences/settings/root overrides: `AgentSessions/Pi/PiSettings.swift`, `AgentSessions/Pi/PiCLIEnvironment.swift`, `AgentSessions/Views/Preferences/PreferencesView+Pi.swift`, `AgentSessions/Views/PreferencesView.swift`, `AgentSessions/Views/Preferences/PreferencesConstants.swift`.
- Provider labels/colors: `AgentSessions/Model/SessionSource.swift`, `AgentSessions/Services/TranscriptColorSystem.swift`, `AgentSessions/Analytics/Utilities/AnalyticsColors.swift`, `AgentSessions/Views/SessionTerminalView.swift`.
- Resume/copy command: `AgentSessions/PiResume/PiResumeTypes.swift`, `AgentSessions/PiResume/PiResumeCommandBuilder.swift`, `AgentSessions/PiResume/PiResumeCoordinator.swift`, `AgentSessions/PiResume/PiTerminalLauncher.swift`, `AgentSessions/Views/UnifiedSessionsView.swift`, `AgentSessionsTests/PiResumeCommandBuilderTests.swift`, `AgentSessionsTests/PiCLIEnvironmentTests.swift`.

Unsupported surfaces:
- Agent Cockpit/live active-session management.
- Usage/rate-limit tracking.
- Analytics parity beyond provider color/label constants required by existing UI surfaces.
- Separate Pi subagent hierarchy detection.
- Remote auth/provider behavior beyond local CLI availability probing and documented settings paths.

## Implementation Task List

- [x] Read existing provider support docs and support-record patterns.
- [x] Generate a support-plan scaffold with `skills/add-agent-support/scripts/new_agent_support_plan.py`.
- [x] Verify official Pi docs for install, session path, JSONL/v3 tree format, and settings/session overrides.
- [x] Inspect real local session evidence from `/tmp/as-agent-lab/pi-agent/sessions`.
- [x] Add redacted Pi fixture under `Resources/Fixtures/stage0/agents/pi/`.
- [x] Add parser coverage.
- [x] Add discovery/index/search wiring.
- [x] Add Preferences/settings/root override wiring.
- [x] Add provider colors and labels.
- [x] Add resume/copy-resume command builder and launcher plumbing.
- [x] Keep Agent Cockpit/live, usage, analytics parity, and subagent hierarchy unsupported.
- [x] Run focused tests and Debug build.
- [x] Run review-fix loop and fix actionable findings.
- [x] Update support records and public docs with tier-2 wording.

## Support Record Updates

- `docs/agent-support/agent-support-matrix.yml`: Pi entry records version `0.74.0`, checked-in fixture evidence, tier-2 support scope, and unsupported live/analytics/usage/subagent hierarchy.
- `docs/agent-support/agent-support-ledger.yml`: latest Pi entry records implementation files, fixture evidence, focused tests, and tier-2 support boundary.
- `docs/agent-json-tracking.md`: upstream/version check log and Pi agent notes now list parser/discovery/indexer/Preferences/resume implementation files.
- `docs/CHANGELOG.md`: `[Unreleased]` describes Pi tier-2 local support and unsupported surfaces.
- `docs/summaries/2026-05.md`: May summary includes Pi tier-2 support.

## QA And Review Loop

Validation already completed after Swift integration:

```bash
xcodebuild -resolvePackageDependencies -project AgentSessions.xcodeproj -scheme AgentSessions
xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug -destination 'platform=macOS,arch=arm64' build
xcodebuild test -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/AgentSessionsPiFocusedTests -only-testing:AgentSessionsTests/PiSessionParserTests -only-testing:AgentSessionsTests/PiResumeCommandBuilderTests -only-testing:AgentSessionsTests/PiCLIEnvironmentTests -only-testing:AgentSessionsTests/NewProviderDiscoverabilityTests
```

Observed results:
- Package resolution: succeeded.
- Debug build: `** BUILD SUCCEEDED **`.
- Focused tests: `** TEST SUCCEEDED **`, 30 tests executed, 0 failures in the final focused run.

Final validation completed before handoff:
- `git diff --check`: passed.
- Review-fix loop: first pass found actionable issues; fixes were applied. Follow-up retry completed the review phase in `.codex-review-artifacts/20260511-194010/`, found two more actionable P2 issues, and both were fixed. Final retry `.codex-review-artifacts/20260511-194801/` completed clean.
- Focused tests after review fixes: `** TEST SUCCEEDED **`, 30 tests executed, 0 failures.
- Debug build after review fixes: `** BUILD SUCCEEDED **`.

## PR, Release, And Marketing Plan

- Verified support wording: "Pi coding agent: local JSONL transcripts under `~/.pi/agent/sessions` can be discovered, browsed, searched, styled, configured in Preferences, and resumed through verified local CLI command construction."
- Unsupported surfaces to avoid mentioning: Agent Cockpit/live status, usage/rate-limit tracking, analytics parity, separate subagent hierarchy, all Pi sessions, remote auth coverage, and full Pi support.
- PR title/body: keep to tier-2 support and include the real capture path plus official docs URLs as evidence.
- Contributor credit: none recorded in this pass.
- Release note: one bullet under `[Unreleased]`.
- Screenshot/GIF needed: only if UI review requests it; current validation is build/test based.
