# Side Chat Probes

Disposable probes and plans for investigating how Codex `/side` chats might be
represented in local JSONL/state/log storage.

This folder is intentionally outside the Agent Sessions app source tree. It can
be deleted after the experiment.

## Run

```bash
./run_probe.sh
```

The probe prints aggregate schema evidence only:

- top-level JSONL event type counts
- `event_msg.payload.type` counts
- `event_msg` key counts
- thread-routing key counts
- files with side-like marker names
- files with multiple thread-ish IDs
- Codex state DB table and `threads.thread_source` summaries

It does not print user or assistant message text.

## Interpretation

Useful positive signals for Agent Sessions support would be stable markers such
as `side_chat`, `side_thread`, `side_chat_id`, or a recurring `event_msg` type
that clearly names side-chat lifecycle boundaries.

If no stable side-specific marker exists, the next best experiment is to create a
fresh Codex `/side` sample in a throwaway thread and rerun the probe before
touching Agent Sessions code.

## Current Review

The latest real `/side` marker test changed the conclusion:

- JSONL and `state_5.sqlite` still do not expose side chats as normal sessions.
- `logs_2.sqlite` does contain side-chat user/assistant content and a distinct
  side thread id.
- Parent linkage is not yet clean enough to safely nest side chats under the
  parent session.

Read these before implementation:

- `FULL_REVIEW.md`
- `V1_FULL_PLAN.md`
- `SIDE_CHAT_LOG_FINDINGS.md`
