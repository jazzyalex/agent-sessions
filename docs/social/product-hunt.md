# Product Hunt Listing

**Launch timing:** 3 days after Show HN (Thursday, 12:01 AM Pacific)

---

## Tagline

Search and resume local AI coding sessions on macOS

---

## Description

Agent Sessions is a local-first macOS app that unifies your AI coding history. Browse and search sessions from Codex CLI, Claude Code, Cursor CLI, Gemini CLI, GitHub Copilot CLI, OpenCode, and OpenClaw in one native window. Droid import remains available for legacy histories, but Droid is not part of the active support set.

No telemetry. No cloud account. No session-history uploads. Just your local agent history, searchable and resumable where the underlying CLI supports it.

**What it does:**
- Unified session list across all supported agents, sorted by recency
- Full-text search across agents and within sessions
- Formatted transcript view with readable tool calls and navigation between prompts
- Right-click supported sessions -> Copy Resume Command -> paste into Terminal or iTerm2
- Codex local history from CLI, Desktop, and VS Code in one searchable view
- Agent Cockpit: live HUD for active iTerm2 Codex, Claude, and OpenCode sessions

**Current release focus:**
- Menu bar controls update immediately when Preferences change
- Agent Sessions and Agent Cockpit menu actions switch between Open and Hide based on visible windows
- Transcript rendering keeps tool calls and outputs readable without digging through raw session JSON

**Privacy:** Everything is local. The indexer reads local session directories you choose or the default CLI locations. The only network activity is optional Sparkle update checks. MIT licensed, signed, and notarized.

---

## Topics

Developer Tools · macOS · Open Source · Artificial Intelligence · Productivity

---

## First Comment (post at launch)

Hey PH,

I built Agent Sessions because I was grepping through JSON files trying to find old Claude Code prompts. There had to be a better way.

The core insight: all the major AI coding CLIs store their sessions locally in semi-structured formats, but none of them ship a good history browser. So I built one that works across all of them.

The workflow I care about most is simple: search for an old task, open the exact transcript section, inspect the readable tool output, and resume the supported CLI session from the terminal when there is more work to do.

Happy to answer questions about how the session parsing works, the local-first architecture, or which agent formats should come next.

---

## Maker notes

- Mention the GitHub repo link in your first comment
- Engage with every comment on launch day
- Share the PH link on X/Twitter and in relevant Slack communities
- Ask your network to upvote and leave honest feedback (not "please upvote" — share genuinely)
- Reuse the same trust receipts as Show HN: Privacy, Security, MIT license, signed/notarized release, and Sparkle-only update checks
