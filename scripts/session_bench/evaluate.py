#!/usr/bin/env python3
"""Session Bench evaluator.

Reads a measurements manifest (probe + corpus numbers) and the manual-gate
checklist, computes the Signal gates from thresholds, merges verdicts, and
emits docs/_data/session_bench.yml — the file the /bench/ page renders.

The scores file is generated, never hand-edited. To dispute a score, dispute
a measurement or a checklist evidence line and re-run this.

Usage:
  python3 scripts/session_bench/evaluate.py \
      --measurements scripts/session_bench/measurements-2026-08-04.json \
      --checklist scripts/session_bench/checklist-2026-08-04.yml \
      --out docs/_data/session_bench.yml
"""
from __future__ import annotations

import argparse
import json
from fractions import Fraction
from pathlib import Path

try:
    import yaml  # type: ignore
except ImportError:  # pragma: no cover
    yaml = None

S1_MAX_BYTES = 10 * 1024
S2_MIN_CONTENT_SHARE = 25.0
S3_MAX_FIXED_RECORD = 25 * 1024

AGENT_META = {
    "pi":          ("Pi", "Pi", "Flat parent-linked JSONL"),
    "openclaw":    ("OpenClaw", "OClaw", "Flat parent-linked JSONL"),
    "claude":      ("Claude Code", "Claude", "Nested-envelope JSONL"),
    "opencode":    ("OpenCode", "OCode", "SQLite (session/message/part rows)"),
    "codex":       ("Codex", "Codex", "Nested-envelope JSONL"),
    "copilot":     ("Copilot CLI", "Copilot", "Nested-envelope JSONL (event-sourced)"),
    "hermes":      ("Hermes", "Hermes", "SQLite ledger + FTS"),
    "kimi":        ("Kimi Code", "Kimi", "Wire-op journal (JSONL)"),
    "antigravity": ("Antigravity", "AntiG", "Step-typed JSONL"),
    "cursor":      ("Cursor Agent", "Cursor", "Flat JSONL + binary metadata DB"),
}

AREAS = ["Signal", "Completeness", "Stability", "Openness", "Tooling"]


