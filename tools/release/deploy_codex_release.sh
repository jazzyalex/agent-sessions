#!/usr/bin/env bash
set -euo pipefail
# Back-compat wrapper. Delegates to the new top-level script name.
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
exec "$ROOT_DIR/tools/release/deploy-agent-sessions.sh" "$@"
