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
import subprocess
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
FIXTURES = REPO / "Resources/Fixtures/stage0/agents"
GOLDEN = REPO / "Resources/Fixtures/stage0/as-core-contract.json"

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
        results[str(path.relative_to(REPO))] = parse(binary, source, path)
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
