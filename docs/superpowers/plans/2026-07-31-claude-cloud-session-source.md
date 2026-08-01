# Claude Cloud Sessions in Runway — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show actively-running Claude cloud sessions as live rows in the Quota Meter's Live Sessions list, alongside local agent rows.

**Architecture:** A new isolated `AgentSessions/ClaudeCloud/` module polls one claude.ai endpoint (`/v1/code/sessions`), keeps rows whose `environment_kind` is `anthropic_cloud`, and maps the active ones to `HUDRow`. Liveness comes entirely from fields in the list payload — no per-session probing, no transcript fetching, no `index.db` writes.

**Tech Stack:** Swift 5 / SwiftUI, `URLSession` (ephemeral), Swift actors, XCTest.

**Status:** Task 0 complete — **GO**. Contract verified live 2026-07-31; see
[the spec](../specs/2026-07-31-claude-cloud-session-source-design.md) §3.

## Global Constraints

- **Read-only.** `GET` only. No mutating call anywhere in this module.
- **No disk persistence.** Nothing written to `index.db` or any cache file.
- **Opt-in, off by default** (`AppStorage` key, §Task 4).
- **Total isolation.** Any cloud failure must leave local rows fully functional.
- **Filter on `environment_kind == "anthropic_cloud"`** — never on the `cse_` prefix. All 177
  observed rows are `cse_`-prefixed; 168 are `bridge` rows that the local indexer already shows.
- **Never** call `safety_flags`, and never long-poll.
- **URLSession, not curl** — curl is Cloudflare-403'd on this API (TLS fingerprint). Any probe
  or manual check must use URLSession or it reports false negatives.
- New Swift files MUST be registered with `./scripts/xcode_add_file.rb` or the build fails.
- Tests run via `./scripts/xcode_test_stable.sh`.
- Conventional Commits; no Claude co-author trailer, no generated-with footer.

## Verified contract (do not re-derive)

```
GET https://claude.ai/v1/code/sessions?limit=100[&cursor=<next_cursor>]
  Cookie: sessionKey=<key>
  anthropic-version: 2023-06-01
  anthropic-beta: ccr-byoc-2025-07-29
  anthropic-client-feature: ccr
  x-organization-uuid: <org uuid>
→ {"data": [...], "next_cursor": String?, "resume_token": String}
```

Row fields used: `id`, `title`, `status`, `status_bucket`, `worker_status`,
`connection_status`, `last_event_at`, `unread`, `environment_kind`.

Observed vocabulary: `status` ∈ {active, archived}; `status_bucket` ∈ {working, review_ready,
completed, failed}; `worker_status` ∈ {running, idle, WORKER_STATUS_UNSPECIFIED};
`connection_status` ∈ {connected, disconnected}; `environment_kind` ∈ {anthropic_cloud, bridge,
absent}.

---

## Task 1: API client

**Files:**
- Create: `AgentSessions/ClaudeCloud/ClaudeCloudError.swift`
- Create: `AgentSessions/ClaudeCloud/ClaudeCloudAPIClient.swift`
- Test: `AgentSessionsLogicTests/ClaudeCloudAPIClientTests.swift`

**Interfaces:**
- Consumes: the existing claude.ai `sessionKey` resolver, and the org UUID (same source
  `ClaudeWebUsageClient` uses).
- Produces:
  - `enum ClaudeCloudError: Error, Equatable { case notConnected, expired, rateLimited(until: Date?), offline, contractDrift(String) }`
  - `struct ClaudeCloudRawSession: Equatable { let id, title, status, statusBucket, workerStatus, connectionStatus, environmentKind: String?; let lastEventAt: Date?; let unread: Int? }`
  - `actor ClaudeCloudAPIClient` with `func listSessions(sessionKey: String, orgID: String, maxPages: Int = 3) async throws -> [ClaudeCloudRawSession]`
  - `static func mapHTTP(_ status: Int, retryAfter: String?) -> ClaudeCloudError?`
  - `static func decodeList(_ data: Data) throws -> (rows: [ClaudeCloudRawSession], nextCursor: String?)`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import AgentSessions

final class ClaudeCloudAPIClientTests: XCTestCase {

    func test_mapHTTP_401_isExpired() {
        XCTAssertEqual(ClaudeCloudAPIClient.mapHTTP(401, retryAfter: nil), .expired)
    }

