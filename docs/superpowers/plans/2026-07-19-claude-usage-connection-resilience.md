# Claude Usage Connection Resilience Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Recover the Claude usage meter in seconds instead of minutes after 429/401 episodes, and replace the anonymous infinite "reconnecting…" spinner with the honest cause the manager already knows.

**Architecture:** Three surgical changes to `ClaudeUsageSourceManager`'s failure paths (immediate 401 retry with a freshly re-read Keychain token; web-API fallback during rate-limit windows even when a cache exists), one presentation change (`QuotaData` exposes a compact reason caption that every reconnecting render site displays), and one process-hygiene fix (the socketless-orphan tmux sweep provably runs and kills multi-day leaked probes). Decision logic is added as pure static helpers so it is unit-testable without subprocesses or network, matching the existing `shouldEscalateExpired` / `orphanSweepAction` pattern.

**Tech Stack:** Swift / SwiftUI, XCTest, os_log.

## Background (diagnosed 2026-07-19)

- `api.anthropic.com/api/oauth/usage` edge-rate-limits with Retry-After up to ~47 min. During a 429 with any cached snapshot, the manager marks it `.stale` and *waits* — the claude.ai web fallback (which had fresh data the whole time) is only activated when there is **no** cache ([ClaudeUsageSourceManager.swift:597-628](../../../AgentSessions/ClaudeStatus/ClaudeOAuth/ClaudeUsageSourceManager.swift)).
- The resolver caches the Keychain token (~10 min). When the CLI refreshes the Keychain meanwhile, the next fetch 401s with the *old cached copy*, delegated refresh reports "no credential change" (the CLI already refreshed), and the manager credential-gates for minutes while a valid token sits one Keychain read away.
- `transientReason` ("Rate limited — retrying shortly") is rendered **nowhere** — it only forces `presentationState == .reconnecting`, so every transient collapses into the same unexplained spinner.
- A tmux probe orphan (`tmux -L as-cc-… new-session … claude --model sonnet`, PPID 1, socket file deleted) survived 3+ days across many launches even though `ClaudeStatusService.cleanupOrphansOnLaunch()` is wired at [AgentSessionsApp.swift:842](../../../AgentSessions/AgentSessionsApp.swift) and `terminateSocketlessProbeServers` exists for exactly this case.

## Global Constraints

- Conventional Commits with `Tool: Claude Code` / `Model: Fable 5` / `Why: …` trailers; NO "Generated with" footer, NO Claude co-author.
- Commit only the paths named in each task (`git commit -- <paths>`).
- New Swift files must be registered via `scripts/xcode_add_file.rb <path>` (watch for the duplicate-ref gotcha: run it once, verify with `git diff AgentSessions.xcodeproj`).
- Tests run centrally: `xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "$PWD/.deriveddata-tests" -parallel-testing-enabled NO test` (subagents must NOT run xcodebuild; the orchestrator runs one central verification).
- Never `open` an app bundle from `.deriveddata-tests`; manual-run builds go to `.deriveddata-manual`.
- UI copy: lowercase compact captions in QM cells (match existing "reconnecting…" style); no new colors or layout changes.

---

### Task 1: Immediate 401 retry with a freshly re-read Keychain token

**Files:**
- Modify: `AgentSessions/ClaudeStatus/ClaudeOAuth/ClaudeUsageSourceManager.swift` (catch-unauthorized block ~line 555; success-reset block ~line 493; new stored property near `lastDelegatedRefreshAt`)
- Test: `AgentSessionsTests/ClaudeOAuth/ClaudeUsageSourceManagerTests.swift`

**Interfaces:**
- Produces: `static func shouldRetry401WithFreshToken(failedHash: String?, freshHash: String?, alreadyRetriedHash: String?) -> Bool` on `ClaudeUsageSourceManager` (internal, testable).
- Consumes: existing `Self.tokenFingerprint(_:)`, `tokenResolver.invalidateCache()`, `tokenResolver.resolve()`.

- [ ] **Step 1: Write the failing tests**

Append to `ClaudeUsageSourceManagerTests.swift`:

