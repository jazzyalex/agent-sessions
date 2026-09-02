#!/usr/bin/env python3
"""One command a steward runs to re-verify that an agent's session format still matches.

Who this is for
---------------
Each supported agent has a steward: a volunteer who uses that agent daily and
re-checks it a few times a year, or whenever the vendor ships a big release. A
steward is not expected to know how the monitor works, so this command does the
whole weekly scan for one agent and answers in plain sentences.

    ./scripts/steward_check.py grok

What it does
------------
Runs the ordinary weekly scan restricted to that one agent, against the
steward's own local sessions, then reports one of three outcomes:

  exit 0  all good -- the local sessions match the committed baseline.
  exit 1  drift -- something new showed up. Prints the difference in plain
          words, writes a REDACTED sample next to the report, and prints a
          ready-to-paste GitHub issue body.
  exit 2  cannot check -- the agent's CLI is not installed, or there are no
          sessions on disk yet. Says which, and what to do about it.

Nothing is written to the repository's baseline fixtures. Deciding that drift is
real, and rebuilding a baseline for it, stays a maintainer job
(`scripts/rebuild_stage0_baseline.py`).

Redaction
---------
The sample reuses `rebuild_stage0_baseline._redact`, the same trimming that
produces committed fixtures: every string becomes a placeholder, every number 0,
every boolean false, and only the structural discriminators (`type`, `role`,
`subtype`, `model`) survive verbatim. The result is then re-scanned for anything
that looks like a home directory, an email address, a token or a long opaque id,
and the sample is withheld entirely if any of that survived.
"""
from __future__ import annotations

import argparse
import contextlib
import io
import json
import os
import re
import shutil
import sys
import tempfile
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

import agent_watch  # noqa: E402
import rebuild_stage0_baseline as rebuild  # noqa: E402

REPO = Path(__file__).resolve().parents[1]
CONFIG = REPO / "docs/agent-support/agent-watch-config.json"
DEFAULT_OUT = REPO / "scripts/probe_scan_output/steward_check"

EXIT_OK = 0
EXIT_DRIFT = 1
EXIT_CANNOT_CHECK = 2

# The doc a steward is pointed at when something needs a human.
STEWARD_DOC = "docs/adding-a-session-source.md"

