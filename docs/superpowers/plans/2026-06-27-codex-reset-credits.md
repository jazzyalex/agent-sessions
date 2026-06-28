# Codex Reset Credits Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Surface Codex "reset credits" (count + expiry) in the Quota Meter hover panel and the menu-bar dropdown, read-only.

**Architecture:** A new `CodexResetCreditsFetcher` (sibling of `CodexOAuthUsageFetcher`) GETs `chatgpt.com/backend-api/wham/rate-limit-reset-credits` using the existing OAuth credentials, decodes defensively into a `CodexResetCreditsSnapshot`, and pushes it onto the shared `CodexUsageModel`. Both surfaces render from that one model via a shared, unit-tested formatter in `CodexResetCredits.swift`.

**Tech Stack:** Swift, SwiftUI, XCTest, async/await actors, `URLSession`. macOS app.

## Global Constraints

- **Codex only.** Reset credits render only under the Codex provider block; Claude has no equivalent. Copy these values verbatim.
- **Display only.** No redeem/"reset now" action, no POST, no new preference toggle. Feature inherits the existing `PreferencesKey.codexUsageEnabled` gate.
- **Privacy:** never store, log, render, or copy auth tokens, account IDs, or credit IDs. Only grant date, expiry date, status, and counts reach the UI/model layer.
- **No resting-row reflow:** the compact QM row is untouched; credits appear only in the hover-expanded panel (`HUDLimitsDetailPanel`).
- **Fail closed:** a nil/garbage network response leaves the model untouched (last good values persist).
- **New Swift files** must be registered in the Xcode project with `scripts/xcode_add_file.rb` before building.
- **Commits:** Conventional Commits with `Tool:` / `Model:` trailers, no "Generated with" footer, no Claude co-author, authored by the repo owner.
- **Build:** `xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug -derivedDataPath "$PWD/.deriveddata-manual" build`
- **Tests:** `./scripts/xcode_test_stable.sh`

---

## File Structure

- **Create** `AgentSessions/Utilities/CodexResetCredits.swift` — value types (`CodexResetCredit`, `CodexResetCreditsSnapshot`) + pure formatter functions. Shared by both surfaces and all tests.
- **Create** `AgentSessions/CodexStatus/CodexOAuth/CodexResetCreditsFetcher.swift` — defensive JSON decoder (`parse(_:)` static) + network actor.
- **Modify** `AgentSessions/CodexStatus/CodexStatusService.swift` — add `@Published` fields + `applyResetCredits(...)` + `refreshResetCredits()` to `CodexUsageModel`; trigger from `refreshNow()` and `hardProbeNow()`.
- **Modify** `AgentSessions/Views/AgentCockpitHUDView.swift` — add the credits line to `HUDLimitsDetailPanel` under the Codex block.
- **Modify** `AgentSessions/MenuBar/UsageMenuBar.swift` — add the Reset credits section to the Codex subsection (both Codex-only and `.both` layouts).
- **Create** `AgentSessionsTests/CodexResetCreditsTests.swift` — formatter + decoder tests.

---

### Task 1: Shared value types + formatter

**Files:**
- Create: `AgentSessions/Utilities/CodexResetCredits.swift`
- Test: `AgentSessionsTests/CodexResetCreditsTests.swift`

**Interfaces:**
- Produces:
  - `struct CodexResetCredit: Equatable { let grantedAt: Date?; let expiresAt: Date?; let status: String? }`
  - `struct CodexResetCreditsSnapshot: Equatable { let available: Int; let credits: [CodexResetCredit] }`
  - `enum CodexResetCredits` with:
    - `static func renderable(_ credits: [CodexResetCredit], now: Date) -> [CodexResetCredit]`
    - `static func shortExpiry(_ date: Date) -> String`
    - `static func fullExpiry(_ date: Date) -> String`
    - `static func quotaMeterLine(_ credits: [CodexResetCredit], now: Date) -> String?`
    - `static func menuSummaryLine(_ credits: [CodexResetCredit], now: Date) -> String?`
    - `static func menuExpiryLines(_ credits: [CodexResetCredit], now: Date) -> [String]`

- [ ] **Step 1: Write the failing tests**

Create `AgentSessionsTests/CodexResetCreditsTests.swift`:

