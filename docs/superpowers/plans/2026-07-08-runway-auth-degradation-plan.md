# Runway Auth — Cause-Aware Degradation, No-CLI Ladder, Probe Hardening (P2–P4)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** `docs/superpowers/specs/2026-07-08-reauth-and-as-owned-refresh-design.md` (P1 is DONE — commit `84fc9696` + the shipped Phase-1 classifier/banner/notifier stack).

**Goal:** When the OAuth usage path fails, tell the user *why* and *what to do*: transient service/network/429 failures show a calm "temporarily unavailable — retrying" caption and never alarm; only a **persistent, debounced 401** escalates to the `.expired` remediation banner. Desktop-only (no-CLI) users get an honest remediation ladder instead of a dead-end command. The interactive tmux `/usage` probe is hardened so no path can surprise-launch a browser, CLI-fallback data is labeled, and the auto-mode probe becomes explicit opt-in.

**Hard boundary (owner-mandated, spec §1):** Agent Sessions NEVER mints or refreshes its own Claude token. No PKCE, no in-app login, no refresh-token grant *with a token AS read*, no AS-owned Keychain item, no `Remediation.inAppSignIn`. Every task below is presentation, classification, gating, or guidance around tokens the official Claude tooling already minted.

**Delegated refresh is RETAINED (owner-confirmed).** `ClaudeDelegatedTokenRefresh` (spawning the non-interactive, browser-suppressed `claude auth status`) stays exactly as shipped. Per spec §1: *"AS may trigger the official CLI to refresh its own token — a 'delegated refresh' that spawns the non-interactive, browser-suppressed `claude auth status` so Claude Code performs its own refresh-token grant — then re-reads the result. That is the official client refreshing itself... AS itself never runs a refresh grant with a token it read."* The P2 escalation clock (Task 1) starts at the **first 401 that survives delegated refresh**, which is where `handleOAuthFailure` is reached — no change to the delegated-refresh call.

**Architecture (delta over Phase 1):** The source manager keeps two layers deliberately apart: the **internal verdict** (`currentAuthState`) flips to `.expired` on the *first* verified 401-with-token — preserving `shouldSuppressTmuxFallback` and the no-Safari guarantee — while the **published escalation** (availability → banner) is debounced behind a new `first401At` clock. Non-alarming failures ride a new `transientReason` string on `ClaudeServiceAvailability`. The no-CLI remediation ladder becomes CLI-presence-aware via a `cliPresent` parameter on `UsageAuthStatus.make` and a new `Remediation.noCLILadder` case whose **rung 1 is the already-shipped Web API mode** (`ClaudeWebCookieResolver` + the `claudeWebApiEnabled` pref) and **rung 2 is the opt-in guided CLI install**. Probe hardening is script-side (auth-check ordering + `BROWSER` suppression) plus availability emits on the two currently-silent abort paths.

---

## Global Constraints

- **Never mint/refresh (spec §1).** If any task drifts toward PKCE / loopback OAuth / writing tokens / `inAppSignIn`, STOP — it is cancelled work. Token precedence stays: env `CLAUDE_CODE_OAUTH_TOKEN` → Keychain `Claude Code-credentials` → `~/.claude/.credentials.json`. Only endpoint: read-only `GET https://api.anthropic.com/api/oauth/usage`.
- **No live-auth calls anywhere in dev/tests.** All tests are pure/table-driven against static helpers (mirror `isWithinColdStartWindow`, `successPathState`, `shouldReprobe`). `AppRuntime.isRunningTests` guards already stop the runners in test mode — keep it that way. P3 rung-1 wiring (Task 6) reuses the already-shipped web-cookie path with *no new auth surface*; its validation is read-only (resolver reachability + pure remediation-mapping tests).
- **Test target:** app-hosted unit tests go in **`AgentSessionsTests`** with `@testable import AgentSessions`. Do NOT add them to `AgentSessionsLogicTests` (mixing targets broke the build earlier in this project).
- **New Swift files must be registered** (app *and* test files):
  `LANG=en_US.UTF-8 RUBYOPT="-E UTF-8" ruby scripts/xcode_add_file.rb AgentSessions.xcodeproj <target> <path> <group>`
  **Duplicate-ref gotcha:** before running, `grep <FileName>.swift AgentSessions.xcodeproj/project.pbxproj` — if it is already referenced, do NOT run the script again (it creates a duplicate reference that breaks the build). This plan needs exactly **one** new file: `AgentSessionsTests/RunwayAuthDegradationTests.swift`.
- **Builds are centralized.** Implementer subagents write code + tests but do NOT run `xcodebuild`. One central verification per phase (Tasks 5, 10, 15) runs build + full suite in the main session.
  - Build: `xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug build`
  - Test: `xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO test` — **default DerivedData; do NOT pass `-derivedDataPath` for the test action** (custom paths trigger SPM module errors).
- **Commits:** Conventional Commits with `Tool:` / `Model:` / `Why:` trailers only — NO Claude co-author, NO "Generated with" footer. **Never run `git commit`/`git push` without the owner's explicit request** — each "Stage" step stages the task's files (`git add -- <paths>`, verify with `git diff --cached --stat`) and pauses.
- **UI/HIG:** reuse shared spacing tokens and the existing strip/banner idioms per `agents.md`; transient captions are `.caption`/`.secondary` (calm — no red/orange, no icon); no new visual language.
- **Verified command strings:** login = `claude auth login`; status = `claude auth status`. The stale `claude /login` (Swift) and `claude login` (script) strings are fixed in Tasks 2 and 11.

