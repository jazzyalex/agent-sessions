# Side Chat Log Probe Findings

This note was produced after creating a `/side` chat in the current Codex Desktop thread with the marker `ABRACADABRA test phrase`.

## Observed Storage

- Literal JSONL search found the marker only after it was repeated in the main thread message and subsequent tool-output echoes. It did not find an earlier side-chat JSONL transcript.
- `state_5.sqlite.threads` did not contain a row for the side-chat thread id and did not contain the marker in `title`, `first_user_message`, or `preview`.
- `state_5.sqlite.thread_spawn_edges` did not add a side-chat edge. It still only showed normal subagent edges.
- `logs_2.sqlite.logs` did contain the side-chat turn.

## Side Chat Evidence

The side-chat conversation id observed in logs was:

```text
019ed789-2247-7ad3-9b32-00a7875ffa77
```

Evidence from `logs_2.sqlite.logs`:

- First seen: `2026-06-17 21:42:29`.
- Last seen in the focused probe window: `2026-06-17 21:44:10`.
- 111 rows matched the side thread id or log bodies mentioning it.
- The log row `288679649` stored the user submission with the marker.
- The log row `288681398` stored a large websocket request containing the side-conversation boundary and the user marker.
- The log row `288684953` stored the assistant output item with the marker.

The side boundary text in the request includes:

```text
You are a side-conversation assistant, separate from the main thread.
```

This is a strong classifier for side chats in logs, but it is not present in normal session JSONL.

## Parent Linkage

The side chat was spawned through a `thread/fork` request at `2026-06-17 21:42:29`, and the log rows for that request have `thread_id = 019ed789-2247-7ad3-9b32-00a7875ffa77`.

One pre-contamination websocket request row contained both the current parent thread id and the side thread id, but the parent id appeared inside the large copied parent-context payload, not as a clean `parent_thread_id` field. Treat that as weak linkage until a better app/server source is found.

For Agent Sessions, this means:

- Side-chat content is recoverable today from `logs_2.sqlite`.
- Side-chat parent linkage is not yet cleanly proven from `state_5.sqlite` or JSONL.
- A logs fallback can support phrase search by side thread id.
- Parent-scoped browsing still needs a reliable parent-to-side mapping. The best next target is the app/server `thread/fork` request path, not transcript text.

## Probe Command

```bash
./side-chat-probes-tmp/probe_side_chat_logs.sh "ABRACADABRA test phrase" 019ed6b5-8eaa-7403-873c-2bc43e7b690a
```

After the marker is repeated in the main thread, use a cutoff to avoid contaminating the result set:

```bash
SIDE_PROBE_BEFORE="2026-06-17 21:43:00" ./side-chat-probes-tmp/probe_side_chat_logs.sh "ABRACADABRA test phrase" 019ed6b5-8eaa-7403-873c-2bc43e7b690a
```
