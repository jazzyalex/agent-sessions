# Git Worktree Guide

## ⚠️ CRITICAL: How Git Checkout Actually Works

### Your Question Answered

> "git checkout -b ui/analytics-prefs-tweaks in this claude tab will switch current claude cli to new branch - but will it impact another tab with codex running right now and also switch from main to a new branch? is checkout makes system wide branch change or just in current terminal?"

**Answer: YES, it WILL affect Codex. `git checkout` is REPOSITORY-WIDE, not terminal-specific.**

### What Actually Happens

When you run `git checkout -b ui/analytics-prefs-tweaks` in Claude's terminal:

```
BEFORE:
/Users/alexm/Repository/Codex-History/
├── .git/HEAD → refs/heads/main
├── AgentSessions/ (files from main branch)
└── docs/ (files from main branch)

Terminal 1 (Claude): → Sees main
Terminal 2 (Codex):  → Sees main  ✓ Both see the same thing

AFTER git checkout -b ui/analytics-prefs-tweaks:
/Users/alexm/Repository/Codex-History/
├── .git/HEAD → refs/heads/ui/analytics-prefs-tweaks  ← CHANGED FOR ENTIRE REPO
├── AgentSessions/ (files from new branch)
└── docs/ (files from new branch)

Terminal 1 (Claude): → Sees ui/analytics-prefs-tweaks
Terminal 2 (Codex):  → Sees ui/analytics-prefs-tweaks  ✗ SURPRISE! Branch changed
```

### Why This Happens

1. **Git branches are not terminal-specific**
   - The current branch is stored in `.git/HEAD` (a file)
   - ALL processes reading that file see the same branch

2. **Checkout changes files on disk**
   - `git checkout` updates the working directory
   - Every terminal/editor pointing to that directory sees the changes

3. **Terminals don't have "local branches"**
   - Your terminal prompt showing "main" is just cached text
   - Running `git status` in Codex's terminal would show the new branch

### The Danger

If you `git checkout` in Claude's terminal while Codex is working:

```bash
# Codex's terminal (before your checkout)
$ git status
On branch main
Your branch is up to date with 'origin/main'.
nothing to commit, working tree clean

# YOU run in Claude's terminal:
$ git checkout -b ui/analytics-prefs-tweaks
Switched to a new branch 'ui/analytics-prefs-tweaks'

# Codex makes changes and commits (thinks it's on main):
$ git add SomeFile.swift
$ git commit -m "feat: important change"

# BUT! Codex just committed to YOUR branch!
$ git log --oneline
abc1234 (HEAD -> ui/analytics-prefs-tweaks) feat: important change

# Your UI changes and Codex's changes are now mixed on the same branch!
```

**Result:** Merge disaster, lost work, confusion.

---

## ✅ My Recommendation for Your Situation

**Scenario:** You want to make minor UI tweaks while Codex works on complex changes in another terminal.

### Option 1: Use Worktree (SAFEST - Recommended)

**Pros:**
- Zero risk of interfering with Codex
- Both can work simultaneously
- Clean separation of concerns

**Cons:**
- Requires 2 minutes to set up
- Uses extra disk space (small - just source code)

**Setup:**
```bash
# 1. Create worktree for UI work (in Claude's terminal)
git worktree add ../Codex-History-ui -b ui/analytics-prefs-tweaks

# 2. Open UI worktree in new Claude Code window
code /Users/alexm/Repository/Codex-History-ui

# 3. Verify separation
git worktree list
# /Users/alexm/Repository/Codex-History         3b83559 [main]
# /Users/alexm/Repository/Codex-History-ui      abc1234 [ui/analytics-prefs-tweaks]
```

**Now:**
- Codex works in `/Users/alexm/Repository/Codex-History` (main) ← SAFE
- Claude works in `/Users/alexm/Repository/Codex-History-ui` (ui/analytics-prefs-tweaks)
- **Zero chance of conflict**

### Option 2: Coordinate Timing (Medium Risk)

**Only safe if Codex can pause work.**

