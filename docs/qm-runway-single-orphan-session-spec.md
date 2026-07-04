# Spec — Runway "single orphan session" promotion (no more "+1 session")

**Status:** Draft / awaiting approval — no code written yet
**Date:** 2026-07-03
**Area:** Quota Meter (QM) → session Runway drawer

---

## 1. One-liner

The Runway shows up to 4 real session rows, then collapses everything else into a
single summary row. When only **one** session overflows, that summary reads
"**+1 session**" — which wastes a row saying nothing useful. Instead, when exactly
one session would be hidden, render it as a **full row** (name + burn rate + load
bar). Keep the "**+X sessions**" summary only when **2 or more** sessions overflow.

## 2. Current behavior

The Runway drawer is fed a `CodexRunwaySnapshot`:

```swift
struct CodexRunwaySnapshot {
    let baseline: RunwayProviderBaseline
    let rows: [RunwayPauseImpactRow]        // up to maxRows real sessions
    let burstSummary: RunwayShortBurstSummary?   // the collapsed overflow, or nil
}
```
— [CodexRunwayModel.swift:139](AgentSessions/CodexStatus/CodexRunwayModel.swift:139)

The HUD requests `maxRows: 4` for the drawer
([AgentCockpitHUDView.swift:3905](AgentSessions/Views/AgentCockpitHUDView.swift:3905),
[:3921](AgentSessions/Views/AgentCockpitHUDView.swift:3921),
[:4164](AgentSessions/Views/AgentCockpitHUDView.swift:4164),
[:4180](AgentSessions/Views/AgentCockpitHUDView.swift:4180)),
so the runway renders **≤ 4** ranked session rows and then, if any sessions remain,
one aggregate `burstSummary` row.

The view renders that summary via:

```swift
private func summaryLabel(_ summary: RunwayShortBurstSummary) -> String {
    summary.quotaMinutesPerHour > 0 ? "+\(summary.count) bursts" : "+\(summary.count) sessions"
}
```
— [AgentCockpitHUDView.swift:4579](AgentSessions/Views/AgentCockpitHUDView.swift:4579)

The `burstSummary` is produced in **three** places, all in
[CodexRunwayModel.swift](AgentSessions/CodexStatus/CodexRunwayModel.swift):

| # | Site | What it splits | Overflow → summary when |
|---|------|----------------|-------------------------|
| A | `CodexRunwayCalculator.snapshot` — *after-reset* branch ([:412–442](AgentSessions/CodexStatus/CodexRunwayModel.swift:412)) | `ranked.prefix(maxRows)` vs `ranked.dropFirst(maxRows)` | `hiddenCount > 0` |
| B | `CodexRunwayCalculator.snapshot` — *pressure* branch ([:445–466](AgentSessions/CodexStatus/CodexRunwayModel.swift:445)) | `pressureImpacts.prefix(maxRows)` vs `.dropFirst(maxRows)` | `summary(...)` non-nil |
| C | `RunwaySnapshotAssembly.withPendingRows` ([:308–346](AgentSessions/CodexStatus/CodexRunwayModel.swift:308)) | pending identities fill open slots up to `maxRows` | `hiddenPendingCount > 0` |

All providers share this path — the Claude loader calls the same
`CodexRunwayCalculator.snapshot` + `RunwaySnapshotAssembly.withPendingRows`
([ClaudeRunwaySnapshotLoader.swift:53–62](AgentSessions/ClaudeStatus/ClaudeRunwaySnapshotLoader.swift:53)).

## 3. Problem

With exactly `maxRows + 1` sessions (e.g. **5** in the drawer), the user sees
4 real rows plus a fifth row that just says "**+1 session**". That fifth row:

- Occupies the **same vertical space** as a real row would.
- Hides the session's name, burn rate, and load bar behind a useless count of "1".
- Is grammatically the plural template collapsed onto a singular ("+1 session**s**"
  is the raw string; even fixed to "+1 session" it's still strictly worse than
  just showing the session).

There is **zero height cost** to showing the real row instead — a summary row and a
real row are both exactly one runway row tall.

## 4. Desired behavior

**Orphan-promotion rule.** When splitting the ranked session list into visible rows
plus an overflow summary:

- If the overflow would contain **exactly one** session → promote that session to a
  **full visible row** and emit **no summary**.
- Emit the "+X …" summary **only when two or more** sessions overflow.

Formally, for a ranked list of `total` sessions and a cap of `maxRows` (≥ 1):

```
visibleCount = (total == maxRows + 1) ? total : min(total, maxRows)
summary emitted  ⇔  total > maxRows + 1        // i.e. overflow ≥ 2
summary.count (when emitted)  ≥ 2               // "+1" becomes unreachable
```

Worked examples with `maxRows = 4`:

| total sessions | visible rows | summary |
|----------------|--------------|---------|
| ≤ 4 | all | none |
| **5** | **5 (all)** | **none** ← the fix |
| 6 | 4 | `+2 sessions` |
| 9 | 4 | `+5 sessions` |

