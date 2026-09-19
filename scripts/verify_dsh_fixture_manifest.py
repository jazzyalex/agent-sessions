#!/usr/bin/env python3
"""Verify the committed DSH compatibility corpus without reading user history."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
FIXTURES = REPO / "AgentSessionsTests/Resources/Fixtures/stage0/agents/deepseek-harness"
PINNED_SOURCE_COMMIT = "ddefc45fbc7f8e46dd73185e68295696d1297887"


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify() -> int:
    manifest = json.loads((FIXTURES / "manifest.json").read_text(encoding="utf-8"))
    if manifest.get("sourceCommit") != PINNED_SOURCE_COMMIT:
        raise SystemExit("DSH fixture manifest source commit does not match the pinned checkout")

    entries = manifest.get("fixtures")
    if not isinstance(entries, list) or not entries:
        raise SystemExit("DSH fixture manifest has no fixture inventory")

    listed = {entry.get("file") for entry in entries if isinstance(entry, dict)}
    if None in listed or len(listed) != len(entries):
        raise SystemExit("DSH fixture manifest contains a missing or duplicate file entry")
    actual = {
        path.name
        for path in FIXTURES.iterdir()
        if path.name.endswith((".jsonl", ".jsonl.zstd"))
    }
    if listed != actual:
        raise SystemExit(f"DSH fixture inventory mismatch: listed={sorted(listed)} actual={sorted(actual)}")

    for entry in entries:
        path = FIXTURES / entry["file"]
        expected = str(entry.get("sha256", "")).lower()
        if sha256(path) != expected:
            raise SystemExit(f"DSH fixture hash mismatch: {entry['file']}")

    expected = manifest.get("expectedNormalizedV3")
    if not isinstance(expected, dict) or not isinstance(expected.get("file"), str):
        raise SystemExit("DSH normalized-v3 fixture metadata is missing")
    expected_path = FIXTURES / expected["file"]
    if sha256(expected_path) != str(expected.get("sha256", "")).lower():
        raise SystemExit(f"DSH normalized-v3 hash mismatch: {expected_path.name}")

    print(f"verified DSH fixture manifest: {len(entries)} artifacts at {PINNED_SOURCE_COMMIT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(verify())
