# Agent Sessions Deployment Runbook

This runbook provides a fully automated deployment process with upfront validation.
All questions are answered before running the script, which then executes non-interactively.

## Pre-flight Checklist

Complete this checklist **before** running the deployment script. Answer all questions and verify all conditions.

### 1. Version Planning
- [ ] What version are you releasing? (e.g., 2.2)
- [ ] Current MARKETING_VERSION in project.pbxproj: _________
- [ ] Confirm version bump is correct (major/minor/patch)

### 2. Asset Preparation
- [ ] Screenshots updated (if UI changed):
  - `docs/assets/screenshot-V.png`
  - `docs/assets/screenshot-H.png`
  - `docs/assets/screenshot-menubar.png`
- [ ] `docs/CHANGELOG.md` has section for new version
- [ ] README.md reviewed for accuracy
- [ ] All code changes committed and pushed to main

### 3. Environment Validation
- [ ] macOS with Xcode CLT installed
- [ ] Developer ID Application certificate in Keychain
- [ ] Notary profile configured: `xcrun notarytool history --keychain-profile AgentSessionsNotary`
- [ ] GitHub CLI authenticated: `gh auth status`
- [ ] Clean working directory: `git status`
- [ ] On main branch: `git branch --show-current`

### 4. Deployment Parameters

Gather these values before running the script:

```bash
# Required
VERSION=2.2                                           # Target version

# Optional (auto-detected if not set)
TEAM_ID=24NDRU35WD                                    # Apple Team ID
NOTARY_PROFILE=AgentSessionsNotary                    # Keychain profile name
DEV_ID_APP="Developer ID Application: Alex M (24NDRU35WD)"  # Code signing identity

# Optional (defaults shown)
UPDATE_CASK=1                                         # Update Homebrew cask (1=yes, 0=no)
SKIP_CONFIRM=1                                        # Skip interactive prompts (1=yes, 0=no)
```

## Automated Deployment

Once pre-flight is complete, run the deployment script with all parameters:

```bash
VERSION=2.2 SKIP_CONFIRM=1 tools/release/deploy-agent-sessions.sh
```

### What the script does automatically:

1. **Pre-checks**
   - Validates xcodebuild, gh, notarytool are available
   - Auto-detects Developer ID certificate
   - Verifies CHANGELOG.md has version section

2. **Build & Notarize** (5-15 minutes)
   - Builds Release configuration
   - Code signs with hardened runtime
   - Creates DMG
   - Submits to Apple notary service
   - Waits for approval
   - Staples notarization ticket

3. **Update Documentation**
   - Updates download links in README.md
   - Updates download links in docs/index.html
   - Commits and pushes changes

4. **Update Homebrew Cask**
   - Updates version and sha256 in local cask
   - Commits and pushes to homebrew-agent-sessions repo

5. **Create GitHub Release**
   - Extracts release notes from CHANGELOG.md
   - Creates or updates GitHub Release
   - Uploads DMG and SHA256 checksum

### Script output location:
- DMG: `dist/AgentSessions-{VERSION}.dmg`
- SHA: `dist/AgentSessions-{VERSION}.dmg.sha256`
- Build logs: Terminal output

## Post-Deployment Verification

After script completes successfully, run automated and manual checks.

### Automated Checks (Run by Agent - 1-2 minutes)

These checks should be performed automatically by the deployment agent:

```bash
# 1. Verify GitHub release exists with correct assets
gh release view v{VERSION} --json name,assets | jq '.assets[] | .name'
# Expected: AgentSessions-{VERSION}.dmg and AgentSessions-{VERSION}.dmg.sha256

# 2. Verify README.md download links point to new version
grep "releases/download/v" README.md | grep "{VERSION}"
# Should find: AgentSessions-{VERSION}.dmg URLs and text labels with {VERSION}

# 3. Verify docs/index.html download links point to new version
grep "releases/download/v" docs/index.html | grep "{VERSION}"
# Should find: AgentSessions-{VERSION}.dmg URL and "Download Agent Sessions {VERSION}" text

# 4. Verify Homebrew cask updated (if local tap exists)
grep -E "(version|sha256)" /opt/homebrew/Library/Taps/jazzyalex/homebrew-agent-sessions/Casks/agent-sessions.rb | head -2
# Expected: version "{VERSION}" and matching sha256

# 5. Verify release notes match CHANGELOG.md
gh release view v{VERSION} --json body -q '.body' > /tmp/release_notes.txt
awk '/^## \[{VERSION}\]/,/^## \[/' docs/CHANGELOG.md > /tmp/changelog_section.txt
diff -u /tmp/changelog_section.txt /tmp/release_notes.txt
# Expected: no significant differences

# 6. Verify git is clean
git status --porcelain
# Expected: empty output or only .claude/settings.local.json, project.pbxproj, CLAUDE.md
```

