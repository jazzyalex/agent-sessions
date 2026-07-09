---
name: handover
description: Use when wrapping up or capturing the current state of a coding session — writes a dated, structured entry to the repo's RepoHandover.md so a future agent or you can resume without grepping archived sessions. Triggers on "handover", "hand off", "write handover", "capture state", "checkpoint this session".
---

# Handover

Append one dated, structured entry to `RepoHandover.md` at the repo root (newest-first),
capturing the session's state so it can be resumed later. Serves both a future agent
(actionable state) and the human (skimmable narrative). You draft it; the user approves;
you write it. **Never commit** — the user commits.

## Procedure

### 1. Gather ground truth from git (never infer facts from the conversation)
Run and read the output:
- `git rev-parse --abbrev-ref HEAD` — branch
- `git rev-parse --short HEAD` — commit hash
- `git status --porcelain` — dirty files (count + top dir for the branch line)
- `git log --oneline -5` — commits (identify which were made this session)
- `git diff --stat` — scope of uncommitted work

### 2. Extract entry content, in reliability order
- **Key files** ← files you actually touched via Edit/Write this session (NOT files merely
  mentioned). Format each inline as `path:line — why`.
- **Already decided / don't redo** ← user messages that rejected/corrected an approach,
  plus approaches you tried that failed. This is the highest-value section.
- **Verified** ← claims backed by a real tool result in this session (a git hash, test
  output, a sample). **Believed / unverified** ← everything else. Never promote a Believed
  claim to Verified without transcript evidence.
- **Next steps (prioritized)** ← the final todo/plan state, numbered. Items needing the
  human get a `DECIDE:` prefix.
- **Risks / landmines** ← risk → mitigation/stop-condition pairs.
- **How to verify** ← the build/test command that confirms the entry's claims (omit if N/A).

### 3. Reconcile git vs conversation
If the conversation says "committed" but the tree is dirty (or vice versa), flag the
discrepancy in the entry rather than picking one. **Git wins for facts; conversation wins
for intent.**

### 4. Draft within budget
Compose the entry using the exact format below. Hard budget: **~50 lines / ~600 words**.
Trim before showing. Omit any section that would be empty. The scope-slug is derived from
the branch name or the active plan/spec doc name — do not freestyle it (supersede-matching
depends on stable slugs).

Format (key block is exactly three lines: heading, `status:`, `branch:`):

    ## <YYYY-MM-DD> <HH:MM> · <scope-slug> · <title>
    status: <in-progress | blocked | done>
    branch: <branch> @ <short-hash> (dirty: <n> files[ in <dir>])

    **State in one line:** <one sentence>

    ### Already decided / don't redo
    - …

    ### Key files
    - `path:line` — …

    ### Verified
    - … (commit <hash> / test output)
    ### Believed / unverified
    - …

    ### Next steps (prioritized)
    1. …
    2. DECIDE: …

    ### Risks / landmines
    - <risk> — mitigation: <…>

    ### How to verify
    - <command>

Use the current date/time for the heading (ask the shell: `date +'%Y-%m-%d %H:%M'`).

### 5. Show the draft; default-accept on Enter
Present the drafted entry. Tell the user: press Enter to accept as-is, or reply with edits.
Apply any edits inline. Keep approval lightweight — heavyweight approval kills the habit.

### 6. Write (prepend, newest-first)
- If `RepoHandover.md` does not exist, create it with the new entry as the only content,
  AND append one line to the repo's `CLAUDE.md` (create a short one if absent):
  `> Before starting work, read the newest entry in \`RepoHandover.md\`.`
- If it exists, **prepend** the new entry above the current topmost entry (a blank line
  between entries). Do not touch older entries except in step 7.
- **Never run `git commit`.** Tell the user the file is written and theirs to commit.

### 7. Supersede check
Scan existing entries for one whose scope-slug matches the new entry's slug and whose
status is not already `superseded-by:`. If found, offer to change that older entry's
`status:` line to `status: superseded-by:<new-entry-date>` (a one-line edit; leave its
prose untouched). Only on user confirmation.

### 8. Self-check the format
Run the installed validator against the file and report the result:
`~/.claude/skills/handover/handover-lint.sh RepoHandover.md` (or the repo copy
`tools/handover/handover-lint.sh` when developing). It must exit 0. If it fails, fix the
key block and re-run.

## Notes
- Rotation: if `RepoHandover.md` exceeds ~1000 lines, offer (never silently) to move all
  but the newest ~10 entries to `RepoHandover-archive.md`.
- The Stop hook may *offer* a handover at session close; this skill is what actually runs.
