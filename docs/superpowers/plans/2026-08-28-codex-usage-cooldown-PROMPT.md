# Session prompt — Codex usage cooldown lockout

Paste everything below the line into a fresh session.

---

You are fixing the **Codex usage transient-failure cooldown lockout** in Agent Sessions.
Repo: `/Users/alexm/Repository/Codex-History`. Read `agents.md` first, then the backlog
entry "Transient-failure cooldowns lock out both live sources with no reachable bypass"
in `docs/backlog.md` (under *Codex Usage Meter*).

**The owner expects full automated verification from you.** This task has been deferred
three times specifically because the code change is small and the test burden is not. If
you ship the code without the suite, you have not done the task. Do not ask the owner to
manually verify what you can seed and assert yourself.

## Hard rules

- **Never commit or push unless the owner says so in chat.** You may advise it.
- Conventional Commits, with `Tool:` / `Model:` / `Why:` trailers. No "Generated with"
  footer, no `Co-Authored-By`. All commits are authored by the repo owner.
- Do not create branches or worktrees without asking.
- Serialize builds. Another session may be building into `.deriveddata-tests`; check
  `pgrep -f "Developer/usr/bin/xcodebuild"` and wait rather than colliding, or you will
  get "database is locked" and a stale test bundle.
- User-visible changes need a `[Unreleased]` bullet in `docs/CHANGELOG.md` and a note in
  `docs/summaries/2026-08.md` (see `agents.md` → User-visible changes).
- Every claim you make needs evidence — file:line or exact output. The backlog line
  numbers below were re-verified on 2026-08-28; **re-verify before trusting them**, since
  several in the original entry had already drifted.

## The defect

After a failed usage fetch the app sets a cooldown before it will try that source again.
There are three gates, all verified 2026-08-28:

- `CodexOAuthUsageFetcher.fetchUsage` — declared :115, gate at
  [:128](../../../AgentSessions/CodexStatus/CodexOAuth/CodexOAuthUsageFetcher.swift:128).
  `cooldownFailure` defaults to **30 minutes**.
- `CodexOAuthUsageFetcher.fetchUsageResult` — declared :166, gate at
  [:179](../../../AgentSessions/CodexStatus/CodexOAuth/CodexOAuthUsageFetcher.swift:179).
  The live polling path. Same 30 minutes, **shared actor state** with the above.
- `CodexCLIRPCProbe.fetchRateLimits` — declared :46, gate at
  [:52](../../../AgentSessions/CodexStatus/CodexCLIRPCProbe.swift:52).
  `cooldownFailure` defaults to **60 minutes**.

So one offline launch or one network blip locks out both authoritative sources — the RPC
probe for a full hour — while the ~3-minute poll keeps being rejected by the gate.

**The bypass that exists does not cover this case.** `resetForUserRecheck()`
([CodexOAuthUsageFetcher.swift:95](../../../AgentSessions/CodexStatus/CodexOAuth/CodexOAuthUsageFetcher.swift:95))
clears `lastFetchAt` / `lastFetchFailed` / `rateLimitedUntil`, and is reached through
`recheckAuthNow`. But it sits behind `AuthRemediationBanner`, which only replaces the meter
when the auth verdict is *alarming*. A transient network failure is not alarming, so the
user gets `FooterRetryChip`
([CockpitFooterView.swift:390](../../../AgentSessions/Views/CockpitFooterView.swift:390)) —
a spinning "Codex — reconnecting…" with **no Button and no gesture**. The one control a
user would reach for, Preferences → Usage → "Refresh now"
([PreferencesView+Usage.swift:77](../../../AgentSessions/Views/Preferences/PreferencesView+Usage.swift:77)),
routes through `refreshNow` straight back into the gate.

**And the recovery path only half-clears.** `recheckAuthNow` calls `resetForUserRecheck()`
on the OAuth fetcher but passes the RPC probe merely `cooldownSuccess: 0`
([CodexStatusService.swift:2169](../../../AgentSessions/CodexStatus/CodexStatusService.swift:2169)).
`lastProbeFailed` stays set, so the 60-minute *failure* cooldown still rejects it.
`CodexCLIRPCProbe` has no `resetForUserRecheck` equivalent. The recovery attempt therefore
cannot recover the source with the longer lockout.

**Silent auto-recovery does not apply.** `shouldSilentlyRecheckAuth`
([CodexStatusService.swift:779](../../../AgentSessions/CodexStatus/CodexStatusService.swift:779))
fires only on `.unauthorized`, never on `.transient` — correctly, since hammering a dead
network is pointless. Do not "fix" that.

