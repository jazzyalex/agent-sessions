---
name: agent-support-matrix
description: Maintain Agent Sessions agent support matrix and JSON/JSONL parsing compatibility. Use when checking upstream agent releases for session format changes, updating max verified versions in docs/agent-support/agent-support-matrix.yml, or updating docs/agent-json-tracking.md and fixtures/tests.
---

# Agent Support Matrix

## Overview

Keep the support matrix and memory bank accurate, and gate updates with evidence so parsing
regressions are avoided.

## Quick Start

1. Read `docs/agent-support/workflow.md`.
2. Compare upstream agent versions to `docs/agent-support/agent-support-matrix.yml`.
3. If gaps exist, run an impact scan, collect evidence, and update fixtures/tests before
   bumping `max_verified_version`.

## Workflow

- Determine the current Agent Sessions version from `AgentSessions.xcodeproj/project.pbxproj`
  `MARKETING_VERSION`.
- Use `references/impact-scan.md` to inspect upstream releases for format changes.
- Follow `references/update-checklist.md` before updating docs or fixtures.

## Guardrails

- Do not bump `max_verified_version` without fixtures or sample logs plus passing parser tests.
- If an agent does not log a version, keep `max_verified_version: "unknown"` and document
  verification scope in `docs/agent-json-tracking.md`.

## References

- `references/matrix-schema.md` for matrix fields and update rules.
- `references/impact-scan.md` for format change detection heuristics.
- `references/update-checklist.md` for the evidence checklist.
