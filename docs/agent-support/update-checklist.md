# Agent support update checklist

Use the [canonical format-check runbook](../../skills/agent-session-format-check/SKILL.md).
Do not maintain a second run order here.

Before recording a ceiling, require a session written by that build, a real tool call,
a non-zero baseline type count, passing discovery and parser checks, triaged schema drift,
and healthy usage probes. Keep direct failed prebump reports. Read the rebuild report
before --emit; verified drift belongs in normal fixtures with survive-parsing tests.

Usage/parsing changes require positive and negative cases before review. Run the stable
Xcode wrapper and read suite totals from xcresult against tools/release/test-count-baseline.txt.
An unexplained decrease fails the check. User-visible fixes need CHANGELOG and monthly notes;
Bug Fixes names defects in a released build only.

Record the app version from project.pbxproj and use git rev-parse --short HEAD as the
baseline. After the final CLI update, write the final weekly, then the matrix, ledger,
tracking paragraph and append-only finding rows. See [record ownership](workflow.md).
