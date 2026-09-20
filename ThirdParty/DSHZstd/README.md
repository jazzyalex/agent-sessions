# DeepSeek Harness Zstandard dependency

This directory is a local Swift package that exposes the C library product and
module name `libzstd` used by Agent Sessions. It contains the portable
decompression path needed for DeepSeek Harness `.jsonl.zstd` artifacts; it does
not include compression, dictionary-builder, legacy, or deprecated code.

## Provenance

- Version: Zstandard `1.5.7` (`v1.5.7`)
- Release archive: <https://github.com/facebook/zstd/releases/download/v1.5.7/zstd-1.5.7.tar.gz>
- Archive SHA-256: `eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3`
- License: upstream BSD License for Zstandard software, copied verbatim to
  [`LICENSE`](LICENSE)
- Intended macOS architectures: arm64 and x86_64, using portable C; the
  upstream x86_64 `huf_decompress_amd64.S` file is intentionally excluded.

The package product and target/module are both named `libzstd`, so existing
`import libzstd` clients keep the established identity. The package builds a
static library from the selected C sources and defines `ZSTD_DISABLE_ASM` and
`ZSTD_LEGACY_SUPPORT=0`.

[`UPSTREAM_SHA256SUMS`](UPSTREAM_SHA256SUMS) is the exact allowlist and
per-file digest manifest for the copied upstream license, sources, and headers.
Run `./scripts/verify_dsh_zstd_vendor.sh` from the repository root to reject a
missing, extra, or modified upstream file. The verifier is fully offline.

## Copied upstream files

The files below are copied unchanged from the release archive, preserving their
upstream notices. The vendored set contains 34 source/header files:

- `lib/common/*.c`: `debug.c`, `entropy_common.c`, `error_private.c`,
  `fse_decompress.c`, `pool.c`, `threading.c`, `xxhash.c`, `zstd_common.c`
- `lib/common/*.h`: `allocations.h`, `bits.h`, `bitstream.h`, `compiler.h`,
  `cpu.h`, `debug.h`, `error_private.h`, `fse.h`, `huf.h`, `mem.h`, `pool.h`,
  `portability_macros.h`, `threading.h`, `xxhash.h`, `zstd_deps.h`,
  `zstd_internal.h`, `zstd_trace.h`
- `lib/decompress/*.c`: `huf_decompress.c`, `zstd_ddict.c`,
  `zstd_decompress.c`, `zstd_decompress_block.c`
- `lib/decompress/*.h`: `zstd_ddict.h`, `zstd_decompress_block.h`,
  `zstd_decompress_internal.h`
- `lib/zstd.h`
- `lib/zstd_errors.h`

The two public headers live at the target root (`Sources/libzstd`) so the
upstream private headers' unchanged `../zstd.h` and `../zstd_errors.h` includes
continue to resolve.

SwiftPM integration adds exactly two local forwarding headers, which are not
part of the 34-file upstream count:

- `Sources/libzstd/include/zstd.h`
- `Sources/libzstd/include/zstd_errors.h`

`Package.swift` uses this directory as `publicHeadersPath`, so Swift's
generated umbrella exposes only those two public bridges while C compilation
continues to use the unchanged upstream headers at the target root.

The upstream `lib/compress`, `lib/dictBuilder`, `lib/legacy`, and
`lib/deprecated` trees, plus `lib/decompress/huf_decompress_amd64.S`, are not
vendored.

## Reproducible verified update procedure

1. Download the desired official release archive from the upstream release URL.
2. Verify its SHA-256 before extraction; for this release, it must equal the
   exact digest recorded above.
3. Extract the archive and copy only the paths listed in “Copied upstream
   files” into the matching `Sources/libzstd` subdirectories. Copy the upstream
   BSD `LICENSE` unchanged. Do not add assembly, compression, dictionary,
   legacy, or deprecated sources.
4. Regenerate `UPSTREAM_SHA256SUMS`, review every path and digest, then run
   `./scripts/verify_dsh_zstd_vendor.sh` from the repository root.
5. From this directory, run `swift package dump-package` and `swift build`.
6. Review the resulting file list, upstream notices, and both intended macOS
   architectures before updating the provenance values above.

The decoder is linked in-process. It does not invoke a `zstd` executable,
`Process`, or runtime library discovery.