## Do not overstate the severity

The JSONL fallback still runs (local `rate_limits` from `~/.codex/sessions`, no network, no
cooldown, honestly labelled as a fallback), so the meter usually still shows something and
**never shows a wrong number**. All retry state is in-memory actor vars with no
`UserDefaults` persistence, so quit-and-reopen clears it instantly. This is recovery
latency, not a correctness bug. Write the changelog entry accordingly — do not claim users
were shown wrong data.

## Fix shape

1. Give `CodexCLIRPCProbe` a `resetForUserRecheck()` and call it beside the OAuth one in
   `recheckAuthNow`.
2. Make the retry chip's recovery action reachable during transient failures — the user
   needs *some* control when the chip is showing.
3. Give `refreshNow` a user-initiated flag that bypasses the failure gate. Both
   `refreshNow`s matter: `CodexStatusService.refreshNow` at :330 and the one at :2147 —
   check which the Preferences button actually reaches before changing either.
4. Fold in the `.idle` mislabelling entry below it in the backlog ("`.idle` can mislabel a
   cold-start transient failure"). It shares this code path and the backlog says to do them
   together. `QuotaData.codex(from:)`
   ([CockpitFooterView.swift:159](../../../AgentSessions/Views/CockpitFooterView.swift:159))
   passes neither `dataIsStale` nor `transientReason`, unlike `claude(from:)` — that
   asymmetry is the reason the reason never reaches the UI.
5. NWPathMonitor reset on network-path change is a nice-to-have, not required. Skip it
   unless the rest lands cleanly.

## The test burden — this is the actual task

Cover all of these:

- **Both cooldown clocks independently.** 30-minute OAuth and 60-minute RPC. Assert that a
  failure sets each, that the gate rejects inside the window, and that a user-initiated
  refresh bypasses it.
- **The OAuth/RPC fallthrough order**, including the case where OAuth is cooled down and
  RPC is not, and the reverse.
- **The reachable-vs-alarming branch** that decides whether the user sees
  `AuthRemediationBanner` or `FooterRetryChip`. Assert as a pure function of the auth
  verdict; do not drive the UI to find out.
- **The `.idle` interaction** — a cold launch with a transient first fetch must not read
  "No active Codex session".
- **`recheckAuthNow` now clears both sources**, which is the regression test for the
  half-clearing bug.

### Seams: less is missing than the backlog implies

Verified 2026-08-28:

- Cooldown durations are **already injectable** — both `fetchUsage`/`fetchUsageResult` and
  `fetchRateLimits` take `cooldownSuccess`/`cooldownFailure` as parameters with defaults.
  You do not need to wait out real time in any test.
- The OAuth half **already has** `seedRetryStateForTesting(lastFetchAt:failed:rateLimitedUntil:)`
  at :103 and `retryStateForTesting()` at :109.
- `CodexCLIRPCProbe` is the gap: `lastProbeFailed` is a `private var`
  ([:21](../../../AgentSessions/CodexStatus/CodexCLIRPCProbe.swift:21)) with no seed and no
  reset. Add both. The reset is part of the fix anyway (item 1 above), so you are only
  adding the seed for tests.

### The one thing you cannot automate

You cannot prove the real-world path — actually losing the network in a running app and
watching the chip become reachable. Get as close as possible without it:

- Assert the chip-selection branch as a pure function (above).
- Render the footer states to PNG with `ImageRenderer` in a throwaway test to check the
  visual branch. **Do not use computer-use or drive the owner's app**; that is a standing
  repo rule. Note that `ImageRenderer` cannot draw `.buttonStyle(.link)`, so if the new
  control uses that style, assert its presence structurally instead.

State this limitation plainly in your final report rather than implying end-to-end proof.
If the owner wants the last mile, they pull their wifi once and look — but everything else
is yours.

## Definition of done

- All three gates behave correctly under seeded state, proven by tests that run in CI.
- `recheckAuthNow` clears both sources; regression test present.
- A user hitting a transient failure has a reachable control, and using it actually
  refetches.
- `.idle` no longer mislabels a transient cold start.
- Full suite green — `AgentSessionsTests` and `AgentSessionsLogicTests`, both targets, with
  the counts quoted in your report.
- `docs/CHANGELOG.md` `[Unreleased]` and `docs/summaries/2026-08.md` updated.
- The backlog entry collapsed to a tombstone (date, commit, test name) per the rules at the
  top of `docs/backlog.md`, and the `.idle` entry closed with it if you folded it in.
