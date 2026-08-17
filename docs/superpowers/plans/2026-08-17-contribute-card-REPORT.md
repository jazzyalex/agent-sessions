# Contribute-an-agent card — implementation report

Date: 2026-08-17 · Branch: `main` (base `8c499ce7`) · Not committed.

## What was built

A fifth card in the existing onboarding top-slot system (`OnboardingListTopSlot`). No new
notification surface, window, or framework was introduced. The card is a one-time,
dismissible invitation to help add support for another coding agent.

## Final copy (verbatim)

- **Title:** `Using an agent we don't index?`
- **Body:** `New agents get added from user-contributed format samples — a pull request, your coding agent working from our brief, or a sanitized sample a maintainer can build from. Never share real transcripts, keys, or private paths.`
- **Primary button:** `Contribute an agent`
- **Secondary link:** `How it works`
- **Snooze button:** `Maybe later`
- **✕ help text:** `Don't ask again`

Copy lives inline in the card view as `ContributeCard.titleText` / `ContributeCard.bodyText`
(same file, same type — no strings file), held as constants only so the frozen privacy
sentence can be pinned by a test. No source count appears anywhere in the copy, and a test
enforces that.

## Eligibility and dismissal policy

Trigger (earliest of): `onboardingSessionsOpenedCount >= 25` **or** 45 days since
`onboardingFirstLaunchDate`.

Suppression guards, mirroring the star card exactly:

- `whatsNewMajorMinor == nil` — What's New always wins the slot.
- `!didConsumeTopSlotAskThisLaunch` — one ask per launch.
- `!contributeCardSuppressedThisLaunch` — in-memory only, never persisted.
- `!didPresentFreshInstallThisLaunch` — never on a fresh-install launch.
- Slot order is What's New > Quota Meter > star > feedback > **contribute** (last). The star
  card outranks it unconditionally: no aging or outranking mechanism was added, because the
  star ask always spends itself within two rounds and hands the slot back on its own.

Lifecycle (`ContributeAskState`: `notAsked` / `snoozed` / `dismissedForever` / `opened`,
defaulting to `notAsked` on an absent or unparseable value):

- **"Maybe later"** → `snoozed`, 14-day snooze (`contributeAskSnoozeInterval`), then exactly
  one retry.
- **✕** → `dismissedForever` immediately (an explicit no; "Maybe later" is right beside it).
  Never downgrades an `opened` record.
- **Opening either CTA** → `opened`, terminal, never shown again.
- **3 shown-but-unanswered launches** end the round exactly as "Maybe later" would; the retry
  round gets a fresh impression budget. A second round-out goes straight to
  `dismissedForever` — one invitation, not a recurring campaign. Impressions are counted once
  per launch, not once per render.

New defaults keys: `OnboardingContributeAskState`, `OnboardingContributeAskSnoozedUntil`,
`OnboardingContributeAskImpressions`.

## CTA destinations

- Primary → `https://github.com/jazzyalex/agent-sessions/issues/new?template=new-agent-source.yml`
- Secondary → `https://github.com/jazzyalex/agent-sessions/blob/main/docs/CONTRIBUTING.md`

Both verified before wiring: `.github/ISSUE_TEMPLATE/new-agent-source.yml` exists and its
filename matches the `?template=` query form, and it already carries its own do-not-attach
privacy notice. `docs/CONTRIBUTING.md` exists and already describes both routes the copy
promises (implement it / hand over sanitized format evidence, plus the AI-agent brief) — no
doc fix was needed.

## Privacy safeguards

The card reads no session data and transmits nothing; its only side effect is
`NSWorkspace.shared.open` on a constant public URL, guarded on success so a click that opened
no browser does not spend the ask (same guard as the star card). Tests pin both URLs
literally, assert both stay on `github.com/jazzyalex/agent-sessions`, and pin the frozen
privacy sentence as the last thing the card says.

## Files changed

| File | +/- |
| --- | --- |
| `AgentSessions/Onboarding/Models/OnboardingCoordinator.swift` | +129 |
| `AgentSessions/Onboarding/Views/OnboardingListTopSlot.swift` | +96 / -1 |
| `AgentSessions/Onboarding/Utilities/OnboardingDefaults.swift` | +38 |
| `AgentSessions.xcodeproj/project.pbxproj` | +4 |
| `docs/CHANGELOG.md` | +1 |
| `docs/summaries/2026-08.md` | +1 |
| `AgentSessionsTests/OnboardingContributeCardTests.swift` | new, 27 tests |

