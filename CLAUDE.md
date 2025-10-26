# CLAUDE Agent Notes

This repository uses a shared playbook for all agents (Claude, Codex, Xcode, Cursor, etc.).

Primary source of truth
- Read `agents.md` first for project‑wide policies, UX rules, and commit protocols.
- Treat `agents.md` as authoritative for UI design language (HIG‑aligned spacing, tokens, and behavior) and development workflow.

Key reminders for Claude Code contributions
- Follow Conventional Commits and include trailers (Tool, Model, Why when applicable).
- **NEVER commit or push without explicit user request.** Only run `git commit` or `git push` when user says "commit" or "push".
- You may advise the user to commit/push, but do not execute these commands proactively.
- **Commit message format:** Use clean conventional commits WITHOUT "Generated with Claude Code" footer or "Co-Authored-By: Claude" trailer. Only include Tool/Model/Why trailers.
- **Git authorship:** All commits MUST be authored by the repository owner only. Never add Claude as a co-author.
- When touching UI, use the shared spacing tokens and HIG guidance defined in `agents.md`.
- If you add or rename Swift files, use `scripts/xcode_add_file.rb` to add them to the project (see `agents.md` → "Adding New Swift Files to Xcode Project").

If anything is unclear, open a short plan in chat and confirm before implementing.
