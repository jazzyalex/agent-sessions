# What's New Slot Starvation — Implementation Spec

**Status:** implementation-ready
**Date:** 2026-08-29
**Scope:** `AgentSessions/Onboarding/` only. See §8 before touching anything.

## 1. Product contract

The session list hosts exactly one top-slot card. Six asks queue for it in a
fixed order: What's New → Quota Meter → star → feedback → steward → contribute.

Every card in that queue except What's New already obeys the same rule — *being
ignored is an answer* — and every one of them terminates. What's New does not.
It has two controls, and only one of them writes anything:

| The user… | Today | After this change |
|---|---|---|
| clicks ✕ | version recorded, card retired | unchanged |
| clicks "See what's new", reads the notes | **nothing recorded, card returns every launch** | version recorded, card retired |
| ignores it for three launches | **nothing recorded, card returns every launch** | budget spent, card stands down for that version |
| opens Help → What's New | panel opens, nothing recorded | unchanged — must stay always available |

The consequence today is that the queue behind What's New never advances for
anyone who does not click the ✕ specifically. The engaged user who clicks the
primary action and reads what shipped is punished hardest: they have answered
the card in the most complete way available, and it still blocks the star,
feedback, steward and contribute asks on every subsequent launch until the next
minor release.

**After this change, all three honest answers retire the card.** Nothing else
about What's New changes: same copy, same design, same slot priority, same
behaviour for the ✕, and Help → What's New continues to work forever.

## 2. State model

Two new keys in `OnboardingDefaults.swift`, mirroring the star ask's existing
`starAskImpressions` / `starAskDueSince` pair:

```
OnboardingWhatsNewImpressions        Int      launches that showed this version's card
OnboardingWhatsNewImpressionsVersion String?  the major.minor the counter belongs to
```

The counter is **version-scoped rather than reset on a bump**. The coordinator
has no reliable "a bump just happened" edge to hang a reset on, and a
version-scoped counter makes the reset implicit and idempotent: when the counter
is consulted or incremented for a version other than the one it was stamped
with, it is zero by definition. This satisfies "reset the budget when
major.minor changes" without a migration and without a launch-ordering hazard.

One in-memory flag, alongside `didCountStarImpressionThisLaunch` (line 190):

```swift
/// One impression per launch, not per render: `.onAppear` fires again every
/// time the list rebuilds the card.
private var didCountWhatsNewImpressionThisLaunch: Bool = false
```

One constant, alongside `starAskMaxImpressionsPerRound` (line 38):

```swift
/// Launches a version's What's New card may go unanswered before it stands
/// down. Same budget and same reasoning as the star ask: ignoring a card is an
/// answer, and without this the card holds the slot against every ask behind it
/// until the next minor.
static let whatsNewMaxImpressionsPerVersion = 3
```

### Do not rename the existing key

`OnboardingWhatsNewDismissedMajorMinor` now means *handled*, not *dismissed* —
it is written by the ✕ and by the card's open path. **Keep the key string
exactly as it is** and widen the doc comment only. Renaming it silently resets
the flag for every installed user, resurrecting a card they already answered.

## 3. Retire on open

`openWhatsNewPanel(version:)` (line 319) has two callers:

- the card's "See what's new" — `OnboardingListTopSlot.swift:69`
- `presentWhatsNewFromMenu()` (line 326) — the Help menu

Only the first may retire the card. Add a distinct entry point rather than a
defaulted parameter, so the Help path cannot acquire the side effect by someone
forgetting an argument at a call site:

```swift
/// The card's primary action. Reading the notes is an answer: it records the
/// version handled, exactly as the ✕ does, so the card does not return next
/// launch and the queue behind it advances.
func openWhatsNewFromCard(version: String) {
    defaults.onboardingWhatsNewDismissedMajorMinor = version
    didConsumeTopSlotAskThisLaunch = true
    whatsNewMajorMinor = nil
    openWhatsNewPanel(version: version)
}
```

`openWhatsNewPanel(version:)` itself stays exactly as it is — it remains the
Help menu's path and must keep recording nothing.

`didConsumeTopSlotAskThisLaunch = true` is deliberate and matches both
`dismissWhatsNewCard()` (line 331) and `recordQuotaMeterActivated()`: someone
who just acted should not be handed the next card the instant this one leaves
the slot. Without it, clicking "See what's new" swaps the star card into place
behind the opening panel.

