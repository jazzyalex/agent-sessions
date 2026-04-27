# Codex Local Rollout Sessions Handoff

Date: 2026-04-26

Status: implementation-ready plan, no app code changed in this document.

Scope: local Codex rollout sessions created by Codex CLI, Codex App, and the Codex VS Code extension. Cloud Codex tasks are explicitly out of scope.

## Summary

Agent Sessions should keep treating Codex local rollout sessions as one provider, but enrich Codex local rollout rows with a surface label such as CLI, App, VS Code, Subagent, Other, or Unknown.

The important correction from research is that Codex App and Codex VS Code extension local sessions are not separate opaque desktop stores. They are normal rollout JSONL files under the same local Codex rollout tree used by Codex CLI.

Agent Sessions should therefore read the shared local rollout corpus directly and avoid inheriting Codex App sidebar filtering behavior.

## Verified Local Findings

### Shared rollout tree

Codex CLI, Codex App, and Codex VS Code extension local sessions can all write rollout JSONL files under:

```text
~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl
~/.codex/archived_sessions/rollout-*.jsonl
```

Agent Sessions already scans `~/.codex/sessions` through `CodexSessionDiscovery`.

Relevant current code:

- `AgentSessions/Services/SessionDiscovery.swift`
  - `CodexSessionDiscovery.sessionsRoot()` resolves `$CODEX_HOME/sessions` or `~/.codex/sessions`.
  - `discoverSessionFiles()` finds `rollout-*.jsonl`.
- `AgentSessions/Services/SessionIndexer.swift`
  - Codex rollout parsing is already implemented there.

### Codex VS Code extension proof session

A fresh Codex VS Code extension session was found at:

```text
~/.codex/sessions/2026/04/26/rollout-2026-04-26T17-50-52-019dcc6a-eae1-7cf1-abc6-3e89614353f1.jsonl
```

The session metadata contained:

```text
id: 019dcc6a-eae1-7cf1-abc6-3e89614353f1
originator: codex_vscode
source: vscode
cwd: /Users/alexm/Repository/Codex-History
cli_version: 0.125.0-alpha.3
```

`~/.codex/state_5.sqlite` also contained a matching `threads` row:

```text
source: vscode
title: Run ls and greet
first_user_message: test sesion. just run ls and say hi
archived: 0
rollout_path: ~/.codex/sessions/2026/04/26/rollout-2026-04-26T17-50-52-019dcc6a-eae1-7cf1-abc6-3e89614353f1.jsonl
```

The transcript body was present in the JSONL file. This proves the Codex VS Code extension path is directly parseable by the existing Codex rollout parser.

### Codex App local sessions

Local Codex App sessions were found as ordinary rollout JSONL files under `~/.codex/sessions` and `~/.codex/archived_sessions`.

Observed identifying metadata included:

```text
originator: Codex Desktop
source: vscode
```

Do not interpret `source: vscode` alone as proof that the VS Code extension created the session. Use `originator` first when present.

### Title metadata

The best local title source is:

```text
~/.codex/state_5.sqlite
```

The `threads` table includes useful fields:

```text
id
rollout_path
created_at
updated_at
source
cwd
title
first_user_message
archived
cli_version
model
reasoning_effort
```

Agent Sessions already reads `~/.codex/session_index.jsonl` for `thread_name` overrides. Keep that path, but add read-only `state_*.sqlite` enrichment as a fallback/title metadata source.

Recommended title precedence:

1. `session_index.jsonl.thread_name`
2. `state_*.sqlite.threads.title`
3. `state_*.sqlite.threads.first_user_message`
4. existing parsed title from JSONL

### What not to use

Do not use Codex App Electron storage, Chromium cache, IndexedDB, or `~/Library/Application Support/Codex` for this feature.

Earlier research found some Codex App cache data there, but it was not the reliable source for local sessions. The reliable transcript source is the local Codex rollout tree.

## Public Evidence

### Official Codex app-server docs

OpenAI documents `thread/list` as the app-server endpoint for history UI. The endpoint supports filters including:

- `sourceKinds`
- `archived`
- `cwd`
- `searchTerm`
- `modelProviders`
- sort key and pagination

When `sourceKinds` is omitted, the docs say it defaults to interactive source kinds, including `cli` and `vscode`.

Source:

- https://developers.openai.com/codex/app-server/#list-threads-with-pagination--filters

Implication: Codex App is not necessarily showing every `rollout-*.jsonl` file. It is showing results from app-server `thread/list`, which can filter by metadata, project/cwd, archive state, source kind, and pagination.

