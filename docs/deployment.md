# Agent Sessions Deployment Runbook

This document is the canonical deployment runbook for all agents (Claude, Codex, OpenCode, Xcode, manual shell). Always treat this file as the single source of truth for how releases are built, signed, notarized, and published.


This runbook provides a **fully automated deployment process** with comprehensive validation, retry logic, automated testing, and verification.

## One-screen cheat sheet

**Core commands** (run from repo root):
- `tools/release/deploy changelog [FROM_TAG]`
- `tools/release/deploy bump [patch|minor|major]`
- `git push origin main`
- `tools/release/deploy release <VERSION>`
- `tools/release/deploy verify <VERSION>`

## Sparkle Update Integrity (Appcast + Signatures)

- **Appcast file**: `docs/appcast.xml` (committed to `main`)
- **Served from**: GitHub Pages over HTTPS at `https://jazzyalex.github.io/agent-sessions/appcast.xml`
- **Update payloads**: DMGs are hosted on GitHub Releases over HTTPS (the appcast `enclosure url` should point to `https://github.com/jazzyalex/agent-sessions/releases/...`)
- **Signing (recommended by Sparkle)**: Appcast generation uses Sparkle’s `generate_appcast`, which produces EdDSA signatures for update enclosures.

**Key environment flags**:
- `SKIP_CONFIRM=1` — make bump and release flows unattended (suppresses confirmation prompts where supported).
- `NOTARIZE_SYNC=1` — use legacy blocking notarization instead of background polling.
- `UPDATE_CASK=1` — update the Homebrew tap via GitHub API.

**Log locations** (see troubleshooting for details):
- Unified deploy log: `tools/release/deploy` prints the path (in `/tmp`) when running `release`.
- Verification log: `/tmp/deploy-<VERSION>.log`.
- Notarization log: `/tmp/notarization-<VERSION>-<timestamp>.log`.

## Quick Start (Unified Tool)

The entire deployment workflow is now handled by a single unified tool: `tools/release/deploy`

### Typical Release Workflow

```bash
# 1. Review what changed since last release
tools/release/deploy changelog

# 2. Bump version (patch/minor/major)
tools/release/deploy bump minor

# 3. Push version bump to GitHub
git push origin main

# 4. Deploy the release
tools/release/deploy release 2.8.0

# 5. Verify deployment (runs automatically, but can re-run)
tools/release/deploy verify 2.8.0
```

### Quick Patch Release

```bash
tools/release/deploy bump patch
git push origin main
tools/release/deploy release 2.7.2
```

## Unified Tool Subcommands

### `deploy bump [major|minor|patch]`
Automatically increments version and updates CHANGELOG:
- Auto-increments build number (critical for Sparkle)
- Updates MARKETING_VERSION in project.pbxproj (2 occurrences)
- Moves [Unreleased] to [VERSION] in CHANGELOG.md
- Creates git commit with version bump
- Shows diff for review before committing
- Respects `SKIP_CONFIRM=1` to skip interactive confirmations when running unattended

### `deploy release VERSION`
Full deployment pipeline with enhanced safety:
- ✅ **Comprehensive dependency validation** (all required tools)
- ✅ **Enhanced pre-flight checks** (git state, version validation, build numbers)
- ✅ **Build, sign, and notarize** (Apple Developer ID)
- ✅ **DMG smoke testing** (mount, verify signature, check version)
- ✅ **Sparkle appcast generation** (Sparkle `generate_appcast`, EdDSA signatures)
- ✅ **GitHub release creation** (idempotent, can re-run)
- ✅ **Homebrew cask update** (via GitHub API)
- ✅ **Network retry logic** (3 attempts, 5s backoff)
- ✅ **Cache propagation waits** (GitHub Pages, Homebrew)
- ✅ **Automated verification** (8+ critical checks)
- ✅ **Auto-rollback prompt** (if verification fails)
- ✅ **Structured logging** (saved to /tmp/release-VERSION-timestamp.log)

