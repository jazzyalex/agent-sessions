# Claude Multi-Root and Desktop Sessions - Current Design

## Goal
Agent Sessions shows local Claude Code sessions that are readable on disk, including:

- Standard Claude Code CLI sessions under `~/.claude/projects`.
- Alternate Claude config directories, for example roots supplied through `CLAUDE_CONFIG_DIR` or `CLAUDE_CONFIG_DIRS`.
- Claude Desktop app Code-tab / local-agent transcripts stored under Claude Desktop application support directories.

Status: the first implementation has landed. This note now records the current design, validation scope, and remaining follow-up considerations.

## Current State
Agent Sessions currently treats Claude as a single provider, `SessionSource.claude`, and discovers sessions through `ClaudeSessionDiscovery` in `AgentSessions/Services/SessionDiscovery.swift`.

Verified current behavior:

- `ClaudeSessionDiscovery.sessionsRoot()` still returns the configured standard Claude root for compatibility.
- Discovery now uses candidate roots from the custom preference, `CLAUDE_CONFIG_DIRS`, `CLAUDE_CONFIG_DIR`, default `~/.claude`, valid sibling `~/.claude*` roots, and Claude Desktop `local-agent-mode-sessions`.
- `discoverSessionFiles()` scans each candidate root for `.jsonl` and `.ndjson`, while recent/full deltas track the same candidate set.
- `ClaudeSessionParser` parses Claude Code JSONL events and enriches matching Desktop local-agent transcripts with Desktop metadata.
- `SessionMetaRepository` and `IndexDB` persist generic origin fields (`originator`, `origin_source`, `surface`) while keeping Codex-named fields readable for compatibility.

Current limitation:

- Metadata-only Desktop records without a matching readable transcript are not indexed as sessions.

## Local Evidence
Inspection on this machine found Claude Desktop data under:

- `~/Library/Application Support/Claude/claude-code-sessions/.../local_*.json`
- `~/Library/Application Support/Claude/local-agent-mode-sessions/.../local_*.json`
- `~/Library/Application Support/Claude/local-agent-mode-sessions/.../local_*/.claude/projects/**/*.jsonl`

The `local_*.json` metadata files include fields such as:

- `sessionId`
- `cliSessionId`
- `cwd`
- `originCwd`
- `worktreePath`
- `worktreeName`
- `createdAt`
- `lastActivityAt`
- `model`
- `title`
- `isArchived`

The nested JSONL transcripts under `local-agent-mode-sessions/.../local_*/.claude/projects` match the Claude Code JSONL shape that `ClaudeSessionParser` already understands.

Important distinction:

- Some Desktop records under `claude-code-sessions` appear to be metadata-only unless a matching nested transcript can be found elsewhere.
- Metadata-only records should not be silently treated as full transcripts.

## Product Behavior
Use `SessionSource.claude` for all Claude Code sessions. Do not create a separate provider unless a later UI/product decision explicitly requires it.

Display origin/surface as metadata:

- Standard `~/.claude/projects` rows: Claude Code CLI.
- Nested Desktop local-agent rows: Claude Desktop.
- Metadata-only Desktop rows with no transcript: either hidden by default or shown as incomplete metadata rows behind an explicit decision.

Implemented first pass:

- Index only transcript-backed Desktop rows.
- Use Desktop metadata to enrich title, model, timestamps, and visible origin.
- Skip metadata-only rows in the first pass.

## Data Model
Avoid adding more Codex-specific fields for Claude. The existing `codex_originator`, `codex_source`, and `codex_surface` fields are already a naming mismatch for other providers.

Implemented schema direction:

1. Added generic session-origin fields to `Session`:
   - `originator: String?`
   - `originSource: String?`
   - `surface: SessionSurface?`

2. Added `SessionSurface` values:
   - `cli`
   - `desktop`
   - `vscode`
   - `subagent`
   - `other`
   - `unknown`

3. Added generic columns to `session_meta`:
   - `originator TEXT`
   - `origin_source TEXT`
   - `surface TEXT`

4. Populate generic fields from provider-native metadata while keeping existing Codex fields for backwards compatibility.

5. Update hydration to prefer generic fields when present and fall back to existing Codex fields.

Rejected shortcut option:

- Reuse `codex_*` fields for Claude Desktop metadata in the first pass.
- This is faster but undesirable because it further embeds provider-specific naming into cross-provider UI.

Recommendation:

- Do the generic schema cleanup now, because Claude Desktop is the second surface-level origin case and makes the Codex-specific names actively misleading.

## Discovery Design
`ClaudeSessionDiscovery` uses a candidate-root model instead of scanning only one standard Claude root.