---

## File Structure

**New (target `AgentSessionsTests`):**
- `AgentSessionsTests/RunwayAuthDegradationTests.swift` — all P2/P3 pure-helper tests.

**Modified:**
- `AgentSessions/ClaudeStatus/ClaudeOAuth/ClaudeUsageSourceManager.swift` — `first401At` clock, `shouldEscalateExpired`, `expiredPublication`/`failurePublication` pure helpers, retire `publishCLIAuthRequired()`, 429 transient emit, suppressed-fallback availability emit, opt-in gate.
- `AgentSessions/ClaudeStatus/ClaudeUsageModel.swift` — `ClaudeServiceAvailability.transientReason`, `@Published transientReason`, `@Published currentSource`, `cliPresent` wiring in `applyAvailability`.
- `AgentSessions/ClaudeStatus/ClaudeUsageStripView.swift` — calm transient caption, CLI-fallback source caption, tooltip updates.
- `AgentSessions/Shared/UsageAuthStatus.swift` — `cliPresent` parameter, `Remediation.noCLILadder` (rung-1 Web API + rung-2 guided install), copy fixes.
- `AgentSessions/Shared/Views/AuthRemediationBanner.swift` — render `.noCLILadder` (help alert offering "Enable Web API mode" + "Install CLI", mirrors the tmux-help alert).
- `AgentSessions/ClaudeStatus/ClaudeStatusService.swift` — `authStateForProbeAvailability` pure helper; exit-13/setup emits carry `authState`.
- `AgentSessions/Resources/claude_usage_capture.sh` + `tools/claude_usage_capture.sh` — auth-check ordering, `BROWSER` suppression, hint copy.
- `AgentSessions/Views/Preferences/PreferencesConstants.swift` + `PreferencesView+Usage.swift` — auto-fallback opt-in preference (P4).
- `AgentSessions/MenuBar/StatusItemController.swift`, `AgentSessions/Views/CockpitFooterView.swift` — mirror transient caption / source label (one-liners).
- Extended tests: `AgentSessionsTests/ClaudeUsageModelAuthWiringTests.swift`, `AgentSessionsTests/ClaudeStatusServiceTests.swift`.
- Reuses (no edit): `AgentSessions/ClaudeStatus/ClaudeOAuth/ClaudeWebCookieResolver.swift` + `ClaudeWebUsageClient.swift` + the `claudeWebApiEnabled` pref — the shipped Web API path that becomes no-CLI rung 1.

---

# Phase P2 — Cause-aware degradation

## Task 1: Debounced `.expired` escalation (internal verdict stays immediate)

**Goal:** a single verified 401 no longer raises the banner; the banner rises only when 401s persist past a threshold. The *internal* `currentAuthState` still flips to `.expired` on the first 401 so `shouldSuppressTmuxFallback` keeps protecting against the login-screen hang / browser pop (do NOT weaken this — it is the P1 fix).

**Files:**
- Modify: `AgentSessions/ClaudeStatus/ClaudeOAuth/ClaudeUsageSourceManager.swift` (`classifyAndPublishAuthState(was401:)`, success-path reset block in `performOAuthFetch`)
- Create test: `AgentSessionsTests/RunwayAuthDegradationTests.swift`

**Interfaces (all on `ClaudeUsageSourceManager`):**
```swift
/// Escalation threshold for publishing `.expired`. First verified 401 starts the
/// clock; a later verified 401 at/after the threshold escalates. Owner-tunable.
private static let expiredEscalationThreshold: TimeInterval = 5 * 60
private var first401At: Date?

static func shouldEscalateExpired(first401At: Date?, now: Date,
                                  threshold: TimeInterval) -> Bool

/// Pure publication routing for the verified-401-with-token branch.
/// Pre-escalation: publish NO auth change (nil keeps the current banner state)
/// + the calm transient caption. Post-escalation: publish `.expired`, no caption.
static func expiredPublication(escalated: Bool) -> (authState: UsageAuthState?, reason: String?)

/// Pure publication routing for the classifier branch: alarming verdicts publish
/// as-is (no caption); non-alarming verdicts publish with the calm caption so the
/// strip explains the degradation without alarming.
static func failurePublication(verdict: UsageAuthState) -> (authState: UsageAuthState?, reason: String?)

static let transientUnavailableReason = "Claude usage temporarily unavailable — retrying"
static let rateLimitedReason = "Rate limited — retrying shortly"
```

- [ ] **Step 1: Write the failing tests** in `RunwayAuthDegradationTests.swift` (`import XCTest`, `@testable import AgentSessions`):

