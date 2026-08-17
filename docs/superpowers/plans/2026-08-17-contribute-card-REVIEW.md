# Review — contribute-an-agent card (uncommitted, base `8c499ce7`)

Reviewer pass: read-only. Every claim below was checked against the code, not the
implementation report. Verdict: **Spec ✅ · Quality Approved** with one recommended
change (body line limit) and four low-severity notes.

---

## 1. Non-interference — PASS (the critical property holds)

Checked every touched decision path.

`OnboardingCoordinator.swift`: the diff is **purely additive**. No existing function body
was modified — `shouldShowFeedbackCard()`, `shouldShowQuotaMeterCard(...)`,
`shouldShowStarCard()`, `starAskOutranksQuotaMeterCard()`, `isFeedbackAskDue()`,
`usageTriggerMet()`, `checkAndPresentIfNeeded()` are byte-identical to HEAD. The new
state (`contributeCardSuppressedThisLaunch`, `didCountContributeImpressionThisLaunch`,
three defaults keys) is read only from the four new contribute functions. **No existing
card's path gained a new guard or flag read.**

`OnboardingDefaults.swift`: one new enum plus three new computed properties. No existing
key, getter, or setter touched.

`OnboardingListTopSlot.swift`: the new branch is appended as the **last `else if`** in the
chain, after feedback. The four preceding branches are unchanged (only the file's header
doc comment gained a clause). A user who never becomes eligible never evaluates
`shouldShowContributeCard()` at all, because SwiftUI's `if/else if` short-circuits at the
first true branch; and even when it is evaluated, it is a pure query with no side effects.
`noteContributeCardShown()` is reachable only from the new branch's `.onAppear`.

Guard set on `shouldShowContributeCard()` matches the required list exactly and in the
right order:
`whatsNewMajorMinor == nil` → `!didConsumeTopSlotAskThisLaunch` →
`!contributeCardSuppressedThisLaunch` → `!didPresentFreshInstallThisLaunch` → lifecycle
switch → trigger.

**No aging / outrank mechanism was copied.** There is no `contributeAskDueSince`, no
analogue of `starAskOutranksQuotaMeterCard()`, and nothing stamps a due date in
`checkAndPresentIfNeeded()`. The star card therefore outranks contribute unconditionally,
as required.

## 2. Policy exactness — PASS

| Requirement | Code | Verdict |
| --- | --- | --- |
| Trigger ≥25 sessions OR ≥45 days | `contributeAskTriggerMet()`, constants `25` / `45` | ✅ |
| "Maybe later" = 14-day snooze | `contributeAskSnoozeInterval = 14 * 86_400`, set in `endContributeAskRound()` | ✅ |
| ✕ = `dismissedForever` | `dismissContributeAskForever()` | ✅ |
| CTA open = `opened`, terminal | `recordContributeOpened()`; `.opened` returns false in the lifecycle switch | ✅ |
| 3 ignored launches = snooze | `noteContributeCardShown()` → `contributeAskMaxImpressionsPerRound = 3` → `endContributeAskRound()` | ✅ |
| Second round-out = `dismissedForever` | `endContributeAskRound()` `.snoozed` case | ✅ |

Correct details worth naming: `dismissContributeAskForever()` refuses to downgrade an
`opened` record; the retry round is given a fresh impression budget
(`contributeAskImpressions = 0`); a `.snoozed` state with a nil `snoozedUntil` is treated
as due rather than as a permanent silence (mirrors the star card); the impression counter
is launch-scoped, not render-scoped.

Persistence follows the file's conventions: UpperCamelCase key strings under
`OnboardingKeys`, three computed properties, and a garbage-tolerant getter —
`ContributeAskState(rawValue: string(forKey:) ?? "") ?? .notAsked`. Identical shape to the
existing `starAskState` accessor.

## 3. Copy — PASS, frozen verbatim

