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

Three corrections, each from an observed error on live data:

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
  carries no account scope); its bootstrap persists keyed by reset anchor.
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
Claude  previous full week : 72pp / $1073.58 → 0.0671 pp/$   (implied quota $1491)
        current window     :  6pp / $ 114.28 → 0.0569 pp/$
Codex   current window     :  3pp / $  11.89 → 0.2523 pp/$   (implied quota $396)
```

Two independent windows agreeing within quantization is the strongest available
evidence, since no ground-truth quota size is published.

## 9. Key regression tests

`WeeklyQuotaCalibrationTests`, `WeeklyQuotaBootstrapTests`,
`WeeklyQuotaDisplayTests`, `WeeklyRateHoldTests`, `ProvisionalRateClampTests`,
`RunwayQuietLabelTests`, `RunwayLoadBarAgreementTests`.

Notable invariants pinned: `Wk` can never resolve to `tk/h` or `$/h`; no
calibration renders a clock, never `0%/h`; doubling activity doubles `%/h`; a
session ending mid-interval stays in the denominator; a drop with no local
activity is rejected; unpriced material activity voids an interval; scope changes
invalidate; a scoped calibration survives restart and an unscoped one does not;
the carry-over survives a reset; the bar never fills at a zero rate.

Tests use `WeeklyQuotaCalibrationStore.makeForTesting()` and an injected
`UserDefaults` suite. Do **not** test against `.shared`: it carries a launch
timestamp from whenever the first test touched it, which makes budget assertions
pass alone and fail in the suite.
