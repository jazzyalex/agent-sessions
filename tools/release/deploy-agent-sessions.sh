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

echo "==> Pre-checks"
command -v xcodebuild >/dev/null || { red "xcodebuild not found"; exit 2; }
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

    # Copy appcast to docs/ for GitHub Pages
    cp "$UPDATES_DIR/appcast.xml" "$REPO_ROOT/docs/appcast.xml"

    # Commit and push appcast to GitHub Pages
    git add "$REPO_ROOT/docs/appcast.xml" || true
    git commit -m "chore(release): update appcast for ${VERSION}" || true
    git push origin HEAD:main || true

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

git add README.md docs/index.html || true
git commit -m "docs: update download links for ${VERSION}" || true
git push origin HEAD:main || true

# Ensure visible version strings in buttons and file names also updated (no release notes)
sed -i '' -E \
  "s/Download Agent Sessions [0-9.]+/Download Agent Sessions ${VERSION}/g" \
  "$REPO_ROOT/README.md" "$REPO_ROOT/docs/index.html"
sed -i '' -E \
  "s/AgentSessions-[0-9.]+\\.dmg/AgentSessions-${VERSION}.dmg/g" \
  "$REPO_ROOT/README.md"
git diff --quiet README.md docs/index.html || {
  git add README.md docs/index.html || true
  git commit -m "docs: normalize visible version labels to ${VERSION}" || true
  git push origin HEAD:main || true
}

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
  CURR_SHA=$(gh api -H "Accept: application/vnd.github+json" \
    "/repos/${CASK_REPO}/contents/${CASK_PATH}" --jq .sha 2>/dev/null || true)

  # Create or update the file on main branch
  if [[ -n "$CURR_SHA" ]]; then
    gh api -X PUT -H "Accept: application/vnd.github+json" \
      "/repos/${CASK_REPO}/contents/${CASK_PATH}" \
      -f message="agent-sessions ${VERSION}" \
      -f content="$B64" \
      -f branch=main \
      -f sha="$CURR_SHA" >/dev/null
  else
    gh api -X PUT -H "Accept: application/vnd.github+json" \
      "/repos/${CASK_REPO}/contents/${CASK_PATH}" \
      -f message="agent-sessions ${VERSION}" \
      -f content="$B64" \
      -f branch=main >/dev/null
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
  gh release upload "$TAG" "$DMG" "$DMG.sha256" --clobber
  if [[ -n "${NOTES_FILE}" ]]; then gh release edit "$TAG" --notes-file "$NOTES_FILE"; fi
else
  if [[ -n "${NOTES_FILE}" ]]; then
    gh release create "$TAG" "$DMG" "$DMG.sha256" --title "Agent Sessions ${VERSION}" --notes-file "$NOTES_FILE"
  else
    gh release create "$TAG" "$DMG" "$DMG.sha256" --title "Agent Sessions ${VERSION}" --notes "Release ${VERSION}"
  fi
fi

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
