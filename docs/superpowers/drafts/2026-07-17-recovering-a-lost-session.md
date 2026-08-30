# SUPERSEDED — do not edit or quote this file

This was the pre-publication draft of Rollout #3, "Recovering an AI coding-agent
session you thought you lost." It is kept only so the drafts folder stays
complete. **The live post is the source of truth:**

`docs/_posts/2026-07-17-recovering-a-lost-session.md`
→ https://jazzyalex.github.io/agent-sessions/blog/recovering-a-lost-session/

The draft body was removed on 2026-08-29 rather than left in place, because it
carried three claims that were verified false against the source and the disk
(commit `0b9a0ee1`). Anyone grepping the drafts folder would have found the
wrong version first.

**What was wrong, so it does not get reintroduced:**

1. **"Agent Sessions reads the OpenCode database including archived rows."**
   False. `OpenCodeSqliteReader.querySessionList` filters `WHERE time_archived
   IS NULL` in both of its queries, with no UI override, and
   `AgentSessionsTests/SessionParserTests.swift:3029` pins the behaviour by
   asserting an archived row's FTS entry is *pruned*. AS hides an archived
   OpenCode session exactly as the picker does. It *does* surface archived Codex
   rollouts and archived Claude Desktop sessions — the limitation is
   OpenCode-specific.
2. **"Claude marks an archived session with an `isArchived` flag in a sidecar
   that lives next to the session."** Wrong location. The sidecar is
   `~/Library/Application Support/Claude/claude-code-sessions/**/local_*.json`
   (plus `local-agent-mode-sessions/` for Cowork), joined to the CLI transcript
   by `cliSessionId`. Archiving is a Claude **Desktop** feature; the CLI has
   none, and the JSONL under `~/.claude/projects/` is never touched.
3. **The meta description promised Cursor and the body never mentioned it.** The
   live post now covers it: `~/.cursor/projects/<Path-Encoded>/agent-transcripts/
   <id>/<id>.jsonl`, the same path-encoding as Claude Code but with no leading
   dash, so Cursor hits the identical renamed-repo failure. Chat DBs under
   `~/.cursor/chats/` are hash-named and unaffected.

The published file also carried two leaked tool-call tags (`</content>` and
`</invoke>`) that rendered on the public page from 2026-07-17 until they were
removed on 2026-08-29. Check the tail of any generated post before committing.

Background and the knock-on fixes to the Discord drafts: `Marketing/STATUS.md`
→ "⚠️ Rollout #3 fact-check".
