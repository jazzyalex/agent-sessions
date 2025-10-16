# Agent Sessions Deployment Runbook

This runbook provides a fully automated deployment process with upfront validation.
All questions are answered before running the script, which then executes non-interactively.

## Quick Start (2.3.2)

If you’re ready to ship 2.3.2 and have Xcode + notarytool + gh configured on your Mac:

```bash
# Example for 2.3.2 (adjust TEAM_ID / DEV_ID_APP if needed)
export VERSION=2.3.2
export TEAM_ID=24NDRU35WD
export NOTARY_PROFILE=AgentSessionsNotary
export DEV_ID_APP="Developer ID Application: Alex M (24NDRU35WD)"
export UPDATE_CASK=1
export SKIP_CONFIRM=1

tools/release/deploy-agent-sessions.sh
```

Outputs:
- DMG: `dist/AgentSessions-2.3.2.dmg`
- SHA: `dist/AgentSessions-2.3.2.dmg.sha256`
- GitHub Release: `v2.3.2` with assets and notes from `docs/CHANGELOG.md`
- README and docs download links updated to 2.3.2
- Homebrew cask updated in `jazzyalex/homebrew-agent-sessions`

If any step fails, see “Troubleshooting” below.

### Agent Execution (Codex CLI)
- The Agent can and will run xcodebuild, codesign, notarytool, hdiutil, and gh with escalated permissions when you request a release.
- Certificates and notary profile are assumed to be installed on the system Keychain (per this project’s setup). The Agent won’t prompt for them each time.
- To avoid repeated questions, prefer SKIP_CONFIRM=1 and provide VERSION/TEAM_ID/DEV_ID_APP/NOTARY_PROFILE explicitly.
- The Agent will request elevation when necessary (build/sign/notarize/upload/cask writes) and proceed non‑interactively.

## Pre-flight Checklist

Complete this checklist **before** running the deployment script. Answer all questions and verify all conditions.

### 1. Version Planning
- [ ] What version are you releasing? (e.g., 2.3.2)
- [ ] Current MARKETING_VERSION in project.pbxproj: 2.3.2 (run grep to confirm)
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
VERSION=2.3.2                                         # Target version

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
VERSION=2.3.2 SKIP_CONFIRM=1 tools/release/deploy-agent-sessions.sh
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
   - Copies appcast.xml to docs/ for GitHub Pages
   - Commits and pushes appcast to main branch

6. **Update Documentation**
   - Updates download links in README.md and docs/index.html
   - Normalizes visible version strings in download button labels and file names
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

# 3. Verify EdDSA signature is present in appcast
curl -s https://jazzyalex.github.io/agent-sessions/appcast.xml | grep "sparkle:edSignature" | wc -l
# Expected: 1 (or more if multiple versions in appcast)

# 4. Verify appcast DMG URL points to GitHub Releases (not GitHub Pages)
curl -s https://jazzyalex.github.io/agent-sessions/appcast.xml | grep "enclosure url" | grep -v "github.com/jazzyalex/agent-sessions/releases"
# Expected: no output (all URLs should be GitHub Releases)

# 5. Verify README.md download links and labels point to new version
grep -E "releases/download/v{VERSION}/AgentSessions-{VERSION}\.dmg|Download Agent Sessions {VERSION}" README.md
# Should find: AgentSessions-{VERSION}.dmg URL and a visible "Download Agent Sessions {VERSION}" label

# 6. Verify docs/index.html download links and labels point to new version
grep -E "releases/download/v{VERSION}/AgentSessions-{VERSION}\.dmg|Download Agent Sessions {VERSION}" docs/index.html
# Should find: AgentSessions-{VERSION}.dmg URL and a visible "Download Agent Sessions {VERSION}" label

# 7. Verify Homebrew cask updated
curl -s https://raw.githubusercontent.com/jazzyalex/homebrew-agent-sessions/main/Casks/agent-sessions.rb | grep -E "(version|sha256)" | head -2
# Expected: version "{VERSION}" and matching sha256

# 8. Verify release notes match CHANGELOG.md
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