    func test_mapHTTP_429_parsesRetryAfterSeconds() {
        guard case .rateLimited(let until)? = ClaudeCloudAPIClient.mapHTTP(429, retryAfter: "120") else {
            return XCTFail("expected rateLimited")
        }
        XCTAssertNotNil(until)
    }

    func test_mapHTTP_200_isNil() {
        XCTAssertNil(ClaudeCloudAPIClient.mapHTTP(200, retryAfter: nil))
    }

    func test_decodeList_readsEnvelopeAndCursor() throws {
        let json = """
        {"data":[{"id":"cse_a","title":"T","status":"active","status_bucket":"working",
                  "worker_status":"running","connection_status":"connected",
                  "environment_kind":"anthropic_cloud","unread":1,
                  "last_event_at":"2026-08-01T02:19:02.357615Z"}],
         "next_cursor":"abc","resume_token":"r"}
        """.data(using: .utf8)!
        let out = try ClaudeCloudAPIClient.decodeList(json)
        XCTAssertEqual(out.nextCursor, "abc")
        XCTAssertEqual(out.rows.count, 1)
        XCTAssertEqual(out.rows[0].id, "cse_a")
        XCTAssertEqual(out.rows[0].workerStatus, "running")
        XCTAssertEqual(out.rows[0].unread, 1)
        XCTAssertNotNil(out.rows[0].lastEventAt, "fractional-second ISO-8601 must parse")
    }

    func test_decodeList_skipsBadRowsInsteadOfFailingBatch() throws {
        let json = #"{"data":[{"id":"cse_ok"},{"no_id":true}],"next_cursor":null}"#.data(using: .utf8)!
        let out = try ClaudeCloudAPIClient.decodeList(json)
        XCTAssertEqual(out.rows.map(\.id), ["cse_ok"])
    }

