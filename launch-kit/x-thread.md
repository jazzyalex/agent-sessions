# X / Twitter thread — Agent Sessions

Voice: understated, technical, credible. No hype, no emoji.
Constraint: @jazzyalex is not X Premium, so **every post is ≤280 characters** (submit with ⌘+Return). Approx counts noted per post so Alex can verify before posting.

---

**1/** *(~256)*

Nine months ago I started Agent Sessions: a Mac app that reads the session history your coding agents leave on disk and makes it searchable.

Codex, Claude Code, Cursor + 6 more, in one local view.

~700 weekly users. Zero marketing. Here's what I learned.

---

**2/** *(~266)*

Every agent writes history to disk — but nowhere near the same way.

Some use append-only JSONL. Some a SQLite DB. Some a bespoke state store. They disagree on how a tool call, a project, even a timestamp is stored.

I now read 9 of these formats. There's no standard.

---

**3/** *(~264)*

The counterintuitive part:

As Codex, Claude and others added their own session features, the category didn't shrink for me — it clarified.

A single vendor can only ever show you its own history. Codex won't index your Claude sessions. Nobody runs one agent anymore.

---

**4/** *(~200)*

So the cross-agent view is the one thing a first-party tool structurally can't build. That's the whole bet.

Every new agent a developer adds makes a neutral, unified history *more* necessary, not less.

---

**5/** *(~249)*

It's local-first, and I mean it:

- No account, no backend, no telemetry
- Reads the folders your agents already write to, read-only
- Builds a local search index
- Only network call is an optional update check

I can't see what anyone does with it.

---

**6/** *(~255)*

Which makes the contributor PRs my best signal.

People have sent real features I didn't write: Warp terminal support, CodeBuddy, OpenCode, Copilot CLI discovery fixes. For a no-telemetry tool, an unsolicited PR is the clearest "this is load-bearing" I get.

---

**7/** *(~220)*

The numbers, plainly:

674 stars, 44 forks, 0 open issues
~700 weekly active users
9,240 downloads

And growth accelerated over time: ~55 stars/mo early, then 133 in March, 101 in April. It built as the category matured.

---

**8/** *(~193)*

If you run more than one coding agent, this is for you. macOS 14+, MIT, free.

DMG or: brew tap jazzyalex/agent-sessions && brew install --cask agent-sessions

github.com/jazzyalex/agent-sessions
