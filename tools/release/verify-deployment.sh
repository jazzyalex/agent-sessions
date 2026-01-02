#!/usr/bin/env bash
set -euo pipefail

# verify-deployment.sh
# Automated post-deployment verification for Agent Sessions releases
# Usage: verify-deployment.sh VERSION

REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$REPO_ROOT"

VERSION=${1:-}
[[ -n "$VERSION" ]] || { echo "Usage: verify-deployment.sh VERSION (e.g., 2.7.1)"; exit 1; }

TAG="v$VERSION"
ERRORS=0
WARNINGS=0

green(){ printf "\033[32m✅ %s\033[0m\n" "$*"; }
yellow(){ printf "\033[33m⚠️  %s\033[0m\n" "$*"; }
red(){ printf "\033[31m❌ %s\033[0m\n" "$*"; }

# Dependency validation
for cmd in git gh curl grep base64; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    red "Required command not found: $cmd"
    exit 2
  fi
done

check() {
    local name="$1"
    local command="$2"
    local required="${3:-true}"

    if eval "$command" >/dev/null 2>&1; then
        green "$name"
    else
        if [[ "$required" == "true" ]]; then
            red "$name"
            ((ERRORS++))
        else
            yellow "$name (optional check failed)"
            ((WARNINGS++))
        fi
    fi
}

check_output() {
    local name="$1"
    local command="$2"
    local expected="$3"
    local required="${4:-true}"

    local output
    output=$(eval "$command" 2>/dev/null || echo "")

    if echo "$output" | grep -q "$expected"; then
        green "$name"
    else
        if [[ "$required" == "true" ]]; then
            red "$name (expected: $expected, got: $output)"
            ((ERRORS++))
        else
            yellow "$name (expected: $expected, got: $output)"
            ((WARNINGS++))
        fi
    fi
}

echo "==> Verifying deployment for Agent Sessions $VERSION"
echo ""

# 1. GitHub Release checks
echo "GitHub Release:"
check "Release exists" "gh release view $TAG"
check "DMG asset uploaded" "gh release view $TAG --json assets -q '.assets[].name' | grep -q 'AgentSessions-$VERSION.dmg'"
check "SHA256 asset uploaded" "gh release view $TAG --json assets -q '.assets[].name' | grep -q 'AgentSessions-$VERSION.dmg.sha256'"
check_output "Release has notes" "gh release view $TAG --json body -q '.body'" "."

echo ""

# 2. Sparkle appcast checks
echo "Sparkle Appcast:"
check "Appcast is accessible" "curl -sf https://jazzyalex.github.io/agent-sessions/appcast.xml"
check_output "Appcast has correct version" "curl -sf https://jazzyalex.github.io/agent-sessions/appcast.xml | grep -o '<sparkle:shortVersionString>[^<]*' | head -1" "$VERSION"
check "Appcast has EdDSA signature" "curl -sf https://jazzyalex.github.io/agent-sessions/appcast.xml | grep -q 'sparkle:edSignature'"
check_output "Appcast URL points to GitHub Releases" "curl -sf https://jazzyalex.github.io/agent-sessions/appcast.xml | grep 'enclosure url'" "github.com/jazzyalex/agent-sessions/releases"
check "Appcast has release notes" "curl -sf https://jazzyalex.github.io/agent-sessions/appcast.xml | grep -q '<description>'"

echo ""

