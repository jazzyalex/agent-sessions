# Claude Quota Meter Burn-Rate Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the Claude per-session runway burn rate ("m/h") from exploding to thousands as the 5-hour reset approaches, by deriving the no-projection baseline run-out from average usage instead of the reset time.

**Architecture:** The displayed Claude per-session burn is `providerRate × (session token share)`, where `providerRate = remainingPercent / (currentRunoutAt − observedAt)`. Claude almost never has a fresh account projection, so `currentRunoutAt` falls back to `resetAt` — making the denominator → 0 near reset and `providerRate` (hence m/h) blow up. Fix: when there is no fresh projection, set `currentRunoutAt` from the **measured average burn so far this window** (`used% / elapsed`). That makes `providerRate == averageRate`, fully decoupled from time-to-reset, so it can never explode. Change is isolated to the baseline construction in the Claude request builder plus one pure helper; no view or parser changes.

**Tech Stack:** Swift, XCTest, macOS app target `AgentSessions` / test target `AgentSessionsTests`. Tests run via `./scripts/xcode_test_stable.sh`.

## Global Constraints

- **Commits:** NEVER run `git commit`/`git push` without an explicit user request. The commit steps below are part of the plan, but only execute them when the user says "commit". (Project rule, `CLAUDE.md`.)
- **Commit format:** Conventional Commits, no "Generated with Claude Code" footer, no `Co-Authored-By: Claude` trailer. Include `Tool:` / `Model:` / `Why:` trailers. Author is the repo owner only.
- **No new files:** all edits land in three existing files — no `scripts/xcode_add_file.rb` registration needed.
- **Scope:** Claude only. Codex is unaffected — its token burns are gated on `hasProjectedRunout` (`CodexRunwaySnapshotLoader.swift:149`), so when Codex lacks a projection it shows *no* token burn rather than an inflated one. Do not touch the Codex path.
- **Unit:** "m/h" = quota-minutes per hour; a full 5h window is 300 quota-minutes and the HUD burn bar saturates at 45 m/h (`AgentCockpitHUDView.swift:4458`). Any single-session value in the thousands is the bug.

## Background (root cause, verified)

- `AgentCockpitHUDView.swift:3534` (`HUDRunwayRequestBuilder.claudeRequest`):
  `runoutAt = freshProjectionObservedAt.flatMap { _ in fiveHourProjectedRunoutAt } ?? resetAt`.
  Claude has no fresh projection (documented in `docs/claude-usage-projection-freshness.md`), so `runoutAt = resetAt`.
- `ClaudeRunwayTokenActivityParser.burns` (`...ClaudeRunwayTokenActivityParser.swift:79-82`):
  `currentSeconds = currentRunoutAt − observedAt = timeToReset`; `providerRate = remaining / timeToReset`.
- Single active session ⇒ displayed `m/h = remaining% × 10800 / secondsToReset`. Live example: remaining 61%, ~157 s to reset ⇒ ~4196 m/h. As `secondsToReset → 0`, m/h → ∞.
- Fix target invariant: with average-burn run-out, `secondsToRunout = remaining / (used/elapsed)`, so `providerRate = remaining / secondsToRunout = used/elapsed = averageRate` — independent of `secondsToReset`.

## File Structure

- `AgentSessions/CodexStatus/CodexRunwayModel.swift` — **Modify.** Home of `RunwayProviderBaseline`. Add a small pure `enum RunwayBaselineMath` with `averageBurnRunout(...)` and the `fiveHourWindow` constant. (Shared model file, no SwiftUI, trivially testable.)
- `AgentSessions/Views/AgentCockpitHUDView.swift` — **Modify.** `HUDRunwayRequestBuilder.claudeRequest` (the `runoutAt` line at `:3534`) calls the new helper as the no-projection fallback.
- `AgentSessionsTests/ClaudeRunwayParserTests.swift` — **Modify.** Add unit tests for the helper and one integration test for `claudeRequest`.

---

### Task 1: `RunwayBaselineMath.averageBurnRunout` pure helper

**Files:**
- Modify: `AgentSessions/CodexStatus/CodexRunwayModel.swift` (add after the `RunwayProviderBaseline` struct, ~line 38)
- Test: `AgentSessionsTests/ClaudeRunwayParserTests.swift`

**Interfaces:**
- Produces:
  - `enum RunwayBaselineMath`
  - `static func averageBurnRunout(remainingPercent: Double, resetAt: Date, windowLength: TimeInterval, now: Date) -> Date?`
  - `static let fiveHourWindow: TimeInterval` (= `5 * 3600`)
  - `static let minimumElapsed: TimeInterval` (= `10 * 60`)

- [ ] **Step 1: Write the failing tests**

