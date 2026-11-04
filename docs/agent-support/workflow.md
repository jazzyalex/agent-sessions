# Agent support workflow

Follow the [canonical format-check runbook](../../skills/agent-session-format-check/SKILL.md)
from preflight through the final report. An authorized update check includes CLI updates;
a read-only review does not authorize mutation.

Records have separate jobs:

| Record | Job |
|---|---|
| agent-support-matrix.yml | Current verified ceiling, structured hold, one-line note |
| agent-support-ledger.yml | Claim, scope, evidence paths; note at most three sentences |
| ../agent-json-tracking.md | One paragraph of format changes |
| agent-format-tracker.jsonl | Append-only row per finding with bucket and confidence |

Legacy tracker buckets remain valid historical data. New triage uses handled, noise,
watch or candidate. Never rewrite old rows. The tracker integrity pytest checks every row.

A hold uses a JSON flow object (valid YAML) with quoted keys, for example
`hold: {"version":"2.4.1","reason":"HTTP 429","since":"2026-11-02"}`. It is dated
failed evidence, not an exemption: retry every held driver on the newest stable build.

Write records only from the final weekly after the last CLI update. Use the current
short HEAD as as_of_commit. Propose tooling, app fixes and records as separate commits;
commit and publication remain owner actions. See [monitoring](monitoring.md) for report
fields and scheduling. Only install.sh activates the weekly schedule.