### `deploy verify VERSION`
Post-deployment verification (runs automatically after release):
- GitHub Release assets uploaded and downloadable
- Appcast has correct version, EdDSA signature, release URLs
- Documentation links updated (README.md, docs/index.html)
- Homebrew cask updated to correct version
- DMG downloadable and correct size
- SHA256 checksums match
- Git tags exist locally and remotely

### `deploy changelog [FROM_TAG]`
Generate CHANGELOG from conventional commits:
- Auto-detects last tag if not specified
- Extracts feat/fix/perf/refactor/docs commits
- Groups into CHANGELOG sections (Added, Fixed, Performance, etc.)
- Shows commit breakdown by category
- Offers to save snippet file for easy copying

### Emergency Rollback

If deployment fails or has issues, use the separate rollback tool:

```bash
tools/release/rollback-release.sh VERSION

# What it does:
# - Deletes GitHub Release and git tags (local + remote)
# - Reverts version-related commits
# - Provides guidance for Homebrew cask cleanup
# - Interactive confirmations for safety
```

## Legacy Commands (Still Work)

The individual scripts are still available for backward compatibility:

```bash
# Old way (still works)
tools/release/bump-version.sh patch
VERSION=2.7.2 SKIP_CONFIRM=1 tools/release/deploy-agent-sessions.sh
tools/release/verify-deployment.sh 2.7.2

# New unified way (recommended)
tools/release/deploy bump patch
tools/release/deploy release 2.7.2
tools/release/deploy verify 2.7.2
```

Outputs:
- DMG: `dist/AgentSessions-2.5.1.dmg`
- SHA: `dist/AgentSessions-2.5.1.dmg.sha256`
- GitHub Release: `v2.5.1` with assets and notes from `docs/CHANGELOG.md`
- README and docs download links updated to 2.5.1
- Homebrew cask updated in `jazzyalex/homebrew-agent-sessions`

If any step fails, see “Troubleshooting” below.

## Deployment Features

### 1. Comprehensive Dependency Validation
All required tools are checked upfront:
- ✅ xcodebuild, git, gh, python3, curl, shasum, codesign, hdiutil, security
- ✅ Python packaging module for semver comparison
- ✅ GitHub CLI authentication status
- ✅ Apple notary profile configuration

**Benefit**: Fails fast with clear error messages instead of mysterious mid-deployment failures

### 2. Enhanced Pre-Flight Validation
Before building, the system validates:
- ✅ **Git state**: Clean working directory, on main branch, synced with origin
- ✅ **Version validation**: Tag doesn't exist, semver comparison with previous version
- ✅ **Build number**: Must increment for Sparkle (critical!)
- ✅ **CHANGELOG**: Section exists for version with correct date format

**Benefit**: Catches errors before the 10-minute build/notarize cycle

### 3. Pre-Deployment Smoke Testing (NEW!)
After DMG creation, before upload:
- ✅ **DMG verification**: Validates structure with `hdiutil verify`
- ✅ **Mount test**: Mounts DMG to verify it's bootable
- ✅ **App bundle check**: Ensures .app exists in DMG
- ✅ **Code signature**: Validates with `codesign --verify --deep --strict`
- ✅ **Version check**: Confirms app version matches expected

**Benefit**: Prevents uploading corrupted or incorrectly signed DMGs

### 4. Network Retry Logic
All network operations retry automatically (3 attempts, 5s backoff):
- GitHub Release creation/upload
- Homebrew cask updates via GitHub API
- Git push operations (appcast, docs)

**Benefit**: Resilient to transient network failures

### 5. Improved Cache Propagation Waits
Smart timeout-based waiting instead of hardcoded loops:
- **GitHub Pages**: Waits up to 120s for appcast.xml to be live
- **Homebrew cask**: Waits up to 40s for cask version to propagate
- Shows elapsed time when cache propagates
- Non-blocking warnings if timeout exceeded

