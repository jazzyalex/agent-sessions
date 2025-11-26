#!/usr/bin/env bash
set -euo pipefail

# bump-version.sh
# Automates version bumping and CHANGELOG management for Agent Sessions releases
# Usage: bump-version.sh [major|minor|patch]

REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$REPO_ROOT"

BUMP_TYPE=${1:-patch}
[[ "$BUMP_TYPE" =~ ^(major|minor|patch)$ ]] || { echo "Usage: bump-version.sh [major|minor|patch]"; exit 1; }

green(){ printf "\033[32m%s\033[0m\n" "$*"; }
yellow(){ printf "\033[33m%s\033[0m\n" "$*"; }
red(){ printf "\033[31m%s\033[0m\n" "$*"; }

# Dependency validation
for cmd in git grep sed awk python3; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    red "ERROR: Required command not found: $cmd"
    exit 2
  fi
done

if ! python3 -c "import sys" 2>/dev/null; then
  red "ERROR: python3 not working properly"
  exit 2
fi

echo "==> Version Bump: $BUMP_TYPE"

# 1. Detect current version
CURR_MARKETING=$(grep -m1 "MARKETING_VERSION = " AgentSessions.xcodeproj/project.pbxproj | sed 's/.*= \([^;]*\);/\1/' | tr -d ' ')
CURR_BUILD=$(grep -m1 "CURRENT_PROJECT_VERSION = " AgentSessions.xcodeproj/project.pbxproj | sed 's/.*= \([^;]*\);/\1/' | tr -d ' ')

echo "Current version: $CURR_MARKETING (build $CURR_BUILD)"

# 2. Calculate new version using Python
NEW_VERSION=$(python3 << PYEOF
import sys
version = "$CURR_MARKETING".split('.')
major, minor = int(version[0]), int(version[1])
patch = int(version[2]) if len(version) > 2 else 0

if "$BUMP_TYPE" == "major":
    major += 1
    minor = 0
    patch = 0
elif "$BUMP_TYPE" == "minor":
    minor += 1
    patch = 0
elif "$BUMP_TYPE" == "patch":
    patch += 1

print(f"{major}.{minor}.{patch}")
PYEOF
)

# 3. Auto-increment build number
NEW_BUILD=$((CURR_BUILD + 1))

echo "New version: $NEW_VERSION (build $NEW_BUILD)"

# 4. Update project.pbxproj (all occurrences)
echo "==> Updating AgentSessions.xcodeproj/project.pbxproj"
sed -i '' "s/CURRENT_PROJECT_VERSION = $CURR_BUILD;/CURRENT_PROJECT_VERSION = $NEW_BUILD;/g" AgentSessions.xcodeproj/project.pbxproj
sed -i '' "s/MARKETING_VERSION = $CURR_MARKETING;/MARKETING_VERSION = $NEW_VERSION;/g" AgentSessions.xcodeproj/project.pbxproj

# Verify replacements
COUNT_BUILD=$(grep -c "CURRENT_PROJECT_VERSION = $NEW_BUILD;" AgentSessions.xcodeproj/project.pbxproj || true)
COUNT_VERSION=$(grep -c "MARKETING_VERSION = $NEW_VERSION;" AgentSessions.xcodeproj/project.pbxproj || true)

if [[ $COUNT_BUILD -ne 2 || $COUNT_VERSION -ne 2 ]]; then
    red "ERROR: Version replacement failed. Expected 2 occurrences each, got BUILD=$COUNT_BUILD VERSION=$COUNT_VERSION"
    exit 1
fi
green "✓ Updated 2 CURRENT_PROJECT_VERSION and 2 MARKETING_VERSION entries"

# 5. Update CHANGELOG.md: Move [Unreleased] to [NEW_VERSION]
echo "==> Updating docs/CHANGELOG.md"
TODAY=$(date +%Y-%m-%d)

# Check if version already exists
if grep -q "^## \[$NEW_VERSION\]" docs/CHANGELOG.md; then
    yellow "WARNING: Version $NEW_VERSION already exists in CHANGELOG.md"
    read -p "Continue anyway? [y/N] " -n 1 -r
    echo
    [[ $REPLY =~ ^[Yy]$ ]] || exit 1
fi

# Use awk to insert new version section after [Unreleased] and restore empty [Unreleased]
awk -v ver="$NEW_VERSION" -v date="$TODAY" '
/^## \[Unreleased\]/ {
    print
    print ""
    print "## [" ver "] - " date
    in_unreleased = 1
    next
}
/^## \[/ && in_unreleased {
    print ""
    print "## [Unreleased]"
    print ""
    in_unreleased = 0
}
{ print }
' docs/CHANGELOG.md > docs/CHANGELOG.md.tmp && mv docs/CHANGELOG.md.tmp docs/CHANGELOG.md

# Verify CHANGELOG has new section
if ! grep -q "^## \[$NEW_VERSION\] - $TODAY" docs/CHANGELOG.md; then
    red "ERROR: Failed to update CHANGELOG.md"
    exit 1
fi
green "✓ Added [${NEW_VERSION}] section to CHANGELOG.md"

# 6. Show diff for review
echo ""
echo "==> Changes to be committed:"
git diff AgentSessions.xcodeproj/project.pbxproj docs/CHANGELOG.md | head -50

# 7. Confirm before committing
echo ""
read -p "Commit these changes? [y/N] " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    yellow "Aborted. Run 'git checkout AgentSessions.xcodeproj/project.pbxproj docs/CHANGELOG.md' to revert."
    exit 1
fi

# 8. Git commit
echo "==> Creating git commit"
git add AgentSessions.xcodeproj/project.pbxproj docs/CHANGELOG.md

# Read actual changes from CHANGELOG for commit message
CHANGELOG_EXCERPT=$(sed -n "/^## \[$NEW_VERSION\]/,/^## \[/{/^## \[/d; p;}" docs/CHANGELOG.md | head -15)

git commit -m "chore: bump version to $NEW_VERSION (build $NEW_BUILD)

Build number: $CURR_BUILD → $NEW_BUILD
Marketing version: $CURR_MARKETING → $NEW_VERSION

Release highlights:
$CHANGELOG_EXCERPT

Tool: Claude Code
Model: Sonnet 4.5
Why: Version bump for $NEW_VERSION release"

green "✓ Version bump committed"
echo ""
echo "Next steps:"
echo "  1. Review commit: git show HEAD"
echo "  2. Push to GitHub: git push origin main"
echo "  3. Deploy: VERSION=$NEW_VERSION SKIP_CONFIRM=1 tools/release/deploy-agent-sessions.sh"
