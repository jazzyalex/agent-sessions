# Deployment Skill (Agent Sessions)

This skill is an agent-facing entrypoint that avoids duplicating the deployment runbook.

## Canonical Sources (Single Source of Truth)

- Runbook: `docs/deployment.md`
- Unified tool: `tools/release/deploy` (see `tools/release/deploy --help`)

If anything here disagrees with the runbook, follow `docs/deployment.md`.

## Before Starting (Ask the User)

1. Target version (prefer `X.Y` or `X.Y.Z`, avoid trailing `.0` unless the repo uses it for that release)
2. Any headline changes (new agents, major features) that must be reflected in `docs/CHANGELOG.md`
3. Whether this is a major release that requires onboarding updates
4. Public copy updates needed for README/GitHub Pages (major changes to highlight, renamed features, or outdated wording to fix)

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
