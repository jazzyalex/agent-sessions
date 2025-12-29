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
