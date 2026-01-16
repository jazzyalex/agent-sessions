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
- Keep detailed release notes in `docs/CHANGELOG.md` (README/GH Pages should stay concise).
- After pushing, verify GitHub Pages reflects the updated `docs/index.html`.

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
