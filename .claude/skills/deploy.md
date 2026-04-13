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

- Always run deployment from the user’s current local repository checkout.
- Do not clone to temporary directories and do not switch to alternate worktrees as a deployment workaround.
- If the local worktree is dirty, stop and tell the user to clean the tree first (commit, stash, or discard), then continue in the same local repo.

## QA Gate (Mandatory — Run Automatically Before Deploy)

- **Always run QA automatically** before any bump/release/verify step, unless the user explicitly says to skip it (e.g. "skip QA", "no QA").
- Do not ask whether to run QA — just run it.
- QA execution order:
  1. **Scope** — `git log --oneline --decorate -n 30` and `git diff --name-only <LAST_TAG>..HEAD`; identify high-risk areas.
  2. **Build** — `xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug build`
  3. **Full test suite** — `./scripts/xcode_test_stable.sh`
  4. **Targeted tests** — run suites for touched high-risk areas (session parsing, usage tracking, onboarding, etc.)
  5. **Warnings sweep** — flag any new actionable warnings in build output.
  6. **Manual smoke reminder** — list the manual steps from `docs/release/pre-release-qa.md` §2–3 and ask the user to confirm GO/NO-GO after completing them.
- If automated gates fail → stop, report failure, do not proceed to bump/release.
- If user says "skip QA" or "no QA" → proceed without running, note it was skipped.

## Before Starting (Ask the User)

1. Target version (`X.Y` for major/minor releases, `X.Y.Z` only for patch releases; never ship `X.Y.0`)
2. Any headline changes (new agents, major features) that must be reflected in `docs/CHANGELOG.md`
3. Whether this is a major release that requires onboarding updates
4. Public copy updates needed for README/GitHub Pages (major changes to highlight, renamed features, or outdated wording to fix)

**Do NOT ask about QA status** — QA always runs automatically as part of pre-deploy (see QA Gate above).

## Public Copy Update (Required for Releases)

- Update `README.md` with a short **TL;DR** and major highlights under “What’s New in X.Y”.
- Ensure README feature copy matches current naming (for example, **Session view** instead of Color view) and agent list.
- Update `docs/index.html` feature/hero copy to reflect major changes and avoid outdated references.
- Do not add a versioned `What's New in X.Y` section to `docs/index.html` (GitHub Pages main page).
- Keep detailed release notes in `docs/CHANGELOG.md` (README/GH Pages should stay concise).
- For major feature/UI releases, update README/index narrative copy (not just the download link/version).
- After pushing, verify GitHub Pages reflects the updated `docs/index.html`.

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
