#!/usr/bin/env python3
"""Generate a pre-support research report for a new AgentSessions provider."""

from __future__ import annotations

import argparse
import datetime as dt
import os
import re
import shutil
import sys
from pathlib import Path


def slugify(value: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-")
    return slug or "agent"


def repeated_csv(values: list[str]) -> list[str]:
    items: list[str] = []
    for value in values:
        for part in value.split(","):
            part = part.strip()
            if part:
                items.append(part)
    return items


def command_probe(command: str) -> tuple[str, str]:
    path = shutil.which(command)
    if path:
        return ("found", path)
    return ("missing", "")


def root_probe(root: str) -> tuple[str, str]:
    expanded = os.path.expandvars(os.path.expanduser(root))
    path = Path(expanded)
    if path.exists():
        if path.is_dir():
            try:
                count = sum(1 for _ in path.iterdir())
            except OSError as exc:
                return ("exists-unreadable", f"{path} ({exc})")
            return ("exists-dir", f"{path} ({count} immediate entries)")
        return ("exists-file", str(path))
    return ("missing", str(path))


def markdown_table(rows: list[tuple[str, str, str]]) -> str:
    out = ["| Item | Result | Evidence |", "| --- | --- | --- |"]
    for item, result, evidence in rows:
        out.append(f"| {item} | {result} | {evidence or '-'} |")
    return "\n".join(out)


def build_report(args: argparse.Namespace) -> str:
    today = dt.date.today().isoformat()
    commands = repeated_csv(args.command)
    install_commands = repeated_csv(args.install_command)
    test_commands = repeated_csv(args.test_command)
    roots = repeated_csv(args.root)
    urls = repeated_csv(args.url)
    agent_key = args.agent_key or slugify(args.agent)
    is_new_provider = args.work_type == "new_provider"
    format_gate_status = "N/A" if is_new_provider else "TODO"
    format_gate_evidence = "No existing AgentSessions provider baseline yet." if is_new_provider else "TODO"
    discovery_gate_status = "N/A" if is_new_provider else "TODO"
    discovery_gate_evidence = "No existing AgentSessions discovery contract yet." if is_new_provider else "TODO"
    format_check_intro = (
        "This is a new provider, so existing-provider format checks are not available yet. "
        "Use this section only after provider support lands and `agent_watch.py` has a baseline."
        if is_new_provider
        else "Run this before any verified-version bump or public claim for an existing provider."
    )
    if is_new_provider:
        format_check_section = f"""{format_check_intro}

Status:
- N/A before AgentSessions has a provider baseline, fixtures, and `agent_watch.py` config for `{agent_key}`.
- Do not run weekly/prebump monitor commands for this provider until support lands.
"""
    else:
        format_check_section = f"""{format_check_intro}

```bash
cd {args.repo}
./scripts/agent_watch.py --mode weekly
# If recommended, or before max_verified_version bumps:
./scripts/agent_watch.py --mode prebump --agent {agent_key}
```

Report path:
- TODO: `scripts/probe_scan_output/agent_watch/.../report.json`

Fields to record:
- `verified_version`:
- `installed.parsed_version`:
- `upstream.parsed_version`:
- `weekly.local_schema.file`:
- `weekly.schema_diff`:
- `evidence.schema_matches_baseline`:
- `evidence.sample_freshness.is_stale`:
- `probes[*].ok`:
- `weekly.discovery_path_contract`:
- `severity`:
- `recommendation`:
- prebump exit code:
"""

    command_rows = [(cmd, *command_probe(cmd)) for cmd in commands]
    root_rows = [(root, *root_probe(root)) for root in roots]

    url_lines = "\n".join(f"- {url}" for url in urls) if urls else "- TODO: add official docs URLs"
    install_lines = "\n".join(f"- `{cmd}`" for cmd in install_commands) if install_commands else "- TODO: official install command, package/source URL, checksum if available."
    test_lines = "\n".join(f"- `{cmd}`" for cmd in test_commands) if test_commands else "- TODO: safe read-only test-session command."
    command_table = markdown_table(command_rows) if command_rows else "_No command probes supplied._"
    root_table = markdown_table(root_rows) if root_rows else "_No storage-root probes supplied._"

    return f"""# {args.agent} Pre-Support Research

Date: {today}
Repository: `{args.repo}`
Region under test: {args.region}
Required language: {args.language}
Required plan path: {args.plan}

## Decision

Work type: {args.work_type}
Status: TODO: ACCEPT / DEFER / REJECT

Summary:
- TODO: one-sentence maintainer decision.

## Official Sources

{url_lines}

## Hard Gates

| Gate | Status | Evidence | Blocker |
| --- | --- | --- | --- |
| Region availability | TODO | TODO | TODO |
| English docs/UI/CLI | TODO | TODO | TODO |
| Free or existing-plan testability | TODO | TODO | TODO |
| Install/auth feasible on this Mac | TODO | TODO | TODO |
| Real local transcript/session data generated | TODO | TODO | TODO |
| Redacted fixture possible without secrets | TODO | TODO | TODO |
| Format check evidence for existing provider | {format_gate_status} | {format_gate_evidence} | {"-" if is_new_provider else "TODO"} |
| Discovery contract still matches | {discovery_gate_status} | {discovery_gate_evidence} | {"-" if is_new_provider else "TODO"} |
| Binary lifecycle known | TODO | TODO | TODO |
| Marketing claims match validated surfaces | TODO | TODO | TODO |
| Maintainer can re-test later | TODO | TODO | TODO |

## Local Command Probes

{command_table}

## Binary Install And Cleanup Plan

Install commands or official package references:
{install_lines}

Pre-install inventory to record before any install/login:
- Existing binary lookup:
- Existing app bundle path / bundle ID / version, if any:
- Existing support/state roots and entry counts:
- Existing package manager ownership, if applicable:
- Snapshot timestamp:

Verification to record:
- Binary path:
- Version:
- Help output summary:
- App bundle path / bundle ID / version, if applicable:
- Auth/login requirements:
- Uninstall command:
- Test-only state paths to remove if rejected:

## Local Storage Root Probes

{root_table}

## Existing Provider Format Check

{format_check_section}

## Safe Session Generation Plan

Use a disposable project under `/tmp`, do not connect real work accounts, and ask before installing or logging in.

```bash
mkdir -p /tmp/as-agent-lab/{slugify(args.agent)}-project
cd /tmp/as-agent-lab/{slugify(args.agent)}-project
git init
printf 'print("hello from fixture")\\n' > hello.py
# TODO: run the provider read-only against hello.py and capture exact command/output.
```

Planned or observed test commands:
{test_lines}

Required test sessions:
- Normal read-only session:
- Follow-up/continued session, if supported:
- Tool call/tool result producing session, if free plan allows:
- Auth/region/plan failure transcript, if full session creation is blocked:

## Real Format Notes

Record only verified facts here.

- Storage layout:
- Session ID fields:
- Timestamp shapes:
- Event type names:
- Role fields:
- Content shapes:
- Tool call/result shapes:
- cwd/model fields:
- Artifact-only directories to skip:
- Subagent/session hierarchy behavior:

## Subagent Evaluation

- Official-doc/region/plan researcher:
- Local schema inspector:
- Parser/integration surface auditor:
- Fixture redaction reviewer:
- Marketing/docs claim reviewer:

## Fixture Plan

- Fixture paths:
- Event families preserved:
- Redactions performed:
- Raw capture path, if any:
- Secret scan command:
- Secret scan result:

## Implementation Scope If Accepted

- Parser:
- Discovery:
- Search:
- Preferences/settings:
- Unified sessions UI:
- Analytics:
- Resume/copy command:
- Active/live status:
- Usage tracking:
- Docs/public wording:

## Support Record Updates If Accepted

- `docs/agent-support/agent-support-matrix.yml`:
- `docs/agent-support/agent-support-ledger.yml`:
- `docs/agent-json-tracking.md`:
- `docs/CHANGELOG.md`:
- `docs/summaries/YYYY-MM.md`:

## Marketing Plan If Accepted

- Verified support wording:
- Unsupported surfaces to avoid mentioning:
- Screenshot/GIF needed:
- Contributor credit:
- Release note:
- Social copy:

## Validation Plan

```bash
git diff --check
./scripts/xcode_test_stable.sh
xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug -destination 'platform=macOS,arch=arm64' build
```

## Rejection/Deferral Note

Use this if any hard gate fails:

```text
Thanks for the contribution. After maintainer review, I do not plan to support {args.agent} in AgentSessions at this time.

I cannot reliably verify {args.agent} compatibility from my environment, and <specific blocker> makes ongoing QA and support impractical for this project. I do not want to ship provider support that I cannot maintain or describe accurately.

I appreciate the work here, but I am keeping provider support limited to tools I can verify and support locally.
```
"""


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--agent", required=True, help="Provider/agent name under evaluation.")
    parser.add_argument("--repo", default="/Users/alexm/Repository/Codex-History", help="AgentSessions repo root.")
    parser.add_argument("--region", default="United States", help="Region being tested.")
    parser.add_argument("--language", default="English", help="Required usable language.")
    parser.add_argument("--plan", default="free or existing plan", help="Required plan/access level.")
    parser.add_argument("--url", action="append", default=[], help="Official docs URL. Repeat or comma-separate.")
    parser.add_argument("--command", action="append", default=[], help="CLI command to probe. Repeat or comma-separate.")
    parser.add_argument("--install-command", action="append", default=[], help="Official install command or package reference. Repeat or comma-separate.")
    parser.add_argument("--test-command", action="append", default=[], help="Safe test-session command. Repeat or comma-separate.")
    parser.add_argument("--root", action="append", default=[], help="Expected local storage root. Repeat or comma-separate.")
    parser.add_argument("--work-type", choices=["new_provider", "existing_provider_update", "public_claim"], default="new_provider", help="Kind of provider-support work.")
    parser.add_argument("--agent-key", help="agent_watch.py provider key for existing-provider checks. Defaults to slugified --agent.")
    parser.add_argument("--output", help="Output Markdown path. Defaults to /tmp/<agent>-presupport-report.md.")
    args = parser.parse_args(argv)

    output = Path(args.output or f"/tmp/{slugify(args.agent)}-presupport-report.md")
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(build_report(args), encoding="utf-8")
    print(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