### Public bug reports and developer reports

The following public reports support the conclusion that Codex App and Codex CLI do not always surface the same local history even when local files exist.

| Topic | Evidence |
| --- | --- |
| Recent-window or pagination can hide older sessions | https://github.com/openai/codex/issues/14751 |
| Local rollout files exist but Codex App sidebar misses them after restart | https://github.com/openai/codex/issues/13713 |
| Shared `CODEX_HOME` surfaced differently by Codex App and Codex VS Code extension | https://github.com/openai/codex/issues/14389 |
| ACP/custom sessions written to JSONL may not appear in Codex App | https://github.com/openai/codex/issues/16385 |
| Worktree/project/cwd grouping affects visibility | https://github.com/openai/codex/issues/14519 |
| Symlink/workspace path differences affect visibility | https://github.com/openai/codex/issues/18483 |
| Recent bogus `source='cli'`, `cwd='/'` rows can pollute recent local history | https://github.com/openai/codex/issues/18364 |

Third-party writeups also describe the two-layer model:

- JSONL rollout files contain transcript history.
- SQLite state DB contains metadata used for listing/search.

References:

- https://codex.danielvaughan.com/2026/03/30/codex-cli-thread-search-session-management/
- https://llmbase.ai/openclaw/codex-export/
- https://dev.to/vild_da_f524590ed3ae13840/why-codex-history-disappears-after-switching-providers-and-how-i-fixed-it-f0j

## Product Positioning

Use precise product names. Avoid saying only "Codex" when distinguishing surfaces.

Preferred wording:

```text
Agent Sessions reads Codex local rollout files directly, so it can show local sessions created by Codex CLI, Codex App, and the Codex VS Code extension in one searchable UI.
```

More compact:

```text
Browse and search local Codex CLI, Codex App, and Codex VS Code extension sessions in one place.
```

Avoid:

```text
Codex App cannot show Codex CLI sessions.
```

Corrected statement:

```text
Codex App and Codex CLI do not always surface the same local session history. Agent Sessions indexes the local rollout files directly, so Codex CLI, Codex App, and Codex VS Code extension sessions can be searched together without inheriting Codex App sidebar filters.
```

## Implementation Plan

### 1. Keep one Codex provider

Do not add new `SessionSource` cases for Codex App or Codex VS Code extension.

Keep:

```text
SessionSource.codex
```

Add Codex local rollout surface metadata to `Session`.

Suggested model:

```swift
public enum CodexSessionSurface: String, Codable, Sendable {
    case cli
    case app
    case vscode
    case subagent
    case other
    case unknown
}
```

Suggested `Session` fields:

```swift
public let codexOriginator: String?
public let codexSource: String?
public let codexSurface: CodexSessionSurface?
```

Defaults should be nil so non-Codex providers are unaffected.

### 2. Extract surface metadata from `session_meta`

Read early JSONL `session_meta.payload` fields:

```text
payload.originator
payload.source
```

Implement extraction in both:

- full parse path
- lightweight parse path

Current nearby code already extracts Codex subagent information from `session_meta.payload.source`.

Recommended classification:

| Condition | Surface |
| --- | --- |
| `originator == "codex_vscode"` | `vscode` |
| `source == "vscode"` and no stronger originator exists | `vscode` |
| `originator == "Codex Desktop"` | `app` |
| `originator` contains desktop/app wording | `app` |
| `originator == "codex_cli_rs"` | `cli` |
| `source == "cli"` or `source == "exec"` | `cli` |
| `source` is object containing `subagent` | `subagent` |
| source/originator present but unknown | `other` |
| no usable source/originator | `unknown` |

Classification should preserve the raw strings too, because public formats are still changing.

### 3. Persist metadata in IndexDB

Add nullable columns to `session_meta`:

```sql
codex_originator TEXT
codex_source TEXT
codex_surface TEXT
```

Update:

- DB bootstrap migration
- `SessionMetaRow`
- fetch/hydrate code
- `upsertSessionMeta`
- `upsertSessionMetaCore`
- `SessionIndexer.sessionMetaRow(from:)`

Do not make these columns required.

### 4. Add read-only Codex state DB enrichment

Add a small read-only reader for latest `state_*.sqlite` beside the sessions root.

Discovery rule:

```text
If sessions root is ~/.codex/sessions or $CODEX_HOME/sessions,
look in the parent directory for state_*.sqlite and prefer newest/highest version.
```

Query:

