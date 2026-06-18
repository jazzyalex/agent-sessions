# Probe Results

Generated on 2026-06-17 against local Codex storage. No Agent Sessions app code
was modified.

## Recent JSONL Shape

Command:

```bash
./side-chat-probes-tmp/run_probe.sh --max-files 50
```

Key observations from the 50 newest JSONL files:

- Top-level event types are generic: `response_item`, `event_msg`,
  `turn_context`, `session_meta`, and `compacted`.
- `event_msg.payload.type` contains generic lifecycle events such as
  `token_count`, `agent_message`, `thread_goal_updated`, `patch_apply_end`,
  `task_started`, and `task_complete`.
- Thread-routing keys seen: `threadId` and `parent_thread_id`.
- State DB has `threads` and `thread_spawn_edges`; there are no
  side/conversation-like tables.
- `threads.thread_source` values were `<null>`, `subagent`, `user`, and
  `automation`.
- The only side-like key hit in the recent scan came from this disposable
  `side-chat-probes-tmp` path being present in patch metadata, not from Codex
  `/side` storage.

## Prototype Direction

Command:

```bash
swiftc side-chat-probes-tmp/SyntheticThreadChildrenPrototype.swift \
  -o side-chat-probes-tmp/.build/SyntheticThreadChildrenPrototype
side-chat-probes-tmp/.build/SyntheticThreadChildrenPrototype
```

Output:

```text
Synthetic generic thread-child rows
- [main children=2] Refactor parser (main-a)
  - [side] Quick API question (side-a1)
  - [subagent] Review worker (sub-a1)
- [main] Standalone task (main-b)
```

This supports adding a generic relationship kind rather than overloading
`subagentType` for side chats.

## Recommendation

Before changing Agent Sessions source code, create one fresh throwaway Codex
thread, run `/side` or `/btw` with a unique non-sensitive marker, then rerun:

```bash
./side-chat-probes-tmp/run_probe.sh --max-files 20
```

If the marker creates a new `thread_source`, DB edge, top-level event type, or
stable key path, use that as the parser/index rule. If it creates only ordinary
message events with no stable marker, Agent Sessions cannot reliably filter side
chats from persisted storage without upstream Codex adding a durable marker.