```bash
# 1. Ask Codex to commit and push current work
# (Codex pushes to main)

# 2. Pull latest changes
git pull

# 3. Create UI branch
git checkout -b ui/analytics-prefs-tweaks

# 4. Make UI changes, commit
git add AgentSessions/Analytics/...
git commit -m "fix(ui): analytics tweaks"

# 5. Merge back to main
git checkout main
git merge ui/analytics-prefs-tweaks
git push

# 6. Tell Codex to pull latest main
# (Codex continues work)
```

**Risk:** If Codex commits while you're on the UI branch, chaos.

### Option 3: Simple Branch (HIGH RISK - Not Recommended)

```bash
# Just create branch without coordination
git checkout -b ui/analytics-prefs-tweaks

# DANGER: Codex's terminal is now on YOUR branch too!
```

**Don't do this unless Codex is completely idle.**

---

## What is Git Worktree?

Git worktree allows you to check out **multiple branches simultaneously** in separate directories, all linked to the same `.git` repository.

### Visual Comparison

**Traditional (One Working Directory):**
```
/Users/alexm/Repository/Codex-History/
├── .git/
└── (files from current branch) ← Only one branch at a time
```

**With Worktree (Multiple Working Directories):**
```
/Users/alexm/Repository/Codex-History/          ← Main worktree
├── .git/ ← Shared by all worktrees
└── (files from main)

/Users/alexm/Repository/Codex-History-ui/       ← Additional worktree
└── (files from ui/analytics-prefs-tweaks)

/Users/alexm/Repository/Codex-History-hotfix/   ← Another worktree
└── (files from hotfix/urgent-bug)
```

### Key Concept

- **One `.git` directory** (commits, branches, history)
- **Multiple working directories** (different branches checked out)
- Changes in one worktree don't affect others
- All worktrees see the same commits/branches

---

## When to Use Worktree

### ✅ Good Use Cases

**1. Parallel Development**
- You need to work on feature A and feature B simultaneously
- Switching branches disrupts your flow
- Examples: UI redesign + backend refactor

**2. Code Review**
- Checkout PR branch in worktree for review
- Keep main branch in primary worktree for reference
- No need to switch back and forth

**3. Testing Multiple Versions**
- Build/test different branches simultaneously
- Compare behavior side-by-side
- Examples: Performance testing old vs new implementation

**4. Hotfix Urgency**
- Working on long-running feature
- Urgent bug needs immediate fix on main
- Use worktree to fix without disrupting feature work

**5. Long-Running Experiments**
- Try risky refactor in worktree
- Keep stable main in primary worktree
- Easy to abandon experiment without affecting main

### ❌ Bad Use Cases (Use Branches Instead)

**1. Short-Term Features**
- Quick bug fix (30 minutes)
- Simple UI tweak (1 hour)
- **Why:** Overhead of worktree setup not worth it

**2. Sequential Work**
- Work on feature A, then feature B, then feature C
- No need for parallel branches
- **Why:** Simple `git checkout` is faster

**3. Learning Git**
- Still mastering basic branching/merging
- **Why:** Worktree adds complexity, master basics first

**4. Small Repos**
- Full checkout takes <1 second
- Switching branches is instant
- **Why:** No performance benefit from worktree

**5. Team Unfamiliar with Worktree**
- Other developers don't know worktree exists
- Risk of confusion in collaboration
- **Why:** Stick to simpler workflows everyone understands

---

## Complete Workflow: Your Exact Scenario

**Goal:** Make UI tweaks while Codex works on indexing refactor.

### Step 1: Setup Worktree (One-Time)

```bash
# Current state: You're in main worktree
cd /Users/alexm/Repository/Codex-History
git status
# On branch main

# Create worktree for UI work
git worktree add ../Codex-History-ui -b ui/analytics-prefs-tweaks

# Verify
git worktree list
# /Users/alexm/Repository/Codex-History         3b83559 [main]
# /Users/alexm/Repository/Codex-History-ui      3b83559 [ui/analytics-prefs-tweaks]
```

