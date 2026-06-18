# Codex Side Chat Recovery Prep

This is a disposable implementation-prep note. It describes the pre-implementation state; the follow-up V1 implementation now modifies Agent Sessions app code.

## User Problem

Codex app and CLI users can create useful `/side` chats while working in a main session. After the app restarts or the parent session is no longer open, those side chats are hard to find again. The recovery job is usually one of two workflows:

- The user remembers a unique phrase and wants to search for it, then read or copy the side-chat answer.
- The user does not remember a phrase, but knows the parent session and wants to visually browse its recent side chats, especially today's side chats, with enough context to recognize the right one.

The second workflow means the first UI should be parent-scoped. A broad "only side chats" filter is useful later, but it is not the primary recovery surface.

## Current Evidence

- `Session` currently has `parentSessionID`, `subagentType`, and `isSubagent`, but no generic relationship kind or side-chat kind. See `AgentSessions/Model/Session.swift:55`.
- Full Codex parsing extracts `session_meta.payload.source.subagent.thread_spawn.parent_thread_id` and `agent_role`, then stores them as parent/subagent metadata. See `AgentSessions/Services/SessionIndexer.swift:1847`.
- Lightweight Codex parsing duplicates that subagent metadata path and must stay symmetric with full parsing. See `AgentSessions/Services/SessionIndexer.swift:2040`.
- The hierarchy builder is named around subagents but already groups resolved parent/child sessions by `parentSessionID`. See `AgentSessions/Services/SubagentHierarchyBuilder.swift:3`.
- Unified rows disable hierarchy when search is active. See `AgentSessions/Views/UnifiedSessionsView.swift:2091`.
- The toolbar already has a hierarchy toggle beside agent filters. See `AgentSessions/Views/UnifiedSessionsView.swift:1404`.
- Existing row rendering treats nested and flat child markers as subagents, including the `sub` marker and purple role badge. See `AgentSessions/Views/UnifiedSessionsView.swift:3288`.
- The local probe over existing Codex data found no durable side-chat marker yet. It did find `threads.thread_source` values `<null>`, `subagent`, `user`, and `automation`, and no side-chat table. See `side-chat-probes-tmp/RESULTS.md`.

## Required Storage Proof Before App Code

Do not implement side-chat parsing from path names, transcript text, or "side" string hits. The current local scan produced a false side-like marker caused by this disposable folder path in patch metadata.

Before changing Agent Sessions source, create a fresh throwaway `/side` sample with a unique marker and run:

```bash
./side-chat-probes-tmp/run_probe.sh --max-files 20
./side-chat-probes-tmp/run_probe.sh --max-files 200 --scan-values
```

Acceptable durable signals, in preferred order:

1. A Codex state DB relationship, such as a `threads.thread_source = side_chat` value or a `thread_spawn_edges` relationship that identifies side chats.
2. A `session_meta.payload.source` shape that marks side chat and provides a parent thread id.
3. A stable JSONL lifecycle event that marks a side chat and its parent.

If none exists, Agent Sessions cannot reliably recover side chats from current persisted data without upstream Codex adding a marker.

Follow-up probe with a real `/side` marker (`ABRACADABRA test phrase`) found one additional source:

- `logs_2.sqlite.logs` contains the side-chat turn and a distinct side conversation id.
- The side-chat id was not present as a row in `state_5.sqlite.threads`.
- The marker did not appear in normal session JSONL before it was repeated in the main thread.
- The large websocket request contains the side-conversation boundary text: `You are a side-conversation assistant, separate from the main thread.`

This changes the fallback architecture: phrase search can recover side-chat content from logs today, but parent-scoped browsing still needs a reliable parent-to-side mapping that is not just copied transcript context. See `side-chat-probes-tmp/SIDE_CHAT_LOG_FINDINGS.md`.

## Data Model Recommendation

Add a first-class relationship kind instead of overloading `subagentType`.

Suggested shape:

```swift
enum SessionRelationshipKind: String, Codable, Sendable {
    case root
    case subagent
    case sideChat
    case relatedThread
}
```

Model rules:

- `parentSessionID` remains the raw parent thread/session id.
- `subagentType` remains only the subagent role or legacy role string.
- `relationshipKind == .subagent` when existing subagent metadata is present.
- `relationshipKind == .sideChat` only when a proven side-chat marker is present.
- `relationshipKind == .relatedThread` is a conservative fallback for a parented Codex child whose exact kind is unknown.
- Existing rows with `parentSessionID != nil` and `subagentType != nil` hydrate as `.subagent`.
- Existing root rows with no parent hydrate as `.root`.