Add to `ClaudeRunwayParserTests.swift` (inside the `final class ClaudeRunwayParserTests`):

```swift
    // MARK: - RunwayBaselineMath.averageBurnRunout

    /// The whole point of the fix: near reset, the derived rate reflects the
    /// measured average (~36 m/h for 60% used over ~5h), NOT the reset-pinned
    /// fallback (~3600 m/h) that exploded as the denominator shrank.
    func testAverageBurnRunoutDoesNotExplodeNearReset() throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let resetAt = now.addingTimeInterval(120) // 2 min to reset
        let runout = try XCTUnwrap(RunwayBaselineMath.averageBurnRunout(
            remainingPercent: 40,
            resetAt: resetAt,
            windowLength: RunwayBaselineMath.fiveHourWindow,
            now: now))
        let providerRate = 40.0 / runout.timeIntervalSince(now) // %/s
        let mPerHour = providerRate * 3 * 3600
        XCTAssertEqual(mPerHour, 36.2, accuracy: 1.0)
        XCTAssertLessThan(mPerHour, 100)
    }

    /// The rate must stay stable as the reset approaches (it depends on
    /// elapsed, not time-to-reset). The old fallback produced ~3600 then
    /// ~21600 m/h for these two inputs.
    func testAverageBurnRunoutRateStableAsResetApproaches() throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        func mPerHour(secondsToReset: TimeInterval, remaining: Double) throws -> Double {
            let resetAt = now.addingTimeInterval(secondsToReset)
            let runout = try XCTUnwrap(RunwayBaselineMath.averageBurnRunout(
                remainingPercent: remaining,
                resetAt: resetAt,
                windowLength: RunwayBaselineMath.fiveHourWindow,
                now: now))
            return remaining / runout.timeIntervalSince(now) * 3 * 3600
        }
        let near = try mPerHour(secondsToReset: 120, remaining: 40)
        let nearer = try mPerHour(secondsToReset: 20, remaining: 40)
        XCTAssertEqual(near, nearer, accuracy: 1.0)
        XCTAssertLessThan(nearer, 100)
    }

    /// Nothing used yet ⇒ no measurable burn ⇒ nil (caller keeps resetAt).
    func testAverageBurnRunoutNilWhenNothingUsed() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        XCTAssertNil(RunwayBaselineMath.averageBurnRunout(
            remainingPercent: 100,
            resetAt: now.addingTimeInterval(3600),
            windowLength: RunwayBaselineMath.fiveHourWindow,
            now: now))
    }

    /// Defensive: a reset farther out than the window length puts the window
    /// start in the future ⇒ nil rather than a negative elapsed.
    func testAverageBurnRunoutNilWhenWindowStartInFuture() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        XCTAssertNil(RunwayBaselineMath.averageBurnRunout(
            remainingPercent: 40,
            resetAt: now.addingTimeInterval(6 * 3600),
            windowLength: RunwayBaselineMath.fiveHourWindow,
            now: now))
    }

    /// Symmetric guard: a burst 30 s after reset (2% used) must be damped by the
    /// elapsed floor (2%/600s → ~36 m/h), not divided by 30 s (2%/30s → ~720 m/h).
    func testAverageBurnRunoutFloorsEarlyWindowElapsed() throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let resetAt = now.addingTimeInterval(RunwayBaselineMath.fiveHourWindow - 30)
        let runout = try XCTUnwrap(RunwayBaselineMath.averageBurnRunout(
            remainingPercent: 98,
            resetAt: resetAt,
            windowLength: RunwayBaselineMath.fiveHourWindow,
            now: now))
        let mPerHour = 98.0 / runout.timeIntervalSince(now) * 3 * 3600
        XCTAssertEqual(mPerHour, 36.0, accuracy: 2.0)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/ClaudeRunwayParserTests`
Expected: FAIL to compile with "cannot find 'RunwayBaselineMath' in scope".

- [ ] **Step 3: Implement the helper**

In `AgentSessions/CodexStatus/CodexRunwayModel.swift`, add immediately after the `RunwayProviderBaseline` struct (the struct ends ~line 38):