    func test_decodeList_unrecognisedEnvelopeThrowsContractDrift() {
        let json = #"{"unexpected":"envelope"}"#.data(using: .utf8)!
        XCTAssertThrowsError(try ClaudeCloudAPIClient.decodeList(json)) {
            guard case ClaudeCloudError.contractDrift = $0 else {
                return XCTFail("expected contractDrift, got \($0)")
            }
        }
    }
}
```

- [ ] **Step 2: Register the files**

```bash
./scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessions AgentSessions/ClaudeCloud/ClaudeCloudError.swift AgentSessions/ClaudeCloud
./scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessions AgentSessions/ClaudeCloud/ClaudeCloudAPIClient.swift AgentSessions/ClaudeCloud
./scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessionsLogicTests AgentSessionsLogicTests/ClaudeCloudAPIClientTests.swift AgentSessionsLogicTests
```

- [ ] **Step 3: Run tests — expect FAIL** (`ClaudeCloudAPIClient` not found)

Run: `./scripts/xcode_test_stable.sh`

- [ ] **Step 4: Implement**

Transport mirrors `ClaudeWebUsageClient`: `URLSessionConfiguration.ephemeral`, request timeout 8,
resource timeout 12. Headers exactly as in the verified contract above.

`last_event_at` is ISO-8601 **with fractional seconds** — use
`ISO8601DateFormatter` with `[.withInternetDateTime, .withFractionalSeconds]`, and fall back to
the non-fractional variant so a format change degrades to `nil` rather than throwing.

`decodeList` requires a `data` array; anything else throws `.contractDrift`. Individual rows
missing `id` are skipped, not fatal. Pagination follows `next_cursor` up to `maxPages`
(default 3 = 300 rows, ample for the active set) and stops on nil.

- [ ] **Step 5: Run tests — expect PASS** (5 tests)

- [ ] **Step 6: Commit**

```bash
git add AgentSessions/ClaudeCloud AgentSessionsLogicTests/ClaudeCloudAPIClientTests.swift AgentSessions.xcodeproj
git commit -m "feat(cloud): add claude.ai /v1/code/sessions client"
```

---

## Task 2: Catalog — cloud filter, active predicate, rendered state machine

**Files:**
- Create: `AgentSessions/ClaudeCloud/ClaudeCloudSourceState.swift`
- Create: `AgentSessions/ClaudeCloud/ClaudeCloudSessionCatalog.swift`
- Test: `AgentSessionsLogicTests/ClaudeCloudCatalogTests.swift`

**Interfaces:**
- Consumes: Task 1.
- Produces:
  - `enum ClaudeCloudSourceState: Equatable { case disabled, notConnected, expired, rateLimited(until: Date?), offline, contractDrift(String), empty, ok(count: Int) }` with `var displayMessage: String` and `var isStale: Bool`
  - `struct ClaudeCloudSession: Identifiable, Equatable { let id, title: String; let isWorking, isAwaitingReview, isDisconnected: Bool; let lastEventAt: Date?; let unread: Int }`
  - `enum ClaudeCloudFilter { static func cloudOnly(_:) -> [ClaudeCloudRawSession]; static func activeRows(_:) -> [ClaudeCloudSession] }`
  - `@MainActor @Observable final class ClaudeCloudSessionCatalog` with `private(set) var state`, `private(set) var sessions: [ClaudeCloudSession]`, `func refresh() async`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import AgentSessions

final class ClaudeCloudCatalogTests: XCTestCase {

    private func raw(_ id: String, kind: String?, status: String = "active",
                     bucket: String = "working", worker: String = "running",
                     conn: String = "connected") -> ClaudeCloudRawSession {
        ClaudeCloudRawSession(id: id, title: "t", status: status, statusBucket: bucket,
                              workerStatus: worker, connectionStatus: conn,
                              environmentKind: kind, lastEventAt: nil, unread: 0)
    }

    func test_keepsOnlyAnthropicCloudRows_notThePrefix() {
        let rows = [raw("cse_a", kind: "anthropic_cloud"),
                    raw("cse_b", kind: "bridge"),
                    raw("cse_c", kind: nil)]
        XCTAssertEqual(ClaudeCloudFilter.cloudOnly(rows).map(\.id), ["cse_a"],
                       "bridge and absent kinds must be excluded — all three are cse_")
    }

    func test_activeRowsExcludeArchivedAndCompleted() {
        let rows = [raw("cse_working", kind: "anthropic_cloud"),
                    raw("cse_review", kind: "anthropic_cloud", bucket: "review_ready", worker: "idle"),
                    raw("cse_done", kind: "anthropic_cloud", status: "archived", bucket: "completed", worker: "idle"),
                    raw("cse_failed", kind: "anthropic_cloud", bucket: "failed", worker: "idle")]
        let ids = ClaudeCloudFilter.activeRows(ClaudeCloudFilter.cloudOnly(rows)).map(\.id)
        XCTAssertEqual(Set(ids), ["cse_working", "cse_review"])
    }

    func test_unspecifiedWorkerStatusFallsBackToBucket() {
        let rows = [raw("cse_x", kind: "anthropic_cloud", worker: "WORKER_STATUS_UNSPECIFIED")]
        let row = ClaudeCloudFilter.activeRows(ClaudeCloudFilter.cloudOnly(rows)).first
        XCTAssertEqual(row?.isWorking, true, "bucket=working must carry it when worker is unspecified")
    }

    func test_everyStateHasDistinctNonEmptyMessage() {
        let all: [ClaudeCloudSourceState] = [.disabled, .notConnected, .expired,
                                             .rateLimited(until: nil), .offline,
                                             .contractDrift("x"), .empty, .ok(count: 2)]
        let msgs = all.map(\.displayMessage)
        XCTAssertFalse(msgs.contains { $0.trimmingCharacters(in: .whitespaces).isEmpty })
        XCTAssertEqual(Set(msgs).count, all.count, "states collapsed to identical copy")
    }

    func test_emptyAndNotConnectedNeverReadTheSame() {
        XCTAssertNotEqual(ClaudeCloudSourceState.empty.displayMessage,
                          ClaudeCloudSourceState.notConnected.displayMessage)
    }

    func test_onlyDegradedStatesAreStale() {
        XCTAssertTrue(ClaudeCloudSourceState.offline.isStale)
        XCTAssertTrue(ClaudeCloudSourceState.rateLimited(until: nil).isStale)
        XCTAssertFalse(ClaudeCloudSourceState.ok(count: 1).isStale)
        XCTAssertFalse(ClaudeCloudSourceState.empty.isStale)
    }
}
```

- [ ] **Step 2: Register the files** (same `xcode_add_file.rb` pattern as Task 1)

- [ ] **Step 3: Run tests — expect FAIL**

