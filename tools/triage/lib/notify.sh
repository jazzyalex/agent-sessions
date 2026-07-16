#!/usr/bin/env bash
# notify.sh TITLE MESSAGE — Notification Center banner via osascript. Never fails
# the caller (a dropped notification must not break the run).
set -euo pipefail
title="${1:-Repo triage}"; msg="${2:-}"
osascript -e "display notification \"${msg//\"/\\\"}\" with title \"${title//\"/\\\"}\"" >/dev/null 2>&1 || true