```swift
/// Baseline math shared by the runway request builders.
enum RunwayBaselineMath {
    /// The 5-hour rolling window length used by the "5h" limit.
    static let fiveHourWindow: TimeInterval = 5 * 3600

    /// Floor for elapsed time. A heavy burst in the first minutes after a reset
    /// (e.g. a workflow fanning out many agents) could otherwise divide by a
    /// tiny elapsed and re-introduce small-denominator inflation on the
    /// early-window side — the symmetric twin of the near-reset bug this fix
    /// removes. 10 min over a 5h window is light smoothing that only binds early.
    static let minimumElapsed: TimeInterval = 10 * 60

    /// Even-burn run-out derived from *average usage so far this window*, for
    /// providers that lack a fresh per-account projection (Claude).
    ///
    /// The naive fallback — pinning run-out to the reset time — makes the
    /// implied burn rate `remaining / timeToReset` explode as the reset
    /// approaches (denominator → 0), producing absurd per-session "m/h".
    /// Anchoring run-out to the measured average instead (`used% / elapsed`)
    /// gives `providerRate == averageRate`, which never blows up near reset.
    /// `elapsed` is floored by `minimumElapsed` so the early-window side can't
    /// inflate the same way.
    ///
    /// Returns `nil` when no burn is measurable yet (`used <= 0`) or the
    /// window start is in the future; callers fall back to the reset time.
    static func averageBurnRunout(remainingPercent: Double,
                                  resetAt: Date,
                                  windowLength: TimeInterval,
                                  now: Date) -> Date? {
        let usedPercent = 100 - remainingPercent
        guard usedPercent > 0, remainingPercent > 0 else { return nil }
        let windowStart = resetAt.addingTimeInterval(-windowLength)
        let rawElapsed = now.timeIntervalSince(windowStart)
        guard rawElapsed > 0 else { return nil }
        let elapsed = max(rawElapsed, minimumElapsed)
        let averageRatePerSecond = usedPercent / elapsed
        guard averageRatePerSecond > 0, averageRatePerSecond.isFinite else { return nil }
        let secondsToRunout = remainingPercent / averageRatePerSecond
        guard secondsToRunout.isFinite, secondsToRunout > 0 else { return nil }
        return now.addingTimeInterval(secondsToRunout)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/ClaudeRunwayParserTests`
Expected: PASS (all four new tests + existing tests).

- [ ] **Step 5: Commit** (only on explicit user request)

```bash
git add AgentSessions/CodexStatus/CodexRunwayModel.swift AgentSessionsTests/ClaudeRunwayParserTests.swift
git commit -m "feat: add average-burn runout helper for runway baseline

Tool: Claude Code
Model: claude-opus-4-8
Why: stable no-projection burn baseline that does not explode near reset"
```

---

### Task 2: Use average-burn run-out in the Claude request builder

**Files:**
- Modify: `AgentSessions/Views/AgentCockpitHUDView.swift:3534` (`HUDRunwayRequestBuilder.claudeRequest`)
- Test: `AgentSessionsTests/ClaudeRunwayParserTests.swift`

**Interfaces:**
- Consumes: `RunwayBaselineMath.averageBurnRunout(...)`, `RunwayBaselineMath.fiveHourWindow` (Task 1).
- Produces: no signature change to `claudeRequest`; only the `runoutAt` value changes when there is no fresh projection.

- [ ] **Step 1: Write the failing integration test**

Add to `ClaudeRunwayParserTests.swift`:

```swift
    // MARK: - claudeRequest baseline

    /// End-to-end: with no projection and ~2 min to reset, the baseline the
    /// builder produces must imply a sane burn rate (< 100 m/h), not the
    /// ~3600 m/h the reset-pinned fallback produced.
    func testClaudeRequestDerivesSaneBurnRateNearReset() throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let resetAt = now.addingTimeInterval(120)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let resetText = iso.string(from: resetAt)

        let request = try XCTUnwrap(HUDRunwayRequestBuilder.claudeRequest(
            activeRows: [],
            projectedRunoutEnabled: true,
            claudeAgentEnabled: true,
            claudeUsageEnabled: true,
            fiveHourRemainingPercent: 40,
            fiveHourResetText: resetText,
            fiveHourProjectedRunoutAt: nil,
            fiveHourProjectionObservedAt: nil,
            now: now,
            maxRows: 4,
            forceVisible: true))

        let baseline = request.baseline
        let providerRate = baseline.remainingPercent
            / baseline.currentRunoutAt.timeIntervalSince(baseline.observedAt)
        let mPerHour = providerRate * 3 * 3600
        XCTAssertGreaterThan(mPerHour, 0)
        XCTAssertLessThan(mPerHour, 100)
        // Sanity: run-out is pushed well past the imminent reset.
        XCTAssertGreaterThan(baseline.currentRunoutAt, resetAt)
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/ClaudeRunwayParserTests/testClaudeRequestDerivesSaneBurnRateNearReset`
Expected: FAIL — `mPerHour` ≈ 3600 (reset-pinned fallback), so `XCTAssertLessThan(mPerHour, 100)` fails.

- [ ] **Step 3: Wire the helper into `claudeRequest`**

In `AgentSessions/Views/AgentCockpitHUDView.swift`, replace the `runoutAt` line inside `claudeRequest` (currently at `:3534`):

