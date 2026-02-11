# Codex headless review→fix workflow

This repo includes a headless loop script that runs:

1. `codex review` (non-interactive)
2. if not clean, `codex exec` to apply fixes
3. repeats until the reviewer outputs `REVIEW_CLEAN` or the max rounds is reached

## Run

From repo root:

```bash
./scripts/codex_review_fix_loop.sh
```

Default review mode is plain (no injected review prompt) for CLI compatibility.
If you want prompt-injection behavior, pass:

```bash
./scripts/codex_review_fix_loop.sh --review-prompt-mode auto
```

Heartbeat summaries are enabled by default (every 60s) and use plain-language one-liners.
If recommendation changes to a non-routine action, an `ALERT` line is printed immediately.
To change interval:

```bash
./scripts/codex_review_fix_loop.sh --heartbeat-seconds 10
```

Artifacts are written to:

- `.codex-review-artifacts/<timestamp>/`
- `.codex-review-artifacts/LATEST` points to the most recent run directory

## Live steering

Create/edit `.codex-review-control.md` in repo root. Model/scope/context changes apply between rounds; `status: stop` is also honored during in-flight heartbeat polling.

See:
- `.agents/skills/review-skill/references/control-file.md`

## Make scripts executable

Depending on how you apply these files, you may need:

```bash
chmod +x .agents/skills/review-skill/scripts/codex_review_fix_loop.sh
chmod +x scripts/codex_review_fix_loop.sh
```
