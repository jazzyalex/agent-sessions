#!/usr/bin/env bash
set -euo pipefail

# generate-changelog.sh
# Generates CHANGELOG entries from conventional commit messages
# Usage: generate-changelog.sh [FROM_TAG]

REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$REPO_ROOT"

green(){ printf "\033[32m%s\033[0m\n" "$*"; }
yellow(){ printf "\033[33m%s\033[0m\n" "$*"; }
red(){ printf "\033[31m%s\033[0m\n" "$*"; }

FROM_TAG=${1:-}

# Auto-detect last tag if not provided
if [[ -z "$FROM_TAG" ]]; then
  FROM_TAG=$(git tag --sort=-version:refname | grep -E '^v[0-9]' | head -n1)
  if [[ -z "$FROM_TAG" ]]; then
    red "ERROR: No previous tags found and no FROM_TAG specified"
    exit 1
  fi
  yellow "Using last tag: $FROM_TAG"
fi

echo "==> Generating CHANGELOG from $FROM_TAG..HEAD"
echo ""

# Extract conventional commits
FEAT_COMMITS=$(git log --pretty=format:"%s" "$FROM_TAG..HEAD" | grep "^feat:" || true)
FIX_COMMITS=$(git log --pretty=format:"%s" "$FROM_TAG..HEAD" | grep "^fix:" || true)
PERF_COMMITS=$(git log --pretty=format:"%s" "$FROM_TAG..HEAD" | grep "^perf:" || true)
REFACTOR_COMMITS=$(git log --pretty=format:"%s" "$FROM_TAG..HEAD" | grep "^refactor:" || true)
DOCS_COMMITS=$(git log --pretty=format:"%s" "$FROM_TAG..HEAD" | grep "^docs:" || true)
CHORE_COMMITS=$(git log --pretty=format:"%s" "$FROM_TAG..HEAD" | grep "^chore:" || true)

# Count commits by category
FEAT_COUNT=$(echo "$FEAT_COMMITS" | grep -c "^" || echo "0")
FIX_COUNT=$(echo "$FIX_COMMITS" | grep -c "^" || echo "0")
PERF_COUNT=$(echo "$PERF_COMMITS" | grep -c "^" || echo "0")
REFACTOR_COUNT=$(echo "$REFACTOR_COMMITS" | grep -c "^" || echo "0")
DOCS_COUNT=$(echo "$DOCS_COMMITS" | grep -c "^" || echo "0")
CHORE_COUNT=$(echo "$CHORE_COMMITS" | grep -c "^" || echo "0")

echo "Commit breakdown:"
echo "  Features:     $FEAT_COUNT"
echo "  Fixes:        $FIX_COUNT"
echo "  Performance:  $PERF_COUNT"
echo "  Refactoring:  $REFACTOR_COUNT"
echo "  Docs:         $DOCS_COUNT"
echo "  Chores:       $CHORE_COUNT"
echo ""

# Generate CHANGELOG content
OUTPUT=""

if [[ -n "$FEAT_COMMITS" ]]; then
  OUTPUT+="### Added\n"
  while IFS= read -r commit; do
    # Extract message after "feat:" or "feat(scope):"
    MSG=$(echo "$commit" | sed -E 's/^feat(\([^)]+\))?:[[:space:]]*//')
    OUTPUT+="- $MSG\n"
  done <<< "$FEAT_COMMITS"
  OUTPUT+="\n"
fi

if [[ -n "$FIX_COMMITS" ]]; then
  OUTPUT+="### Fixed\n"
  while IFS= read -r commit; do
    MSG=$(echo "$commit" | sed -E 's/^fix(\([^)]+\))?:[[:space:]]*//')
    OUTPUT+="- $MSG\n"
  done <<< "$FIX_COMMITS"
  OUTPUT+="\n"
fi

if [[ -n "$PERF_COMMITS" ]]; then
  OUTPUT+="### Performance\n"
  while IFS= read -r commit; do
    MSG=$(echo "$commit" | sed -E 's/^perf(\([^)]+\))?:[[:space:]]*//')
    OUTPUT+="- $MSG\n"
  done <<< "$PERF_COMMITS"
  OUTPUT+="\n"
fi

if [[ -n "$REFACTOR_COMMITS" ]]; then
  OUTPUT+="### Refactoring\n"
  while IFS= read -r commit; do
    MSG=$(echo "$commit" | sed -E 's/^refactor(\([^)]+\))?:[[:space:]]*//')
    OUTPUT+="- $MSG\n"
  done <<< "$REFACTOR_COMMITS"
  OUTPUT+="\n"
fi

if [[ -n "$DOCS_COMMITS" ]]; then
  OUTPUT+="### Documentation\n"
  while IFS= read -r commit; do
    MSG=$(echo "$commit" | sed -E 's/^docs(\([^)]+\))?:[[:space:]]*//')
    OUTPUT+="- $MSG\n"
  done <<< "$DOCS_COMMITS"
  OUTPUT+="\n"
fi

# Don't show chores by default (too noisy)
# if [[ -n "$CHORE_COMMITS" ]]; then
#   OUTPUT+="### Chores\n"
#   while IFS= read -r commit; do
#     MSG=$(echo "$commit" | sed -E 's/^chore(\([^)]+\))?:[[:space:]]*//')
#     OUTPUT+="- $MSG\n"
#   done <<< "$CHORE_COMMITS"
#   OUTPUT+="\n"
# fi

if [[ -z "$OUTPUT" ]]; then
  yellow "No conventional commits found. Showing all commits instead:"
  echo ""
  git log --pretty='- %s' "$FROM_TAG..HEAD"
  exit 0
fi

green "==> Generated CHANGELOG:"
echo ""
echo -e "$OUTPUT"

# Offer to save to file
echo ""
read -p "Save to CHANGELOG snippet file? [y/N] " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
  SNIPPET_FILE="/tmp/changelog-snippet-$(date +%s).md"
  echo -e "$OUTPUT" > "$SNIPPET_FILE"
  green "✓ Saved to $SNIPPET_FILE"
  echo ""
  echo "You can now copy this content into docs/CHANGELOG.md under the [Unreleased] section"
  echo "or run: cat $SNIPPET_FILE >> docs/CHANGELOG.md"
fi