```swift
import XCTest
@testable import AgentSessions

final class CodexResetCreditsTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_750_000_000) // fixed reference

    private func credit(daysFromNow: Double, status: String? = "available") -> CodexResetCredit {
        CodexResetCredit(
            grantedAt: now,
            expiresAt: now.addingTimeInterval(daysFromNow * 86_400),
            status: status
        )
    }

    // MARK: renderable

    func testRenderableExcludesExpiredAndRedeemedStatus() {
        let credits = [
            credit(daysFromNow: 30, status: "available"),
            credit(daysFromNow: 30, status: "expired"),
            credit(daysFromNow: 30, status: "redeemed"),
            credit(daysFromNow: 30, status: "REDEEMED"), // case-insensitive
        ]
        XCTAssertEqual(CodexResetCredits.renderable(credits, now: now).count, 1)
    }

    func testRenderableExcludesPastExpiry() {
        let credits = [credit(daysFromNow: -1), credit(daysFromNow: 10)]
        XCTAssertEqual(CodexResetCredits.renderable(credits, now: now).count, 1)
    }

    func testRenderableSortsByExpiryAscending() {
        let later = credit(daysFromNow: 30)
        let sooner = credit(daysFromNow: 5)
        let result = CodexResetCredits.renderable([later, sooner], now: now)
        XCTAssertEqual(result.first?.expiresAt, sooner.expiresAt)
    }

    // MARK: quotaMeterLine

    func testQuotaMeterLineNilWhenNoneRenderable() {
        XCTAssertNil(CodexResetCredits.quotaMeterLine([], now: now))
        XCTAssertNil(CodexResetCredits.quotaMeterLine([credit(daysFromNow: -1)], now: now))
    }

    func testQuotaMeterLineSingular() {
        let line = CodexResetCredits.quotaMeterLine([credit(daysFromNow: 10)], now: now)
        XCTAssertNotNil(line)
        XCTAssertTrue(line!.hasPrefix("↑ 1 reset credit · expires "), line ?? "")
    }

    func testQuotaMeterLinePlural() {
        let line = CodexResetCredits.quotaMeterLine(
            [credit(daysFromNow: 10), credit(daysFromNow: 20)], now: now
        )
        XCTAssertNotNil(line)
        XCTAssertTrue(line!.hasPrefix("↑ 2 reset credits · next expires "), line ?? "")
    }

    // MARK: menuSummaryLine

    func testMenuSummaryLineSingular() {
        let line = CodexResetCredits.menuSummaryLine([credit(daysFromNow: 10)], now: now)
        XCTAssertNotNil(line)
        XCTAssertTrue(line!.hasPrefix("1 available · expires "), line ?? "")
    }

    func testMenuSummaryLinePlural() {
        let line = CodexResetCredits.menuSummaryLine(
            [credit(daysFromNow: 10), credit(daysFromNow: 20)], now: now
        )
        XCTAssertTrue(line!.hasPrefix("2 available · next expires "), line ?? "")
    }

    func testMenuSummaryLineNilWhenEmpty() {
        XCTAssertNil(CodexResetCredits.menuSummaryLine([], now: now))
    }

    func testMenuExpiryLinesOnePerRenderableCredit() {
        let lines = CodexResetCredits.menuExpiryLines(
            [credit(daysFromNow: 10), credit(daysFromNow: 20)], now: now
        )
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines.allSatisfy { $0.hasPrefix("expires ") })
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/xcode_test_stable.sh`
Expected: FAIL — `CodexResetCredits` / `CodexResetCredit` are unresolved identifiers (compile error). That confirms the test targets nonexistent code.

- [ ] **Step 3: Write the implementation**

Create `AgentSessions/Utilities/CodexResetCredits.swift`:

