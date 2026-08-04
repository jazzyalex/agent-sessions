#!/usr/bin/env python3
"""Rebuild a stage0 baseline fixture from EVERY session on disk, not a recent sample.

Why this exists
---------------
Fixtures built from the few most recent sessions miss every rare event family by
construction. On 2026-08-04 the Claude fixture covered 11 of 24 attachment subtypes
and the Codex fixture 12 of 18 `event_msg` families, so the weekly scan went amber
each time one of the missing families happened to surface -- drift alerts that meant
"our baseline was incomplete", not "upstream changed". A monitor that cries wolf
stops being read, which defeats the point of having one.

What it does
------------
Sweeps every session the weekly monitor could discover for an agent, unions their
schema fingerprints, and reports which buckets/keys the committed fixture is missing.
With --emit it harvests real records covering those gaps, redacts them, and appends
them to the fixture.

Redaction
---------
Every scalar is replaced: strings become a placeholder, numbers 0, booleans false.
Only structural discriminators survive verbatim (`type`, `role`, `subtype`, `model`),
because those are the schema. Values under an agent's `_NESTED_OPAQUE_KEYS` are
dropped wholesale -- those maps are keyed by absolute file path or tool name, so
their KEYS are user content rather than format.

Usage
-----
    ./scripts/rebuild_stage0_baseline.py --agent claude            # report only
    ./scripts/rebuild_stage0_baseline.py --agent claude --emit     # append coverage
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import agent_watch  # noqa: E402

REPO = Path(__file__).resolve().parents[1]
FIXTURES = REPO / "Resources/Fixtures/stage0/agents"
CONFIG = REPO / "docs/agent-support/agent-watch-config.json"
MATRIX = REPO / "docs/agent-support/agent-support-matrix.yml"

PLACEHOLDER = "[trimmed for fixture]"
# Values that ARE the schema and must survive redaction verbatim.
STRUCTURAL_KEYS = {"type", "role", "subtype", "model"}

# Fixture that receives appended coverage, per agent.
TARGET_FIXTURE = {
    "claude": "claude/small.jsonl",
    "codex": "codex/small.jsonl",
    "copilot": "copilot/small.jsonl",
}

# matrix key -> evidence_fixtures, mirroring agent_watch's own mapping.
MATRIX_KEY = {
    "codex": "codex_cli", "claude": "claude_code", "copilot": "copilot_cli",
    "antigravity": "antigravity", "opencode": "opencode", "hermes": "hermes",
    "openclaw": "openclaw", "cursor": "cursor", "pi": "pi", "kimi": "kimi_code",
}


def _load_config(agent: str) -> dict:
    cfg = json.loads(CONFIG.read_text(encoding="utf-8"))
    agents = cfg.get("agents", cfg)
    if agent not in agents:
        raise SystemExit(f"unknown agent: {agent}")
    return agents[agent]


def _baseline_paths(agent: str) -> list[str]:
    """evidence_fixtures for the agent, read without a yaml dependency."""
    key = MATRIX_KEY.get(agent, agent)
    text = MATRIX.read_text(encoding="utf-8")
    out: list[str] = []
    in_agent = False
    for line in text.splitlines():
        if line.startswith(f"  {key}:"):
            in_agent = True
            continue
        if in_agent:
            if line and not line.startswith("    ") and not line.startswith("      "):
                break
            stripped = line.strip()
            if stripped.startswith('- "Resources/'):
                out.append(stripped[3:].strip('"'))
    return out


def _all_sessions(agent: str, cfg: dict, limit: int | None) -> list[Path]:
    ls = cfg.get("weekly", {}).get("local_schema", {})
    roots = ls.get("roots") or []
    glob = ls.get("glob") or "**/*.jsonl"
    excludes = ls.get("exclude_globs")
    required = ls.get("required_types") or []
    huge = limit or 100000
    if required:
        return agent_watch._newest_files_with_types(
            roots, glob, required, huge, max_lines=400, exclude_globs=excludes)
    return agent_watch._newest_files(roots, glob, huge, exclude_globs=excludes)


def _redact(value, opaque: frozenset[str], key: str | None = None):
    if key in opaque:
        # Keyed by absolute path or tool name: keep the key, discard the map.
        return {} if isinstance(value, dict) else ([] if isinstance(value, list) else None)
    if isinstance(value, dict):
        return {k: _redact(v, opaque, k) for k, v in value.items()}
    if isinstance(value, list):
        return [_redact(v, opaque) for v in value]
    if isinstance(value, bool):
        return False
    if isinstance(value, (int, float)):
        return 0
    if isinstance(value, str):
        return value if key in STRUCTURAL_KEYS else PLACEHOLDER
    return value


def _record_buckets(agent: str, record: dict, tmp: Path) -> dict[str, list[str]]:
    tmp.write_text(json.dumps(record) + "\n", encoding="utf-8")
    return agent_watch._schema_fingerprint_for_agent(agent, tmp, max_lines=5).get("type_keys") or {}


def _gaps(observed: dict[str, list[str]], baseline: dict[str, list[str]]) -> set[tuple[str, str]]:
    """Every (bucket, key) pair present on disk but absent from the fixture."""
    missing: set[tuple[str, str]] = set()
    for bucket, keys in observed.items():
        known = set(baseline.get(bucket, []))
        for k in keys:
            if bucket not in baseline or k not in known:
                missing.add((bucket, k))
    return missing


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--agent", required=True)
    ap.add_argument("--emit", action="store_true",
                    help="append redacted coverage records to the fixture")
    ap.add_argument("--max-sessions", type=int, default=None)
    args = ap.parse_args(argv)

    agent = args.agent
    cfg = _load_config(agent)
    opaque = frozenset(agent_watch._NESTED_OPAQUE_KEYS.get(agent, ()))
    baseline = agent_watch._baseline_type_keys_for_agent(agent, _baseline_paths(agent))

    sessions = _all_sessions(agent, cfg, args.max_sessions)
    print(f"{agent}: sweeping {len(sessions)} sessions on disk")

    fps = []
    for p in sessions:
        try:
            fps.append(agent_watch._schema_fingerprint_for_agent(agent, p, max_lines=5000))
        except (OSError, ValueError):
            continue
    observed = agent_watch._merge_type_keys(fps) if fps else {}

    missing = _gaps(observed, baseline)
    if not missing:
        print(f"{agent}: fixture already covers every bucket/key on disk")
        return 0

    buckets = sorted({b for b, _ in missing})
    print(f"{agent}: {len(missing)} missing (bucket, key) pairs across {len(buckets)} buckets")
    for b in buckets:
        keys = sorted(k for bb, k in missing if bb == b)
        print(f"  {b} += {','.join(keys)}")

    if not args.emit:
        print("\n(report only -- rerun with --emit to append redacted coverage)")
        return 1

    target = FIXTURES / TARGET_FIXTURE[agent]
    tmp = target.parent / ".rebuild_probe.jsonl"
    harvested: list[dict] = []
    remaining = set(missing)

    # Greedy set cover: keep a record only if it closes a gap nothing else has.
    try:
        for p in sessions:
            if not remaining:
                break
            try:
                lines = agent_watch._tail_lines(p, 5000)
            except OSError:
                continue
            for raw in lines:
                if not remaining:
                    break
                try:
                    rec = json.loads(raw.strip())
                except json.JSONDecodeError:
                    continue
                if not isinstance(rec, dict):
                    continue
                red = _redact(rec, opaque)
                closes = {(b, k) for b, ks in _record_buckets(agent, red, tmp).items()
                          for k in ks} & remaining
                if closes:
                    harvested.append(red)
                    remaining -= closes
    finally:
        tmp.unlink(missing_ok=True)

    if harvested:
        with target.open("a", encoding="utf-8") as fh:
            for rec in harvested:
                fh.write(json.dumps(rec, separators=(",", ":")) + "\n")
    print(f"\n{agent}: appended {len(harvested)} redacted records to {target.relative_to(REPO)}")
    if remaining:
        # Reachable when a gap exists only inside an opaque subtree or a record whose
        # redaction changes its own bucket -- report rather than silently claim success.
        print(f"{agent}: {len(remaining)} pairs still uncovered: {sorted(remaining)[:8]}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