Max runway height is **unchanged**: worst case is still `maxRows` rows + 1 summary =
`maxRows + 1` rows; the promoted-orphan case is also exactly `maxRows + 1` rows.

## 5. Why the fix must live in the model, not the view

By the time data reaches `summaryLabel` in the view, the individual hidden session's
identity — its `displayName`, `quotaMinutesPerHour`, `confidence`, `deadline` — has
already been discarded into an aggregate `RunwayShortBurstSummary { count, deadline,
gainedSeconds, quotaMinutesPerHour }`. The view **cannot** reconstruct the session's
name or load bar. Therefore the promotion must happen where the per-session
`RunwayPauseImpactRow` still exists: inside `CodexRunwayModel.swift`.

A promoted orphan is strictly richer than the summary it replaces — it shows the real
name and a live load bar instead of "+1".

## 6. Proposed changes (model only)

Introduce one shared split helper and use it at all three sites so the rule lives in a
single place.

### 6.1 Shared helper (new)

```swift
// Splits an already-ranked list into (visibleRows, overflow).
// Orphan rule: a lone overflow item is promoted to a visible row.
private static func splitForRunway<T>(_ ranked: [T], maxRows: Int) -> (visible: ArraySlice<T>, overflow: ArraySlice<T>) {
    guard maxRows > 0 else { return (ranked[..<0], ranked[...]) }
    let overflow = ranked.count - maxRows
    if overflow <= 1 {                       // 0 hidden, or exactly 1 → show all
        return (ranked[...], ranked[..<0])
    }
    return (ranked.prefix(maxRows), ranked.dropFirst(maxRows))
}
```

(Exact type/placement at implementer's discretion; the behavior is what matters.)

### 6.2 Site A — after-reset branch ([:422–442](AgentSessions/CodexStatus/CodexRunwayModel.swift:422))

Replace `ranked.prefix(maxRows)` / `ranked.dropFirst(maxRows)` with the helper.
`burstSummary` is built from `overflow` and is `nil` when `overflow` is empty (which
now includes the single-orphan case). The promoted orphan is mapped through the same
`RunwayPauseImpactRow(...)` constructor already used for visible rows, so it keeps its
`.afterReset` deadline and real `quotaMinutesPerHour`.

### 6.3 Site B — pressure branch ([:459–466](AgentSessions/CodexStatus/CodexRunwayModel.swift:459))

Same substitution. `rows = visible.map(\.row)`; `summary(for: Array(overflow), …)`.
Because `summary(...)` already returns `nil` for an empty slice, the single-orphan case
naturally yields no summary and the orphan appears as a full row.

### 6.4 Site C — pending fill ([:318–345](AgentSessions/CodexStatus/CodexRunwayModel.swift:318))

Today `openSlots = max(0, maxRows - existing.rows.count)` and any pending beyond that
becomes `pendingSummary`. Apply the orphan rule against the **combined** row budget:
if, after filling up to `maxRows`, exactly **one** pending identity would be hidden,
render it as a real pending row (`quotaMinutesPerHour: 0`, `.idle`/`.waiting`
confidence — identical to how the other pending rows already render) and emit no
`pendingSummary`. Only collapse when ≥ 2 pending remain.

**Also fix the overflow undercount (folded in — see Appendix A).** Replace the
precedence `burstSummary: existing.burstSummary ?? pendingSummary` with a **merge**:
when both an existing burn summary and hidden pending sessions exist, the displayed
"+X" must count `existing.burstSummary.count + hiddenPendingCount`, not just one of
them. Reachability is guaranteed to be `openSlots == 0` whenever
`existing.burstSummary != nil` (rows are already full to `maxRows`), so pending
identities can never double-count with the hidden burns — the merge is a pure count
addition. Keep the burn summary's `quotaMinutesPerHour`/`deadline` (pending
contributes rate 0 / `.unavailable`), only summing `count`. After the orphan rule,
the merged `count` is still ≥ 2, preserving the plural-only invariant.

### 6.5 View

No change required. Because `summary.count ≥ 2` is now an invariant, the
`"+\(count) sessions"` / `"+\(count) bursts"` label is always grammatically plural and
correct. (Optional hardening, not required: `assert(summary.count >= 2)` in
`summaryRow`.)

## 7. Edge cases

- **total ≤ maxRows:** unchanged — all rows shown, no summary.
- **total == maxRows + 1:** the fix — all shown as rows, no summary.
- **total ≥ maxRows + 2:** unchanged — `maxRows` rows + `+X` summary, `X ≥ 2`.
- **maxRows == 0:** guarded early in both functions today; helper preserves that (no rows).
- **Goal (GOAL) row as the orphan:** promoted like any other row; `sessionLabel`
  already prefixes `"GOAL "` ([AgentCockpitHUDView.swift:4575](AgentSessions/Views/AgentCockpitHUDView.swift:4575)).
