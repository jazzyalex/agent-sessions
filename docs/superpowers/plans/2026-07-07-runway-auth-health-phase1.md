# Runway Auth Health — Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When the Claude/Codex CLI OAuth token dies (or was never installed), Agent Sessions authoritatively detects it, stops hanging on a login-screen tmux probe, and shows a loud, copyable "sign in" remediation with a one-shot notification — instead of silently going blank.

**Architecture:** A shared provider-agnostic `UsageAuthStatus` value is produced by two pure classifiers (Claude, Codex), each preferring an authoritative CLI status check (`claude auth status` / `codex login status`) and falling back to token-resolution with keychain-exit-code discrimination and a debounce so a transient/unreadable read never false-fires. The tmux `/usage` and `/status` fallbacks are short-circuited on signed-out. A shared `AuthRemediationBanner` renders the state; a permission-gated notifier fires once per episode.

**Tech Stack:** Swift 5 / SwiftUI / AppKit, XCTest, macOS app (non-sandboxed), `os_log`. New Swift files registered into the Xcode project via `scripts/xcode_add_file.rb`.

## Global Constraints

- **Verified remediation commands (copy verbatim):** Claude = `claude auth login`; Codex = `codex login`. Authoritative status checks: `claude auth status`; `codex login status` (confirm exact subcommand at Task 5; `codex doctor` is the diagnostic fallback).
- **Never false-alarm:** keychain-unreadable, `security` timeout, or a single missed resolution map to `.unknown`, never `.signedOut`. Only `.signedOut` / `.expired` / `.cliNotInstalled` drive the banner + notification.
- **Do NOT run `git commit` / `git push` without the owner's explicit request.** The "Commit" steps below are stage-points; stage the files and pause for the owner to commit. (Repo rule in `CLAUDE.md` / `agents.md`.)
- **Builds are centralized.** Per repo rule, implementer subagents do NOT each run `xcodebuild`. Write code + tests per task; the single central verification (Task 13) runs the build + full test suite in the main session. Where a task says "run the test," that is executed in the central pass unless you are running inline.
- **New Swift files must be registered:** `ruby scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessions <file> <group>` and, for test files, target `AgentSessionsTests`. See `agents.md` → "Adding New Swift Files to Xcode Project."
- **Commit trailers:** Conventional Commits, no Claude co-author, Tool/Model/Why trailers only.
- **Build:** `xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug build`
- **Test:** `xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath "$PWD/.deriveddata-tests" -parallel-testing-enabled NO clean test`
- Spec: `docs/superpowers/specs/2026-07-07-runway-auth-health-design.md`.

---

## File Structure

**New (target `AgentSessions`):**
- `AgentSessions/Shared/UsageAuthStatus.swift` — the shared enums + struct + copy factory.
- `AgentSessions/Shared/Views/AuthRemediationBanner.swift` — shared banner subview.
- `AgentSessions/Shared/AuthStatusNotifier.swift` — permission-gated one-shot notifier + episode store.
- `AgentSessions/ClaudeStatus/ClaudeAuthClassifier.swift` — Claude classifier (pure).
- `AgentSessions/CodexStatus/CodexAuthClassifier.swift` — Codex classifier (pure).

**New (target `AgentSessionsTests`):**
- `UsageAuthStatusTests.swift`, `ClaudeAuthClassifierTests.swift`, `CodexAuthClassifierTests.swift`, `AuthStatusNotifierTests.swift`, `KeychainResultTests.swift`, `OrphanSweepEscalationTests.swift`.

**Modified:**
- `ClaudeStatus/ClaudeOAuth/ClaudeOAuthTokenResolver.swift` — surface `security` exit code.
- `ClaudeStatus/ClaudeOAuth/ClaudeUsageSourceManager.swift` — guard inside `activateTmuxFallback`, deactivate on signed-out, emit `.ok` on success.
- `ClaudeStatus/ClaudeUsageModel.swift` / `ClaudeUsageStripView.swift` — publish `authStatus`, gate hard probe, render banner.
- `ClaudeStatus/ClaudeStatusService.swift` — orphan-sweep escalation.
- `CodexStatus/CodexOAuth/CodexOAuthCredentials.swift` / `CodexOAuthUsageFetcher.swift` — result-typed returns.
- `CodexStatus/CodexStatusService.swift` — publish `authStatus`, short-circuit tmux `/status`, orphan-sweep escalation.
- `CodexStatus/UsageStripView.swift` + menu-bar dropdown views — render banner.

---

## Task 0: Orphan-sweep escalation (prerequisite bug fix)

Fixes the concrete leak from the incident: multi-day `as-cc-*` tmux servers survive because a live login-screen probe resists `kill-server`, and the retry cap (`tmuxCleanupMaxKillAttemptsPerLabel = 2`, `ClaudeStatusService.swift:100,799`) then skips the label forever. Extract the escalation *decision* as a pure function so it is unit-testable, then wire it.

**Files:**
- Modify: `AgentSessions/ClaudeStatus/ClaudeStatusService.swift` (cleanup routine near `:799-855`, `managedProbePIDs` at `:882`)
- Test: `AgentSessionsTests/OrphanSweepEscalationTests.swift`

**Interfaces:**
- Produces: `enum OrphanSweepAction { case retryKillServer, escalateSIGKILL, giveUp }` and
  `static func orphanSweepAction(isManagedLabel: Bool, attempts: Int, maxAttempts: Int, serverAlive: Bool) -> OrphanSweepAction`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import AgentSessions