```swift
// MARK: - 401 fresh-token immediate retry (2026-07-19 stale-cached-token race)

func testShouldRetry401_freshTokenDiffers_retries() {
    XCTAssertTrue(ClaudeUsageSourceManager.shouldRetry401WithFreshToken(
        failedHash: "aaaa1111", freshHash: "bbbb2222", alreadyRetriedHash: nil))
}

func testShouldRetry401_sameToken_doesNotRetry() {
    XCTAssertFalse(ClaudeUsageSourceManager.shouldRetry401WithFreshToken(
        failedHash: "aaaa1111", freshHash: "aaaa1111", alreadyRetriedHash: nil))
}

func testShouldRetry401_freshTokenAlreadyRetried_doesNotLoop() {
    // The same "fresh" token must only earn ONE immediate retry per episode,
    // otherwise a token that is new-but-still-invalid retries forever.
    XCTAssertFalse(ClaudeUsageSourceManager.shouldRetry401WithFreshToken(
        failedHash: "aaaa1111", freshHash: "bbbb2222", alreadyRetriedHash: "bbbb2222"))
}

func testShouldRetry401_missingHashes_doesNotRetry() {
    XCTAssertFalse(ClaudeUsageSourceManager.shouldRetry401WithFreshToken(
        failedHash: nil, freshHash: "bbbb2222", alreadyRetriedHash: nil))
    XCTAssertFalse(ClaudeUsageSourceManager.shouldRetry401WithFreshToken(
        failedHash: "aaaa1111", freshHash: nil, alreadyRetriedHash: nil))
}
```

