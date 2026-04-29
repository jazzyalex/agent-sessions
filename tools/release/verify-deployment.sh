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
TRANSIENT_ERRORS=0
LAST_CHECK_ERROR=""
LAST_CHECK_OUTPUT=""

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

is_transient_error() {
    grep -Eqi 'TLS handshake timeout|i/o timeout|connection timed out|operation timed out|connection reset|connection refused|Could not resolve host|network is unreachable|HTTP status code: 5[0-9][0-9]|502|503|504|temporary failure' <<<"$1"
}

retry_eval() {
    local command="$1"
    local attempts="${2:-3}"
    local sleep_s="${3:-3}"
    local output=""
    local status=0

    LAST_CHECK_ERROR=""
    LAST_CHECK_OUTPUT=""

    for ((attempt=1; attempt<=attempts; attempt++)); do
        output=$(eval "$command" 2>&1)
        status=$?
        if [[ $status -eq 0 ]]; then
            LAST_CHECK_OUTPUT="$output"
            return 0
        fi

        LAST_CHECK_ERROR="$output"
        if [[ $attempt -lt $attempts ]] && is_transient_error "$output"; then
            yellow "Transient verification failure on attempt $attempt/$attempts; retrying in ${sleep_s}s"
            sleep "$sleep_s"
            sleep_s=$((sleep_s * 2))
            continue
        fi

        return "$status"
    done

    return "$status"
}

record_failed_check() {
    local name="$1"
    local required="${2:-true}"
    local detail="${LAST_CHECK_ERROR:-}"

    if [[ "$required" == "true" ]]; then
        if [[ -n "$detail" ]] && is_transient_error "$detail"; then
            red "$name (transient network/API failure after retries: $detail)"
            ((TRANSIENT_ERRORS+=1))
        else
            red "$name"
        fi
        ((ERRORS+=1))
    else
        yellow "$name (optional check failed)"
        ((WARNINGS+=1))
    fi
}

check() {
    local name="$1"
    local command="$2"
    local required="${3:-true}"

    if retry_eval "$command >/dev/null"; then
        green "$name"
    else
        record_failed_check "$name" "$required"
    fi
}

check_output() {
    local name="$1"
    local command="$2"
    local expected="$3"
    local required="${4:-true}"

    local output
    if retry_eval "$command"; then
        output="$LAST_CHECK_OUTPUT"
    else
        output=""
    fi

    if grep -q -- "$expected" <<<"$output"; then
        green "$name"
    else
        if [[ "$required" == "true" ]]; then
            if [[ -n "${LAST_CHECK_ERROR:-}" ]] && is_transient_error "$LAST_CHECK_ERROR"; then
                red "$name (transient network/API failure after retries: $LAST_CHECK_ERROR)"
                ((TRANSIENT_ERRORS+=1))
            else
                red "$name (expected: $expected, got: $output)"
            fi
            ((ERRORS+=1))
        else
            yellow "$name (expected: $expected, got: $output)"
            ((WARNINGS+=1))
        fi
    fi
}

extract_appcast_item() {
    local appcast_file="$1"
    local version="$2"

    awk -v version="$version" '
        BEGIN { RS="</item>"; ORS="</item>\n" }
        index($0, "<sparkle:shortVersionString>" version "</sparkle:shortVersionString>") {
            print
            exit
        }
    ' "$appcast_file"
}

echo "==> Verifying deployment for Agent Sessions $VERSION"
echo ""

# 1. GitHub Release checks
echo "GitHub Release:"
check "Release exists" "gh release view $TAG"
check "DMG asset uploaded" "gh release view $TAG --json assets -q '.assets[].name' | grep -q 'AgentSessions-$VERSION.dmg'"
check "SHA256 asset uploaded" "gh release view $TAG --json assets -q '.assets[].name' | grep -q 'AgentSessions-$VERSION.dmg.sha256'"
check "Release has notes" "gh release view $TAG --json body -q '.body' | grep -q '[^[:space:]]'"

echo ""

# 2. Sparkle appcast checks
echo "Sparkle Appcast:"
APPCAST_URL="https://jazzyalex.github.io/agent-sessions/appcast.xml"
APPCAST_TMP=$(mktemp)
trap 'rm -f "$APPCAST_TMP"' EXIT

if curl -sf "$APPCAST_URL" >"$APPCAST_TMP"; then
    green "Appcast is accessible"
else
    red "Appcast is accessible"
    ((ERRORS+=1))
fi

APPCAST_ITEM=""
if [[ -s "$APPCAST_TMP" ]]; then
    APPCAST_ITEM=$(extract_appcast_item "$APPCAST_TMP" "$VERSION")
fi

if [[ -n "$APPCAST_ITEM" ]]; then
    green "Appcast has exact release item for $VERSION"
else
    red "Appcast has exact release item for $VERSION"
    ((ERRORS+=1))
fi