final class OrphanSweepEscalationTests: XCTestCase {
    func testManagedLiveServerEscalatesAfterCap() {
        let a = ClaudeStatusService.orphanSweepAction(
            isManagedLabel: true, attempts: 2, maxAttempts: 2, serverAlive: true)
        XCTAssertEqual(a, .escalateSIGKILL)   // was .giveUp before the fix
    }
    func testManagedUnderCapRetries() {
        XCTAssertEqual(
            ClaudeStatusService.orphanSweepAction(isManagedLabel: true, attempts: 1, maxAttempts: 2, serverAlive: true),
            .retryKillServer)
    }
    func testNonManagedRespectsCap() {
        XCTAssertEqual(
            ClaudeStatusService.orphanSweepAction(isManagedLabel: false, attempts: 2, maxAttempts: 2, serverAlive: true),
            .giveUp)
    }
    func testDeadServerNeedsNoAction() {
        XCTAssertEqual(
            ClaudeStatusService.orphanSweepAction(isManagedLabel: true, attempts: 5, maxAttempts: 2, serverAlive: false),
            .giveUp)
    }
}
```

- [ ] **Step 2: Run test to verify it fails** (central pass) — Expected: FAIL, `orphanSweepAction` not defined.

- [ ] **Step 3: Add the pure decision function** in `ClaudeStatusService.swift` (near the cleanup helpers):

```swift
enum OrphanSweepAction: Equatable { case retryKillServer, escalateSIGKILL, giveUp }

/// A managed (`as-cc-`) probe whose server is still alive after the retry cap
/// must be SIGKILLed rather than skipped forever (fixes multi-day orphan leak).
static func orphanSweepAction(isManagedLabel: Bool, attempts: Int,
                              maxAttempts: Int, serverAlive: Bool) -> OrphanSweepAction {
    guard serverAlive else { return .giveUp }
    if attempts < maxAttempts { return .retryKillServer }
    return isManagedLabel ? .escalateSIGKILL : .giveUp
}
```

- [ ] **Step 4: Wire it into the cleanup loop.** At the retry-cap check (`ClaudeStatusService.swift:799-801`), replace the "skip when over cap" branch with a call to `orphanSweepAction(...)`; on `.escalateSIGKILL`, call the existing `managedProbePIDs(for: label)` and `kill(pid, SIGKILL)` path (already present at `:844-855`) for managed labels instead of skipping. Mirror the same change in `CodexStatusService`'s cleanup if it has an independent copy (grep `tmuxCleanupMaxKillAttempts` in that file; if shared, no second edit).

- [ ] **Step 5: Run tests to verify pass** (central pass) — Expected: PASS.

- [ ] **Step 6: Stage (owner commits)** — `git add` the two files; pause. Suggested message: `fix(usage): SIGKILL-escalate live managed tmux probe orphans past retry cap`.

---

## Task 1: Shared `UsageAuthStatus` model + copy

**Files:**
- Create: `AgentSessions/Shared/UsageAuthStatus.swift`
- Test: `AgentSessionsTests/UsageAuthStatusTests.swift`

**Interfaces:**
- Produces: `enum UsageAuthState`, `enum Remediation`, `struct UsageAuthStatus`, and
  `static UsageAuthStatus.make(provider: AuthProvider, state: UsageAuthState) -> UsageAuthStatus`
  where `enum AuthProvider { case claude, codex }`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import AgentSessions

final class UsageAuthStatusTests: XCTestCase {
    func testSignedOutClaudeCopyAndRemediation() {
        let s = UsageAuthStatus.make(provider: .claude, state: .signedOut)
        XCTAssertEqual(s.state, .signedOut)
        XCTAssertEqual(s.remediation, .showCommand("claude auth login"))
        XCTAssertTrue(s.headline.localizedCaseInsensitiveContains("sign in"))
    }
    func testSignedOutCodexCommand() {
        XCTAssertEqual(UsageAuthStatus.make(provider: .codex, state: .signedOut).remediation,
                       .showCommand("codex login"))
    }
    func testOkIsSilent() {
        let s = UsageAuthStatus.make(provider: .codex, state: .ok)
        XCTAssertEqual(s.remediation, .none)
    }
    func testUnknownIsSilent() {
        XCTAssertEqual(UsageAuthStatus.make(provider: .claude, state: .unknown).remediation, .none)
    }
    func testCliNotInstalledOpensURL() {
        if case .openURL = UsageAuthStatus.make(provider: .claude, state: .cliNotInstalled).remediation { }
        else { XCTFail("expected openURL remediation") }
    }
}
```

- [ ] **Step 2: Run test to verify it fails** — Expected: FAIL, types undefined.

- [ ] **Step 3: Create `UsageAuthStatus.swift`**

```swift
import Foundation

enum AuthProvider: Equatable { case claude, codex
    var displayName: String { self == .claude ? "Claude" : "Codex" }
}

enum UsageAuthState: Equatable {
    case ok, signedOut, expired, cliNotInstalled, needsSetup, unknown
    /// States that should raise the loud banner + one-shot notification.
    var isAlarming: Bool {
        switch self { case .signedOut, .expired, .cliNotInstalled: return true
        default: return false }
    }
}

enum Remediation: Equatable {
    case showCommand(String)   // rendered with a Copy button; never auto-run
    case openURL(URL)
    case none
    // Phase 2 adds: case inAppSignIn
}

struct UsageAuthStatus: Equatable {
    var state: UsageAuthState
    var remediation: Remediation
    var headline: String
    var detail: String

    static func make(provider: AuthProvider, state: UsageAuthState) -> UsageAuthStatus {
        let name = provider.displayName
        let loginCmd = provider == .claude ? "claude auth login" : "codex login"
        let installURL = URL(string: provider == .claude
            ? "https://docs.claude.com/en/docs/claude-code/setup"
            : "https://developers.openai.com/codex/cli/")!
        switch state {
        case .ok, .unknown:
            return .init(state: state, remediation: .none, headline: "", detail: "")
        case .signedOut:
            return .init(state: state, remediation: .showCommand(loginCmd),
                headline: "Runway paused — sign in to \(name)",
                detail: "You're signed out of the \(name) CLI. Run the command below, then runway resumes automatically.")
        case .expired:
            return .init(state: state, remediation: .showCommand(loginCmd),
                headline: "Runway paused — \(name) session expired",
                detail: "Your \(name) credentials expired. Run the command below to re-authenticate.")
        case .cliNotInstalled:
            return .init(state: state, remediation: .openURL(installURL),
                headline: "Runway needs an account token",
                detail: "Install the \(name) CLI, or (coming soon) sign in to Agent Sessions directly.")
        case .needsSetup:
            return .init(state: state, remediation: .showCommand(provider == .claude ? "claude" : "codex"),
                headline: "\(name) needs one-time setup",
                detail: "Open Terminal and run the \(name) CLI once to finish setup.")
        }
    }
}
```

