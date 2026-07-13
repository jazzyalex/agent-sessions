---
name: handover
description: Use when wrapping up or capturing the current state of a coding session — writes a short, dated entry to the repo's RepoHandover.md so a future agent or you can resume without grepping archived sessions. Triggers on "handover", "hand off", "write handover", "capture state", "checkpoint this session".
---

# Handover

Append a **short**, dated entry to `RepoHandover.md` at the repo root (newest-first)
capturing where things stand, so you or a future agent can resume. Keep it lean — a handful
of lines, **no git audit**. The user already opted in by running `/handover`, so **draft and
write it directly — do NOT ask for approval or show a draft to confirm.** Just write, report
one line, and stop. **Never commit.**

## Procedure

1. **Draft from the conversation — do NOT run a git audit.** You already know what happened
   this session. At most, run a single `git branch --show-current` if you want the branch in
   the header. Do not run `git status`/`log`/`diff` sweeps — that's the verbosity we removed.

2. **Compose a short entry** in this format. Omit any line/section that would be empty.
   Aim for ~8–15 lines total:

        ## <YYYY-MM-DD HH:MM> · <slug> · <title>
        status: in-progress            # in-progress | blocked | done

        **State:** <one sentence — where things stand right now>

        **Decided / don't redo:**      <only if there is something>
        - <a decision made, or a dead-end already tried>

        **Key files:**                 <only if it helps resume>
        - `path` — <why it matters>

        **Next:**
        1. <the next concrete step>
        2. <...>

   - `slug` = the branch or plan/spec name (keep it stable — supersede-matching uses it).
   - Timestamp: `date +'%Y-%m-%d %H:%M'`.

3. **Write it immediately — no approval prompt.**
   - New file → create `RepoHandover.md` with this entry as its only content.
   - Existing file → **prepend** the entry above the current top entry (blank line between).
     Don't touch older entries except the silent supersede below.
   - Ensure the repo's `CLAUDE.md` contains this pointer (add it once, creating a short
     `CLAUDE.md` if absent):

            > Before starting work, read the newest entry in `RepoHandover.md`.

   - **Silent supersede:** if an older entry has the same `slug` and its status isn't already
     `done` or `superseded-by:`, change that older entry's status line to
     `status: superseded-by:<new-entry-date>` (one-line edit; leave its prose alone). No prompt.
   - **Never run `git commit`.**

4. **Report one line and stop.** e.g. `Wrote handover to RepoHandover.md (superseded the
   previous runway-auth entry). Not committed.` Do not ask follow-up questions — the user is
   about to close/archive the session.

## Notes
- **Lean by default.** State + key decisions + next steps. No git verification dump, no
  "Verified/Believed" ceremony, no risk matrix.
- If the drafted entry is wrong, the user edits the file directly — it's short and uncommitted,
  so a bad entry is cheap. That's why no approval gate is needed.
- Sanity-check (optional, cheap): `handover-lint.sh RepoHandover.md` — installed next to this
  skill — exits 0 when the newest entry's heading + `status:` line are well-formed.
- Rotation: if `RepoHandover.md` passes ~1000 lines, offer (never silently) to move all but
  the newest ~10 entries to `RepoHandover-archive.md`.