**Benefit**: Prevents race conditions, provides better feedback

### 6. Idempotent Operations
Safe to re-run if deployment partially fails:
- GitHub release checks if release exists before creating
- Asset uploads use `--clobber` flag to replace existing
- All operations logged with structured timestamps

**Benefit**: Can recover from partial failures by re-running

### 7. Automated Verification
After deployment, comprehensive checks run automatically:
- GitHub Release assets exist and are downloadable
- Appcast has correct version, EdDSA signature, and URLs
- Validates README/docs download links
- Checks Homebrew cask version matches
- Verifies SHA256 checksums
- Exits with error if any check fails

**Benefit**: Catches deployment issues immediately

### 8. Auto-Rollback on Failure (NEW!)
If verification fails, the system prompts for automatic rollback:
- ✅ Offers to run rollback script automatically (default: Yes)
- ✅ Deletes GitHub Release and git tags
- ✅ Reverts version-related commits
- ✅ Provides clear error logging
- ✅ Respects `SKIP_CONFIRM=1` flag (shows manual command instead)

**Benefit**: Fast recovery from failed deployments

### 9. Structured Logging
All operations log to timestamped files:
- Format: `/tmp/<subcommand>-<VERSION>-<timestamp>.log`
- Includes ISO timestamps and severity levels
- Captures all output for debugging
- Example: `/tmp/release-2.8.0-1732652300.log`

**Benefit**: Easy to debug failed deployments, share logs with team

### 10. CHANGELOG Automation (NEW!)
Generate CHANGELOG entries from conventional commits:
- ✅ Extracts commits by type: feat/fix/perf/refactor/docs
- ✅ Groups into CHANGELOG sections (Added, Fixed, Performance, etc.)
- ✅ Shows commit breakdown by category
- ✅ Offers to save snippet file for easy copying
- ✅ Auto-detects last tag if not specified

**Benefit**: No more manual CHANGELOG writing, consistent formatting

## Rollback Capability
`rollback-release.sh` provides fast recovery:
- Deletes GitHub Release and git tags (local + remote)
- Reverts appcast/README/docs commits
- Checks Homebrew cask status
- Interactive confirmations for destructive operations

**Benefit**: MTTR (mean time to recover) reduced from hours to minutes