- [ ] **Step 4: Implement**

`cloudOnly` keeps `environmentKind == "anthropic_cloud"` exactly — absent kind is excluded, never
guessed.

`activeRows` keeps `status == "active"` and `statusBucket ∈ {working, review_ready}`, mapping:
`isWorking = workerStatus == "running" || (workerStatus == "WORKER_STATUS_UNSPECIFIED" && statusBucket == "working")`;
`isAwaitingReview = statusBucket == "review_ready"`;
`isDisconnected = connectionStatus == "disconnected"`.

`displayMessage` copy: `disabled` → `Cloud sessions are off`; `notConnected` → `Connect claude.ai in Settings to see cloud sessions`; `expired` → `claude.ai session expired — paste a fresh session cookie in Settings`; `rateLimited` → `Rate limited — retrying at HH:mm` (or `…retrying shortly` when nil); `offline` → `Offline — showing last known cloud sessions`; `contractDrift` → `Cloud sessions unavailable (claude.ai API changed)`; `empty` → `No active cloud sessions`; `ok(n)` → `n active cloud sessions`.

`refresh()` keeps existing `sessions` on `rateLimited`/`offline`, clears them on
`expired`/`notConnected`/`contractDrift`/`disabled`.

- [ ] **Step 5: Run tests — expect PASS** (6 tests)

- [ ] **Step 6: Commit**

```bash
git add AgentSessions/ClaudeCloud AgentSessionsLogicTests/ClaudeCloudCatalogTests.swift AgentSessions.xcodeproj
git commit -m "feat(cloud): filter cloud sessions and add rendered source state"
```

---

## Task 3: HUDRow mapping and Quota Meter wiring

**Files:**
- Create: `AgentSessions/ClaudeCloud/ClaudeCloudHUDRowMapper.swift`
- Modify: `AgentSessions/Views/AgentCockpitHUDView.swift` (append cloud rows to the live list)
- Test: `AgentSessionsLogicTests/ClaudeCloudHUDRowMapperTests.swift`

**Interfaces:**
- Consumes: Task 2.
- Produces: `enum ClaudeCloudHUDRowMapper { static func rows(from: [ClaudeCloudSession], now: Date) -> [HUDRow] }`

`HUDRow`'s init defaults every terminal/path field to nil, so a cloud row needs no fake process
data: `itermSessionId`, `revealURL`, `tty`, `termProgram`, `logPath`, `workingDirectory` all stay
nil and `navigationConfidence` stays `.none`.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import AgentSessions

final class ClaudeCloudHUDRowMapperTests: XCTestCase {

    private func session(_ id: String, working: Bool = true, review: Bool = false,
                         disconnected: Bool = false, unread: Int = 0) -> ClaudeCloudSession {
        ClaudeCloudSession(id: id, title: "PingCraft game design prototype",
                           isWorking: working, isAwaitingReview: review,
                           isDisconnected: disconnected,
                           lastEventAt: Date(timeIntervalSince1970: 1_785_000_000),
                           unread: unread)
    }

    func test_workingSessionMapsToActiveRow() {
        let row = ClaudeCloudHUDRowMapper.rows(from: [session("cse_a")], now: Date()).first
        XCTAssertEqual(row?.liveState, .active)
        XCTAssertEqual(row?.agentType, .claude)
        XCTAssertEqual(row?.displayName, "PingCraft game design prototype")
    }

    func test_reviewReadyMapsToIdleWaiting() {
        let row = ClaudeCloudHUDRowMapper.rows(
            from: [session("cse_b", working: false, review: true)], now: Date()).first
        XCTAssertEqual(row?.liveState, .idle)
        XCTAssertEqual(row?.idleReason, .generic)
    }

    func test_carriesNoFakeProcessData() {
        let row = ClaudeCloudHUDRowMapper.rows(from: [session("cse_c")], now: Date()).first
        XCTAssertNil(row?.tty)
        XCTAssertNil(row?.logPath)
        XCTAssertNil(row?.revealURL)
        XCTAssertNil(row?.workingDirectory)
        XCTAssertEqual(row?.navigationConfidence, HUDNavigationConfidence.none)
    }

