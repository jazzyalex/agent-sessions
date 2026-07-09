# Handover skill + Stop hook

Global `/handover` skill and a `Stop` hook that offers a handover once per substantive
session. Entries go to a per-repo `RepoHandover.md` (newest-first). Spec:
`docs/superpowers/specs/2026-07-09-handover-skill-design.md`.

## Install
    bash tools/handover/install.sh
Installs to `~/.claude/skills/handover/`, `~/.claude/hooks/handover-offer.sh`, and merges a
`Stop` hook into `~/.claude/settings.json`. Idempotent (safe to re-run; preserves all other
settings keys).

## Tune
- `HANDOVER_MIN_TRANSCRIPT_LINES` (default 50) — substantiveness threshold.
- `HANDOVER_OFFER_MODE` (`context` default | `systemMessage`) — offer channel. Switch to
  `systemMessage` if the `additionalContext` nudge doesn't reliably make the assistant ask.

## Rollback
- Remove just the Stop entry (keeps everything else):
      jq 'del(.hooks.Stop)' ~/.claude/settings.json > /tmp/s && mv /tmp/s ~/.claude/settings.json
  Or restore the backup written at install time:
      mv ~/.claude/settings.json.pre-handover.bak ~/.claude/settings.json
- Remove the skill + hook:
      rm -rf ~/.claude/skills/handover ~/.claude/hooks/handover-offer.sh

## Tests
    bash tools/test_handover_lint.sh
    bash tools/test_handover_hook.sh
    bash tools/test_handover_install.sh

## Production smoke (verified 2026-07-09)
- Substantive session (≥50 transcript lines OR dirty tree) → emits `additionalContext` offer.
- Trivial session → silent.
- `stop_hook_active: true` → silent (loop guard).
- Merge preserved all 15 pre-existing `settings.json` keys; only `hooks.Stop` added.