**Agent should automatically fix any issues found:**
- Incorrect version numbers in download button text → Edit and commit
- Missing Homebrew cask update → Update cask, commit, and push
- Uncommitted documentation changes → Commit and push

### Human-Required Checks (30-60 minutes)
- [ ] Download DMG from GitHub Release
- [ ] Verify SHA256 checksum matches
- [ ] Test installation on clean macOS system
- [ ] Verify Gatekeeper accepts app (right-click → Open)
- [ ] Test app launches without errors
- [ ] Test basic functionality (session list, search, resume)
- [ ] Test Homebrew installation: `brew upgrade agent-sessions`

### Communication
- [ ] Update website if needed (jazzyalex.github.io/agent-sessions)
- [ ] Announce release (if applicable)
- [ ] Monitor GitHub issues for installation problems

### Monitoring (24-48 hours)
- [ ] Check GitHub Release download count
- [ ] Monitor for new issues or bug reports
- [ ] Verify no Gatekeeper or notarization complaints

## Troubleshooting

### Notary profile errors
```bash
xcrun notarytool store-credentials AgentSessionsNotary \
  --apple-id "your-apple-id@example.com" \
  --team-id "24NDRU35WD" \
  --password "app-specific-password"
```

### GitHub CLI authentication
```bash
gh auth login
gh auth status
```

### Developer ID certificate not found
```bash
security find-identity -v -p codesigning
```

### Build failures
- Check Xcode version: `xcodebuild -version`
- Clean build folder: `rm -rf build/ dist/`
- Verify project.pbxproj MARKETING_VERSION is correct

### Notarization rejected
- Review notary log: `xcrun notarytool log --keychain-profile AgentSessionsNotary {submission-id}`
- Common issues: unsigned binaries, incorrect entitlements, missing hardened runtime

### Homebrew cask not updated
- Verify local tap exists: `ls /opt/homebrew/Library/Taps/jazzyalex/homebrew-agent-sessions/`
- Check UPDATE_CASK=1 was set
- Manually update: Edit `Casks/agent-sessions.rb`, update version/sha256/url

## Manual Deployment (Alternative)

If automation fails, use manual steps:

1. Build: `xcodebuild -scheme AgentSessions -configuration Release SYMROOT=build`
2. Sign: `codesign --deep --force --verify --verbose --timestamp --options runtime --sign "Developer ID Application: Alex M (24NDRU35WD)" build/Release/AgentSessions.app`
3. Create DMG: `hdiutil create -volname "Agent Sessions" -srcfolder build/Release/AgentSessions.app -ov -format UDZO dist/AgentSessions-{VERSION}.dmg`
4. Notarize: `xcrun notarytool submit dist/AgentSessions-{VERSION}.dmg --keychain-profile AgentSessionsNotary --wait`
5. Staple: `xcrun stapler staple dist/AgentSessions-{VERSION}.dmg`
6. Compute SHA: `shasum -a 256 dist/AgentSessions-{VERSION}.dmg > dist/AgentSessions-{VERSION}.dmg.sha256`
7. Create release: `gh release create v{VERSION} dist/AgentSessions-{VERSION}.dmg dist/AgentSessions-{VERSION}.dmg.sha256 --title "Agent Sessions {VERSION}" --notes-file notes.txt`
8. Update README/docs download links manually
9. Update Homebrew cask manually

## Environment Configuration

Optional: Create `tools/release/.env` (not committed) with default values:

```bash
TEAM_ID=24NDRU35WD
NOTARY_PROFILE=AgentSessionsNotary
DEV_ID_APP="Developer ID Application: Alex M (24NDRU35WD)"
UPDATE_CASK=1
SKIP_CONFIRM=1
```

This file is sourced automatically by the script.