```swift
final class RunwayAuthDegradationTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 10_000)

    func testNoFirst401NeverEscalates() {
        XCTAssertFalse(ClaudeUsageSourceManager.shouldEscalateExpired(first401At: nil, now: t0, threshold: 300))
    }
    func testUnderThresholdStaysCalm() {
        XCTAssertFalse(ClaudeUsageSourceManager.shouldEscalateExpired(
            first401At: t0, now: t0.addingTimeInterval(299), threshold: 300))
    }
    func testAtThresholdEscalates() {
        XCTAssertTrue(ClaudeUsageSourceManager.shouldEscalateExpired(
            first401At: t0, now: t0.addingTimeInterval(300), threshold: 300))
    }
    func testExpiredPublicationPreEscalationHidesBannerShowsReason() {
        let p = ClaudeUsageSourceManager.expiredPublication(escalated: false)
        XCTAssertNil(p.authState)                 // nil = "no auth update" — banner untouched
        XCTAssertEqual(p.reason, ClaudeUsageSourceManager.transientUnavailableReason)
    }
    func testExpiredPublicationPostEscalationRaisesBanner() {
        let p = ClaudeUsageSourceManager.expiredPublication(escalated: true)
        XCTAssertEqual(p.authState, .expired)
        XCTAssertNil(p.reason)
    }
    func testFailurePublicationAlarmingVerdictPassesThrough() {
        let p = ClaudeUsageSourceManager.failurePublication(verdict: .signedOut)
        XCTAssertEqual(p.authState, .signedOut); XCTAssertNil(p.reason)
    }
    func testFailurePublicationUnknownCarriesCalmReason() {
        let p = ClaudeUsageSourceManager.failurePublication(verdict: .unknown)
        XCTAssertEqual(p.authState, .unknown)
        XCTAssertEqual(p.reason, ClaudeUsageSourceManager.transientUnavailableReason)
    }
}
```

- [ ] **Step 2: Register the test file** (grep pbxproj first — see Global Constraints):
```bash
LANG=en_US.UTF-8 RUBYOPT="-E UTF-8" ruby scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessionsTests AgentSessionsTests/RunwayAuthDegradationTests.swift AgentSessionsTests
```
Expected (central pass): FAIL — helpers undefined.

- [ ] **Step 3: Implement.** In `classifyAndPublishAuthState(was401:)`, the `was401 && hasToken` branch becomes:
  - `if first401At == nil { first401At = now }`
  - `let escalated = Self.shouldEscalateExpired(first401At: first401At, now: now, threshold: Self.expiredEscalationThreshold)`
  - `state = .expired` (internal, unconditional — `currentAuthState` write and `shouldSuppressTmuxFallback` teardown below are unchanged) and `authClassifier.reset()` as today.
  - The availability emit uses `expiredPublication(escalated:)`: pre-escalation it carries `authState: nil` (+ `transientReason`, Task 3), and the legacy `loginRequired` bool must be `false` pre-escalation (calm means calm). Post-escalation it publishes exactly as today (`authState: .expired`).
  The classifier branch's emit uses `failurePublication(verdict:)` the same way. **Lifecycle:** clear `first401At` in the success-path reset block (next to `oauthFailureCount = 0`) and when the failure path takes the classifier branch (non-401, or token vanished — different cause, classifier debounce owns it).
  Note the I2 generation guard already brackets this function — keep the new state writes inside the guarded region.

- [ ] **Step 4:** Central pass expectation: PASS. Also confirm the existing `ClaudeTmuxSuppressionTests` still pass (internal `.expired` semantics unchanged).

- [ ] **Step 5: Stage (owner commits)** — `feat(claude): debounce published .expired escalation behind first401At clock`.

**Why 5 minutes:** the visible failure-retry cadence is 3 min (`visibleFailureRetryInterval`), so escalation lands on the 3rd consecutive 401 (~6 min) while visible. Hidden surfaces enter credential-watch (no polls), so escalation happens on the first visible poll ≥5 min after the first 401 — acceptable because no banner is visible while hidden. Delegated refresh already ran before the first `handleOAuthFailure`, so a refreshable token never starts the clock.

---

## Task 2: Retire `publishCLIAuthRequired()` (stale command + escalation bypass)

**Goal:** remove the immediate `loginRequired: true` emit with the wrong `claude /login` hint that fires on every 401 and would bypass Task 1's debounce.

**Files:**
- Modify: `AgentSessions/ClaudeStatus/ClaudeOAuth/ClaudeUsageSourceManager.swift` (the `catch ClaudeOAuthUsageClientError.unauthorized` branch calls `handleOAuthFailure(...)` then `publishCLIAuthRequired()` — delete the call and the now-dead private func at the bottom of the file).

- [ ] **Step 1:** Delete the `publishCLIAuthRequired()` call and definition. `classifyAndPublishAuthState` (invoked first inside `handleOAuthFailure`) is now the single 401 publisher.
- [ ] **Step 2:** Grep for regressions: `grep -rn "publishCLIAuthRequired\|claude /login" AgentSessions/` → zero hits after the change. Existing `ClaudeUsageModelAuthWiringTests` still pin the banner mapping.
- [ ] **Step 3: Stage (owner commits)** — `fix(claude): drop immediate loginRequired emit on 401 (stale claude /login hint, bypassed expiry debounce)`.

---

## Task 3: `transientReason` plumbing (availability → model), incl. 429

**Goal:** a non-alarming failure carries a short, machine-clearable reason string to the UI; 429 gets its own calm caption (today the 429 catch publishes no availability at all); any successful fetch clears it silently.

