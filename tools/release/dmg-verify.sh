#!/usr/bin/env bash
# dmg-verify.sh — detach-then-verify helpers, shared by the build script and the
# deploy smoke test.
#
# `hdiutil verify` needs an exclusive handle on the image. `hdiutil create` can
# leave the image it just made attached, and stapling plus the Gatekeeper checks
# can mount it transiently, so any volume backed by the file makes verify fail
# with "Resource temporarily unavailable". That is not corruption — but both call
# sites used to report a damaged app bundle and send the operator after a build
# problem that did not exist.
#
# Both entry points are written to never abort a caller running under
# `set -euo pipefail`: they end in an explicit `return`, never in a pipeline
# whose status would become the function's.

# Print the /dev/diskN devices of every attached volume backed by image $1.
_dmg_attached_devices() {
  local img="$1"
  hdiutil info 2>/dev/null | awk -v img="$img" '
    $1 == "image-path" {
      # The path is everything after the first colon. Matching on $3 truncates
      # at the first space, so a checkout under "/Users/x/My Repos/..." never
      # matched and the detach silently did nothing.
      idx = index($0, ":")
      path = substr($0, idx + 1)
      gsub(/^[ \t]+|[ \t]+$/, "", path)
      current = (path == img)
      next
    }
    current && $1 ~ /^\/dev\/disk/ { print $1 }
  ' || true
  return 0
}

# Detach any volume backed by DMG $1. Never fails the caller.
dmg_detach_stale_mounts() {
  local dmg="$1" abs dev
  # Canonicalise, but degrade to the given path rather than aborting under
  # `set -e` when the directory is missing or unreadable.
  abs=$(cd "${dmg%/*}" 2>/dev/null && pwd)/"${dmg##*/}" || abs="$dmg"
  while read -r dev; do
    [[ -n "$dev" ]] || continue
    echo "==> Detaching stale mount of the DMG: $dev"
    hdiutil detach "$dev" -force >/dev/null 2>&1 || true
  done < <(_dmg_attached_devices "$abs")
  return 0
}

# Detach, then verify DMG $1, retrying twice for a slow DiskArbitration unmount.
# Pass "1" as $2 to silence hdiutil's own output. Returns 0 on success, 1 on
# failure — the caller owns the error message and the exit code.
dmg_verify_with_detach() {
  local dmg="$1" quiet="${2:-0}" attempt
  dmg_detach_stale_mounts "$dmg"
  for attempt in 1 2 3; do
    if [[ "$quiet" == "1" ]]; then
      if hdiutil verify "$dmg" >/dev/null 2>&1; then return 0; fi
    else
      if hdiutil verify "$dmg"; then return 0; fi
    fi
    # No sleep after the final attempt — nothing follows it to wait for.
    if [[ "$attempt" -lt 3 ]]; then
      echo "==> DMG verify attempt $attempt failed; detaching and retrying in 3s" >&2
      dmg_detach_stale_mounts "$dmg"
      sleep 3
    fi
  done
  return 1
}