### Step 2: Open UI Worktree in Claude Code

```bash
# Open new window pointing to UI worktree
code /Users/alexm/Repository/Codex-History-ui

# Verify you're on correct branch
cd /Users/alexm/Repository/Codex-History-ui
git status
# On branch ui/analytics-prefs-tweaks
```

### Step 3: Work in Parallel

**In Claude's terminal (UI worktree):**
```bash
cd /Users/alexm/Repository/Codex-History-ui

# Make UI changes
edit AgentSessions/Analytics/Views/AnalyticsView.swift
edit AgentSessions/Views/PreferencesView.swift

# Commit frequently
git add AgentSessions/Analytics/Views/AnalyticsView.swift
git commit -m "fix(ui): adjust Analytics header spacing"

git add AgentSessions/Views/PreferencesView.swift
git commit -m "fix(ui): update Preferences layout"
```

**Meanwhile, in Codex's terminal (main worktree):**
```bash
cd /Users/alexm/Repository/Codex-History

# Codex works on indexing (completely independent)
edit AgentSessions/Indexing/DB.swift
git add AgentSessions/Indexing/DB.swift
git commit -m "feat(indexing): optimize rollup queries"

# No conflicts! Different directories, different branches
```

### Step 4: Sync When Ready

**When Codex finishes and pushes:**
```bash
# In main worktree (Codex is done)
cd /Users/alexm/Repository/Codex-History
git push
# Pushed indexing work to main

# In UI worktree, rebase on latest main
cd /Users/alexm/Repository/Codex-History-ui
git fetch origin main
git rebase origin/main
# Replays UI commits on top of latest main (including Codex's work)
```

### Step 5: Merge UI Changes

```bash
# Switch to main worktree
cd /Users/alexm/Repository/Codex-History

# Pull latest (includes Codex's work)
git pull

# Merge UI branch
git merge ui/analytics-prefs-tweaks
# Fast-forward or merge commit

# Push combined result
git push
```

### Step 6: Cleanup

```bash
# Remove UI worktree
git worktree remove ../Codex-History-ui

# Delete UI branch (optional)
git branch -d ui/analytics-prefs-tweaks

# Verify cleanup
git worktree list
# /Users/alexm/Repository/Codex-History  abc1234 [main]
```

---

## Basic Commands Reference

### Create Worktree

```bash
# Create new branch + worktree
git worktree add <path> -b <new-branch>

# Use existing branch
git worktree add <path> <existing-branch>

# Examples:
git worktree add ../project-ui -b ui/redesign
git worktree add ../project-hotfix hotfix/urgent-bug
git worktree add ~/Desktop/project-experiment -b experiment/new-feature
```

### List Worktrees

```bash
git worktree list

# Output:
# /Users/alexm/Repository/project        abc1234 [main]
# /Users/alexm/Repository/project-ui     def5678 [ui/redesign]
# /Users/alexm/Repository/project-hotfix 123abcd [hotfix/urgent-bug]
```

### Remove Worktree

```bash
# Method 1: Git command
git worktree remove <path>

# Method 2: Manual
rm -rf <path>
git worktree prune

# Examples:
git worktree remove ../project-ui
git worktree remove ~/Desktop/project-experiment
```

### Check Worktree Status

```bash
# In any worktree, see all worktrees
git worktree list

# Lock worktree (prevent accidental removal)
git worktree lock <path> --reason "Long-running work"

# Unlock
git worktree unlock <path>
```

---

## Advanced Usage

### Sparse Checkout (Large Repos)

Only check out specific directories:

```bash
# Create worktree without files
git worktree add --no-checkout ../project-ui ui/redesign

# Enter worktree
cd ../project-ui

# Configure sparse checkout
git sparse-checkout init
git sparse-checkout set AgentSessions/Analytics AgentSessions/Views

# Checkout files
git checkout ui/redesign
```

**Result:** Only Analytics and Views directories, not entire repo.

### Move Worktree

