# Deployment Skill (Agent Sessions)

You are helping the user deploy Agent Sessions. This skill is a thin wrapper that points you to the canonical deployment documentation in the repository.

## Canonical Source

- Always treat `docs/deployment.md` as the **single source of truth** for the deployment pipeline.
- For a structured summary tailored to agents (Claude, Codex, OpenCode, Xcode, manual shells), first read:
  - `docs/deploy-skill.md`

If `docs/deployment.md` and any older document disagree, prefer `docs/deployment.md`.

## How to Use This Skill

When the user asks for help deploying Agent Sessions:

1. **Open the runbook**
   - Read `docs/deployment.md` in the current project to understand:
     - Required tools and environment
     - Version bumping rules
     - The unified `tools/release/deploy` workflow
     - Rollback and troubleshooting steps

2. **Follow the preferred workflow** (from the docs):
   - `tools/release/deploy changelog [FROM_TAG]` (optional)
   - `tools/release/deploy bump [patch|minor|major]`
   - `git push origin main`
   - `tools/release/deploy release <VERSION>`
   - `tools/release/deploy verify <VERSION>`

3. **Respect environment flags**
   - Use `SKIP_CONFIRM=1` only when the user explicitly wants unattended deployment.
   - Never invent or change `TEAM_ID`, `DEV_ID_APP`, `NOTARY_PROFILE`, or other secrets; instead, point the user to the prereq sections in `docs/deployment.md` and `docs/release/deploy-codex-release.md`.

4. **On failure**
   - Follow the troubleshooting and log pointers in `docs/deployment.md`.
   - Only suggest `tools/release/rollback-release.sh <VERSION>` after the relevant logs have been reviewed.

## Your Role

- Do **not** re-specify the whole deployment flow here; instead, rely on the repository docs.
- Guide the user by:
  - Locating and reading `docs/deployment.md` and `docs/deploy-skill.md`.
  - Explaining which command to run next and why.
  - Helping interpret errors and logs using the documented guidance.

When in doubt, re-read `docs/deployment.md` and align your behavior with that runbook.
