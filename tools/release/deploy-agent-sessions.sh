#!/usr/bin/env bash
set -euo pipefail

# deploy-agent-sessions.sh
# End-to-end release helper for Agent Sessions.

REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$REPO_ROOT"

ENV_FILE="$REPO_ROOT/tools/release/.env"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

APP_NAME_DEFAULT=$(sed -n 's/.*BuildableName = "\([^"]\+\)\.app".*/\1/p' AgentSessions.xcodeproj/xcshareddata/xcschemes/AgentSessions.xcscheme | head -n1)
APP_NAME=${APP_NAME:-${APP_NAME_DEFAULT:-AgentSessions}}

# Detect current marketing version to remind the user
CURR_VERSION=$(sed -n 's/.*MARKETING_VERSION = \([0-9][0-9.]*\).*/\1/p' AgentSessions.xcodeproj/project.pbxproj | head -n1)

VERSION=${VERSION:-}
if [[ -z "${VERSION}" ]]; then
  red "ERROR: VERSION not provided. Set VERSION=X.Y environment variable."
  echo "Current version in project: ${CURR_VERSION:-unknown}"
  exit 1
fi
TAG=${TAG:-v$VERSION}

TEAM_ID=${TEAM_ID:-}
NOTARY_PROFILE=${NOTARY_PROFILE:-AgentSessionsNotary}
DEV_ID_APP=${DEV_ID_APP:-}
NOTES_FILE=${NOTES_FILE:-}
UPDATE_CASK=${UPDATE_CASK:-1}
SKIP_CONFIRM=${SKIP_CONFIRM:-0}

green(){ printf "\033[32m%s\033[0m\n" "$*"; }
yellow(){ printf "\033[33m%s\033[0m\n" "$*"; }
red(){ printf "\033[31m%s\033[0m\n" "$*"; }

# Structured logging
LOG_FILE="/tmp/deploy-${VERSION:-unknown}-$(date +%s).log"
exec > >(tee -a "$LOG_FILE") 2>&1

log() {
  local level="$1"; shift
  echo "[$(date -Iseconds)] [$level] $*"
}

