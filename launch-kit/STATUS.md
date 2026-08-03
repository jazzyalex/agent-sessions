# Launch Kit — STATUS

**Last updated:** 2026-07-06 (Monday) — after Alex's "go"
**Branch:** `auto/launch-kit` (created off `feature/transcript-redesign-v5`)
**State:** COMPLETE — all four deliverables + REPORT.md written. See `REPORT.md`.

---

## Timeline note (kept for the record)

- Work **started Saturday 2026-07-04 ~21:00 PDT**, inside the credit window. Setup done (branch, folder, ground truth).
- Session **idled and resumed Monday 2026-07-06 08:28 PDT**, past the Sunday 05:00 credit reset. Per the credit guard I **paused before writing deliverables** rather than spend post-reset Opus budget unprompted, and asked Alex to confirm.
- **Alex replied "go"** → wrote all four deliverables + `REPORT.md` in one pass on this week's budget. Every X post verified ≤280 chars.

---

## Done
- [x] Branch `auto/launch-kit` created (per explicit instruction). Working tree carries the uncommitted `feature/transcript-redesign-v5` changes that rode along — **not** mine, and I will **never** stage them. Commits will include **only** `launch-kit/`.
- [x] `launch-kit/` folder created.
- [x] Ground truth gathered from `README.md`, `agents.md`, `Marketing/` (screenshots only — no conflicting positioning text).
- [x] Verified the fact sheet against the repo: 9 sources match the README exactly; Warp confirmed as a *launch target* (Terminal.app / iTerm2 / Warp), not a source; no emoji rule confirmed in `agents.md`; owner-sole-author + no Claude co-author/footer confirmed in `CLAUDE.md`.

## Deliverables (all written)
- [x] `launch-kit/case-study.md` — ~1,050 word first-person essay
- [x] `launch-kit/show-hn.md` — Show HN title options + body, plain HN voice
- [x] `launch-kit/x-thread.md` — 8-post thread, every post ≤280 chars (verified)
- [x] `launch-kit/readme-hero-draft.md` — punched-up README hero DRAFT (does NOT touch README.md)
- [x] `launch-kit/REPORT.md` — final wrap: what's in the folder, unverifiable facts, judgment calls

---

## Verified facts (locked — use exactly, do NOT inflate)
- **674** GitHub stars, **44** forks, **0** open issues. Created **2025-09-19**.
- Star growth **accelerated**: ~55/mo first four months → **133 in Mar 2026**, **101 in Apr**, ~80/mo since. Momentum grew; it did not decay.
- **~700 weekly active users**. **9,240** total release downloads.
- **v4.0** shipped **2026-06-28**, **294** downloads in first 3 days. (README is now at v4.1 — "the Instant release," a performance pass. Use v4.0's numbers as the verified data point; v4.1 exists and can be referenced generically.)
- All growth with **ZERO marketing**.
- **9 session sources:** Codex, Claude Code, Cursor, OpenCode, GitHub Copilot CLI, Hermes, OpenClaw, Antigravity, Pi. **Do NOT** claim Gemini CLI as a source. **Warp** = terminal *launch* target (contributor PR #39), not a source.
- **External contributor PRs** are real: Warp terminal support, CodeBuddy support, OpenCode, Copilot CLI discovery fixes.
- **Local-first, no backend, no telemetry.** Only network activity is optional Sparkle update checks.
- **Thesis:** the category narrowed (first-party agents added their own session/resume features) but the *surviving* job got stronger — nobody runs one agent CLI anymore, and cross-agent history/search/analytics is what a single vendor's first-party tool structurally cannot do. Codex won't index your Claude sessions.
- Alex **applied to Anthropic's Claude for Open Source program.**
- Repo: github.com/jazzyalex/agent-sessions. macOS 14+. MIT. Homebrew: `brew tap jazzyalex/agent-sessions && brew install --cask agent-sessions`.

## Voice / rules to honor when writing
- Understated, technical, credible. **No hype, no emoji** (agents.md rule — applies to README hero especially).
- Accuracy > hype: a wrong claim in a portfolio piece is worse than no piece.
- Audience: senior PM / AI-tooling hiring manager + HN/X. Job of the kit: make a solo builder look serious.
- Commits: Conventional Commits, owner sole author, **no** "Generated with Claude Code" footer, **no** Co-Authored-By. Trailers Tool/Model/Why allowed. NEVER push.

## Resume plan (when Alex says "go")
Write, in order, committing incrementally (`git add launch-kit/` only):
1. `case-study.md` — arc: 0→~700 WAU with zero marketing → the local-first cross-agent thesis → the genuinely rare expertise (session-data formats across 9 ecosystems: JSONL, SQLite, state.db, per-vendor quirks) → honest "maintenance-mode vs. undervalued-asset" tension. First person, no hype.
2. `show-hn.md` — "Show HN: Agent Sessions — one searchable view of your local AI-coding sessions (Codex, Claude, Cursor, +6)". Body: what it is, why built, the local-first angle, honest limitations, link. Plain HN register.
3. `x-thread.md` — 6–10 posts. Hook = the counterintuitive thesis (category narrowed, job got stronger). Include the real numbers as proof, contributor PRs as social proof, close on the Claude-for-OSS note softly.
4. `readme-hero-draft.md` — badges (stars/downloads/build/license/macOS), one-liner, the real numbers, download CTA. Draft only; Alex merges.
5. `REPORT.md` — final summary + any judgment calls.