DB path to update later:

- `session_meta` schema and migrations in `AgentSessions/Indexing/DB.swift`.
- `SessionMetaRow` and fetch/upsert mapping in `AgentSessions/Indexing/DB.swift`.
- Hydration in `AgentSessions/Indexing/SessionMetaRepository.swift`.
- Search indexing only if side-chat transcript text becomes separate from parent transcript text.

## UI Architecture

Primary surface: parent-scoped side-chat recovery.

When a parent session is selected, the existing list hierarchy should show side chats as child rows, and the transcript pane should expose a compact "Side chats" strip or right rail for that parent. This keeps the app as one session browser instead of adding a separate recovery tool. The parent-scoped strip should be sorted by recency and grouped by `Today`, `Yesterday`, and `Earlier` when there are enough items. Each item needs recognition data:

- start time or relative time
- title if available
- first user prompt line or compact generated summary
- model when available
- short id only as fallback
- parent session context kept visible in the header

Actions for a selected side chat should prioritize recovery:

- open/read side-chat transcript
- copy answer or copy transcript
- export Markdown
- open parent session
- reveal log
- copy side-chat id

Do not prioritize resume or terminal focus actions until Codex exposes a reliable side-chat resume target. This is a read/copy/export workflow first.

Secondary surface: phrase search.

If a user searches a unique phrase and the match is inside a side chat, the result should be a side-chat row with a `side` marker and a parent crumb. It should not require the parent session itself to match. Since hierarchy is disabled while search is active, the search result can be flat:

- `side` badge
- side-chat title or first prompt
- `Parent: <parent title>` secondary line
- match snippet
- action to open the parent

Tertiary surface: global side-chat browse.

A toolbar browse mode for "Recent side chats" can exist, but should be framed as a fallback when the user does not remember the parent. It should retain parent context and allow date narrowing (`Today`, `7 days`, `All`) to prevent a noisy list.

## Hierarchy Recommendation

Generalize `SubagentHierarchyBuilder` semantics before adding side chats:

- Rename concepts to thread-child relationships in code when making the app change.
- Keep one-level parent/child rendering for the first version.
- Do not use the role-only subagent parent inference for side chats. Side chats need an explicit parent signal.
- In mixed parents, show distinct counts: `2 side, 1 sub`.
- Flat search results should use `side`, not `sub`.

## Parent-Scoped Filtering Rules

For a selected parent session:

- The side-chat rail shows only children whose resolved parent is that selected parent.
- Archived parents still show recoverable side chats when the archived parent is selected or search matched it.
- Global saved/favorite filtering should not hide side-chat children inside an already selected parent unless the side-chat item itself becomes saveable.
- Active-only should not be the default lens for recovery, because the target side chat is often historical.

## Tests To Add During Implementation

- Parser fixture for confirmed side-chat metadata shape, with both full and lightweight Codex parse paths.
- Negative fixture proving ordinary subagent and parent sessions are not classified as side chats.
- DB round-trip for `relationshipKind`.
- Mixed hierarchy ordering: parent with subagent child and side-chat child.
- Search result behavior: side-chat match appears when parent text does not match.
- Parent-scoped rail policy: selected parent returns only its side chats, grouped by date.
- Transcript selection: selected side-chat transcript renders side-chat events and keeps parent action available.

## Verification Gates For Later App Change

Use the repo's normal build discipline once Agent Sessions source changes:

```bash
git diff --check
./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/SessionParserTests -only-testing:AgentSessionsTests/CoreSessionMetaTests
xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug build
```

Manual QA:

- Create or use a fixture with at least two side chats under one parent.
- Select parent and verify only that parent's side chats appear.
- Search a unique phrase from one side chat and verify the flat result shows parent context.
- Open a side-chat transcript, copy content, return to parent without losing selection.
- Restart app and verify the same side chats are still discoverable.

## First Implementation Slice

Do not start with a global "side chats only" filter. Start with:

1. Proven persisted side-chat marker or a logs-backed side boundary fallback.
2. Relationship kind in model and DB.
3. Parent-scoped side-chat rail for the selected parent after parent linkage is reliable.
4. Search result rows for phrase recovery, which can be prototyped earlier from `logs_2.sqlite`.

That slice directly solves the lost-content problem without over-expanding the session list UI.
