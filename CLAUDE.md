# CLAUDE Agent Notes

This repository uses a shared playbook for all agents (Claude, Codex, Xcode, Cursor, etc.).

Primary source of truth
- Read `agents.md` first for project‑wide policies, UX rules, and commit protocols.
- Treat `agents.md` as authoritative for UI design language (HIG‑aligned spacing, tokens, and behavior) and development workflow.

Key reminders for Claude Code contributions
- Follow Conventional Commits and include trailers (Tool, Model, Why when applicable).
- Do not auto‑commit. Only commit after explicit "commit".
- When touching UI, use the shared spacing tokens and HIG guidance defined in `agents.md`.
- If you add or rename Swift files, use `scripts/xcode_add_file.rb` to add them to the project (see `agents.md` → "Adding New Swift Files to Xcode Project").

If anything is unclear, open a short plan in chat and confirm before implementing.