# Comprehensive dependency validation
check_dependencies() {
  log INFO "Checking dependencies..."
  local missing=()
  local missing_optional=()

  # Required tools
  for cmd in xcodebuild git gh python3 curl shasum codesign; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done

  # Optional but recommended tools
  for cmd in hdiutil security; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing_optional+=("$cmd")
    fi
  done

  # Check Python packages
  if ! python3 -c "import packaging" 2>/dev/null; then
    missing+=("python3-packaging (install: pip3 install packaging)")
  fi

  # Report missing dependencies
  if [[ ${#missing[@]} -gt 0 ]]; then
    red "ERROR: Missing required dependencies:"
    for dep in "${missing[@]}"; do
      red "  - $dep"
    done
    exit 2
  fi

  if [[ ${#missing_optional[@]} -gt 0 ]]; then
    yellow "WARNING: Missing optional dependencies:"
    for dep in "${missing_optional[@]}"; do
      yellow "  - $dep"
    done
  fi

  green "✓ All required dependencies available"
}

# Improved cache wait with timeout
wait_for_cache() {
  local url="$1"
  local expected="$2"
  local max_wait="${3:-120}"  # seconds
  local interval=3

  log INFO "Waiting for cache propagation: $url"

  for ((i=0; i<max_wait; i+=interval)); do
    if curl -sf "$url" 2>/dev/null | grep -q "$expected"; then
      green "✓ Cache propagated after ${i}s"
      return 0
    fi
    sleep $interval
  done

  red "ERROR: Cache did not propagate after ${max_wait}s"
  return 1
}

# Retry function for network operations
retry() {
  local max_attempts=3
  local timeout=5
  local attempt=1
  local exitCode=0

  while [[ $attempt -le $max_attempts ]]; do
    if "$@"; then
      return 0
    else
      exitCode=$?
    fi

    if [[ $attempt -lt $max_attempts ]]; then
      yellow "Attempt $attempt failed (exit $exitCode). Retrying in $timeout seconds..."
      sleep $timeout
    fi
    ((attempt++))
  done

  red "Command failed after $max_attempts attempts"
  return $exitCode
}

echo "==> Pre-checks"
log INFO "Starting deployment pre-checks"

# Run comprehensive dependency validation
check_dependencies

# Check gh authentication
command -v gh >/dev/null || { red "gh CLI not found"; exit 2; }
gh auth status >/dev/null 2>&1 || { red "gh not authenticated. Run: gh auth login"; exit 2; }

if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  red "Notary profile '$NOTARY_PROFILE' not configured. Run: xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <id> --team-id <TEAM> --password <app-specific-password>"
  exit 2
fi

# Try to auto-detect DEV_ID_APP if not provided
if [[ -z "$DEV_ID_APP" ]]; then
  if [[ -n "$TEAM_ID" ]]; then
    DETECTED=$(security find-identity -v -p codesigning 2>/dev/null | grep -i "Developer ID Application" | grep "(${TEAM_ID})" | head -n1 | sed -E 's/^[[:space:]]*[0-9]+\) [A-F0-9]+ \"([^\"]+)\".*$/\1/') || true
    if [[ -n "$DETECTED" ]]; then DEV_ID_APP="$DETECTED"; fi
  fi
  if [[ -z "$DEV_ID_APP" ]]; then
    DETECTED=$(security find-identity -v -p codesigning 2>/dev/null | grep -i "Developer ID Application" | head -n1 | sed -E 's/^[[:space:]]*[0-9]+\) [A-F0-9]+ \"([^\"]+)\".*$/\1/') || true
    if [[ -n "$DETECTED" ]]; then DEV_ID_APP="$DETECTED"; fi
  fi
fi

if [[ -z "$DEV_ID_APP" ]]; then
  red "Developer ID Application identity not found. Set DEV_ID_APP or ensure the cert is installed."
  exit 2
fi

echo "App       : $APP_NAME"
echo "Version   : $VERSION (tag $TAG)"
echo "Team ID   : ${TEAM_ID:-<not set>}"
echo "Dev ID    : $DEV_ID_APP"
echo "Notary    : $NOTARY_PROFILE"

# Enhanced pre-flight validation
echo ""
echo "==> Enhanced Pre-Flight Validation"

# Git state validation
echo "Checking git state..."
if [[ -n $(git status --porcelain | grep -v "^??") ]]; then
  red "ERROR: Uncommitted changes detected. Commit or stash changes before deploying."
  git status --short
  exit 2
fi
green "✓ Working directory clean"

if [[ $(git branch --show-current) != "main" ]]; then
  red "ERROR: Not on main branch (currently on $(git branch --show-current))"
  exit 2
fi
green "✓ On main branch"

git fetch origin main --quiet
if [[ $(git rev-parse HEAD) != $(git rev-parse origin/main) ]]; then
  red "ERROR: Local main not synced with origin/main. Run: git push or git pull"
  exit 2
fi
green "✓ Local main synced with origin"

# Version validation
echo "Checking version validity..."
if git rev-parse "$TAG" >/dev/null 2>&1; then
  red "ERROR: Tag $TAG already exists. Delete it first or bump to a new version."
  exit 2
fi
green "✓ Tag $TAG does not exist"

# Check previous version/build
PREV_TAG=$(git tag --sort=-version:refname | grep -E '^v[0-9]' | head -n1)
if [[ -n "$PREV_TAG" ]]; then
  PREV_VERSION=${PREV_TAG#v}
  echo "Previous version: $PREV_VERSION"

  # Semver comparison using Python
  IS_GREATER=$(python3 << PYEOF
from packaging import version
try:
    print("true" if version.parse("$VERSION") > version.parse("$PREV_VERSION") else "false")
except:
    print("true")  # Fallback if packaging module not available
PYEOF
)

  if [[ "$IS_GREATER" != "true" ]]; then
    red "ERROR: New version $VERSION must be greater than previous version $PREV_VERSION"
    exit 2
  fi
  green "✓ Version $VERSION > $PREV_VERSION"

  # Build number validation
  PREV_BUILD=$(git show "$PREV_TAG:AgentSessions.xcodeproj/project.pbxproj" 2>/dev/null | grep -m1 "CURRENT_PROJECT_VERSION" | sed 's/.*= \([0-9]*\);/\1/' | tr -d ' ' || echo "0")
  CURR_BUILD=$(sed -n 's/.*CURRENT_PROJECT_VERSION = \([0-9][0-9]*\).*/\1/p' AgentSessions.xcodeproj/project.pbxproj | head -n1 | tr -d ' ')

  if [[ -n "$CURR_BUILD" ]] && [[ -n "$PREV_BUILD" ]] && [[ $CURR_BUILD -le $PREV_BUILD ]]; then
    red "ERROR: Build number $CURR_BUILD must be greater than previous build $PREV_BUILD (Sparkle requirement)"
    exit 2
  fi
  green "✓ Build number $CURR_BUILD > $PREV_BUILD"
fi

# CHANGELOG validation
echo "Checking CHANGELOG.md..."
if [[ ! -f "docs/CHANGELOG.md" ]]; then
  red "ERROR: docs/CHANGELOG.md not found"
  exit 2
fi

if ! grep -q "^## \[$VERSION\]" docs/CHANGELOG.md; then
  red "ERROR: docs/CHANGELOG.md missing section for [$VERSION]"
  exit 2
fi
green "✓ CHANGELOG.md has section for $VERSION"

TODAY=$(date +%Y-%m-%d)
if ! grep -q "^## \[$VERSION\] - $TODAY" docs/CHANGELOG.md; then
  yellow "WARNING: CHANGELOG.md date is not today ($TODAY). This is OK if intentional."
fi

# Dependency validation
echo "Checking dependencies..."
if ! command -v python3 >/dev/null; then
  red "ERROR: python3 not found (required for version comparison)"
  exit 2
fi
green "✓ python3 available"

if ! security find-generic-password -s "https://sparkle-project.org" >/dev/null 2>&1; then
  yellow "WARNING: Sparkle EdDSA private key not found in Keychain (appcast may fail)"
fi

echo ""
green "✓ All pre-flight checks passed"

# Pre-deployment checklist (user confirmation)
echo
echo "Pre-deployment checklist:"
echo "  - Screenshots updated: docs/assets/screenshot-V.png, screenshot-H.png"
echo "  - CHANGELOG.md has a section for ${VERSION}"
echo "  - README sections reviewed (links, instructions)"
echo "  - GitHub CLI authenticated (gh auth status ok)"
echo "  - Notary profile available in Keychain (${NOTARY_PROFILE})"

# Simple validations
if [[ -f "docs/CHANGELOG.md" ]]; then
  if ! grep -q -E "^##[ ]*\[?${VERSION}\]?" docs/CHANGELOG.md; then
    yellow "WARNING: docs/CHANGELOG.md has no explicit section for ${VERSION}. Release notes will fall back to git log."
  fi
fi

# Build number validation (critical for Sparkle auto-updates)
CURR_BUILD=$(sed -n 's/.*CURRENT_PROJECT_VERSION = \([0-9][0-9]*\).*/\1/p' AgentSessions.xcodeproj/project.pbxproj | head -n1)
if [[ -n "$CURR_BUILD" ]]; then
  echo "Current build number: $CURR_BUILD"
  yellow "REMINDER: Sparkle uses build numbers (CFBundleVersion), not marketing versions, for update detection."
  yellow "If previous release also had build number $CURR_BUILD, users won't see an update!"
  yellow "Increment CURRENT_PROJECT_VERSION in project.pbxproj before releasing."
else
  yellow "WARNING: Could not detect CURRENT_PROJECT_VERSION from project.pbxproj"
fi

# Skip confirmation if SKIP_CONFIRM=1
if [[ "${SKIP_CONFIRM}" != "1" ]]; then
  read -r -p "Proceed with build/sign/notarize now? [y/N] " go
  if [[ "${go:-}" != "y" && "${go:-}" != "Y" ]]; then
    yellow "Aborted by user"
    exit 0
  fi
else
  green "Proceeding automatically (SKIP_CONFIRM=1)"
fi

export TEAM_ID NOTARY_PROFILE DEV_ID_APP VERSION TAG

green "==> Building and notarizing"
chmod +x "$REPO_ROOT/tools/release/build_sign_notarize_release.sh"
TEAM_ID="$TEAM_ID" NOTARY_PROFILE="$NOTARY_PROFILE" TAG="$TAG" VERSION="$VERSION" DEV_ID_APP="$DEV_ID_APP" \
  "$REPO_ROOT/tools/release/build_sign_notarize_release.sh"

DMG="$REPO_ROOT/dist/${APP_NAME}-${VERSION}.dmg"
SHA=$(shasum -a 256 "$DMG" | awk '{print $1}')

# Pre-deployment smoke test
log INFO "Running pre-deployment smoke test on DMG"
echo "==> Smoke Testing DMG"

if [[ ! -f "$DMG" ]]; then
  red "ERROR: DMG not found at $DMG"
  exit 2
fi

# Verify DMG is valid and mountable
if ! hdiutil verify "$DMG" >/dev/null 2>&1; then
  red "ERROR: DMG verification failed - file may be corrupt"
  exit 2
fi
green "✓ DMG structure valid"

# Mount DMG and test app
MOUNT_POINT="/tmp/agent-sessions-test-$$"
if hdiutil attach "$DMG" -mountpoint "$MOUNT_POINT" -quiet 2>/dev/null; then
  APP_PATH="$MOUNT_POINT/${APP_NAME}.app"

  if [[ ! -d "$APP_PATH" ]]; then
    red "ERROR: ${APP_NAME}.app not found in DMG"
    hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || true
    exit 2
  fi
  green "✓ App bundle found in DMG"

  # Verify code signature
  if codesign --verify --deep --strict "$APP_PATH" 2>/dev/null; then
    green "✓ Code signature valid"
  else
    red "ERROR: Code signature verification failed"
    hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || true
    exit 2
  fi

  # Verify app version matches expected
  APP_VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo "")
  if [[ "$APP_VERSION" != "$VERSION" ]]; then
    red "ERROR: App version mismatch. Expected $VERSION, got $APP_VERSION"
    hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || true
    exit 2
  fi
  green "✓ App version matches $VERSION"

  hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || true
  green "✓ All smoke tests passed"
else
  red "ERROR: Failed to mount DMG for smoke testing"
  exit 2
fi

green "==> Generating Sparkle appcast"
# Sparkle 2: Generate appcast.xml with EdDSA signatures
UPDATES_DIR="$REPO_ROOT/dist/updates"
mkdir -p "$UPDATES_DIR"

# Copy DMG to updates directory (Sparkle needs all versions in one place for delta updates)
cp "$DMG" "$UPDATES_DIR/"

# Find Sparkle generate_appcast tool from SPM artifacts
SPARKLE_BIN=$(find ~/Library/Developer/Xcode/DerivedData \
  -name "generate_appcast" \
  -path "*/artifacts/*/Sparkle/bin/*" \
  2>/dev/null | head -n1)

if [[ -z "$SPARKLE_BIN" ]]; then
  yellow "WARNING: Sparkle generate_appcast tool not found. Skipping appcast generation."
  yellow "Ensure Sparkle 2 is added via SPM and the project has been built at least once."
else
  green "Found Sparkle tools at: $(dirname "$SPARKLE_BIN")"

  # Generate appcast with EdDSA signatures (private key must be in Keychain)
  # Sparkle will read the private key from Keychain item "Sparkle"
  "$SPARKLE_BIN" "$UPDATES_DIR"

  if [[ -f "$UPDATES_DIR/appcast.xml" ]]; then
    green "Appcast generated successfully"

    # Fix DMG URLs: Sparkle generates wrong URLs pointing to GitHub Pages
    # Replace: https://jazzyalex.github.io/agent-sessions/AgentSessions-{VERSION}.dmg
    # With:    https://github.com/jazzyalex/agent-sessions/releases/download/v{VERSION}/AgentSessions-{VERSION}.dmg
    sed -i '' -E 's|https://jazzyalex\.github\.io/agent-sessions/AgentSessions-([0-9.]+)\.dmg|https://github.com/jazzyalex/agent-sessions/releases/download/v\1/AgentSessions-\1.dmg|g' \
      "$UPDATES_DIR/appcast.xml"
    green "Fixed DMG URLs in appcast to point to GitHub Releases"

    # Add release notes from CHANGELOG.md to prevent Sparkle UI hang
    # CRITICAL: Sparkle UI will hang without release notes!
    if [[ -f "docs/CHANGELOG.md" ]]; then
      # Patch version rule: Aggregate [A.B.C] and [A.B] notes
      # Example: 2.5.1 will include [2.5.1] first, then [2.5]
      NOTES=""
      if [[ "$VERSION" =~ ^([0-9]+\.[0-9]+)\.([0-9]+)$ ]]; then
        # Patch version (A.B.C) - include parent version notes
        PARENT_VERSION="${BASH_REMATCH[1]}"
        yellow "Patch version detected: ${VERSION} - including notes from ${PARENT_VERSION}"

        # Extract parent version notes
        PARENT_NOTES=$(sed -n "/^## \[${PARENT_VERSION}\]/,/^## \[/{ /^## \[${PARENT_VERSION}\]/d; /^## \[/d; p; }" docs/CHANGELOG.md 2>/dev/null || true)
        # Extract patch version notes
        PATCH_NOTES=$(sed -n "/^## \[${VERSION}\]/,/^## \[/{ /^## \[${VERSION}\]/d; /^## \[/d; p; }" docs/CHANGELOG.md 2>/dev/null || true)

        # Combine notes: patch notes first, then parent notes if present
        if [[ -n "$PATCH_NOTES" || -n "$PARENT_NOTES" ]]; then
          NOTES="${PATCH_NOTES}${PATCH_NOTES:+\n}${PARENT_NOTES}"
        fi
      else
        # Major/minor version (A.B) - extract only this version
        NOTES=$(sed -n "/^## \[${VERSION}\]/,/^## \[/{ /^## \[${VERSION}\]/d; /^## \[/d; p; }" docs/CHANGELOG.md 2>/dev/null || true)
      fi

      if [[ -n "$NOTES" ]]; then
        # Convert markdown to HTML
        NOTES_HTML=$(echo "$NOTES" | sed 's/^### \(.*\)/<h3>\1<\/h3>/g; s/^- \(.*\)/<p>\1<\/p>/g')

        # Use Python to insert description (most reliable for XML manipulation)
        python3 << PYEOF
import re

# Read appcast
with open("$UPDATES_DIR/appcast.xml", "r") as f:
    content = f.read()

# Create description element
description = """            <description><![CDATA[
                <h2>What's New in ${VERSION}</h2>
${NOTES_HTML}
            ]]></description>"""

# Insert after pubDate
content = re.sub(
    r'(<pubDate>.*?</pubDate>)',
    r'\1\n' + description,
    content,
    flags=re.DOTALL
)

# Write back
with open("$UPDATES_DIR/appcast.xml", "w") as f:
    f.write(content)
PYEOF

        green "Added release notes from CHANGELOG.md to appcast"
      else
        red "ERROR: No release notes found for ${VERSION} in CHANGELOG.md"
        red "Sparkle UI will HANG without release notes! Add notes and re-run."
        exit 1
      fi
    else
      red "ERROR: docs/CHANGELOG.md not found"
      red "Sparkle UI will HANG without release notes!"
      exit 1
    fi

    # Copy appcast to docs/ for GitHub Pages
    cp "$UPDATES_DIR/appcast.xml" "$REPO_ROOT/docs/appcast.xml"

    # Commit and push appcast to GitHub Pages (fail hard if push fails)
    git add "$REPO_ROOT/docs/appcast.xml"
    if ! git diff --staged --quiet; then
      git commit -m "chore(release): update appcast for ${VERSION}"
      retry git push origin HEAD:main
    else
      yellow "No appcast changes to commit."
    fi

    # Wait for GitHub Pages cache invalidation
    echo "Waiting for GitHub Pages to serve new appcast..."
    if ! wait_for_cache "https://jazzyalex.github.io/agent-sessions/appcast.xml" "$VERSION" 120; then
      yellow "WARNING: Appcast cache did not propagate, but continuing..."
    fi

    green "Appcast published to GitHub Pages: https://jazzyalex.github.io/agent-sessions/appcast.xml"
  else
    yellow "WARNING: appcast.xml not created. Check Sparkle EdDSA key in Keychain."
  fi
fi

green "==> Updating README and website download links"
sed -i '' -E \
  "s#releases/download/v[0-9.]+/AgentSessions-[0-9.]+\.dmg#releases/download/v${VERSION}/AgentSessions-${VERSION}.dmg#g" \
  "$REPO_ROOT/README.md"
sed -i '' -E \
  "s#releases/download/v[0-9.]+/AgentSessions-[0-9.]+\.dmg#releases/download/v${VERSION}/AgentSessions-${VERSION}.dmg#g" \
  "$REPO_ROOT/docs/index.html"

# Ensure visible version strings in buttons and file names also updated
sed -i '' -E \
  "s/Download Agent Sessions [0-9.]+/Download Agent Sessions ${VERSION}/g" \
  "$REPO_ROOT/README.md" "$REPO_ROOT/docs/index.html"
sed -i '' -E \
  "s/AgentSessions-[0-9.]+\\.dmg/AgentSessions-${VERSION}.dmg/g" \
  "$REPO_ROOT/README.md" "$REPO_ROOT/docs/index.html"

# Validate links and labels; fail hard if mismatch
EXPECTED_URL="releases/download/v${VERSION}/AgentSessions-${VERSION}.dmg"
EXPECTED_LABEL="Download Agent Sessions ${VERSION}"
for f in "$REPO_ROOT/README.md" "$REPO_ROOT/docs/index.html"; do
  if ! grep -q "$EXPECTED_URL" "$f"; then
    red "ERROR: $f does not contain expected download URL: $EXPECTED_URL"
    exit 1
  fi
  if ! grep -q "$EXPECTED_LABEL" "$f"; then
    red "ERROR: $f does not contain expected label: $EXPECTED_LABEL"
    exit 1
  fi
done

git add README.md docs/index.html
if ! git diff --staged --quiet; then
  git commit -m "docs: update download links for ${VERSION}"
  retry git push origin HEAD:main
else
  yellow "No README/docs link changes to commit."
fi

# (labels/filenames normalized and validated above)

# Always update the tap via GitHub API (no local clone required)
if [[ "${UPDATE_CASK}" == "1" ]]; then
  green "==> Updating Homebrew cask in jazzyalex/homebrew-agent-sessions"
  CASK_REPO=${CASK_REPO:-"jazzyalex/homebrew-agent-sessions"}
  CASK_PATH="Casks/agent-sessions.rb"

  # Compose cask content (use placeholders to avoid accidental interpolation)
  CASK_FILE=$(mktemp)
  cat >"$CASK_FILE" <<'CASK'
cask "agent-sessions" do
  version "__VERSION__"
  sha256 "__SHA__"

  url "https://github.com/jazzyalex/agent-sessions/releases/download/v#{version}/AgentSessions-#{version}.dmg",
      verified: "github.com/jazzyalex/agent-sessions/"
  name "Agent Sessions"
  desc "Unified session browser for Codex CLI, Claude Code, and Gemini CLI (read-only)"
  homepage "https://jazzyalex.github.io/agent-sessions/"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"

  app "AgentSessions.app", target: "AgentSessions.app"

  zap trash: [
    "~/Library/Application Support/Agent Sessions",
    "~/Library/Preferences/com.triada.AgentSessions.plist",
    "~/Library/Saved Application State/com.triada.AgentSessions.savedState",
  ]
end
CASK

  # Replace placeholders
  sed -i '' -e "s/__VERSION__/${VERSION}/g" -e "s/__SHA__/${SHA}/g" "$CASK_FILE"

  # Base64 encode the content without newlines
  B64=$(base64 <"$CASK_FILE" | tr -d '\n')

  # Get current file sha if exists
  CURR_SHA=$(retry gh api -H "Accept: application/vnd.github+json" \
    "/repos/${CASK_REPO}/contents/${CASK_PATH}" --jq .sha 2>/dev/null || true)

  # Create or update the file on main branch
  if [[ -n "$CURR_SHA" ]]; then
    retry gh api -X PUT -H "Accept: application/vnd.github+json" \
      "/repos/${CASK_REPO}/contents/${CASK_PATH}" \
      -f message="agent-sessions ${VERSION}" \
      -f content="$B64" \
      -f branch=main \
      -f sha="$CURR_SHA" >/dev/null
  else
    retry gh api -X PUT -H "Accept: application/vnd.github+json" \
      "/repos/${CASK_REPO}/contents/${CASK_PATH}" \
      -f message="agent-sessions ${VERSION}" \
      -f content="$B64" \
      -f branch=main >/dev/null
  fi

  # Wait for GitHub API propagation
  echo "Waiting for Homebrew cask propagation..."
  log INFO "Checking Homebrew cask version propagation"

  for i in {1..20}; do
    CASK_VERSION=$(retry gh api -H "Accept: application/vnd.github+json" \
      "/repos/${CASK_REPO}/contents/${CASK_PATH}" --jq .content 2>/dev/null | tr -d '\n' | base64 --decode | grep 'version' | cut -d'"' -f2 || echo "")
    if [[ "$CASK_VERSION" == "$VERSION" ]]; then
      green "✓ Cask propagated to version $VERSION after $((i*2))s"
      break
    fi
    sleep 2
  done

  if [[ "$CASK_VERSION" != "$VERSION" ]]; then
    yellow "WARNING: Cask version did not propagate to $VERSION in 40s (got: $CASK_VERSION)"
  fi

  # Validate cask update via API (avoids raw cache)
  CASK_BODY=$(retry gh api -H "Accept: application/vnd.github+json" \
    "/repos/${CASK_REPO}/contents/${CASK_PATH}" --jq .content | tr -d '\n' | base64 --decode)
  if ! printf "%s" "$CASK_BODY" | grep -q "version \"${VERSION}\""; then
    red "ERROR: Homebrew cask did not update to version ${VERSION}"
    exit 1
  fi
fi

green "==> Creating or updating GitHub Release"
# Build release notes if none provided
TMP_NOTES=""
if [[ -z "${NOTES_FILE}" ]]; then
  if [[ -f "$REPO_ROOT/docs/CHANGELOG.md" ]]; then
    TMP_NOTES=$(mktemp)
    awk -v ver="$VERSION" '
      BEGIN{insec=0}
      /^##[ ]*\[?'"$VERSION"'\]?([ )-]|$)/ {insec=1; next}
      /^##[ ]/ && insec==1 {insec=0}
      insec==1 {print}
    ' "$REPO_ROOT/docs/CHANGELOG.md" > "$TMP_NOTES" || true
    if [[ ! -s "$TMP_NOTES" ]]; then rm -f "$TMP_NOTES"; TMP_NOTES=""; fi
  fi
  if [[ -z "$TMP_NOTES" ]]; then
    TMP_NOTES=$(mktemp)
    prev=$(git tag --sort=-version:refname | grep -E '^v[0-9]+' | grep -v "^$TAG$" | head -n1 || true)
    if [[ -n "$prev" ]]; then
      echo "Changes since $prev:" > "$TMP_NOTES"
      git log --pretty='- %s' "$prev..HEAD" >> "$TMP_NOTES"
    else
      echo "Recent changes:" > "$TMP_NOTES"
      git log -n 50 --pretty='- %s' >> "$TMP_NOTES"
    fi
  fi
  NOTES_FILE="$TMP_NOTES"
fi
if gh release view "$TAG" >/dev/null 2>&1; then
  log INFO "Release $TAG already exists, updating assets"
  yellow "Release $TAG already exists, updating assets..."
  retry gh release upload "$TAG" "$DMG" "$DMG.sha256" --clobber
  if [[ -n "${NOTES_FILE}" ]]; then
    log INFO "Updating release notes"
    retry gh release edit "$TAG" --notes-file "$NOTES_FILE"
  fi
  green "✓ Release $TAG updated (idempotent)"
else
  log INFO "Creating new release $TAG"
  if [[ -n "${NOTES_FILE}" ]]; then
    retry gh release create "$TAG" "$DMG" "$DMG.sha256" --title "Agent Sessions ${VERSION}" --notes-file "$NOTES_FILE"
  else
    retry gh release create "$TAG" "$DMG" "$DMG.sha256" --title "Agent Sessions ${VERSION}" --notes "Release ${VERSION}"
  fi
  green "✓ Release $TAG created"
fi

green "==> Running post-deployment verification"
echo ""

# Run automated verification
if [[ -x "$REPO_ROOT/tools/release/verify-deployment.sh" ]]; then
  if "$REPO_ROOT/tools/release/verify-deployment.sh" "$VERSION"; then
    green "✓ All automated checks passed"
  else
    red "❌ Some verification checks failed"
    log ERROR "Deployment verification failed for version $VERSION"
    echo ""

    # Auto-rollback prompt
    if [[ -x "$REPO_ROOT/tools/release/rollback-release.sh" ]]; then
      if [[ "${SKIP_CONFIRM}" == "1" ]]; then
        yellow "SKIP_CONFIRM=1 set, skipping auto-rollback prompt"
        yellow "Manual rollback: tools/release/rollback-release.sh $VERSION"
        exit 1
      fi

      read -p "Deployment failed. Rollback release $VERSION? [Y/n] " -n 1 -r
      echo
      if [[ $REPLY =~ ^[Yy]$ ]] || [[ -z $REPLY ]]; then
        log INFO "Initiating automatic rollback for version $VERSION"
        "$REPO_ROOT/tools/release/rollback-release.sh" "$VERSION"
        red "Deployment rolled back. Fix issues and retry."
        exit 1
      else
        yellow "Rollback skipped. Manual rollback: tools/release/rollback-release.sh $VERSION"
        exit 1
      fi
    else
      yellow "Rollback script not found. Manual cleanup required."
      exit 1
    fi
  fi
else
  yellow "WARNING: verify-deployment.sh not found or not executable"
fi

echo ""
green "Done."
echo
green "==> Post-deployment reminders"
echo "1. Verify GitHub Release: https://github.com/jazzyalex/agent-sessions/releases/tag/${TAG}"
echo "2. Verify Sparkle appcast: https://jazzyalex.github.io/agent-sessions/appcast.xml"
echo "   - Check <sparkle:version> matches ${VERSION}"
echo "   - Verify <enclosure url> points to correct DMG"
echo "   - Confirm <sparkle:edSignature> is present"
echo "3. Test DMG download and installation on a clean system"
echo "4. Verify Gatekeeper acceptance: right-click → Open on fresh macOS"
echo "5. Test Homebrew installation: brew upgrade agent-sessions"
echo "6. Test Sparkle auto-update (if existing version installed):"
echo "   - defaults delete com.triada.AgentSessions SULastCheckTime"
echo "   - Launch app and check for update notification"
echo "7. Update marketing materials if needed"
echo "8. Announce release in relevant channels"
echo "9. Monitor for installation issues in the first 24 hours"
echo
