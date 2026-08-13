# Codex task: Session Bench public receipts repo

Owner: Alex (@jazzyalex). Prepared 2026-08-07 by Claude (main session).
Model to copy: github.com/phuryn/experiments ("when a post claims a number,
the receipt lives here") — see its root README, per-experiment folder
layout, and especially its Anonymization section (rules as code).

## Goal

A new public repo, **jazzyalex/session-bench**, holding the receipts behind
Session Bench (live at jazzyalex.github.io/agent-sessions/bench/): redacted
probe artifacts, measurement outputs, per-gate evidence, and the graphics —
so every cell on the leaderboard has an inspectable receipt. The scoring
engine stays in agent-sessions (scripts/session_bench/); this repo holds
data and links back.

## Hard privacy constraints (non-negotiable, read first)

The owner's real session content must never appear in the public repo.

1. **Only probe artifacts are publishable.** The 2026-08-04 probe sessions
   were created by one synthetic prompt ("List the files in the current
   directory, then say hello in one sentence.") — that content is safe.
   NOTHING from the owner's real working sessions is ever published: no
   corpus files, no excerpts, no titles, no paths. Corpus numbers stay
   aggregates only (they are already public in session_bench.yml).
2. **Redact even the probe artifacts.** Known contamination to handle:
   - Claude's probe ran with real HOME and repo cwd: its `attachment`
     events can embed CLAUDE.md / user-instruction content. Replace every
     attachment payload with `"<REDACTED: attachment, N bytes>"`, keeping
     type + byte count (sizes are the measurement; content is private).
   - Kimi's `config.update` carries a `systemPrompt` field → same
     placeholder treatment.
   - Vendor system prompts (Copilot's 52 KB `system.message`, any other
     harness-shipped prompt text): do NOT republish vendor prompt text —
     replace with `"<REDACTED: vendor system prompt, N bytes, sha256:…>"`.
     Byte count + hash preserve verifiability without redistribution.
   - Absolute paths → `<HOME>`, `<WORKDIR>`; username `alexm` must not
     appear anywhere; machine names, env vars, tokens, OAuth material,
     account ids, git remotes → placeholders.
3. **Rules as code, like the model repo:** `anonymize-rules.json` +
   `anonymize.py`, applied to every published artifact, checked in, and
   wired as a PostToolUse hook in the repo's `.claude/settings.json` so any
   agent session editing the repo scrubs its own writes.
4. **Leak validator with tests:** a `validate_no_leaks.py` that scans the
   whole repo for `/Users/`, `alexm`, `@gmail`, key/token patterns, and the
   repo must fail CI (or a pre-publish script) if any hit. Redaction is
   structure-preserving: line counts and byte counts of redacted fields are
   recorded next to each artifact so the bench numbers remain checkable.
5. **Nothing is pushed or made public by you.** Build the repo locally
   (no remote), run the validator, and hand the owner a diff-able tree plus
   a one-page "what got redacted" report. The owner creates the GitHub repo
   and pushes after review. Do not run any remote git operation.

## Repo structure (mirror phuryn/experiments)

```
session-bench/
  README.md                  # index table: waves, headline results, links to
                             # the live bench + launch post + agent-sessions
  LICENSE                    # MIT
  .claude/settings.json      # PostToolUse anonymize hook
  .claude/hooks/anonymize.py + anonymize-rules.json
  bench-v0.1-2026-08-04/
    README.md                # question, method, probe prompt, the board,
                             # per-gate summary, caveats (not-run gates,
                             # content-key heuristic limits, CLI-only scope)
    scoreboard.csv           # the 10×20 matrix + per-area + totals (from
                             # docs/_data/session_bench.yml in agent-sessions)
    probe-artifacts/         # REDACTED session files, one per harness
      codex-0.146.0.rollout.jsonl
      claude-2.1.220.session.jsonl
      … (8 artifacts; hermes/openclaw folders contain NOT-RUN.md explaining
         the failure evidence instead)
    measurements/            # measure.py output JSON per artifact +
                             # the manifest snapshot + evaluator output
    evidence/                # per-gate receipts: sqlite query transcripts
                             # (S3), kimi writer-trace notes (T3), drift
                             # ledger excerpts (T1/O4) — all redacted
    graphics/                # bench social card, probe bar chart PNGs
  previous-editions/         # empty; future waves land as new folders
```

## Sources on this machine

- Engine + inputs: `~/Repository/Codex-History/scripts/session_bench/`
  (measurements JSON, checklist YAML, evaluate.py, measure.py, tests).
- Generated board: `~/Repository/Codex-History/docs/_data/session_bench.yml`.
- Probe artifacts (the 2026-08-04 run):
  - Claude: `~/.claude/projects/-Users-alexm-Repository-Codex-History/c1c69d06-53ab-4466-8c0f-2fb0e81f627c.jsonl`
  - Copilot: `~/.copilot/session-state/16a42cfb-dd6c-4687-87b7-cf80fade0f6e/events.jsonl`
  - Antigravity: `~/.gemini/antigravity-cli/brain/e5cefa5b-b8ef-4fc5-a350-458e32f97cdf/.system_generated/logs/transcript.jsonl`
  - Kimi: `~/.kimi-code/sessions/wd_kimi-wd_66fd89e9db58/session_2371ec41-*/agents/main/wire.jsonl` (+ state.json sidecar)
  - Cursor: `~/.cursor/projects/private-tmp-*format-experiment*cursor*/agent-transcripts/*/*.jsonl`
  - Codex, OpenCode (sandbox db), Pi + the prebump report: already archived
    (byte counts verified against the manifest: 78,244 / 274,432 / 1,463) at
    `~/Repository/Codex-History/Marketing/formats-post-2026-08/probe-artifacts-raw/`
    — UNREDACTED, local-only, gitignored. Treat as sensitive input.
- Bench page/post for cross-links: `docs/bench/index.md`,
  `docs/_posts/2026-08-07-session-bench-launch.md`.
- Graphics: `docs/assets/bench-social-card.png` + the probe bar chart SVG
  inside the launch post (render to PNG for graphics/).

## Acceptance checklist

- [ ] Validator passes over the whole tree; zero occurrences of the
      username, home paths, emails, tokens, vendor prompt text.
- [ ] Every published artifact's byte count reconciles with
      measurements-2026-08-04.json, with redaction deltas documented
      (original vs redacted sizes listed per file).
- [ ] `measure.py` from agent-sessions, run against the published redacted
      artifacts, reproduces the redaction-adjusted numbers in
      measurements/ (document which numbers shift under redaction and why).
- [ ] README index matches the live bench board exactly (post-O3-correction:
      Pi 18/19, OpenClaw 17/18†, Claude 14/19, OpenCode 13/18†,
      Codex=Copilot=Kimi 12/19, Hermes 11/18†, Antigravity 9/19,
      Cursor 8/19) and reproduces the /bench/ Corrections section.
- [ ] No git remote configured; owner-review report written
      (`REVIEW-BEFORE-PUBLISH.md`: what was redacted, what was lost,
      what to double-check).

## Non-goals

- No harness re-runs, no new measurements, no rubric changes (v0.1 is
  frozen; this task is receipts, not science).
- No publishing of anything from `~/Repository/Session-Bench` (that project
  is being renamed Session Fidelity Lab and is out of scope here).
- No blog/site edits.
