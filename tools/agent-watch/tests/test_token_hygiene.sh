#!/usr/bin/env bash
# The scheduled scan runs with a GitHub token in its environment and shells out
# to every agent CLI on the machine. Two leaks are easy to reintroduce and
# invisible in normal use, so they are pinned here:
#   1. a token in curl's argv is readable by any user via the process table;
#   2. a token in the inherited environment is ambient authority handed to a
#      dozen third-party binaries that have no use for it.
# Makes no network calls — `_run_cmd` is stubbed.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"

cd "$REPO_ROOT"
python3 - <<'PYEOF'
import importlib.util
import os
import sys

spec = importlib.util.spec_from_file_location("agent_watch", "scripts/agent_watch.py")
aw = importlib.util.module_from_spec(spec)
sys.modules["agent_watch"] = aw
spec.loader.exec_module(aw)

TOKEN = "ghp_tokenhygienecheck"
os.environ["GITHUB_TOKEN"] = TOKEN

passed = failed = 0


def check(ok, label):
    global passed, failed
    if ok:
        passed += 1
        print(f"  ok - {label}")
    else:
        failed += 1
        print(f"  NOT OK - {label}", file=sys.stderr)


# 1. Spawned commands must not inherit the credential.
check("GITHUB_TOKEN" not in aw._child_env(), "GITHUB_TOKEN stripped from child env")
check("GH_TOKEN" not in aw._child_env(), "GH_TOKEN stripped from child env")
check("PATH" in aw._child_env(), "PATH survives the strip")
rc, out, _ = aw._run_cmd(["/usr/bin/env"], timeout=10)
check(rc == 0 and TOKEN not in out, "a real spawned process cannot see the token")

# 2. The GitHub API call must carry the token in a 0600 config file, not argv.
seen = {}


def spy(argv, timeout):
    seen["argv"] = list(argv)
    if "--config" in argv:
        path = argv[argv.index("--config") + 1]
        seen["conf"] = open(path, encoding="utf-8").read()
        seen["mode"] = os.stat(path).st_mode & 0o777
        seen["path"] = path
    return 0, "{}", ""


aw._run_cmd = spy
aw._http_get_text("https://api.github.com/repos/o/r/releases/latest", timeout=5)
check(not any(TOKEN in a for a in seen["argv"]), "token absent from curl argv")
check(TOKEN in seen.get("conf", ""), "token present in the curl config file")
check(seen.get("mode") == 0o600, "curl config file is 0600")
check(not os.path.exists(seen["path"]), "curl config file deleted after the call")

# 3. Only api.github.com gets the credential.
seen.clear()
aw._http_get_text("https://example.com/releases", timeout=5)
check("--config" not in seen["argv"], "no credential sent to a non-GitHub host")

print("----")
print(f"PASSED={passed} FAILED={failed}")
sys.exit(1 if failed else 0)
PYEOF
