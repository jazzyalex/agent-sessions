# Modern Vibe Coding Workflow Blueprint (and how Agent Sessions can serve it)

This is a product design plan grounded in what’s working in the ecosystem and what experienced developers complain about.

## First principles: what “vibe coding” actually changes

Two shifts matter:

1) Execution is cheaper than judgment
- Writing code is no longer the bottleneck; deciding what to build, what to accept, and what to discard is.
- This is why “diff review” and “quality gates” are central in tools like Crystal and Claude Squad.

2) Context is the new currency
- If you lose context, you lose speed.
- If your context is bloated, you lose quality and control.
- This is why memory services (MCP memory) and task systems (cc-sessions) are taking off.

## What experienced devs are reacting to (signals, not opinions)

### “The smell of vibe coding” is real
Alex Kondov’s post (“I Know When You’re Vibe Coding”) describes the real failure mode:
- code may work and be “clean”, but violates established project conventions
- reimplements libraries already in the repo
- changes global config instead of local patterns

Source: https://alexkondov.com/i-know-when-youre-vibe-coding/

### Typed languages make AI refactors safer
One widely shared claim: compile-time guarantees plus agents that run compilers/tests allow large diffs with lower fear.
Source: https://solmaz.io/typed-languages-are-better-suited-for-vibecoding

Interpretation for Agent Sessions:
- the product should surface “evidence of safety” (tests run, builds run, failures)
- and help users carry conventions forward (project DNA)

## The modern vibe loop (a practical model)

You can think of “vibe coding” as a loop with artifacts:

1) Capture intent
- task goal
- constraints
- “definition of done”

2) Assemble context (just enough)
- relevant files
- current state
- conventions
- recent decisions

3) Execute (agent runs)
- with visible costs (tokens/time)
- with guardrails (plan, then write; tests)

4) Review (human judgment)
- diff review
- failure review (what did not work and why)

5) Ship (merge/release)
- create a durable artifact

6) Preserve memory for next time
- summary
- decisions
- next steps
- links to diffs/PRs

Agent Sessions is naturally positioned to own steps 2, 4, and 6.

## Agent Sessions: pick a 10/10 product identity

You have two viable identities; pick one and orient everything around it.

### Identity A (recommended): “Local-first memory and limits radar for terminal agents”
- Best at: history, search, resume context, usage limits, git context at session time
- Competes with: lightweight viewers/exporters
- Integrates with: Crystal/Claude Squad/cc-sessions/memory services

### Identity B (risky): “Desktop multi-session manager”
- Best at: running parallel sessions, worktrees, diff, merge, scripts
- Competes directly with: Crystal, Claude Squad, CCManager, claudecodeui
- Requires: a much larger scope, plus higher security risk profile

If the goal is 10/10 execution with a small team, Identity A wins.

## Painkillers (not vitamins): the features that change daily behavior

These are the features that make someone open Agent Sessions every day.

### 1) Context Pack export (the hero feature)

Problem:
- “I’m starting a new session and need the last 2–4 hours of context without rereading 1,000 messages.”

What it is:
- A one-click export that produces a tight, pasteable Markdown block:
  - goal
  - current state
  - decisions made (with rationale)
  - commands/tools used (important ones)
  - files changed (if detectable)
  - repo/branch/commit context
  - next steps

Why it wins:
- It directly attacks “stop re-explaining” without requiring embeddings/cloud.
- It makes your product useful even if the user never “resumes” via CLI.

Compatibility:
- Works for Codex, Claude, Gemini, Copilot, OpenCode, Droid by staying at the text/decision layer.

### 2) Project Memory (conventions and decisions)

Problem:
- vibe coding fails when the model violates conventions.

What it is:
- A per-repo memory panel that stores:
  - “project DNA” (frameworks, patterns, house style)
  - known pitfalls
  - “do not do” rules
  - build/test commands
  - links to key docs and decisions

How to fill it:
- Manual notes plus “extract from sessions” suggestions.
- Optional import from existing artifacts: `AGENTS.md`, `CLAUDE.md`, cc-sessions task files.

### 3) Keyboard-first Command Palette

Problem:
- vibe coders live on keyboard shortcuts and hate UI hunting.

What it is:
- A single palette (like “command-K”) that can:
  - switch agent/source filters
  - open session by fuzzy search
  - jump between user prompts/tool calls/errors
  - export context pack
  - open git context inspector (if enabled)

### 4) Quality signals extracted from logs

Problem:
- trust is low when you cannot tell what safety checks happened.

What it is:
- A per-session “Quality” summary:
  - compilers/tests run (detected from tool output and commands)
  - failures and error bursts
  - warnings (where parsable)
  - “session ended while failing” indicator

This turns raw transcripts into actionable confidence.

### 5) Workstreams view (worktree/branch-centric grouping)

Problem:
- modern workflows are multi-branch and multi-session.

What it is:
- Group sessions by repo and by inferred branch/worktree path.
- Make it easy to see “what else is happening on this codebase”.

This is how you integrate with Crystal/Claude Squad without becoming them.

## Ecosystem integrations (high-leverage partnerships)

You should treat these projects as your distribution channels.

### Crystal / Claude Squad / CCManager
Integration goal:
- detect worktrees and sessions per workspace
- export context pack per worktree
- deep link from Agent Sessions to open the worktree in terminal/editor

### cc-sessions / claude-sessions
Integration goal:
- ingest their task/session markdown artifacts
- show “task status” next to sessions
- enable “continue task” via context pack export + resume

### MCP memory service
Integration goal:
- do not compete initially
- offer “export to memory” or “import memory snapshot”
- optionally become a UI for browsing what memory was injected

## What to avoid (common traps)

- Do not build a full remote IDE unless you want the security and scope burden (claudecodeui already exists).
- Do not add cloud sync as a default growth lever; it changes your trust model.
- Do not become a “feature museum”: a user should learn the core loop in 2 minutes.

## If you ship only one thing next: ship Context Pack

If you want the shortest path to “people recommend this tool”:
- build Context Pack export
- make it sharable and safe by default (redaction mode)
- market it as “stop re-explaining your project to your agent”

## Appendix: Context Pack MVP spec (concrete output format)

The goal is that a user can paste this into a new agent session and continue immediately.

### Context Pack sections (recommended)

1) Header
- project/repo (best-effort)
- session source (Codex/Claude/etc.)
- timestamps (start/end)
- branch/worktree (if known)

2) Goal (one paragraph)
- what we are trying to achieve
- what “done” means

3) Current state (bullet list)
- what is implemented
- what is verified (tests/builds that passed)
- what is still broken

4) Decisions and rationale (bullets)
- decision: X
- why: Y
- tradeoff: Z

5) Commands and tools used (curated)
- include the commands that changed state (migrations, builds, deploys)
- exclude noisy commands unless they matter

6) Files/areas touched (best-effort)
- if git context is available, summarize changes
- otherwise infer from tool output and working directory

7) Next steps (ordered checklist)
- the next 3–7 actions a human/agent should take

8) Guardrails (project DNA snippet)
- “use existing library X”
- “do not introduce new framework Y”
- “run command Z before committing”

### “Share-safe” mode

Default export should support a safe mode that:
- redacts absolute paths
- redacts obvious secrets (tokens, API keys, long hex) with conservative heuristics
- optionally replaces repo name with a placeholder

This is a distribution feature as much as a privacy feature.

