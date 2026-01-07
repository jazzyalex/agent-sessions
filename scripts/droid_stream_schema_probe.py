#!/usr/bin/env python3
"""
Probe Droid stream-json output and compare observed event keys to fixture baselines.

This runs `droid exec --output-format stream-json`, records the JSONL output, and
writes a schema_report.json under scripts/agent_captures/<UTC>/droid by default.
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable


DEFAULT_PROMPT = "Say HELLO. Then run ls -la."
DEFAULT_CONTINUE_PROMPT = (
    "Continue: if README.md exists, read and summarize it. Otherwise say NO_README."
)


@dataclass(frozen=True)
class RunResult:
    label: str
    argv: list[str]
    stdout_path: Path
    stderr_path: Path
    exit_code: int
    session_id: str | None


def _now_utc_slug() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%SZ")


def _newest(paths: Iterable[Path]) -> Path | None:
    newest: Path | None = None
    newest_mtime: float = -1.0
    for p in paths:
        try:
            mtime = p.stat().st_mtime
        except OSError:
            continue
        if mtime > newest_mtime:
            newest = p
            newest_mtime = mtime
    return newest


def _try_version(cmd: list[str]) -> str | None:
    try:
        proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=False)
    except OSError:
        return None
    out = (proc.stdout or "").strip()
    return out if out else None


def _extract_session_id(path: Path) -> str | None:
    session_id: str | None = None
    text = path.read_text(encoding="utf-8", errors="replace")
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(obj, dict):
            continue
        if obj.get("type") == "completion":
            sid = obj.get("session_id")
            if isinstance(sid, str) and sid:
                session_id = sid
    return session_id


def _run_droid(argv: list[str], out_dir: Path, label: str, timeout: int) -> RunResult:
    stdout_path = out_dir / f"stream_{label}.jsonl"
    stderr_path = out_dir / f"stream_{label}.stderr.txt"
    try:
        proc = subprocess.run(
            argv,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
            timeout=timeout,
        )
        stdout = proc.stdout or ""
        stderr = proc.stderr or ""
        exit_code = proc.returncode
    except subprocess.TimeoutExpired as exc:
        stdout = exc.stdout or ""
        stderr = (exc.stderr or "") + f"\nTimed out after {timeout} seconds."
        exit_code = 124

    stdout_path.write_text(stdout, encoding="utf-8")
    stderr_path.write_text(stderr, encoding="utf-8")
    session_id = _extract_session_id(stdout_path)

    return RunResult(
        label=label,
        argv=argv,
        stdout_path=stdout_path,
        stderr_path=stderr_path,
        exit_code=exit_code,
        session_id=session_id,
    )


def _default_baseline_paths() -> list[Path]:
    root = Path("Resources") / "Fixtures" / "stage0" / "agents" / "droid"
    if not root.exists():
        return []
    return sorted(root.glob("stream_json*.jsonl"))


def _load_events(paths: Iterable[Path]) -> tuple[list[dict], list[dict]]:
    events: list[dict] = []
    errors: list[dict] = []
    for path in paths:
        text = path.read_text(encoding="utf-8", errors="replace")
        for idx, line in enumerate(text.splitlines(), start=1):
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError as exc:
                errors.append(
                    {
                        "file": str(path),
                        "line": idx,
                        "error": str(exc),
                    }
                )
                continue
            if isinstance(obj, dict):
                events.append(obj)
    return events, errors


def _schema_index(events: Iterable[dict]) -> tuple[dict[str, set[str]], dict[str, int]]:
    type_keys: dict[str, set[str]] = {}
    type_counts: dict[str, int] = {}
    for obj in events:
        if not isinstance(obj, dict):
            continue
        raw_type = obj.get("type")
        event_type = raw_type if isinstance(raw_type, str) and raw_type else "<missing-type>"
        type_counts[event_type] = type_counts.get(event_type, 0) + 1
        keys = type_keys.setdefault(event_type, set())
        for key in obj.keys():
            keys.add(key)
    return type_keys, type_counts


def _serialize_keys(type_keys: dict[str, set[str]]) -> dict[str, list[str]]:
    return {event_type: sorted(keys) for event_type, keys in sorted(type_keys.items())}


def _compare_schema(
    observed: dict[str, set[str]], baseline: dict[str, set[str]]
) -> dict[str, dict[str, list[str]] | list[str]]:
    observed_types = set(observed.keys())
    baseline_types = set(baseline.keys())
    unknown_types = sorted(observed_types - baseline_types)
    missing_types = sorted(baseline_types - observed_types)

    unknown_keys: dict[str, list[str]] = {}
    missing_keys: dict[str, list[str]] = {}
    for event_type in sorted(observed_types | baseline_types):
        observed_keys = observed.get(event_type, set())
        baseline_keys = baseline.get(event_type, set())
        extra = sorted(observed_keys - baseline_keys)
        missing = sorted(baseline_keys - observed_keys)
        if extra:
            unknown_keys[event_type] = extra
        if missing:
            missing_keys[event_type] = missing

    return {
        "unknown_types": unknown_types,
        "missing_types": missing_types,
        "unknown_keys": unknown_keys,
        "missing_keys": missing_keys,
    }


def _format_type_counts(type_counts: dict[str, int]) -> str:
    if not type_counts:
        return "none"
    return ", ".join(f"{event_type}={type_counts[event_type]}" for event_type in sorted(type_counts))


def _copy_session_store(
    session_id: str, out_dir: Path, root: Path | None = None
) -> Path | None:
    if not session_id:
        return None
    root = root or (Path.home() / ".factory" / "sessions")
    if not root.exists():
        return None
    candidates = list(root.rglob(f"{session_id}.jsonl"))
    src = _newest(candidates)
    if src is None:
        return None
    dst = out_dir / "session_store" / src.relative_to(root)
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)
    return dst


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--droid-bin", default="droid", help="Path to the droid binary.")
    parser.add_argument("--prompt", default=DEFAULT_PROMPT, help="Prompt for the initial exec run.")
    parser.add_argument(
        "--continue-prompt",
        default=DEFAULT_CONTINUE_PROMPT,
        help="Prompt for the continuation exec run.",
    )
    parser.add_argument(
        "--no-continue", action="store_true", help="Skip the continuation exec run."
    )
    parser.add_argument(
        "--stream-file",
        action="append",
        default=[],
        help="Analyze an existing stream JSONL file instead of running droid.",
    )
    parser.add_argument(
        "--baseline",
        action="append",
        default=[],
        help="Baseline fixture JSONL path(s) to compare against.",
    )
    parser.add_argument(
        "--out",
        default=None,
        help="Output directory (default: scripts/agent_captures/<UTC>/droid).",
    )
    parser.add_argument("--timeout", type=int, default=120, help="Timeout for droid exec runs.")
    parser.add_argument(
        "--no-copy-session",
        action="store_true",
        help="Skip copying the on-disk session store file.",
    )
    args = parser.parse_args(argv)

    out_dir = Path(args.out) if args.out else Path("scripts") / "agent_captures" / _now_utc_slug() / "droid"
    out_dir.mkdir(parents=True, exist_ok=True)

    droid_version = _try_version([args.droid_bin, "--version"]) or _try_version(
        [args.droid_bin, "-v"]
    )

    run_results: list[RunResult] = []
    stream_paths: list[Path] = []
    session_id: str | None = None

    if args.stream_file:
        stream_paths = [Path(p) for p in args.stream_file]
        missing = [str(p) for p in stream_paths if not p.exists()]
        if missing:
            print(f"Missing stream JSONL files: {', '.join(missing)}", file=sys.stderr)
            return 2
    else:
        initial_argv = [args.droid_bin, "exec", "--output-format", "stream-json", args.prompt]
        initial = _run_droid(initial_argv, out_dir, "initial", args.timeout)
        run_results.append(initial)
        stream_paths.append(initial.stdout_path)
        session_id = initial.session_id
        if initial.exit_code != 0:
            print(f"Initial droid exec exited with {initial.exit_code}.", file=sys.stderr)
        if not args.no_continue and session_id:
            continue_argv = [
                args.droid_bin,
                "exec",
                "--session-id",
                session_id,
                "--output-format",
                "stream-json",
                args.continue_prompt,
            ]
            followup = _run_droid(continue_argv, out_dir, "continue", args.timeout)
            run_results.append(followup)
            stream_paths.append(followup.stdout_path)
            if followup.exit_code != 0:
                print(f"Continuation droid exec exited with {followup.exit_code}.", file=sys.stderr)

    if not stream_paths:
        print("No stream logs captured.", file=sys.stderr)
        return 2

    baseline_paths = [Path(p) for p in args.baseline] if args.baseline else _default_baseline_paths()
    baseline_paths = [p for p in baseline_paths if p.exists()]

    observed_events, parse_errors = _load_events(stream_paths)
    baseline_events, _ = _load_events(baseline_paths)

    observed_keys, observed_counts = _schema_index(observed_events)
    baseline_keys, _ = _schema_index(baseline_events)

    diff = _compare_schema(observed_keys, baseline_keys) if baseline_keys else {}

    session_store_path: Path | None = None
    if session_id and not args.no_copy_session:
        session_store_path = _copy_session_store(session_id, out_dir)

    report = {
        "timestamp_utc": datetime.now(timezone.utc).isoformat(),
        "droid_version": droid_version,
        "stream_files": [str(p) for p in stream_paths],
        "baseline_files": [str(p) for p in baseline_paths],
        "session_id": session_id,
        "session_store_copy": str(session_store_path) if session_store_path else None,
        "observed": {
            "type_counts": observed_counts,
            "type_keys": _serialize_keys(observed_keys),
        },
        "baseline": {"type_keys": _serialize_keys(baseline_keys)} if baseline_keys else None,
        "diff": diff,
        "parse_errors": {
            "count": len(parse_errors),
            "samples": parse_errors[:5],
        },
        "commands": [
            {
                "label": run.label,
                "argv": run.argv,
                "stdout": str(run.stdout_path),
                "stderr": str(run.stderr_path),
                "exit_code": run.exit_code,
                "session_id": run.session_id,
            }
            for run in run_results
        ],
    }

    report_path = out_dir / "schema_report.json"
    report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    summary = [
        f"Droid version: {droid_version or 'unknown'}",
        f"Stream files: {', '.join(str(p) for p in stream_paths)}",
        f"Observed types: {_format_type_counts(observed_counts)}",
    ]
    if diff:
        unknown_types = diff.get("unknown_types") or []
        if unknown_types:
            summary.append(f"Unknown types: {', '.join(unknown_types)}")
        unknown_keys = diff.get("unknown_keys") or {}
        if unknown_keys:
            summary.append(f"Unknown keys in {len(unknown_keys)} type(s).")
    if session_store_path:
        summary.append(f"Session store copy: {session_store_path}")
    summary.append(f"Report: {report_path}")
    print("\n".join(summary))

    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
