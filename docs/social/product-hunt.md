# Product Hunt Listing

**Launch timing:** 3 days after Show HN (Thursday, 12:01 AM Pacific)

---

## Tagline

Search and resume AI coding sessions across 7 CLI agents

---

## Description

Agent Sessions is a local-first macOS app that unifies your AI coding history. Browse, search, and resume sessions from Codex CLI, Claude Code, Gemini CLI, GitHub Copilot CLI, Droid, OpenCode, and OpenClaw in one native window.

No telemetry. No cloud. No account. Just your sessions, searchable and resumable.

**What it does:**
- Unified session list across all supported agents, sorted by recency
- Full-text search across agents and within sessions
- Formatted transcript view with readable tool calls and navigation between prompts
- Right-click any session → Copy Resume Command → paste into terminal
- Agent Cockpit: live HUD for active sessions with token usage tracking

**New in 3.4:**
- Codex subagent sessions now nest under their parent in the session list (Cmd+H to toggle)
- Agent Cockpit shows live subagent count badges per session
- Fixed a CPU drain that ran even when sessions were idle

**Privacy:** Everything is local. The app has read-only access to your session directories. The only network call is Sparkle update checks. MIT licensed.

---

## Topics

Developer Tools · macOS · Open Source · Artificial Intelligence · Productivity

---

## First comment (post at launch)

Hey PH 👋

I built Agent Sessions because I was grepping through JSON files trying to find old Claude Code prompts. There had to be a better way.

The core insight: all the major AI coding CLIs store their sessions locally in semi-structured formats, but none of them ship a good history browser. So I built one that works across all of them.

The feature I'm most excited about in 3.4 is the subagent hierarchy. When Codex CLI runs a complex task, it spawns multiple worker agents. Previously they showed up as a flat list of sessions with no parent-child relationship — finding what each worker actually did was a puzzle. Now they nest under their parent session with a toggle.

Happy to answer questions about how the session parsing works, or about the local-first architecture.

---

## Maker notes

- Mention the GitHub repo link in your first comment
- Engage with every comment on launch day
- Share the PH link on X/Twitter and in relevant Slack communities
- Ask your network to upvote and leave honest feedback (not "please upvote" — share genuinely)
