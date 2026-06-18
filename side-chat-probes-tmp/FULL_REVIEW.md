# Side Chat Recovery Full Review

This review covers prepared findings: storage discovery, parent linkage, indexing, data model, UI, tests, and implementation risk. It started as a prep artifact; the follow-up V1 implementation now modifies Agent Sessions app source and tests.

## Bottom Line

The feature is feasible, but not as one single step.

- Phrase-based recovery is feasible now from `logs_2.sqlite`.
- Side-chat hierarchy next to subagents is the right V1 UI target, but only after parent linkage is evidence-backed.
- Current JSONL and `state_5.sqlite` do not expose side chats as ordinary session rows.
- Treat side chats as related child threads, not as subagents.

## Evidence Reviewed

### JSONL

`run_probe.sh` found generic JSONL event types and no side-specific persisted session marker. The only side-like hit in recent JSONL was caused by this disposable folder path appearing in patch metadata, not by `/side` storage.

After the real marker `ABRACADABRA test phrase` was used in a side chat, normal JSONL did not contain the side transcript before the marker was repeated in the main thread. Once repeated, JSONL became contaminated by the main-thread message and tool-output echoes.

Conclusion: JSONL is not a reliable source for side chats in the tested build.

### `state_5.sqlite`

Current tables:

- `threads`
- `thread_spawn_edges`
- automation/job/support tables

Observed `threads.thread_source` values:

- `<null>`
- `subagent`
- `user`
- `automation`

No `side`, `side_chat`, `conversation`, or equivalent value appeared. The real side-chat thread id `019ed789-2247-7ad3-9b32-00a7875ffa77` did not exist in `threads`, and `thread_spawn_edges` had no side-chat edge.

Conclusion: state DB cannot currently drive side-chat discovery.

### `logs_2.sqlite`

The real `/side` marker was found in `logs_2.sqlite.logs`.

Confirmed evidence:

- side thread id: `019ed789-2247-7ad3-9b32-00a7875ffa77`
- user submission row contains the marker
- assistant output rows contain the marker
- a large websocket request row contains the side boundary text
- the boundary includes: `You are a side-conversation assistant, separate from the main thread.`

This is the strongest current discovery signal.

Conclusion: logs can support phrase recovery and can identify side-chat thread ids by boundary text and turn rows.

### Parent Linkage

The side chat was spawned by `thread/fork` at `2026-06-17 21:42:29`. The fork log rows have `thread_id = 019ed789-2247-7ad3-9b32-00a7875ffa77`, but the inspected fork rows do not carry a clean parent id. One pre-contamination request row contained both the current parent thread id and side thread id, but the parent id appeared inside copied parent-context payload, not a clean `parent_thread_id` field.

There was a temporary shell snapshot path for the side thread during fork, but no durable shell snapshot remained for the side thread in the later check.

Conclusion: parent linkage is not proven enough to ship parent-scoped hierarchy from logs alone.

## Current AS Fit

### Existing model

`Session` currently has:

- `parentSessionID`
- `subagentType`
- `isSubagent`

That is enough for current subagent hierarchy, but it is semantically wrong for side chats. Side chats are not subagents.

### Existing hierarchy

`SubagentHierarchyBuilder` already does the mechanical part we need: it resolves parent ids and inserts children after parent rows. The problem is naming and semantics, not layout mechanics.

### Existing row UI

The row renderer currently assumes nested children are subagents and uses `sub` / subagent role badge behavior. A side chat needs a separate `side` badge and help text.

### Existing search

Search flattens hierarchy while active. That is acceptable for side-chat phrase recovery: a matching side chat can appear as a flat result with a `side` badge and a parent crumb when parent linkage is available. If parent linkage is not available, the row should show `Parent unavailable`.

## Recommended Product Scope

V1 should not add a side rail, separate recovery window, graph, timeline, or global side-chat dashboard.

Recommended V1 UI:

- Keep the existing session table and transcript pane.
- Use the existing hierarchy view.
- Show side chats next to subagents as sibling child rows.
- Use `side` badge for side chats and `sub` badge for subagents.
- Keep parent count as a simple child count first. Split counts can wait.
- In search, show side-chat matches as flat `side` rows.

This keeps UI complexity low and matches the user's mental model: "I was in this parent session; show me its related side chats."

## Required Architecture

Add a generic relationship concept:

```swift
enum SessionRelationshipKind: String, Codable, Sendable {
    case root
    case subagent
    case sideChat
    case relatedThread
}
```

Rules:

- Existing subagents become `.subagent`.
- Side chats become `.sideChat`.
- Parented but unknown child threads become `.relatedThread`.
- `subagentType` remains only for subagent role labels.
- `isSubagent` should not be used as the generic "is child" predicate.

The hierarchy builder can be generalized without changing its core flattening behavior:

- `SubagentHierarchyBuilder` -> `RelatedThreadHierarchyBuilder`
- `SubagentRowMeta` -> `RelatedThreadRowMeta`
- Add child kind metadata for row rendering.

## Discovery Strategy

### Preferred source

Find or add an upstream persisted parent mapping:

- state DB `threads.thread_source = side_chat`
- state DB side-chat edge
- JSONL side-chat session metadata
- app/server fork metadata that includes parent and child ids

This is the only clean path for parent-scoped hierarchy.

### Fallback source

Use `logs_2.sqlite` for phrase recovery:

- detect side thread ids by `side-conversation assistant` boundary text
- extract user/assistant rows from log events for that side thread
- index them as synthetic side-chat search rows
- show parent as unavailable unless reliable linkage is found

This is useful, but should be explicitly lower confidence than normal session indexing.

## Rejected Shortcuts

- Do not classify side chats by path text or user message text containing `side`.
- Do not treat all `thread/fork` rows as side chats. Subagents also use thread spawning.
- Do not overload `subagentType = "side"` or make `isSubagent` true for side chats.
- Do not infer parent by nearest active session time unless clearly marked as low-confidence and excluded from hierarchy.
- Do not build a broad global side-chat browser before parent linkage is solved.

## Open Questions

- Is there an app connector/API that can return side-chat parent linkage directly?
- Does Codex Desktop keep side-chat parent linkage outside `~/.codex`, such as in app container storage?
- Can upstream Codex persist side chats into `state_5.sqlite.threads` with a new `thread_source`?
- Should logs-backed side chats be shown in normal sessions list or only search results until parent linkage is reliable?

## Review Verdict

Proceed with V1 only if it is split into two deliverables:

1. logs-backed phrase recovery for side chats
2. hierarchy display only when parent linkage is proven

Do not ship a parent-scoped side-chat hierarchy from the current evidence alone.