# 3. Build number check
echo "Build Number:"
BUILD_NUMBER=$(curl -sf https://jazzyalex.github.io/agent-sessions/appcast.xml | grep -o '<sparkle:version>[^<]*' | head -1 | cut -d'>' -f2)
if [[ -n "$BUILD_NUMBER" ]] && [[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
    green "Build number is $BUILD_NUMBER"
else
    red "Build number missing or invalid: $BUILD_NUMBER"
    ((ERRORS++))
fi

echo ""

# 4. Documentation checks
echo "Documentation:"
check "README.md links updated" "grep -q 'releases/download/v$VERSION/AgentSessions-$VERSION.dmg' README.md"
check_output "README.md button label updated" "grep -o 'Download Agent Sessions [0-9.]*' README.md | head -1" "$VERSION"
check "docs/index.html links updated" "grep -q 'releases/download/v$VERSION/AgentSessions-$VERSION.dmg' docs/index.html"
check_output "docs/index.html button label updated" "grep -o 'Download Agent Sessions [0-9.]*' docs/index.html | head -1" "$VERSION"

echo ""

# 5. Homebrew cask check
echo "Homebrew Cask:"
CASK_VERSION=$(gh api -H "Accept: application/vnd.github+json" "/repos/jazzyalex/homebrew-agent-sessions/contents/Casks/agent-sessions.rb" --jq '.content' 2>/dev/null | tr -d '\n' | base64 --decode | grep -E '^[[:space:]]*version "' | head -1 | cut -d'"' -f2 || echo "")
if [[ "$CASK_VERSION" == "$VERSION" ]]; then
    green "Cask version is $VERSION"
else
    red "Cask version is $CASK_VERSION (expected $VERSION)"
    ((ERRORS++))
fi

CASK_URL=$(gh api -H "Accept: application/vnd.github+json" "/repos/jazzyalex/homebrew-agent-sessions/contents/Casks/agent-sessions.rb" --jq '.content' 2>/dev/null | tr -d '\n' | base64 --decode | grep 'url' | head -1 || echo "")
if echo "$CASK_URL" | grep -q "v#{version}/AgentSessions-#{version}.dmg"; then
    green "Cask URL template correct"
else
    yellow "Cask URL may need review: $CASK_URL"
    ((WARNINGS++))
fi

echo ""

# 6. DMG download check
echo "DMG Download:"
DMG_URL="https://github.com/jazzyalex/agent-sessions/releases/download/v$VERSION/AgentSessions-$VERSION.dmg"
if curl -fsSLI "$DMG_URL" >/dev/null 2>&1; then
    green "DMG is downloadable"

    # Check DMG size (should be > 1MB)
    DMG_SIZE=$(curl -fsSLI "$DMG_URL" | awk 'tolower($1)=="content-length:"{print $2}' | tr -d '\r' | tail -1 || echo "0")
    if [[ "$DMG_SIZE" -gt 1048576 ]]; then
        green "DMG size is reasonable ($(numfmt --to=iec $DMG_SIZE 2>/dev/null || echo $DMG_SIZE bytes))"
    else
        yellow "DMG size seems small: $DMG_SIZE bytes"
        ((WARNINGS++))
    fi
else
    red "DMG is not downloadable (HTTP error)"
    ((ERRORS++))
fi

echo ""

# 7. SHA256 verification (if local DMG exists)
echo "SHA256 Verification:"
if [[ -f "dist/AgentSessions-$VERSION.dmg" ]]; then
    LOCAL_SHA=$(shasum -a 256 "dist/AgentSessions-$VERSION.dmg" | awk '{print $1}')
    REMOTE_SHA=$(curl -fsSL "https://github.com/jazzyalex/agent-sessions/releases/download/v$VERSION/AgentSessions-$VERSION.dmg.sha256" | awk '{print $1}' || echo "")

    if [[ "$LOCAL_SHA" == "$REMOTE_SHA" ]]; then
        green "SHA256 matches (${LOCAL_SHA:0:16}...)"
    else
        red "SHA256 mismatch. Local: $LOCAL_SHA, Remote: $REMOTE_SHA"
        ((ERRORS++))
    fi
else
    yellow "Local DMG not found at dist/AgentSessions-$VERSION.dmg (skipping SHA256 check)"
    ((WARNINGS++))
fi

echo ""

# 8. Git tag check
echo "Git Tags:"
if git tag | grep -q "^$TAG$"; then
    green "Local tag $TAG exists"
else
    yellow "Local tag $TAG not found"
    ((WARNINGS++))
fi

if git ls-remote --tags origin | grep -q "refs/tags/$TAG$"; then
    green "Remote tag $TAG exists"
else
    red "Remote tag $TAG not found"
    ((ERRORS++))
fi

echo ""

# Summary
echo "==> Verification Summary"
echo "Errors:   $ERRORS"
echo "Warnings: $WARNINGS"
echo ""

if [[ $ERRORS -eq 0 ]]; then
    green "All critical checks passed!"
    if [[ $WARNINGS -gt 0 ]]; then
        yellow "Review $WARNINGS warning(s) above"
    fi
    echo ""
    echo "Manual verification steps:"
    echo "  1. Download and test DMG: $DMG_URL"
    echo "  2. Test Sparkle auto-update from previous version"
    echo "  3. Test Homebrew installation: brew upgrade agent-sessions"
    echo "  4. Monitor GitHub release downloads and issues"
    exit 0
else
    red "Deployment verification FAILED with $ERRORS error(s)"
    echo ""
    echo "Recommended actions:"
    echo "  1. Review errors above"
    echo "  2. Check deployment logs: /tmp/deploy-$VERSION.log"
    echo "  3. Consider rollback: tools/release/rollback-release.sh $VERSION"
    exit 1
fi