**Files:**
- Modify: `AgentSessions/ClaudeStatus/ClaudeUsageModel.swift` — add `var transientReason: String? = nil` to `ClaudeServiceAvailability` (defaulted → all existing constructions stay valid); add `@Published var transientReason: String?` to `ClaudeUsageModel`; in `applyAvailability` write it **unconditionally** (unlike the `authState`-gated fields) with a change-check (mirror the F7 pattern) so steady polls don't churn `objectWillChange`.
- Modify: `AgentSessions/ClaudeStatus/ClaudeOAuth/ClaudeUsageSourceManager.swift` — thread the `reason` halves of Task 1's publication helpers into the availability emits; in the `catch ClaudeOAuthUsageClientError.rateLimited` branch add one emit: `availabilityHandler?(ClaudeServiceAvailability(cliUnavailable: false, tmuxUnavailable: false, transientReason: Self.rateLimitedReason))` (authState nil → banner untouched). The success-path emit already constructs a fresh availability — its default-nil `transientReason` is the clear signal.
- Test: extend `AgentSessionsTests/ClaudeUsageModelAuthWiringTests.swift` (existing file — no registration).

- [ ] **Step 1: Write the failing tests** (in the wiring tests file, `@MainActor`):
  - `applyAvailability` with `transientReason: "x"` → `model.transientReason == "x"`, `model.authStatus` untouched (authState nil).
  - a subsequent availability with `transientReason: nil` → cleared.
  - an alarming emit (`authState: .expired`, reason nil) → banner up AND `transientReason == nil` (never both).
- [ ] **Step 2:** Implement per Files above. Expected: PASS in central run.
- [ ] **Step 3: Stage (owner commits)** — `feat(claude): calm transientReason channel for non-alarming usage failures (incl. 429)`.

---

## Task 4: Calm caption in strip / menu / Cockpit + tooltip

**Goal:** surface the reason without alarm: secondary-caption text, no icon, no red/orange, auto-clears on the next good fetch.

**Files:**
- Modify: `AgentSessions/ClaudeStatus/ClaudeUsageStripView.swift` — in `metersRow`'s status-text chain, after the `setupRequired` branch and before the "Updated Xm ago" branch: `else if let reason = status.transientReason { Text(reason).font(.caption).foregroundStyle(.secondary) }`. Add the reason line to `makeTooltip()`.
- Modify: `AgentSessions/Views/CockpitFooterView.swift` — where the footer cell shows per-provider status (`FooterAuthCell` handles alarming states), add the same secondary one-liner for a non-nil `transientReason`.
- Modify: `AgentSessions/MenuBar/StatusItemController.swift` — the condensed-banner block (~line 200) already renders alarming states; add the calm one-liner for `transientReason` beneath the Claude meters row (same copy, `.secondaryLabelColor`).

**UI/HIG note:** this is deliberately quieter than the banner — plain `.secondary` caption, existing strip spacing tokens, no new visual language (per `agents.md`). No notification fires (transient states never reach `AuthStatusNotifier` because they are not `isAlarming`).

- [ ] **Step 1:** Implement the three surfaces. No new files.
- [ ] **Step 2:** Manual note for owner QA (batched at Task 15): unplug network / force a 5xx → strip shows "Claude usage temporarily unavailable — retrying" in gray, no banner, no notification; restore network → caption disappears on next poll.
- [ ] **Step 3: Stage (owner commits)** — `feat(ui): calm "temporarily unavailable — retrying" caption in strip, menu bar, Cockpit`.

---

## Task 5: P2 central verification

- [ ] **Step 1:** Build (command in Global Constraints) → BUILD SUCCEEDED.
- [ ] **Step 2:** Full test suite (default DerivedData) → all green, including `RunwayAuthDegradationTests` and the extended wiring tests.
- [ ] **Step 3:** Greps: `grep -rn "claude /login" AgentSessions/` → 0; `grep -rn "publishCLIAuthRequired" AgentSessions/` → 0; confirm `shouldSuppressTmuxFallback` call sites unchanged.
- [ ] **Step 4:** Pause for owner commit of any remaining staged work. P2 is shippable here.

---

# Phase P3 — No-CLI remediation ladder (rung 1 = Web API mode, rung 2 = guided CLI install)

**Owner decision (R10, confirmed):** the no-CLI rung 1 is the **already-shipped Web API path**, NOT a Desktop-refresh hint. The Desktop-refresh idea is rejected (Claude Desktop is Electron with its own encrypted store; claude.ai relogin only refreshes cookies) — so there is no live-auth verification gate. Per spec §5 rung 1: *"Zero-install (Web API mode): 'Sign in at claude.ai, then enable Web API mode.' AS already ships a claude.ai session-cookie path (ClaudeWebCookieResolver + the claudeWebApiEnabled pref) that needs no CLI."*

## Task 6: Rung-1 = Web API mode — reachability validation (no new auth surface)

**Goal:** confirm the shipped Web API path is intact and reachable so rung 1 can point at it, WITHOUT adding any new auth surface or making a live-auth call.

**Files:** none modified — this task is a read-only validation that the wiring the later tasks depend on exists.

