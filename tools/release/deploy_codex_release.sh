#!/usr/bin/env bash
set -euo pipefail
# Back-compat wrapper. Delegates to the unified release command so QA-stamp
# enforcement, resume validation, and release sequencing stay centralized.
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

if [[ $# -eq 0 ]]; then
  if [[ -z "${VERSION:-}" ]]; then
    echo "ERROR: version required. Usage: tools/release/deploy_codex_release.sh VERSION [--skip-qa]" >&2
    exit 2
  fi
  set -- "$VERSION"
fi

exec "$ROOT_DIR/tools/release/deploy" release "$@"
