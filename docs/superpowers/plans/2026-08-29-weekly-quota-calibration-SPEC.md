# Weekly `%/h` Quota Calibration — Spec (as shipped)

**Status:** implemented 2026-08-30. Suite green (2340 tests).
**Supersedes:** the original live-tick-only draft, which could not produce a first
number on Codex in under ~12 hours and was therefore unusable.

## 1. Product contract

With `Wk` selected, every measurable session row reads its estimated share of the
account's weekly quota per hour:

```
2.6%/h        one decimal below 10, integer at and above
```

Weekly never renders `tk/h`, `$`, or a whole-week average. The `/h` suffix is
kept deliberately: the provider row above reads `Wk: 92%` meaning *quota
remaining*, so a bare `2.6%` would collide with it.

### Row vocabulary

| Situation | Row |
|---|---|
| Calibrated, session currently burning | `2.6%/h` |
| Calibrated, session alive but spending nothing | `quiet` |
| Session finished its turn | `—` |
| No calibration yet (bounded, see §5) | spinning clock |
| No weekly window / unpriceable model / absurd rate | `n/a` |
| Cloud session (no local transcript) | `Cloud` |

`quiet` replaced `flat` in **all four units** (`5h`, `tk`, `$`, `Wk`): "flat"
describes a curve and read as ambiguous beside real rates. The state being named
is a session that is alive and working but not consuming tokens — waiting on a
tool, a script, or a long read.

The load bar must agree with the label. `RunwayLoadBarFill.shouldFill` is the
single source of truth, used by both the view and its test: `fillFraction` floors
at 12% so a genuinely tiny rate stays visible, which meant a **zero** rate drew a
pulsing sliver contradicting the word beside it.

## 2. Estimation model

```
calibration  = quota percentage points ÷ priced API-equivalent activity  [pp/$]
session %/h  = calibration × session current $/h
```

Doubling a session's activity doubles its `%/h`. The predecessor split a fixed
account rate proportionally, so the displayed total was invariant to real
activity — the defect this design exists to remove.

Absolute price level cancels between the two lines; correct *relative* prices
still matter, so `$` pricing is reused as the weight function.

## 3. Acquiring the calibration — historical bootstrap

Waiting for a live quota tick cannot produce a first number: Codex reports weekly
percent as an integer, so the smallest observable drop is 1pp of a *weekly*
quota — hours of work. The conversion is instead computed from history at launch.

Every Codex `token_count` line carries both the turn's own `last_token_usage`
**and** the `rate_limits` snapshot at that instant, so a transcript is a full
quota trace:

```
calibration = used_percent_since_window_start ÷ priced_activity_since_window_start
```

Both terms are measured; no quota size is invented.

Rules:
- Window start = `resets_at` − `window_minutes`, read from the transcript itself.
- Search **both** `primary` and `secondary` slots by declared length, never by
  slot position: the 5h window is plan-dependent (Plus has it, Pro-lite does
  not), so weekly is `primary` without a 5h window and `secondary` with one.
  Mirrors `CodexRateLimitWindowClassifier.route`.
- Bank a turn only when the transcript's live weekly anchor matches the current
  one (±120s). This is an **account** filter — two accounts can share a machine —
  and handles mid-week re-anchors for free.
- Enumerate by mtime, never by the `YYYY/MM/DD` path: a months-old session
  resumed this week is this week's activity.
- Require ≥1pp consumed and ≤5% unpriced volume.
- Claude has no quota trace in its transcripts, so its window comes from the
  account snapshot and its per-call `message.usage` records are summed directly,
  deduped by message id.

Cost, measured: Codex ~44 MB / 4s; Claude ~681 MB / 667 files, fanned out over 4
workers. Concurrency is **bounded** — an unbounded `concurrentPerform` decoding
44 MB files peaked near a gigabyte.

## 4. Keeping it accurate

Corrections, each from an observed error on live data:

- **Denominator tracks ongoing spend.** A frozen bootstrap drifts high: the
  numerator is integer-quantized and sits still for hours while spending accrues.
  Measured as a **+43%** overestimate. The activity ledger already banks priced
  dollars every cycle, so the denominator extends for free.
- **Quantization midpoint.** A provider reporting `2` means true consumption is
  in `[2, 3)`. Using `2` biases low, worst where the numerator is smallest.
- **Trust the largest numerator, not the newest window.** A ratio from a
  completed 72pp week is stable to a few percent; a 2pp sliver swung **2.6×**
  inside one integer quantum. The best-conditioned measurement is retained,
  persisted anchor-free, and preferred until the current window exceeds it.

That last rule also carries the conversion **across a weekly reset**, where the
fresh window has ~0% consumed to divide by. The conversion describes the plan,
not the window. Promotion happens on restore as well as after a scan — a launch
that restores from cache never scans, so promotion-on-scan alone left the
carry-over slot empty.

Three further corrections came out of an external review of the shipped code,
each verified against live state before being accepted:

- **Every stored window feeds the carry-over slot.** Restore consulted only two
  keys — the slot itself and the *current* anchor's cache — so a completed
  window's measurement sat on disk unread. The first launch after the slot was
  introduced seeded it from the fresh window's sliver and the promotion guard
  locked it there. Live: a completed week at **77pp / $1239.62** (0.0621 pp/$)
  was ignored in favour of **7pp / $142.71** (0.0491 pp/$), understating every
  Claude session's `%/h` by **21%**. Now every `weeklyBootstrap.<provider>.<scope>.*`
  key is swept once per process and the largest numerator wins.
- **Rescan on age, not only on growth.** The ledger can only extend a denominator
  inside its own 6h retention, so once a stored scan is older than that nothing
  can freshen it. Live: a ratio scanned the previous day was still being served
  while real spend against the same integer percent had grown **14%**, and the
  growth trigger could not fire because the reported percent had not moved.
- **Failed scans stay retryable.** The anchor was marked on *dispatch*, and every
  failure path returned without clearing it, so one unreadable root or unpriced
  week retired that bucket permanently — pinning the stale ratio the rescan
  exists to replace. It also created a startup dead zone: a window at 0pp is
  rejected for having nothing to divide, and 0pp/1pp/2pp share one bucket, so the
  burnt attempt blocked every retry until 3pp. Anchors now record **successes
  only**; failures back off for 10 minutes.

**Freshening never crosses a window boundary.** Freshening pairs the current
reported percent with a stored denominator, but `bestConditionedBootstrap` may
return a measurement carried over from a *previous* week. Those terms describe
different windows: a carried 77pp/$1239.62 beside a fresh week reporting 1pp
would serve `1.5/1239.62` — roughly fifty times too low. Freshening now requires
the stored anchor to match the reported one; otherwise the carried ratio is
served intact.

Resolution order: ≥2 accepted live ticks (median) → bootstrap → a single tick.

## 5. Waiting, bounded

The clock means "a number is coming". It falls to `n/a` when the provider has no
weekly window, when the model cannot be priced, or after **60 seconds measured
from app launch** — not per session and not per attempt, either of which would
restart under the user. A scan in flight suppresses the budget, itself bounded by
a 120s deadline so a stalled scan cannot pin the clock forever.

## 6. Smoothing

- **Rate hold (150s).** Providers emit a usage record only per assistant message,
  and the parsers require one within ~30s, so a turn spent thinking or in a long
  tool read as "no activity" and the row flickered between a number and `quiet`.
  `RunwayWeeklyRateHold` bridges the gap; `.idle`, `.unsupported` and `.waiting`
  pass through untouched, and a genuinely stopped session still goes quiet.
- **Provisional clamp (all units).** A new session's first turn is cache-heavy
  and may be measured over as little as 2s, giving rates an order of magnitude
  high — seen as a headline `38%/h` that silently corrected itself. The existing
  per-path guard could not fire, because it compares against the best *measured*
  path in the same session and a brand-new session has none. A cross-**session**
  clamp caps a provisional session at the fastest measured session that cycle and
  withholds it entirely when nothing is measured. Applied to `tk`, `$` and `Wk`;
  `5h` is structurally immune, splitting a fixed account rate.