- [ ] **Step 1: Confirm the shipped path.** Verify in source that: `ClaudeWebCookieResolver.resolve()` reads the claude.ai session cookie (no CLI, no token mint), `ClaudeWebUsageClient.fetch(sessionKey:)` hits the read-only claude.ai usage endpoint, and `ClaudeUsageSourceManager` already activates `performWebFetch()` when `webApiEnabled` (`UserDefaults.standard.bool(forKey: PreferencesKey.claudeWebApiEnabled)`) and mode is `.webOnly` or the OAuth path fails in `.auto`. Confirm the pref key `PreferencesKey.claudeWebApiEnabled` exists (it does — `Views/Preferences/PreferencesConstants.swift`).
- [ ] **Step 2: Confirm the toggle affordance exists** in `PreferencesView+Usage.swift` (the Web API mode option under the Claude usage-mode picker). Rung 1's button will flip this pref, so it must round-trip through the same key the source manager reads. No new pref, no new endpoint.
- [ ] **Step 3:** Record in the spec (§5 rung 1) that the path is confirmed reachable: `CONFIRMED reachable: ClaudeWebCookieResolver + claudeWebApiEnabled (2026-07-08, source inspection)`. This is inspection only — do NOT drive a live web fetch.

**Constraint:** NO live-auth calls. This task neither resolves a cookie at runtime nor fetches usage — it verifies the code path the rung-1 button targets already ships.

---

## Task 7: CLI-presence-aware remediation ladder in `UsageAuthStatus`

**Goal:** stop prescribing `claude auth login` to users who have no CLI; give no-CLI users the two-rung ladder (rung 1 = enable Web API mode, rung 2 = guided CLI install); drop the cancelled "(coming soon) sign in to Agent Sessions directly" promise. Encode the ladder as data.

**Files:**
- Modify: `AgentSessions/Shared/UsageAuthStatus.swift`
- Test: extend `AgentSessionsTests/RunwayAuthDegradationTests.swift`

**Interfaces:**
```swift
enum Remediation: Equatable {
    case showCommand(String)                                 // CLI present: `claude auth login`
    case openURL(URL)
    case noCLILadder(installCommand: String, docsURL: URL)   // NEW — rung 1 Web API mode + rung 2 guided install
    case none
}
// Extended factory — default preserves every existing call site and the Codex path:
static func make(provider: AuthProvider, state: UsageAuthState, cliPresent: Bool = true) -> UsageAuthStatus
```

Ladder rules (Claude; Codex behavior unchanged via the `cliPresent: true` default):
- `.signedOut`/`.expired`, `cliPresent == true` → `.showCommand("claude auth login")` (unchanged).
- `.signedOut`/`.expired`, `cliPresent == false` → `.noCLILadder(installCommand: <install cmd>, docsURL: <setup docs>)`, detail (both rungs, no Desktop-refresh copy): "Sign in at claude.ai, then enable Web API mode — or install the Claude CLI so Agent Sessions can read usage directly." (Rung 1 first, rung 2 second, matching spec §5.)
- `.cliNotInstalled` → `.noCLILadder(...)`; detail same two-rung copy; drops "(coming soon) sign in to Agent Sessions directly" (cancelled feature — the current shipped copy still promises it).

**Install command:** verify from the official install docs at implementation time (currently `npm install -g @anthropic-ai/claude-code`; docs URL already in this file: `https://docs.claude.com/en/docs/claude-code/setup`). Do not invent; record what the docs say.

- [ ] **Step 1: Write the failing tests** (table-driven, in `RunwayAuthDegradationTests.swift`): `(state, cliPresent) → expected Remediation kind`:
  - `(.signedOut, true)` / `(.expired, true)` → `.showCommand("claude auth login")`.
  - `(.signedOut, false)` / `(.expired, false)` / `(.cliNotInstalled, _)` → `.noCLILadder`.
  - No detail string contains `"coming soon"`; every `.noCLILadder` detail contains both `"claude.ai"` (rung 1) and `"CLI"` (rung 2); no detail mentions "Desktop".
  - Codex compat: `make(provider: .codex, state: .signedOut)` still `.showCommand("codex login")`.
- [ ] **Step 2:** Implement. Expected: PASS (central).
- [ ] **Step 3: Stage (owner commits)** — `feat(usage): no-CLI remediation ladder (rung1 Web API mode, rung2 guided install); drop cancelled in-app sign-in copy`.

---

## Task 8: Render `.noCLILadder` — help alert offering both rungs (mirror the tmux-help alert)

**Goal:** a zero-install-first remediation surface: banner button → alert whose primary action enables Web API mode (rung 1) and whose secondary action guides the CLI install (rung 2). AS toggles a pref and copies a command; it never runs an installer or a login.

**Files:**
- Modify: `AgentSessions/Shared/Views/AuthRemediationBanner.swift`

- [ ] **Step 1:** Add a `case .noCLILadder(let installCommand, let docsURL)` arm to `remediationControl`: a borderless `Button("How to fix…")` toggling a local `@State private var showNoCLIHelp` `.alert` styled like the existing `"tmux not found"` alert in `ClaudeUsageStripView`. Buttons:
  - **"Enable Web API mode"** (rung 1) → `UserDefaults.standard.set(true, forKey: PreferencesKey.claudeWebApiEnabled)` (the same key Task 6 confirmed the source manager reads — no new plumbing).
  - **"Copy CLI install command"** (rung 2) → `NSPasteboard` sets `installCommand` (reuse the `CommandCopyControl` pasteboard pattern).
  - **"Open install guide"** → `NSWorkspace.shared.open(docsURL)`.
  - **"OK"** cancel.
  - Message: "Sign in at claude.ai, then enable Web API mode — no CLI needed. Or install the Claude CLI:  \n\n  \(installCommand)".
