---
name: deploy
description: Use when shipping a release of Agent Sessions — bumping version, updating CHANGELOG, building, signing, notarizing, publishing appcast, and creating a GitHub release.
---

# Deployment Skill (Agent Sessions)

This skill is an agent-facing entrypoint that avoids duplicating the deployment runbook.

## Canonical Sources (Single Source of Truth)

- Runbook: `docs/deployment.md`
- Unified tool: `tools/release/deploy` (see `tools/release/deploy --help`)
- Recommended pre-release QA checklist: `docs/release/pre-release-qa.md`

If anything here disagrees with the runbook, follow `docs/deployment.md`.

## Workspace Policy (Hard Rule)

- Always run deployment from the user's current local repository checkout.
- Do not clone to temporary directories and do not switch to alternate worktrees as a deployment workaround.
- If the local worktree is dirty, stop and tell the user to clean the tree first (commit, stash, or discard), then continue in the same local repo.

## Recommended QA Gate (Before Deploy Steps)

- Before bump/release/verify commands, recommend running `docs/release/pre-release-qa.md`.
- Ask for QA status explicitly:
  1. Was the checklist run for this candidate build?
  2. Result: `GO` or `NO-GO`?
  3. Any known risk accepted for release?
- If QA was not run, pause deployment execution and recommend running the checklist first.

## Before Starting (Ask the User)

1. Target version (`X.Y` for major/minor releases, `X.Y.Z` only for patch releases; never ship `X.Y.0`)
2. Any headline changes (new agents, major features) that must be reflected in `docs/CHANGELOG.md`
3. Whether this is a major release that requires onboarding updates
4. Public copy updates needed for README/GitHub Pages (major changes to highlight, renamed features, or outdated wording to fix)

## Public Copy Update (Required for All Releases)

### Always update (every release)
- `README.md` download link: `v{VERSION}/AgentSessions-{VERSION}.dmg` and label `Download Agent Sessions {VERSION} (DMG)`
- `README.md` Option A download link (second occurrence under Install section)
- `docs/index.html` download button URL and label
- `docs/index.html` `<meta name="description">` content (mention current version + key change)
- `docs/index.html` `<meta property="og:description">` content
- `docs/index.html` `<meta name="twitter:description">` content

### Update for minor/major or user-visible feature releases
- `README.md` "What's New in X.Y" section: update heading to new version, rewrite TL;DR and Highlights to reflect this release's key changes (do not keep old version's copy)
- `docs/index.html` hero/feature copy if features were renamed or new agents added

### Never add
- Versioned "What's New in X.Y" section to `docs/index.html`
- Detailed release notes to README or website (those live in `docs/CHANGELOG.md`)

### After pushing
- Verify GitHub Pages reflects updated `docs/index.html` (check meta description and download button)

## Pre-Deploy Checklist (Run Before Bump)

- [ ] `docs/CHANGELOG.md` `[Unreleased]` section has full, accurate content for this release
- [ ] `CHANGELOG.md` (root, if present) mirrors `docs/CHANGELOG.md` content
- [ ] README.md download links updated to new version (both occurrences)
- [ ] README.md "What's New" section updated to new version heading + rewritten highlights
- [ ] `docs/index.html` download button URL and label updated
- [ ] `docs/index.html` meta description, og:description, twitter:description updated with version + key change
- [ ] All above files committed before running `deploy bump` (or bump will overwrite)

## Sparkle Release Notes (Approval Gate)

- The release pipeline generates **structured Sparkle notes** from `docs/CHANGELOG.md`:
  - Highlights (current release)
  - Other changes (summary)
  - Reminder from the baseline release (for patch releases: `A.B`)
- During `tools/release/deploy release <VERSION>`, the deploy script prints a **Sparkle release notes preview** after build/sign/notarization and appcast validation.
- If `SKIP_CONFIRM` is not `1`, it will pause and ask for approval before publishing (pushing appcast, updating Homebrew, updating the GitHub release).
- If you want fully unattended deploys, set `SKIP_CONFIRM=1` (skips the notes prompt).
- If the current release has no structured bullets, the generator adds a fallback highlight: `Small bug fixes and stability improvements.`

## Standard Workflow (Use the Unified Tool)

```bash
tools/release/deploy changelog [FROM_TAG]
tools/release/deploy bump [patch|minor|major]
git push origin main
tools/release/deploy release <VERSION> [--dry-run]
tools/release/deploy verify <VERSION>
```

## Failure Handling

- First stop: `docs/deployment.md` → Troubleshooting, logs, and rollback guidance.
- Rollback only after reviewing logs: `tools/release/rollback-release.sh <VERSION>`.
