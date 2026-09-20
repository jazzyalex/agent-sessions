---
name: deploy-agent-sessions
description: Release/deploy workflow for Agent Sessions (Sparkle appcast + GitHub release). Use when asked to "deploy", "ship", "publish", or "prepare a production release" for this repo. Follows the repo’s canonical deploy skill at `.claude/skills/deploy.md` and the runbook at `docs/deployment.md`.
---

# Agent Sessions Deploy

## Canonical sources

When working in the Agent Sessions repo, treat these as the single source of truth:

- `.claude/skills/deploy.md`
- `docs/deployment.md`
- Unified tool: `tools/release/deploy` (start with `tools/release/deploy --help`)

If this skill conflicts with any of the above, follow the repo docs.

## Workspace policy (mandatory)

- Always deploy from the user’s current local repository checkout.
- Do not create temporary clones or alternate worktrees to work around a dirty tree.
- If the local worktree is dirty, stop and advise the user to clean it first (commit, stash, or discard), then continue in the same local repo.

## Default workflow (command sequence)

Use the unified deploy tool, following `.claude/skills/deploy.md`:

```bash
tools/release/deploy changelog [FROM_TAG]
tools/release/deploy qa --version <VERSION>
tools/release/deploy bump [patch|minor|major]
git push origin main
tools/release/deploy qa --version <VERSION>
tools/release/deploy release <VERSION> [--dry-run]
tools/release/deploy verify <VERSION>
```

## Before running `release`

- Confirm target version string (`X.Y` for major/minor releases, `X.Y.Z` only for patch releases) and whether this is a patch/minor/major bump. Never ship `X.Y.0`.
- Ensure user-visible notes are updated (per `.claude/skills/deploy.md`): `docs/CHANGELOG.md`, monthly summary in `docs/summaries/YYYY-MM.md`, and any required public copy updates.
- Run `tools/release/deploy qa --version <VERSION>` on the exact release commit. QA requires a clean `main` checkout synced with `origin/main`; `tools/release/deploy release` and `tools/release/deploy resume` require its fresh QA stamp unless `--skip-qa`/`SKIP_QA=1` is explicit.
- The QA gate is CI-parity: it verifies the pinned Xcode toolchain, runs the docs guards and localization catalog validation, runs a no-signing Debug build in `.deriveddata-localization`, and runs localization extraction-drift validation before writing the QA stamp. A green XCTest run alone is not release-ready.
- If user-facing SwiftUI copy changed, update `AgentSessions/Resources/Localizable.xcstrings` in the same change. Keep intentional raw paths, commands, and identifiers as `Text(verbatim:)`; add validator verbatim exceptions only after review.
- `tools/release/deploy bump` requires the target-version QA stamp before changing release metadata; after pushing the bump commit, rerun exact-commit QA before release. Never use the manual fallback to bypass a failed QA/extraction gate.
- Local QA must match `tools/release/ci-xcode-version.txt`; CI selects that toolchain on the pinned `macos-26` image.
- Expect Release builds to spend several minutes in `swift-frontend` during whole-module optimization; the build helper now prints heartbeats. If interrupted after the notarized DMG is built, prefer `tools/release/deploy resume`, which validates the saved git `HEAD` before continuing.