## Validation

1. `xcodebuild ... -configuration Debug build` — **BUILD SUCCEEDED**.
2. Focused: `OnboardingContributeCardTests` + the four existing `Onboarding*Tests` classes —
   **88 tests, 0 failures** (27 new).
3. `./scripts/xcode_test_stable.sh` — **2023 tests, 3 skipped, 0 failures**, TEST SUCCEEDED.
4. `git diff --check` — clean.

The app was not launched and macOS Appearance was not touched.

## Limitations and owner decisions

- **Star-card copy tension (owner decision, not changed here).** `StarCard`'s body still reads
  "A star is the only thing this project asks for." Once the contribute card exists that is
  slightly false. Left verbatim as instructed — the owner should decide whether to reword it.
- **Full-suite total.** The brief expected ~2051 + new; the actual run is 2023 (1996 baseline
  + 27 new). The diff is additive only — no test file was deleted or disabled — so the 2051
  figure appears to be stale rather than indicating lost coverage.
- **Card width.** The card now carries four controls (primary, "How it works", "Maybe later",
  ✕) plus a long body line held at `.lineLimit(1)`, matching the other cards. In a narrow
  window the body truncates earlier than the other cards' shorter copy does — including,
  potentially, the privacy sentence. The full sentence is always reachable behind "How it
  works", and the issue form repeats the warning, but visual QA at a narrow window width is
  worth an owner look.
- Presentation was not visually QA'd (no app launch per instructions).

## Fix round (post-review)

Applied against review verdict "Spec ✅, Quality Approved, with fixes"
(`2026-08-17-contribute-card-REVIEW.md`). Each fix verified against the code.

1. **Truncation (approved design change).** The card body `Text` now uses `.lineLimit(2)` +
   `.fixedSize(horizontal: false, vertical: true)` instead of `.lineLimit(1)`. Applied to the
   body only — the title and every other card in the slot are untouched. At normal widths the
   body still renders on one line, so the card stays visually identical to `StarCard`; at
   narrow widths the frozen privacy sentence now wraps instead of being clipped away. This
   retires the width concern raised in the first report.
2. **F3 — comment/code mismatch.** `contributeAgentSourceURL` and `contributeGuideURL` are now
   built from `OnboardingCoordinator.githubRepositoryURL.absoluteString` by interpolation, so
   the "derived from" comment is true. Interpolation rather than `appendingPathComponent`
   because the issue URL's `?template=` query would otherwise be percent-escaped. Final URLs
   are byte-identical — the two literal-pinning tests still pass unchanged.
3. **F2 — changelog section.** The bullet moved from `### Documentation` to `### Features`,
   matching the 4.5 precedent ("The Quota Meter offers itself").
4. **Test gap — feedback/contribute collision.** Added
   `testFeedbackWinsTheSlotWhenBothAreDue`: with both asks eligible on one launch, feedback
   holds the slot and contribute is hidden; feedback's soft ✕ brings it back ahead next
   launch; once feedback reaches a terminal state the slot falls through to contribute.
5. **F5 — hardened count pin.** `testCopyStatesNoSourceCount` is now a blanket ban rather than
   a list of today's likely numbers: the frozen copy must contain no decimal digit at all, and
   no spelled-out count word (one…twenty, dozen/dozens, handful, several) matched on word
   boundaries so "someone" does not false-positive. "A dozen agents" would now fail.
   `testFrozenPrivacySentenceIsPresentInTheCardBody` was left as-is.

Out of scope as instructed and left untouched: **F1** (feedback-starvation reach cost) and
**F4** (star-card copy) — both owner decisions, both documented above.

**Fix-round validation:** Debug build **SUCCEEDED**; focused run of the five `Onboarding*Tests`
classes — **89 tests, 0 failures** (28 in `OnboardingContributeCardTests`, one more than
before). `git diff --check` clean. The full suite was deliberately **not** run this round —
another agent is building in this tree, and the controller runs the central suite after both
streams land.
