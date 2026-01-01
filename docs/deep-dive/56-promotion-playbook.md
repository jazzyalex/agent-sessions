# Promotion Playbook (templates and checklists)

This is a practical playbook to promote Agent Sessions without guessing.

## Launch readiness checklist (before any big post)

Trust and legitimacy:
- [ ] Add a top-level `LICENSE`
- [ ] Add `SECURITY.md` with disclosure instructions
- [ ] Add a “Security and Privacy” section in README:
  - session locations read
  - what is executed (Terminal launch, probes)
  - local-only guarantees
- [ ] Remove obvious accidental artifacts from git (generated logs, local paths, DMGs in repo if not required)

Product clarity:
- [ ] One hero feature on top of README (Context Pack)
- [ ] 30–60 second demo video showing the hero loop
- [ ] “Works with” list is accurate and tested

## Show HN draft (structure)

Title ideas:
- “Show HN: Local-first browser for Codex/Claude sessions with context packs to resume work”
- “Show HN: Stop re-explaining your project to terminal coding agents (local session memory)”

Body template:

1) One-sentence problem
- “My agent sessions were scattered across tools, and I kept losing context when starting fresh.”

2) One-sentence solution
- “Agent Sessions is a local-first macOS app that indexes Codex/Claude/Gemini/Copilot/OpenCode logs and lets you search and export a Context Pack to continue work instantly.”

3) 3 bullets: what it does
- Unified search across agents
- Resume workflows (Terminal/iTerm)
- Usage limits radar

4) 2 bullets: what it does not do (trust)
- No telemetry / no uploads
- Read-only access to session files (explain exceptions clearly)

5) Links
- GitHub repo
- Release DMG
- Short demo video

6) Ask
- “If you use other agents and have session format samples, I’d love test fixtures.”

## Outreach templates (partner ecosystem)

### Maintainers of multi-session managers (Crystal, Claude Squad, CCManager)

Subject:
“Agent Sessions integration idea: worktree-aware session memory and context packs”

Body:
- I built Agent Sessions, a local-first session browser for Codex/Claude/Gemini/Copilot/OpenCode.
- Your tool owns running parallel sessions; mine is strong at browsing history across tools and exporting resume-ready context packs.
- I’d like to add a small integration so users can:
  - group sessions by worktree
  - export a Context Pack per worktree/task
- If you’re open to it, I can send a PR to your docs listing Agent Sessions as a companion tool.

## “Awesome list” PR template

When submitting to lists like:
- https://github.com/hesreallyhim/awesome-claude-code
- https://github.com/Piebald-AI/awesome-gemini-cli
- https://github.com/milisp/awesome-codex-cli

PR content:
- One-line description
- Screenshot (if list accepts)
- “Local-first” and “multi-agent” keywords
- Install links (DMG + Homebrew cask)

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

