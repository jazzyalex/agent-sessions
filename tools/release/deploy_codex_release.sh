#!/usr/bin/env bash
set -euo pipefail

# deploy_codex_release.sh
# End-to-end release helper for Agent Sessions.
# - Pre-checks (xcodebuild, gh, codesigning identity, notary profile)
# - Build/sign/notarize via build_sign_notarize_release.sh
# - Update README and docs site download links to the new version
# - Optionally update Homebrew tap cask (if present locally)
# - Create/update GitHub Release with assets and notes
#
# No secrets are stored. Notary credentials must be stored via `xcrun notarytool store-credentials`.
# gh must be authenticated via `gh auth login`. Optionally use tools/release/.env (excluded from git) for non-secret defaults.

REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$REPO_ROOT"

ENV_FILE="$REPO_ROOT/tools/release/.env"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

APP_NAME_DEFAULT=$(sed -n 's/.*BuildableName = "\([^"]\+\)\.app".*/\1/p' AgentSessions.xcodeproj/xcshareddata/xcschemes/AgentSessions.xcscheme | head -n1)
APP_NAME=${APP_NAME:-${APP_NAME_DEFAULT:-AgentSessions}}

VERSION=${VERSION:-}
if [[ -z "${VERSION}" ]]; then
  read -r -p "Version to release (e.g., 1.2): " VERSION
fi
TAG=${TAG:-v$VERSION}

TEAM_ID=${TEAM_ID:-}
NOTARY_PROFILE=${NOTARY_PROFILE:-AgentSessionsNotary}
DEV_ID_APP=${DEV_ID_APP:-}
NOTES_FILE=${NOTES_FILE:-}
UPDATE_CASK=${UPDATE_CASK:-1}

green(){ printf "\033[32m%s\033[0m\n" "$*"; }
yellow(){ printf "\033[33m%s\033[0m\n" "$*"; }
red(){ printf "\033[31m%s\033[0m\n" "$*"; }

echo "==> Pre-checks"
command -v xcodebuild >/dev/null || { red "xcodebuild not found"; exit 2; }
command -v gh >/dev/null || { red "gh CLI not found"; exit 2; }
gh auth status >/dev/null 2>&1 || { red "gh not authenticated. Run: gh auth login"; exit 2; }

if ! xcrun notarytool whoami --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
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

echo "App     : $APP_NAME"
echo "Version : $VERSION (tag $TAG)"
echo "Team ID : ${TEAM_ID:-<not set>}"
echo "Dev ID  : $DEV_ID_APP"
echo "Notary  : $NOTARY_PROFILE"

read -r -p "Proceed with build/sign/notarize? [y/N] " go
if [[ "${go:-}" != "y" && "${go:-}" != "Y" ]]; then
  yellow "Aborted by user"
  exit 0
fi

export TEAM_ID NOTARY_PROFILE DEV_ID_APP VERSION TAG

green "==> Building and notarizing"
chmod +x "$REPO_ROOT/tools/release/build_sign_notarize_release.sh"
TEAM_ID="$TEAM_ID" NOTARY_PROFILE="$NOTARY_PROFILE" TAG="$TAG" VERSION="$VERSION" DEV_ID_APP="$DEV_ID_APP" \
  "$REPO_ROOT/tools/release/build_sign_notarize_release.sh"

DMG="$REPO_ROOT/dist/${APP_NAME}-${VERSION}.dmg"
SHA=$(shasum -a 256 "$DMG" | awk '{print $1}')

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

if [[ "${UPDATE_CASK}" == "1" ]] && [[ -d "/opt/homebrew/Library/Taps/jazzyalex/homebrew-agent-sessions/Casks" ]]; then
  CASK="/opt/homebrew/Library/Taps/jazzyalex/homebrew-agent-sessions/Casks/agent-sessions.rb"
  if [[ -f "$CASK" ]]; then
    green "==> Updating local Homebrew cask"
    sed -i '' -E "s/^\s*version \"[0-9.]+\"/  version \"${VERSION}\"/" "$CASK"
    sed -i '' -E "s/^\s*sha256 \"[a-f0-9]+\"/  sha256 \"${SHA}\"/" "$CASK"
    sed -i '' -E "s#AgentSessions(-[0-9.]+)?\.dmg#AgentSessions-${VERSION}.dmg#g" "$CASK"
    (cd "$(dirname "$CASK")/.." && git add "$CASK" && git commit -m "agent-sessions ${VERSION} (cask): update url and sha256" && git push origin HEAD:main) || true
  fi
fi

green "==> Creating or updating GitHub Release"
if gh release view "$TAG" >/dev/null 2>&1; then
  gh release upload "$TAG" "$DMG" "$DMG.sha256" --clobber
  if [[ -n "${NOTES_FILE}" ]]; then
    gh release edit "$TAG" --notes-file "$NOTES_FILE"
  fi
else
  if [[ -n "${NOTES_FILE}" ]]; then
    gh release create "$TAG" "$DMG" "$DMG.sha256" --title "Agent Sessions ${VERSION}" --notes-file "$NOTES_FILE"
  else
    gh release create "$TAG" "$DMG" "$DMG.sha256" --title "Agent Sessions ${VERSION}" --notes "Release ${VERSION}"
  fi
fi

green "Done."