## 7. Scope and honest limits

- Claude calibration is **memory-only** for the live tracker (`ClaudeLimitSnapshot`
  carries no account scope); its bootstrap persists keyed by reset anchor under
  the literal scope `unscoped`. Two Claude accounts on one machine would share
  that slot. The reset anchor discriminates in practice — it is an account's own
  reset instant at second precision — but this is a real gap, not a guarantee.
  Tracked in `docs/backlog.md` ("Weekly quota calibration cannot tell two accounts
  of the same provider apart"); the fix is multi-account support for Claude and
  Codex, not a better cache key, and is not planned soon.
- In-memory calibration state is keyed by provider, while the persisted keys are
  account-scoped. A same-process account switch would otherwise keep serving the
  previous account's conversion, so a scope change now clears that provider's
  bootstraps, tracker, ledger and scan bookkeeping.
- **Both providers quantize weekly percent to whole points**, so the midpoint
  correction applies to both — and on every path. Verified against the live
  payload: Claude's OAuth `utilization` reports `27.0` / `11.0` and
  `limits[].percent` is a literal JSON integer. `weeklyUsedRatio` is a `Double`
  only because the normalizer divides by 100 — it does not imply sub-point
  resolution, and Claude's `observeQuota` call accordingly reports
  `hasExactPercent: false` so it takes the 1pp acceptance floor rather than the
  0.25pp one.
- The midpoint previously lived only on the freshening path, so whether a
  measurement received it depended on whether its window matched the current one:
  a carried-over bootstrap served the raw floor while a current-window one served
  the midpoint. Two providers' numbers were incomparable for no reason but which
  code path they took. It now lives on the measurement
  (`calibratedPercentPointsPerDollar`).
- A bootstrap is stamped with the **price revision** and **limit shape** it was
  measured under, and an incompatible stamp is neither restored nor migrated —
  otherwise an old plan or a stale price table could win the carry-over slot
  forever purely by having reached a larger percentage. Records written before the
  stamp existed decode as `nil` and are still accepted: discarding them would
  throw away the completed windows the cache exists to keep.
- **A quota regime can change with nothing in the payload announcing it.**
  Promotional weekly limits move capacity by tens of percent and begin and end
  with no price change and no limit-shape change, so the compatibility stamp
  cannot see them and a carry-over measured under one stays formally valid while
  describing a plan that no longer exists. Two guards, since detection is
  impossible: the current window is preferred outright once it reaches
  `wellConditionedPercentPoints` (10pp, ~±5% quantization), and a carry-over no
  fresh measurement has displaced expires after `carryOverMaximumAge` (21 days,
  three weekly windows). Both thresholds are judgment calls, not measurements.
  Vendor promotion terms and dates are deliberately kept out of the code and out
  of this spec: they change, and neither can verify them.
- **The ledger must vouch for the span it freshens.** `activity(from:to:)` answers
  from a single bucket, so freshening silently accepted intervals it never watched
  and undercounted the denominator — which overstates burn rather than failing
  safe. The ledger is memory-only, so every restart hit this: a cache of
  4pp/$13.56 restored while real spend had reached $28.07 served 0.332 pp/$
  against a true 0.232, **43% high**, and neither the growth (+3pp) nor the age
  (6h) trigger could clear it. Freshening now applies the same
  `maximumPollGap` check the live tracker uses, and a stored measurement the
  ledger cannot cover is a third rescan trigger.
- A bootstrap scan captures a **scope generation** at dispatch and its result is
  discarded if the generation has moved. A scan walking hundreds of megabytes can
  outlive the account it was started for, and the state dictionaries are keyed by
  provider, so nothing else would stop account A's result landing in account B.
- Outside usage (another device, an untracked client) drops the account quota
  with no local activity to match, biasing the calibration **high**. Intervals
  with zero local activity are rejected; partial contamination is not detectable.
- Per-session rates derive from a ~30s sampling window, so they are spikier than
  a weekly quantity warrants. The hold masks this; it does not fix it.
- Values above 999%/h render `n/a` — at that magnitude the calibration is
  contaminated, not the session extraordinary.

## 8. Verification performed

Independent recomputation from raw transcripts, outside the app:

```
Claude  previous full week : 77pp / $1239.62 → 0.0621 pp/$   (implied quota $1610)
        current window     :  7pp / $ 142.71 → 0.0491 pp/$   (implied quota $2039)
Codex   current window     :  4pp / $  17.84 → 0.2242 pp/$   (implied quota $446)
```

No ground-truth quota size is published, so these are the strongest available
evidence — but they do **not** corroborate each other. The two Claude windows
differ by **26%**, and treating 7pp as `[7,8)` yields `0.0491–0.0561`, which
still does not reach `0.0621`. The completed week is the better-conditioned
measurement (larger numerator, whole window) and is what the app now serves; the
disagreement is unexplained and is a reason to distrust short windows, not a
validation of the model. An earlier revision of this spec cited these as agreeing
"within quantization" — that claim was wrong and is withdrawn.

Cross-provider, Codex consumes roughly **3.6–4.0×** more weekly quota per
API-equivalent dollar than Claude. The range is not hedging — it is the
quantization policy:

```
floors     : 4/$17.84 = 0.2242   77/$1239.62 = 0.0621   -> 3.61x
midpoints  : 4.5/$17.84 = 0.2522   77.5/$1239.62 = 0.0625 -> 4.03x
```

The app serves the midpoint on both, so **~4.0×** is the consistent figure; the
earlier 3.61× divided the floors and did not apply this spec's own policy.
Treat it as a snapshot, not a settled constant: the Codex numerator is only 4pp,
so quantization alone puts ±12% on it, and it drifts inside the integer quantum
as the week accrues. Claude's 77pp numerator carries ±0.6%. The gap will be worth
restating once Codex has a completed window to divide.

The direction survives every correction above and is not a cache-mix artifact —
both providers ran 93–98% cache reads over the compared windows. It rests on the
assumption that quota consumption is proportional to API list price, which is
unverified and may not hold identically across providers.

## 9. Key regression tests

`WeeklyQuotaCalibrationTests`, `WeeklyQuotaBootstrapTests`,
`WeeklyQuotaBootstrapCacheTests`, `WeeklyQuotaDisplayTests`, `WeeklyRateHoldTests`,
`ProvisionalRateClampTests`, `RunwayQuietLabelTests`, `RunwayLoadBarAgreementTests`.

Notable invariants pinned: `Wk` can never resolve to `tk/h` or `$/h`; no
calibration renders a clock, never `0%/h`; doubling activity doubles `%/h`; a
session ending mid-interval stays in the denominator; a drop with no local
activity is rejected; unpriced material activity voids an interval; scope changes
invalidate; a scoped calibration survives restart and an unscoped one does not;
the carry-over survives a reset; the bar never fills at a zero rate.

`WeeklyQuotaBootstrapCacheTests` pins the cache defects specifically: a completed
window migrates into the carry-over slot; migration cannot demote a better slot;
freshening is rejected across a window boundary; a failed scan backs off and stays
retryable; a 0pp window does not block the retry at 1pp; an age-triggered rescan
actually **replaces** the stored denominator rather than merely dispatching; and
an account switch drops the previous account's conversion. The last two exist
because the original age-trigger test scanned `/nonexistent` and asserted only
that a scan was launched — a scan that had to fail. Dispatch and success are now
separate observations.

Tests use `WeeklyQuotaCalibrationStore.makeForTesting()` and an injected
`UserDefaults` suite. Do **not** test against `.shared`: it carries a launch
timestamp from whenever the first test touched it, which makes budget assertions
pass alone and fail in the suite.