- [ ] **Step 4: Register the files & run tests**

```bash
ruby scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessions AgentSessions/Shared/UsageAuthStatus.swift Shared
ruby scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessionsTests AgentSessionsTests/UsageAuthStatusTests.swift AgentSessionsTests
```
Expected (central pass): PASS.

- [ ] **Step 5: Stage (owner commits)** — `feat(usage): shared UsageAuthStatus model + remediation copy`.

---

## Task 2: Keychain read → exit-code result (Claude resolver)

Make "token absent" distinguishable from "keychain unreadable / timed out" so the classifier can honor the never-false-alarm rule.

**Files:**
- Modify: `AgentSessions/ClaudeStatus/ClaudeOAuth/ClaudeOAuthTokenResolver.swift:93-122`
- Test: `AgentSessionsTests/KeychainResultTests.swift`

**Interfaces:**
- Produces: `enum KeychainRead: Equatable { case found(String), notFound, unreadable }` and
  `static ClaudeOAuthTokenResolver.classifyKeychain(exitCode: Int32?, timedOut: Bool, stdout: String?) -> KeychainRead`
  (`errSecItemNotFound` == exit 44).

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import AgentSessions

final class KeychainResultTests: XCTestCase {
    func testExit44IsNotFound() {
        XCTAssertEqual(ClaudeOAuthTokenResolver.classifyKeychain(exitCode: 44, timedOut: false, stdout: ""), .notFound)
    }
    func testTimeoutIsUnreadable() {
        XCTAssertEqual(ClaudeOAuthTokenResolver.classifyKeychain(exitCode: nil, timedOut: true, stdout: nil), .unreadable)
    }
    func testOtherNonZeroIsUnreadable() {
        XCTAssertEqual(ClaudeOAuthTokenResolver.classifyKeychain(exitCode: 51, timedOut: false, stdout: nil), .unreadable)
    }
    func testZeroWithTokenIsFound() {
        XCTAssertEqual(ClaudeOAuthTokenResolver.classifyKeychain(exitCode: 0, timedOut: false, stdout: "sk-ant-oat01-x"),
                       .found("sk-ant-oat01-x"))
    }
    func testZeroEmptyIsNotFound() {
        XCTAssertEqual(ClaudeOAuthTokenResolver.classifyKeychain(exitCode: 0, timedOut: false, stdout: "  "), .notFound)
    }
}
```

- [ ] **Step 2: Run to verify fail** — Expected: FAIL, `classifyKeychain` undefined.

- [ ] **Step 3: Add the classifier + capture the exit code.** Add:

```swift
enum KeychainRead: Equatable { case found(String), notFound, unreadable }

static func classifyKeychain(exitCode: Int32?, timedOut: Bool, stdout: String?) -> KeychainRead {
    if timedOut { return .unreadable }
    switch exitCode {
    case .some(0):
        let t = stdout?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? .notFound : .found(t)
    case .some(44): return .notFound          // errSecItemNotFound
    default: return .unreadable
    }
}
```

Then refactor `runSecurityCommand` (`:93-122`) to return `KeychainRead` instead of `String?`: capture `process.terminationStatus`, pass `timedOut: process.isRunning` (before terminate), route both through `classifyKeychain`. Update the single caller `resolveFromKeychainCLI` (`:88-91`) to map `.found` → token, `.notFound`/`.unreadable` → propagate distinctly (return an enum up, or expose a new `resolveKeychainRead()` the classifier calls in Task 3).

- [ ] **Step 4: Run tests to verify pass** — Expected: PASS.

- [ ] **Step 5: Stage (owner commits)** — `refactor(claude): surface keychain exit code (notFound vs unreadable)`.

---

## Task 3: `ClaudeAuthClassifier` (authoritative + debounced)

**Files:**
- Create: `AgentSessions/ClaudeStatus/ClaudeAuthClassifier.swift`
- Test: `AgentSessionsTests/ClaudeAuthClassifierTests.swift`

**Interfaces:**
- Consumes: `KeychainRead` (Task 2), `UsageAuthState` (Task 1).
- Produces:
  ```swift
  enum CLIAuthStatus: Equatable { case signedIn, signedOut, cliMissing, unknown }  // from `claude auth status`
  struct ClaudeAuthInputs { var cliStatus: CLIAuthStatus; var keychain: KeychainRead; var credsFilePresentToken: Bool; var binaryPresent: Bool }
  ```
  and a stateful `ClaudeAuthClassifier` with
  `func classify(_ inputs: ClaudeAuthInputs, now: Date) -> UsageAuthState` applying the ≥2-over-≥60s debounce for the `signedOut` verdict.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import AgentSessions

final class ClaudeAuthClassifierTests: XCTestCase {
    private func inputs(_ cli: CLIAuthStatus, _ kc: KeychainRead = .notFound,
                       creds: Bool = false, bin: Bool = true) -> ClaudeAuthInputs {
        .init(cliStatus: cli, keychain: kc, credsFilePresentToken: creds, binaryPresent: bin)
    }
    func testAuthoritativeSignedInIsOkImmediately() {
        let c = ClaudeAuthClassifier()
        XCTAssertEqual(c.classify(inputs(.signedIn, .found("t")), now: Date()), .ok)
    }
    func testKeychainUnreadableIsUnknownNotSignedOut() {
        let c = ClaudeAuthClassifier()
        XCTAssertEqual(c.classify(inputs(.unknown, .unreadable), now: Date()), .unknown)
    }
    func testSignedOutRequiresTwoOverSixtySeconds() {
        let c = ClaudeAuthClassifier()
        let t0 = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(c.classify(inputs(.signedOut, .notFound), now: t0), .unknown)          // first miss
        XCTAssertEqual(c.classify(inputs(.signedOut, .notFound), now: t0.addingTimeInterval(30)), .unknown) // <60s
        XCTAssertEqual(c.classify(inputs(.signedOut, .notFound), now: t0.addingTimeInterval(61)), .signedOut)
    }
    func testCliMissingNoTokenIsCliNotInstalled() {
        let c = ClaudeAuthClassifier()
        XCTAssertEqual(c.classify(inputs(.cliMissing, .notFound, creds: false, bin: false), now: Date()),
                       .cliNotInstalled)
    }
    func testRecoveryResetsDebounce() {
        let c = ClaudeAuthClassifier()
        let t0 = Date(timeIntervalSince1970: 2000)
        _ = c.classify(inputs(.signedOut, .notFound), now: t0)
        XCTAssertEqual(c.classify(inputs(.signedIn, .found("t")), now: t0.addingTimeInterval(5)), .ok)
        // A later single miss must again be .unknown, not immediately signedOut.
        XCTAssertEqual(c.classify(inputs(.signedOut, .notFound), now: t0.addingTimeInterval(100)), .unknown)
    }
}
```

