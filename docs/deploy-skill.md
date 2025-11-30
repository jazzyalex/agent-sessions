# Agent Sessions Deploy Skill (Claude, Codex, OpenCode)

This skill file describes how agents (Claude, Codex, OpenCode, Xcode, manual shells) should reason about deployments for this repository.

## Canonical Source of Truth

- Always treat `docs/deployment.md` as the **single source of truth** for the deployment pipeline.
- Do **not** reinvent or bypass that runbook; read it to understand:
  - Required tools and environment
  - Version bumping rules
  - The unified `tools/release/deploy` workflow
  - Rollback and troubleshooting procedures

If `docs/deployment.md` and any other document disagree, prefer `docs/deployment.md`.

## Preferred Commands

For standard releases, agents should prefer the unified wrapper:

```bash
# 1. (Optional) See what changed since last release
tools/release/deploy changelog [FROM_TAG]

# 2. Bump version (major|minor|patch)
tools/release/deploy bump patch

# 3. Push the bump commit
git push origin main

# 4. Deploy the release
tools/release/deploy release <VERSION>

# 5. Verify the deployment
tools/release/deploy verify <VERSION>
```

- Use `SKIP_CONFIRM=1` when automation must run unattended.
- Only fall back to `tools/release/deploy-agent-sessions.sh` or `tools/release/build_sign_notarize_release.sh` for advanced debugging, as explained in `docs/deployment.md`.

## Environment & Secrets

- Environment variables (`TEAM_ID`, `DEV_ID_APP`, `NOTARY_PROFILE`, `SKIP_CONFIRM`, `NOTARIZE_SYNC`, `UPDATE_CASK`, etc.) are documented in `docs/deployment.md`.
- Never hard-code secrets or Apple IDs in code or committed config. Point the user to the Keychain and `tools/release/.env` guidance in:
  - `docs/deployment.md`
  - `docs/release/deploy-codex-release.md` (prereqs and local defaults only)

## Failure Handling

When any deployment step fails, agents should:

1. Consult the troubleshooting and log pointers in `docs/deployment.md`.
2. Only suggest `tools/release/rollback-release.sh <VERSION>` after the relevant logs have been inspected.
3. Avoid editing release scripts unless explicitly asked; instead, guide the user using the documented commands.