### Agent Execution (Codex CLI)
- The Agent can and will run xcodebuild, codesign, notarytool, hdiutil, and gh with escalated permissions when you request a release.
- Certificates and notary profile are assumed to be installed on the system Keychain (per this project's setup). The Agent won't prompt for them each time.
- To avoid repeated questions, prefer SKIP_CONFIRM=1 and provide VERSION/TEAM_ID/DEV_ID_APP/NOTARY_PROFILE explicitly.
- The Agent will request elevation when necessary (build/sign/notarize/upload/cask writes) and proceed non‑interactively.

## Pre-flight Checklist (Mostly Automated Now)

Complete this checklist **before** running the deployment script. Answer all questions and verify all conditions.

### 1. Version Planning
- [ ] What version are you releasing? (e.g., 2.5.1)
- [ ] Current MARKETING_VERSION in project.pbxproj: 2.5.1 (run grep to confirm)
- [ ] **CRITICAL: Increment CURRENT_PROJECT_VERSION (build number) for Sparkle updates:**
  ```bash
  grep "CURRENT_PROJECT_VERSION" AgentSessions.xcodeproj/project.pbxproj
  # Must be higher than previous release (e.g., 1 → 2, 2 → 3)
  # Sparkle compares build numbers, not marketing versions!
  ```
- [ ] Confirm version bump is correct (major/minor/patch)

### 2. Asset Preparation
- [ ] Screenshots updated (if UI changed):
  - `docs/assets/screenshot-V.png`
  - `docs/assets/screenshot-H.png`
  - `docs/assets/screenshot-menubar.png`
- [ ] `docs/CHANGELOG.md` has a section for the new version
- [ ] README.md and docs/index.html reviewed and updated:
  - Download button/link points to `{VERSION}` and visible label reads `Download Agent Sessions {VERSION}`
  - File name references use `AgentSessions-{VERSION}.dmg`
  - No release notes added to README or website (keep feature overview current; detailed notes live in `docs/CHANGELOG.md`)
  - Gemini remains noted as read-only; Favorites listed if present
  - Product Hunt badge aligns with the social buttons row and matches button height
- [ ] All code changes committed and pushed to main

### 3. Environment Validation
- [ ] macOS with Xcode CLT installed
- [ ] Developer ID Application certificate in Keychain
- [ ] Notary profile configured: `xcrun notarytool history --keychain-profile AgentSessionsNotary`
- [ ] Sparkle EdDSA private key exists in Keychain:
  ```bash
  security find-generic-password -s "Sparkle"
  # Should show: keychain: "/Users/.../Library/Keychains/login.keychain-db"
  ```
- [ ] GitHub CLI authenticated: `gh auth status`
- [ ] Clean working directory: `git status`
- [ ] On main branch: `git branch --show-current`

### 4. Deployment Parameters

Gather these values before running the script:

```bash
# Required
VERSION=2.5.1                                         # Target version

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
VERSION=2.5.1 SKIP_CONFIRM=1 tools/release/deploy-agent-sessions.sh
```

### What the script does automatically:

1. **Pre-checks**
   - Validates xcodebuild, gh, notarytool are available
   - Auto-detects Developer ID certificate
   - Verifies CHANGELOG.md has version section

2. **Build & Sign** (2-5 minutes)
   - Builds Release configuration
   - Code signs with Developer ID Application certificate + hardened runtime
   - **Verifies signature uses Developer ID (not ad-hoc)**
   - Creates DMG

3. **DMG Verification** (Critical!)
   - **Verifies DMG integrity with `hdiutil verify`**
   - **Validates DMG is a proper disk image format**
   - Catches corrupted DMGs before notarization (prevents wasted time)

4. **Notarize & Staple** (5-15 minutes)
   - Submits verified DMG to Apple notary service
   - Waits for approval
   - Staples notarization ticket to DMG

5. **Generate Sparkle Appcast** (for auto-updates)
   - Copies DMG to `dist/updates/` directory
   - Finds Sparkle `generate_appcast` tool from SPM artifacts
   - Generates `appcast.xml` with EdDSA signature (reads private key from Keychain)
   - **Verifies EdDSA private key exists in Keychain (service: "https://sparkle-project.org")**
   - Fixes DMG URL to point to GitHub Releases (not GitHub Pages)
   - Inserts release notes into a `<description><![CDATA[...]]></description>` element using Python (robust with CDATA)
     - Patch version rule: When releasing `A.B.C`, the script aggregates `[A.B.C]` and `[A.B]` sections (patch first, then minor). Fails if neither exist
     - Fails hard with a clear error if no notes found (prevents Sparkle UI hang)
   - Copies appcast.xml to docs/ for GitHub Pages
   - Commits and pushes appcast to main branch

6. **Update Documentation**
   - Updates download links in README.md and docs/index.html
   - Normalizes visible version strings in download button labels and file names
   - Validates that both files contain the expected `{VERSION}` URL and label; fails hard if mismatched
   - Does not inject release notes; README/site remain feature-focused
   - Commits and pushes changes

7. **Update Homebrew Cask**
   - Generates cask file with correct version and SHA256
   - Updates via GitHub API to jazzyalex/homebrew-agent-sessions
   - Commits directly to main branch

8. **Create GitHub Release**
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

# 2. Verify Sparkle appcast.xml published on GitHub Pages
curl -s https://jazzyalex.github.io/agent-sessions/appcast.xml | grep -E "(sparkle:version|sparkle:edSignature|enclosure url)"
# Expected:
#   <sparkle:version>1</sparkle:version>
#   <sparkle:shortVersionString>{VERSION}</sparkle:shortVersionString>
#   <enclosure url="https://github.com/jazzyalex/agent-sessions/releases/download/v{VERSION}/AgentSessions-{VERSION}.dmg" ... sparkle:edSignature="..."/>

# 3. Verify `<description>` (release notes) is present for the latest item
curl -s https://jazzyalex.github.io/agent-sessions/appcast.xml | grep -A2 "<title>2.5.1" | grep -n "<description>"
# Expected: a `<description><![CDATA[` block immediately after `<pubDate>`

# 4. Verify EdDSA signature is present in appcast
curl -s https://jazzyalex.github.io/agent-sessions/appcast.xml | grep "sparkle:edSignature" | wc -l
# Expected: 1 (or more if multiple versions in appcast)

# 5. Verify appcast DMG URL points to GitHub Releases (not GitHub Pages)
curl -s https://jazzyalex.github.io/agent-sessions/appcast.xml | grep "enclosure url" | grep -v "github.com/jazzyalex/agent-sessions/releases"
# Expected: no output (all URLs should be GitHub Releases)

# 6. Verify README.md download links and labels point to new version
grep -E "releases/download/v{VERSION}/AgentSessions-{VERSION}\.dmg|Download Agent Sessions {VERSION}" README.md
# Should find: AgentSessions-{VERSION}.dmg URL and a visible "Download Agent Sessions {VERSION}" label

# 7. Verify docs/index.html download links and labels point to new version
grep -E "releases/download/v{VERSION}/AgentSessions-{VERSION}\.dmg|Download Agent Sessions {VERSION}" docs/index.html
# Should find: AgentSessions-{VERSION}.dmg URL and a visible "Download Agent Sessions {VERSION}" label

# 8. Verify Homebrew cask updated (API avoids raw cache)
gh api -H "Accept: application/vnd.github+json" \
  "/repos/jazzyalex/homebrew-agent-sessions/contents/Casks/agent-sessions.rb" \
  --jq '.content' | tr -d '\n' | base64 --decode | \
  grep -E "(version \"{VERSION}\"|sha256 )"
# Expected: version "{VERSION}" and matching sha256

# 9. Verify release notes match CHANGELOG.md
gh release view v{VERSION} --json body -q '.body' > /tmp/release_notes.txt
awk '/^## \[{VERSION}\]/,/^## \[/' docs/CHANGELOG.md > /tmp/changelog_section.txt
diff -u /tmp/changelog_section.txt /tmp/release_notes.txt
# Expected: no significant differences

# 9. Verify git is clean
git status --porcelain
# Expected: empty output or only .claude/settings.local.json
```

**Agent should automatically fix any issues found:**
- Incorrect version numbers in download button text or filenames → Edit and commit
- Missing Homebrew cask update → Update cask, commit, and push
- Uncommitted documentation changes → Commit and push

## Website/README Content Guidelines (Mandatory)
- Do not add release notes to README or the website. Keep detailed changes in `docs/CHANGELOG.md`.
- Keep features current. If a patch release (e.g., 2.3.1) has no new features, leave "What's New" at the latest minor (e.g., 2.3).
- Always update:
  - The download URL to `v{VERSION}/AgentSessions-{VERSION}.dmg`
  - The visible label to `Download Agent Sessions {VERSION}`
  - Any text references to `AgentSessions-{VERSION}.dmg`
- Product Hunt badge should be in the same row as GitHub/X buttons and visually aligned (matching height).
- Follow Docs Style Policy: no emojis, clear headings, accessible text.

### Human-Required Checks (30-60 minutes)
- [ ] Download DMG from GitHub Release
- [ ] Verify SHA256 checksum matches
- [ ] Test installation on clean macOS system
- [ ] Verify Gatekeeper accepts app (right-click → Open)
- [ ] Test app launches without errors
- [ ] Test basic functionality (session list, search, resume)
- [ ] Test Homebrew cask installation locally:
  ```bash
  # Uninstall current version if present
  brew uninstall agent-sessions

  # Update tap and verify new version is available
  brew update
  brew info agent-sessions  # Should show version {VERSION}

  # Install and verify
  brew install agent-sessions
  open -a "Agent Sessions"

  # Verify version matches
  plutil -p "/Applications/Agent Sessions.app/Contents/Info.plist" | grep CFBundleShortVersionString
  # Expected: "CFBundleShortVersionString" => "{VERSION}"
  ```

### Communication
- [ ] Update website if needed (jazzyalex.github.io/agent-sessions)
- [ ] Announce release (if applicable)
- [ ] Monitor GitHub issues for installation problems

### Monitoring (24-48 hours)
- [ ] Check GitHub Release download count
- [ ] Monitor for new issues or bug reports
- [ ] Verify no Gatekeeper or notarization complaints

## Troubleshooting

### Corrupted DMG (notarytool hangs or fails)

**Symptom**: `xcrun notarytool submit` hangs at "initiating connection" or fails immediately

**Diagnosis**:
```bash
# Check if DMG is corrupted
hdiutil verify dist/AgentSessions-{VERSION}.dmg

# Check file type
file dist/AgentSessions-{VERSION}.dmg
# Expected: "...Apple partition map..." or "...Macintosh HFS..."
# Bad: "zlib compressed data" (corrupted)
```

**Root Causes**:
1. App bundle was incomplete when DMG was created
2. App was signed with ad-hoc certificate instead of Developer ID
3. Xcode build failed but didn't exit with error code

**Solution**:
```bash
# 1. Delete corrupted DMG
rm dist/AgentSessions-{VERSION}.dmg

# 2. Verify app signature uses Developer ID
codesign -dv --verbose=4 dist/AgentSessions.app 2>&1 | grep "Authority=Developer ID Application"
# Must show: Authority=Developer ID Application: Your Name (TEAM_ID)

# 3. If app has wrong signature, re-sign
codesign --deep --force --verify --verbose --timestamp --options runtime \
  --sign "Developer ID Application: Alex M (24NDRU35WD)" dist/AgentSessions.app

# 4. Create fresh DMG
hdiutil create -volname "Agent Sessions" -srcfolder dist/AgentSessions.app \
  -ov -format UDZO dist/AgentSessions-{VERSION}.dmg

# 5. Verify DMG is valid
hdiutil verify dist/AgentSessions-{VERSION}.dmg

# 6. Retry notarization
xcrun notarytool submit dist/AgentSessions-{VERSION}.dmg --keychain-profile AgentSessionsNotary --wait
```

**Prevention**: The updated build script now includes DMG verification before notarization.

## Docs sanity check (for agents)

Before changing deployment scripts, do a quick paper dry run using a fake version (for example, 2.9.0):
- Walk through the cheat sheet commands and confirm each one is documented with required flags and environment variables.
- Verify that `docs/deployment.md` and `.claude/skills/deploy.md` reference the same entrypoints (`tools/release/deploy`).
- Treat this as a documentation validation step only; do not actually tag or publish 2.9.0.

### Sparkle EdDSA signature errors

**Symptom**: Users see "The update is improperly signed and could not be validated"

**Diagnosis**:
```bash
# 1. Check if EdDSA private key exists
security find-generic-password -s "https://sparkle-project.org" -a "ed25519"
# Should show: keychain: "/Users/.../Library/Keychains/login.keychain-db"

# 2. Verify public key in Info.plist matches
~/Library/Developer/Xcode/DerivedData/AgentSessions-*/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys
# Shows: "A pre-existing signing key was found. This is how it should appear in your Info.plist:"

# 3. Compare with AgentSessions/Info.plist
grep -A1 "SUPublicEDKey" AgentSessions/Info.plist
```

**Root Causes**:
1. Public key in Info.plist doesn't match private key in Keychain
2. Appcast was signed with different key than what's in Info.plist
3. Private key was lost/regenerated but Info.plist wasn't updated

**Solution**:
1. If keys don't match: Update Info.plist with correct public key from `generate_keys`
2. Regenerate appcast.xml with matching key
3. Test signature: Download DMG and verify with Sparkle's `sign_update --verify`

### Sparkle auto-update not detecting new version

**Symptom**: App says "You're up to date" when a newer version exists in the appcast

**Diagnosis**:
```bash
# 1. Check build numbers (NOT marketing versions!)
# Old version:
plutil -p "/Applications/Agent Sessions.app/Contents/Info.plist" | grep CFBundleVersion
# New version in release:
curl -s https://jazzyalex.github.io/agent-sessions/appcast.xml | grep "sparkle:version"

# 2. Sparkle compares build numbers, not marketing versions!
# If both have CFBundleVersion=1, Sparkle thinks they're the same
```

**Root Cause**:
Sparkle uses `CFBundleVersion` (build number), not `CFBundleShortVersionString` (marketing version) for version comparison. If you release 2.5 with build number "1" and the previous 2.4 also had build number "1", Sparkle won't detect an update.

**Solution**:
```bash
# 1. Increment CURRENT_PROJECT_VERSION in project.pbxproj
grep -n "CURRENT_PROJECT_VERSION" AgentSessions.xcodeproj/project.pbxproj
# Update from 1 → 2 (or N → N+1) in BOTH Debug and Release configurations

# 2. Rebuild the app
tools/release/build_sign_notarize_release.sh

# 3. Verify new build number
plutil -p dist/AgentSessions.app/Contents/Info.plist | grep CFBundleVersion
# Should show: "CFBundleVersion" => "2" (or N+1)

# 4. Regenerate appcast
rm -rf dist/updates && mkdir dist/updates
cp dist/AgentSessions-{VERSION}.dmg dist/updates/
~/Library/Developer/Xcode/DerivedData/AgentSessions-*/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast dist/updates/

# 5. Verify appcast has new build number
grep "sparkle:version" dist/updates/appcast.xml
# Should show: <sparkle:version>2</sparkle:version>

# 6. Update docs/appcast.xml and push
cp dist/updates/appcast.xml docs/appcast.xml
# Fix DMG URL to GitHub Releases, then commit and push
```

**Prevention**: Always increment `CURRENT_PROJECT_VERSION` for each release (even patch releases).

### Sparkle update window shows spinning wheel forever

**Symptom**: Update is detected, window opens, but shows indefinite spinning wheel during download

**Diagnosis**:
```bash
# Check if release notes are present in appcast
curl -s https://jazzyalex.github.io/agent-sessions/appcast.xml | grep -A5 "description"
# If empty or missing, Sparkle may hang when SUShowReleaseNotes=1
```

**Root Cause**:
When `SUShowReleaseNotes` is enabled in Info.plist but the appcast has no `<description>` element, Sparkle may hang waiting for release notes content.

**Solution**:
```bash
# Add release notes to appcast.xml item:
<description><![CDATA[
    <h2>What's New in {VERSION}</h2>
    <ul>
        <li><strong>Feature:</strong> Description</li>
        <li><strong>Fixed:</strong> Bug description</li>
    </ul>
]]></description>

# Commit and push appcast
git add docs/appcast.xml
git commit -m "Add release notes to appcast for {VERSION}"
git push
```

**Prevention**: The deployment script automatically adds release notes from CHANGELOG.md to the appcast using Python (robust with CDATA) and fails hard if missing. This prevents the Sparkle UI from hanging due to an empty `<description>`.

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
- Script now uses GitHub API to update cask directly
- Check: `curl -s https://raw.githubusercontent.com/jazzyalex/homebrew-agent-sessions/main/Casks/agent-sessions.rb | grep version`
- If wrong: Re-run deploy script with UPDATE_CASK=1

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