- [ ] **Step 2: Run to verify fail** — Expected: FAIL, classifier undefined.

- [ ] **Step 3: Implement `ClaudeAuthClassifier.swift`**

```swift
import Foundation

enum CLIAuthStatus: Equatable { case signedIn, signedOut, cliMissing, unknown }

struct ClaudeAuthInputs {
    var cliStatus: CLIAuthStatus
    var keychain: KeychainRead
    var credsFilePresentToken: Bool
    var binaryPresent: Bool
}

/// Pure, stateful classifier. Debounces the `signedOut` verdict so a transient
/// or unreadable read never false-alarms (spec: ≥2 "absent" resolutions ≥60s apart).
final class ClaudeAuthClassifier {
    private var firstMissAt: Date?
    private static let debounce: TimeInterval = 60

    func classify(_ i: ClaudeAuthInputs, now: Date) -> UsageAuthState {
        // 1. Authoritative CLI status wins when definite.
        switch i.cliStatus {
        case .signedIn: firstMissAt = nil; return .ok
        case .cliMissing:
            let hasToken = i.credsFilePresentToken || { if case .found = i.keychain { return true } else { return false } }()
            return hasToken ? tokenExpiryState(i) : .cliNotInstalled
        case .signedOut: break                 // fall through to debounce
        case .unknown: break                   // rely on token evidence
        }

        // 2. Token evidence.
        switch i.keychain {
        case .found: firstMissAt = nil; return tokenExpiryState(i)
        case .unreadable:
            return i.credsFilePresentToken ? tokenExpiryState(i) : .unknown   // never signedOut on unreadable
        case .notFound:
            if i.credsFilePresentToken { firstMissAt = nil; return tokenExpiryState(i) }
        }

        // 3. Genuinely absent — debounce before alarming.
        guard let first = firstMissAt else { firstMissAt = now; return .unknown }
        if now.timeIntervalSince(first) >= Self.debounce { return .signedOut }
        return .unknown
    }

    /// Token is present; only a verified 401 elsewhere flips this to `.expired`.
    /// Here we default to `.ok`; the source manager overrides with `.expired` on 401.
    private func tokenExpiryState(_ i: ClaudeAuthInputs) -> UsageAuthState { .ok }
}
```

- [ ] **Step 4: Register + run tests**

```bash
ruby scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessions AgentSessions/ClaudeStatus/ClaudeAuthClassifier.swift ClaudeStatus
ruby scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessionsTests AgentSessionsTests/ClaudeAuthClassifierTests.swift AgentSessionsTests
```
Expected: PASS.

- [ ] **Step 5: Stage (owner commits)** — `feat(claude): debounced auth classifier (authoritative + token fallback)`.

---

## Task 4: Result-typed Codex credentials + fetcher

Codex today collapses missing/malformed creds and 401/429/network all into `nil` (`CodexOAuthCredentials.swift:50-70`, `CodexOAuthUsageFetcher.swift:72-115`). Expose the cause so the classifier can see it — additively, keeping existing `nil`-returning entry points intact.