if [[ -n "$APPCAST_ITEM" ]] && grep -q 'sparkle:edSignature=' <<<"$APPCAST_ITEM"; then
    green "Appcast item has EdDSA signature"
else
    red "Appcast item has EdDSA signature"
    ((ERRORS+=1))
fi

EXPECTED_APPCAST_URL="https://github.com/jazzyalex/agent-sessions/releases/download/v$VERSION/AgentSessions-$VERSION.dmg"
if [[ -n "$APPCAST_ITEM" ]] && grep -Fq "$EXPECTED_APPCAST_URL" <<<"$APPCAST_ITEM"; then
    green "Appcast item points to GitHub Releases"
else
    red "Appcast item points to GitHub Releases"
    ((ERRORS+=1))
fi

if [[ -n "$APPCAST_ITEM" ]] && grep -q '<description' <<<"$APPCAST_ITEM"; then
    green "Appcast item has release notes"
else
    red "Appcast item has release notes"
    ((ERRORS+=1))
fi

echo ""

# 3. Build number check
echo "Build Number:"
BUILD_NUMBER=""
if [[ -n "$APPCAST_ITEM" ]]; then
    BUILD_NUMBER=$(grep -o '<sparkle:version>[^<]*' <<<"$APPCAST_ITEM" | head -1 | cut -d'>' -f2)
fi
if [[ -n "$BUILD_NUMBER" ]] && [[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
    green "Build number is $BUILD_NUMBER"
else
    red "Build number missing or invalid: $BUILD_NUMBER"
    ((ERRORS+=1))
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
CASK_CONTENT=""
if retry_eval "gh api -H 'Accept: application/vnd.github+json' '/repos/jazzyalex/homebrew-agent-sessions/contents/Casks/agent-sessions.rb' --jq '.content' | tr -d '\n' | base64 --decode"; then
    CASK_CONTENT="$LAST_CHECK_OUTPUT"
else
    record_failed_check "Cask content fetched" "true"
fi

if [[ -n "$CASK_CONTENT" ]]; then
    CASK_VERSION=$(grep -E '^[[:space:]]*version "' <<<"$CASK_CONTENT" | head -1 | cut -d'"' -f2 || echo "")
    if [[ "$CASK_VERSION" == "$VERSION" ]]; then
        green "Cask version is $VERSION"
    else
        red "Cask version is $CASK_VERSION (expected $VERSION)"
        ((ERRORS+=1))
    fi

    CASK_URL=$(grep 'url' <<<"$CASK_CONTENT" | head -1 || echo "")
    if echo "$CASK_URL" | grep -q "v#{version}/AgentSessions-#{version}.dmg"; then
        green "Cask URL template correct"
    else
        yellow "Cask URL may need review: $CASK_URL"
        ((WARNINGS+=1))
    fi
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
        ((WARNINGS+=1))
    fi
else
    red "DMG is not downloadable (HTTP error)"
    ((ERRORS+=1))
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
        ((ERRORS+=1))
    fi
else
    yellow "Local DMG not found at dist/AgentSessions-$VERSION.dmg (skipping SHA256 check)"
    ((WARNINGS+=1))
fi

echo ""

# 8. Git tag check
echo "Git Tags:"
REMOTE_TAG_OK=0
if git ls-remote --tags origin | grep -q "refs/tags/$TAG$"; then
    green "Remote tag $TAG exists"
    REMOTE_TAG_OK=1
else
    red "Remote tag $TAG not found"
    ((ERRORS+=1))
fi

if git tag | grep -q "^$TAG$"; then
    green "Local tag $TAG exists"
else
    if [[ "$REMOTE_TAG_OK" == "1" ]]; then
        # GitHub Releases can create tags remotely without a local tag.
        # Fetch the specific tag to avoid spurious warnings.
        git fetch --tags origin "refs/tags/$TAG:refs/tags/$TAG" >/dev/null 2>&1 || true
    fi

    if git tag | grep -q "^$TAG$"; then
        green "Local tag $TAG exists (fetched)"
    else
        yellow "Local tag $TAG not found"
        ((WARNINGS+=1))
    fi
fi

echo ""

# Summary
echo "==> Verification Summary"
echo "Errors:   $ERRORS"
echo "Warnings: $WARNINGS"
if [[ $TRANSIENT_ERRORS -gt 0 ]]; then
    echo "Transient network/API errors: $TRANSIENT_ERRORS"
fi
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
    if [[ $TRANSIENT_ERRORS -gt 0 ]]; then
        echo "  2. Rerun verification before rollback; at least one failure was classified as transient network/API behavior"
        echo "  3. Check deployment logs: /tmp/deploy-$VERSION.log"
    else
        echo "  2. Check deployment logs: /tmp/deploy-$VERSION.log"
        echo "  3. Consider rollback: tools/release/rollback-release.sh $VERSION"
    fi
    exit 1
fi
