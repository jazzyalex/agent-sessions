#!/usr/bin/env python3
"""Rebuild a stage0 baseline fixture from every supported file-backed session.

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
For file-backed agents, sweeps every session the weekly monitor could discover, unions
their schema fingerprints, and reports which buckets/keys the committed fixture is
missing. With --emit it harvests real records covering those gaps, redacts them, and
appends them to the fixture.

OpenCode's current SQLite path is different: the weekly fingerprinter intentionally
inspects only the latest session. This tool may use that bounded fingerprint for a
diagnostic report, but it cannot call that an all-session rebuild. Its row-limit
diagnostics are conservative because the existing fingerprinter exposes parsed-row
counts rather than fetched-row counts. DB-backed OpenCode runs therefore always return
nonzero, and --emit is refused before any fixture write.

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
import shutil
import sys
import tempfile
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
    "antigravity": "antigravity/cli_small.jsonl",
    "claude": "claude/small.jsonl",
    "grok": "grok/chat_history.jsonl",
    "codex": "codex/small.jsonl",
    "copilot": "copilot/small.jsonl",
    "kimi": "kimi/small.jsonl",
    # Qwen's five fixtures are hand-built synthetic transcripts whose exact event
    # counts are asserted by QwenIntegrationTests, so appended coverage gets its own
    # file rather than perturbing one of them.
    "qwen": "qwen/system_telemetry.jsonl",
}

SIDECAR_FIXTURE = {
    "grok": "grok/summary.json",
}

# agent name -> its section in agent-support-matrix.yml. IMPORTED, never re-declared:
# this used to be a third private copy of the same map, and copies drift. grok was
# missing here on 2026-08-13 and qwen on 2026-08-17, and in both cases _baseline_paths
# silently returned [] and the tool reported the ENTIRE schema as missing.
MATRIX_KEY = agent_watch.MATRIX_KEY_FOR_AGENT


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
            if stripped.startswith(('- "Resources/', '- "AgentSessionsTests/Resources/')):
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
    """Buckets a single record contributes, fingerprinted the same way as the agent.

    `tmp` must live OUTSIDE the fixture tree: a directory-aware fingerprinter
    (grok reads the sibling `summary.json`) would otherwise pick up the target
    fixture's own neighbours and report their buckets for every probed record.
    """
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


def _merge_missing_structure(existing, observed):
    """Add missing dict structure without replacing curated fixture values."""
    if not isinstance(existing, dict) or not isinstance(observed, dict):
        return existing
    for key, value in observed.items():
        if key not in existing:
            existing[key] = value
        elif isinstance(existing[key], dict) and isinstance(value, dict):
            _merge_missing_structure(existing[key], value)
    return existing


def _report_opencode_db_diagnostic(
    cfg: dict, baseline: dict[str, list[str]], *, emit: bool
) -> int:
    """Inspect configured OpenCode DB roots without claiming an all-session rebuild."""
    local_schema = cfg.get("weekly", {}).get("local_schema", {})
    configured = local_schema.get("db_roots")
    if not isinstance(configured, list) or not configured:
        print(
            "opencode: configured SQLite db_roots is missing or empty; "
            "the implicit HOME default DB path is not accessed, so "
            "DB-backed all-session rebuild is incomplete/unsupported",
            file=sys.stderr,
        )
        if emit:
            print(
                "opencode: --emit is unsupported for DB-backed diagnostics; "
                "no fixture files were modified",
                file=sys.stderr,
            )
        return 1

    max_messages = int(local_schema.get("max_messages") or 250)
    max_parts = int(local_schema.get("max_parts") or 2500)
    db_paths: list[Path] = []
    invalid_roots = False
    for raw in configured:
        if not isinstance(raw, str) or not raw.strip():
            print(
                f"opencode: invalid configured SQLite DB root: {raw!r}",
                file=sys.stderr,
            )
            invalid_roots = True
            continue
        db_paths.append(agent_watch._expand_path(raw))

    print(
        "opencode: DB-backed baseline rebuild is diagnostic only; "
        f"inspecting latest SQLite session from {len(configured)} configured DB root(s)"
    )

    fingerprints: list[dict] = []
    incomplete = invalid_roots
    for db_path in db_paths:
        if not db_path.exists():
            print(f"opencode: configured SQLite DB missing: {db_path}", file=sys.stderr)
            incomplete = True
            continue

        try:
            fp = agent_watch._opencode_sqlite_latest_session_schema_fingerprint(
                db_path,
                max_messages=max_messages,
                max_parts=max_parts,
            )
        except Exception as exc:
            print(
                f"opencode: SQLite fingerprint failed for {db_path}: {exc}",
                file=sys.stderr,
            )
            incomplete = True
            continue

        error = fp.get("error")
        if error:
            print(
                f"opencode: SQLite fingerprint failed for {db_path}: {error}",
                file=sys.stderr,
            )
            incomplete = True
            continue

        parse_errors = int(fp.get("parse_errors") or 0)
        if parse_errors:
            print(
                f"opencode: SQLite fingerprint for {db_path} had "
                f"{parse_errors} parse error(s)",
                file=sys.stderr,
            )
            incomplete = True
            continue

        warning = fp.get("warning")
        type_keys = fp.get("type_keys")
        if warning == "no_sessions_found" or not isinstance(type_keys, dict) or not type_keys:
            print(
                f"opencode: SQLite DB is empty or has no active sessions: {db_path}",
                file=sys.stderr,
            )
            incomplete = True
            continue

        message_rows = int(fp.get("message_rows_parsed") or 0)
        part_rows = int(fp.get("part_rows_parsed") or 0)
        if max_messages <= 0 or message_rows >= max_messages:
            print(
                f"opencode: latest SQLite session diagnostic reached the "
                f"max_messages row limit ({max_messages}) for {db_path}",
                file=sys.stderr,
            )
            incomplete = True
        if max_parts <= 0 or part_rows >= max_parts:
            print(
                f"opencode: latest SQLite session diagnostic reached the "
                f"max_parts row limit ({max_parts}) for {db_path}",
                file=sys.stderr,
            )
            incomplete = True

        fingerprints.append(fp)

    observed = agent_watch._merge_type_keys(fingerprints) if fingerprints else {}
    missing = _gaps(observed, baseline)

    if missing:
        buckets = sorted({bucket for bucket, _ in missing})
        print(
            f"opencode: {len(missing)} missing (bucket, key) pairs "
            f"across {len(buckets)} buckets in latest SQLite session diagnostics"
        )
        for bucket in buckets:
            keys = sorted(key for candidate, key in missing if candidate == bucket)
            print(f"  {bucket} += {','.join(keys)}")
    elif fingerprints:
        if incomplete:
            print(
                "opencode: observed parsed SQLite rows show no schema gaps, "
                "but configured DB evidence is incomplete"
            )
        else:
            print(
                "opencode: observed parsed SQLite rows show no schema gaps; "
                "this bounded latest-session diagnostic cannot establish complete coverage"
            )

    if emit:
        print(
            "opencode: --emit is unsupported for DB-backed diagnostics; "
            "no fixture files were modified",
            file=sys.stderr,
        )

    if incomplete:
        print(
            "opencode: SQLite diagnostic is incomplete; "
            "DB-backed all-session rebuild cannot be certified",
            file=sys.stderr,
        )
    else:
        print(
            "opencode: latest-session SQLite fingerprint is bounded and cannot "
            "establish all-session coverage; DB-backed rebuild remains incomplete/unsupported",
            file=sys.stderr,
        )

    return 1


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--agent", required=True)
    ap.add_argument(
        "--emit",
        action="store_true",
        help=(
            "append redacted coverage for supported file-backed all-session rebuilds; "
            "DB-backed OpenCode diagnostics never emit"
        ),
    )
    ap.add_argument("--max-sessions", type=int, default=None)
    args = ap.parse_args(argv)

    agent = args.agent
    cfg = _load_config(agent)
    opaque = frozenset(agent_watch._NESTED_OPAQUE_KEYS.get(agent, ()))
    baseline = agent_watch._baseline_type_keys_for_agent(agent, _baseline_paths(agent))

    local_schema = cfg.get("weekly", {}).get("local_schema", {})
    if agent == "opencode" and (
        local_schema.get("kind") == "opencode_latest_session"
        or "db_roots" in local_schema
    ):
        return _report_opencode_db_diagnostic(cfg, baseline, emit=args.emit)

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

    if agent not in TARGET_FIXTURE:
        print(f"{agent}: no TARGET_FIXTURE configured -- cannot --emit for this agent",
              file=sys.stderr)
        return 4
    target = FIXTURES / TARGET_FIXTURE[agent]
    probe_dir = tempfile.mkdtemp(prefix="rebuild-probe-")
    tmp = Path(probe_dir) / "probe.jsonl"
    harvested: list[dict] = []
    remaining = set(missing)

    # Grok's schema includes summary.json beside chat_history.jsonl. The old emitter
    # detected sidecar gaps but only harvested transcript lines, so it could never
    # close those gaps and exited 1 after partially changing the fixture.
    if agent == "grok" and any(bucket.startswith("summary") for bucket, _ in remaining):
        sidecar_target = FIXTURES / SIDECAR_FIXTURE[agent]
        sidecar_fixture = json.loads(sidecar_target.read_text(encoding="utf-8"))
        sidecar_probe_dir = Path(probe_dir) / "grok-sidecar"
        sidecar_probe_dir.mkdir(parents=True, exist_ok=True)
        sidecar_transcript = sidecar_probe_dir / "chat_history.jsonl"
        sidecar_transcript.write_text('{"type":"system"}\n', encoding="utf-8")
        for session in sessions:
            observed_sidecar, _error = agent_watch._read_json_object(session.parent / "summary.json")
            if not isinstance(observed_sidecar, dict):
                continue
            redacted_sidecar = _redact(observed_sidecar, opaque)
            (sidecar_probe_dir / "summary.json").write_text(
                json.dumps(redacted_sidecar) + "\n", encoding="utf-8"
            )
            sidecar_keys = agent_watch._grok_session_schema_fingerprint(
                sidecar_transcript, max_lines=5
            ).get("type_keys") or {}
            closes = {
                (bucket, key)
                for bucket, keys in sidecar_keys.items()
                if bucket.startswith("summary")
                for key in keys
            } & remaining
            if closes:
                _merge_missing_structure(sidecar_fixture, redacted_sidecar)
                remaining -= closes
            if not any(bucket.startswith("summary") for bucket, _ in remaining):
                break
        sidecar_target.write_text(
            json.dumps(sidecar_fixture, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )

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
        shutil.rmtree(probe_dir, ignore_errors=True)

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