    func test_rowIdIsStableAndNamespaced() {
        let a = ClaudeCloudHUDRowMapper.rows(from: [session("cse_a")], now: Date()).first
        let b = ClaudeCloudHUDRowMapper.rows(from: [session("cse_a")], now: Date()).first
        XCTAssertEqual(a?.id, b?.id)
        XCTAssertTrue(a?.id.contains("cse_a") == true)
    }
}
```

- [ ] **Step 2: Register the files**

- [ ] **Step 3: Run tests — expect FAIL**

- [ ] **Step 4: Implement mapper, then wire it in**

Mapper: `liveState = isWorking ? .active : .idle`; `idleReason = isWorking ? nil : .generic`;
`projectName` = "Claude Cloud"; `preview` = "" unless disconnected, in which case a short
"Disconnected" note; `elapsed` formatted from `lastEventAt` using the same helper local rows use.

Wiring: append the mapper's output to the row list `AgentCockpitHUDView` already builds, behind
the enablement flag. Wrap the catalog call so a throw cannot reach local row construction.

- [ ] **Step 5: Run tests — expect PASS** (4 tests, plus all prior tests still green)

- [ ] **Step 6: Commit**

```bash
git add AgentSessions/ClaudeCloud AgentSessions/Views/AgentCockpitHUDView.swift AgentSessionsLogicTests/ClaudeCloudHUDRowMapperTests.swift AgentSessions.xcodeproj
git commit -m "feat(cloud): show active cloud sessions as Quota Meter live rows"
```

---

## Task 4: Isolation guard

**Files:**
- Test: `AgentSessionsLogicTests/ClaudeCloudIsolationTests.swift`

Source-level guards for constraints that are invisible at runtime until violated.

- [ ] **Step 1: Write the test**

```swift
import XCTest

final class ClaudeCloudIsolationTests: XCTestCase {

    private func cloudSources() throws -> [(name: String, text: String)] {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("AgentSessions/ClaudeCloud")
        let files = try FileManager.default
            .contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "guard is vacuous if it finds no sources")
        return try files.map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }

    func test_noCloudCodeTouchesTheIndexDatabase() throws {
        for f in try cloudSources() {
            XCTAssertFalse(f.text.contains("index.db"), "\(f.name) references index.db")
            XCTAssertFalse(f.text.contains("sqlite3_"), "\(f.name) uses sqlite directly")
        }
    }

    func test_noMutatingHTTPMethods() throws {
        for f in try cloudSources() {
            for verb in ["\"POST\"", "\"PUT\"", "\"DELETE\"", "\"PATCH\""] {
                XCTAssertFalse(f.text.contains(verb), "\(f.name) issues \(verb)")
            }
        }
    }

    func test_forbiddenEndpointsAndPrefixFilterAreNeverUsed() throws {
        for f in try cloudSources() {
            XCTAssertFalse(f.text.contains("safety_flags"), "\(f.name) calls a per-message endpoint")
            XCTAssertFalse(f.text.contains("poll=true"), "\(f.name) long-polls")
            XCTAssertFalse(f.text.contains("hasPrefix(\"cse_\")"),
                           "\(f.name) filters on the cse_ prefix — must use environment_kind")
        }
    }
}
```

- [ ] **Step 2: Register, run the full suite, commit**

```bash
./scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessionsLogicTests AgentSessionsLogicTests/ClaudeCloudIsolationTests.swift AgentSessionsLogicTests
./scripts/xcode_test_stable.sh
git add AgentSessionsLogicTests/ClaudeCloudIsolationTests.swift AgentSessions.xcodeproj
git commit -m "test(cloud): guard read-only, no-persistence, no-prefix-filter constraints"
```

---

## Self-review notes

**Spec coverage.** §3 contract → Task 1. §3.1 `environment_kind` filter → Task 2 + guarded in
Task 4. §5 presence/row-state mapping → Tasks 2 and 3. §6 failure modes → Task 2, every state
asserted distinct. §7 privacy → no transcript code exists at all; Task 4 guards it.

**Cut from the previous revision.** Transcript store, transcript mapper, and the browsing source
view — spec §2 excludes them. The old Task 0 is complete and must not be re-run; its
`chat_conversations_v2` premise was the wrong API namespace.

**Deliberately deferred.** De-duplicating `bridge` rows against locally-indexed sessions. Not
needed while the filter is `anthropic_cloud`-only, but it becomes load-bearing the moment anyone
widens that filter — which is why Task 4 guards the prefix filter from coming back.
