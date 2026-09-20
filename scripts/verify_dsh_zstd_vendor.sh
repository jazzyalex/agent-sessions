#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
package_root="${1:-${repo_root}/ThirdParty/DSHZstd}"
manifest="${package_root}/UPSTREAM_SHA256SUMS"
expected_file="$(mktemp)"
actual_file="$(mktemp)"
trap 'unlink "${expected_file}"; unlink "${actual_file}"' EXIT

awk '{print $2}' "${manifest}" | LC_ALL=C sort > "${expected_file}"
(
  cd "${package_root}"
  find \
    LICENSE \
    Sources/libzstd/zstd.h \
    Sources/libzstd/zstd_errors.h \
    Sources/libzstd/common \
    Sources/libzstd/decompress \
    -type f -print | LC_ALL=C sort
) > "${actual_file}"

if ! diff -u "${expected_file}" "${actual_file}"; then
  echo "DSHZstd vendored file inventory differs from UPSTREAM_SHA256SUMS" >&2
  exit 1
fi

(
  cd "${package_root}"
  shasum -a 256 -c UPSTREAM_SHA256SUMS
)

count="$(wc -l < "${actual_file}" | tr -d ' ')"
echo "Verified DSHZstd upstream inventory: ${count} files from Zstandard v1.5.7"