Title, body, both button labels, ✕ help text and the "How it works" link all match the
sanctioned strings character-for-character. The multiline body literal uses trailing `\`
continuations with the closing delimiter at the same indentation as the content, so the
runtime string carries no leading whitespace and no embedded newlines — confirmed by
`testCardCopyIsFrozen`, which pins the concatenated single-line form. No source count
appears anywhere in the card, coordinator, or defaults.

## 4. CTAs — PASS

Both URLs are `static let` constants declared immediately below `githubRepositoryURL` in
`OnboardingCoordinator`, and both targets exist in-repo:
`.github/ISSUE_TEMPLATE/new-agent-source.yml` (filename matches the `?template=` query
form) and `docs/CONTRIBUTING.md`. Both are opened through `NSWorkspace.shared.open` behind
a `guard … else { return }` success check, so a click that opened no browser does not
spend the ask — the same guard the star card uses. Nothing in the card path reads session
data, touches an indexer, or transmits anything; the URLs are compile-time constants with
no interpolation, so nothing about the user can ride along in a query string.

## 5. Test honesty — PASS with one coverage gap

27 tests, counted. Hermetic in the file's own house style: a per-test
`UserDefaults(suiteName:)` cleared with `removePersistentDomain(forName:)`, matching all
four existing `Onboarding*Tests` classes; suite names are uniquely prefixed `Contribute.`
so they cannot collide with the `Star.` / feedback / quota suites. Time is injected via a
frozen `referenceNow`, so no test depends on wall clock.

Values are **pinned literally**, not re-derived: `25`, `45`, `3`, `14 * 86_400`, both full
URL strings, the whole body string, and the raw defaults key `"OnboardingContributeAskState"`
(spelled out in `testGarbageStateFallsBackToNotAsked`, so a key rename is caught).

Would each fail on the regression it claims to catch? Spot-checked the load-bearing ones:

- `testShownAtTheSessionsThreshold` / `testShownAtTheDaysThreshold` — both trigger legs
  proven independently (the days test sets sessions to 1; the sessions test sets first
  launch to *now*, i.e. 0 days). Neither passes via the other leg. Real.
- `testNotShownJustBelowEitherThreshold` — 24 sessions / 44 days. Fails if either bound
  is loosened by one. Real.
- `testRepeatedRendersInOneLaunchCountOnce` — fails if the
  `didCountContributeImpressionThisLaunch` guard is removed. Real.
- `testThreeIgnoredLaunchesEndTheRoundLikeMaybeLater` and
  `testIgnoringTheRetryRoundSilencesItForever` — cover both round-outs, including the
  budget reset and the permanent second round-out. Real.
- `testDismissDoesNotOverwriteAnOpen` — fails if the `!= .opened` guard is dropped. Real.
- `testLaunchSuppressionIsNotPersisted` — asserts both the in-launch hide *and* that a
  fresh coordinator on the same defaults shows it again. Real.
- `testStarCardStillOutranksTheContributeCard` — covers the collision in both directions
  (star wins while due; contribute becomes available only on the *next* launch after star
  resolves). Real.
- `testOpeningIsTerminal`, `testDismissIsPermanentAndSurvivesRelaunch`,
  `testSnoozeSurvivesRelaunchUntilItExpires` — all re-instantiate the coordinator against
  the same defaults, so they genuinely test persistence rather than in-memory flags. Real.

Weak or near-tautological:

- `testCopyStatesNoSourceCount` searches for `"11"`, `"12"`, `"13"`, `"14"`, `"thirteen"`,
  `"fourteen"`. The frozen copy contains no digits and no number words at all, so this can
  only fail if someone edits the copy *and* happens to pick one of six enumerated tokens —
  "a dozen agents" or "over 10 sources" would sail through. Near-tautology; harmless, but
  it is weaker than it reads.
- `testFrozenPrivacySentenceIsPresentInTheCardBody` is fully subsumed by
  `testCardCopyIsFrozen`. Redundant rather than tautological — and the redundancy is
  arguably the point (it names *why* that sentence is load-bearing).
- `testThresholdsArePinned` is a constant-equals-literal check. Not a tautology (it is the
  intended freeze) but it carries no behavioural signal beyond the trigger tests.
- `testNotShownToANewUser` is largely covered by `testNotShownJustBelowEitherThreshold`.

**Coverage gap (moderate):** slot collision against the **feedback** card is tested in one
direction only. `testFeedbackCardIsUnaffectedWhenContributeIsIneligible` proves the
ineligible case; there is no test for the case where *both* are due, which is where the
ordering actually matters (see finding F1). Because the ordering lives in the view's
`else if` chain rather than in the coordinator, a unit test cannot assert it directly — but
a test asserting that `shouldShowFeedbackCard()` and `shouldShowContributeCard()` are both
true at 25 sessions, with a comment pinning the view's order, would at least document the
contract and fail loudly if someone later added a mutual exclusion.

## 6. Visual language — matches, one recommended change

`ContributeCard` is a structural clone of `StarCard`: `HStack(spacing: 10)`; a
14pt semibold SF Symbol in `palette.accentBlue`; `VStack(alignment: .leading, spacing: 1)`
with a 12pt semibold primary title and an 11pt secondary body; `Spacer(minLength: 8)`;
`.buttonStyle(.link)` actions at 12pt (semibold for the primary, regular for the rest); a
10pt bold `xmark` in `.buttonStyle(.plain)` with `.help("Don't ask again")`; and identical
`.padding(.horizontal, 12)` / `.padding(.vertical, 8)` / 10pt rounded `rowFill` background
with a 1pt `rowStroke` overlay. Container padding (`.horizontal, 10` / `.top, 8`) matches
the other four branches. No token drift.

**Truncation question — recommend allowing 2 lines.** The card carries one control more
than `StarCard` ("How it works") and roughly three times the body text, all inside the same
single-line budget. At realistic session-list widths the body will truncate well before the
privacy sentence, which sits at the very end. The argument that the warning is repeated in
the issue form is true but backwards: the warning's job is to reach the user *before* they
decide to gather material, and this card is the only place the app invites someone to hand
session-derived material to a public tracker. The test suite itself asserts the warning
"must remain the last thing the card says" — a layout that reliably clips exactly that
sentence quietly defeats the property the tests were written to protect.

Recommended minimal change, staying inside the sanctioned design:

```swift
.lineLimit(2)
.fixedSize(horizontal: false, vertical: true)
```

on the body `Text` only. This grows the card by one 11pt line at narrow widths and leaves
it visually identical to `StarCard` at normal widths (the other cards' shorter copy still
fits on one line). If the owner prefers a strictly uniform card height, the alternative is
to shorten the body to the privacy sentence plus one clause and move the three routes
behind "How it works" — but that is a copy change, and the copy is frozen, so `lineLimit(2)`
is the change I recommend.

## 7. pbxproj, CHANGELOG, summaries — PASS with a house-style nit

pbxproj: exactly **4** added lines, no deletions — one `PBXBuildFile`, one
`PBXFileReference` (`sourceTree = SOURCE_ROOT`, path `AgentSessionsTests/…`), one group
membership under the `AgentSessionsTests` group, and one entry in that target's `Sources`
build phase, adjacent to the other test files. `grep -c OnboardingContributeCardTests`
returns 4 — no duplicate refs, and the file is on the test target only, not the app target.

CHANGELOG and `docs/summaries/2026-08.md` entries are single lines, in the house voice
(concrete, user-facing, no marketing register), and their factual content matches the code:
25 sessions or 45 days, never on fresh install, never above an existing card, terminal on
dismiss / second "Maybe later" / open, reads nothing and sends nothing. See finding F2 on
placement.

---

## Findings

**F1 — moderate (design consequence, not a defect).** The contribute card can be starved
indefinitely. `shouldShowFeedbackCard()` is true on every launch for a user whose feedback
state stays `notAsked`, because the feedback card's ✕ is soft
(`suppressFeedbackCardThisLaunch()` sets an in-memory flag only and never advances the
lifecycle). Contribute sits below feedback with no aging rule, so that cohort never sees
it. This is precisely the starvation argument `shouldShowStarCard()`'s own doc comment uses
to justify placing the star card *above* feedback. The implementer was explicitly forbidden
to add an aging mechanism and correctly did not, so this is the right code for the given
brief — but the owner should know the reach cost is real and probably not small. Fail-quiet
either way; nothing breaks.

**F2 — low.** The CHANGELOG entry sits under `### Documentation`. Precedent for an in-app
onboarding card is `### Features` — cf. 4.5's "**The Quota Meter offers itself.**", the
closest analogue in the file. The `docs/summaries` placement is fine (that file is a flat
list).

**F3 — low.** The doc comment on `contributeAgentSourceURL` says "Derived from
`githubRepositoryURL` so the two can never drift onto different repositories." It is not
derived — it is an independent string literal that repeats the repo path. The comment
promises an invariant the code does not enforce. Either interpolate
`githubRepositoryURL.absoluteString` (or `appending(path:)`) or reword the comment to say
"kept beside". `testDestinationsStayOnThePublicRepository` catches host/path drift, which
softens this to a comment-accuracy issue.

**F4 — low.** `StarCard`'s body still reads "A star is the only thing this project asks
for." Once the contribute card ships, that is no longer true. Correctly left alone (copy is
frozen and this is a different card), but it is now an owner decision, as the implementer
flagged.

**F5 — low.** Test weaknesses named in §5: `testCopyStatesNoSourceCount` is a near-tautology
(enumerated-token search over copy containing no numerals), and the feedback-vs-contribute
"both due" collision is untested in that direction.

Nothing at high severity. No privacy, correctness, or non-interference defect found.
