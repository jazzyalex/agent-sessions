#!/usr/bin/env bash
# Builds as-core inside a Linux container. Build output stays in .build-linux*/ so it
# never mixes with the host's macOS .build/.
#   AS_PLATFORM=linux/amd64 ./linux/build.sh -c release --static-swift-stdlib
# cross-builds an x86_64 binary (emulated on Apple silicon; slower).
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
platform="${AS_PLATFORM:-}"
suffix="${platform:+-${platform#linux/}}"
image="agent-sessions-linux${suffix}"
scratch=".build-linux${suffix}"
docker build -q ${platform:+--platform "$platform"} -t "$image" "$repo/linux" >/dev/null
# SwiftPM in the container intermittently fails with "unknown build description" after
# manifest edits; dropping the cached description forces it to regenerate (cheap).
find "$repo/$scratch" -maxdepth 3 -name description.json -delete 2>/dev/null || true
docker run --rm ${platform:+--platform "$platform"} -v "$repo:/src" -w /src "$image" \
  swift build --scratch-path "/src/$scratch" "$@"
