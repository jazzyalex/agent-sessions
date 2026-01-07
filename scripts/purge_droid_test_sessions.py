#!/usr/bin/env python3
"""
Purge Droid (Factory CLI) test sessions created by our schema probes.

Safety rules (enforced):
- Dry-run by default.
- Two-signal match required for deletion:
  1) File content contains the exact marker prompt string.
  2) File path is under the encoded repo cwd folder name (defaults to this repo).
- Refuses to operate on /, $HOME, or a missing root.
- Requires --execute and a --confirm string that includes the exact count.
- Writes a timestamped manifest under scripts/probe_scan_output/purge_test_sessions/.
"""

from __future__ import annotations

import argparse
import json
import os
import random
import shutil
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path


DEFAULT_MARKER = "Say HELLO. Then run ls -la."
DEFAULT_ROOT = str(Path.home() / ".factory" / "sessions")
# This is the folder Factory uses to encode a working directory path into a safe folder name.
DEFAULT_ENCODED_CWD_DIRNAME = "-Users-alexm-Repository-Codex-History"


def _now_utc_slug() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%SZ")


def _refuse_dangerous_root(root: Path) -> None:
    root = root.resolve()
    home = Path.home().resolve()
    if root == Path("/"):
        raise SystemExit("Refusing to run with root=/")
    if root == home:
        raise SystemExit("Refusing to run with root=$HOME")
    if not root.exists():
        raise SystemExit(f"Root does not exist: {root}")


def _read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return ""


def _marker_in_file(path: Path, marker: str) -> bool:
    return marker in _read_text(path)


@dataclass(frozen=True)
class Candidate:
    path: Path
    marker_hit: bool
    cwd_signal: bool


def _collect_candidates(root: Path, marker: str, encoded_cwd_dirname: str) -> list[Candidate]:
    candidates: list[Candidate] = []
    for path in root.rglob("*.jsonl"):
        if not path.is_file():
            continue
        marker_hit = _marker_in_file(path, marker)
        if not marker_hit:
            continue
        cwd_signal = encoded_cwd_dirname in str(path)
        candidates.append(Candidate(path=path, marker_hit=marker_hit, cwd_signal=cwd_signal))
    return candidates


def _confusion_matrix(candidates: list[Candidate]) -> dict[str, list[Path]]:
    buckets: dict[str, list[Path]] = {"marker_only": [], "both": []}
    for c in candidates:
        if c.marker_hit and c.cwd_signal:
            buckets["both"].append(c.path)
        else:
            buckets["marker_only"].append(c.path)
    return buckets


def _write_manifest(out_dir: Path, manifest: dict) -> Path:
    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / "manifest.json"
    path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return path


def _sample(paths: list[Path], k: int) -> list[str]:
    if not paths:
        return []
    if len(paths) <= k:
        return [str(p) for p in paths]
    return [str(p) for p in random.sample(paths, k)]


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=DEFAULT_ROOT, help="Root folder to scan (default: ~/.factory/sessions).")
    parser.add_argument("--marker", default=DEFAULT_MARKER, help="Exact marker string to match (fixed string).")
    parser.add_argument(
        "--encoded-cwd-dirname",
        default=DEFAULT_ENCODED_CWD_DIRNAME,
        help="Second-signal folder name that must appear in the file path.",
    )
    parser.add_argument("--execute", action="store_true", help="Actually delete matched sessions.")
    parser.add_argument(
        "--confirm",
        default="",
        help='Confirmation string that must equal "delete <N> sessions" for the computed N.',
    )
    parser.add_argument(
        "--quarantine",
        action="store_true",
        help="Move to a quarantine folder instead of hard delete (recommended).",
    )
    args = parser.parse_args(argv)

    root = Path(os.path.expandvars(args.root)).expanduser()
    _refuse_dangerous_root(root)

    candidates = _collect_candidates(root, args.marker, args.encoded_cwd_dirname)
    buckets = _confusion_matrix(candidates)

    to_delete = buckets["both"]
    marker_only = buckets["marker_only"]

    out_dir = Path("scripts") / "probe_scan_output" / "purge_test_sessions" / _now_utc_slug()
    manifest = {
        "timestamp_utc": datetime.now(timezone.utc).isoformat(),
        "root": str(root),
        "marker": args.marker,
        "encoded_cwd_dirname": args.encoded_cwd_dirname,
        "counts": {
            "marker_only": len(marker_only),
            "both": len(to_delete),
            "total": len(candidates),
        },
        "samples": {
            "marker_only": _sample(marker_only, 3),
            "both": _sample(to_delete, 3),
        },
        "to_delete": [str(p) for p in to_delete],
        "mode": "execute" if args.execute else "dry_run",
        "quarantine": bool(args.quarantine),
    }
    manifest_path = _write_manifest(out_dir, manifest)

    print(f"Root: {root}")
    print(f"Marker: {args.marker!r}")
    print(f"Second signal (path contains): {args.encoded_cwd_dirname!r}")
    print(f"Counts: marker_only={len(marker_only)} both={len(to_delete)} total={len(candidates)}")
    if marker_only:
        print("marker_only samples:")
        for p in manifest["samples"]["marker_only"]:
            print(f"  {p}")
    if to_delete:
        print("both (eligible) samples:")
        for p in manifest["samples"]["both"]:
            print(f"  {p}")
    print(f"Manifest: {manifest_path}")

    if not args.execute:
        print("Dry-run only. To execute, pass --execute and --confirm \"delete <N> sessions\".")
        return 0

    expected = f"delete {len(to_delete)} sessions"
    if args.confirm.strip() != expected:
        print(f"Refusing to execute: --confirm must be exactly: {expected!r}", file=os.sys.stderr)
        return 2

    if not to_delete:
        print("Nothing to delete.")
        return 0

    if args.quarantine:
        quarantine_root = out_dir / "quarantine"
        quarantine_root.mkdir(parents=True, exist_ok=True)
        for p in to_delete:
            dst = quarantine_root / p.name
            try:
                shutil.move(str(p), str(dst))
            except OSError as exc:
                print(f"Failed to move {p}: {exc}", file=os.sys.stderr)
        print(f"Moved {len(to_delete)} sessions to quarantine: {quarantine_root}")
        return 0

    # Hard delete.
    for p in to_delete:
        try:
            p.unlink()
        except OSError as exc:
            print(f"Failed to delete {p}: {exc}", file=os.sys.stderr)
    print(f"Deleted {len(to_delete)} sessions.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(os.sys.argv[1:]))

