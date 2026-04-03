# Dev.to Article Outline

**Title:** Stop Re-explaining Your Project to Your AI Coding Agent

**Publish:** 2–3 days BEFORE the Show HN post. Becomes a reference link in HN, Reddit, and Product Hunt.

**Tags:** `productivity`, `devtools`, `ai`, `macos`

**Cover image:** `docs/assets/AS-social-media.png`

---

## Section 1: The Problem (~300 words)

Opening hook (first person, specific):
> Last Tuesday I spent 20 minutes grepping through ~/.claude/sessions looking for a prompt where I'd worked out a database migration strategy. I remembered the session existed. I remembered it worked. I couldn't find it.

Expand the pain:
- You switch between agents (Claude Code for work, Codex for side projects, maybe Gemini for experiments)
- Each tool stores sessions in a completely different format, in a different hidden directory
- None of them have a good native history browser
- When you start a new session on the same problem, you spend the first 10 minutes re-explaining context the agent already knew last week

Close with the question the article will answer:
> What if you could search across all your agent sessions the same way you search your notes?

---

## Section 2: What I Built (~200 words)

- Introduce Agent Sessions by name
- One-sentence description: "a local-first macOS app that indexes your AI coding CLI session files and lets you search, browse, and resume them"
- Screenshot: `screenshot-H.png` (main session view)
- Mention the 7 supported agents
- Lead with the trust angle: "everything runs locally — no telemetry, no cloud, read-only access to your session files"

---

## Section 3: How It Works — Walkthrough (~400 words)

Walk through the core workflow with screenshots at each step:

**Step 1: Unified session list**
- Screenshot: `screenshot-V.png` (vertical layout showing mixed agents)
- "Sessions from all your agents appear in one list, sorted by recency"

**Step 2: Search**
- Screenshot: search results view
- "Full-text search across all agents. Type a keyword, see matching sessions and their matching lines."

**Step 3: Transcript view**
- Screenshot: `screenshot-H.png`
- "Tool calls are parsed and formatted. Navigate between prompts, tool outputs, and errors."

**Step 4: Resume**
- Screenshot: context menu showing "Copy Resume Command"
- "Right-click any session, copy the resume command, paste into your terminal. The CLI picks up with the right session ID and flags."

**Step 5: Agent Cockpit**
- Screenshot: `screenshot-cockpit-light.png`
- "A live HUD for active sessions. Pin it to your desktop, see which agents are active or waiting, track token usage."

---

## Section 4: What's New in 3.4 (~200 words)

- Subagent hierarchy: explain the problem it solves (Codex spawns worker agents; before 3.4 they showed as a flat list with no parent-child relationship)
- Screenshot: `screenshot-subagent-hierarchy.png`
- Cockpit badges: subagent count per session visible at a glance
- Performance fix: eliminated a CPU drain that ran even when sessions were idle

---

## Section 5: The Trust Model (~200 words)

Why local-first matters for developer tools:
- Your session history contains your codebase context, your API keys you accidentally typed, your reasoning about sensitive decisions
- Agent Sessions never sends any of this anywhere
- List the exact paths it reads
- Explain why it's not sandboxed (needs filesystem access to agent dirs) and link to docs/security.md
- MIT licensed — you can audit the source

---

## Section 6: Try It (~100 words)

Install options:
```
# Download DMG
https://github.com/jazzyalex/agent-sessions/releases/download/v3.4/AgentSessions-3.4.dmg

# Homebrew
brew tap jazzyalex/agent-sessions
brew install --cask agent-sessions
```

macOS 14+ required.

Star the repo if it's useful: https://github.com/jazzyalex/agent-sessions

---

## Notes

- Keep a personal, first-person tone throughout
- Avoid marketing language ("powerful", "revolutionary", "game-changer")
- Specific details > vague claims: say "searches ~/.claude/sessions and ~/.codex/sessions" not "searches your sessions"
- End with a question to drive comments: "Which AI coding CLI do you use most? I want to make sure the session format for it is well-supported."
