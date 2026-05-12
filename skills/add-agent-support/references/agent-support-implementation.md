# Agent Support Implementation

Use this reference after the hard gates pass. The goal is to ship support that can be re-tested, explained, and maintained.

## Implementation Surface Map

Start by finding the closest existing provider implementation and copying its local patterns.

Typical surfaces:
- Parser and preview parser: read real events, handle schema drift, preserve unknown metadata, agree on id/title/cwd/model/start/end.
- Discovery: scan only explicit roots, skip only proven artifact directories, support subagent/child-session paths when real data proves them.
- Indexing and search: ensure transcript text, tool calls, tool results, cwd, model, and title are discoverable.
- Settings and Preferences: expose root overrides when shell env vars will not reach a macOS app.
- Unified Sessions UI: filters, labels, provider colors/icons, transcript panes, and empty/error states.
- Analytics: either fully wire the provider or explicitly exclude it from analytics claims.
- Resume/copy command: implement only when a real command can resume the exact provider/session.
- Active/live status: implement only when a local, reliable source exists.
- Usage/rate limits: implement only when real local records or CLI output exposes it.

Likely AgentSessions areas:
- `AgentSessions/Services/*Parser*.swift`
- `AgentSessions/Services/*Discovery*.swift`
- `AgentSessions/Services/*Indexer*.swift`
- `AgentSessions/Services/UnifiedSessionIndexer.swift`
- `AgentSessions/Views/Preferences*`
- `AgentSessions/Analytics/Views/AnalyticsView.swift`
- `AgentSessionsTests/*ParserTests.swift`
- `AgentSessionsTests/*DiscoveryTests.swift`
- `AgentSessionsTests/SearchCoordinatorTests.swift`
- `AgentSessionsTests/NewProviderDiscoverabilityTests.swift`
- `Resources/Fixtures/stage0/agents/<agent>/`
- `docs/agent-support/agent-support-matrix.yml`
- `docs/agent-support/agent-support-ledger.yml`
- `docs/agent-json-tracking.md`
- `docs/CHANGELOG.md`
- `docs/summaries/YYYY-MM.md`

## Fixture Strategy

Create fixtures from real sessions, not handwritten approximations.

Required fixture set when the data exists:
- `small`: normal prompt/response session.
- `tool`: tool call and tool result session.
- `continued`: follow-up/resumed session.
- `subagent`: child/subagent session or explicit note that the provider has none.
- `schema_drift`: unknown/extra event types preserved as metadata.
- `blocked_auth_or_region`: only if full support is blocked and the failure transcript is useful evidence.

Redaction rules:
- Preserve real keys, nesting, event names, timestamp formats, role names, and ordering.
- Replace local paths with `/tmp/as-agent-fixture/project`.
- Remove names, emails, tokens, cookies, auth headers, private prompts, proprietary content, and credentials.
- Preserve enough text to prove title, cwd, model, user/assistant text, tool calls, tool results, timestamps, and unknown metadata.
- Keep raw captures private under `scripts/agent_captures/<timestamp>/<agent>/`.

Run:

```bash
rg -n "/Users/|@|token|secret|cookie|authorization|api[_-]?key|BEGIN PRIVATE" Resources/Fixtures/stage0/agents/<agent>
```

## Implementation Loop

1. Read the nearest existing provider parser/discovery/tests.
2. Add fixtures first so parser work is evidence-backed.
3. Implement preview parsing and full parsing together.
4. Add discovery with bounded roots and path contracts.
5. Wire index/search only after parser and discovery tests pass.
6. Wire UI/settings after backend behavior is stable.
7. Decide analytics/resume/live/usage surfaces explicitly. Do not let marketing imply unsupported surfaces.
8. Update docs/support records after tests prove the behavior.

Preserve stable app session IDs unless switching is necessary and the migration/favorites/archive impact is addressed.

## QA Commands

Use focused commands first, then broader validation:

```bash
git diff --check

xcodebuild test -project AgentSessions.xcodeproj -scheme AgentSessions \
  -derivedDataPath /tmp/AgentSessionsProviderFocusedTests \
  -only-testing:AgentSessionsTests/<Provider>ParserTests \
  -only-testing:AgentSessionsTests/<Provider>DiscoveryTests \
  -only-testing:AgentSessionsTests/SearchCoordinatorTests \
  -only-testing:AgentSessionsTests/NewProviderDiscoverabilityTests \
  -destination 'platform=macOS,arch=arm64'

./scripts/xcode_test_stable.sh

xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' build
```

If UI changed, launch/render-check the app and verify:
- Provider appears in Unified Sessions filters.
- Search finds fixture text.
- Transcript pane renders user, assistant, tool call, tool result, and unknown metadata.
- Preferences overrides are visible and persisted when implemented.
- Analytics/resume/live/usage surfaces either work or are not claimed.

Restore macOS Appearance to `System` if QA changes it.

## Review And Fix Loop

Review findings first and fix actionable issues before release.

Focus areas:
- Real fixture coverage and no synthetic-only confidence.
- Parser tolerance for unknown events and timestamp variants.
- Secret/path leakage in fixtures and docs.
- Unbounded filesystem scans.
- Unsupported analytics/resume/live/usage claims.
- Stable session IDs and favorites/archive impact.
- Indexer/search performance.
- Public wording truthfulness.

After every substantive fix, rerun focused tests and the Debug build. Use automated review only after tests pass, then repeat until clean or only accepted low-risk notes remain.

## Support Records

After validation:
- Update `docs/agent-support/agent-support-matrix.yml` for verified capabilities and versions.
- Append `docs/agent-support/agent-support-ledger.yml`.
- Add `docs/agent-json-tracking.md` evidence with source URLs, versions, fixture paths, and test results.
- Add `[Unreleased]` changelog and monthly summary bullets for user-visible support.
- Update README/support pages only for validated surfaces.

## PR And Marketing

PR body should include:
- What surfaces were implemented.
- What real fixtures prove.
- Commands and results from focused tests, stable tests, Debug build, and secret scan.
- Unsupported surfaces intentionally not claimed.
- Contributor credit when relevant.

Allowed wording when only local transcript browsing/search is implemented:
- "Added local transcript browsing and search for <provider> sessions."
- "Transcripts stay local; AgentSessions indexes local session files."

Do not mention analytics, resume, live status, usage tracking, or full support unless those exact surfaces are implemented and validated.