def compute_signal(agent: str, m: dict) -> dict:
    """Return {gate_id: {state, evidence}} for S1-S3 from measurements."""
    out = {}
    notes = m.get("notes") or {}
    pb = m.get("probe_bytes")
    if pb is None:
        out["S1"] = {"state": "not_run",
                     "evidence": notes.get("probe_bytes", "probe could not run")}
    else:
        state = "pass" if pb <= S1_MAX_BYTES else "fail"
        ev = f"probe wrote {pb:,} bytes (limit {S1_MAX_BYTES:,})"
        if "probe_bytes" in notes:
            ev += f"; {notes['probe_bytes']}"
        out["S1"] = {"state": state, "evidence": ev}
    share = m["corpus_content_share"]
    ev = f"work-product text is {share}% of corpus bytes (floor {S2_MIN_CONTENT_SHARE}%)"
    if "corpus_content_share" in notes:
        ev += f" — {notes['corpus_content_share']}"
    out["S2"] = {"state": "pass" if share >= S2_MIN_CONTENT_SHARE else "fail", "evidence": ev}
    mx = m["max_fixed_record_bytes"]
    if mx is None:
        if m.get("fixed_dump_found") is False:
            out["S3"] = {"state": "pass",
                         "evidence": notes.get("max_fixed_record_bytes",
                                               "no fixed-cost dump records found")}
        else:
            out["S3"] = {"state": "not_run",
                         "evidence": notes.get("max_fixed_record_bytes", "not measured")}
    else:
        ev = f"largest bookkeeping record {mx:,} bytes (limit {S3_MAX_FIXED_RECORD:,})"
        if "max_fixed_record_bytes" in notes:
            ev += f" — {notes['max_fixed_record_bytes']}"
        out["S3"] = {"state": "pass" if mx <= S3_MAX_FIXED_RECORD else "fail", "evidence": ev}
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--measurements", required=True)
    ap.add_argument("--checklist", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    if yaml is None:
        raise SystemExit("pyyaml required: pip install pyyaml")

    meas = json.loads(Path(args.measurements).read_text())
    chk = yaml.safe_load(Path(args.checklist).read_text())
    gates = chk["gates"]
    scored_gates = [g for g in gates if not g.get("untested")]

    VALID_STATES = {"pass", "fail", "not_run"}
    computed_ids = {g["id"] for g in gates if g.get("computed")}

    agents_out = []
    for slug, (name, short, fmt) in AGENT_META.items():
        m = meas["agents"][slug]
        cells = compute_signal(slug, m)
        for gid, v in (chk["verdicts"][slug] or {}).items():
            if gid in computed_ids:
                raise SystemExit(f"{slug}: checklist may not override computed gate {gid}")
            if v.get("state") not in VALID_STATES:
                raise SystemExit(f"{slug} {gid}: invalid state {v.get('state')!r}")
            if not v.get("evidence"):
                raise SystemExit(f"{slug} {gid}: evidence is required")
            cells[gid] = v
        results, notes = {}, {}
        cleared = scored = not_run = 0
        area_pass = {a: 0 for a in AREAS}
        area_scored = {a: 0 for a in AREAS}
        for g in gates:
            gid, area = g["id"], g["area"]
            if g.get("untested"):
                results[gid] = "untested"
                notes[gid] = g["desc"]
                continue
            cell = cells.get(gid)
            if cell is None:
                raise SystemExit(f"missing verdict: {slug} {gid}")
            state = cell["state"]
            results[gid] = state
            notes[gid] = cell["evidence"]
            if state == "not_run":
                not_run += 1
                continue
            scored += 1
            area_scored[area] += 1
            if state == "pass":
                cleared += 1
                area_pass[area] += 1
        agents_out.append({
            "slug": slug, "name": name, "short": short, "format": fmt,
            "version": m["version"],
            "cleared": cleared, "scored": scored, "not_run": not_run,
            "score_pct": round(100.0 * cleared / scored, 1),
            "area_scores": {a: f"{area_pass[a]}/{area_scored[a]}" for a in AREAS},
            "results": results, "notes": notes,
        })

    # Rank by exact fraction cleared (standard competition ranking on ties).
    for a in agents_out:
        a["_frac"] = Fraction(a["cleared"], a["scored"])
    agents_out.sort(key=lambda a: (-a["_frac"], a["name"]))
    prev_key, prev_rank = None, 0
    for i, a in enumerate(agents_out, 1):
        key = a["_frac"]
        a["rank"] = prev_rank if key == prev_key else i
        prev_key, prev_rank = key, a["rank"]

    # Provisional rank ranges via exhaustive enumeration: assign pass/fail to
    # every not_run cell, rank each complete board (all denominators equal),
    # and record each provisional agent's actual min/max rank across boards.
    from itertools import product
    provisional = [a for a in agents_out if a["not_run"] > 0]
    if provisional:
        ranges = {a["slug"]: [None, None] for a in provisional}
        for bits in product((0, 1), repeat=len(provisional)):
            fracs = {}
            for a in agents_out:
                full = a["scored"] + a["not_run"]
                extra = 0
                for b, bit in zip(provisional, bits):
                    if b is a:
                        extra = bit * a["not_run"]
                fracs[a["slug"]] = Fraction(a["cleared"] + extra, full)
            for a in provisional:
                rank = 1 + sum(1 for s, f in fracs.items()
                               if s != a["slug"] and f > fracs[a["slug"]])
                lo, hi = ranges[a["slug"]]
                ranges[a["slug"]] = [rank if lo is None else min(lo, rank),
                                     rank if hi is None else max(hi, rank)]
        for a in provisional:
            a["provisional"] = True
            a["rank_best"], a["rank_worst"] = ranges[a["slug"]]
    for a in agents_out:
        del a["_frac"]

    out = {
        "version": meas["bench_version"],
        "data_date": meas["data_date"],
        "generated_by": "scripts/session_bench/evaluate.py",
        "surface": meas["probe"]["surface"],
        "probe_prompt": meas["probe"]["prompt"],
        "methodology_url": "https://github.com/jazzyalex/agent-sessions/tree/main/scripts/session_bench",
        "scored_gate_count": len(scored_gates),
        "gates": [{k: v for k, v in g.items() if k != "computed"} for g in gates],
        "agents": agents_out,
    }
    header = ("# GENERATED by scripts/session_bench/evaluate.py — do not hand-edit.\n"
              "# Inputs: measurements + checklist under scripts/session_bench/.\n")
    Path(args.out).write_text(header + yaml.safe_dump(out, sort_keys=False, allow_unicode=True))
    for a in agents_out:
        print(f"{a['rank']:>2}. {a['name']:<12} {a['cleared']}/{a['scored']}"
              f" ({a['score_pct']}%)" + (f"  [{a['not_run']} not run]" if a["not_run"] else ""))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
