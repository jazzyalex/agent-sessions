# Deployment Skill

You are helping the user deploy Agent Sessions. Follow this workflow step-by-step.

## Context

This project uses a unified deployment tool: `tools/release/deploy`
The tool handles: version bumping, building, signing, notarization, GitHub releases, Homebrew cask updates, and verification.

## Workflow Steps

### Step 1: Review Changes
First, show what has changed since the last release:

```bash
tools/release/deploy changelog
```

This will:
- Extract conventional commits (feat/fix/perf/refactor/docs)
- Show commit breakdown by category
- Display generated CHANGELOG entries

Ask the user: "Would you like to proceed with the deployment?"

### Step 2: Determine Version Bump
Ask: "What type of release is this?"
- **patch** - Bug fixes, small changes (2.7.1 → 2.7.2)
- **minor** - New features, non-breaking changes (2.7 → 2.8)
- **major** - Breaking changes (2.7 → 3.0)

**IMPORTANT**: Version format follows semantic versioning with a twist:
- Use `X.Y` for minor/major releases (e.g., 2.8, 3.0)
- Use `X.Y.Z` only for patch releases when Z is not zero (e.g., 2.8.1, 2.8.2)
- Never use `X.Y.0` - always omit the `.0`

Then run:
```bash
tools/release/deploy bump [patch|minor|major]
```

This will:
- Auto-increment build number
- Update project.pbxproj (MARKETING_VERSION and CURRENT_PROJECT_VERSION)
- Move CHANGELOG [Unreleased] → [VERSION]
- Create git commit
- Show diff for review

The script will prompt for confirmation before committing. If the user confirms, it will create the commit.

### Step 3: Push Version Bump
After the bump is committed, push to GitHub:

```bash
git push origin main
```

Wait for confirmation that push succeeded before proceeding.

### Step 4: Deploy Release
Now run the full deployment pipeline. First, ask the user to confirm the version number from Step 2.

Then run:
```bash
tools/release/deploy release VERSION
```

Replace VERSION with the actual version (e.g., 2.8 for minor, 2.8.1 for patch).

This will execute:
1. ✅ Comprehensive dependency validation
2. ✅ Enhanced pre-flight checks (git state, version validation)
3. ✅ Build and sign the app
4. ✅ Notarize with Apple
5. ✅ Create DMG
6. ✅ **Smoke test DMG** (mount, verify signature, check version)
7. ✅ Generate Sparkle appcast with EdDSA signatures
8. ✅ Create GitHub release with assets
9. ✅ Update Homebrew cask
10. ✅ **Automated verification**
11. ✅ **Auto-rollback prompt if verification fails**

**Expected duration**: 10-15 minutes (mostly notarization wait time)

The script will ask for confirmation before building unless `SKIP_CONFIRM=1` is set.

### Step 5: Verification
Verification runs automatically after deployment, but you can re-run manually:

```bash
tools/release/deploy verify VERSION
```

This checks:
- GitHub Release exists and has DMG + SHA256 assets
- DMG is downloadable and correct size
- Appcast has correct version and EdDSA signature
- README.md and docs/index.html have updated download links
- Homebrew cask updated to correct version
- SHA256 checksums match

If verification fails, the deployment script will prompt for automatic rollback.

### Step 6: Manual Verification (Optional)
After automated checks pass, suggest the user manually verify:

1. **Test download**: Visit the GitHub release page and download the DMG
2. **Test installation**: Mount DMG and verify app opens
3. **Test Sparkle update**: Open previous version and check for update prompt
4. **Test Homebrew**: Run `brew upgrade agent-sessions` (if installed via Homebrew)

### Emergency: Rollback
If something goes wrong, rollback is available:

```bash
tools/release/rollback-release.sh VERSION
```

This will:
- Delete GitHub Release and git tags
- Revert version-related commits
- Prompt for each destructive operation

## Important Notes

1. **Always read deployment.md first** if you haven't before starting
2. **Check that you have**:
   - Xcode installed with command-line tools
   - GitHub CLI (`gh`) authenticated
   - Apple notary profile configured
   - Sparkle EdDSA key in Keychain
3. **All operations are logged** to `/tmp/release-VERSION-timestamp.log`
4. **The deployment is idempotent** - safe to re-run if it fails partway
5. **Build number MUST increment** for Sparkle auto-updates to work

## If User Asks Questions

- **"How do I set up notary profile?"** → Check deployment.md section on Prerequisites
- **"What if build fails?"** → Check the log file in /tmp, address the issue, and re-run
- **"Can I test locally first?"** → Yes, but the script will build, sign, and notarize (can't skip those steps)
- **"What if I need to rollback?"** → Use `tools/release/rollback-release.sh VERSION`

## Environment Variables (Optional)

The user can set these to skip prompts:
- `SKIP_CONFIRM=1` - Skip confirmation prompts
- `TEAM_ID` - Apple Team ID
- `DEV_ID_APP` - Developer ID Application identity
- `NOTARY_PROFILE` - Notarytool keychain profile (default: AgentSessionsNotary)

Example:
```bash
SKIP_CONFIRM=1 tools/release/deploy release 2.8
```

## Your Role

1. Guide the user through each step sequentially
2. Wait for confirmation before proceeding to next step
3. Show the exact commands to run
4. Explain what each step does
5. If errors occur, help debug using the log files
6. Remain calm and methodical - deployment should be boring and predictable

Start by asking: "Are you ready to start the deployment process? I'll guide you through each step."
