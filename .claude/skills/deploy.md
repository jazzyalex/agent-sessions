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
   - **Update README.md and docs/index.html** with new version and features
   - `git push origin main`
   - `tools/release/deploy release <VERSION>`
   - `tools/release/deploy verify <VERSION>`

3. **Respect environment flags**
   - Use `SKIP_CONFIRM=1` only when the user explicitly wants unattended deployment.
   - Never invent or change `TEAM_ID`, `DEV_ID_APP`, `NOTARY_PROFILE`, or other secrets; instead, point the user to the prereq sections in `docs/deployment.md` and `docs/release/deploy-codex-release.md`.

4. **On failure**
   - Follow the troubleshooting and log pointers in `docs/deployment.md`.
   - Only suggest `tools/release/rollback-release.sh <VERSION>` after the relevant logs have been reviewed.

## Writing Clean Release Notes

**CRITICAL**: Release notes are user-facing. Focus on what's NEW, not implementation details.

### Bad Examples (Too Verbose)
❌ "Fixed onboarding slide 2 layout"
❌ "Refined the agents tour step with centered layout"
❌ "Resolved Swift 6 actor isolation for onboarding"

**Why bad?** These are implementation details from developing the Onboarding feature. Users don't care about individual bug fixes during development.

### Good Examples (Concise, User-Focused)
✅ "Onboarding Tours: Interactive onboarding for new installs"
✅ "Copilot CLI Support: Full session browser integration"
✅ "Saved Sessions: Archive backfill and reveal actions now work reliably"

### Guidelines

1. **New Features**: One line per feature. What does it do for the user?
2. **Improvements**: Only list changes to existing features users will notice.
3. **Fixed**: Only bugs users experienced in previous releases, NOT bugs introduced and fixed during development of new features.
4. **Avoid**:
   - Internal refactoring details
   - Multiple items about the same feature (consolidate!)
   - Implementation specifics (Swift 6, actor isolation, etc.)
   - Fixes to code you just wrote in this release

### Version Numbering

**IMPORTANT**: Use version format `X.Y` (e.g., "2.9"), NOT `X.Y.0` (e.g., "2.9.0").
- Marketing version should never end in `.0`
- The deploy script handles version bumping, but verify it uses the correct format
- CHANGELOG sections should be `## [2.9]` not `## [2.9.0]`

### Update README.md and Website

**REQUIRED**: After preparing release notes, update user-facing documentation:

1. **README.md**:
   - Update download link version (search for `v2.X` and `AgentSessions-2.X.dmg`)
   - Add "What's New in X.Y" section at the top with key features from release notes
   - Update agent list in overview if new agents added
   - Keep concise - 3-5 key features, not exhaustive list

2. **docs/index.html**:
   - Update download button version and link
   - Update meta descriptions to mention new features
   - Update hero text if agent support changed
   - Update feature cards if major features added
   - Keep aligned with README messaging

3. **Commit these updates** before pushing and deploying so website is in sync with release

## Your Role

- Do **not** re-specify the whole deployment flow here; instead, rely on the repository docs.
- Guide the user by:
  - Locating and reading `docs/deployment.md` and `docs/deploy-skill.md`.
  - Explaining which command to run next and why.
  - Helping interpret errors and logs using the documented guidance.
  - Writing clean, user-focused release notes following the guidelines above.

When in doubt, re-read `docs/deployment.md` and align your behavior with that runbook.
