# Cline CLI and Cline Desktop Agent Support Plan

Date: 2026-09-15
Repository: `/Users/alexm/Repository/Codex-History`
Region/language: United States / English
Work type: new provider
Status: implementation and automated QA complete; uncommitted

## Decision

Accept Cline as one Agent Sessions source spanning Cline CLI and Cline Desktop. Both installed products write the same local manifest/messages session format. Ship browsing and search now; do not claim resume, live status, images, subagent hierarchy, or telemetry until those contracts have separate evidence.

## Evidence and gates

| Gate | Result | Evidence |
| --- | --- | --- |
| Installed products | pass | `/opt/homebrew/bin/cline` 3.0.62; `/Applications/Cline.app`, bundle `bot.cline.app`, version 0.0.28, English development region |
| Region/language | pass | Both installed and usable in the US with English CLI/UI metadata |
| Existing-plan testability | pass | Existing local state supplied real schema evidence; no install, login, or paid action was needed |
| Local session data | pass | 13 rows in the local sessions database: 12 CLI and 1 Desktop |
| Fixture safety | pass | Two schema-faithful fixture pairs are redacted; repository secret/path scan is clean |
| Maintainability | pass for browse/search | Deterministic root, stable manifest identity, adjacent transcript, fixtures, tests, and explicit unsupported surfaces |

Official references:

- `https://docs.cline.bot/cli/cli-reference`
- `https://docs.cline.bot/getting-started/config`
- `https://cline.bot/`

No new provider run was generated. Existing session state was sufficient, so the work did not spend quota or touch account configuration.

## Verified format

- Root: `~/.cline/data/sessions/<session-id>/`, or `$CLINE_DATA_DIR/sessions/<session-id>/`; an explicit in-app override wins.
- Manifest: `<session-id>.json`; fields observed include `session_id`, `source`, ISO-8601 start/end timestamps, model, cwd/workspace root, prompt, and metadata title.
- Transcript: adjacent `<session-id>.messages.json`; the manifest's absolute `messages_path` is export-time data and is never followed.
- Messages carry role, epoch-millisecond `ts`, id, and ordered content blocks.
- Covered block families: `text`, `thinking`, `tool_use`, and `tool_result`. Unknown blocks remain visible as metadata with raw JSON.
- Stable Agent Sessions ID: manifest `session_id`, with filename fallback only when the field is absent.
- Surface: manifest `source=cli` or `source=desktop`.
- Title priority: metadata title, manifest prompt, first user text.
- The manifest and transcript are treated as one logical session for preview/full-parse limits, size reporting, search freshness, focused reloads, and saved-session archives.
- Both files must declare contract version 1, and the transcript identity must match the manifest. Preview rows survive a temporarily missing or partial companion, but a full reload fails closed so an already displayed transcript is not erased.
- A nonempty `CLINE_DATA_DIR` is authoritative even when its `sessions` directory is temporarily absent; Agent Sessions does not expose the default-profile corpus as a fallback.
- This two-file layout is an observed local format, not a stable public Cline storage API contract.

## Fixtures

- `Resources/Fixtures/stage0/agents/cline/cli_tool/cline-cli-tool.json`
- `Resources/Fixtures/stage0/agents/cline/cli_tool/cline-cli-tool.messages.json`
- `Resources/Fixtures/stage0/agents/cline/desktop_continued/cline-desktop-continued.json`
- `Resources/Fixtures/stage0/agents/cline/desktop_continued/cline-desktop-continued.messages.json`

The CLI pair covers thinking, assistant text, a command tool call, and an error result. The Desktop pair covers an imported continued conversation. User content, IDs, paths, and timestamps are synthetic replacements while the key/type structure follows the observed files.

Secret/path scan:

```bash
rg -n "/Users/|@|token|secret|cookie|authorization|api[_-]?key|BEGIN PRIVATE" Resources/Fixtures/stage0/agents/cline
```

Result: no matches.

## Implemented surfaces

- `SessionSource.cline` identity, registry descriptor, provider runtime, availability, and persistent keys.
- Discovery of canonical immediate-child manifests under the default or selected Cline data/session root; `.messages.json` files are not separate sessions.
- Lightweight and full parsing, transcript rendering, search hydration, focused-session reload, and saved-session backfill.
- Cline Settings, first-run source list, toolbar/source filtering, analytics source filtering, and surface labels.
- Explicitly unavailable telemetry capability and no resume command.
- Redacted fixtures plus parser, discovery, registry, key, view-derivation, and compatibility tests.

## Unsupported surfaces

- Resume and copy-resume: `cline --id` was not proven to safely reopen an existing stored conversation.
- Live/active status.
- Image extraction.
- Usage or rate-limit telemetry.
- Subagent hierarchy.

## QA record

- Free implementation worker: OpenCode Muse Spark 1.3 Contributor Free, xhigh, session `ses_f58be1fe4ffeFp5yEVM9NCgcSR`.
- Integration hardening review: Cline Muse Spark 1.3 Contributor Free proposed the bounded Preferences, release-copy, and monitoring fixes; the parent session verified and applied them.
- Focused Cline suites after Preferences, parser, retrieval, and monitoring hardening: 44 tests, 0 failures.
- Prior integration cohorts from the worker: 75 registry/integration tests, 68 binary/stage0/fx-regression tests, and 36 onboarding tests, all green.
- `git diff --check`: clean at the final gate.
- Clean Debug build: passed.
- Oracle reviews: GPT-5.6 Sol, Extra High browser sessions `cline-cli-desktop-review` and `cline-integral-review`. The integral review's initial NO-SHIP covered missing-companion transcript erasure, non-authoritative `CLINE_DATA_DIR`, unbounded production full parses, incomplete CLI/Desktop version reporting, shallow monitor identity checks, and manifest-only freshness. All six are fixed and independently covered or source-verified.
- Full stable suite: passed. The xcresult reports 2,873 total / 2,870 passed / 3 skipped / 0 failed across both test bundles. Xcode stdout showed only the 2,818-test application bundle, which is not the authoritative combined count.
- Full monitoring suite: 307 tests plus 5 subtests passed.
- Test inventory versus `HEAD`: +44 declarations (+41 unique method names), all Cline coverage; no existing unique test method was removed.
- Documentation publication guard, JSON/YAML parsing, fixture secret/path scan, and `git diff --check`: passed.
- UI automation: not run because it was not requested; source/view integration is covered by compile and derivation tests.

## Release wording

Safe claim: “Browse and search local Cline CLI and Cline Desktop sessions.”

Do not claim resume, live status, images, hierarchy, or token/cost/quota telemetry.

No commit, push, PR, release, screenshot, or external post is part of this task.
