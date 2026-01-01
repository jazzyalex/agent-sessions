# Ballast Audit (what to cut, hide, or de-scope)

Ballast is anything that:
- increases maintenance cost disproportionately
- confuses the “first 2 minutes” user experience
- creates security/trust anxiety without a clear payoff
- bloats the repository and blocks contributors

This is not about removing “cool features”. It is about making the core loop unstoppable.

## Step 1: Define the core loop you refuse to compromise

Core loop (recommended):
1) Find the session you need (fast)
2) Understand what happened (readable transcript + highlights)
3) Re-use or resume the work (context pack, resume, copy)

Anything not supporting this loop is either:
- secondary (advanced)
- optional (plugin)
- or ballast (remove)

## Step 2: Repo ballast (contributor friction)

These are tracked in git and should be treated as debt:

1) Large binary artifacts committed to the repo
- Example: `docs/AgentSessions-2.9.1.dmg` is tracked (~8.9 MB).
- The repo also contains many large PNGs and some large “probe scan output” text files.

Why this is ballast:
- Slows cloning and indexing
- Makes contributors suspicious (“why is a DMG committed?”)
- Encourages “repo as storage” instead of “releases as storage”

Suggestion:
- Keep screenshots that are truly required for README/website.
- Move DMGs and generated scan outputs out of git and into releases or a separate artifacts repo.

Privacy note:
- At least one tracked scan output file in `scripts/probe_scan_output/` contains absolute user paths from a local machine. Treat these files as sensitive and do not keep them in the public repo.

2) Multiple tracked pbxproj backup variants
- Example files in `AgentSessions.xcodeproj/`: `project.pbxproj.bak2`, `project.pbxproj.bak3`, `project.pbxproj.backup2`, etc.

Why this is ballast:
- Signals “manual project editing happened and may be fragile”
- Increases merge conflicts for contributors

Suggestion:
- Keep one authoritative `project.pbxproj` in git.
- Store backups outside git, or generate them via a script if needed.

## Step 3: Product ballast (UX and narrative confusion)

### Candidate: too many “big” features presented as equal
You have multiple major windows/features (sessions, analytics, git inspector, saved sessions, onboarding, usage tracking).
That’s fine for power users, but dangerous for onboarding and marketing:
- new users need one reason to care, not five

Recommendation:
- Pick one hero feature (Context Pack) and orient the UI around it.
- Keep advanced views, but reduce their prominence for first-time users.

### Candidate: features that require trust but aren’t explained
Examples:
- non-sandboxed app model (`AgentSessions/AgentSessions.entitlements`)
- subprocess usage (shell, osascript, tmux scripts)

This is not “ballast” if it’s core to the product, but it becomes ballast if it is:
- surprising
- undocumented
- perceived as unsafe

Recommendation:
- If you cannot explain a feature in 2 sentences inside the app, hide it behind an “Advanced” toggle until you can.

### Candidate: embedded resume execution
Evidence:
- embedded resume uses `bash -lc <string>` (`AgentSessions/Resume/CodexResumeLauncher.swift`).

Risk:
- “stringly-typed shell command” is a red flag for security-minded users.

If it is rarely used, it is a strong candidate to:
- disable by default
- or remove and rely on launching in Terminal/iTerm only

## Step 4: Technical ballast (maintenance tax)

The biggest technical ballast is duplication:
- per-agent indexers with copied throttlers and filter pipelines
- search coordinator coupled to concrete indexers

This is not glamorous to fix, but it is the highest ROI “engineering for speed” move you can make.

## A practical approach: “Advanced mode” and “editions”

If you do not want to delete features, you can still remove ballast by:

1) Advanced mode toggle
- Default experience: sessions + transcript + context pack + resume
- Advanced: analytics, git inspector, probes, saved sessions management

2) Editions (optional, business-driven)
- “Free (OSS)” edition: viewer + context pack + basic resume
- “Pro” edition: analytics, git inspector, advanced filters, extra exports

Do not do editions until you have a license and a stable distribution story.

## What I would cut first (if forced)

If you forced me to reduce scope to hit growth and quality faster:

- Cut/relocate: tracked DMGs and generated scan output files in git (repo hygiene)
- Hide by default: complex analytics UI and advanced probes until trust/docs are excellent
- Consider removing: embedded resume console if it is not a daily driver for users

Keep:
- cross-agent history
- fast search
- readable transcripts
- context pack export
- basic resume workflows