Rewire the call site:

```swift
// OnboardingListTopSlot.swift:69
onOpen: { coordinator.openWhatsNewFromCard(version: version) },
```

## 4. Cap ignored cards

Add to `shouldOfferWhatsNew(current:previous:)` (line 271), after the existing
handled-version check:

```swift
if whatsNewImpressionBudgetSpent(for: current) { return false }
```

```swift
/// Whether this version's card has already had its three launches.
private func whatsNewImpressionBudgetSpent(for majorMinor: String) -> Bool {
    guard defaults.onboardingWhatsNewImpressionsVersion == majorMinor else { return false }
    return defaults.onboardingWhatsNewImpressions >= Self.whatsNewMaxImpressionsPerVersion
}
```

And the counter, modelled on `noteStarCardShown()` (line 522):

```swift
/// Records that this launch put the What's New card on screen. Ignoring a card
/// is an answer; without this the card returns on every launch until the next
/// minor, holding the slot against every ask behind it.
func noteWhatsNewCardShown() {
    guard !didCountWhatsNewImpressionThisLaunch else { return }
    guard let current = currentMajorMinorProvider() else { return }
    didCountWhatsNewImpressionThisLaunch = true

    if defaults.onboardingWhatsNewImpressionsVersion != current {
        defaults.onboardingWhatsNewImpressionsVersion = current
        defaults.onboardingWhatsNewImpressions = 0
    }
    defaults.onboardingWhatsNewImpressions += 1
}
```

Wire it on the card, matching the star branch at line 94:

```swift
// OnboardingListTopSlot.swift, the WhatsNewCard branch
.onAppear { coordinator.noteWhatsNewCardShown() }
```

## 5. The card does not vanish mid-launch

`whatsNewMajorMinor` is set once during launch evaluation (line 266) and
`shouldOfferWhatsNew` is consulted only there. So spending the third impression
does **not** remove the card from the screen during that launch — it stands the
card down starting with the next one.

This is the desired behaviour and it needs no code. Do not "fix" it by
re-checking the budget during rendering: a card that disappears while the user
is reading it is worse than one that stays a launch too long. Note this differs
from the star card, which does re-evaluate and can disappear mid-launch when its
round ends; that asymmetry is intentional and out of scope here.

## 6. What this unblocks

Every ask behind What's New starts getting slot time it has never had:

- **star** — the confirmed target; gated at 25 opens or 30 days
- **feedback** — soft ✕, returns every launch
- **steward** — one round per release, three lifetime
- **contribute** — one round, clock-snoozed
- **Quota Meter card** — see §8

No priority changes. The order stays What's New → Quota Meter → star →
feedback → steward → contribute, and `starAskOutranksQuotaMeterCard()` (line
572) continues to govern the star/Quota Meter contest after fourteen days.

## 7. Honest limitation

This repairs a defect confirmed in the source. It is not a growth mechanism and
should not be sold as one.

The app ships no telemetry, so there is no way to observe how often the card was
starved, how many users this reaches, or whether the star ask converts once it
is visible. The GitHub star curve is the only instrument and it cannot separate
this change from a release, a Reddit post, or an ecosystem placement landing in
the same week. **Do not attach a star-count projection to this work.** Ship it
because the current behaviour punishes the most engaged user, which is reason
enough.

An earlier draft of the review sized this ask from release download counts and
concluded a ceiling of "a few dozen stars." That arithmetic was wrong — a
release's download count is not the installed base and not a count of people —
and the conclusion is withdrawn.

## 8. Coordination — a parallel session owns Quota Meter work

Another session is implementing weekly `%/h` quota calibration
(`2026-08-29-weekly-quota-calibration-SPEC.md`). Its working tree holds changes
in `AgentSessions/CodexStatus/`, `AgentSessions/ClaudeStatus/`,
`AgentCockpitHUDView.swift`, and new `WeeklyQuotaCalibration.swift` files.

**Verified at time of writing: zero file overlap.** All four files this spec
touches are clean in the working tree.

Do not touch, in this work:

- `AgentSessions/CodexStatus/**`, `AgentSessions/ClaudeStatus/**`
- `AgentSessions/Views/AgentCockpitHUDView.swift`
- `AgentSessions/Onboarding/Views/QuotaMeterPromoView.swift`
- `shouldShowQuotaMeterCard()`, `suppressQuotaMeterCardThisLaunch()`,
  `recordQuotaMeterActivated()`, `recordQuotaMeterDeclined()`,
  `noteCockpitOpened()`, `starAskOutranksQuotaMeterCard()`

**No new Swift files, therefore no `project.pbxproj` edit.** The parallel
session has already modified the pbxproj to register `WeeklyQuotaCalibration`;
this work must not go near it. That is why the tests in §9 go into the two
existing registered test files rather than a new `OnboardingWhatsNewTests.swift`.

One behavioural interaction to be aware of, not a conflict: once What's New
stands down, the **onboarding Quota Meter card** starts appearing on launches
where it previously could not. That is the intended effect of unblocking the
queue, and it changes no Quota Meter logic — but it does change what a manual
QA pass sees.

## 9. Acceptance tests

Into `AgentSessionsTests/OnboardingCoordinatorTests.swift` (already registered;
already the home of `testDismissWhatsNewCardRecordsVersion`):

1. **Open retires it.** `openWhatsNewFromCard(version:)` persists the version,
   clears `whatsNewMajorMinor`, and a fresh coordinator on the same version does
   not re-arm the card.
2. **Help does not retire it.** `presentWhatsNewFromMenu()` leaves
   `onboardingWhatsNewDismissedMajorMinor` and the impression counter untouched,
   and the card still arms next launch.
3. **Help still works after the card is retired.** With the version handled and
   the budget spent, `presentWhatsNewFromMenu()` still presents the panel.
4. **Ignored-launch cap.** Three launches each counting one impression; the
   fourth does not arm the card.
5. **Same-launch rerender.** `noteWhatsNewCardShown()` called repeatedly within
   one launch charges exactly one impression.
6. **Version reset.** A major.minor bump restores a full three-launch budget,
   including when the previous version's budget was fully spent.
7. **Open beats the cap.** Opening from the card on launch 2 retires the version
   outright; the counter is irrelevant afterwards.

Into `AgentSessionsTests/OnboardingStarCardTests.swift`:

8. **The star card reaches the slot.** Retention gate met, What's New armed and
   ignored for three launches → `shouldShowStarCard()` is true on the fourth.
   This is the sibling `testWhatsNewWinsTheSlot` has never had.
9. **No regressions.** All 30 existing cases stay green.

## 10. Out of scope

- **Calendar-day star impressions.** Proposed in an earlier draft and withdrawn:
  the per-launch count is deliberate, the second round already waits fourteen
  days, and there is no evidence multiple daily launches cost meaningful
  conversion. Revisit only if the star card still underperforms once it is
  actually reaching people.
- **The star card's copy, design, gate, or terminal states.** Nothing suggests
  the card fails when it is seen.
- **Telemetry of any kind.** The card promises "nothing sent".

## 11. Follow-up: `TopSlotDebugOverride` covers `star` and `whatsnew`

Landed separately from the defect fix, as §10 originally proposed.

The override forces one card into the slot ahead of the whole chain, read from
the volatile launch-argument domain so it leaves nothing behind:

```
open <built>.app --args -AgentSessionsDebugTopSlotCard star
open <built>.app --args -AgentSessionsDebugTopSlotCard whatsnew
open <built>.app --args -AgentSessionsDebugTopSlotCard whatsnew:5.0
```

A bare `whatsnew` renders this build's own major.minor. Before this, positions 1
and 3 of the queue had no override at all, and reaching them by hand meant
writing `OnboardingSessionsOpenedCount` and deleting three lifecycle keys — all
of which persist in the real preference domain after the run, which is exactly
what the launch-argument design exists to avoid.

**What it is not.** It renders appearance — copy, layout, wrapping, light and
dark. Every action is wired to `debugCardDismissed`, so viewing a card here
cannot spend the real ask, and the `whatsnew` branch deliberately calls
`openWhatsNewPanel` rather than `openWhatsNewFromCard` so looking at it cannot
retire the version. The lifecycles in §1–§4 are verified by the tests in §9, not
by this.