```swift
        let runoutAt = freshProjectionObservedAt.flatMap { _ in fiveHourProjectedRunoutAt } ?? resetAt
```

with:

```swift
        // No fresh projection: derive run-out from average usage so far this
        // window instead of pinning to resetAt, which makes the implied
        // per-session burn rate explode as the reset approaches.
        let runoutAt = (freshProjectionObservedAt.flatMap { _ in fiveHourProjectedRunoutAt })
            ?? RunwayBaselineMath.averageBurnRunout(
                remainingPercent: Double(fiveHourRemainingPercent),
                resetAt: resetAt,
                windowLength: RunwayBaselineMath.fiveHourWindow,
                now: now)
            ?? resetAt
```

Leave `observedAt`, the `guard resetAt > observedAt, runoutAt > observedAt`, and `hasProjectedRunout: freshProjectionObservedAt != nil` unchanged. Do **not** modify the Codex `request` builder at `:3481`.

- [ ] **Step 4: Run the test to verify it passes**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/ClaudeRunwayParserTests/testClaudeRequestDerivesSaneBurnRateNearReset`
Expected: PASS.

- [ ] **Step 5: Run the full runway suite (regression)**

Run: `./scripts/xcode_test_stable.sh -only-testing:AgentSessionsTests/ClaudeRunwayParserTests`
Expected: PASS — all existing tests plus the six new ones (five `averageBurnRunout` unit tests + one `claudeRequest` integration test).

- [ ] **Step 6: Commit** (only on explicit user request)

```bash
git add AgentSessions/Views/AgentCockpitHUDView.swift AgentSessionsTests/ClaudeRunwayParserTests.swift
git commit -m "fix: derive Claude runway burn from average usage, not reset time

The no-projection baseline pinned run-out to the reset time, so the
implied per-session rate (remaining / timeToReset) exploded to thousands
of m/h as the 5h reset approached. Derive run-out from average usage so
far this window so providerRate equals the measured average and stays
bounded.

Tool: Claude Code
Model: claude-opus-4-8
Why: Claude session showed 2600-5000 m/h near reset on the \$100 plan"
```

---

## Out of scope / optional follow-ups

- **Account ▸ETA badge.** This plan keeps `hasProjectedRunout = false` for the fallback, so the account-level ETA badge behavior is unchanged (it still does not claim a projection from a coarse average). If desired later, surface a distinctly-styled "coarse ETA" when the average-burn run-out precedes reset.
- **Defensive clamp.** A belt-and-suspenders cap on `quotaMinutesPerHour` in `CodexRunwayCalculator` could prevent any future explosion regardless of baseline, but risks masking genuine fast burns. Not needed once the root cause is fixed.
- **Workflow/subagent browser support** (separate investigation): `ClaudeSessionParser.detectSubagentInfo` does not recognize the nested `subagents/workflows/wf_<id>/agent-*.jsonl` layout. Tracked separately from this QM fix.

## Self-Review

- **Spec coverage:** Root cause (reset-pinned `runoutAt`) → Task 2 wiring; the stable-rate invariant → Task 1 helper + tests. Both symptoms (explosive m/h; the same fallback) trace to the one `runoutAt` line, which Task 2 changes. ✓
- **Placeholder scan:** every step has concrete code, exact paths, exact run commands, and expected output. ✓
- **Type consistency:** `averageBurnRunout(remainingPercent:resetAt:windowLength:now:) -> Date?` and `fiveHourWindow` are defined in Task 1 and consumed verbatim in Task 2 and all tests. `claudeRequest` parameters match `AgentCockpitHUDView.swift:3503-3513`. ✓
- **Numbers (near reset):** 40% remaining, 120 s to reset, 5h window: elapsed 17880 s, avg 0.003356 %/s ⇒ ~36 m/h; reset-pinned would be 40/120 = 0.333 %/s ⇒ 3600 m/h. Assertions (`≈36 ±1`, `<100`) hold. ✓
- **Numbers (early window):** 98% remaining, 30 s after reset: rawElapsed 30 s floored to 600 s ⇒ 2%/600 = 0.00333 %/s ⇒ ~36 m/h; unfloored would be 2%/30 = 0.0667 %/s ⇒ ~720 m/h. Floor test (`≈36 ±2`) holds. ✓
- **Symmetric safety:** the fix removes the small-`timeToReset` denominator and the `minimumElapsed` floor removes the small-`elapsed` denominator, so neither end of the window can inflate the rate. ✓
- **Column width:** realistic avg-burn values are 0–~300 m/h (3-digit); 4-digit overflow needs burning a large fraction of the 5h quota within the 10-min floor — not physically realistic — so the existing 3-digit rate column stays adequate. ✓