# Everything below is checked against the redacted sample before it is written.
# A hit means redaction did not do its job, and the sample is withheld rather
# than handed to someone who is about to paste it into a public issue.
_LEAK_PATTERNS: list[tuple[str, str]] = [
    ("an email address", r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"),
    ("a macOS home directory", r"/Users/[A-Za-z0-9._-]+"),
    ("a Linux home directory", r"/home/[A-Za-z0-9._-]+"),
    ("a Windows user directory", r"[A-Za-z]:\\\\Users\\\\[A-Za-z0-9._-]+"),
    ("an API-key-shaped string", r"\b(?:sk|pk|ghp|gho|ghs|github_pat|xoxb|xoxp|Bearer)[-_ ][A-Za-z0-9._-]{8,}"),
    ("a long opaque identifier (token, hash or UUID)", r"[A-Za-z0-9_-]{32,}"),
    ("an IPv4 address", r"\b(?:\d{1,3}\.){3}\d{1,3}\b"),
]


# --------------------------------------------------------------------------
# Running the scan
# --------------------------------------------------------------------------


def _known_agents() -> list[str]:
    """Agents that are both monitored and mapped to a section of the support matrix.

    `MATRIX_KEY_FOR_AGENT` is imported, never re-declared. A private copy of that
    map has drifted twice already, and each time the effect was a silent empty
    baseline rather than an error.
    """
    cfg = json.loads(CONFIG.read_text(encoding="utf-8"))
    configured = (cfg.get("agents") or {}).keys()
    return sorted(a for a in configured if a in agent_watch.MATRIX_KEY_FOR_AGENT)


def _resolve_agent(typed: str, known: list[str]) -> str | None:
    """Accept what a steward would actually type, not just the internal key.

    The public docs name agents "Grok CLI", "Claude Code", "Kimi Code", so the
    matrix key (`grok_cli`, `claude_code`) is often the nearer guess. Both spellings
    resolve, and both come out of `MATRIX_KEY_FOR_AGENT` rather than a hand-kept
    list of aliases.
    """
    wanted = typed.strip().lower().replace("-", "_").replace(" ", "_")
    if wanted in known:
        return wanted
    for name in known:
        if agent_watch.MATRIX_KEY_FOR_AGENT.get(name) == wanted:
            return name
    return None


def _scan(agent: str, out_dir: Path, timeout: int, verbose: bool) -> dict[str, Any]:
    """Run the real weekly scan, restricted to one agent, and return its result block.

    The scan itself is `agent_watch.main` driven through a filtered copy of the
    shared config. Reimplementing the weekly logic here would mean a second
    fingerprint dispatch to keep in sync with the first, which is exactly the
    kind of copy that has silently drifted in this tool before.
    """
    cfg = json.loads(CONFIG.read_text(encoding="utf-8"))
    agents = cfg.get("agents") or {}
    agent_cfg = dict(agents[agent])
    cadence = dict(agent_cfg.get("cadence") or {})
    cadence["weekly"] = True
    agent_cfg["cadence"] = cadence

    report_root = out_dir / "scan"
    filtered = dict(cfg)
    filtered["agents"] = {agent: agent_cfg}
    filtered["report_root"] = str(report_root)

    tmp_dir = Path(tempfile.mkdtemp(prefix="steward-check-"))
    tmp_cfg = tmp_dir / "config.json"
    tmp_cfg.write_text(json.dumps(filtered), encoding="utf-8")

    # agent_watch resolves the support matrix relative to the working directory.
    prev_cwd = Path.cwd()
    buffer = io.StringIO()
    try:
        os.chdir(REPO)
        argv = ["--mode", "weekly", "--config", str(tmp_cfg), "--timeout", str(timeout)]
        with contextlib.redirect_stdout(buffer):
            agent_watch.main(argv)
    finally:
        os.chdir(prev_cwd)
        shutil.rmtree(tmp_dir, ignore_errors=True)

    if verbose:
        print("--- raw scan output ---")
        print(buffer.getvalue().rstrip())
        print("--- end raw scan output ---\n")

    reports = sorted(report_root.glob("*/report.json"))
    if not reports:
        raise RuntimeError("the scan produced no report; rerun with --verbose to see why")
    report = json.loads(reports[-1].read_text(encoding="utf-8"))
    result = (report.get("results") or {}).get(agent)
    if not isinstance(result, dict):
        raise RuntimeError(f"the scan produced no result for {agent}")
    result["_report_path"] = str(reports[-1])
    return result


# --------------------------------------------------------------------------
# Redaction
# --------------------------------------------------------------------------


def _redaction_leaks(text: str) -> list[str]:
    """Names of anything private-looking that survived redaction. Empty is the goal."""
    found: list[str] = []
    for label, pattern in _LEAK_PATTERNS:
        if re.search(pattern, text):
            found.append(label)
    home = os.path.expanduser("~")
    if home and home != "~" and home in text:
        found.append("the steward's own home directory")
    return found


def _redact_records(agent: str, records: list[dict]) -> list[dict]:
    opaque = frozenset(agent_watch._NESTED_OPAQUE_KEYS.get(agent, ()))
    return [rebuild._redact(rec, opaque) for rec in records]


def _collect_drifting_records(agent: str, session_files: list[Path], wanted: set[tuple[str, str]],
                              wanted_buckets: set[str], max_records: int) -> list[dict]:
    """Transcript records that carry at least one of the drifting (bucket, key) pairs.

    Selection is the same greedy set cover `rebuild_stage0_baseline` uses when it
    harvests fixture coverage: a record is kept only if it shows something no
    already-kept record showed.

    `wanted_buckets` covers a whole record kind that is new. Matching those by
    bucket rather than by (bucket, key) matters: a brand-new record type has no
    guaranteed key to key off, and pairing it with a guessed key name silently
    harvested nothing.
    """
    if not wanted and not wanted_buckets:
        return []
    probe_dir = Path(tempfile.mkdtemp(prefix="steward-probe-"))
    probe = probe_dir / "probe.jsonl"
    kept: list[dict] = []
    remaining = set(wanted)
    remaining_buckets = set(wanted_buckets)
    opaque = frozenset(agent_watch._NESTED_OPAQUE_KEYS.get(agent, ()))
    try:
        for path in session_files:
            if (not remaining and not remaining_buckets) or len(kept) >= max_records:
                break
            if path.suffix not in (".jsonl", ".json", ".ndjson"):
                # sqlite / markdown sources: no line-oriented records to harvest.
                continue
            try:
                lines = agent_watch._tail_lines(path, 5000)
            except OSError:
                continue
            for raw in lines:
                if (not remaining and not remaining_buckets) or len(kept) >= max_records:
                    break
                try:
                    rec = json.loads(raw.strip())
                except json.JSONDecodeError:
                    continue
                if not isinstance(rec, dict):
                    continue
                red = rebuild._redact(rec, opaque)
                buckets = rebuild._record_buckets(agent, red, probe)
                closes = {(b, k) for b, ks in buckets.items() for k in ks} & remaining
                closes_buckets = set(buckets) & remaining_buckets
                if closes or closes_buckets:
                    kept.append(red)
                    remaining -= closes
                    remaining_buckets -= closes_buckets
    finally:
        probe.unlink(missing_ok=True)
        shutil.rmtree(probe_dir, ignore_errors=True)
    return kept


def _write_redacted_sample(agent: str, records: list[dict], sidecar: dict | None,
                           sample_dir: Path, sidecar_name: str = "summary.json") -> tuple[Path | None, list[str]]:
    """Write the redacted sample, or withhold it and report what leaked.

    Returns (path_or_None, leaks). A non-empty `leaks` means nothing was written:
    a sample a steward cannot safely paste is worse than no sample at all.
    """
    if not records and sidecar is None:
        return None, []

    sample_dir.mkdir(parents=True, exist_ok=True)
    body = "".join(json.dumps(r, separators=(",", ":")) + "\n" for r in records)
    sidecar_text = json.dumps(sidecar, indent=2, sort_keys=True) + "\n" if sidecar is not None else ""

    leaks = _redaction_leaks(body + sidecar_text)
    if leaks:
        return None, leaks

    target = sample_dir / f"{agent}-drift-sample.jsonl"
    if records:
        target.write_text(body, encoding="utf-8")
    if sidecar is not None:
        # Named the way the agent names it on disk, so a maintainer can drop the
        # pair straight into a fixture directory.
        (sample_dir / sidecar_name).write_text(sidecar_text, encoding="utf-8")
        if not records:
            target = sample_dir / sidecar_name
    return target, []


# --------------------------------------------------------------------------
# Plain-language reporting
# --------------------------------------------------------------------------


def _sampled_files(result: dict) -> list[Path]:
    local = ((result.get("weekly") or {}).get("local_schema")) or {}
    paths = [p for p in (local.get("sampled_files") or []) if isinstance(p, str)]
    if not paths and isinstance(local.get("file"), str):
        paths = [local["file"]]
    return [Path(p) for p in paths]


def _sample_count(result: dict) -> int:
    return len(_sampled_files(result))


def _describe_diff(diff: dict) -> list[str]:
    """The schema diff, said out loud."""
    lines: list[str] = []
    for t in diff.get("unknown_types") or []:
        # A dotted name is a nested section inside a record, not a record type.
        # Calling both "a new kind of record" read as several unrelated changes
        # when it was really one new field with an object inside it.
        if "." in t:
            parent, _, leaf = t.rpartition(".")
            lines.append(f"- A new section named '{leaf}' inside {parent}")
        else:
            lines.append(f"- A kind of record we have never seen before: {t}")
    for bucket, keys in (diff.get("unknown_keys") or {}).items():
        pretty = ", ".join(keys)
        lines.append(f"- New field(s) inside {bucket}: {pretty}")
    if not lines:
        lines.append("- No new records or fields; see the numbers below.")

    missing = diff.get("missing_types") or []
    if missing:
        shown = ", ".join(missing[:8])
        if len(missing) > 8:
            shown += f", and {len(missing) - 8} more"
        lines.append(
            "- Your sessions did not contain these parts of the known format: " + shown
        )
        lines.append(
            "  (that usually just means you did not use those features; it is not drift)"
        )
    return lines


def _cannot_check_reason(agent: str, result: dict) -> str | None:
    """Why this run could not reach a verdict, in the steward's terms."""
    installed = result.get("installed") or {}
    if installed.get("parsed_version") is None and installed.get("stderr") != "skipped":
        argv = installed.get("argv")
        cmd = " ".join(argv) if isinstance(argv, list) else f"{agent} --version"
        return (
            f"Could not find the {agent} CLI on this machine.\n"
            f"The check runs `{cmd}` to learn which version you have.\n"
            "Install the CLI (or make sure it is on your PATH) and run this again."
        )
    local = ((result.get("weekly") or {}).get("local_schema")) or {}
    if local.get("error") == "no_files_found":
        roots = ", ".join(local.get("roots") or []) or "its usual location"
        return (
            f"No {agent} sessions were found on this machine.\n"
            f"The check looks under: {roots}\n"
            f"Use {agent} for a short real session -- a prompt, a reply, and one tool call is\n"
            "enough -- and then run this again."
        )
    if result.get("evidence", {}).get("schema_matches_baseline") is None:
        return (
            f"The check could not compare {agent} against a baseline.\n"
            f"That usually means the repository has no committed fixtures for {agent} yet.\n"
            f"See {STEWARD_DOC}."
        )
    return None


def _issue_body(agent: str, result: dict, diff: dict, sample_path: Path | None,
                leaks: list[str]) -> str:
    verified = result.get("verified_version")
    installed = (result.get("installed") or {}).get("parsed_version")
    upstream = (result.get("upstream") or {}).get("parsed_version")
    count = _sample_count(result)

    lines = [
        f"Title: {agent}: session format drift at version {installed or 'unknown'}",
        "",
        f"Agent: {agent}",
        f"Version I am running: {installed or 'unknown'}",
        f"Version this repository has verified: {verified or 'unknown'}",
        f"Latest version published: {upstream or 'unknown'}",
        f"Sessions sampled: {count}",
        "",
        "What changed",
        "",
    ]
    lines.extend(_describe_diff(diff))
    lines.extend([
        "",
        "Sample",
        "",
    ])
    if sample_path is not None:
        lines.extend([
            f"A redacted sample is attached. It was produced by `scripts/steward_check.py {agent}`,",
            "Content values were replaced; structural discriminators (`type`, `role`, `subtype`, `model`) remain.",
            f"Attach the generated file named: {sample_path.name}",
            "Drag it into the GitHub issue; do not paste raw sessions.",
        ])
    else:
        lines.extend([
            "No sample is attached.",
            "The automatic redaction could not guarantee the sample was clean"
            + (f" (it still contained {', '.join(leaks)})" if leaks else "")
            + ", so it was withheld.",
            "Please describe the change in words instead, or hand-redact a few records yourself.",
        ])
    lines.extend([
        "",
        "How I checked",
        "",
        f"`./scripts/steward_check.py {agent}` on my own machine.",
        f"Steward and new-source flow: {STEWARD_DOC}",
    ])
    return "\n".join(lines) + "\n"


def _report(agent: str, result: dict, out_dir: Path, write_sample: bool = True) -> int:
    """Turn one scan result into steward-facing output. Returns the exit code."""
    verified = result.get("verified_version") or "unknown"
    installed = (result.get("installed") or {}).get("parsed_version")

    reason = _cannot_check_reason(agent, result)
    if reason:
        print(f"Cannot check {agent} yet.")
        print()
        print(reason)
        return EXIT_CANNOT_CHECK

    evidence = result.get("evidence") or {}
    diff = evidence.get("schema_diff") or {}
    count = _sample_count(result)

    if evidence.get("schema_matches_baseline") is True:
        print(f"All good: {agent} format matches the baseline ({count} sessions sampled).")
        print(f"Verified version in the support matrix: {verified}")
        verified_semver = agent_watch._extract_semver(verified) if verified else None
        if installed and verified_semver and agent_watch._compare_semver(installed, verified_semver) == 1:
            print(f"You are running {installed}, which is newer than the verified {verified}.")
            freshness = evidence.get("sample_freshness")
            if isinstance(freshness, dict) and freshness.get("is_stale") is False:
                print("Nothing is broken -- the matrix entry can be bumped to your version.")
            else:
                print("Keep the verified version unchanged until a session created by this CLI is checked.")
        return EXIT_OK

    print(f"Something changed in {agent}'s session format.")
    print()
    print(f"Sessions sampled: {count}")
    print(f"Version you are running: {installed or 'unknown'}")
    print(f"Version this repository verified: {verified}")
    print()
    print("What is different:")
    for line in _describe_diff(diff):
        print(line)
    print()

    sample_path: Path | None = None
    leaks: list[str] = []
    if write_sample:
        wanted: set[tuple[str, str]] = set()
        wanted_buckets: set[str] = set(diff.get("unknown_types") or [])
        for bucket, keys in (diff.get("unknown_keys") or {}).items():
            for k in keys:
                wanted.add((bucket, k))

        # Some formats keep monitored structure in a sibling JSON sidecar rather
        # than in the transcript itself. No transcript record can carry those
        # buckets, so harvest and redact the named sidecar independently.
        sidecar: dict | None = None
        sidecar_name = "summary.json"
        local = ((result.get("weekly") or {}).get("local_schema")) or {}
        sidecar_spec: tuple[str, Path] | None = None
        if agent == "grok" and isinstance(local.get("summary_file"), str):
            sidecar_spec = ("summary", Path(local["summary_file"]))
        elif agent == "fx":
            sampled = _sampled_files(result)
            if sampled:
                sidecar_spec = ("session", sampled[0].parent / "session.json")

        if sidecar_spec is not None:
            bucket, sidecar_path = sidecar_spec
            if sidecar_path.exists() and any(
                b.split(".")[0] == bucket for b in {b for b, _ in wanted} | wanted_buckets
            ):
                obj, _err = agent_watch._read_json_object(sidecar_path)
                if isinstance(obj, dict):
                    sidecar = _redact_records(agent, [obj])[0]
                    sidecar_name = sidecar_path.name

        records = _collect_drifting_records(agent, _sampled_files(result), wanted,
                                            wanted_buckets, max_records=20)
        sample_dir = out_dir / "redacted-sample"
        sample_path, leaks = _write_redacted_sample(
            agent, records, sidecar, sample_dir, sidecar_name=sidecar_name
        )

        if sample_path is not None:
            print(f"A redacted sample was written to: {sample_path}")
            print("Content values were replaced; structural type, role, subtype, and model values remain.")
        elif leaks:
            print("A sample was NOT written: after redaction it still contained "
                  + ", ".join(leaks) + ".")
            print("Please do not paste raw sessions; describe the change in words instead.")
        else:
            print("No sample could be extracted automatically for this agent's storage format.")

    body = _issue_body(agent, result, diff, sample_path, leaks)
    issue_path = out_dir / "issue.md"
    out_dir.mkdir(parents=True, exist_ok=True)
    issue_path.write_text(body, encoding="utf-8")

    print()
    print("Please open an issue with the text below (also saved to " + str(issue_path) + "):")
    print()
    print("-" * 72)
    print(body.rstrip())
    print("-" * 72)
    return EXIT_DRIFT


# --------------------------------------------------------------------------


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description="Re-verify one agent's session format against this repository's baseline.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("agent", nargs="?", help="Which agent to check, e.g. grok")
    parser.add_argument("--list-agents", action="store_true", help="Print the agents that can be checked.")
    parser.add_argument("--out", default=None, help="Where to write the report and any sample.")
    parser.add_argument("--timeout", type=int, default=12, help="Network timeout in seconds.")
    parser.add_argument("--no-sample", action="store_true", help="Do not write a redacted sample.")
    parser.add_argument("--verbose", action="store_true", help="Also print the raw scan output.")
    args = parser.parse_args(argv)

    known = _known_agents()
    if args.list_agents:
        for name in known:
            print(name)
        return EXIT_OK
    if not args.agent:
        parser.error("give the agent to check, for example: ./scripts/steward_check.py grok")

    agent = _resolve_agent(args.agent, known)
    if agent is None:
        print(f"'{args.agent}' is not an agent this repository monitors.")
        print("Known agents: " + ", ".join(known))
        return EXIT_CANNOT_CHECK

    out_dir = Path(args.out).expanduser() if args.out else DEFAULT_OUT / agent
    out_dir.mkdir(parents=True, exist_ok=True)

    print(f"Checking {agent} against this repository's baseline. This takes a minute.")
    print()
    try:
        result = _scan(agent, out_dir, timeout=args.timeout, verbose=args.verbose)
    except (RuntimeError, OSError) as exc:
        print(f"The check could not run: {exc}")
        return EXIT_CANNOT_CHECK

    return _report(agent, result, out_dir, write_sample=not args.no_sample)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
