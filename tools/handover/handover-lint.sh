#!/usr/bin/env bash
# Validate the newest (topmost) entry's key block in a RepoHandover.md.
# Usage: handover-lint.sh <path>   ->   exit 0 valid, exit 1 invalid (reason on stderr)
set -euo pipefail

file="${1:-}"
if [ -z "$file" ] || [ ! -f "$file" ]; then
  echo "handover-lint: file not found: ${file:-<none>}" >&2
  exit 1
fi

# Find the first heading line and the two lines after it.
head_line="$(grep -nE '^## ' "$file" | head -1 || true)"
if [ -z "$head_line" ]; then
  echo "handover-lint: no '## ' entry heading found" >&2
  exit 1
fi
hn="${head_line%%:*}"                    # line number of first heading
h="$(sed -n "${hn}p" "$file")"
s="$(sed -n "$((hn+1))p" "$file")"
b="$(sed -n "$((hn+2))p" "$file")"

# Heading: "## DATE TIME · slug · title"
if ! printf '%s' "$h" | grep -qE '^## [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} · .+ · .+'; then
  echo "handover-lint: heading not in '## DATE TIME · slug · title' form: $h" >&2
  exit 1
fi
# status line
if ! printf '%s' "$s" | grep -qE '^status: (in-progress|blocked|done|superseded-by:[0-9]{4}-[0-9]{2}-[0-9]{2})[[:space:]]*(#.*)?$'; then
  echo "handover-lint: bad or missing status line: $s" >&2
  exit 1
fi
# branch line (non-empty payload)
if ! printf '%s' "$b" | grep -qE '^branch: .+'; then
  echo "handover-lint: bad or missing branch line: $b" >&2
  exit 1
fi
exit 0
