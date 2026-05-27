# Promotion Playbook (templates and checklists)

This is a practical playbook to promote Agent Sessions without guessing.

## Launch readiness checklist (before any big post)

Trust and legitimacy:
- [x] Add a top-level `LICENSE`
- [x] Add `SECURITY.md` with disclosure instructions
- [x] Add a “Security and Privacy” section in README:
  - session locations read
  - what is executed (Terminal launch, probes)
  - local-only guarantees
- [ ] Remove obvious accidental artifacts from git (generated logs, local paths, DMGs in repo if not required)

Product clarity:
- [ ] One hero workflow on top of README: find an old agent answer, inspect the transcript, and resume the session
- [ ] 30-60 second demo video showing the hero loop
- [ ] “Works with” list is accurate and tested

Promo assets:
- [ ] GitHub social preview image with the app name, native macOS UI, and the local-first promise
- [ ] Screenshot: Unified session list with multiple supported providers visible
- [ ] Screenshot: transcript search with a readable tool call or useful output selected
- [ ] Screenshot: Agent Cockpit with active/waiting state visible
- [ ] Short GIF or video: search old session -> open transcript -> copy resume command -> reopen in terminal
- [ ] 1-line description, 2-line description, and 5-bullet feature summary
- [ ] Trust boilerplate: local-first, no telemetry, MIT licensed, signed/notarized release, Sparkle-only update checks

Trust receipts to link from launch posts:
- GitHub repo: https://github.com/jazzyalex/agent-sessions
- Latest release DMG: https://github.com/jazzyalex/agent-sessions/releases
- Privacy: `docs/PRIVACY.md`
- Security: `docs/security.md`
- License: top-level `LICENSE`
- Homebrew cask install instructions in `README.md`

## Show HN draft (structure)

Title ideas:
- “Show HN: Local-first browser for Codex, Claude, Cursor, Gemini, Copilot, OpenCode, and OpenClaw sessions”
- “Show HN: I built a macOS app to search and resume AI coding sessions across local CLIs”

Body template:

1) One-sentence problem
- “My agent sessions were scattered across tools, and I kept losing context when starting fresh.”

2) One-sentence solution
- “Agent Sessions is a local-first macOS app that indexes local Codex, Claude, Cursor, Gemini, Copilot, OpenCode, and OpenClaw histories so you can search transcripts, inspect tool output, and resume supported sessions.”

3) 3 bullets: what it does
- Unified search across agents
- Readable transcript and tool-output browsing
- Resume workflows for supported CLIs plus Agent Cockpit for live iTerm2 sessions

4) 2 bullets: what it does not do (trust)
- No telemetry / no uploads
- Not a chat client or agent runner; it is the local history and resume layer
- Read-only session indexing by default; explain explicit actions such as opening terminals, update checks, and optional probe cleanup clearly

5) Links
- GitHub repo
- Release DMG
- Short demo video

6) Ask
- “If you use other agents and have session format samples, I’d love test fixtures.”

## 30-60 second demo script

Goal: show the daily workflow, not a tour of every feature.

1. Start in Unified Sessions with Codex, Claude, Cursor, Gemini, Copilot, OpenCode, and OpenClaw filters visible.
2. Search for a real phrase from an old migration, bug fix, or release task.
3. Open the best result and jump to the matching transcript section.
4. Show one readable tool call/output that would be painful to recover from raw JSON.
5. Right-click the session and copy the resume command for a supported CLI.
6. Paste or open the command in Terminal/iTerm2 and show the old context coming back.
7. End on Agent Cockpit if active sessions are running: the product is both history and live awareness.

Voiceover:
“Agent Sessions is a local-first macOS app for your AI coding history. I can search across Codex, Claude, Cursor, Gemini, Copilot, OpenCode, and OpenClaw, open the exact transcript, inspect the tool output, and resume supported sessions from the terminal. No telemetry, no cloud account, and no upload of my session history.”

## Positioning

Agent Sessions is not a chat client, not a hosted coding agent, and not a replacement for Codex, Claude Code, Cursor CLI, Gemini CLI, Copilot CLI, OpenCode, or OpenClaw.