**Files:**
- Modify: `AgentSessions/CodexStatus/CodexOAuth/CodexOAuthCredentials.swift`
- Modify: `AgentSessions/CodexStatus/CodexOAuth/CodexOAuthUsageFetcher.swift`
- Test: (covered by Task 5's classifier tests + a small direct test here)

**Interfaces:**
- Produces:
  ```swift
  enum CodexCredentialRead: Equatable { case present(CodexTokenSet), absent, malformed }
  func CodexOAuthCredentials.resolveRead() -> CodexCredentialRead
  enum CodexUsageFetchResult { case ok(CodexUsageSnapshot), unauthorized, skippedCooldown, transient }
  func CodexOAuthUsageFetcher.fetchUsageResult(cooldownSuccess:cooldownFailure:) async -> CodexUsageFetchResult
  ```
- Consumes: existing `CodexTokenSet` (`CodexOAuthCredentials.swift:12`), `CodexUsageSnapshot`.

- [ ] **Step 1: Write the failing test** (`CodexCredentialReadTests.swift`)

```swift
import XCTest
@testable import AgentSessions

final class CodexCredentialReadTests: XCTestCase {
    func testMissingFileIsAbsent() {
        setenv("AS_TEST_CODEX_AUTH_PATH", "/nonexistent/authXYZ.json", 1)
        XCTAssertEqual(CodexOAuthCredentials().resolveRead(), .absent)
    }
    func testMalformedIsMalformed() throws {
        let p = NSTemporaryDirectory() + "codex-bad-\(UUID().uuidString).json"
        try "{ not json".write(toFile: p, atomically: true, encoding: .utf8)
        setenv("AS_TEST_CODEX_AUTH_PATH", p, 1)
        XCTAssertEqual(CodexOAuthCredentials().resolveRead(), .malformed)
    }
}
```

- [ ] **Step 2: Run to verify fail** — Expected: FAIL.

- [ ] **Step 3: Implement.** In `CodexOAuthCredentials.swift`: add a test-overridable path (`ProcessInfo.processInfo.environment["AS_TEST_CODEX_AUTH_PATH"] ?? Self.authFilePath`), then add:

```swift
enum CodexCredentialRead: Equatable { case present(CodexTokenSet), absent, malformed }

func resolveRead() -> CodexCredentialRead {
    let path = ProcessInfo.processInfo.environment["AS_TEST_CODEX_AUTH_PATH"] ?? Self.authFilePath
    guard let data = FileManager.default.contents(atPath: path) else { return .absent }
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .malformed }
    if let tokens = json["tokens"] as? [String: Any],
       let access = tokens["access_token"] as? String, !access.isEmpty {
        return .present(CodexTokenSet(accessToken: access,
                                      refreshToken: tokens["refresh_token"] as? String,
                                      accountId: (json["account_id"] as? String)))
    }
    if let apiKey = json["OPENAI_API_KEY"] as? String, !apiKey.isEmpty {
        return .present(CodexTokenSet(accessToken: apiKey, refreshToken: nil, accountId: nil))
    }
    return .malformed   // file present, no usable token
}
```
Keep the existing `readFromFile()`/`resolve()` unchanged (delegating to `resolveRead()` is optional — do NOT break current callers).

In `CodexOAuthUsageFetcher.swift`, add `fetchUsageResult(...)` mirroring `fetchUsage` (`:73-116`) but mapping the `catch`/status paths: HTTP 401 → `.unauthorized`; cooldown gate hit → `.skippedCooldown`; network/decode/other → `.transient`; success → `.ok(snap)`. Leave `fetchUsage` as a thin wrapper returning the snapshot for `.ok`, `nil` otherwise, so existing call sites (`CodexStatusService.swift:2058`) are unaffected.

- [ ] **Step 4: Register test + run** — Expected: PASS.

- [ ] **Step 5: Stage (owner commits)** — `refactor(codex): result-typed credentials + usage fetch (expose 401/absent/malformed)`.

---

## Task 5: `CodexAuthClassifier`

**Files:**
- Create: `AgentSessions/CodexStatus/CodexAuthClassifier.swift`
- Test: `AgentSessionsTests/CodexAuthClassifierTests.swift`

**Interfaces:**
- Consumes: `CodexCredentialRead` (Task 4), `CodexUsageFetchResult` (Task 4), `CLIAuthStatus` (Task 3), `UsageAuthState` (Task 1).
- Produces: `final class CodexAuthClassifier { func classify(cliStatus: CLIAuthStatus, creds: CodexCredentialRead, lastFetch: CodexUsageFetchResult?, binaryPresent: Bool, now: Date) -> UsageAuthState }` with the same ≥2/≥60s debounce.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import AgentSessions

final class CodexAuthClassifierTests: XCTestCase {
    func testUnauthorizedFetchIsExpired() {
        let c = CodexAuthClassifier()
        let s = c.classify(cliStatus: .unknown, creds: .present(.init(accessToken: "t", refreshToken: nil, accountId: nil)),
                           lastFetch: .unauthorized, binaryPresent: true, now: Date())
        XCTAssertEqual(s, .expired)
    }
    func testAbsentCredsCliMissingIsCliNotInstalled() {
        let c = CodexAuthClassifier()
        XCTAssertEqual(c.classify(cliStatus: .cliMissing, creds: .absent, lastFetch: nil, binaryPresent: false, now: Date()),
                       .cliNotInstalled)
    }
    func testAbsentCredsDebouncesSignedOut() {
        let c = CodexAuthClassifier()
        let t0 = Date(timeIntervalSince1970: 3000)
        XCTAssertEqual(c.classify(cliStatus: .signedOut, creds: .absent, lastFetch: nil, binaryPresent: true, now: t0), .unknown)
        XCTAssertEqual(c.classify(cliStatus: .signedOut, creds: .absent, lastFetch: nil, binaryPresent: true, now: t0.addingTimeInterval(61)), .signedOut)
    }
    func testTransientFetchWithTokenStaysOk() {
        let c = CodexAuthClassifier()
        XCTAssertEqual(c.classify(cliStatus: .signedIn, creds: .present(.init(accessToken: "t", refreshToken: nil, accountId: nil)),
                                  lastFetch: .transient, binaryPresent: true, now: Date()), .ok)
    }
}
```

- [ ] **Step 2: Run to verify fail** — Expected: FAIL.

- [ ] **Step 3: Implement `CodexAuthClassifier.swift`**

```swift
import Foundation

final class CodexAuthClassifier {
    private var firstMissAt: Date?
    private static let debounce: TimeInterval = 60

    func classify(cliStatus: CLIAuthStatus, creds: CodexCredentialRead,
                  lastFetch: CodexUsageFetchResult?, binaryPresent: Bool, now: Date) -> UsageAuthState {
        // Verified 401 with a token present ⇒ expired (regardless of CLI status).
        if case .present = creds, case .unauthorized? = lastFetch { firstMissAt = nil; return .expired }

        switch cliStatus {
        case .signedIn: firstMissAt = nil; return .ok
        case .cliMissing:
            if case .present = creds { firstMissAt = nil; return .ok }
            return .cliNotInstalled
        case .signedOut, .unknown: break
        }

        switch creds {
        case .present: firstMissAt = nil; return .ok
        case .malformed: return .unknown                 // don't alarm on garbage
        case .absent:
            if !binaryPresent { return .cliNotInstalled }
            guard let first = firstMissAt else { firstMissAt = now; return .unknown }
            return now.timeIntervalSince(first) >= Self.debounce ? .signedOut : .unknown
        }
    }
}
```

- [ ] **Step 4: Confirm the authoritative status command.** Run `codex login status` (and `codex doctor`) to confirm the exact signed-in/out output the CLI-status probe should parse; note it in the classifier's call-site (Task 8/9). If `codex login status` does not exist, use `codex doctor` auth section. Register files + run tests — Expected: PASS.

- [ ] **Step 5: Stage (owner commits)** — `feat(codex): auth classifier (expired/signedOut/cliNotInstalled, debounced)`.

---

## Task 6: Claude — short-circuit tmux, deactivate on signed-out, emit `.ok`

**Files:**
- Modify: `AgentSessions/ClaudeStatus/ClaudeOAuth/ClaudeUsageSourceManager.swift` (`activateTmuxFallback` `:583-607`; success branch `:245-269`)
- Test: extend `ClaudeAuthClassifierTests` or add `SourceManagerShortCircuitTests.swift` (behavioral assert via an injected flag)

**Interfaces:**
- Consumes: the classifier's current `UsageAuthState` (store as `private var currentAuthState: UsageAuthState = .unknown` on the manager, updated wherever the classifier runs).
- Produces: guaranteed no tmux adapter creation while signed-out; `authStatus = .ok` availability emission on OAuth success.

- [ ] **Step 1: Guard inside `activateTmuxFallback`.** At the top of `activateTmuxFallback` (`:583`), before `guard tmuxAdapter == nil`:

```swift
if currentAuthState == .signedOut || currentAuthState == .cliNotInstalled {
    os_log("ClaudeOAuth: suppressing tmux fallback while signed out", log: log, type: .info)
    return
}
```
This covers all five call sites (`:142, 323, 355-359, 379-380, 572-575`) in one place.

- [ ] **Step 2: Deactivate a running adapter on transition to signed-out.** Wherever `currentAuthState` is set to `.signedOut`, add: `if usingTmuxFallback { await deactivateTmuxFallback() }`.

- [ ] **Step 3: Emit recovery.** In the success branch after `publish(snapshot)` (`:267`), add:

```swift
currentAuthState = .ok
availabilityHandler?(ClaudeServiceAvailability(cliUnavailable: false, tmuxUnavailable: false,
                                               loginRequired: false, setupRequired: false, setupHint: nil))
```
This is the missing `.ok` emission that resets `loginRequired` (latent-bug fix) and the notification episode.

- [ ] **Step 4: Behavioral test.** Add a test that sets `currentAuthState = .signedOut` (via a test seam / `@testable` access) and asserts calling the activation path leaves `tmuxAdapter == nil`. Expected: PASS.

- [ ] **Step 5: Stage (owner commits)** — `fix(claude): never spawn tmux /usage probe while signed out; emit recovery`.

---

## Task 7: Claude — gate hard probes on signed-out

**Files:**
- Modify: `AgentSessions/ClaudeStatus/ClaudeUsageStripView.swift:64-74` (double-click), `ClaudeUsageModel.swift:299-354` (`hardProbeNowDiagnostics` / `forceProbeNow` entry), Preferences "probe now" button in `PreferencesView+Usage.swift`.

- [ ] **Step 1:** In `hardProbeNowDiagnostics` (and the Preferences action), add an early guard:

```swift
if model.authStatus?.state == .signedOut || model.authStatus?.state == .cliNotInstalled {
    model.showAuthBanner = true      // surface remediation instead of probing
    return
}
```
(`authStatus` / `showAuthBanner` published in Task 9.)

- [ ] **Step 2:** Manual verification note (UI): with the CLI signed out, double-clicking the strip and clicking Preferences "probe now" must show the banner, not spawn a probe (confirm no new `as-cc-*` server via `ls /private/tmp/tmux-$UID/`).

- [ ] **Step 3: Stage (owner commits)** — `fix(claude): route hard probes to remediation banner when signed out`.

---

## Task 8: Codex — short-circuit the `/status` tmux probe

**Files:**
- Modify: `AgentSessions/CodexStatus/CodexStatusService.swift` (`maybeProbeStatusViaTMUX`, override path `:2180-2199`)
- Test: `CodexStatusShortCircuitTests.swift`

**Interfaces:**
- Consumes: a stored `private var currentAuthState: UsageAuthState` on the service (set where the classifier runs, Task 9).
- Produces: guaranteed no `runCodexStatusViaTMUX()` while signed-out.

- [ ] **Step 1:** At the very start of `maybeProbeStatusViaTMUX` (before the `shouldProbe` guard `:2173`), add:

```swift
if currentAuthState == .signedOut || currentAuthState == .cliNotInstalled {
    os_log("Codex: suppressing tmux /status probe while signed out", log: log, type: .info)
    return
}
```
This closes the `needsProbeOverride` bypass (`:2183-2196`) that spawned the probe precisely in the signed-out end-state.

- [ ] **Step 2:** Extract the guard as a testable static `static func shouldSuppressStatusProbe(_ s: UsageAuthState) -> Bool { s == .signedOut || s == .cliNotInstalled }` and unit-test it (both true, `.ok`/`.unknown` false).

- [ ] **Step 3: Run tests** — Expected: PASS.

- [ ] **Step 4: Stage (owner commits)** — `fix(codex): never spawn tmux /status probe while signed out`.

---

## Task 9: Publish `authStatus` on both models

**Files:**
- Modify: `ClaudeUsageModel.swift` (add `@Published var authStatus: UsageAuthStatus?`, `@Published var showAuthBanner: Bool`; map in the availability handler `:181-191`), `CodexStatusService.swift` (add same to `CodexUsageModel` `:140-171`; run `CodexAuthClassifier` on each poll and set `authStatus`, `currentAuthState`), `ClaudeUsageSourceManager`/`ClaudeStatusService` (run `ClaudeAuthClassifier`, set `currentAuthState`, map `loginRequired/cliUnavailable` → `UsageAuthState`).

**Interfaces:**
- Produces: `ClaudeUsageModel.authStatus`, `CodexUsageModel.authStatus` (both `UsageAuthStatus?`), consumed by the banner (Task 11/12) and hard-probe gate (Task 7).

- [ ] **Step 1:** Add the published properties to both models.
- [ ] **Step 2:** Claude: in the availability handler (`ClaudeUsageModel.swift:181-191`), after mapping the raw flags, derive `authStatus`:

```swift
let state: UsageAuthState =
    availability.loginRequired ? .signedOut :
    availability.cliUnavailable ? .cliNotInstalled :
    availability.setupRequired ? .needsSetup : .ok
model.authStatus = UsageAuthStatus.make(provider: .claude, state: state)
```
(For `.expired`, the source manager sets `currentAuthState = .expired` on a verified 401 and publishes an availability carrying it — extend `ClaudeServiceAvailability` with an optional `authState: UsageAuthState?` if the boolean flags can't express `expired`; map that through here.)

- [ ] **Step 3:** Codex: after each usage poll, call `CodexAuthClassifier.classify(...)` with the authoritative `codex login status` result + `resolveRead()` + last `fetchUsageResult` + binary presence, set `self.currentAuthState` and `model.authStatus = UsageAuthStatus.make(provider: .codex, state: state)` on the main actor.

- [ ] **Step 4:** Verify (central build) the app compiles and both models expose `authStatus`. Manual: force a signed-out state (`mv ~/.codex/auth.json` aside in a scratch copy, or use a test token path) and confirm `authStatus.state == .signedOut` via a temporary `os_log`.

- [ ] **Step 5: Stage (owner commits)** — `feat(usage): publish UsageAuthStatus on Claude + Codex models`.

---

## Task 10: Permission-gated one-shot notifier + episode store

**Files:**
- Create: `AgentSessions/Shared/AuthStatusNotifier.swift`
- Test: `AgentSessionsTests/AuthStatusNotifierTests.swift`

**Interfaces:**
- Produces:
  ```swift
  protocol NotificationGate { func isAuthorized() async -> Bool; func post(title: String, body: String) }
  final class AuthEpisodeStore { func shouldNotify(provider: AuthProvider, state: UsageAuthState) -> Bool; func reset(provider: AuthProvider) }
  final class AuthStatusNotifier { init(gate: NotificationGate, store: AuthEpisodeStore); func onStatus(_ s: UsageAuthStatus, provider: AuthProvider) async }
  ```
  `AuthEpisodeStore` persists a per-provider episode token in `UserDefaults` (`AuthEpisode.claude` / `.codex`); `signedOut` and `expired` share one episode; `.ok`/`.unknown` reset it.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import AgentSessions

final class AuthStatusNotifierTests: XCTestCase {
    final class FakeGate: NotificationGate {
        var authorized = true; private(set) var posts = 0
        func isAuthorized() async -> Bool { authorized }
        func post(title: String, body: String) { posts += 1 }
    }
    private func store() -> AuthEpisodeStore {
        UserDefaults.standard.removeObject(forKey: "AuthEpisode.claude")
        return AuthEpisodeStore()
    }
    func testFiresOncePerEpisode() async {
        let g = FakeGate(); let n = AuthStatusNotifier(gate: g, store: store())
        await n.onStatus(.make(provider: .claude, state: .signedOut), provider: .claude)
        await n.onStatus(.make(provider: .claude, state: .signedOut), provider: .claude)
        XCTAssertEqual(g.posts, 1)
    }
    func testSignedOutThenExpiredShareEpisode() async {
        let g = FakeGate(); let n = AuthStatusNotifier(gate: g, store: store())
        await n.onStatus(.make(provider: .claude, state: .signedOut), provider: .claude)
        await n.onStatus(.make(provider: .claude, state: .expired), provider: .claude)
        XCTAssertEqual(g.posts, 1)
    }
    func testRecoveryThenSignedOutRefires() async {
        let g = FakeGate(); let st = store(); let n = AuthStatusNotifier(gate: g, store: st)
        await n.onStatus(.make(provider: .claude, state: .signedOut), provider: .claude)
        await n.onStatus(.make(provider: .claude, state: .ok), provider: .claude)
        await n.onStatus(.make(provider: .claude, state: .signedOut), provider: .claude)
        XCTAssertEqual(g.posts, 2)
    }
    func testNotAuthorizedNeverPosts() async {
        let g = FakeGate(); g.authorized = false; let n = AuthStatusNotifier(gate: g, store: store())
        await n.onStatus(.make(provider: .claude, state: .signedOut), provider: .claude)
        XCTAssertEqual(g.posts, 0)
    }
    func testUnknownNeverPosts() async {
        let g = FakeGate(); let n = AuthStatusNotifier(gate: g, store: store())
        await n.onStatus(.make(provider: .claude, state: .unknown), provider: .claude)
        XCTAssertEqual(g.posts, 0)
    }
}
```

- [ ] **Step 2: Run to verify fail** — Expected: FAIL.

- [ ] **Step 3: Implement `AuthStatusNotifier.swift`**

```swift
import Foundation
import UserNotifications

protocol NotificationGate { func isAuthorized() async -> Bool; func post(title: String, body: String) }

/// Real gate: checks getNotificationSettings and NEVER calls requestAuthorization.
struct SystemNotificationGate: NotificationGate {
    func isAuthorized() async -> Bool {
        await withCheckedContinuation { cont in
            UNUserNotificationCenter.current().getNotificationSettings { cont.resume(returning: $0.authorizationStatus == .authorized) }
        }
    }
    func post(title: String, body: String) {
        let c = UNMutableNotificationContent(); c.title = title; c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}

final class AuthEpisodeStore {
    private func key(_ p: AuthProvider) -> String { p == .claude ? "AuthEpisode.claude" : "AuthEpisode.codex" }
    /// Returns true exactly once per signed-out/expired episode; resets on ok/unknown.
    func shouldNotify(provider p: AuthProvider, state: UsageAuthState) -> Bool {
        let d = UserDefaults.standard
        switch state {
        case .signedOut, .expired, .cliNotInstalled:
            if d.bool(forKey: key(p)) { return false }   // already notified this episode
            d.set(true, forKey: key(p)); return true
        case .ok, .unknown, .needsSetup:
            d.set(false, forKey: key(p)); return false
        }
    }
    func reset(provider p: AuthProvider) { UserDefaults.standard.set(false, forKey: key(p)) }
}

final class AuthStatusNotifier {
    private let gate: NotificationGate
    private let store: AuthEpisodeStore
    init(gate: NotificationGate = SystemNotificationGate(), store: AuthEpisodeStore = AuthEpisodeStore()) {
        self.gate = gate; self.store = store
    }
    func onStatus(_ s: UsageAuthStatus, provider: AuthProvider) async {
        guard s.state.isAlarming, store.shouldNotify(provider: provider, state: s.state) else { return }
        guard await gate.isAuthorized() else { return }
        gate.post(title: s.headline, body: "Open Agent Sessions to see how to fix it.")
    }
}
```
Note: `shouldNotify` records the episode *before* the authorization check so repeated alarming polls don't re-enter; if you prefer to only "spend" the episode when actually posting, move the `d.set(true...)` after the gate check and adjust `testNotAuthorizedNeverPosts` to allow a later post — keep the current ordering to match the tests as written.

- [ ] **Step 4:** Wire `AuthStatusNotifier().onStatus(status, provider:)` into both models' `authStatus` `didSet` (or the poll completion). Register files + run tests — Expected: PASS.

- [ ] **Step 5: Stage (owner commits)** — `feat(usage): permission-gated one-shot signed-out notification`.

---

## Task 11: `AuthRemediationBanner` shared view

**Files:**
- Create: `AgentSessions/Shared/Views/AuthRemediationBanner.swift`

- [ ] **Step 1: Implement the view**

```swift
import SwiftUI
import AppKit

struct AuthRemediationBanner: View {
    let status: UsageAuthStatus
    var compact: Bool = false        // compact = live data still present; soften
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(status.state == .expired ? .orange : .red)
            VStack(alignment: .leading, spacing: 2) {
                Text(status.headline).font(.caption).bold()
                if !compact { Text(status.detail).font(.caption2).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            remediationControl
        }
        .padding(.horizontal, 10).padding(.vertical, compact ? 4 : 8)
        .background(.thinMaterial)
    }

    @ViewBuilder private var remediationControl: some View {
        switch status.remediation {
        case .showCommand(let cmd):
            HStack(spacing: 6) {
                Text(cmd).font(.system(.caption, design: .monospaced))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15)).cornerRadius(4)
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(cmd, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }.buttonStyle(.borderless).font(.caption)
            }
        case .openURL(let url):
            Button("Install…") { NSWorkspace.shared.open(url) }.buttonStyle(.borderless).font(.caption)
        case .none:
            EmptyView()
        }
    }
}
```

- [ ] **Step 2:** Register the file. Manual visual check deferred to Task 13 QA.
- [ ] **Step 3: Stage (owner commits)** — `feat(ui): shared AuthRemediationBanner with copy-command control`.

---

## Task 12: Wire banner into strips + menu bar; live-data suppression

**Files:**
- Modify: `ClaudeUsageStripView.swift` (replace caption path `:34-58`), `UsageStripView.swift` (Codex), menu-bar dropdown views (`UsageMenuBar.swift` / `StatusItemController.swift`).

- [ ] **Step 1:** In each strip, when `status.authStatus?.state.isAlarming == true`, render `AuthRemediationBanner(status:compact:)` in place of (or above) the meters. Set `compact = true` when fresh data still exists — Claude: web fallback delivering (`lastUpdate` recent while `loginRequired`); Codex: JSONL/`lastUpdate` recent. In compact mode show the banner *above* dimmed meters and do NOT let the notifier fire (Task 10 already gates on state, so additionally skip `onStatus` when `compact` — pass the live-data flag into the poll so `onStatus` is not called).

- [ ] **Step 2:** Mirror a one-line indicator in the menu-bar dropdown ("⚠︎ Sign in to Claude") linking to the same copy control.

- [ ] **Step 3:** Remove/replace the now-redundant `loginRequired`/`cliUnavailable` caption branches so there's a single source of truth (the banner).

- [ ] **Step 4: Stage (owner commits)** — `feat(ui): render auth remediation in usage strips + menu bar`.

---

## Task 13: Central verification + QA

**Files:** none (verification only).

- [ ] **Step 1: Build** — `xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug build` → Expected: BUILD SUCCEEDED.
- [ ] **Step 2: Full test suite** — run the Test command from Global Constraints → Expected: all tests pass, including the six new test files.
- [ ] **Step 3: Grep for missed callsites** — `grep -rn "loginRequired\|cliUnavailable\|activateTmuxFallback\|runCodexStatusViaTMUX\|forceProbeNow" AgentSessions` and confirm every hang/probe path honors the signed-out guard.
- [ ] **Step 4: Owner QA (batch, feature-complete)** — build the app to a non-test derived-data path (`agents.md` §Relaunching) and, with a scratch signed-out state:
  - runway shows the loud banner + correct copyable command (`claude auth login` / `codex login`), not a blank/"Usage unavailable";
  - **no** `as-cc-*` tmux server is spawned while signed-out (`ls /private/tmp/tmux-$UID/`);
  - one notification fires (if notifications authorized), not repeated; relaunch while signed-out → no repeat;
  - `claude auth login` re-auth → runway resumes automatically (recovery `.ok` emission), banner clears;
  - Desktop-only simulation (CLI binary absent) → `.cliNotInstalled` banner with Install link.
- [ ] **Step 5:** Update `CHANGELOG.md` (dev history) and hand to the owner for release/commit.

---

## Self-Review (author checklist — completed)

- **Spec coverage:** shared model → T1; blocker/keychain → T2/T3; Codex result-typed + classifier → T4/T5; short-circuit Claude/Codex + hang → T6/T8; hard-probe gate → T7; recovery `.ok` emission → T6; publish status → T9; permission-gated one-shot + persistence → T10; banner + copy + live-data suppression → T11/T12; orphan-sweep root cause → T0; verified commands → Global Constraints + T1. All spec sections mapped.
- **Placeholder scan:** the only deferred item is confirming the exact `codex login status` subcommand (T5 Step 4) — an explicit verification step, not a code placeholder.
- **Type consistency:** `UsageAuthState`/`Remediation`/`UsageAuthStatus` (T1) used consistently in T3/T5/T6/T8/T9/T10/T11; `KeychainRead` (T2)→T3; `CodexCredentialRead`/`CodexUsageFetchResult` (T4)→T5; `currentAuthState` naming shared T6/T8/T9; `authStatus`/`showAuthBanner` (T9)→T7/T12.