- [ ] **Step 2:** Update the `#if DEBUG` preview block with a `.noCLILadder` example.
- [ ] **Step 3:** UI/HIG note: native `.alert` (not a custom sheet) matches the shipped tmux-help idiom; banner spacing/typography untouched; rung 1 listed first (zero-install preferred).
- [ ] **Step 4: Stage (owner commits)** — `feat(ui): no-CLI remediation alert offering Web API mode then guided install`.

---

## Task 9: Wire `cliPresent` into the Claude model

**Goal:** the published `authStatus` picks the right ladder rung automatically.

**Files:**
- Modify: `AgentSessions/ClaudeStatus/ClaudeUsageModel.swift` — in `applyAvailability`, compute `let cliPresent = CLIBinaryPresence.claudeInstalled(overridePath: UserDefaults.standard.string(forKey: ClaudeResumeSettings.Keys.binaryPath))` (deterministic disk check — cheap, main-actor-safe, and the same source `classifyAndPublishAuthState` already uses) and pass it to `UsageAuthStatus.make(provider: .claude, state: state, cliPresent: cliPresent)`.
- Test: extend `AgentSessionsTests/ClaudeUsageModelAuthWiringTests.swift` — pin the mapping via the pure path: assert `UsageAuthStatus.make(provider: .claude, state: .expired, cliPresent: false)` produces `.noCLILadder`, and `cliPresent: true` produces `.showCommand`. (The disk check itself is covered by `CLIBinaryPresenceTests`.)
- [ ] **Step 1:** Failing test → implement → PASS (central).
- [ ] **Step 2: Stage (owner commits)** — `feat(claude): remediation banner selects ladder rung by CLI presence`.

---

## Task 10: P3 central verification

- [ ] **Step 1:** Build + full suite (commands in Global Constraints) → green.
- [ ] **Step 2:** Greps: `grep -rn "coming soon" AgentSessions/` → 0 in auth copy; `grep -rn "inAppSignIn\|PKCE\|loopback" AgentSessions/` → 0 (cancelled-work tripwire); `grep -rn "Desktop" AgentSessions/Shared/UsageAuthStatus.swift` → 0 (rejected rung-1 copy never landed).
- [ ] **Step 3:** Pause for owner commit. P3 shippable.

---

# Phase P4 — Harden the CLI probe

## Task 11: Script hardening — auth check first, browser suppression, correct hint

**Goal:** the interactive probe can never *advance* a login screen or hand the CLI a working browser hook, and its remediation hint matches the verified command.

**Files:**
- Modify: `AgentSessions/Resources/claude_usage_capture.sh` (canonical) and `tools/claude_usage_capture.sh` (keep byte-identical logic; diff after editing).

- [ ] **Step 1: Reorder the boot loop.** Move the auth/login prompt check (`grep -qE '(sign in|login|authentication|unauthorized|Please run.*claude login|Select login method)'` → exit 13) to the **top** of the `while` loop, BEFORE the trust-prompt / theme-selection branches that `send-keys ... Enter`. Today a mis-grep on a login screen can press Enter into "Select login method" and trigger the browser OAuth flow — this ordering closes it.
- [ ] **Step 2: Suppress the browser hook at spawn.** Change the tmux spawn line(s) to `env TERM=xterm-256color BROWSER=/usr/bin/true '$CLAUDE_CMD' --model $MODEL`. Do **NOT** set `CI=1` here (unlike `ClaudeDelegatedTokenRefresh.browserSuppressedEnvironment`, which wraps the non-TUI `claude auth status`) — CI mode can suppress the TUI the probe needs. If the CLI calls `open(2)` directly, `$BROWSER` won't stop it — the reordered exit-13 + the pre-spawn gates remain the primary defense; note the residual risk in the QA checklist.
- [ ] **Step 3: Fix the hint copy** at the exit-13 emit: `'Run: claude login'` → `'Run: claude auth login'`.
- [ ] **Step 4:** No unit test (bash); verified by owner QA (Task 15): a *signed-in* probe still boots and parses; the script edit is inspectable by `diff` between the two copies.
- [ ] **Step 5: Stage (owner commits)** — `fix(claude): probe script checks auth before sending keys; BROWSER suppressed at spawn`.

---

## Task 12: Abort-paths must raise the banner (close the two silent aborts)

**Goal:** spec §6's "abort and show the banner instead of opening Safari". Two paths currently abort silently: (a) `activateTmuxFallback`'s suppression returns (`shouldSuppressTmuxFallback` guard and the authoritative-probe backstop) publish nothing — in `.tmuxOnly` mode a signed-out user gets no probe, no banner, no explanation; (b) a probe exit-13 publishes `loginRequired: true` with `authState: nil`, which `applyAvailability` ignores for the banner (the legacy captions were retired in P1).

**Files:**
- Modify: `AgentSessions/ClaudeStatus/ClaudeOAuth/ClaudeUsageSourceManager.swift` (`activateTmuxFallback`)
- Modify: `AgentSessions/ClaudeStatus/ClaudeStatusService.swift` (`publishAvailability(loginRequired:setupRequired:setupHint:)`)
- Test: extend `AgentSessionsTests/ClaudeStatusServiceTests.swift` (existing — no registration)

