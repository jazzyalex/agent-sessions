---
name: sc-skill
description: Capture deterministic macOS screenshots for testing, docs, release notes, and marketing assets. Use when asked to automate app screenshots, batch-generate screenshot sets, standardize window sizing/composition, or choose between Peekaboo and native macOS screenshot tooling.
---

# SC Skill

## Overview

Use this skill to produce repeatable screenshots for two modes:
- `testing`: stable evidence screenshots for QA/regression workflows.
- `marketing`: polished, consistently framed screenshots for docs/site/release assets.

This skill is macOS-first and uses `Peekaboo` as primary automation with native `screencapture` fallback.

## Quick Start

1. Normalize window size and position:
```bash
skills/sc-skill/scripts/sc_window_preset.sh --app "AgentSessions" --preset marketing
```

2. Capture one screenshot (auto-select tool):
```bash
skills/sc-skill/scripts/sc_capture.sh \
  --app "AgentSessions" \
  --mode marketing \
  --delay 0.25 \
  --max-edge auto \
  --window-preset auto \
  --output artifacts/screenshots/agent-sessions-main.png
```

3. Run a manifest batch:
```bash
skills/sc-skill/scripts/sc_capture_suite.sh \
  --manifest skills/sc-skill/references/examples/agent-sessions.tsv \
  --outdir artifacts/screenshots
```

## Workflow

1. Choose mode:
- `testing`: prioritize determinism and speed.
- `marketing`: prioritize composition consistency.

2. Choose tool:
- Start with `--tool auto` (defaults to Peekaboo when available and permitted).
- Use `--tool native` when you need zero external dependency and simple window-region capture.

3. Enforce layout before capture:
- Always run `sc_window_preset.sh` first.
- Use consistent presets across runs to reduce visual drift.

4. Capture and archive:
- Save to `artifacts/screenshots/...`.
- Sidecar metadata (`.json`) is opt-in via `--metadata`; default runs keep artifacts cleaner.
- Default output uses mode-based max edge (`--max-edge auto`): `testing=1800`, `marketing=2560`, optimized/compressed for sharing/upload.
- AgentSessions windows are normalized to a realistic working preset before capture (mode-based `testing`/`marketing`) to avoid distorted/compressed UI composition.
- Single capture closes the target app window by default (`--no-close-window` to keep it open).
- Suite runs close captured app windows after all requested screenshots by default (`--no-close-after-suite` to keep them open).
- For `AgentSessions`, transcript readiness retry includes a built-in selection nudge (key down + `0.5s` pause) to force transcript loading before capture.
- Default transcript readiness remains fast-fail if loading still does not occur after nudge attempts.
- If transcript readiness times out, capture fails fast by default; pass `--allow-blank-transcript` only when blank transcript output is acceptable.

## Guardrails

- Never run captures from XCTest-driven launches when validating user-visible UI behavior; use a normal app launch.
- Keep screenshot naming stable and descriptive (`screen-purpose-state.png`).
- Avoid manual resize/drag between shots; use presets.
- For multi-shot runs, use the suite manifest instead of ad-hoc commands.

## Resources

- `scripts/sc_window_preset.sh`: deterministic window sizing/placement.
- `scripts/sc_capture.sh`: single-shot capture with Peekaboo/native fallback.
- `scripts/sc_capture_suite.sh`: manifest-driven batch capture.
- `references/tool-matrix.md`: tooling decision matrix and tradeoffs.
- `references/workflow-checklist.md`: repeatable QA/marketing checklist.