```bash
# Manually move directory
mv /Users/alexm/Repository/project-ui /Users/alexm/Desktop/project-ui

# Update Git's records
git worktree repair /Users/alexm/Desktop/project-ui

# Verify
git worktree list
# /Users/alexm/Desktop/project-ui  def5678 [ui/redesign]
```

### Lock Worktree

Prevent accidental removal:

```bash
# Lock with reason
git worktree lock ../project-important --reason "Active refactor, do not remove"

# Try to remove (fails)
git worktree remove ../project-important
# error: 'remove' refused: Active refactor, do not remove

# Unlock when safe to remove
git worktree unlock ../project-important
git worktree remove ../project-important
```

---

## Common Pitfalls & Solutions

### 1. Same Branch in Multiple Worktrees

**Problem:**
```bash
git worktree add ../project-feature feature-x
# error: 'feature-x' is already checked out at '/existing/path'
```

**Why:** Git prevents same branch in multiple worktrees (would cause conflicts).

**Solution:**
```bash
# Option A: Use different branch name
git worktree add ../project-feature-copy -b feature-x-copy feature-x

# Option B: Remove existing worktree first
git worktree remove /existing/path
git worktree add ../project-feature feature-x
```

### 2. Forgetting to Remove Worktrees

**Problem:** Disk fills with stale worktrees.

**Solution:**
```bash
# List all worktrees
git worktree list

# Remove unused ones
git worktree remove ../old-feature
git worktree remove ../abandoned-experiment

# Prune stale records
git worktree prune
```

### 3. Merge Conflicts

**Problem:** UI worktree and main both modified same file.

**Prevention:**
- Coordinate file ownership (UI files vs backend files)
- Rebase frequently: `git rebase origin/main`
- Small, focused changes in each worktree

**Resolution:**
```bash
# During merge
git merge ui/analytics-prefs-tweaks
# CONFLICT in AgentSessions/SomeFile.swift

# Fix conflicts in editor
# Then:
git add AgentSessions/SomeFile.swift
git merge --continue
```

### 4. Xcode Project File Conflicts

**Problem:** Both worktrees added new Swift files, `project.pbxproj` conflicts.

**Prevention:**
- Add files in only one worktree at a time
- Merge frequently

**Resolution:**
```bash
# Accept both changes manually in Xcode
# Or regenerate project file if using SwiftPM
```

### 5. Worktree Path Doesn't Exist

**Error:**
```bash
fatal: '/path/to/worktree' already exists
```

**Fix:**
```bash
# Directory exists but Git doesn't know about it
rm -rf /path/to/worktree
git worktree prune
git worktree add /path/to/worktree branch-name
```

---

## Comparison: Worktree vs Alternatives

| Strategy | Switching Cost | Disk Usage | Complexity | Best For |
|----------|---------------|------------|------------|----------|
| **Branches** | Medium (`git checkout`) | Low (1x repo) | Low | Sequential work |
| **Worktree** | None (separate dirs) | Medium (Nx repo) | Medium | Parallel work |
| **Stash** | Low (`git stash`) | Low (1x repo) | Low | Quick switches |
| **Clone** | None | High (Nx full clone) | High | Isolated testing |

### When to Use Each

**Branches:** (Default choice)
- Sequential feature development
- Short-term experiments
- Small repos (checkout is fast)

**Worktree:** (This guide)
- Long-running parallel features
- Frequent context switching
- Need to test/build multiple versions

**Stash:** (Temporary storage)
- Quick temporary switches
- Saving uncommitted work before checkout
- Trying something without committing

**Clone:** (Complete isolation)
- Need completely separate environment
- Testing destructive changes
- CI/CD builds

---

## Best Practices

### 1. Naming Convention

Use descriptive paths matching branch names:

```bash
# Good
git worktree add ../Codex-History-ui-tweaks -b ui/analytics-prefs
git worktree add ../Codex-History-indexing -b feat/sqlite-index
git worktree add ../Codex-History-hotfix-crash -b hotfix/startup-crash

# Bad (confusing)
git worktree add ../tmp -b wip
git worktree add ../test -b experiment
git worktree add ../foo -b bar
```

