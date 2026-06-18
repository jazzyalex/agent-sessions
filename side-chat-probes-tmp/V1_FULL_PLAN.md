# V1 Full Plan: Codex Side Chat Recovery

This plan is for a small, shippable V1 in Agent Sessions. It intentionally keeps the UI simple and separates proven discovery from unproven parent hierarchy.

## Goal

Let users recover closed Codex `/side` chats so they can read, search, copy, and export useful content after the original side chat is no longer visible in Codex Desktop.

## Non-Goals

- No separate Side Chat Recovery window.
- No timeline, graph, summary generation, semantic search, or AI labeling.
- No global side-chat dashboard in V1.
- No parent hierarchy based on weak inference.
- No resume/focus action for side chats unless Codex exposes a real resume target.

## Product Shape

V1 has two surfaces:

1. Search recovery: a phrase match inside a side chat appears as a flat `side` result.
2. Related hierarchy: side chats appear beside subagents under a parent only when parent linkage is reliable.

If parent linkage is not reliable, V1 still ships phrase recovery and shows `Parent unavailable` for side-chat results.

## Data Model

Add:

```swift
enum SessionRelationshipKind: String, Codable, Sendable {
    case root
    case subagent
    case sideChat
    case relatedThread
}
```

Add fields to `Session`:

- `relationshipKind: SessionRelationshipKind`
- optional `relationshipConfidence` or `relationshipSource` if logs-backed rows are included

Keep:

- `parentSessionID` for parent references
- `subagentType` only for subagent roles

Update `isSubagent` semantics carefully. Prefer new computed properties:

- `isChildThread`
- `isSideChat`
- `isSubagent`

## Storage And Indexing

### Phase 1: relationship field plumbing

Expected files:

- `AgentSessions/Model/Session.swift`
- `AgentSessions/Indexing/DB.swift`
- `AgentSessions/Indexing/SessionMetaRepository.swift`
- tests in `AgentSessionsTests/Indexing/CoreSessionMetaTests.swift`

DB:

- add `relationship_kind TEXT NOT NULL DEFAULT 'root'`
- optional `relationship_source TEXT`
- existing rows hydrate:
  - `parent_session_id != NULL OR subagent_type != NULL` plus subagent metadata -> `subagent`
  - no parent and no subagent -> `root`

Verification:

```bash
./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/CoreSessionMetaTests
```

### Phase 2: logs-backed side-chat discovery for search

Add a focused logs reader rather than changing normal JSONL parsing first.

Proposed new component:

```text
AgentSessions/Services/CodexSideChatLogIndexer.swift
```

Responsibilities:

- open newest `logs_*.sqlite` read-only
- identify side-chat thread ids by side boundary text:
  - `side-conversation assistant`
  - `separate from the main thread`
- extract side-thread events from `logs.thread_id`
- extract user text from `Submission sub=Submission`
- extract assistant text from response/output log events
- produce synthetic side-chat search records

Important guardrails:

- skip rows without a side boundary for that thread id
- use thread id as the side-chat id
- do not infer parent from copied context
- cap row size and number of rows per thread
- log failures as non-fatal

DB options:

Preferred: add a separate table so synthetic log-backed rows do not pretend to be normal session files.

```sql
CREATE TABLE IF NOT EXISTS side_chat_meta (
  id TEXT PRIMARY KEY,
  source TEXT NOT NULL,
  parent_session_id TEXT,
  parent_confidence TEXT,
  created_ts REAL,
  updated_ts REAL,
  cwd TEXT,
  title TEXT,
  model TEXT,
  relationship_source TEXT NOT NULL
);
```

Add search text either to `session_search` with synthetic ids or to a sibling `side_chat_search` table. The lower-blast-radius option is a sibling table plus a small merge step in `SearchCoordinator`.

Verification:

```bash
./side-chat-probes-tmp/probe_side_chat_logs.sh "ABRACADABRA test phrase" 019ed6b5-8eaa-7403-873c-2bc43e7b690a
./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/SessionParserTests
```

### Phase 3: parent linkage gate

Do not show side chats under parent hierarchy until one of these is true:

- state DB exposes a side-chat parent edge
- JSONL exposes side-chat parent metadata
- app/server fork logs expose parent and child ids in a clean field
- a Codex app connector can return parent/side relationship

If this gate is not met, phrase-search V1 can still ship.

If this gate is met:

- write `parentSessionID`
- set `relationshipKind = .sideChat`
- show side chats as children in hierarchy

### Phase 4: hierarchy UI

Rename/generalize hierarchy concepts where they leak into UI behavior:

- builder can keep the same algorithm
- row metadata should know child relationship kind
- row renderer shows:
  - `side` badge for side chats
  - `sub` or role badge for subagents

Keep UI minimal:

- no side rail
- no global side-chat filter in V1
- no split counts unless trivial

Expected files:

- `AgentSessions/Services/SubagentHierarchyBuilder.swift`
- `AgentSessions/Views/UnifiedSessionsView.swift`
- related tests in `AgentSessionsTests/SessionParserTests.swift`

Verification:

```bash
./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/SessionParserTests
```

## Search Behavior

When searching:

- hierarchy remains disabled, same as today
- side-chat matches appear as flat rows
- badge: `side`
- if parent known: secondary line or tooltip has parent title
- if parent unknown: secondary line says `Parent unavailable`

Selecting a side-chat result:

- opens transcript pane with side-chat content only
- shows copy/export/reveal actions
- does not offer resume/focus

## Transcript Behavior

Use existing transcript rendering where possible. For synthetic logs-backed side chats, build a minimal transcript model from log rows:

- user message rows
- assistant message rows
- timestamps when available
- raw source reference to `logs_2.sqlite` and log row ids

Actions:

- Copy transcript
- Export Markdown
- Copy side-chat id
- Reveal logs DB or source row context if the app has a safe affordance

## Tests

Add fixtures using sanitized log snippets, not full local logs.

Required tests:

- detects side boundary text and extracts side thread id
- extracts user and assistant messages for one side thread
- ignores normal main-thread logs that mention the marker later
- does not infer parent from copied parent context
- relationship kind DB round-trip
- row badge policy: side chat row renders as `side`, not `sub`
- search returns side-chat result when normal session search has no JSONL match

## Manual QA

1. Create a `/side` chat with a unique phrase.
2. Close/restart Codex Desktop if needed.
3. Search phrase in Agent Sessions.
4. Verify result is labeled `side`.
5. Verify transcript content can be read and copied.
6. Verify result does not appear as `sub`.
7. If parent linkage gate is met, verify side chat nests under the correct parent.
8. If parent linkage is not met, verify UI says parent unavailable instead of guessing.

## Implementation Order

1. Add model relationship kind and tests.
2. Add logs-backed side-chat discovery prototype behind normal indexing code, without UI hierarchy.
3. Add search result integration for side chats.
4. Add side-chat transcript display.
5. Add parent hierarchy only after parent linkage is proven.
6. Rename/generalize hierarchy UI labels once side chats share it with subagents.

## Ship Criteria

V1 can ship if:

- phrase search finds a closed side chat from logs
- selecting the result renders readable side-chat transcript content
- copy/export works
- normal subagent hierarchy is unchanged
- side chats are never labeled as subagents
- parent hierarchy is disabled or marked unavailable unless parent linkage is proven

## Stop Conditions

Stop and do not ship if:

- the logs reader cannot reliably distinguish side-chat threads from normal threads
- search results duplicate main-thread contamination as side-chat results
- side-chat transcript extraction depends on local-only row ids without stable thread grouping
- parent hierarchy requires time-nearest inference
- build or focused tests fail