- [ ] **Step 2: Verify the tests fail to compile** (helper doesn't exist yet). Report the compile error; do not run the full suite.

- [ ] **Step 3: Implement the helper and wiring**

In `ClaudeUsageSourceManager.swift`, near the other pure helpers (after `tokenFingerprint`, ~line 244):

```swift
/// One-shot fast path for the stale-cached-token 401 race: the resolver's
/// ~10-min token cache can hand `performOAuthFetch` a copy the CLI has since
/// refreshed in the Keychain. If a *different* token is available after
/// invalidating the cache, retry immediately instead of credential-gating on
/// a token that is already obsolete. `alreadyRetriedHash` caps this at one
/// immediate retry per fresh token so a new-but-still-invalid token cannot
/// spin a retry loop.
static func shouldRetry401WithFreshToken(failedHash: String?,
                                         freshHash: String?,
                                         alreadyRetriedHash: String?) -> Bool {
    guard let failedHash, let freshHash else { return false }
    return freshHash != failedHash && freshHash != alreadyRetriedHash
}
```

Add the stored property next to `lastDelegatedRefreshAt`:

```swift
/// Fingerprint of the fresh token the 401 fast path already retried with,
/// so the same token never earns a second immediate retry. Cleared on any
/// successful fetch.
private var last401ImmediateRetryTokenHash: String?
```

In the `catch ClaudeOAuthUsageClientError.unauthorized` block, immediately after `await tokenResolver.invalidateCache()` (~line 558) and BEFORE the delegated-refresh attempt:

```swift
// Fast path: the CLI may have refreshed the Keychain while we held a
// cached copy. A different token now in the Keychain means the 401 was
// about a token that no longer exists — retry with the fresh one now
// (sub-second) instead of delegating/credential-gating (minutes).
let failedHash = Self.tokenFingerprint(resolved.token)
if let fresh = await tokenResolver.resolve() {
    let freshHash = Self.tokenFingerprint(fresh.token)
    if Self.shouldRetry401WithFreshToken(failedHash: failedHash,
                                         freshHash: freshHash,
                                         alreadyRetriedHash: last401ImmediateRetryTokenHash) {
        last401ImmediateRetryTokenHash = freshHash
        os_log("ClaudeOAuth: Keychain token changed since resolve — retrying 401 immediately with fresh token",
               log: log, type: .info)
        await performOAuthFetch()
        return
    }
}
```

In the success-path reset block (where `first401At = nil` etc., ~line 498) add:

```swift
last401ImmediateRetryTokenHash = nil
```

- [ ] **Step 4: Confirm the new tests compile and the logic is consistent** (helper referenced in exactly one call site; `resolved.token` is the token that 401'd). Do not run xcodebuild — flag Task 6 to verify.

- [ ] **Step 5: Commit**

```bash
git add AgentSessions/ClaudeStatus/ClaudeOAuth/ClaudeUsageSourceManager.swift AgentSessionsTests/ClaudeOAuth/ClaudeUsageSourceManagerTests.swift
git commit -m "fix(usage): retry a Claude 401 immediately when the Keychain holds a fresher token

Tool: Claude Code
Model: Fable 5
Why: the resolver's cached token can 401 after the CLI refreshes the Keychain; delegated refresh then sees 'no change' and credential-gates for minutes while a valid token sits one read away" -- AgentSessions/ClaudeStatus/ClaudeOAuth/ClaudeUsageSourceManager.swift AgentSessionsTests/ClaudeOAuth/ClaudeUsageSourceManagerTests.swift
```

---

### Task 2: Activate the web fallback during rate-limit windows even with a cache

**Files:**
- Modify: `AgentSessions/ClaudeStatus/ClaudeOAuth/ClaudeUsageSourceManager.swift` (rate-limited catch block, ~lines 587-628)
- Test: `AgentSessionsTests/ClaudeOAuth/ClaudeUsageSourceManagerTests.swift`

**Interfaces:**
- Produces: `static func shouldActivateWebFallbackDuringRateLimit(isAutoMode: Bool, webApiEnabled: Bool, usingWebFallback: Bool) -> Bool` on `ClaudeUsageSourceManager`.
- Consumes: existing `usingWebFallback`, `scheduleWebRefresh(delay:)`, and the existing OAuth-recovery path (~line 513) that already deactivates the web fallback on the next successful non-cache OAuth fetch — no change needed there.

- [ ] **Step 1: Write the failing tests**

Append to `ClaudeUsageSourceManagerTests.swift`:

```swift
// MARK: - Web fallback during 429 windows (edge rate limit can last ~47 min)

func testRateLimitWebFallback_autoModeEnabledNotRunning_activates() {
    XCTAssertTrue(ClaudeUsageSourceManager.shouldActivateWebFallbackDuringRateLimit(
        isAutoMode: true, webApiEnabled: true, usingWebFallback: false))
}

func testRateLimitWebFallback_alreadyRunning_doesNotReactivate() {
    XCTAssertFalse(ClaudeUsageSourceManager.shouldActivateWebFallbackDuringRateLimit(
        isAutoMode: true, webApiEnabled: true, usingWebFallback: true))
}

func testRateLimitWebFallback_webDisabled_staysOff() {
    XCTAssertFalse(ClaudeUsageSourceManager.shouldActivateWebFallbackDuringRateLimit(
        isAutoMode: true, webApiEnabled: false, usingWebFallback: false))
}

func testRateLimitWebFallback_nonAutoMode_staysOff() {
    XCTAssertFalse(ClaudeUsageSourceManager.shouldActivateWebFallbackDuringRateLimit(
        isAutoMode: false, webApiEnabled: true, usingWebFallback: false))
}
```

- [ ] **Step 2: Verify the tests fail to compile** (helper doesn't exist yet).

- [ ] **Step 3: Implement the helper and wiring**

Helper, next to the one from Task 1:

```swift
/// During a 429 window the OAuth path is dark for Retry-After (5 min floor,
/// observed up to ~47 min at the edge). Cached data goes stale within
/// minutes; the claude.ai web path is a different endpoint that is NOT
/// covered by the oauth/usage quota, so it should carry the meter through
/// the window whenever it is available — not only when there is no cache.
static func shouldActivateWebFallbackDuringRateLimit(isAutoMode: Bool,
                                                     webApiEnabled: Bool,
                                                     usingWebFallback: Bool) -> Bool {
    isAutoMode && webApiEnabled && !usingWebFallback
}
```

In the `catch ClaudeOAuthUsageClientError.rateLimited(let retryAfter)` block, the first two branches currently publish stale data and only `scheduleOAuthRefresh(delay: delay)`. Add the web-fallback kick to BOTH branches (after `publish(snap)` in the in-memory branch, and after the `os_log` in the persisted-snapshot branch):

```swift
if Self.shouldActivateWebFallbackDuringRateLimit(isAutoMode: mode == .auto,
                                                 webApiEnabled: webApiEnabled,
                                                 usingWebFallback: usingWebFallback) {
    os_log("ClaudeOAuth: rate limited with cache — activating web API fallback for the window",
           log: log, type: .info)
    usingWebFallback = true
    scheduleWebRefresh(delay: 0)
}
```

Leave the existing no-cache `else if mode == .auto && !usingTmuxFallback` branch as is (it already activates web/tmux), and leave the final `else` untouched.

- [ ] **Step 4: Re-read the modified catch block end to end.** Confirm: every branch still ends with `scheduleOAuthRefresh(delay: delay)`, and web recovery/deactivation on OAuth success (~line 513) still applies.

- [ ] **Step 5: Commit**

```bash
git add AgentSessions/ClaudeStatus/ClaudeOAuth/ClaudeUsageSourceManager.swift AgentSessionsTests/ClaudeOAuth/ClaudeUsageSourceManagerTests.swift
git commit -m "fix(usage): keep Claude meter live through 429 windows via the web fallback

Tool: Claude Code
Model: Fable 5
Why: edge rate-limit windows run up to ~47 min; with a cache present the manager previously just served stale data and waited instead of using the unthrottled claude.ai path" -- AgentSessions/ClaudeStatus/ClaudeOAuth/ClaudeUsageSourceManager.swift AgentSessionsTests/ClaudeOAuth/ClaudeUsageSourceManagerTests.swift
```

---

### Task 3: `QuotaData` exposes a compact honest caption for the reconnecting state

**Files:**
- Modify: `AgentSessions/Views/CockpitFooterView.swift` (QuotaData struct, ~line 105-133)
- Create: `AgentSessionsTests/QuotaDataPresentationTests.swift` (register via `scripts/xcode_add_file.rb`)

**Interfaces:**
- Produces: `var reconnectingCaption: String` on `QuotaData` — what every spinner site renders instead of the literal "reconnecting…".
- Consumes: existing `transientReason` (set by the manager: "Rate limited — retrying shortly" / "Temporarily unavailable — retrying" / web-path captions), `dataIsStale`.

- [ ] **Step 1: Write the failing tests**

Create `AgentSessionsTests/QuotaDataPresentationTests.swift`:

```swift
import XCTest
@testable import AgentSessions

final class QuotaDataPresentationTests: XCTestCase {

    private func claudeQuota(transientReason: String?, stale: Bool = false) -> QuotaData {
        // provider/percent/reset fields have no memberwise defaults.
        var q = QuotaData(provider: .claude,
                          fiveHourRemainingPercent: 73,
                          fiveHourResetText: "",
                          weekRemainingPercent: 91,
                          weekResetText: "")
        q.transientReason = transientReason
        q.dataIsStale = stale
        return q
    }

    func testCaption_rateLimited_saysRateLimited() {
        let q = claudeQuota(transientReason: "Rate limited — retrying shortly")
        XCTAssertEqual(q.reconnectingCaption, "rate limited — retrying…")
    }

    func testCaption_transientUnavailable_saysRetrying() {
        let q = claudeQuota(transientReason: "Temporarily unavailable — retrying")
        XCTAssertEqual(q.reconnectingCaption, "retrying…")
    }

    func testCaption_noReason_fallsBackToReconnecting() {
        XCTAssertEqual(claudeQuota(transientReason: nil).reconnectingCaption, "reconnecting…")
        XCTAssertEqual(claudeQuota(transientReason: "").reconnectingCaption, "reconnecting…")
    }

    func testCaption_unrecognizedReason_fallsBackToReconnecting() {
        // Unknown manager captions must never leak raw sentence-case prose
        // into the compact QM cell.
        let q = claudeQuota(transientReason: "Some future caption we have not mapped")
        XCTAssertEqual(q.reconnectingCaption, "reconnecting…")
    }
}
```

- [ ] **Step 2: Verify the tests fail to compile** (`reconnectingCaption` doesn't exist).

- [ ] **Step 3: Implement**

In `CockpitFooterView.swift`, inside `QuotaData` after `presentationState`:

```swift
/// Compact, honest caption for the reconnecting cell. The manager already
/// knows WHY the meter is dark (`transientReason`); the spinner previously
/// discarded it, which read as a never-ending mystery reconnect during
/// multi-minute 429 windows. Contains-matching keeps this resilient to
/// minor copy edits in the manager constants; anything unrecognized falls
/// back to the generic caption rather than leaking prose into the cell.
var reconnectingCaption: String {
    guard let reason = transientReason?.lowercased(), !reason.isEmpty else {
        return "reconnecting…"
    }
    if reason.contains("rate limit") { return "rate limited — retrying…" }
    if reason.contains("unavailable") { return "retrying…" }
    return "reconnecting…"
}
```

- [ ] **Step 4: Register the new test file**

Run: `ruby scripts/xcode_add_file.rb AgentSessionsTests/QuotaDataPresentationTests.swift`
Then: `git diff AgentSessions.xcodeproj` — verify exactly ONE new file reference was added (duplicate-ref gotcha).

- [ ] **Step 5: Commit**

```bash
git add AgentSessions/Views/CockpitFooterView.swift AgentSessionsTests/QuotaDataPresentationTests.swift AgentSessions.xcodeproj
git commit -m "feat(usage): QuotaData maps transient reasons to a compact reconnect caption

Tool: Claude Code
Model: Fable 5
Why: the manager publishes why the meter is dark (rate limited / retrying) but every surface discarded it and showed an anonymous spinner" -- AgentSessions/Views/CockpitFooterView.swift AgentSessionsTests/QuotaDataPresentationTests.swift AgentSessions.xcodeproj
```

---

### Task 4: Render the caption at every reconnecting site (QM, menu bar, footer)

**Files:**
- Modify: `AgentSessions/Views/AgentCockpitHUDView.swift` (`HUDLimitsRetryCell` ~line 5853; call sites ~lines 4665, 5029, 5756)
- Modify: `AgentSessions/MenuBar/StatusItemController.swift` (`claudeResetLine` ~line 544)
- Modify: `AgentSessions/MenuBar/UsageMenuBar.swift` (`.reconnecting` case ~line 295 — dropdown/face cell)
- Modify: `AgentSessions/Views/CockpitFooterView.swift` (`FooterRetryChip` ~line 354 and its call site ~line 231)

No new tests (pure view plumbing over the Task 3 tested mapping); owner visual QA in Task 6.

- [ ] **Step 1: Give `HUDLimitsRetryCell` a caption parameter**

```swift
private struct HUDLimitsRetryCell: View {
    let source: UsageTrackingSource
    var enlarged: Bool = false
    var caption: String = "reconnecting…"

    var body: some View {
        HStack(spacing: 8) {
            HUDLimitsProviderIcon(source: source)
            HUDLimitsLoadingSpinner()
            Text(caption)
                .font(.system(size: QuotaMeterTextMetrics.providerFontSize(enlarged: enlarged), weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}
```

At each of the three call sites, pass the caption from the same `QuotaData` value whose `presentationState` the surrounding `switch` matched `.reconnecting` on (the switch subject — e.g. `entry.quota` or the local the site already binds; read the enclosing code and use that exact value):

```swift
HUDLimitsRetryCell(source: entry.source, enlarged: quotaMeterEnlarged, caption: quota.reconnectingCaption)
// and at the two compact sites:
HUDLimitsRetryCell(source: entry.source, caption: quota.reconnectingCaption)
```

- [ ] **Step 2: Menu-bar dropdown line (`StatusItemController.claudeResetLine`)**

```swift
switch QuotaData.claude(from: claudeStatus).presentationState {
case .needsAction:
    return "\(label) --  Usage unavailable"
case .idle:
    return "\(label) --  No active session"
case .reconnecting:
    return "\(label) --  \(QuotaData.claude(from: claudeStatus).reconnectingCaption)"
case .live:
    return resetLine(label: label, percent: percent, reset: reset)
}
```

(Hoist `QuotaData.claude(from: claudeStatus)` into a `let quota` above the switch and use it for both the switch and the caption.)

- [ ] **Step 3: Menu-bar face (`UsageMenuBar.swift` ~line 295)**

The face is width-constrained; keep the glyph + provider name, but append the caption ONLY when it is more specific than the generic one:

```swift
case .reconnecting:
    // Spinning arrows + provider name — the footer's "reconnecting"
    // affordance in a menu-bar-sized form. A specific cause (rate limited)
    // replaces the provider name so the face is honest at a glance.
    HStack(spacing: 3) {
        MenuBarReconnectingGlyph()
        Text(q.reconnectingCaption == "reconnecting…"
             ? (q.provider == .claude ? "Claude" : "Codex")
             : q.reconnectingCaption)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary)
    }
```

- [ ] **Step 4: Footer chip (`FooterRetryChip`)**

The footer has room for the full reason. Change the label line:

```swift
private struct FooterRetryChip: View {
    let provider: QuotaData.Provider
    var caption: String = "reconnecting…"
    @State private var spinning = false
    // body unchanged except:
    Text("\(provider == .claude ? "Claude" : "Codex") — \(caption)")
```

Call site (~line 231): `FooterRetryChip(provider: q.provider, caption: q.reconnectingCaption)`

- [ ] **Step 5: Commit**

```bash
git add AgentSessions/Views/AgentCockpitHUDView.swift AgentSessions/MenuBar/StatusItemController.swift AgentSessions/MenuBar/UsageMenuBar.swift AgentSessions/Views/CockpitFooterView.swift
git commit -m "feat(usage): reconnecting cells show the actual cause (rate limited / retrying)

Tool: Claude Code
Model: Fable 5
Why: multi-minute 429 windows rendered as an unexplained never-ending spinner in the QM, menu bar, and footer" -- AgentSessions/Views/AgentCockpitHUDView.swift AgentSessions/MenuBar/StatusItemController.swift AgentSessions/MenuBar/UsageMenuBar.swift AgentSessions/Views/CockpitFooterView.swift
```

---

### Task 5: Make the socketless-orphan probe sweep testable and provably firing

**Files:**
- Modify: `AgentSessions/Support/ProbeCleanupHelpers.swift`
- Modify: `AgentSessions/ClaudeStatus/ClaudeStatusService.swift` (`cleanupOrphanedProbeProcesses` ~line 599: empty-ps guard + logging)
- Create: `AgentSessionsTests/ProbeCleanupHelpersTests.swift` (register via `scripts/xcode_add_file.rb`)

**Interfaces:**
- Produces: `terminateSocketlessProbeServers(labelPrefix:psOutput:socketExists:killAction:)` — same free function, injectable socket check and kill for tests; production call sites unchanged (defaults preserve behavior).

**Context:** A probe orphan survived 3 days across many launches despite this sweep being wired at launch. The helper's logic looks correct for the observed ps line, so the suspect is the pipeline around it: `cleanupOrphanedProbeProcesses` silently skips the socketless sweep whenever the 2-second `ps -A` snapshot times out (empty stdout → early return at ~line 605), and nothing logs that it ran at all.

- [ ] **Step 1: Write the failing tests**

Create `AgentSessionsTests/ProbeCleanupHelpersTests.swift`:

```swift
import XCTest
@testable import AgentSessions

final class ProbeCleanupHelpersTests: XCTestCase {

    // The exact ps line shape of the real 3-day orphan observed 2026-07-19.
    private let orphanLine = "46300 /opt/homebrew/bin/tmux -L as-cc-uWZOFrvx8vv3 new-session -d -s usage cd '/Users/alexm/Library/Application Support/AgentSessions/ClaudeProbeProject' && env TERM=xterm-256color BROWSER=/usr/bin/true '/Users/alexm/.local/bin/claude' --model sonnet"

    func testSocketlessOrphan_isKilled() {
        var killed: [pid_t] = []
        terminateSocketlessProbeServers(labelPrefix: "as-cc-",
                                        psOutput: orphanLine,
                                        socketExists: { _ in false },
                                        killAction: { killed.append($0) })
        XCTAssertEqual(killed, [46300])
    }

    func testLiveSocketServer_isSpared() {
        var killed: [pid_t] = []
        terminateSocketlessProbeServers(labelPrefix: "as-cc-",
                                        psOutput: orphanLine,
                                        socketExists: { label in label == "as-cc-uWZOFrvx8vv3" },
                                        killAction: { killed.append($0) })
        XCTAssertTrue(killed.isEmpty)
    }

    func testForeignTmuxServer_isIgnored() {
        var killed: [pid_t] = []
        terminateSocketlessProbeServers(labelPrefix: "as-cc-",
                                        psOutput: "999 /opt/homebrew/bin/tmux -L someone-else new-session -d",
                                        socketExists: { _ in false },
                                        killAction: { killed.append($0) })
        XCTAssertTrue(killed.isEmpty)
    }
}
```

- [ ] **Step 2: Verify the tests fail to compile** (current signature has no `socketExists`/`killAction`).

- [ ] **Step 3: Refactor the helper with injectable seams (behavior-preserving defaults)**

```swift
func terminateSocketlessProbeServers(labelPrefix: String,
                                     psOutput: String,
                                     socketExists: ((String) -> Bool)? = nil,
                                     killAction: ((pid_t) -> Void)? = nil) {
    guard !psOutput.isEmpty else { return }
    let uid = getuid()
    let socketDirs = ["/private/tmp/tmux-\(uid)", "/tmp/tmux-\(uid)"]
    let socketCheck = socketExists ?? { label in
        socketDirs.contains { FileManager.default.fileExists(atPath: "\($0)/\(label)") }
    }
    let kill = killAction ?? { pid in _ = Darwin.kill(pid, SIGKILL) }
    for line in psOutput.split(separator: "\n") {
        let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { continue }
        let parts = trimmed.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
        guard parts.count == 2, let tmuxPID = Int32(parts[0]) else { continue }
        let command = String(parts[1])
        guard command.contains("tmux"), command.contains(labelPrefix) else { continue }
        guard let lRange = command.range(of: "-L ") else { continue }
        let afterL = command[lRange.upperBound...]
        let labelEnd = afterL.firstIndex(where: { $0.isWhitespace }) ?? afterL.endIndex
        let label = String(afterL[..<labelEnd])
        guard label.hasPrefix(labelPrefix) else { continue }
        if !socketCheck(label) {
            kill(pid_t(tmuxPID))
        }
    }
}
```

- [ ] **Step 4: Close the silent-skip hole in `cleanupOrphanedProbeProcesses`**

In `ClaudeStatusService.swift` ~line 602: bump the ps timeout from 2 to 5 seconds, and make the empty-snapshot path retry once and log — a timed-out ps must not silently skip the socketless sweep:

```swift
var snapshot = await runProcess(executable: "/bin/ps",
                                arguments: ["-A", "-o", "pid=", "-o", "command="],
                                timeoutSeconds: 5)
if snapshot.stdout.isEmpty {
    os_log("ClaudeStatus: orphan sweep ps snapshot empty — retrying once", log: log, type: .info)
    snapshot = await runProcess(executable: "/bin/ps",
                                arguments: ["-A", "-o", "pid=", "-o", "command="],
                                timeoutSeconds: 5)
}
guard !snapshot.stdout.isEmpty else {
    os_log("ClaudeStatus: orphan sweep skipped — ps snapshot empty twice", log: log, type: .error)
    await cleanupOrphanedTmuxLabels()
    return
}
```

(Keep the existing `let` → adjust to `var`. `log` here is the file's existing OSLog handle — check its actual name at the top of ClaudeStatusService.swift and use that.)

Also add one log after the socketless sweep call (~line 677) so future multi-day leaks are diagnosable:

```swift
terminateSocketlessProbeServers(labelPrefix: Self.probeLabelPrefix,
                               psOutput: snapshot.stdout)
os_log("ClaudeStatus: orphan sweep completed (socketless pass included)", log: log, type: .info)
```

- [ ] **Step 5: Live verification of the real orphan** (orchestrator, not subagent): if `pgrep -f "tmux -L as-cc-"` still shows the July-16 orphan (PIDs 46300/46301), kill it manually with `kill 46300 46301` and confirm gone. After Task 6's build, a relaunch should show the sweep-completed log line.

- [ ] **Step 6: Register the new test file**

Run: `ruby scripts/xcode_add_file.rb AgentSessionsTests/ProbeCleanupHelpersTests.swift`
Then: `git diff AgentSessions.xcodeproj` — one new reference only.

- [ ] **Step 7: Commit**

```bash
git add AgentSessions/Support/ProbeCleanupHelpers.swift AgentSessions/ClaudeStatus/ClaudeStatusService.swift AgentSessionsTests/ProbeCleanupHelpersTests.swift AgentSessions.xcodeproj
git commit -m "fix(probes): socketless orphan sweep is testable and never silently skipped

Tool: Claude Code
Model: Fable 5
Why: a probe orphan survived 3 days because a timed-out ps snapshot silently skipped the socketless sweep and nothing logged that it ran" -- AgentSessions/Support/ProbeCleanupHelpers.swift AgentSessions/ClaudeStatus/ClaudeStatusService.swift AgentSessionsTests/ProbeCleanupHelpersTests.swift AgentSessions.xcodeproj
```

---

### Task 6: Central verification + CHANGELOG

**Files:**
- Modify: `docs/CHANGELOG.md` (Unreleased section)

- [ ] **Step 1: Run the full central test suite** (orchestrator only — subagents never run xcodebuild):

Run: `xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "$PWD/.deriveddata-tests" -parallel-testing-enabled NO test`
Expected: all tests pass, including the new `ClaudeUsageSourceManagerTests` cases, `QuotaDataPresentationTests`, and `ProbeCleanupHelpersTests`.

- [ ] **Step 2: Build a manual-run bundle and hand off for owner visual QA** (do NOT drive the app):

Run: `xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "$PWD/.deriveddata-manual" build`
Then: `killall AgentSessions 2>/dev/null; open .deriveddata-manual/Build/Products/Debug/AgentSessions.app`
Tell the owner what to check: during a Claude usage outage the QM/menu bar/footer should read "rate limited — retrying…" or "retrying…" instead of bare "reconnecting…", and recovery after `claude` refreshes its token should be near-instant instead of minutes.

- [ ] **Step 3: Add CHANGELOG entries under `## [Unreleased]`**

```markdown
### Bug Fixes
- **Claude usage recovers in seconds, not minutes.** When the Claude CLI refreshes its sign-in while Agent Sessions holds an older cached token, the meter now retries immediately with the fresh token instead of waiting out a multi-minute credential check.
- **Rate-limit windows no longer black out the meter.** When Anthropic's usage endpoint rate-limits (windows can run tens of minutes), Agent Sessions now switches to the claude.ai web path to keep live numbers flowing instead of sitting on stale data.
- **The spinner tells you why.** The "reconnecting…" cells in the Quota Meter, menu bar, and footer now say what's actually happening — "rate limited — retrying…" — instead of spinning anonymously.
- **Leaked probe sessions are reaped reliably.** A hidden Claude probe could survive for days if its tmux socket vanished; the launch sweep now retries and logs instead of silently skipping.
```

- [ ] **Step 4: Commit**

```bash
git add docs/CHANGELOG.md
git commit -m "docs(changelog): Claude usage connection resilience fixes

Tool: Claude Code
Model: Fable 5
Why: user-facing summary of the 429/401/spinner/orphan fixes" -- docs/CHANGELOG.md
```

---

## Non-goals (explicitly out of scope)

- Rendering dimmed stale meter numbers during reconnect (caption-only for now; revisit if captions prove insufficient).
- Changing the `.idle` "No active session" copy — Task 1 removes the main misfire path that made it contradict the Runway.
- Any change to retry cadence against the 429 window (the manager already honors Retry-After with a 5-min floor).
- OpenAI/Codex paths.
