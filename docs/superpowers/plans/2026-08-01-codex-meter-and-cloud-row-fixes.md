# Codex Meter + Cloud Row Fixes — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the Codex usage meter's permanent "reconnecting…" state, and close the known gaps left by the Claude cloud-rows feature shipped 2026-07-31.

**Architecture:** Two independent tracks. Track A (Tasks 1–4) is the Codex usage pipeline — a pre-existing bug unrelated to cloud work. Track B (Tasks 5–8) is cleanup on the cloud rows feature. They touch different files and can be done in either order; Track A is higher user value.

**Tech Stack:** Swift 5 / SwiftUI, XCTest, `./scripts/xcode_test_stable.sh`.

## Global Constraints

- Test command on this machine needs signing overrides — there is **no "Mac Development" certificate**, only Developer ID:
  `./scripts/xcode_test_stable.sh CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= CODE_SIGN_ENTITLEMENTS=`
- Runnable builds must be signed with **Developer ID**, not ad-hoc, or the app is denied the claude.ai keychain item:
  `CODE_SIGN_IDENTITY="Developer ID Application: Alex M (24NDRU35WD)" DEVELOPMENT_TEAM=24NDRU35WD`
- New Swift files MUST be registered with `./scripts/xcode_add_file.rb` (run with `LANG=en_US.UTF-8`, or xcodeproj throws on non-ASCII).
- **os_log is useless in this app** — nothing reaches `log show`/`log stream`. Use a DEBUG file write (see `ClaudeCloudLiveModel.note()`) when runtime evidence is needed.
- Conventional Commits, no Claude co-author trailer, no generated-with footer.
- Never claim a fix works without a falsifiable check. Several fixes below ship with one.

## Provenance of findings

Verified directly by me: the guard order at `CodexStatusService.swift:2337`, the empty `~/.codex/sessions/2026/08/01` and `/07/31` directories, the valid OAuth token, the absent `codex_usage_latest.json`.
Verified by subagent against live services (re-verify before relying on): the OAuth endpoint returning 200 with `primary_window.limit_window_seconds: 604800`, and `codex-cli 0.146.0` returning `windowDurationMins`.

---

# TRACK A — Codex meter (fixes "reconnecting… forever")

## Task 1: Hoist the live fetch above the rollout-file guard

**The actual bug.** The authoritative OAuth fetch sits behind a guard that requires a *local log file from today or yesterday*. With no Codex CLI run in 3 days, `sourceFile` is nil and the function returns before ever fetching. This only triggers in `.menuBackground` mode — i.e. whenever the pinned HUD is up and Agent Sessions is not frontmost, which is the normal state.

**Files:**
- Modify: `AgentSessions/CodexStatus/CodexStatusService.swift:2337-2339`

- [ ] **Step 1: Confirm the failing state before changing anything**

With no rollout file for today/yesterday and the app in menu-background, the Codex row reads "reconnecting…". Record it. Then click into the main Agent Sessions window (this switches to `.active` mode, which calls the fetch unconditionally at ~:2283) and confirm the row populates within ~1s.

**If it does NOT populate, this diagnosis is wrong — stop and re-investigate.** Everything below assumes that test passes.

- [ ] **Step 2: Move the fetch above the guard**

```swift
// The authoritative live fetch must not depend on a local log file — that is the
// whole point of it being authoritative. It previously sat below `guard let
// sourceFile`, so with no Codex CLI run in the last two days the meter never
// fetched at all and read "reconnecting…" indefinitely.
_ = await refreshPreferredLiveLimits(visibleFastPath: false)