```swift
import Foundation

/// One reset credit as surfaced to the UI. Intentionally carries only
/// render-relevant fields — never tokens, account IDs, or credit IDs.
struct CodexResetCredit: Equatable {
    let grantedAt: Date?
    let expiresAt: Date?
    let status: String?
}

/// A normalized snapshot of the reset-credits endpoint.
struct CodexResetCreditsSnapshot: Equatable {
    let available: Int
    let credits: [CodexResetCredit]

    static let empty = CodexResetCreditsSnapshot(available: 0, credits: [])
}

/// Pure formatting + filtering shared by the Quota Meter and menu bar.
enum CodexResetCredits {
    private static let nonRenderableStatuses: Set<String> = ["expired", "redeemed"]

    /// Credits that should be shown: not expired (by status or by date),
    /// not redeemed, sorted by soonest expiry first.
    static func renderable(_ credits: [CodexResetCredit], now: Date) -> [CodexResetCredit] {
        credits
            .filter { credit in
                if let status = credit.status?.lowercased(),
                   nonRenderableStatuses.contains(status) {
                    return false
                }
                if let expiry = credit.expiresAt, expiry <= now { return false }
                return true
            }
            .sorted { lhs, rhs in
                switch (lhs.expiresAt, rhs.expiresAt) {
                case let (l?, r?): return l < r
                case (nil, _?): return false
                case (_?, nil): return true
                case (nil, nil): return false
                }
            }
    }

    static func shortExpiry(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day())
    }

    static func fullExpiry(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    /// Quota Meter hover line, e.g. "↑ 1 reset credit · expires Jul 17"
    /// or "↑ 3 reset credits · next expires Jul 17". nil when nothing renderable.
    static func quotaMeterLine(_ credits: [CodexResetCredit], now: Date) -> String? {
        let items = renderable(credits, now: now)
        guard !items.isEmpty else { return nil }
        let n = items.count
        let earliest = items.compactMap(\.expiresAt).min()
        if n == 1 {
            let suffix = earliest.map { " · expires \(shortExpiry($0))" } ?? ""
            return "↑ 1 reset credit\(suffix)"
        } else {
            let suffix = earliest.map { " · next expires \(shortExpiry($0))" } ?? ""
            return "↑ \(n) reset credits\(suffix)"
        }
    }

    /// Menu-bar summary line, e.g. "1 available · expires Jul 17, 2026"
    /// or "3 available · next expires Jul 17, 2026". nil when nothing renderable.
    static func menuSummaryLine(_ credits: [CodexResetCredit], now: Date) -> String? {
        let items = renderable(credits, now: now)
        guard !items.isEmpty else { return nil }
        let n = items.count
        let earliest = items.compactMap(\.expiresAt).min()
        if n == 1 {
            let suffix = earliest.map { " · expires \(fullExpiry($0))" } ?? ""
            return "1 available\(suffix)"
        } else {
            let suffix = earliest.map { " · next expires \(fullExpiry($0))" } ?? ""
            return "\(n) available\(suffix)"
        }
    }

    /// Per-credit expiry lines for the menu bar when more than one credit exists,
    /// e.g. ["expires Jul 17, 2026", "expires Aug 1, 2026"].
    static func menuExpiryLines(_ credits: [CodexResetCredit], now: Date) -> [String] {
        renderable(credits, now: now).compactMap { credit in
            credit.expiresAt.map { "expires \(fullExpiry($0))" }
        }
    }
}
```

- [ ] **Step 4: Register the new file in Xcode**

Run:
```bash
./scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessions \
  AgentSessions/Utilities/CodexResetCredits.swift \
  AgentSessions/Utilities
```

- [ ] **Step 5: Register the test file in Xcode**

Run:
```bash
./scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessionsTests \
  AgentSessionsTests/CodexResetCreditsTests.swift \
  AgentSessionsTests
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `./scripts/xcode_test_stable.sh`
Expected: PASS — all `CodexResetCreditsTests` green.

- [ ] **Step 7: Commit**

```bash
git add AgentSessions/Utilities/CodexResetCredits.swift \
        AgentSessionsTests/CodexResetCreditsTests.swift \
        AgentSessions.xcodeproj/project.pbxproj
git commit -m "feat: add Codex reset-credit value types and formatter

