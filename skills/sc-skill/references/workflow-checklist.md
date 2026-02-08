# Workflow Checklist

## Pre-capture

1. Close unrelated windows and disable transient UI noise (notifications/popovers).
2. Set app appearance and content state explicitly.
3. Apply one window preset:
- `testing`: consistent QA/regression evidence.
- `marketing`: larger composition for docs/site assets.

## Capture

1. Run a single capture with `sc_capture.sh` or batch with `sc_capture_suite.sh`.
2. For async-heavy views (like session transcripts), use settle controls as needed:
- `--delay`, `--settle-timeout`, `--settle-poll`.
3. Keep filenames stable and meaningful:
- `screen-main-list.png`
- `screen-session-transcript.png`
- `screen-onboarding-analytics.png`
4. Keep sidecar `.json` files for traceability.
5. Metadata sidecars are optional; use `--metadata` only when traceability is needed.
6. `AgentSessions` captures auto-retry until transcript is non-blank by default; tune with `--transcript-timeout` and `--transcript-poll` (fast default is ~0.25s window).
7. AgentSessions default transcript recovery includes a selection nudge (`key down` + `0.5s` pause); tune with `--nudge-pause` / `--nudge-attempts`.
8. Use mode-based max edge defaults (`--max-edge auto`: testing `1800`, marketing `2560`) and keep output optimization enabled.
9. Keep AgentSessions windows normalized (`--window-preset auto` default) so screenshots remain realistic and not visually squashed.
10. Transcript readiness timeout fails capture by default; use `--allow-blank-transcript` only when intentional.

## Post-capture

1. Verify dimensions and framing consistency across the set.
2. Check for sensitive information before publishing.
3. Keep raw originals; export edited variants separately.
4. Batch runs close app windows when done unless `--no-close-after-suite` is passed.
5. Single captures close app windows by default unless `--no-close-window` is passed.

## Repeatability Rules

- Do not manually drag/resize windows between shots.
- Do not mix tools in one set unless required; if mixed, record that in metadata.
- For CI or repeated QA, use manifest-driven batches.