### 2. Directory Structure

Keep worktrees organized:

```bash
# Option A: Sibling directories
/Users/alexm/Repository/
├── Codex-History/              # Main worktree
├── Codex-History-ui/           # UI worktree
├── Codex-History-refactor/     # Refactor worktree
└── Codex-History-hotfix/       # Hotfix worktree

# Option B: Dedicated worktrees folder
/Users/alexm/Repository/
├── Codex-History/              # Main worktree
└── worktrees/
    ├── ui-tweaks/
    ├── refactor/
    └── hotfix/
```

### 3. Cleanup Regularly

Don't accumulate stale worktrees:

```bash
# Weekly cleanup
git worktree list
git worktree remove ../old-feature
git worktree prune

# Monthly audit
git worktree list | grep -v main
# Review each non-main worktree, remove if unused
```

### 4. Document Active Worktrees

For team projects, document in README:

```markdown
## Active Worktrees (Updated: 2025-10-22)

- `/Users/alexm/Repository/project-refactor` (feat/db-refactor)
  - Owner: Codex
  - ETA: 2025-10-30
  - Purpose: SQLite indexing refactor

- `/Users/alexm/Repository/project-ui` (ui/analytics-redesign)
  - Owner: Claude
  - ETA: 2025-10-25
  - Purpose: Analytics UI improvements
```

### 5. Commit Before Removing Worktree

Always commit or stash changes before removing:

```bash
# Check for uncommitted changes
cd /path/to/worktree
git status

# Commit or stash
git add .
git commit -m "WIP: save progress"

# Now safe to remove
cd ..
git worktree remove /path/to/worktree
```

---

## Troubleshooting

### Worktree Out of Sync

**Symptom:** Files in worktree don't match branch.

**Fix:**
```bash
cd /path/to/worktree
git status           # Check state
git fetch            # Update refs
git reset --hard HEAD  # Reset to latest commit
```

### Cannot Lock Ref

**Error:**
```
error: cannot lock ref 'refs/heads/branch-name'
```

**Cause:** Branch is checked out in another worktree.

**Fix:**
```bash
# Find which worktree has the branch
git worktree list

# Either:
# 1. Remove that worktree, or
# 2. Use a different branch name
git worktree add ../new-worktree -b different-branch-name
```

### Prune Doesn't Remove Worktree Record

**Symptom:** `git worktree list` shows deleted worktree.

**Fix:**
```bash
# Manually remove from Git's admin files
rm -rf .git/worktrees/<worktree-name>

# Or prune again
git worktree prune --verbose
```

---

## Summary: Do You Need Worktree?

### Use Worktree If:
- ✓ Working on multiple branches for extended periods (days/weeks)
- ✓ Frequently switching disrupts your flow
- ✓ Need to build/test multiple versions simultaneously
- ✓ Collaborating with someone else in same repo (like Codex in your case)

### Use Simple Branches If:
- ✓ Short-term feature work (hours)
- ✓ Sequential work on features
- ✓ Small repo (checkout is instant)
- ✓ Solo work with no parallel needs

### For Your Specific Situation:
**You want to make UI tweaks while Codex works on indexing refactor.**

**Recommendation: Use worktree.**

**Why:**
- Eliminates risk of interfering with Codex
- Clean separation of UI vs backend work
- Minimal setup cost (2 minutes)
- Zero coordination needed

**Commands:**
```bash
# One-time setup
git worktree add ../Codex-History-ui -b ui/analytics-prefs-tweaks

# Open in new window
code /Users/alexm/Repository/Codex-History-ui

# Work normally, merge when done
```

---

## Further Reading

- Official Git Documentation: `git help worktree`
- Git Worktree Tutorial: https://git-scm.com/docs/git-worktree
- Atlassian Worktree Guide: https://www.atlassian.com/git/tutorials/git-worktree

---

**Document Created:** 2025-10-22
**For Project:** AgentSessions (Codex History)
**Purpose:** Guide for safe parallel development using git worktree
