# Show HN

**Title (pick one — HN caps titles at 80 chars):**

- `Show HN: Agent Sessions – one local view of Codex, Claude, Cursor and 7 more`
- `Show HN: Search your local coding-agent history across 10 tools (macOS, no cloud)`

**URL:** https://github.com/jazzyalex/agent-sessions

---

**Body:**

I use several coding agents day to day — Codex, Claude Code, Cursor, a few others — and all of them write full session history to disk: prompts, tool calls, diffs, reasoning. The problem is that history is scattered and basically unsearchable. Each tool uses its own storage (some append-only JSONL, some a SQLite database, some a bespoke state store), so finding "the session where the agent fixed that migration last week" meant grepping thousands of files or just redoing the work.

Agent Sessions is a macOS app that reads those local files and gives you one searchable, browsable view across all of them. It currently supports ten sources: Codex, Claude Code, Cursor, OpenCode, GitHub Copilot CLI, Hermes, OpenClaw, Antigravity, Pi, and Kimi Code. You get full-text search across every session, a readable transcript view with tool calls and outputs, an image browser for visual outputs, and — for the CLIs that support it — a right-click "resume" that opens the session back up in Terminal, iTerm2, or Warp.

It's local-first by design. No account, no backend, no telemetry — I literally cannot see what anyone does with it. It reads the session folders your agents already write to (in read-only mode) and builds a local search index. The only network call is an optional Sparkle update check.

Some honest limitations: it's macOS 14+ only, there's no Windows or Linux build, and every source depends on reverse-engineering formats the vendors can change between releases, so occasionally a new agent version breaks a parser until I catch up. It doesn't sync anything, by design.

Why build it when the vendors are adding their own session features? Because a single vendor's tool can only ever show you its own history — Codex won't index your Claude sessions, and vice versa. The cross-agent, unified view is the part no first-party tool can do, and it gets more useful the more agents you run.

It's been out about ten months, entirely word of mouth: ~700 weekly active users, ~11,400 downloads, MIT licensed. External contributors have added support for things like Warp and CodeBuddy. Happy to answer questions about the storage formats — the differences between how these tools persist a session are genuinely all over the place.

Install: DMG on the releases page, or `brew tap jazzyalex/agent-sessions && brew install --cask agent-sessions`.