guard let sourceFile else { return }
```

- [ ] **Step 3: Verify cost is bounded**

Read `CodexOAuthUsageFetcher` (~:148-151) and confirm the existing cooldowns (60s after success, 30min after failure) still apply on this path. Note in the commit what the added traffic actually is: one HTTPS GET per tick *only when no rollout exists*, which is what `.active` mode already pays.

- [ ] **Step 4: Run the suite**

`./scripts/xcode_test_stable.sh CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= CODE_SIGN_ENTITLEMENTS=`
Expected: 1770+ passed, 0 failures. **Note: there are no tests covering `refreshTickMenuBackground`** — a green suite does not validate this change. Step 5 does.

- [ ] **Step 5: Falsifiable runtime check**

Build Developer-ID signed, relaunch, leave the app in the background with the HUD pinned, and confirm the Codex row populates without ever focusing the window. That is the exact condition that was broken.

- [ ] **Step 6: Commit**

```bash
git commit -m "fix(codex): fetch live limits even with no recent rollout file"
```

---

## Task 2: Fix the dead CLI-RPC field name

**Files:**
- Modify: `AgentSessions/CodexStatus/CodexCLIRPCProbe.swift:227-237`
- Test: `AgentSessionsLogicTests/` (new or existing Codex RPC test file)

The probe looks for `windowMinutes`, `windowSizeMinutes`, `windowMinutesTotal`, `windowSizeSeconds`, `windowSeconds`. The live CLI returns **`windowDurationMins`**. Unmatched → `windowMinutes` nil → lone lengthless window → `CodexRateLimitWindowClassifier.route` returns `suspect: true` with no windows → `guard hasData else { return nil }` drops the whole response silently. The existing code comment concedes the name was "unconfirmed"; it was wrong.

- [ ] **Step 1: Re-verify the field name against the installed CLI**

Do not trust this plan. Run the app-server RPC and read the actual payload; record the observed key and CLI version in the commit message.

- [ ] **Step 2: Write the failing test**

```swift
func test_parsesWindowDurationMinsFromLiveCLIShape() throws {
    let json = #"{"primary":{"usedPercent":1,"windowDurationMins":10080,"resetsAt":1786201963},"secondary":null}"#
        .data(using: .utf8)!
    let parsed = try XCTUnwrap(CodexCLIRPCProbe.parseRateLimits(json))
    XCTAssertEqual(parsed.primaryWindowMinutes, 10080,
                   "windowDurationMins is what codex-cli 0.146.0 actually emits")
}
```

Adjust names to the real API surface once read.

- [ ] **Step 3: Add the key, run tests, commit**

Add `windowDurationMins` to the candidate list. Keep the existing names — older CLIs may still use them. Commit as `fix(codex): accept windowDurationMins from codex-cli rate limits`.

---

## Task 3: Persist the Codex usage snapshot

**Files:**
- Create: `AgentSessions/CodexStatus/CodexUsageSnapshotStore.swift`
- Modify: `AgentSessions/CodexStatus/CodexStatusService.swift` (write on apply, read on init)
- Test: `AgentSessionsLogicTests/CodexUsageSnapshotStoreTests.swift`

Codex state is in-memory only — `ClaudeUsageSnapshotStore` has no Codex counterpart. Every relaunch starts blank, which is why a transient failure presents as permanent. Mirror the Claude store exactly (`ClaudeStatus/ClaudeOAuth/ClaudeUsageSnapshotStore.swift`), writing `codex_usage_latest.json` beside `claude_usage_latest.json`.

- [ ] Steps: write failing round-trip test → register file → implement mirroring the Claude store → load on init as a stale-marked seed (never as live data) → run suite → commit.

**Risk:** a restored snapshot must never render as fresh. Gate it so `dataIsStale` is true until a live fetch lands, or this reintroduces the "trusting figures that stopped updating" failure.

---

## Task 4: Make the Codex meter say something true

**Files:**
- Modify: `AgentSessions/Views/CockpitFooterView.swift:159-176` (`QuotaData.codex(from:)`)
- Modify: `AgentSessions/CodexStatus/CodexAuthClassifier.swift:11-45`
- Test: `AgentSessionsLogicTests/`

"reconnecting…" implies a recoverable, in-progress condition. "You have not run Codex in three days, and nothing is in flight" is terminal and will never self-resolve. The user read the spinner as a fault and asked what was broken — the label caused that.

Two reasons the honest state is unreachable: `CodexAuthClassifier` has no `.idle` branch (only Claude ever publishes `.idle`), and `QuotaData.codex(from:)` never passes `transientReason`, `dataIsStale`, or `currentSource` — so `reconnectingCaption` can only ever return the generic string.

- [ ] **Step 1:** Thread `transientReason` and `dataIsStale` into `QuotaData.codex(from:)`, matching the Claude constructor at :179-196.
- [ ] **Step 2:** Add an `.idle` verdict to `CodexAuthClassifier` for "credentials valid, no data, nothing in flight".
- [ ] **Step 3:** Test that each distinct condition yields a distinct caption — the same anti-spinner guard used for `ClaudeCloudSourceState`. Assert no two states collapse to identical copy.
- [ ] **Step 4:** Run suite, commit.

**Note:** after Task 1 this state should become rare — but "rare" is exactly when a misleading label does the most damage, because there is no recent experience to reinterpret it against.

---

# TRACK B — Cloud rows cleanup

## Task 5: Stop the pinned window clipping rows

**Files:**
- Modify: `AgentSessions/Views/AgentCockpitHUDWindow.swift:337-348` (`limitsWindowHeight`)
- Modify: `AgentSessions/Views/AgentCockpitHUDView.swift` (`cloudStatusLine` placement / measurement)

Two defects, both surfaced by Fable's review:
- `cloudStatusLine` renders **outside** the `LimitsContentHeightKey` GeometryReader, so its ~26pt is missing from the height formula. Whenever it shows — which now includes the steady "No active cloud sessions" state — the fixed-size window is ~26pt short and clips its last row.
- The window is capped at `min(contentHeight, 30 × 9 = 270pt)` with `minSize == maxSize` and clipped content. Cloud rows bypass `RunwayOverflowRule` (injected after folding), so N cloud sessions add N unfoldable lines. Both providers at full runway plus several cloud rows exceeds 270pt and the bottom is silently cut.

- [ ] **Step 1:** Move `cloudStatusLine` inside the measured region, or add its height to the formula. Verify by toggling the line on/off and confirming no row is cut.
- [ ] **Step 2:** Decide the overflow policy — recommended: cap injected cloud rows (e.g. 3) and append a "+N cloud" line, mirroring `RunwayOverflowRule` rather than inventing a second idiom.
- [ ] **Step 3:** Commit. **Never let truncation be silent** — if rows are dropped, say how many.

---

## Task 6: Decouple cloud rows from Claude usage tracking

**Files:**
- Modify: `AgentSessions/Views/AgentCockpitHUDView.swift:3510` (`entries`) or the Settings toggle

The `.claude` provider entry gates on `claudeAgentEnabled && claudeUsageEnabled`; no entry means `runwayBlock(for: .claude)` never renders, so the injection point never executes. A user can enable cloud sessions with Claude usage tracking off and get **nothing**, while `cloudStatusLine` cheerfully reports "2 active cloud sessions" — pointing at rows that cannot render.

- [ ] **Step 1:** Pick one and make it explicit:
  (a) render a Claude entry when cloud sessions exist even if usage tracking is off, or
  (b) gate the cloud toggle and status line on `claudeUsageEnabled`, with subtext saying so.
  (a) is better for the user; (b) is a two-line change. Do not leave the contradiction.
- [ ] **Step 2:** Test the chosen invariant: status line must never claim rows that cannot render.
- [ ] **Step 3:** Commit.

---

## Task 7: Fix the "+N sessions" grouping lie

**Files:**
- Modify: `AgentSessions/Views/AgentCockpitHUDView.swift` (`HUDRunwayPanel` body, ~:3956)

Cloud rows are appended into `snapshot.rows`, so a local overflow summary ("+2 sessions", counting hidden *local* burns) now renders directly beneath the Cloud rows and reads as though it summarises them. Cosmetic but actively misleading.

- [ ] Render the summary before the injected cloud rows, or label it. Commit.

---

## Task 8: Decide the leftovers

- [ ] **Heartbeat file** (`ClaudeCloudLiveModel.note()` → `cloud-debug.json`): DEBUG-only and test-guarded. It is the only working instrument in this app — recommend keeping, but the owner should decide explicitly rather than by default.
- [ ] **Verify the `bridge` assumption.** The filter excludes 168 `environment_kind == "bridge"` sessions on the assumption the local indexer already shows them. **This was never checked.** Confirm a bridge session appears locally; if it does not, those sessions are invisible everywhere and the filter is wrong.
- [ ] **Amend two commit messages.** `a2e0e027` and `e78093ef` describe fixes for symptoms that were not occurring (the feature was switched off at the time). The code changes stand; the rationale is wrong. Amend while unpushed, or leave a corrective note.

---

## Self-review notes

**Ordering.** Task 1 is the highest value and lowest risk — do it first. Task 4 depends on Task 1 landing (otherwise the honest label describes a state that should not exist). Track B is independent of Track A throughout.

**Testing gap to respect.** `refreshTickMenuBackground` has no test coverage, so the suite cannot validate Task 1. Its Step 5 runtime check is the real gate; do not substitute a green suite for it.

**What this plan does not do.** It does not add Codex CLI-independent usage as a general capability, revisit the 30s cloud poll interval, or address transcript access for cloud sessions — all deliberately out of scope.
