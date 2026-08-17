# Track 1 (steward-program docs pack) — report, 2026-08-17

Docs only. No Swift, no scripts, no commits, no branches, no GitHub API calls.
Nothing under `AgentSessions/`, `scripts/`, or `skills/` was touched.

## Files

**Created — `STEWARDS.md`** (repo root)
Defines the steward role (one agent, own installation, pinged 2–3×/year, ~10 minutes),
what it is not (no commit rights, no code, no deadline, no real transcripts), the credit,
the signup path, the three tiers, and the per-agent table. Points to
`docs/agent-support/agent-support-matrix.yml` as the machine-readable source of truth and
says the matrix wins on disagreement. Two honest footnotes: Qwen (verified at 0.14.3, free
tier discontinued 2026-04-15, newer builds unverified) and Hermes (held at 0.17.0 since
2026-06-24, driver produces no usable sample).

**Changed — `README.md`**
New `## Agent Support Status` section between Core Features and Quota Meter. README had no
support matrix table at all, so the "lightest equivalent" is a two-column Agent | Status
table with no versions or dates in it — those live in STEWARDS.md and would rot here. Tier
glossary in one line, plus the `### Help add — and keep — your agent` subsection (four
sentences) linking the new-agent-source form, `docs/CONTRIBUTING.md`, and `STEWARDS.md`. No
agent counts. Nothing else restructured.

**Changed — `docs/CONTRIBUTING.md`**
New `## Become a steward` section, placed between "Add an agent" and "Evidence required".
What/what-not/credit, the `./scripts/steward_check.py <agent>` line described exactly as
briefed, and links to `STEWARDS.md`, the steward-signup form, the new-agent-source form,
and the agent-source PR template.

**Changed — `.github/ISSUE_TEMPLATE/new-agent-source.yml`**
New optional `stewardship` checkboxes block inserted before the existing `privacy` block,
matching the file's existing form schema style. Parses under `yaml.safe_load`.

**Created — `.github/ISSUE_TEMPLATE/steward-signup.yml`**
Tiny form: which agent, GitHub handle for credit, three required confirmations (uses it
regularly with real sessions on disk / willing to be pinged / the repo's standard
privacy line), optional notes. Carries the same privacy wording as new-agent-source.yml
plus the note that the tool redacts first. Labels `steward`. Parses under `yaml.safe_load`.

**Changed — `.github/PULL_REQUEST_TEMPLATE/agent-source.md`**
New `## Stewardship` section with the same checkbox line, before `## Verification`.

**Created — `docs/superpowers/plans/2026-08-17-stewards-wanted-ISSUE.md`**
Prepared body for the pinned issue (owner posts). Suggested title and labels at the top,
then the body: the problem, the ask, the command, the ten steward-less agents with one
concrete line each, and the signup links. All links absolute under
`https://github.com/jazzyalex/agent-sessions` because relative links do not resolve in
issue bodies.

## STEWARDS.md table as written

| Agent | Steward | Last verified | Tier |
|---|---|---|---|
| Codex | @jazzyalex (maintainer) | 2026-08-13 · 0.147.0 | Maintained |
| Claude Code | @jazzyalex (maintainer) | 2026-08-13 · 2.1.220 | Maintained |
| Cursor Agent | steward wanted | 2026-08-13 · 2026.8.11 | Best-effort |
| GitHub Copilot CLI | steward wanted | 2026-08-13 · 1.0.79 | Best-effort |
| OpenCode | steward wanted | 2026-08-17 · 1.18.18 | Best-effort |
| Antigravity CLI | steward wanted | 2026-08-13 · 1.1.12 | Best-effort |
| Pi | steward wanted | 2026-08-17 · 0.84.2 | Best-effort |
| Kimi Code | steward wanted | 2026-08-17 · 0.36.1 | Best-effort |
| Grok CLI | steward wanted | 2026-08-17 · 1.0.4 | Best-effort |
| OpenClaw | steward wanted | 2026-08-13 · 2026.7.1 | Best-effort |
| Hermes | steward wanted | 2026-06-24 · 0.17.0 | Best-effort |
| Qwen Code | steward wanted | 2026-08-17 · 0.14.3 (see note) | Best-effort |

## How the table was derived

Versions are `max_verified_version` from `agent-support-matrix.yml` verbatim. Dates:

- `2026-08-13` — the last full format check note, for the agents whose matrix version
  matches the version that note recorded (Codex, Claude, Copilot, Cursor, Antigravity,
  OpenClaw).
- `2026-08-17` — the matrix `as_of_date`, used where the matrix version is newer than the
  last dated note (OpenCode 1.18.18 vs 1.18.16, Pi 0.84.2 vs 0.84.1, Kimi 0.36.1 vs 0.34.0)
  and for Grok (prebump driver note dated 2026-08-17) and Qwen (first weekly run, same day).
- `2026-06-24` — Hermes, the last run with fresh matching evidence; held ever since.

Tiers are conservative per brief: only Codex and Claude Code are Maintained (the owner's
own daily agents, and the only two with Quota Meter support). Everything else is
Best-effort with "steward wanted", and Best-effort is defined so it does not understate
what exists today: it says the agent stays in the automated weekly format check while the
maintainer can run it, but nobody is on the hook and drift can sit unfixed. No agent is
currently Steward-verified — that tier is defined and empty until the first signup.

## Concerns

1. **Duplication.** The agent list now appears in three places (README status table,
   STEWARDS.md table, matrix YAML). README carries no versions or dates to limit the rot,
   and STEWARDS.md states the matrix is authoritative, but a new agent still means editing
   two Markdown files. Worth folding into the site generator in Track 3.
2. **`steward_check.py` is described but not yet present.** README does not mention it;
   CONTRIBUTING.md and STEWARDS.md do. If the concurrent agent's script lands under a
   different name or path, both need a one-word fix.
3. **The `steward` label does not exist yet.** `steward-signup.yml` declares
   `labels: [steward]`; GitHub silently drops unknown labels on issue forms, so the form
   still works, but the owner should create `steward` (and `steward-wanted` per the plan).
4. **The "Maintained" claim is a judgement call.** The matrix does not record who uses what.
   It was inferred from Codex and Claude being the only two agents with Quota Meter and
   usage-probe support, and from the brief. Worth an owner sanity check.
5. **README section placement.** Put after Core Features and before Quota Meter, which is
   an editorial choice — the support status table now sits above the flagship feature
   section. Easy to move down to just above `## Documentation` if that reads better.