**Interfaces:**
```swift
// ClaudeStatusService — pure mapping, unit-tested:
/// exit 13 (login screen observed) is a DEFINITIVE signed-out/needs-reauth signal
/// from the CLI's own TUI; setup prompts map to .needsSetup; otherwise no verdict.
static func authStateForProbeAvailability(loginRequired: Bool, setupRequired: Bool) -> UsageAuthState?
```

- [ ] **Step 1: Failing test** (table): `(true, false) → .signedOut`, `(false, true) → .needsSetup`, `(false, false) → nil`.
- [ ] **Step 2:** `publishAvailability` passes `authState: Self.authStateForProbeAvailability(...)` into the `ClaudeServiceAvailability` it builds — every exit-13/setup emit now raises/clears the banner through the existing `applyAvailability` path (success emits `(false, false)` → nil → banner untouched; the OAuth success `.ok` emit remains the clearer).
- [ ] **Step 3:** In `activateTmuxFallback`, both suppression returns emit availability before returning: the `shouldSuppressTmuxFallback(currentAuthState)` guard emits `authState: currentAuthState`; the authoritative-backstop guard emits `.signedOut` for `cli == .signedOut` and `.cliNotInstalled` for `.cliMissing`. This gives `.tmuxOnly` users the banner instead of silence.
- [ ] **Step 4:** Central pass → PASS.
- [ ] **Step 5: Stage (owner commits)** — `fix(claude): suppressed/aborted probes publish an auth verdict instead of failing silently`.

---

## Task 13: Honest CLI-fallback labeling + hard-probe affordance

**Goal:** users can tell QM data came from the CLI probe vs the OAuth endpoint; the double-click hard probe says what it does.

**Files:**
- Modify: `AgentSessions/ClaudeStatus/ClaudeUsageModel.swift` — `@Published var currentSource: ClaudeUsageSource?`; set in `applyLimitSnapshot` (`s.source`) and in the hard-probe `apply(_:)` path (`.tmuxUsage`).
- Modify: `AgentSessions/ClaudeStatus/ClaudeUsageStripView.swift` — when `status.currentSource == .tmuxUsage`, show a `.caption`/`.secondary` "via CLI probe" text in the status chain (below the alarm branches, above "Updated…"); `makeTooltip()` gains "Data source: CLI /usage probe (fallback)" and the double-click line becomes "Double-click runs a one-off CLI /usage probe".
- Modify: `AgentSessions/Views/CockpitFooterView.swift` + `AgentSessions/MenuBar/StatusItemController.swift` — mirror the same one-line source note next to the Claude meters (reuse the exact string).
- Test: extend `ClaudeUsageModelAuthWiringTests.swift` using the existing `applyLimitSnapshotForTesting(_:)` seam: a snapshot with `source: .tmuxUsage` → `currentSource == .tmuxUsage`; `.oauthEndpoint` → `.oauthEndpoint`.

- [ ] **Step 1:** Failing test → implement → PASS (central).
- [ ] **Step 2:** UI/HIG note: label is metadata, not a warning — `.secondary`, no icon, existing spacing tokens.
- [ ] **Step 3: Stage (owner commits)** — `feat(usage): label CLI-fallback data source in strip, menu bar, Cockpit`.

---

## Task 14: Demote the auto-mode interactive probe to explicit opt-in

**Goal:** spec §9 P4 — in `.auto` mode the interactive tmux `/usage` fallback activates only if the user opted in. `.tmuxOnly` mode (an explicit choice) and the manual double-click hard probe (an explicit action, already double-gated) are unaffected.

**Owner decision (R11, confirmed): default-OFF / opt-in.** Per spec §9 P4: *"the interactive auto-mode fallback becomes default-OFF / opt-in (a pref; release-noted...)."* This is a behavior change for auto-mode users whose OAuth path fails persistently — they lose the last-resort data path unless they flip the toggle, so it MUST be release-noted (flag for the `release-notes` skill in Task 15 Step 4). The default lives in exactly **one** place: the pref's registered default value (`false`) — no scattered literals; the source manager only reads the key.

