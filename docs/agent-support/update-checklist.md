# Agent Support Update Checklist

Use this checklist before changing the support matrix or memory bank.

## Prepare
- Record `MARKETING_VERSION` from `AgentSessions.xcodeproj/project.pbxproj`.
- Record the repo commit that will anchor the update.
- Note the UTC date for the update.

## Upstream check
- Collect upstream agent versions and record sources.
- Compare against `docs/agent-support/agent-support-matrix.yml`.
- Log the check in `docs/agent-json-tracking.md`, even if no updates are needed.
 - Prefer using `docs/agent-support/monitoring.md` (daily/weekly) to generate the check report.

## Impact scan
- Scan release notes or diffs for storage paths, JSON/JSONL schema changes, or new migrations.
- Require two signals before declaring a format change.
- Classify risk (low, medium, high).

## Evidence
- Capture sample logs or update fixtures for new versions.
- Run parser tests for affected agents.
- If parsing behavior changes, update `docs/CHANGELOG.md` and `docs/summaries/YYYY-MM.md`.

## Update docs
- Update `docs/agent-json-tracking.md` with evidence and file paths.
- Update `docs/agent-support/agent-support-matrix.yml` with the new `max_verified_version`,
  `as_of_commit`, and `as_of_date`.
 - Append a new AS release entry to `docs/agent-support/agent-support-ledger.yml`.
