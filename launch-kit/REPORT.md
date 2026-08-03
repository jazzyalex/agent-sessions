# Launch Kit — REPORT (final)

**Date:** 2026-07-06 · **Branch:** `auto/launch-kit` · **Status:** all deliverables complete, committed, not pushed.

## What's in `launch-kit/`

| File | What it is | Length / shape |
|---|---|---|
| `case-study.md` | First-person essay: 0→~700 WAU story, the local-first cross-agent thesis, the rare 9-ecosystem data-format expertise, the honest maintenance-vs-undervalued arc. | ~1,050 words |
| `show-hn.md` | Show HN post — two title options (both ≤80 chars) + URL + plain-register body with honest limitations. | ~380 words |
| `x-thread.md` | 8-post X thread. Hook = the counterintuitive thesis; numbers as proof; contributor PRs as social proof; CTA close. | 8 posts, each ≤280 chars (verified: max 270 bytes / lower in code points) |
| `readme-hero-draft.md` | Drop-in DRAFT hero for `README.md`: badges + one-liner + "by the numbers" + CTA. Does **not** touch the live README. | Draft + notes |
| `STATUS.md` | Progress tracker + verified fact sheet + timeline. | — |
| `REPORT.md` | This file. | — |

All copy uses the verified numbers exactly (674 stars / 44 forks / 0 issues / ~700 WAU / 9,240 downloads / 9 sources) and honors the repo rules: no emoji, no hype, owner sole author.

## Facts I used as given (could not independently verify from the repo)

The repo confirms the *product* facts — the 9 sources match the README exactly, Warp is a launch target not a source, local-first/no-telemetry is accurate. But these **metrics came from your brief and are not derivable from the working tree**, so I took them on trust and you should sanity-check before publishing:

- **674 stars, 44 forks, 0 open issues** — live on GitHub; the README-hero badges are dynamic so they'll self-correct, but the prose "674" in `case-study.md`, `x-thread.md` (post 7), and the hero "by the numbers" line is **hardcoded** and will drift. Update or soften before posting if the count has moved.
- **~700 weekly active users** — no GitHub metric backs this; it's a stated figure. Appears in all four docs. If you're not comfortable committing to it publicly, the easiest cut is the hero (keep stars + downloads, both live).
- **9,240 downloads** and **v4.0 = 294 in first 3 days** — the 294 figure I used only in the case study; the 9,240 total appears across the kit.
- **Star-growth cadence** (~55/mo early → 133 Mar → 101 Apr → ~80/mo) — used verbatim in the case study and X post 7.
- **Contributor PRs** (Warp #39, CodeBuddy, OpenCode, Copilot CLI discovery) — named as given; I did not open the PR list to confirm authorship/titles.

## Judgment calls I made (flagging so you can override)

1. **Left the Claude-for-OSS application out of the public X thread.** Announcing a *pending* application publicly can read as presumptuous and ages badly if it doesn't land. I put it only in `case-study.md`, which reads as a controlled portfolio/essay for a hiring manager — the right home for it. Reverse if you want it in the thread.
2. **README hero download link → `releases/latest`** instead of the current hardcoded `v4.1` DMG URL, so it never rots. Note in the draft explains the tradeoff if you prefer the exact-DMG link.
3. **v4.0 vs v4.1.** Your brief's data point was v4.0 (2026-06-28, 294 downloads); the live README is already on v4.1 ("the Instant release"). I anchored the verified *number* to v4.0 and kept version references generic elsewhere so nothing is stale.
4. **Tone on "maintenance mode."** The brief asked for the honest arc. The case study states the maintenance-mode worry plainly, then argues the data cuts the other way. If that feels too candid for a career asset, soften the one paragraph under "The honest part."
5. **8 posts, not 6–10 max.** Landed at 8 as the tightest version that still carries thesis + proof + social proof + CTA without filler.
6. **No emoji anywhere**, including the X thread — extended the repo's user-facing-docs rule to the social copy for brand consistency. Emoji is more conventional on X; add sparingly if you want more reach, but I'd keep the thread clean.

## What needs your review before anything ships

- Confirm the hardcoded numbers above are still current (or switch the prose to "670+", "~700", "9k+" to buy headroom).
- Decide the WAU disclosure question (keep / soften / cut).
- Pick the Show HN title (option A leads with the tool names for recognition; option B leads with the job + "no cloud").
- Merge the README hero yourself — I intentionally did not touch `README.md`.

## Git / housekeeping

- Everything is on `auto/launch-kit`. Commits touch **only** `launch-kit/`. The uncommitted `feature/transcript-redesign-v5` changes rode along in the working tree and were **never staged**.
- Nothing pushed. Owner is sole author; no Claude co-author or "Generated with" footer.
- To publish the branch when you're ready, you run the push — I won't.