```sql
SELECT id, rollout_path, source, title, first_user_message, archived, cwd, cli_version, model, reasoning_effort
FROM threads;
```

Join rules:

1. Primary: `threads.id == session.codexInternalSessionIDHint`
2. Secondary validation: normalized `threads.rollout_path == session.filePath`
3. Fallback only when ID missing: match by normalized rollout path

Use read-only SQLite flags. Never write to `~/.codex/state_*.sqlite`.

### 5. Title precedence

Keep the existing `session_index.jsonl` `thread_name` override path.

Add `state_*.sqlite` title fallback below it.

Precedence:

1. `session_index.jsonl.thread_name`
2. `state_*.sqlite.threads.title`
3. `state_*.sqlite.threads.first_user_message`
4. existing parsed JSONL title

### 6. UI display

Change provider display from "Codex CLI" to "Codex local" only if the UI then has a surface label. Otherwise, keep "Codex CLI" until the surface label is visible.

Preferred row display:

```text
Provider: Codex local
Surface: CLI / App / VS Code / Subagent / Other
```

Do not overload the existing subagent badge in the Session column. A surface label should be separate from subagent hierarchy markers.

### 7. Search and analytics

No new search pipeline is needed. All sessions remain `SessionSource.codex`, so existing transcript search should include Codex CLI, Codex App, and Codex VS Code extension rollout files.

Do not split analytics by Codex surface in the first implementation. That can be a later filter.

### 8. Resume behavior

Do not change resume command behavior in this implementation unless tests show a regression.

Resume should continue to use:

```text
codex resume <session-id>
```

with the existing internal ID derivation and fallback logic.

### 9. Documentation updates after implementation

After code lands, update user-facing docs:

- `README.md`
- `docs/CHANGELOG.md`
- `docs/summaries/YYYY-MM.md`
- support matrix docs if applicable

Suggested release note:

```text
Codex local rollout sessions: Agent Sessions now labels local sessions created by Codex CLI, Codex App, and the Codex VS Code extension while indexing them through the same local rollout history.
```

## Tests

Add parser tests in `AgentSessionsTests/SessionParserTests.swift`.

Required cases:

1. `originator: codex_cli_rs` maps to `cli`.
2. `originator: Codex Desktop` maps to `app`.
3. `originator: codex_vscode`, `source: vscode` maps to `vscode`.
4. `source: {"subagent": "review"}` preserves subagent metadata and maps to `subagent`.
5. Missing source/originator maps to `unknown`.
6. Unknown source/originator maps to `other` and keeps raw strings.

Add DB round-trip tests:

1. `codexOriginator`, `codexSource`, and `codexSurface` persist into `session_meta`.
2. Hydrated sessions restore those fields.
3. Existing indexed rows without new columns still hydrate after migration.

Add title enrichment tests:

1. Temp Codex sessions root with sibling fake `state_5.sqlite`.
2. `threads.title` applies when `session_index.jsonl` has no title.
3. `session_index.jsonl.thread_name` wins over `threads.title`.
4. `threads.first_user_message` applies when `title` is empty.
5. No state DB means existing parser behavior remains unchanged.

## Manual QA

Use real local sessions:

1. Codex CLI session in this repo.
2. Codex App session in this repo.
3. Codex VS Code extension session in this repo.

Verify:

- all three appear under the Codex provider
- surface labels are correct
- transcript search finds content from all three
- title is taken from `session_index.jsonl` or `state_*.sqlite` where available
- resume command still uses the expected session ID
- no cloud Codex task data is read

## Validation

Build after implementation:

```bash
xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug -destination 'platform=macOS' build
```

Prefer stable test wrapper for tests:

```bash
./scripts/xcode_test_stable.sh
```

## Risks

1. Codex local metadata is still evolving.
   - Mitigation: persist raw `originator` and `source`, not just derived surface.

2. `state_*.sqlite` can be locked or missing.
   - Mitigation: read-only best effort; never block transcript indexing on it.

3. Codex App may use filters not fully represented on disk.
   - Mitigation: Agent Sessions should not try to match Codex App sidebar exactly. Agent Sessions should index local rollout files directly.

4. Existing AS DB schema migrations must not force a destructive reindex unless necessary.
   - Mitigation: nullable columns plus normal hydration fallback.

## Non-Goals

- No Codex Web or cloud task support.
- No Codex App `~/Library/Application Support/Codex` cache parsing.
- No separate providers named Codex App or Codex VS Code extension.
- No network calls.
- No writes to `~/.codex/state_*.sqlite`.
