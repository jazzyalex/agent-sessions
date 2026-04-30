# Show HN Post

## Title options (pick one)

- "Show HN: Agent Sessions - local-first session browser for AI coding CLIs"
- "Show HN: I built a macOS app to search and resume AI coding sessions"

**Timing:** Tuesday or Wednesday, 9:00–11:00 AM Pacific

---

## First comment (personal story format)

I built this because I use Claude Code for work and Codex CLI for side projects, and I kept losing track of sessions. Last month I spent 20 minutes grepping through local session files trying to find a prompt where I'd worked out a tricky migration strategy. That was the moment I decided to build a proper tool for this.

Agent Sessions reads local session files from Codex CLI, Claude Code, Cursor CLI, Gemini CLI, GitHub Copilot CLI, OpenCode, and OpenClaw. It lets you search across them, read formatted transcripts, inspect tool calls and outputs, and resume supported sessions from Terminal or iTerm2. Droid import remains available for legacy histories, but Droid is not part of the active support set.

What I think is interesting about this project:

- It's local-first. No telemetry, no cloud account, and no session-history uploads. The main indexer reads local agent histories; explicit actions such as terminal resume, optional update checks, and probe cleanup are surfaced separately.
- Codex local history from CLI, Desktop, and VS Code is searchable in one place, with surface labels so the source remains clear.
- The transcript view formats tool calls and outputs so you do not have to read raw JSON to recover useful work.
- Agent Cockpit is a live HUD for active iTerm2 Codex, Claude, and OpenCode sessions, with active/waiting state and usage visibility.

MIT licensed, macOS-only (native Swift app). Signed and notarized.

I'd love feedback on the UX and on which agents/workflows to prioritize next. If you use an agent I do not support yet, I'm happy to look at session format samples.

---

## HN engagement notes

- Respond to every substantive comment within 2 hours on launch day
- If asked about Windows/Linux: "macOS-only for now — the native Swift stack is part of what makes it fast and battery-friendly, but happy to discuss"
- If asked about telemetry: "No telemetry, no analytics, and no remote logging. The only network activity is optional Sparkle update checks."
- If asked about monetization: "Free and MIT-licensed. No current plans to charge."
- If asked whether it is an agent runner: "No. Agent Sessions is the local history and resume layer for the agents you already use."
