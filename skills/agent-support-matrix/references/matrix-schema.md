# Support Matrix Schema

Location: `docs/agent-support/agent-support-matrix.yml`

## Top-Level Fields
- `agent_sessions_version`: Current Agent Sessions version (from MARKETING_VERSION).
- `as_of_commit`: Commit SHA for the matrix snapshot.
- `as_of_date`: UTC date of the snapshot (YYYY-MM-DD).
- `workflow_doc`: Path to the workflow document.
- `notes`: Short reminders about how the matrix is derived.
- `agents`: Map of agent keys to per-agent entries.

## Per-Agent Entry
- `max_verified_version`: Highest version verified for this Agent Sessions version.
  - Use a string, e.g., `"2.0.71"`.
  - Use `"unknown"` when the agent does not log a version.
- `version_field`: Field path where the agent version is found in logs.
- `evidence_fixtures`: List of fixture paths used as evidence.

## Update Rules
- Do not change `max_verified_version` without fixtures or sample logs plus passing parser tests.
- If the agent does not log its version, keep `max_verified_version: "unknown"` and document
  verification scope in `docs/agent-json-tracking.md`.