- **Bursts vs sessions wording:** the rule applies to both variants; "+1 bursts" is
  eliminated for the same reason as "+1 session".
- **Zero-rate orphan (pending path):** shows with `0m/h`/`—`, consistent with existing
  pending/idle rows.
- **Sort order:** unchanged; the promoted orphan is the `(maxRows+1)`-th ranked item and
  becomes the last visible row.

## 8. Test plan (unit, at the calculator level)

Existing tests in
[CodexUsageParserTests.swift](AgentSessionsTests/CodexUsageParserTests.swift) already
exercise the split (e.g. `snapshot(..., maxRows: 1)` with 3 burns → `rows.count == 1`,
`burstSummary.count == 2` at [:2504](AgentSessionsTests/CodexUsageParserTests.swift:2504)).
That case has overflow 2, so it **stays green**. Add:

1. **`…PromotesSingleOverflowSessionToRow`** — `maxRows: 1`, **2** burns → expect
   `rows.count == 2`, `burstSummary == nil`, and both real display names present.
2. **`…KeepsSummaryForTwoOrMoreOverflow`** — `maxRows: 1`, **3** burns → expect
   `rows.count == 1`, `burstSummary?.count == 2` (regression guard on the ≥2 path).
3. **`…AfterResetPromotesSingleOverflow`** — after-reset branch (`currentRunoutAt ≥
   resetAt`), `maxRows: 2`, **3** burns → `rows.count == 3`, `burstSummary == nil`.
4. **`…PendingPromotesSingleOverflow`** — `withPendingRows` with `maxRows: 2`, existing
   rows = 2, **1** extra pending identity → the pending identity becomes a 3rd row,
   `burstSummary == nil`.
5. **`…PendingKeepsSummaryForTwoOverflow`** — same but **2** extra pending → 2 rows +
   `pendingSummary.count == 2`.
6. **Invariant guard:** across the above, assert `burstSummary == nil || burstSummary!.count >= 2`.
7. **`…PendingOverflowMergesWithBurnSummary`** (Appendix A): a snapshot with
   `rows.count == maxRows` and a `burstSummary` of count *b*, passed to
   `withPendingRows` with *p* (≥ 2) unrepresented active identities → expect the
   returned `burstSummary.count == b + p` (today it is just *b*).

## 9. Non-goals

- No change to `maxRows` (stays 4 in the drawer) or overall runway height.
- No change to ranking/sort, burn-rate math, load-bar rendering, or the summary's
  aggregate rate/deadline math for the ≥2 case.
- No change to the `summaryLabel` copy (it's already correct once "+1" is unreachable).
- No change to the enlarged/compact QM sizing.

## 10. Acceptance criteria

- With 5 concurrent sessions and `maxRows: 4`, the drawer shows **5 named rows** and
  **no** summary row.
- With 6+ sessions, the drawer shows 4 rows + a "**+X sessions/bursts**" row where
  **X ≥ 2**.
- "**+1 session**" / "**+1 bursts**" can no longer be produced by any code path.
- Max runway height is unchanged (≤ `maxRows + 1` rows).
- All existing runway tests remain green; the new tests above pass; behavior is
  identical for Codex and Claude providers.
- The "+X" overflow count reflects **all** hidden active sessions (burning +
  non-burning), not just hidden burns (Appendix A).

---

## Appendix A — Overflow undercount in `withPendingRows` (folded into this change)

`RunwaySnapshotAssembly.withPendingRows` currently resolves the overflow summary with
`burstSummary: existing.burstSummary ?? pendingSummary`
([CodexRunwayModel.swift:344](AgentSessions/CodexStatus/CodexRunwayModel.swift:344)).

**Defect.** When ≥ `maxRows` sessions are actively burning (so `snapshot()` already
produced a full row set + a `burstSummary`) *and* there are additional active-but-not-
burning sessions, those extra sessions become `pendingIdentities`, get summarized into
`pendingSummary`, and are then **discarded** by `??`. The drawer's "+X sessions" only
counts the hidden *burns* and silently omits the idle actives — the displayed count is
lower than the real number of concurrent sessions.

**Not a double-count.** `existing.burstSummary != nil` implies `existing.rows.count ==
maxRows` (rows are `prefix(maxRows)` and a summary only appears when items overflowed),
so `openSlots == 0`, so no pending identity is also rendered as a row. The fix is a
pure additive merge of `count`; rate/deadline stay from the burn summary (pending
contributes 0 / `.unavailable`).

**Why folded here, not shipped separately.** This is the same function being rewritten
for the orphan rule (§6.4); the fix needs its own test (§8.7) and a small semantic
decision (which summary owns the aggregate rate). Bundling avoids editing
`withPendingRows` twice and keeps all overflow-accounting changes in one reviewed,
tested commit. Severity is low and the trigger is rare (≥ `maxRows` burning + ≥ 1 idle
active in one provider), so there is no urgency to split it out.
