---
name: review-skill
description: Run a deterministic headless Codex review→fix loop until the review comes back clean, with artifacts and a repo control file for between-round steering.
---

# review-skill

This skill provides a script that repeatedly:
1) runs `codex review` on a chosen diff scope,
2) if issues are found, runs `codex exec` to fix them automatically,
3) repeats until the reviewer outputs `REVIEW_CLEAN` or max rounds is reached.

## When to use
- You run `/review`, then fix, then `/review` again… and want that loop automated.
- You want deterministic, artifacted review/fix passes for local dev or CI-like flows.

## Quickstart

From repo root:

```bash
./scripts/codex_review_fix_loop.sh
```

Defaults:
- Scope: uncommitted changes
- Max rounds: 6
- Review effort: high for rounds 1-2, xhigh for rounds 3+
- Fix effort: high for rounds 1-4, xhigh for rounds 5+
- Artifacts: `.codex-review-artifacts/<timestamp>/`

## Live steering

Create/edit `.codex-review-control.md` in repo root.
The loop applies model/scope/context updates between rounds, and honors `status: stop` during in-flight review/fix heartbeat polling.

See:
- `references/control-file.md`

## Notes on models vs reasoning effort

This workflow treats `high` / `xhigh` as *reasoning effort* (Codex config key: `model_reasoning_effort`).
To set a specific model (e.g. `gpt-5.3-codex`), use:
- CLI flags on the wrapper script (`--review-model-id`, `--fix-model-id`)
- or control file syntax `review_model: gpt-5.3-codex@xhigh`

Review prompt behavior:
- Default mode is plain review (no injected prompt) for best CLI compatibility.
- Optional: `--review-prompt-mode prompt` (strict prompt mode) or `--review-prompt-mode auto` (prompt with fallback).
- Heartbeats print plain-language one-line summaries (default every 60s; configurable via `--heartbeat-seconds`).
- When recommendation changes to a non-routine action (for example `steer` or `stop`), the loop prints an `ALERT` line immediately.

## Safety

- Fix runs use `--full-auto` with `--sandbox workspace-write` (headless with sandboxed automation).
- Avoid `--yolo` unless you are already inside a hardened sandbox VM.

## Outputs

Run artifacts are written to:
- `.codex-review-artifacts/<timestamp>/`

Per round:
- `round-<n>-review.txt`
- `round-<n>-fix.txt`
- `round-<n>-meta.json`

Run-level:
- `control-snapshots.log`
- `summary.json`
- `.codex-review-artifacts/LATEST` pointer file