The clean positioning:
- “The local history and resume layer for AI coding agents on macOS.”
- “Search the work your agents already did.”
- “Find the old context, inspect what happened, and resume from the right place.”

Use one primary promise per promo surface. Lead with search/resume history. Mention Agent Cockpit as the live-session companion, not as a second product.

## Outreach templates (partner ecosystem)

### Maintainers of multi-session managers (Crystal, Claude Squad, CCManager)

Subject:
“Agent Sessions integration idea: worktree-aware local session history”

Body:
- I built Agent Sessions, a local-first session browser for Codex, Claude, Cursor, Gemini, Copilot, OpenCode, and OpenClaw histories.
- Your tool owns running parallel sessions; mine is strong at browsing history across tools and resuming supported sessions from the right terminal context.
- I’d like to add a small integration so users can:
  - group sessions by worktree
  - jump from a running task to its local history
  - resume supported sessions from the right terminal context
- If you’re open to it, I can send a PR to your docs listing Agent Sessions as a companion tool.

## Directory and Listing Targets

Already-relevant awesome lists:
- https://github.com/hesreallyhim/awesome-claude-code
- https://github.com/Piebald-AI/awesome-gemini-cli
- https://github.com/milisp/awesome-codex-cli

Additional targets:
- macOS open-source app lists
- AI/devtool newsletters that accept short product submissions
- Developer tool directories that allow open-source macOS utilities
- Reddit manual workflow posts only; do not submit link drops

## “Awesome list” PR template

PR content:
- One-line description
- Screenshot (if list accepts)
- “Local-first” and “multi-agent” keywords
- Install links (DMG + Homebrew cask)

Suggested description:
“Agent Sessions is a local-first macOS app for searching, browsing, and resuming AI coding sessions across Codex, Claude Code, Cursor CLI, Gemini CLI, GitHub Copilot CLI, OpenCode, and OpenClaw.”

## Manual workflow post ideas

These are useful for Reddit, X/Twitter, newsletters, and devtool communities because they show a concrete workflow instead of asking for attention.

- “How I found an old Claude/Codex migration plan in 10 seconds”
- “A local-first way to search AI coding history across CLIs”
- “What Codex subagents actually did during a complex task”
- “Stop losing useful terminal agent transcripts”

## X/Twitter reply rule

X replies must be drafted for the real 280-character composer limit, not for a Markdown packet.

Hard rule:
- Every final X reply must be <= 280 effective characters before posting.
- Count each URL or bare domain as 23 characters, because X shortens links.
- Include `X effective length: N/280` in approval packets for every postable X draft.
- Approval packets must include affected tool, source evidence phrase, comparison tools, Agent Sessions support state, direct capability match, failure class, link destination, and screenshot decision.
- Prefer 250-270 effective characters when X will auto-add `Replying to @...` context or when a link card may appear.
- If the screenshot carries the proof, the text should get shorter, not longer.
- Drop the star-count footer before dropping the core claim. An honest, direct reply plus link is better than an over-limit promo footer.
- Until a new dedicated social banner exists, do not rely on the default Agent Sessions link card for X replies. Attach a relevant product screenshot when posting a linked reply.
- Verify the affected agent/tool from the source post before posting. Do not treat a comparison baseline as the affected product. Rendering/performance bugs and vendor regressions should stay hold/no-link unless the author asks for history/search/recovery tooling.
- Use GitHub links when the goal is stars/source review; use website links when the reader needs product context, screenshots, install path, or release notes.

Local helper:

```js
function xEffectiveLength(text) {
  return text.replace(/https?:\/\/\S+|(?:[a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}(?:\/\S*)?/g, "xxxxxxxxxxxxxxxxxxxxxxx").length
}
```

## Content strategy (repeatable, not exhausting)

Weekly cadence (example):
- One short clip (15–45 seconds): a workflow win
- One written note (500–900 words): a real problem solved

Do not post “updates”. Post “wins”.

## Metrics (how you know promotion works)

Because you avoid telemetry, you can still track:
- GitHub stars per week
- Release download counts per version
- Homebrew cask installs (if you have access to tap analytics)
- Issue volume and quality (feature requests vs. bug reports)

Set a weekly scoreboard and review it.
