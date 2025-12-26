#!/bin/bash
# validate-release.sh - Pre-deployment validation for Agent Sessions
#
# Usage: validate-release.sh VERSION
#
# Validates documentation, version format, and consistency before deployment.
# Exit codes: 0 = pass, 1 = warnings only, 2 = errors (should not deploy)

set -euo pipefail

VERSION="${1:-}"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# Colors
red()    { echo -e "\033[31m$*\033[0m"; }
yellow() { echo -e "\033[33m$*\033[0m"; }
green()  { echo -e "\033[32m$*\033[0m"; }
blue()   { echo -e "\033[34m$*\033[0m"; }

# Counters
ERRORS=0
WARNINGS=0

error() {
  red "❌ ERROR: $*"
  ((ERRORS++)) || true
}

warn() {
  yellow "⚠️  WARNING: $*"
  ((WARNINGS++)) || true
}

pass() {
  green "✓ $*"
}

info() {
  blue "ℹ️  $*"
}

# Canonical agent list
AGENTS=("Codex CLI" "Claude Code" "Gemini CLI" "GitHub Copilot CLI" "OpenCode")

usage() {
  echo "Usage: $0 VERSION"
  echo ""
  echo "Pre-deployment validation for Agent Sessions."
  echo ""
  echo "Checks:"
  echo "  - Version format (warns on trailing .0)"
  echo "  - README.md download links and content"
  echo "  - docs/index.html download links and meta tags"
  echo "  - docs/CHANGELOG.md version section"
  echo "  - Agent list consistency across all files"
  echo ""
  echo "Exit codes:"
  echo "  0 = All checks passed"
  echo "  1 = Warnings only (can proceed with caution)"
  echo "  2 = Errors found (should not deploy)"
  exit 1
}

if [[ -z "$VERSION" ]]; then
  usage
fi

echo ""
blue "═══════════════════════════════════════════════════════════"
blue "  Agent Sessions Pre-Deployment Validation"
blue "  Version: $VERSION"
blue "═══════════════════════════════════════════════════════════"
echo ""

# =============================================================================
# 1. Version Format Check
# =============================================================================
echo "==> Checking version format..."

if [[ "$VERSION" =~ \.0$ ]]; then
  warn "Version '$VERSION' ends with .0 - prefer format without trailing zero (e.g., '2.9' not '2.9.0')"
else
  pass "Version format OK: $VERSION"
fi

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
  error "Version '$VERSION' does not match expected format (X.Y or X.Y.Z)"
fi

echo ""

# =============================================================================
# 2. README.md Validation
# =============================================================================
echo "==> Checking README.md..."

README="$REPO_ROOT/README.md"
if [[ ! -f "$README" ]]; then
  error "README.md not found"
else
  # Check download link
  if grep -q "releases/download/v${VERSION}/AgentSessions-${VERSION}.dmg" "$README"; then
    pass "README download link has correct version"
  else
    error "README download link missing or wrong version (expected v${VERSION})"
  fi

  # Check download button text
  if grep -q "Download Agent Sessions ${VERSION}" "$README"; then
    pass "README download button text has correct version"
  else
    error "README download button text missing or wrong version"
  fi

  # Check "What's New" section
  # Extract major.minor for section check (2.9.1 -> 2.9, 2.9 -> 2.9)
  if [[ "$VERSION" =~ ^([0-9]+\.[0-9]+)\.[0-9]+$ ]]; then
    # Three-part version: extract first two parts
    MAJOR_MINOR="${BASH_REMATCH[1]}"
  else
    # Two-part version: use as-is
    MAJOR_MINOR="$VERSION"
  fi
  if grep -q "## What's New in ${MAJOR_MINOR}" "$README"; then
    pass "README has 'What's New in ${MAJOR_MINOR}' section"
  else
    error "README missing 'What's New in ${MAJOR_MINOR}' section"
  fi

  # Check for version gaps in "What's New" sections
  # Extract all "What's New in X.Y" versions
  WHATS_NEW_VERSIONS=$(grep -oE "## What's New in [0-9]+\.[0-9]+" "$README" | grep -oE "[0-9]+\.[0-9]+" | sort -V)
  if [[ -n "$WHATS_NEW_VERSIONS" ]]; then
    PREV_MINOR=""
    for v in $WHATS_NEW_VERSIONS; do
      if [[ -n "$PREV_MINOR" ]]; then
        PREV_MAJOR=$(echo "$PREV_MINOR" | cut -d. -f1)
        PREV_MIN=$(echo "$PREV_MINOR" | cut -d. -f2)
        CURR_MAJOR=$(echo "$v" | cut -d. -f1)
        CURR_MIN=$(echo "$v" | cut -d. -f2)

        if [[ "$PREV_MAJOR" == "$CURR_MAJOR" ]]; then
          EXPECTED_MIN=$((PREV_MIN + 1))
          if [[ "$CURR_MIN" -gt "$EXPECTED_MIN" ]]; then
            warn "README may be missing 'What's New' sections between ${PREV_MINOR} and ${v}"
          fi
        fi
      fi
      PREV_MINOR="$v"
    done
  fi

  # Check agent mentions in overview
  for agent in "${AGENTS[@]}"; do
    if grep -q "$agent" "$README"; then
      pass "README mentions: $agent"
    else
      warn "README may be missing agent: $agent"
    fi
  done
fi

echo ""

# =============================================================================
# 3. docs/index.html Validation
# =============================================================================
echo "==> Checking docs/index.html..."

INDEX="$REPO_ROOT/docs/index.html"
if [[ ! -f "$INDEX" ]]; then
  error "docs/index.html not found"
