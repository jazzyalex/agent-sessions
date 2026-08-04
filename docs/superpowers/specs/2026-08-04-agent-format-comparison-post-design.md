# The Rollout: "9 agents, 9 session formats" comparison post — design

Date: 2026-08-04
Status: approved frame (user picked options 2026-08-04); research in progress
Voice: docs/superpowers/the-rollout-voice.md applies in full.

## Concept

In-depth comparison of the session/transcript formats of all 9 agents Agent
Sessions supports, written from the unique position of a codebase that parses
all of them and has monitored them for drift weekly since 2026-03-31.

## Approved decisions

- **Method C:** controlled same-task run through every agent (reuse prebump
  driver infra) as the headline experiment + corpus stats over real local
  sessions as supporting data + the drift ledger for the evolvability section.
- **Roster:** the 9 active agents (Codex, Claude Code, Copilot, Cursor,
  OpenCode, Hermes, Antigravity, OpenClaw, Pi). Kimi gets a sidebar (wire
  format is the strangest of the set). Droid excluded.
- **Angle:** efficiency fact-first — open on the measured size spread for the
  identical task (real numbers, no invention). Readability/ownership
  (plaintext vs hex-encoded vs encrypted) closes the post; it is the best
  discussion hook for Reddit. Taxonomy is the mid-post spine.
- **Framing vs the live 07-14 six-format field study (decided 2026-08-04):**
  NEW-METHOD POST, not a re-tread. Lead with what July couldn't do: the
  controlled same-task experiment, the 4-month drift study, and the four
  never-documented formats (Antigravity, OpenClaw, Pi, Kimi). Link to 07-14
  for the corpus scorecard instead of repeating it. Register in
  Marketing/STATUS.md content pipeline (done).

## Structure (spine)

1. Opener: measured fact — same task, N-fold size spread across agents.
2. The three format families: nested-envelope JSONL (Codex, Claude, Copilot,
   Antigravity), flat JSONL (OpenClaw, Pi, Cursor transcripts), SQLite-backed
   (OpenCode, Hermes, Cursor hybrid). What each buys and costs.
3. Efficiency, measured: bytes/message, envelope overhead vs content, gzip
   ratio as verbosity proxy, base64/image bloat handling. Same-task table +
   corpus medians.
4. Evolvability: drift ledger since March — breaking vs additive changes,
   storage-layout migrations (Copilot flat→subdirs at 1.0, OpenCode and
   Hermes JSON→SQLite), who embeds a schema/protocol version.
5. Completeness: what each format records vs silently loses (usage/tokens,
   model names, subagent trees).
6. Kimi sidebar: wire.jsonl custom ops, Bitcask-style minidb, protocol_version.
7. Closer: readability/ownership — can you `tail -f` your own history? Cursor
   hex-encoded store.db, Copilot encryptedContent, vs plain JSONL. Soft CTA.

## Visuals (per voice guide: at least one, prefer original SVG)

- SVG format-family diagram (taxonomy).
- Bytes-per-identical-task chart (SVG, dataviz conventions, light+dark).
- Small comparison table for the readability/completeness matrix.

## Rules

- Every number traces to a measurement or a repo doc. No invented stats.
- No competitor punching; factual format observations only, tradeoffs named.
- Redact all excerpts (paths, prompts, tokens) — structure only.

## Research plan (cheap subagents, read-only)

1. Corpus stats per agent from local session stores (aggregates only).
2. Drift-timeline scorecard from docs/agent-json-tracking.md +
   docs/agent-support/agent-support-ledger.yml.
3. One redacted, annotated schema excerpt per format.
4. Prior-art scan: existing published comparisons of agent session formats.

Then: same-task live runs (main session, staged carefully — some agents need
real-home auth; OpenClaw known to need fresh sign-in). Then draft.
