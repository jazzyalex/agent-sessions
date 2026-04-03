# Show HN Post

## Title options (pick one)

- "Show HN: Agent Sessions — local-first session browser for Codex, Claude, Gemini, and 4 more AI coding CLIs"
- "Show HN: I built a macOS app to search and resume sessions across 7 AI coding agents"

**Timing:** Tuesday or Wednesday, 9:00–11:00 AM Pacific

---

## First comment (personal story format)

I built this because I use Claude Code for work and Codex CLI for side projects, and I kept losing track of sessions. Last month I spent 20 minutes grepping through ~/.claude/sessions trying to find a prompt where I'd worked out a tricky migration strategy. That was the moment I decided to build a proper tool for this.

Agent Sessions reads the local session files from Codex CLI, Claude Code, Gemini CLI, GitHub Copilot CLI, Droid, OpenCode, and OpenClaw, and lets you search across all of them, read formatted transcripts, and resume sessions with one right-click.

What I think is interesting about this project:

- It's 100% local. No telemetry, no cloud, no account. The app is read-only — it never writes to your agent directories.
- The new subagent hierarchy (v3.4) shows Codex worker sessions nested under their parent, which makes it much easier to understand what happened in a complex multi-agent run.
- Agent Cockpit is a live HUD you can pin to your desktop that shows which of your agents are active, waiting, or idle, with token usage tracking.

MIT licensed, macOS-only (native Swift app). Signed and notarized.

I'd love feedback on the UX and on which agents/workflows to prioritize next. If you use an agent I don't support yet, I'm happy to look at session format samples.

---

## HN engagement notes

- Respond to every substantive comment within 2 hours on launch day
- If asked about Windows/Linux: "macOS-only for now — the native Swift stack is part of what makes it fast and battery-friendly, but happy to discuss"
- If asked about telemetry: "Genuinely none — no Sentry, no analytics, no crash reporting. The only network call is Sparkle update checks."
- If asked about monetization: "Free and MIT-licensed. No current plans to charge."