**Files:**
- Modify: `AgentSessions/Views/Preferences/PreferencesConstants.swift` — `static let claudeTmuxAutoFallbackOptIn = "ClaudeTmuxAutoFallbackOptIn"  // Bool, default false`.
- Modify: `AgentSessions/Views/Preferences/PreferencesView+Usage.swift` — Toggle "Allow CLI probe fallback (runs `claude` in tmux when the OAuth endpoint fails)" next to the existing Claude usage-mode picker, visible when mode == `.auto`.
- Modify: `AgentSessions/ClaudeStatus/ClaudeOAuth/ClaudeUsageSourceManager.swift` — pure gate + wiring:
```swift
/// Auto-mode interactive fallback requires explicit opt-in; tmuxOnly is
/// inherently opted in (the user chose the probe as their mode).
static func tmuxFallbackPermitted(mode: ClaudeUsageMode, optIn: Bool) -> Bool {
    mode == .tmuxOnly || optIn
}
```
  Checked at the top of `activateTmuxFallback` (after the suppression guards so Task 12's banner emits still fire); reads the pref via `UserDefaults.standard.bool(forKey: PreferencesKey.claudeTmuxAutoFallbackOptIn)`.
- Test: extend `RunwayAuthDegradationTests.swift` — table over `(mode, optIn)`: `.tmuxOnly` always true; `.auto`/`.oauthOnly`/`.webOnly` follow `optIn`.

- [ ] **Step 1:** Failing test → implement → PASS (central).
- [ ] **Step 2:** UI/HIG note: standard Toggle in the existing Usage preferences group; helper text in `.caption`/`.secondary` per the pane's current pattern.
- [ ] **Step 3: Stage (owner commits)** — `feat(claude): auto-mode tmux /usage fallback is explicit opt-in`.

---

## Task 15: P4 central verification + owner QA (batched, feature-complete)

- [ ] **Step 1:** Build + full suite (Global Constraints commands; default DerivedData) → green.
- [ ] **Step 2:** Greps: `grep -rn "claude login'" AgentSessions/Resources tools/` → only `claude auth login`; `diff AgentSessions/Resources/claude_usage_capture.sh tools/claude_usage_capture.sh` → logic in sync; `grep -rn "inAppSignIn\|PKCE" AgentSessions/` → 0.
- [ ] **Step 3:** Owner QA checklist (I build; owner runs the app — no CLI `kill`/`open` thrash, no computer-use):
  - Transient: kill network → gray "temporarily unavailable — retrying" caption, NO banner/notification; restore → clears silently.
  - Expiry debounce: (only if a stale token is already at hand — never manufacture one via live auth) first 401 shows the calm caption; banner appears after ~5–6 min of persistent 401s.
  - No-CLI ladder: temporarily point the binary-override pref at a bogus path → banner shows "How to fix…" → alert offering "Enable Web API mode" (rung 1, flips `claudeWebApiEnabled`) + "Copy CLI install command" / "Open install guide" (rung 2); no browser, no login, nothing auto-runs. With claude.ai cookies present, enabling Web API mode restores runway with no CLI.
  - Probe hardening: signed-in `.tmuxOnly` probe still parses usage; **no Safari** at any point; `ls /private/tmp/tmux-$UID/` shows no leaked `as-cc-*` servers.
  - Silent-abort fix: `.tmuxOnly` with CLI signed out → banner (not silence).
  - Source labeling: after a hard probe, strip shows "via CLI probe"; back on OAuth, label goes away.
  - Opt-in: `.auto` mode with opt-in OFF and OAuth forced to fail → no tmux server appears; toggle ON → fallback activates.
- [ ] **Step 4:** Update `CHANGELOG.md` (dev history) + flag for release notes (`release-notes` skill owns user-facing copy): (a) the **default-OFF auto-mode tmux fallback** (R11 — behavior change, MUST be release-noted per spec §9), (b) the new no-CLI **Web API mode remediation**, and (c) the CLI-fallback source labeling. Pause for owner commit/release.

---

## Self-Review (author checklist)

- **Spec coverage:** §1 delegated-refresh RETAINED (owner R1) → Global Constraints boundary; §3/§4 (cause table, threshold, silent recovery) → Tasks 1–4; §5 ladder (rung-1 Web API mode per owner R10, rung-2 guided install) → Tasks 6–9; §6 hardening (no-surprise-browser, labeling, soft probes untouched) → Tasks 11–13; §9 P4 default-OFF/opt-in (owner R11) → Task 14; §1/cancelled-work tripwires → Global Constraints + Tasks 10/15 greps.
- **Owner decisions baked in:** R1 (keep delegated refresh — §1 quote in the boundary block, clock starts post-refresh); R10 (rung-1 = Web API mode via `ClaudeWebCookieResolver` + `claudeWebApiEnabled`, Desktop-refresh rejected — Tasks 6–8 + §5 quote); R11 (auto-fallback default-OFF, release-noted, single-source default — Task 14 + §9 quote).
- **Buildability on real types:** every touched symbol verified in source on 2026-07-08 — `performOAuthFetch` / `handleOAuthFailure` / `classifyAndPublishAuthState(was401:)` / `activateTmuxFallback` / `shouldSuppressTmuxFallback` / `publishCLIAuthRequired` / `ClaudeDelegatedTokenRefresh` (`ClaudeUsageSourceManager.swift` + `ClaudeOAuth/`), `ClaudeServiceAvailability` + `applyAvailability` + `applyLimitSnapshotForTesting` (`ClaudeUsageModel.swift`), `UsageAuthStatus.make` / `Remediation` (`Shared/UsageAuthStatus.swift`), `AuthRemediationBanner` + `CommandCopyControl`, `CLIBinaryPresence.claudeInstalled(overridePath:)`, `ClaudeWebCookieResolver` + `ClaudeWebUsageClient` + `claudeWebApiEnabled` (rung-1 path), `ClaudeStatusService.publishAvailability`, exit-13 grep at `claude_usage_capture.sh:446-451`, `PreferencesKey` in `Views/Preferences/PreferencesConstants.swift`.
- **One new file only** (`RunwayAuthDegradationTests.swift`, test target, registered once with the duplicate-ref pre-grep).
- **No live-auth risk:** all tests pure; Task 6 is source inspection of the shipped web path (no runtime cookie resolve, no web fetch); QA never manufactures a login via the auth server.
