# Handover skill

A **manual** `/handover` skill: writes a short, dated entry to a per-repo `RepoHandover.md`
(newest-first) so you or a future agent can resume without grepping archived sessions.
Design spec: `docs/superpowers/specs/2026-07-09-handover-skill-design.md` (note: the
mid-session auto-offer hook and the verbose git-heavy format described there were dropped —
see "History" below).

## Use
Type `/handover` (or say "write a handover"). It drafts a lean entry from the session — no
git audit — and **writes it immediately** (prepends to `RepoHandover.md`), no approval prompt:
you already opted in by running it, so it writes and reports one line, and you close/archive.
If an entry is ever wrong you just edit the file — it's short and uncommitted. It never commits.

Entries look like:

    ## 2026-07-09 16:20 · runway-auth · AS-owned OAuth
    status: in-progress

    **State:** no-CLI ladder shipped; AS-owned OAuth store is next.

    **Next:**
    1. Build the token store.

## Install
    bash tools/handover/install.sh
Installs `SKILL.md` + `handover-lint.sh` to `~/.claude/skills/handover/`. Manual-only —
it does **not** touch `settings.json` and installs no hook. Idempotent. Restart any open
session to pick up the skill (skills load at session start).

## Tests
    bash tools/test_handover_lint.sh      # format validator
    bash tools/test_handover_install.sh   # manual-only install

## History
- Dropped: a `Stop` hook that offered a handover every turn — it nagged. Handover is now
  purely your call via `/handover`.
- Dropped: the git-audit preamble and Verified/Believed/Risks/How-to-verify scaffold — too
  verbose and token-heavy. Entries are now state + decisions + next steps.
- Open: an optional "auto at true session close" path (`SessionEnd`) is possible but not yet
  built — `SessionEnd` can't run the model, so it would need a headless draft. TBD.