### Candidate Types
Use a small internal descriptor:

```swift
struct ClaudeDiscoveryRoot: Hashable {
    enum Kind {
        case standardConfig
        case desktopLocalAgent
    }

    let configRoot: URL
    let scanRoot: URL
    let kind: Kind
}
```

`configRoot` is the Claude home/root.
`scanRoot` is the directory to enumerate for `.jsonl` / `.ndjson`.

### Standard Roots
Candidate sources:

1. Custom AS preference override (`ClaudeSessionsRootOverride`), if set.
2. `CLAUDE_CONFIG_DIRS`, split by `:`.
3. `CLAUDE_CONFIG_DIR`.
4. Default `~/.claude`.
5. Sibling `~/.claude*` roots that pass a valid-root heuristic.

Valid root heuristic, any true:

- `projects/` exists.
- `settings.json` exists.
- `history.jsonl` exists.
- `todos/` exists.

For each standard root, scan `root/projects` if present; otherwise scan the root.

### Desktop Roots
Candidate sources:

1. `~/Library/Application Support/Claude/local-agent-mode-sessions`

For `local-agent-mode-sessions`, discover nested Claude homes:

- Match directories like `.../local_*/.claude/projects`.
- Treat the parent `.../local_*` directory as the Desktop session workspace.
- Treat the sibling `.../local_*.json` file as metadata when present and when it matches the transcript.

For `claude-code-sessions`:

- This first implementation does not index metadata-only records from `claude-code-sessions`.
- A future pass can add them only after a matching readable transcript source is proven.

### Dedupe
Dedupe by resolved file path first.

Then optionally dedupe by Claude `sessionId` when two paths point to the same logical session:

- Prefer standard `~/.claude/projects` path over Desktop nested copy if paths differ but `sessionId` is identical.
- Prefer transcript-backed row over metadata-only row.
- Prefer newer `mtime` if both candidates are otherwise equivalent.

## Metadata Enrichment
`ClaudeDesktopSessionMetadataReader` reads the Desktop metadata file associated with a transcript.

Responsibilities:

- Find Desktop `local_*.json` metadata candidates from the transcript path.
- Decode known fields into a small `ClaudeDesktopSessionMetadata` struct.
- Provide metadata only when the transcript filename or transcript `sessionId` matches `cliSessionId`.

Use metadata to enrich:

- `surface = .desktop`
- `originator = "Claude Desktop"`
- `originSource = "local-agent-mode"`
- title from `title` when the transcript title is missing or falls back to `No prompt`.
- model from metadata only when transcript parsing does not find a model.
- cwd from `originCwd` for display/project grouping when present; otherwise use transcript `cwd`.
- start/end timestamps from `createdAt` and `lastActivityAt` only when transcript timestamps are missing.

Title precedence:

1. Explicit transcript `custom-title`.
2. Transcript title derived from `ai-title` or a meaningful prompt.
3. Desktop metadata `title`.
4. Existing fallback title behavior, such as `No prompt`.

## Implemented Touchpoints
Files changed by the first implementation:

- `AgentSessions/Services/SessionDiscovery.swift`
  - Replaces single Claude root scanning with candidate roots.
  - Adds full and recent delta support across all candidates.
  - Ensure removed-path detection is scoped per selected root.

- `AgentSessions/Services/ClaudeSessionParser.swift`
  - Enrich matching Desktop transcripts from metadata discovered by path and `cliSessionId`.
  - Preserve current parser behavior for ordinary CLI rows.
  - Keep Desktop metadata as metadata, not fake transcript events.

- `AgentSessions/Services/ClaudeSessionIndexer.swift`
  - Load discovery candidates.
  - Preserve Desktop metadata when merging lightweight and full sessions.
  - Persist generic origin/surface fields.
  - Update hydrate/reload logic so focused reload works for nested Desktop paths.

- `AgentSessions/Indexing/DB.swift`
  - Add generic origin/surface columns.
  - Keep existing Codex fields readable during transition.

- `AgentSessions/Indexing/SessionMetaRepository.swift`
  - Hydrate generic fields.
  - Fall back to existing Codex fields for older indexed Codex sessions.

- `AgentSessions/Model/Session.swift`
  - Add generic origin/surface fields.
  - Keep Codex fields temporarily and map them into generic fallback values.

- `AgentSessions/Views/UnifiedSessionsView.swift`
  - Generalize the Agent-column pill logic from Codex-only to source-aware surfaces.
  - Show a compact Desktop pill for Claude Desktop rows.
  - Preserve existing Codex Desktop / VS Code / CLI behavior.

