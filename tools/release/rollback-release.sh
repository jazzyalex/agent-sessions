#!/usr/bin/env bash
set -euo pipefail

# rollback-release.sh
# Rolls back a failed or problematic Agent Sessions release
# Usage: rollback-release.sh VERSION

REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$REPO_ROOT"

VERSION=${1:-}
[[ -n "$VERSION" ]] || { echo "Usage: rollback-release.sh VERSION (e.g., 2.7.1)"; exit 1; }

TAG="v$VERSION"

green(){ printf "\033[32m%s\033[0m\n" "$*"; }
yellow(){ printf "\033[33m%s\033[0m\n" "$*"; }
red(){ printf "\033[31m%s\033[0m\n" "$*"; }

# Dependency validation
for cmd in git gh grep awk base64; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    red "ERROR: Required command not found: $cmd"
    exit 2
  fi
done

echo "==> Rolling back release $VERSION"
echo ""
yellow "WARNING: This will delete the GitHub release and revert commits."
read -p "Are you sure? [y/N] " -n 1 -r
echo
[[ $REPLY =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

ROLLBACK_COUNT=0

# 1. Delete GitHub Release
echo "==> Checking GitHub Release"
if gh release view "$TAG" >/dev/null 2>&1; then
    echo "Deleting GitHub Release $TAG..."
    gh release delete "$TAG" --yes --cleanup-tag
    green "✓ Deleted GitHub Release $TAG"
    ((ROLLBACK_COUNT++))
else
    yellow "- GitHub Release $TAG not found (skip)"
fi

# 2. Delete local git tag
echo "==> Checking local git tag"
if git tag | grep -q "^$TAG$"; then
    echo "Deleting local tag $TAG..."
    git tag -d "$TAG"
    green "✓ Deleted local tag $TAG"
    ((ROLLBACK_COUNT++))
else
    yellow "- Local tag $TAG not found (skip)"
fi

# 3. Delete remote git tag (if exists)
echo "==> Checking remote git tag"
if git ls-remote --tags origin | grep -q "refs/tags/$TAG$"; then
    echo "Deleting remote tag $TAG..."
    git push origin ":refs/tags/$TAG"
    green "✓ Deleted remote tag $TAG"
    ((ROLLBACK_COUNT++))
else
    yellow "- Remote tag $TAG not found (skip)"
fi

# 4. Revert recent commits (appcast, docs updates)
echo "==> Checking recent commits for $VERSION"

# Check last 5 commits for version-related changes
COMMITS_TO_REVERT=()
for commit in $(git log -5 --pretty=format:%H); do
    MSG=$(git log -1 --pretty=%B "$commit")
    if echo "$MSG" | grep -qi "$VERSION"; then
        echo "Found commit: $(git log -1 --oneline "$commit")"
        COMMITS_TO_REVERT+=("$commit")
    fi
done

if [[ ${#COMMITS_TO_REVERT[@]} -gt 0 ]]; then
    echo ""
    echo "The following commits will be reverted:"
    for commit in "${COMMITS_TO_REVERT[@]}"; do
        git log -1 --oneline "$commit"
    done
    echo ""
    read -p "Revert these commits? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        # Revert in reverse order (newest first)
        for commit in "${COMMITS_TO_REVERT[@]}"; do
            git revert --no-edit "$commit" || {
                red "ERROR: Revert conflict. Resolve manually and run: git revert --continue"
                exit 1
            }
        done
        green "✓ Reverted ${#COMMITS_TO_REVERT[@]} commit(s)"
        ((ROLLBACK_COUNT++))

        echo ""
        read -p "Push reverts to origin/main? [y/N] " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            git push origin main
            green "✓ Pushed revert commits"
        else
            yellow "! Revert commits not pushed. Run: git push origin main"
        fi
    else
        yellow "- Commit revert skipped"
    fi
else
    yellow "- No recent commits found for $VERSION"
fi

# 5. Check Homebrew cask (inform only, requires manual API call)
echo "==> Checking Homebrew cask"
CASK_VERSION=$(gh api -H "Accept: application/vnd.github+json" \
    "/repos/jazzyalex/homebrew-agent-sessions/contents/Casks/agent-sessions.rb" \
    --jq '.content' 2>/dev/null | tr -d '\n' | base64 --decode | grep 'version' | cut -d'"' -f2 || echo "unknown")

if [[ "$CASK_VERSION" == "$VERSION" ]]; then
    yellow "! Homebrew cask is at version $VERSION"
    echo "  To rollback cask, you need to:"
    echo "  1. Determine previous version"
    echo "  2. Manually update cask via GitHub API or PR"
    echo "  3. Or wait for next release to overwrite"
else
    green "✓ Homebrew cask is at version $CASK_VERSION (not $VERSION)"
fi

# 6. Check appcast.xml on GitHub Pages
echo "==> Checking Sparkle appcast"
APPCAST_VERSION=$(curl -sf https://jazzyalex.github.io/agent-sessions/appcast.xml | \
    grep -o '<sparkle:shortVersionString>[^<]*' | head -1 | cut -d'>' -f2 || echo "unknown")

if [[ "$APPCAST_VERSION" == "$VERSION" ]]; then
    yellow "! Appcast shows version $VERSION"
    echo "  Appcast will be updated when commits are reverted and pushed"
else
    green "✓ Appcast shows version $APPCAST_VERSION (not $VERSION)"
fi

# Summary
echo ""
echo "==> Rollback summary"
echo "Operations performed: $ROLLBACK_COUNT"
if [[ $ROLLBACK_COUNT -gt 0 ]]; then
    green "✓ Rollback completed"
else
    yellow "! No rollback actions performed (version $VERSION may not exist)"
fi

echo ""
echo "Manual verification steps:"
echo "  1. Check GitHub Releases: https://github.com/jazzyalex/agent-sessions/releases"
echo "  2. Check appcast: https://jazzyalex.github.io/agent-sessions/appcast.xml"
echo "  3. Check Homebrew cask: brew info agent-sessions"
echo "  4. Verify git log: git log --oneline -10"
