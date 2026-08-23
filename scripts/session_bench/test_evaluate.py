"""Minimal evaluator tests: determinism, tie handling, input validation.

Run: python3 -m pytest scripts/session_bench/test_evaluate.py -q
"""
import json
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).parent
REPO = HERE.parent.parent


def run_eval(tmp_path, out_name="out.yml"):
    out = tmp_path / out_name
    r = subprocess.run(
        [sys.executable, str(HERE / "evaluate.py"),
         "--measurements", str(HERE / "measurements-2026-08-04.json"),
         "--checklist", str(HERE / "checklist-2026-08-04.yml"),
         "--out", str(out)],
        capture_output=True, text=True, cwd=REPO)
    return r, out


def test_deterministic(tmp_path):
    r1, o1 = run_eval(tmp_path, "a.yml")
    r2, o2 = run_eval(tmp_path, "b.yml")
    assert r1.returncode == 0, r1.stderr
    assert o1.read_text() == o2.read_text()


def test_matches_checked_in_data(tmp_path):
    r, out = run_eval(tmp_path)
    assert r.returncode == 0, r.stderr
    assert out.read_text() == (REPO / "docs/_data/session_bench.yml").read_text()


def test_equal_fractions_share_rank(tmp_path):
    import yaml
    r, out = run_eval(tmp_path)
    data = yaml.safe_load(out.read_text())
    by_frac = {}
    for a in data["agents"]:
        by_frac.setdefault((a["cleared"], a["scored"]), []).append(a["rank"])
    for ranks in by_frac.values():
        assert len(set(ranks)) == 1


def test_provisional_ranges_match_exhaustive_enumeration(tmp_path):
    from fractions import Fraction
    from itertools import product
    import yaml
    r, out = run_eval(tmp_path)
    data = yaml.safe_load(out.read_text())
    agents = data["agents"]
    prov = [a for a in agents if a.get("not_run", 0) > 0]
    expected = {a["slug"]: [None, None] for a in prov}
    for bits in product((0, 1), repeat=len(prov)):
        fracs = {}
        for a in agents:
            extra = 0
            for b, bit in zip(prov, bits):
                if b["slug"] == a["slug"]:
                    extra = bit * a["not_run"]
            fracs[a["slug"]] = Fraction(a["cleared"] + extra, a["scored"] + a["not_run"])
        for a in prov:
            rank = 1 + sum(1 for s, f in fracs.items()
                           if s != a["slug"] and f > fracs[a["slug"]])
            lo, hi = expected[a["slug"]]
            expected[a["slug"]] = [rank if lo is None else min(lo, rank),
                                   rank if hi is None else max(hi, rank)]
    for a in prov:
        assert [a["rank_best"], a["rank_worst"]] == expected[a["slug"]], a["slug"]


def test_invalid_state_rejected(tmp_path):
    bad = tmp_path / "bad.yml"
    src = (HERE / "checklist-2026-08-04.yml").read_text()
    bad.write_text(src.replace("{state: fail, evidence: \"tokens only, no dollar figure anywhere\"}",
                               "{state: maybe, evidence: \"x\"}", 1))
    r = subprocess.run(
        [sys.executable, str(HERE / "evaluate.py"),
         "--measurements", str(HERE / "measurements-2026-08-04.json"),
         "--checklist", str(bad), "--out", str(tmp_path / "o.yml")],
        capture_output=True, text=True, cwd=REPO)
    assert r.returncode != 0
    assert "invalid state" in r.stderr


def test_computed_gate_override_rejected(tmp_path):
    bad = tmp_path / "bad2.yml"
    src = (HERE / "checklist-2026-08-04.yml").read_text()
    bad.write_text(src.replace("  codex:\n    C1:",
                               "  codex:\n    S1: {state: pass, evidence: \"x\"}\n    C1:", 1))
    r = subprocess.run(
        [sys.executable, str(HERE / "evaluate.py"),
         "--measurements", str(HERE / "measurements-2026-08-04.json"),
         "--checklist", str(bad), "--out", str(tmp_path / "o.yml")],
        capture_output=True, text=True, cwd=REPO)
    assert r.returncode != 0
    assert "may not override" in r.stderr


def test_t2_not_run_makes_t3_not_run(tmp_path):
    import yaml
    bad = tmp_path / "t2nr.yml"
    src = (HERE / "checklist-2026-08-04.yml").read_text()
    assert 'T2: {state: fail, evidence: "no version marker (matrix: not_logged)"}' in src
    bad.write_text(src.replace(
        'T2: {state: fail, evidence: "no version marker (matrix: not_logged)"}',
        'T2: {state: not_run, evidence: "hypothetical: could not inspect"}', 1))
    out = tmp_path / "o.yml"
    r = subprocess.run(
        [sys.executable, str(HERE / "evaluate.py"),
         "--measurements", str(HERE / "measurements-2026-08-04.json"),
         "--checklist", str(bad), "--out", str(out)],
        capture_output=True, text=True, cwd=REPO)
    assert r.returncode == 0, r.stderr
    data = yaml.safe_load(out.read_text())
    cursor = next(a for a in data["agents"] if a["slug"] == "cursor")
    assert cursor["results"]["T2"] == "not_run"
    assert cursor["results"]["T3"] == "not_run"
    assert "unresolved" in cursor["notes"]["T3"]


def test_s4_fail_evidence_names_the_rule(tmp_path):
    import yaml
    r, out = run_eval(tmp_path)
    assert r.returncode == 0, r.stderr
    data = yaml.safe_load(out.read_text())
    by_slug = {a["slug"]: a for a in data["agents"]}
    assert by_slug["opencode"]["results"]["S4"] == "fail"
    assert "newest snapshot per message" in by_slug["opencode"]["notes"]["S4"]
    assert by_slug["codex"]["results"]["S4"] == "fail"
    assert "freelist" in by_slug["codex"]["notes"]["S4"]


def test_s4_not_run_when_no_rule_measured(tmp_path):
    import yaml
    r, out = run_eval(tmp_path)
    assert r.returncode == 0, r.stderr
    data = yaml.safe_load(out.read_text())
    by_slug = {a["slug"]: a for a in data["agents"]}
    assert by_slug["claude"]["results"]["S4"] == "not_run"
    assert "lossless" in by_slug["claude"]["notes"]["S4"]
    # Hermes carries an explicit reason: flagged snapshot, no rule for the ledger.
    assert "snapshot" in by_slug["hermes"]["notes"]["S4"]


def test_s4_passes_below_limit(tmp_path):
    import yaml
    meas = json.loads((HERE / "measurements-2026-08-04.json").read_text())
    meas["agents"]["claude"]["superseded_share_pct"] = 5.0
    meas["agents"]["claude"]["notes"]["superseded_share_pct"] = \
        "rule: hypothetical whole-source lossless collapse (fixture)"
    m = tmp_path / "m.json"
    m.write_text(json.dumps(meas))
    out = tmp_path / "o.yml"
    r = subprocess.run(
        [sys.executable, str(HERE / "evaluate.py"),
         "--measurements", str(m),
         "--checklist", str(HERE / "checklist-2026-08-04.yml"),
         "--out", str(out)],
        capture_output=True, text=True, cwd=REPO)
    assert r.returncode == 0, r.stderr
    data = yaml.safe_load(out.read_text())
    claude = next(a for a in data["agents"] if a["slug"] == "claude")
    assert claude["results"]["S4"] == "pass"
    assert claude["notes"]["S4"].startswith(
        "lossless collapse would remove 5.0%")
