#!/usr/bin/env python3
"""Contract test for the shared session core: parse every stage0 fixture with `as-core`
and compare against a committed golden file.

The same goldens must hold on macOS and Linux, so a parser that drifts between platforms
(or regresses on either) fails here. Session IDs and paths are excluded: an ID is a hash
of the file's absolute path, which differs per checkout and per container mount.

    python3 scripts/as_core_contract.py                     # check (default binary)
    python3 scripts/as_core_contract.py --binary /path/as-core
    python3 scripts/as_core_contract.py --update            # rewrite the goldens
"""
import argparse
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile

REPO = pathlib.Path(__file__).resolve().parent.parent
FIXTURES = REPO / "Resources/Fixtures/stage0/agents"
GOLDEN = REPO / "Resources/Fixtures/stage0/as-core-contract.json"

# DeepSeek Harness fixtures live with the tests and use descriptive names, while the parser
# only accepts canonical generation names (session.jsonl, session.v1.jsonl, .jsonl.zstd for
# the compressed form). Each is parsed through a temporary copy under its canonical name;
# plain and zstd of the same generation must agree, which also covers the bundled libzstd.
DSH_FIXTURES = REPO / "AgentSessionsTests/Resources/Fixtures/stage0/agents/deepseek-harness"

# Sources whose files record token usage; `stats` must agree across platforms for them.
# Dollars are not stored: they move with every bundled price-table update, so only whether a
# session was priced is pinned. Exact cost agreement is covered by the app's own tests.
STATS_SOURCES = {"claude", "codex", "copilot", "pi"}

# Fixture directory -> source name. `gemini` holds Antigravity's Gemini-CLI layout.
DIR_TO_SOURCE = {"gemini": "antigravity"}
# Fields that depend on where the file lives rather than on what it contains.
VOLATILE = {"id", "path", "schema"}


def parse(binary: str, source: str, path: pathlib.Path) -> dict:
    proc = subprocess.run([binary, "parse", source, str(path)],
                          capture_output=True, text=True)
    if proc.returncode != 0 or not proc.stdout.strip():
        message = (proc.stderr.strip().splitlines() or ["no output"])[-1]
        # Error text names the file; the absolute path differs per checkout and mount.
        return {"error": message.replace(str(path), str(path.relative_to(REPO)))}
    row = json.loads(proc.stdout.strip().splitlines()[-1])
    return {k: v for k, v in sorted(row.items()) if k not in VOLATILE}


def stats(binary: str, source: str, path: pathlib.Path) -> dict:
    proc = subprocess.run([binary, "stats", source, str(path)], capture_output=True, text=True)
    if proc.returncode != 0 or not proc.stdout.strip():
        return {"error": "stats failed"}
    row = json.loads(proc.stdout.strip().splitlines()[-1])
    return {
        "tokens": row.get("tokens"),
        "priced": row.get("costUSD") is not None,
        "unpricedModels": row.get("unpricedModels", []),
    }


def collect(binary: str) -> dict:
    sources = {s["name"] for s in (json.loads(line) for line in subprocess.run(
        [binary, "sources"], capture_output=True, text=True, check=True).stdout.splitlines())}
    results = {}
    for path in sorted(FIXTURES.rglob("*")):
        if not path.is_file() or path.name.startswith("."):
            continue
        # The agent directory is the first component under FIXTURES; several sources keep
        # their fixtures in sub-folders (cline/cli_tool, claude/subagent, ...).
        agent_dir = path.relative_to(FIXTURES).parts[0]
        source = DIR_TO_SOURCE.get(agent_dir, agent_dir)
        if source not in sources:
            continue
        row = parse(binary, source, path)
        if source in STATS_SOURCES and "error" not in row:
            row["stats"] = stats(binary, source, path)
        results[str(path.relative_to(REPO))] = row
    results.update(collect_deepseek(binary, sources))
    return results


def collect_deepseek(binary: str, sources: set) -> dict:
    if "deepseek-harness" not in sources or not DSH_FIXTURES.is_dir():
        return {}
    results = {}
    with tempfile.TemporaryDirectory() as tmp:
        for path in sorted(DSH_FIXTURES.glob("v[0-3]_minimal_session.jsonl*")):
            generation = int(path.name[1])
            canonical = "session" if generation == 0 else f"session.v{generation}"
            suffix = ".jsonl.zstd" if path.name.endswith(".zstd") else ".jsonl"
            target_dir = pathlib.Path(tmp) / path.name
            target_dir.mkdir()
            target = target_dir / (canonical + suffix)
            shutil.copy(path, target)
            row = parse(binary, "deepseek-harness", target)
            if "error" in row:
                row = {"error": row["error"].replace(str(target), path.name)}
            results[str(path.relative_to(REPO))] = row
    return results


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--binary", default=str(REPO / ".build/release/as-core"))
    ap.add_argument("--update", action="store_true")
    args = ap.parse_args()

    results = collect(args.binary)
    if not results:
        print("no fixtures parsed — wrong binary or fixture layout?", file=sys.stderr)
        return 2

    if args.update:
        GOLDEN.write_text(json.dumps(results, indent=2, ensure_ascii=False, sort_keys=True) + "\n")
        print(f"wrote {GOLDEN.relative_to(REPO)} ({len(results)} fixtures)")
        return 0

    if not GOLDEN.exists():
        print(f"missing {GOLDEN.relative_to(REPO)}; run with --update", file=sys.stderr)
        return 2
    expected = json.loads(GOLDEN.read_text())

    failures = []
    for name in sorted(set(expected) | set(results)):
        want, got = expected.get(name), results.get(name)
        if want != got:
            failures.append(f"{name}\n  expected: {json.dumps(want, ensure_ascii=False)}\n  actual:   {json.dumps(got, ensure_ascii=False)}")
    if failures:
        print(f"as-core contract: {len(failures)} of {len(expected)} fixtures differ\n", file=sys.stderr)
        print("\n".join(failures), file=sys.stderr)
        return 1
    print(f"as-core contract: {len(results)} fixtures match")
    return 0


if __name__ == "__main__":
    sys.exit(main())
