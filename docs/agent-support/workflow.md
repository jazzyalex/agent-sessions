# Agent Support Workflow

This workflow defines how Agent Sessions tracks the latest supported agent versions and how we
detect upstream session format changes that could break JSON or JSONL parsing.

## Source of Truth
- Support matrix: `docs/agent-support/agent-support-matrix.yml`
- Memory bank: `docs/agent-json-tracking.md`
- Workflow: `docs/agent-support/README.md`
- Fixtures: `Resources/Fixtures/stage0/agents/**`

## Definitions
- Supported: An agent version that is less than or equal to `max_verified_version` for the
  current Agent Sessions version in the support matrix.
- Verified: A version that is represented by fixtures or captured sample logs and passes the
  relevant parser tests.
- Candidate: An upstream version newer than `max_verified_version` that has not been verified.

## Workflow
1. Identify the Agent Sessions version.
   - Use `MARKETING_VERSION` from `AgentSessions.xcodeproj/project.pbxproj`.
2. Read the update checklist.
   - Use `docs/agent-support/update-checklist.md` to gate the work.
3. Collect upstream agent versions.
   - Record the latest available versions in a scratch note; do not update the matrix yet.
4. Compare against the support matrix.
   - If no gaps, stop and record the check in `docs/agent-json-tracking.md`.
5. Run an impact scan for each newer version.
   - Inspect release notes or package diffs and search for storage paths, JSONL/JSON schema
     changes, migration flags, or renamed fields.
6. Classify risk.
   - Low risk: No storage or schema changes found.
   - Medium risk: Potential format change without samples.
   - High risk: Confirmed format changes or new storage layout.
7. If medium or high risk, acquire sample logs.
   - Capture a minimal session log for the new agent version.
   - Add or update fixtures and ensure parser tests pass.
   - Auto capture helper (Gemini/OpenCode): `./scripts/capture_latest_agent_sessions.py` writes the newest local session artifacts to `scripts/agent_captures/` for quick diffing and fixture updates.
   - Auto capture helper (Droid): `./scripts/droid_stream_schema_probe.py` runs `droid exec --output-format stream-json` and writes stream logs plus a schema report to `scripts/agent_captures/`.
8. Update documentation.
   - Update `docs/agent-json-tracking.md` with the change and evidence.
   - Update `docs/agent-support/agent-support-matrix.yml` with `max_verified_version`,
     `as_of_commit`, and `as_of_date`.

## Error-Proof Guardrails
- Never bump `max_verified_version` without fixtures or sample logs plus passing parser tests.
- Require two signals before declaring a format change:
  - Example: release notes plus diff evidence, or diff evidence plus sample log.
- If an agent does not log its version, keep `max_verified_version: "unknown"` and document
  the scope of verification in the memory bank.
- Do not remove unknown fields from parsing; preserve raw JSON for troubleshooting.

## Evidence Checklist
- Use `docs/agent-support/update-checklist.md` to verify all evidence before updates.
