#!/usr/bin/env bash
# Builds the Linux console release: `as` (Go TUI) + `as-core` (Swift core, static stdlib),
# packed as dist/agent-sessions-linux-<arch>.tar.gz. Run from macOS with Docker.
#   ./linux/package.sh arm64|amd64
# amd64 is cross-built under emulation on Apple silicon (slow; the first run downloads a
# separate Swift image).
set -euo pipefail
arch="${1:?usage: linux/package.sh arm64|amd64}"
case "$arch" in arm64|amd64) ;; *) echo "unknown arch $arch" >&2; exit 2 ;; esac
repo="$(cd "$(dirname "$0")/.." && pwd)"
stage="$repo/dist/agent-sessions-linux-$arch"

# The Docker VM's own architecture builds natively in .build-linux (reusing its fetched
# dependencies); the other one goes through AS_PLATFORM emulation in .build-linux-<arch>.
case "$(docker info --format '{{.Architecture}}')" in
  aarch64|arm64) native=arm64 ;;
  x86_64|amd64) native=amd64 ;;
  *) native="" ;;
esac
if [ "$arch" = "$native" ]; then
  "$repo/linux/build.sh" -c release --static-swift-stdlib
  core="$repo/.build-linux/release/as-core"
else
  AS_PLATFORM="linux/$arch" "$repo/linux/build.sh" -c release --static-swift-stdlib
  core="$repo/.build-linux-$arch/release/as-core"
fi

rm -rf "$stage" && mkdir -p "$stage"
cp "$core" "$stage/as-core"
# Drop debug symbols (roughly 88 MB -> a fraction); strip runs in the build image.
image="agent-sessions-linux"; [ "$arch" = "$native" ] || image="agent-sessions-linux-$arch"
docker run --rm ${native:+$( [ "$arch" = "$native" ] || echo --platform "linux/$arch")} \
  -v "$stage:/stage" "$image" strip /stage/as-core
(cd "$repo/tui" && CGO_ENABLED=0 GOOS=linux GOARCH="$arch" go build -trimpath -ldflags "-s -w" -o "$stage/as" .)
cat > "$stage/README" <<'EOF'
Agent Sessions for the terminal.
  ./as        browse, search, read, and resume local coding-agent sessions
  ./as-core   the JSON engine behind it; run it with no arguments for usage
Keep both files in the same directory. Runtime needs glibc, libstdc++ and libsqlite3
(Debian/Ubuntu: apt install libsqlite3-0).
The index lives in $XDG_DATA_HOME/agent-sessions/index.db (default ~/.local/share).
EOF
tar -C "$repo/dist" -czf "$stage.tar.gz" "$(basename "$stage")"
echo "$stage.tar.gz"
