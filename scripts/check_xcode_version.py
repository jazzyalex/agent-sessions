#!/usr/bin/env python3
"""Require the same Xcode toolchain for local release QA and CI."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
EXPECTED_PATH = REPO / "tools" / "release" / "ci-xcode-version.txt"


def normalized_version(text: str) -> tuple[str, ...]:
    return tuple(line.strip() for line in text.splitlines() if line.strip())


def expected_xcode_version() -> tuple[str, ...]:
    return normalized_version(EXPECTED_PATH.read_text(encoding="utf-8"))


def actual_xcode_version() -> tuple[str, ...]:
    result = subprocess.run(
        ["xcodebuild", "-version"],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout).strip()
        raise RuntimeError(f"xcodebuild -version failed: {detail}")
    return normalized_version(result.stdout)


def main() -> int:
    expected = expected_xcode_version()
    try:
        actual = actual_xcode_version()
    except (OSError, RuntimeError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    if actual != expected:
        print("ERROR: Xcode toolchain mismatch", file=sys.stderr)
        print(f"  expected: {' / '.join(expected)}", file=sys.stderr)
        print(f"  found:    {' / '.join(actual)}", file=sys.stderr)
        print(f"  update/select the toolchain required by {EXPECTED_PATH}", file=sys.stderr)
        return 1

    print(f"Xcode toolchain valid: {' / '.join(actual)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
