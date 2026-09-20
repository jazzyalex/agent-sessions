#!/usr/bin/env bash
# Builds the Linux console release: agent-sessions (Go TUI) + agent-sessions-core (Swift
# engine, static Swift stdlib and SQLite), as a tarball plus .deb and .rpm in dist/.
# Run from macOS with Docker and Go installed.
#   ./linux/package.sh arm64|amd64 [version]
# amd64 is cross-built under emulation on Apple silicon (slow; the first run downloads a
# separate Swift image).
set -euo pipefail
arch="${1:?usage: linux/package.sh arm64|amd64 [version]}"
case "$arch" in arm64|amd64) ;; *) echo "unknown arch $arch" >&2; exit 2 ;; esac
repo="$(cd "$(dirname "$0")/.." && pwd)"
version="${2:-$(git -C "$repo" describe --tags --always --dirty 2>/dev/null | sed 's/^v//')}"
version="${version:-0.0.0}"
stage="$repo/dist/agent-sessions-linux-$arch"
nfpm_version="v2.35.3"

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
  image="agent-sessions-linux"
  platform_args=()
else
  AS_PLATFORM="linux/$arch" "$repo/linux/build.sh" -c release --static-swift-stdlib
  core="$repo/.build-linux-$arch/release/as-core"
  image="agent-sessions-linux-$arch"
  platform_args=(--platform "linux/$arch")
fi

rm -rf "$stage" && mkdir -p "$stage"
cp "$core" "$stage/agent-sessions-core"
# Drop debug symbols (roughly 88 MB -> a third); strip runs in the build image.
docker run --rm ${platform_args[@]+"${platform_args[@]}"} -v "$stage:/stage" "$image" strip /stage/agent-sessions-core
(cd "$repo/tui" && CGO_ENABLED=0 GOOS=linux GOARCH="$arch" go build -buildvcs=false -trimpath -ldflags "-s -w" \
  -o "$stage/agent-sessions" .)
cp "$repo/linux/README.md" "$stage/README"
tar -C "$repo/dist" -czf "$stage.tar.gz" "$(basename "$stage")"

# .deb and .rpm via nfpm, cross-built here and run inside the Linux image (nfpm needs no
# dpkg or rpmbuild, so one tool covers both formats).
tools="$repo/dist/.tools"
mkdir -p "$tools"
if [ ! -x "$tools/nfpm-$arch" ]; then
  work="$(mktemp -d)"
  (cd "$work" && go mod init nfpmtool >/dev/null 2>&1 &&
    GOFLAGS=-mod=mod go get "github.com/goreleaser/nfpm/v2/cmd/nfpm@$nfpm_version" >/dev/null 2>&1 &&
    CGO_ENABLED=0 GOOS=linux GOARCH="$arch" go build -o "$tools/nfpm-$arch" github.com/goreleaser/nfpm/v2/cmd/nfpm)
  rm -rf "$work"
fi
for format in deb rpm; do
  docker run --rm ${platform_args[@]+"${platform_args[@]}"} \
    -e ARCH="$arch" -e VERSION="$version" -e STAGE="/stage" \
    -v "$stage:/stage" -v "$tools:/tools:ro" -v "$repo/linux:/spec:ro" -v "$repo/dist:/out" \
    "$image" /tools/nfpm-"$arch" package --config /spec/nfpm.yaml --packager "$format" --target /out
done

ls -1 "$stage.tar.gz" "$repo/dist"/agent-sessions*"$(echo "$version" | tr -d v)"*.deb "$repo/dist"/agent-sessions*.rpm 2>/dev/null | sort -u
