---
name: handover
description: Use when wrapping up or capturing the current state of a coding session — writes a short, dated entry to the repo's RepoHandover.md so a future agent or you can resume without grepping archived sessions. Triggers on "handover", "hand off", "write handover", "capture state", "checkpoint this session".
---

# Handover

Append a **short**, dated entry to `RepoHandover.md` at the repo root (newest-first)
capturing where things stand, so you or a future agent can resume. Keep it lean — a handful
of lines, **no git audit**. Draft it from what you already know in this session; the user
approves; you write. **Never commit.**

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

3. **Show the draft.** Press Enter to accept, or reply with edits. Keep approval light.

4. **Write (prepend, newest-first).**
   - New file → create `RepoHandover.md` with this entry, and add one line to the repo's
     `CLAUDE.md` (create a short one if absent):
     `> Before starting work, read the newest entry in \`RepoHandover.md\`.`
   - Existing file → **prepend** the entry above the current top entry (blank line between).
     Don't touch older entries except in step 5. **Never run `git commit`** — tell the user
     it's written and theirs to commit.

5. **Supersede (optional).** If an older entry has the same `slug` and isn't already
   superseded, offer to set its status line to `status: superseded-by:<new-entry-date>`
   (a one-line edit; leave its prose alone). Only on the user's confirmation.

## Notes
- **Lean by default.** State + key decisions + next steps. No git verification dump, no
  "Verified/Believed" ceremony, no risk matrix. If the user wants more detail, they'll ask.
- Rotation: if `RepoHandover.md` passes ~1000 lines, offer (never silently) to move all but
  the newest ~10 entries to `RepoHandover-archive.md`.
