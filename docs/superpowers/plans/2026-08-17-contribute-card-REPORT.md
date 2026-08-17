# Contribute-an-agent card — implementation report

Date: 2026-08-17 · Branch: `main` (base `8c499ce7`) · Not committed.

## What was built

A fifth card in the existing onboarding top-slot system (`OnboardingListTopSlot`). No new
notification surface, window, or framework was introduced. The card is a one-time,
dismissible invitation to help add support for another coding agent.

## Final copy (verbatim)

- **Title:** `Don't see your agent?`
- **Body:** `Agent Sessions adds new agents from user contributions — a pull request, your coding agent working from our brief, or a sanitized sample. Never share real transcripts, keys, or private paths.`
- **Primary button:** `Contribute an agent`
- **Secondary link:** `How it works`
- **Snooze button:** `Maybe later`
- **✕ help text:** `Don't ask again`

Copy lives inline in the card view as `ContributeCard.titleText` / `ContributeCard.bodyText`
(same file, same type — no strings file), held as constants only so the frozen privacy
sentence can be pinned by a test. No source count appears anywhere in the copy, and a test
enforces that.

The body `Text` carries **no line limit at all** — only
`.fixedSize(horizontal: false, vertical: true)` — so the entire body always renders and the
card grows to fit. This is deliberate and differs from the other four cards, which clip at one
line: the frozen privacy sentence is the last thing the body says, so any clipping is exactly
what would delete it. Buttons, the secondary link, and the ✕ are unchanged.

Copy revised by the owner after the first implementation (title shortened from "Using an agent
we don't index?", body shortened, line limit dropped entirely). The privacy sentence is
unchanged and still terminal.

## Eligibility and dismissal policy

Trigger (earliest of): `onboardingSessionsOpenedCount >= 25` **or** 45 days since
`onboardingFirstLaunchDate`.

Suppression guards, mirroring the star card exactly:

- `whatsNewMajorMinor == nil` — What's New always wins the slot.
- `!didConsumeTopSlotAskThisLaunch` — one ask per launch.
- `!contributeCardSuppressedThisLaunch` — in-memory only, never persisted.
- `!didPresentFreshInstallThisLaunch` — never on a fresh-install launch.
- Slot order is What's New > Quota Meter > star > feedback > **contribute** (last), until the
  ask has waited `contributeAskPriorityAfterDays` (14 days) since
  `OnboardingContributeAskDueSince`, after which it ages past the **feedback card only** —
  never What's New, the Quota Meter card, or the star ask, all of which keep priority
  unconditionally. See the F1 fix below.

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
`OnboardingContributeAskImpressions`, `OnboardingContributeAskDueSince`.

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

- **F1 was subsequently ruled on by the owner** — reach wins, aging implemented. See the
  second fix round below; the note that follows is superseded only for F1.
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

1. **Truncation (approved design change).** The card body `Text` moved from `.lineLimit(1)` to
   `.lineLimit(2)` + `.fixedSize(horizontal: false, vertical: true)`. Applied to the body only
   — the title and every other card in the slot are untouched. **Superseded by the third round
   below**, which removes the line limit entirely.
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

## Second fix round — F1 aging (owner ruling: reach wins)

The owner reversed the "no aging" decision recorded above. The contribute ask now ages past
the feedback card, copying the star card's proven pattern one-for-one.

- **New persisted key `OnboardingContributeAskDueSince`**, same conventions as
  `OnboardingStarAskDueSince`, stamped **once** in `checkAndPresentIfNeeded()` on the first
  launch the contribute trigger passes — immediately after the star ask's own stamp, and for
  the same reason: the card sits at the bottom of the chain and may wait many launches
  without ever rendering.
- **New constant `contributeAskPriorityAfterDays: Double = 14`**, named and valued like
  `starAskPriorityAfterDays`.
- **New `contributeAskOutranksFeedbackCard()`**, mirroring `starAskOutranksQuotaMeterCard()`:
  requires a stamp, requires 14 days elapsed, and finally requires the ask to actually be
  showable — so an already-resolved contribute ask gives the slot straight back rather than
  suppressing feedback for nothing. It is the **first check** in `shouldShowFeedbackCard()`.
- **Scope of the outranking is feedback only.** What's New, the Quota Meter card, and the
  star ask all still come first unconditionally: they are earlier branches in the
  `OnboardingListTopSlot` chain and nothing in this change touches their guards. **No chain
  reorder was needed** — when the aged ask wins, `shouldShowFeedbackCard()` returns false and
  the existing else-if simply falls through to the contribute branch, exactly as the Quota
  Meter branch falls through to the star branch today.
- **No recursion risk:** `contributeAskOutranksFeedbackCard()` calls
  `shouldShowContributeCard()`, which never consults the feedback card. Same shape as the
  star/Quota Meter pair.
- All other guards are unchanged: one ask per launch, fresh-install suppression, What's New
  wins, and the whole snooze/impression lifecycle.

**Tests added** (7 new, in the new "Aging past the feedback card" section): `dueSince` stamped
once and not re-stamped; not stamped before the ask qualifies; the wait constant pinned
literally at 14; feedback still wins the both-due case one day short of the wait; contribute
wins it once the wait elapses; an aged-but-resolved ask hands the slot back; and an aged ask
still loses to the star card, the Quota Meter card, and What's New. The existing both-due test
was renamed to `testFeedbackWinsTheSlotWhenBothAreDueBeforeAging` and now stamps a fresh
`dueSince` so its premise is explicit rather than incidental.

**Validation:** Debug build **SUCCEEDED**; focused run of the five `Onboarding*Tests` classes —
**96 tests, 0 failures** (35 in `OnboardingContributeCardTests`). The 13 pre-existing
`OnboardingFeedbackTriggerTests` pass unchanged, which is the check that matters most here:
adding a guard to `shouldShowFeedbackCard()` did not alter feedback behaviour for anyone
without an aged contribute ask. Full suite left to the controller.

## Third fix round — owner copy revision

Copy only; no state-machine, eligibility, or URL change.

1. **Title** is now `Don't see your agent?` (was "Using an agent we don't index?").
2. **Body** is now `Agent Sessions adds new agents from user contributions — a pull request,
   your coding agent working from our brief, or a sanitized sample. Never share real
   transcripts, keys, or private paths.` — shorter, with the privacy sentence unchanged and
   still last.
3. **The whole body always renders.** The line limit was removed from the body `Text`
   entirely; `.fixedSize(horizontal: false, vertical: true)` stays, so the card grows to fit
   rather than clipping. Buttons, the "How it works" link, and the ✕ are unchanged.
4. **Tests updated to the new literals.** `testCardCopyIsFrozen` pins both new strings.
   `testFrozenPrivacySentenceIsPresentInTheCardBody` and `testCopyStatesNoSourceCount` needed
   no literal edits — both read `ContributeCard.titleText` / `.bodyText` directly — and both
   still pass against the new copy: the privacy sentence remains the suffix, and the new body
   contains no digit and no count word.

**Validation:** Debug build **SUCCEEDED**; focused run of the five `Onboarding*Tests` classes —
**96 tests, 0 failures** (35 in `OnboardingContributeCardTests`, unchanged count: this round
edited literals rather than adding cases).