## Tests
Focused unit coverage should stay close to discovery, parser enrichment, and metadata persistence.

### Discovery Tests
In `AgentSessionsTests/SessionParserTests.swift` or a future `ClaudeSessionDiscoveryTests.swift`:

- Default `~/.claude/projects` still discovers normal JSONL.
- Multiple roots are deduped by resolved path.
- Environment and sibling-root coverage can be added around the implemented candidate-root behavior.
- Desktop nested `local_*/.claude/projects/**/*.jsonl` files are discovered.
- Desktop metadata-only `local_*.json` files are not returned as transcript files.

### Parser/Metadata Tests
Covered or targeted fixtures:

- Desktop metadata plus matching nested transcript.
- Metadata title used when transcript lacks a meaningful title.
- Transcript custom title beats Desktop metadata title.
- `originCwd` is used for display cwd when transcript cwd is an ephemeral `/sessions/...` path.
- `createdAt` / `lastActivityAt` are used only when transcript timestamps are missing.

### Index Tests
In `AgentSessionsTests/Indexing/CoreSessionMetaTests.swift`:

- Generic origin/surface fields persist and hydrate.
- Existing Codex surface rows still hydrate correctly.
- Claude Desktop rows hydrate with `surface == .desktop` and source still `.claude`.

### UI Tests
Add lightweight view/model coverage where possible:

- Agent column shows a Desktop pill for Claude Desktop rows.
- Existing Codex `Desktop`, `VS Code`, and `CLI` pills are unchanged.
- Subagent marker remains in the session/title area, not duplicated as the agent-origin pill.

## Manual Validation
Use a temporary fixture first, then this machine's real Desktop data.

Fixture validation:

1. Create temp roots:
   - `tmp/.claude/projects/demo/session.jsonl`
   - `tmp/.claudeWork/projects/work/session.jsonl`
   - `tmp/Application Support/Claude/local-agent-mode-sessions/.../local_x/.claude/projects/demo/cli-session-id.jsonl`
   - matching `local_x.json`
2. Run focused discovery/parser tests.
3. Run full build:
   `xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug -destination 'platform=macOS' build`

Real data validation:

1. Launch AS with Claude enabled.
2. Trigger a full Claude refresh/reindex.
3. Confirm rows from:
   - `~/.claude/projects`
   - `~/Library/Application Support/Claude/local-agent-mode-sessions`
4. Confirm Desktop rows show `Claude` provider with Desktop surface metadata.
5. Confirm transcript rendering works for nested Desktop JSONL files.
6. Confirm focused refresh notices changes to a selected Desktop transcript.
7. Confirm metadata-only `claude-code-sessions` records are not presented as blank transcripts.

## Performance Guardrails
Desktop local-agent directories can contain plugins, generated outputs, uploads, shell snapshots, and caches. Do not recursively scan the whole tree without constraints.

Rules:

- Only scan `.claude/projects` subtrees under discovered `local_*` directories.
- Do not scan `uploads`, `outputs`, `skills-plugin`, `cowork_plugins`, cache directories, or arbitrary Desktop app storage.
- Preserve recent-delta behavior by selecting recent candidate roots and changed files only.
- Keep file caps per selected project/root and surface drift as existing Claude indexing does.

## Risks
Metadata-only sessions:

- Claude Desktop may show sessions that have local metadata but no local transcript.
- First implementation should skip them rather than show misleading empty rows.

Path volatility:

- Desktop stores sessions under nested account/workspace IDs and `local_*` directories.
- Discovery should pattern-match shape, not hard-code the account IDs observed on one machine.

Schema churn:

- Generic origin/surface fields require a reindex/migration path.
- Keep Codex compatibility until old indexed rows have been refreshed.

Privacy:

- Desktop metadata includes account/email fields in some files.
- Do not store account name or email in AS index unless explicitly needed. The current design does not need them.

## Completed First Pass
The first pass implemented transcript-backed Desktop local-agent discovery, Desktop metadata enrichment, generic origin/surface persistence, hydration support, and the Agent-column Desktop pill.

Remaining validation and follow-up:

1. Run focused tests.
2. Run the active scheme build.
3. Manually verify against real local Claude Desktop data.
4. Consider metadata-only `claude-code-sessions` rows only after a readable transcript source is proven.

## Recommendation
Implement transcript-backed Claude Desktop sessions first and skip metadata-only Desktop Code-tab records until a readable transcript source is proven for those rows.

Use a generic origin/surface model instead of extending Codex-named fields. The Codex Desktop work already established the UI concept; Claude Desktop makes it clear that the concept belongs to sessions generally, not only Codex.
