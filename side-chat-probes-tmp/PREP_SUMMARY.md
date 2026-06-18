# Side Chat Recovery Prep Summary

Disposable prep artifacts live in this folder. The initial investigation was read-only; the follow-up V1 implementation now modifies Agent Sessions app source and tests.

## Files

- `SideChatShapeProbe.swift` and `run_probe.sh`: local Codex storage shape probe.
- `SyntheticThreadChildrenPrototype.swift`: standalone relationship-kind prototype.
- `RESULTS.md`: current probe findings.
- `SIDE_CHAT_LOG_FINDINGS.md`: real `/side` marker evidence from `logs_2.sqlite`.
- `probe_side_chat_logs.sh`: literal phrase probe for side-chat log recovery.
- `FULL_REVIEW.md`: full review across discovery, parent linkage, indexing, UI, and risk.
- `V1_FULL_PLAN.md`: concrete V1 implementation plan.
- `IMPLEMENTATION_PREP.md`: next-step app implementation plan.
- `mockups/side-chat-ui-mockup.html`: static UI mockup for parent-scoped side-chat recovery and phrase search.
- `mockups/side-chat-ui-mockup-desktop.png`: desktop render check screenshot.
- `mockups/side-chat-ui-mockup-mobile.png`: mobile render check screenshot.
- `mockups/side-chat-ui-mockup-parent.png`: parent-scoped recovery state.
- `mockups/side-chat-ui-mockup-search.png`: phrase-search recovery state.
- `mockups/side-chat-ui-mockup-global.png`: recent side-chats browse state.

## Current Conclusion

The feature is feasible for phrase recovery today through `logs_2.sqlite`, because a real `/side` marker produced a distinct side conversation id and recoverable user/assistant content in logs. Existing JSONL and `state_5.sqlite` still did not expose the side chat as a normal session row.

Parent-scoped browsing remains the harder part: the current logs prove a side thread exists, but do not yet prove a clean `parent_thread_id` field for side chats. The next AS implementation step should either find a better fork-parent source or implement parent linkage only after it is evidence-backed.

The V1 UI should stay simple:

- phrase search shows `side` rows from logs-backed discovery
- side chats appear next to subagents in hierarchy only when parent linkage is proven
- no side rail, no separate recovery window, no global side-chat dashboard in V1
- side chats are never modeled or labeled as subagents

## Next Commands

```bash
./side-chat-probes-tmp/run_probe.sh --max-files 20
./side-chat-probes-tmp/probe_side_chat_logs.sh "ABRACADABRA test phrase" 019ed6b5-8eaa-7403-873c-2bc43e7b690a
swiftc side-chat-probes-tmp/SyntheticThreadChildrenPrototype.swift -o side-chat-probes-tmp/.build/SyntheticThreadChildrenPrototype
side-chat-probes-tmp/.build/SyntheticThreadChildrenPrototype
open side-chat-probes-tmp/mockups/side-chat-ui-mockup.html
```
