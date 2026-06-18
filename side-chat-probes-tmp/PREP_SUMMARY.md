# Side Chat Recovery Prep Summary

Disposable prep artifacts live in this folder only. Agent Sessions source was not modified.

## Files

- `SideChatShapeProbe.swift` and `run_probe.sh`: local Codex storage shape probe.
- `SyntheticThreadChildrenPrototype.swift`: standalone relationship-kind prototype.
- `RESULTS.md`: current probe findings.
- `SIDE_CHAT_LOG_FINDINGS.md`: real `/side` marker evidence from `logs_2.sqlite`.
- `probe_side_chat_logs.sh`: literal phrase probe for side-chat log recovery.
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

The recommended first UI is not a broad side-chat filter. It is a parent-scoped recovery surface inside the existing Sessions window:

- select parent session
- see that parent's recent side chats as related child rows and in a compact side-chat strip
- open/read/copy the side-chat transcript
- export Markdown or reveal the log when needed
- search globally by a remembered phrase when needed

## Next Commands

```bash
./side-chat-probes-tmp/run_probe.sh --max-files 20
./side-chat-probes-tmp/probe_side_chat_logs.sh "ABRACADABRA test phrase" 019ed6b5-8eaa-7403-873c-2bc43e7b690a
swiftc side-chat-probes-tmp/SyntheticThreadChildrenPrototype.swift -o side-chat-probes-tmp/.build/SyntheticThreadChildrenPrototype
side-chat-probes-tmp/.build/SyntheticThreadChildrenPrototype
open side-chat-probes-tmp/mockups/side-chat-ui-mockup.html
```