Tool: Claude Code
Model: claude-opus-4-8
Why: shared, tested rendering for QM + menu-bar reset-credit display"
```

---

### Task 2: Reset-credits decoder + fetcher

**Files:**
- Create: `AgentSessions/CodexStatus/CodexOAuth/CodexResetCreditsFetcher.swift`
- Test: `AgentSessionsTests/CodexResetCreditsTests.swift` (append decoder cases)

**Interfaces:**
- Consumes (Task 1): `CodexResetCredit`, `CodexResetCreditsSnapshot`.
- Consumes (existing): `CodexOAuthCredentials` (init `CodexOAuthCredentials()`, async `resolve() -> CodexTokenSet?`, async `invalidateCache()`), `CodexTokenSet { accessToken, accountId }`.
- Produces:
  - `enum CodexResetCreditsParser { static func parse(_ data: Data) -> CodexResetCreditsSnapshot? }`
  - `actor CodexResetCreditsFetcher { init(credentials: CodexOAuthCredentials); func fetch(cooldownSuccess: TimeInterval, cooldownFailure: TimeInterval) async -> CodexResetCreditsSnapshot? }`

- [ ] **Step 1: Write the failing decoder tests**

Append to `AgentSessionsTests/CodexResetCreditsTests.swift` (inside the class):

```swift
    // MARK: decoder

    private func data(_ json: String) -> Data { Data(json.utf8) }

    func testParseIssueSamplePayload() {
        let json = """
        {"available_count": 1,
         "credits": [
            {"granted_at": "2026-06-17T17:38:38Z",
             "expires_at": "2026-07-17T17:38:38Z",
             "status": "available"}
         ]}
        """
        let snap = CodexResetCreditsParser.parse(data(json))
        XCTAssertNotNil(snap)
        XCTAssertEqual(snap?.available, 1)
        XCTAssertEqual(snap?.credits.count, 1)
        XCTAssertEqual(snap?.credits.first?.status, "available")
        XCTAssertNotNil(snap?.credits.first?.expiresAt)
    }

    func testParseZeroCredits() {
        let snap = CodexResetCreditsParser.parse(data(#"{"available_count": 0, "credits": []}"#))
        XCTAssertEqual(snap?.available, 0)
        XCTAssertEqual(snap?.credits.count, 0)
    }

    func testParseMissingFieldsAreNil() {
        let snap = CodexResetCreditsParser.parse(data(#"{"credits": [{}]}"#))
        XCTAssertNotNil(snap)
        XCTAssertEqual(snap?.credits.count, 1)
        XCTAssertNil(snap?.credits.first?.grantedAt)
        XCTAssertNil(snap?.credits.first?.expiresAt)
        XCTAssertNil(snap?.credits.first?.status)
        // available falls back to credits.count when available_count absent
        XCTAssertEqual(snap?.available, 1)
    }

    func testParseMalformedReturnsNil() {
        XCTAssertNil(CodexResetCreditsParser.parse(data("not json")))
    }

    func testParseFractionalSecondsISO() {
        let json = #"{"available_count": 1, "credits": [{"expires_at": "2026-07-17T17:38:38.397911+00:00"}]}"#
        let snap = CodexResetCreditsParser.parse(data(json))
        XCTAssertNotNil(snap?.credits.first?.expiresAt)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/xcode_test_stable.sh`
Expected: FAIL — `CodexResetCreditsParser` unresolved (compile error).

- [ ] **Step 3: Write the fetcher + parser**

Create `AgentSessions/CodexStatus/CodexOAuth/CodexResetCreditsFetcher.swift`:

```swift
import Foundation
import os.log

private let log = OSLog(subsystem: "com.triada.AgentSessions", category: "CodexResetCredits")

// MARK: - Raw DTOs (defensive: all fields optional, fail closed in parser)

private struct RawResetCreditsResponse: Decodable {
    let availableCount: Int?
    let credits: [RawResetCredit]?

    enum CodingKeys: String, CodingKey {
        case availableCount = "available_count"
        case credits
    }
}

private struct RawResetCredit: Decodable {
    let grantedAt: String?
    let expiresAt: String?
    let status: String?

    enum CodingKeys: String, CodingKey {
        case grantedAt = "granted_at"
        case expiresAt = "expires_at"
        case status
    }
}

// MARK: - Parser (pure, unit-tested)

enum CodexResetCreditsParser {
    static func parse(_ data: Data) -> CodexResetCreditsSnapshot? {
        guard let raw = try? JSONDecoder().decode(RawResetCreditsResponse.self, from: data) else {
            return nil
        }
        let rawCredits = raw.credits ?? []
        let credits = rawCredits.map { rc in
            CodexResetCredit(
                grantedAt: isoDate(rc.grantedAt),
                expiresAt: isoDate(rc.expiresAt),
                status: rc.status
            )
        }
        let available = raw.availableCount ?? credits.count
        return CodexResetCreditsSnapshot(available: max(0, available), credits: credits)
    }

    private static func isoDate(_ text: String?) -> Date? {
        guard let text, text.contains("T") else { return nil }
        let frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = frac.date(from: text) { return d }
        let std = ISO8601DateFormatter()
        std.formatOptions = [.withInternetDateTime]
        return std.date(from: text)
    }
}

// MARK: - Error

private enum CodexResetCreditsError: Error {
    case unauthorized
    case rateLimited(retryAfter: TimeInterval)
    case httpError(Int)
    case needsExtraHeaders
    case networkError(Error)
}

// MARK: - Fetcher

actor CodexResetCreditsFetcher {
    private let credentials: CodexOAuthCredentials
    private let session: URLSession
    private static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!

    private var lastFetchAt: Date?
    private var lastFetchFailed = false
    private var rateLimitedUntil: Date?

    init(credentials: CodexOAuthCredentials) {
        self.credentials = credentials
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        self.session = URLSession(configuration: config)
    }

    /// Returns a snapshot on success, nil on any failure (caller leaves model untouched).
    /// Credits are slow-moving, so the default cooldown is long.
    func fetch(cooldownSuccess: TimeInterval = 6 * 60 * 60,
               cooldownFailure: TimeInterval = 30 * 60) async -> CodexResetCreditsSnapshot? {
        let now = Date()

        if let until = rateLimitedUntil, until > now { return nil }
        if let last = lastFetchAt {
            let cd = lastFetchFailed ? cooldownFailure : cooldownSuccess
            if now.timeIntervalSince(last) < cd { return nil }
        }

        guard let tokenSet = await credentials.resolve() else { return nil }

        lastFetchAt = now
        do {
            let data = try await request(token: tokenSet.accessToken,
                                         accountId: tokenSet.accountId,
                                         extraHeaders: false)
            return finish(data)
        } catch CodexResetCreditsError.needsExtraHeaders {
            // Some accounts require the Codex-Desktop originator headers; retry once.
            do {
                let data = try await request(token: tokenSet.accessToken,
                                             accountId: tokenSet.accountId,
                                             extraHeaders: true)
                return finish(data)
            } catch {
                lastFetchFailed = true
                return nil
            }
        } catch CodexResetCreditsError.unauthorized {
            await credentials.invalidateCache()
            lastFetchFailed = true
            return nil
        } catch CodexResetCreditsError.rateLimited(let retryAfter) {
            rateLimitedUntil = Date().addingTimeInterval(retryAfter)
            lastFetchFailed = true
            return nil
        } catch {
            os_log("CodexResetCredits: fetch failed: %{public}@", log: log, type: .error,
                   String(describing: error))
            lastFetchFailed = true
            return nil
        }
    }

    private func finish(_ data: Data) -> CodexResetCreditsSnapshot? {
        let snap = CodexResetCreditsParser.parse(data)
        lastFetchFailed = (snap == nil)
        return snap
    }

    private func request(token: String, accountId: String?, extraHeaders: Bool) async throws -> Data {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("AgentSessions", forHTTPHeaderField: "User-Agent")
        if let accountId, !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        if extraHeaders {
            request.setValue("codex-1", forHTTPHeaderField: "OpenAI-Beta")
            request.setValue("Codex Desktop", forHTTPHeaderField: "originator")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CodexResetCreditsError.networkError(error)
        }

        if let http = response as? HTTPURLResponse {
            if http.statusCode == 401 { throw CodexResetCreditsError.unauthorized }
            if http.statusCode == 429 {
                let raw = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init) ?? 0
                throw CodexResetCreditsError.rateLimited(retryAfter: max(raw, 300))
            }
            // Bare request rejected → signal a single retry with originator headers.
            if !extraHeaders, http.statusCode == 403 || http.statusCode == 404 {
                throw CodexResetCreditsError.needsExtraHeaders
            }
            guard (200..<300).contains(http.statusCode) else {
                throw CodexResetCreditsError.httpError(http.statusCode)
            }
        }
        return data
    }
}
```

- [ ] **Step 4: Register the new file in Xcode**

Run:
```bash
./scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessions \
  AgentSessions/CodexStatus/CodexOAuth/CodexResetCreditsFetcher.swift \
  AgentSessions/CodexStatus/CodexOAuth
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `./scripts/xcode_test_stable.sh`
Expected: PASS — decoder cases green; existing tests still green.

- [ ] **Step 6: Commit**

```bash
git add AgentSessions/CodexStatus/CodexOAuth/CodexResetCreditsFetcher.swift \
        AgentSessionsTests/CodexResetCreditsTests.swift \
        AgentSessions.xcodeproj/project.pbxproj
git commit -m "feat: add Codex reset-credits fetcher and decoder

Tool: Claude Code
Model: claude-opus-4-8
Why: read reset-credit endpoint with existing OAuth creds, fail closed"
```

---

### Task 3: Store credits on CodexUsageModel and trigger fetches

**Files:**
- Modify: `AgentSessions/CodexStatus/CodexStatusService.swift` (class `CodexUsageModel`, `@MainActor`, starts at `:139`; `refreshNow()` at `:246`; `hardProbeNow(completion:)` at `:279`)

**Interfaces:**
- Consumes (Task 1/2): `CodexResetCredit`, `CodexResetCreditsSnapshot`, `CodexResetCreditsFetcher`, `CodexOAuthCredentials`.
- Produces (used by Tasks 4 & 5):
  - `CodexUsageModel.resetCreditsAvailable: Int`
  - `CodexUsageModel.resetCredits: [CodexResetCredit]`
  - `CodexUsageModel.applyResetCredits(_ snapshot: CodexResetCreditsSnapshot)`

- [ ] **Step 1: Add published fields**

In `CodexStatusService.swift`, in the `@Published` block of `CodexUsageModel` (near the existing `@Published var weekResetText` around `:146`), add:

```swift
    @Published var resetCreditsAvailable: Int = 0
    @Published var resetCredits: [CodexResetCredit] = []
    @Published var resetCreditsLastFetch: Date? = nil
```

- [ ] **Step 2: Add the fetcher instance + apply/refresh methods**

In the same `CodexUsageModel` class (place near other private fields / methods, after `refreshNow()`), add:

```swift
    private let resetCreditsFetcher = CodexResetCreditsFetcher(credentials: CodexOAuthCredentials())

    /// Applies a fetched credits snapshot to the published state. No-op for nil
    /// is handled by the caller; this commits whatever the parser returned.
    func applyResetCredits(_ snapshot: CodexResetCreditsSnapshot) {
        resetCreditsAvailable = snapshot.available
        resetCredits = snapshot.credits
        resetCreditsLastFetch = Date()
    }

    /// Kicks a reset-credits fetch if Codex usage tracking is enabled. The
    /// fetcher's own long cooldown gates how often the network is actually hit,
    /// so this is safe to call from every refresh path.
    func refreshResetCredits() {
        guard UserDefaults.standard.bool(forKey: PreferencesKey.codexUsageEnabled) else { return }
        Task { [weak self] in
            guard let self else { return }
            guard let snapshot = await self.resetCreditsFetcher.fetch() else { return }
            await MainActor.run { self.applyResetCredits(snapshot) }
        }
    }
```

- [ ] **Step 3: Trigger from the refresh entry points**

In `refreshNow()` (`:246`), add `refreshResetCredits()` as the first line of the method body.

In `hardProbeNow(completion:)` (`:279`), add `refreshResetCredits()` as the first line of the method body.

(Both are on the `@MainActor` `CodexUsageModel`, so the call is synchronous and just spawns the gated Task.)

- [ ] **Step 4: Add a model apply test (DEBUG already exposes apply paths)**

Append to `AgentSessionsTests/CodexResetCreditsTests.swift`:

```swift
    @MainActor
    func testModelApplyResetCreditsPublishesValues() {
        let model = CodexUsageModel()
        let snap = CodexResetCreditsSnapshot(
            available: 2,
            credits: [
                CodexResetCredit(grantedAt: now, expiresAt: now.addingTimeInterval(86_400), status: "available"),
                CodexResetCredit(grantedAt: now, expiresAt: now.addingTimeInterval(172_800), status: "available"),
            ]
        )
        model.applyResetCredits(snap)
        XCTAssertEqual(model.resetCreditsAvailable, 2)
        XCTAssertEqual(model.resetCredits.count, 2)
        XCTAssertNotNil(model.resetCreditsLastFetch)
    }
```

Note: if `CodexUsageModel()` is not directly constructible in tests (e.g. a private init or required shared singleton), use `CodexUsageModel.shared` and reset by applying an empty snapshot first:
```swift
let model = CodexUsageModel.shared
model.applyResetCredits(.empty)
```

- [ ] **Step 5: Build, then run tests**

Run: `xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug -derivedDataPath "$PWD/.deriveddata-manual" build`
Expected: BUILD SUCCEEDED.

Run: `./scripts/xcode_test_stable.sh`
Expected: PASS — including `testModelApplyResetCreditsPublishesValues`.

- [ ] **Step 6: Commit**

```bash
git add AgentSessions/CodexStatus/CodexStatusService.swift \
        AgentSessionsTests/CodexResetCreditsTests.swift
git commit -m "feat: fetch and store Codex reset credits on the usage model

Tool: Claude Code
Model: claude-opus-4-8
Why: single shared source feeding QM hover panel and menu bar"
```

---

### Task 4: Render the credits line in the QM hover panel

**Files:**
- Modify: `AgentSessions/Views/AgentCockpitHUDView.swift` (`HUDLimitsDetailPanel`, starts `:4197`; per-entry loop in `body` at `:4223`)

**Interfaces:**
- Consumes (Task 1/3): `CodexResetCredits.quotaMeterLine(_:now:)`, `CodexUsageModel.resetCredits`.
- The panel already receives `now: Date`. It does not currently observe `CodexUsageModel`; add an `@EnvironmentObject` for it (the cockpit already injects `CodexUsageModel` — see `HUDLimitsBar`'s `@EnvironmentObject private var codexUsageModel`).

- [ ] **Step 1: Observe the Codex model in the panel**

In `HUDLimitsDetailPanel` (after the existing stored `let`/`var` properties, before `@Environment(\.colorScheme)` at `:4204`), add:

```swift
    @EnvironmentObject private var codexUsageModel: CodexUsageModel
```

- [ ] **Step 2: Render the credits line under the Codex block**

In `body`, inside the `ForEach(Array(entries.enumerated()) ...)` loop (`:4223`), the per-entry content currently renders a `Grid { detailRow(...) }` then `runwayBlock(for:)`. Insert the credits line between the `Grid` and `runwayBlock`, gated to the Codex entry:

```swift
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity)
                if entry.source == .codex,
                   let creditsLine = CodexResetCredits.quotaMeterLine(codexUsageModel.resetCredits, now: now) {
                    HStack(spacing: 0) {
                        Text(creditsLine)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 1)
                }
                runwayBlock(for: entry.source)
```

(Match the exact surrounding lines: the `Grid { detailRow(...) }` block ends with `.padding(.horizontal, 10)` / `.frame(maxWidth: .infinity)` at `:4235-4236`; insert the new `if` immediately after `.frame(maxWidth: .infinity)` and before the existing `runwayBlock(for: entry.source)` at `:4237`.)

- [ ] **Step 3: Build**

Run: `xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug -derivedDataPath "$PWD/.deriveddata-manual" build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Manual verification**

Run:
```bash
killall AgentSessions 2>/dev/null; open .deriveddata-manual/Build/Products/Debug/AgentSessions.app
```
Switch the cockpit to Quota Meter, ensure Codex usage is enabled and logged in, then hover the Codex row. Expected: when the account has reset credits, a secondary line `↑ N reset credit(s) · …expires …` appears under the Codex usage row and above its runway block; the resting (non-hover) row is unchanged. With no credits, no extra line appears.

(If the account has no credits to verify against, temporarily call `CodexUsageModel.shared.applyResetCredits(CodexResetCreditsSnapshot(available: 1, credits: [CodexResetCredit(grantedAt: Date(), expiresAt: Date().addingTimeInterval(30*86400), status: "available")]))` from a debug menu / breakpoint, confirm the line renders, then remove.)

- [ ] **Step 5: Commit**

```bash
git add AgentSessions/Views/AgentCockpitHUDView.swift
git commit -m "feat: show Codex reset credits in the Quota Meter hover panel

Tool: Claude Code
Model: claude-opus-4-8
Why: surface reset credits without reflowing the compact resting row"
```

---

### Task 5: Render the Reset credits section in the menu bar

**Files:**
- Modify: `AgentSessions/MenuBar/UsageMenuBar.swift` (Codex subsection in `body`, `:291`–`:325`)

**Interfaces:**
- Consumes (Task 1/3): `CodexResetCredits.menuSummaryLine(_:now:)`, `CodexResetCredits.menuExpiryLines(_:now:)`, `codexStatus.resetCredits` (the `CodexUsageModel` injected as `codexStatus`).

- [ ] **Step 1: Insert the section into the Codex subsection**

In `UsageMenuBar` `body`, inside the Codex `VStack(alignment: .leading, spacing: 2)` (the block opened at `:292`), after the `Wk:` button (ends `:313`) and before the "Last updated time" `if let lastUpdate` block (`:316`), insert:

```swift
                    if let creditsSummary = CodexResetCredits.menuSummaryLine(codexStatus.resetCredits, now: Date()) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Reset credits")
                                .font(.body)
                                .fontWeight(.semibold)
                                .foregroundStyle(.primary)
                                .padding(.top, 4)
                            Button(action: { openPreferencesUsage() }) {
                                HStack(spacing: 6) {
                                    Text(creditsSummary)
                                        .font(.system(size: 13))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                            if codexStatus.resetCredits.isEmpty == false {
                                let lines = CodexResetCredits.menuExpiryLines(codexStatus.resetCredits, now: Date())
                                if lines.count > 1 {
                                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                                        Text(line)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
```

Because this lives inside the shared Codex subsection `VStack`, it renders in **both** the Codex-only (`source == .codex`) and the combined (`source == .both`) menu layouts, exactly as required. The menu-bar title/strip itself is not touched.

- [ ] **Step 2: Build**

Run: `xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug -derivedDataPath "$PWD/.deriveddata-manual" build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Manual verification**

Run:
```bash
killall AgentSessions 2>/dev/null; open .deriveddata-manual/Build/Products/Debug/AgentSessions.app
```
Open the usage menu-bar dropdown with Codex enabled. Expected: when credits exist, a "Reset credits" header with `N available · …expires …` appears under the Codex `Wk:` line; with multiple credits, each expiry is listed; tapping opens Usage preferences. With no credits, the section is absent. Verify it shows under both the Codex-only and Codex+Claude (`.both`) menu source settings.

- [ ] **Step 4: Commit**

```bash
git add AgentSessions/MenuBar/UsageMenuBar.swift
git commit -m "feat: show Codex reset credits in the usage menu bar

Tool: Claude Code
Model: claude-opus-4-8
Why: discoverable reset-credit count and expiry alongside reset times"
```

---

## Self-Review

**Spec coverage:**
- Data model (one shared source) → Task 1 (types) + Task 3 (model fields). ✓
- Fetch path mirroring usage fetcher, sibling endpoint, conditional extra headers, defensive decode, fail-closed → Task 2. ✓
- Cadence (long cooldown + hard-probe trigger, no new timer) → Task 2 (cooldown defaults) + Task 3 (`refreshResetCredits` from `refreshNow`/`hardProbeNow`). ✓
- QM hover-only extra line under Codex, no resting reflow → Task 4. ✓
- Menu-bar section under Codex in both layouts, title untouched → Task 5. ✓
- Shared tested formatter → Task 1. ✓
- Empty/unavailable states (render nothing) → `quotaMeterLine`/`menuSummaryLine` return nil; views gate on that (Tasks 1, 4, 5). ✓
- Privacy (no tokens/account/credit IDs stored or shown) → types carry only dates+status+counts; fetcher never persists identifiers (Tasks 1, 2). ✓
- Testing (decoder + formatter, no network) → Tasks 1–3. ✓

**Placeholder scan:** No TBD/TODO; every code step shows complete code; commands have expected output. ✓

**Type consistency:** `CodexResetCredit`/`CodexResetCreditsSnapshot` defined in Task 1 and consumed unchanged in Tasks 2–5. `CodexResetCreditsParser.parse` (Task 2) feeds `CodexResetCreditsFetcher.fetch` (Task 2) → `CodexUsageModel.applyResetCredits` (Task 3). Formatter names (`quotaMeterLine`, `menuSummaryLine`, `menuExpiryLines`, `renderable`) match across Tasks 1/4/5. ✓

**Risk to validate during execution:** the conditional extra-header retry (Task 2) is based on the issue's reference script; if the bare request already succeeds, the retry path is simply never taken. Confirm real endpoint behavior during Task 4/5 manual verification with a logged-in account.