else
  # Check download link
  if grep -q "releases/download/v${VERSION}/AgentSessions-${VERSION}.dmg" "$INDEX"; then
    pass "index.html download link has correct version"
  else
    error "index.html download link missing or wrong version"
  fi

  # Check download button text
  if grep -q "Download Agent Sessions ${VERSION}" "$INDEX"; then
    pass "index.html download button text has correct version"
  else
    error "index.html download button text missing or wrong version"
  fi

  # Check <title> tag for agents
  TITLE_LINE=$(grep -i "<title>" "$INDEX" || echo "")
  TITLE_AGENTS_MISSING=0
  for agent in "Codex" "Claude" "Gemini" "Copilot"; do
    if ! echo "$TITLE_LINE" | grep -qi "$agent"; then
      warn "index.html <title> may be missing: $agent"
      ((TITLE_AGENTS_MISSING++)) || true
    fi
  done
  if [[ "$TITLE_AGENTS_MISSING" -eq 0 ]]; then
    pass "index.html <title> mentions all major agents"
  fi

  # Check twitter:title meta tag
  if grep -q 'name="twitter:title"' "$INDEX"; then
    TWITTER_TITLE=$(grep 'name="twitter:title"' "$INDEX")
    TWITTER_MISSING=0
    for agent in "Codex" "Claude" "Gemini" "Copilot"; do
      if ! echo "$TWITTER_TITLE" | grep -qi "$agent"; then
        ((TWITTER_MISSING++)) || true
      fi
    done
    if [[ "$TWITTER_MISSING" -gt 0 ]]; then
      warn "index.html twitter:title may be missing some agents"
    else
      pass "index.html twitter:title mentions all major agents"
    fi
  fi

  # Check og:description meta tag exists
  if grep -q 'property="og:description"' "$INDEX"; then
    pass "index.html has og:description meta tag"
  else
    warn "index.html missing og:description meta tag"
  fi
fi

echo ""

# =============================================================================
# 4. CHANGELOG.md Validation
# =============================================================================
echo "==> Checking docs/CHANGELOG.md..."

CHANGELOG="$REPO_ROOT/docs/CHANGELOG.md"
if [[ ! -f "$CHANGELOG" ]]; then
  error "docs/CHANGELOG.md not found"
else
  # Check version section exists
  if grep -q "## \[${VERSION}\]" "$CHANGELOG"; then
    pass "CHANGELOG has section for [${VERSION}]"

    # Check section has date
    if grep -q "## \[${VERSION}\] - [0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}" "$CHANGELOG"; then
      pass "CHANGELOG section has date"
    else
      warn "CHANGELOG section missing date (expected format: ## [${VERSION}] - YYYY-MM-DD)"
    fi

    # Check section has content (not empty)
    # Extract section and count non-empty lines
    # Use sed to extract content between version sections
    SECTION_CONTENT=$(sed -n "/^## \[${VERSION}\]/,/^## \[/p" "$CHANGELOG" | grep -v "^## \[" | grep -v "^$" | head -5)
    if [[ -n "$SECTION_CONTENT" ]]; then
      pass "CHANGELOG section has content"
    else
      error "CHANGELOG section for [${VERSION}] appears empty"
    fi
  else
    # Try without patch version
    if grep -q "## \[${MAJOR_MINOR}\]" "$CHANGELOG"; then
      pass "CHANGELOG has section for [${MAJOR_MINOR}] (parent version)"
    else
      error "CHANGELOG missing section for [${VERSION}] or [${MAJOR_MINOR}]"
    fi
  fi
fi

echo ""

# =============================================================================
# 5. Agent List Consistency
# =============================================================================
echo "==> Checking agent list consistency..."

# Count agent mentions in key files
README_AGENT_COUNT=0
INDEX_AGENT_COUNT=0

for agent in "${AGENTS[@]}"; do
  if [[ -f "$README" ]] && grep -q "$agent" "$README"; then
    ((README_AGENT_COUNT++)) || true
  fi
  if [[ -f "$INDEX" ]] && grep -q "$agent" "$INDEX"; then
    ((INDEX_AGENT_COUNT++)) || true
  fi
done

TOTAL_AGENTS=${#AGENTS[@]}

if [[ "$README_AGENT_COUNT" -eq "$TOTAL_AGENTS" ]]; then
  pass "README mentions all $TOTAL_AGENTS agents"
else
  warn "README only mentions $README_AGENT_COUNT of $TOTAL_AGENTS agents"
fi

if [[ "$INDEX_AGENT_COUNT" -eq "$TOTAL_AGENTS" ]]; then
  pass "index.html mentions all $TOTAL_AGENTS agents"
else
  warn "index.html only mentions $INDEX_AGENT_COUNT of $TOTAL_AGENTS agents"
fi

echo ""

# =============================================================================
# Summary
# =============================================================================
echo "═══════════════════════════════════════════════════════════"
if [[ "$ERRORS" -gt 0 ]]; then
  red "  VALIDATION FAILED: $ERRORS error(s), $WARNINGS warning(s)"
  red "  Fix errors before deploying!"
  echo "═══════════════════════════════════════════════════════════"
  exit 2
elif [[ "$WARNINGS" -gt 0 ]]; then
  yellow "  VALIDATION PASSED WITH WARNINGS: $WARNINGS warning(s)"
  yellow "  Review warnings before deploying."
  echo "═══════════════════════════════════════════════════════════"
  exit 1
else
  green "  VALIDATION PASSED: All checks OK"
  echo "═══════════════════════════════════════════════════════════"
  exit 0
fi
