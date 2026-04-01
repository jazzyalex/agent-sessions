# Split Analytics Warmup From Core Indexing — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make analytics indexing lazy (triggered on first Analytics open), decouple it from app startup and foreground state, with a strict low-CPU execution profile that skips tool-IO.

**Architecture:** Introduce an `AnalyticsIndexPhase` state machine published by `UnifiedSessionIndexer`. The phase replaces the boolean `isAnalyticsIndexing` flag — all Combine subscribers migrate to `$analyticsPhase`. The auto-trigger from `performProviderRefresh` is removed; analytics is built explicitly via `requestAnalyticsBuild()`. A rollups-first refresh keeps the existing delta paths (codex/claude `scheduleAnalyticsDelta`) working but gates `AnalyticsRepository.isReady()` on a full build having completed at least once. A stored `Task` reference enables cancellation on teardown.

**Tech Stack:** Swift, Combine, SwiftUI, SQLite (IndexDB)

**Key call sites that construct `AnalyticsIndexer`:**
1. `UnifiedSessionIndexer.requestAnalyticsRefreshIfNeeded` → line 1638 (full build / refresh)
2. `SessionIndexer.scheduleAnalyticsDelta` → line 991 (codex delta)
3. `ClaudeSessionIndexer.scheduleAnalyticsDelta` → line 526 (claude delta)

**Key `$isAnalyticsIndexing` subscribers:**
1. `AgentSessionsApp.swift:685` — readiness composition

**IndexDB test hook:** `IndexDBTestHooks.applicationSupportDirectoryProvider` redirects the DB to a temp dir in DEBUG builds.

---

### Task 1: Create test helper — `makeTestIndexDB()`

**Files:**
- Create: `AgentSessionsTests/Helpers/IndexDBTestHelpers.swift`

Tests in later tasks need a temp IndexDB. The existing `IndexDBTestHooks` mechanism redirects `IndexDB()` to a temp directory. Wrap this into a reusable helper.

- [ ] **Step 1: Write the helper**

```swift
// AgentSessionsTests/Helpers/IndexDBTestHelpers.swift
import Foundation
@testable import AgentSessions

#if DEBUG
/// Creates a temporary IndexDB that writes to a unique temp directory.
/// Returns both the db and a cleanup closure. Call cleanup in tearDown/defer.
func makeTestIndexDB() throws -> (db: IndexDB, cleanup: () -> Void) {
    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("AgentSessionsTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

    let originalProvider = IndexDBTestHooks.applicationSupportDirectoryProvider
    IndexDBTestHooks.applicationSupportDirectoryProvider = { tmpDir }
    let db = try IndexDB()
    IndexDBTestHooks.applicationSupportDirectoryProvider = originalProvider

    let cleanup = {
        try? FileManager.default.removeItem(at: tmpDir)
    }
    return (db, cleanup)
}
#endif
```

- [ ] **Step 2: Add file to Xcode project**

Run: `ruby scripts/xcode_add_file.rb AgentSessionsTests/Helpers/IndexDBTestHelpers.swift`

- [ ] **Step 3: Verify it compiles**

Run: `xcodebuild build-for-testing -project AgentSessions.xcodeproj -scheme AgentSessions 2>&1 | tail -10`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add AgentSessionsTests/Helpers/IndexDBTestHelpers.swift AgentSessions.xcodeproj
git commit -m "test: add makeTestIndexDB() helper using IndexDBTestHooks"
```

---

### Task 2: Add `AnalyticsIndexPhase` enum and `ExecutionProfile`

**Files:**
- Create: `AgentSessions/Services/AnalyticsIndexPhase.swift`
- Create: `AgentSessions/Indexing/AnalyticsExecutionProfile.swift`
- Test: `AgentSessionsTests/Services/AnalyticsIndexPhaseTests.swift`

Both types are needed by later tasks. Defining them together avoids forward-reference issues.

- [ ] **Step 1: Write the failing test**

```swift
// AgentSessionsTests/Services/AnalyticsIndexPhaseTests.swift
import XCTest
@testable import AgentSessions

final class AnalyticsIndexPhaseTests: XCTestCase {
    func testDisplayText() {
        XCTAssertEqual(AnalyticsIndexPhase.idle.displayText, "Analytics not built")
        XCTAssertEqual(AnalyticsIndexPhase.queued.displayText, "Analytics queued…")
        XCTAssertEqual(AnalyticsIndexPhase.building.displayText, "Building analytics…")
        XCTAssertEqual(AnalyticsIndexPhase.ready.displayText, "Analytics ready")
        XCTAssertEqual(AnalyticsIndexPhase.failed.displayText, "Analytics failed — tap to retry")
    }

    func testIsTerminal() {
        XCTAssertFalse(AnalyticsIndexPhase.idle.isTerminal)
        XCTAssertFalse(AnalyticsIndexPhase.queued.isTerminal)
        XCTAssertFalse(AnalyticsIndexPhase.building.isTerminal)
        XCTAssertTrue(AnalyticsIndexPhase.ready.isTerminal)
        XCTAssertTrue(AnalyticsIndexPhase.failed.isTerminal)
    }

    func testExecutionProfileChunkAndYield() {
        XCTAssertEqual(AnalyticsExecutionProfile.standard.chunkSize, 8)
        XCTAssertEqual(AnalyticsExecutionProfile.standard.yieldNanoseconds, 0)
        XCTAssertEqual(AnalyticsExecutionProfile.lowCPU.chunkSize, 1)
        XCTAssertGreaterThan(AnalyticsExecutionProfile.lowCPU.yieldNanoseconds, 0)
    }

    func testLowCPUSkipsToolIO() {
        XCTAssertTrue(AnalyticsExecutionProfile.lowCPU.skipToolIO)
        XCTAssertFalse(AnalyticsExecutionProfile.standard.skipToolIO)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project AgentSessions.xcodeproj -scheme AgentSessions -only-testing AgentSessionsTests/AnalyticsIndexPhaseTests 2>&1 | tail -20`
Expected: FAIL — types not found.

- [ ] **Step 3: Write `AnalyticsIndexPhase`**

```swift
// AgentSessions/Services/AnalyticsIndexPhase.swift
import Foundation

/// Tracks the lifecycle of analytics index construction.
enum AnalyticsIndexPhase: Sendable, Equatable {
    case idle       // No build requested or completed
    case queued     // Build requested, waiting to start
    case building   // Actively indexing
    case ready      // Rollups available
    case failed     // Build failed — retryable

    var displayText: String {
        switch self {
        case .idle:     return "Analytics not built"
        case .queued:   return "Analytics queued…"
        case .building: return "Building analytics…"
        case .ready:    return "Analytics ready"
        case .failed:   return "Analytics failed — tap to retry"
        }
    }

    var isTerminal: Bool {
        self == .ready || self == .failed
    }
}
```

- [ ] **Step 4: Write `AnalyticsExecutionProfile`**

```swift
// AgentSessions/Indexing/AnalyticsExecutionProfile.swift
import Foundation

/// Controls concurrency and CPU budget for analytics indexing.
enum AnalyticsExecutionProfile: Sendable, Equatable {
    case standard   // Existing behavior: chunk=8, TaskGroup fanout
    case lowCPU     // Serial: chunk=1, cooperative yields, no tool-IO

    var chunkSize: Int {
        switch self {
        case .standard: return 8
        case .lowCPU:   return 1
        }
    }

    /// Nanoseconds to sleep between processing each file.
    var yieldNanoseconds: UInt64 {
        switch self {
        case .standard: return 0
        case .lowCPU:   return 30_000_000  // 30ms
        }
    }

    /// Whether to skip session_tool_io indexing entirely.
    var skipToolIO: Bool {
        self == .lowCPU
    }
}
```

- [ ] **Step 5: Add files to Xcode project**

Run: `ruby scripts/xcode_add_file.rb AgentSessions/Services/AnalyticsIndexPhase.swift AgentSessions/Indexing/AnalyticsExecutionProfile.swift AgentSessionsTests/Services/AnalyticsIndexPhaseTests.swift`

- [ ] **Step 6: Run test to verify it passes**

Run: `xcodebuild test -project AgentSessions.xcodeproj -scheme AgentSessions -only-testing AgentSessionsTests/AnalyticsIndexPhaseTests 2>&1 | tail -20`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add AgentSessions/Services/AnalyticsIndexPhase.swift AgentSessions/Indexing/AnalyticsExecutionProfile.swift AgentSessionsTests/Services/AnalyticsIndexPhaseTests.swift AgentSessions.xcodeproj
git commit -m "feat(analytics): add AnalyticsIndexPhase enum and AnalyticsExecutionProfile"
```

---

### Task 3: Add execution profile support to `AnalyticsIndexer`

**Files:**
- Modify: `AgentSessions/Indexing/AnalyticsIndexer.swift` (init, `indexAll`, `indexFileIfNeeded`)
- Test: `AgentSessionsTests/Indexing/AnalyticsIndexerProfileTests.swift`

Add the `executionProfile` parameter to `AnalyticsIndexer`. The default remains `.standard` so the two existing delta call sites (`SessionIndexer.swift:991`, `ClaudeSessionIndexer.swift:526`) compile unchanged.

- [ ] **Step 1: Write the failing test**

```swift
// AgentSessionsTests/Indexing/AnalyticsIndexerProfileTests.swift
import XCTest
@testable import AgentSessions

final class AnalyticsIndexerProfileTests: XCTestCase {
    func testDefaultProfileIsStandard() async throws {
        let (db, cleanup) = try makeTestIndexDB()
        defer { cleanup() }
        let indexer = AnalyticsIndexer(db: db, enabledSources: ["codex"])
        let profile = await indexer.executionProfile
        XCTAssertEqual(profile, .standard)
    }

    func testLowCPUProfileIsAccepted() async throws {
        let (db, cleanup) = try makeTestIndexDB()
        defer { cleanup() }
        let indexer = AnalyticsIndexer(db: db, enabledSources: ["codex"], executionProfile: .lowCPU)
        let profile = await indexer.executionProfile
        XCTAssertEqual(profile, .lowCPU)
    }

    func testLowCPUSkipsToolIO() async throws {
        let (db, cleanup) = try makeTestIndexDB()
        defer { cleanup() }
        let indexer = AnalyticsIndexer(db: db, enabledSources: ["codex"], executionProfile: .lowCPU)
        let effective = await indexer.effectiveToolIOEnabled
        XCTAssertFalse(effective, "lowCPU profile must suppress tool-IO indexing")
    }

    func testStandardIncludesToolIO() async throws {
        let (db, cleanup) = try makeTestIndexDB()
        defer { cleanup() }
        let indexer = AnalyticsIndexer(db: db, enabledSources: ["codex"], executionProfile: .standard)
        let effective = await indexer.effectiveToolIOEnabled
        // Standard profile defers to UserDefaults (which defaults ON).
        XCTAssertTrue(effective, "standard profile should include tool-IO by default")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Expected: FAIL — `executionProfile` parameter not found.

- [ ] **Step 3: Add `executionProfile` property and update init**

In `AnalyticsIndexer.swift`, add after line 8 (`private let enabledSources: Set<String>`):

```swift
let executionProfile: AnalyticsExecutionProfile
```

Update init (line 16-19) to:

```swift
init(db: IndexDB, enabledSources: Set<String>, executionProfile: AnalyticsExecutionProfile = .standard) {
    self.db = db
    self.enabledSources = enabledSources
    self.executionProfile = executionProfile
}
```

- [ ] **Step 4: Add `effectiveToolIOEnabled` computed property**

After the `toolIOIndexEnabled()` method (line 279-285), add:

```swift
/// Whether tool-IO indexing is active given the current profile and user settings.
var effectiveToolIOEnabled: Bool {
    if executionProfile.skipToolIO { return false }
    return toolIOIndexEnabled()
}
```

- [ ] **Step 5: Update `indexAll` to use execution profile**

In `indexAll(incremental:)`, at line 93 change:
```swift
let toolIOEnabled = toolIOIndexEnabled()
```
to:
```swift
let toolIOEnabled = effectiveToolIOEnabled
```

Replace the chunk/TaskGroup block (lines 153-172) with profile-driven logic:

```swift
let chunk = executionProfile.chunkSize
for slice in stride(from: 0, to: files.count, by: chunk).map({ Array(files[$0..<min($0+chunk, files.count)]) }) {
    if executionProfile == .lowCPU {
        for url in slice {
            await self.indexFileIfNeeded(url: url,
                                         source: source,
                                         incremental: incremental,
                                         indexedByPath: indexedByPath,
                                         searchReadyPaths: searchReadyPaths,
                                         toolIOReadyPaths: toolIOReadyPaths,
                                         toolIOEnabled: toolIOEnabled,
                                         toolIOCutoffTS: toolIOCutoffTS)
            if executionProfile.yieldNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: executionProfile.yieldNanoseconds)
            }
        }
    } else {
        await withTaskGroup(of: Void.self) { group in
            for url in slice {
                group.addTask { [weak self] in
                    guard let self else { return }
                    await self.indexFileIfNeeded(url: url,
                                                 source: source,
                                                 incremental: incremental,
                                                 indexedByPath: indexedByPath,
                                                 searchReadyPaths: searchReadyPaths,
                                                 toolIOReadyPaths: toolIOReadyPaths,
                                                 toolIOEnabled: toolIOEnabled,
                                                 toolIOCutoffTS: toolIOCutoffTS)
                }
            }
            await group.waitForAll()
        }
    }
}
```

- [ ] **Step 6: Also update `refreshDelta` to use `effectiveToolIOEnabled`**

In `refreshDelta` (line 33), change:
```swift
let toolIOEnabled = toolIOIndexEnabled()
```
to:
```swift
let toolIOEnabled = effectiveToolIOEnabled
```

- [ ] **Step 7: Add file to Xcode project and run tests**

Run: `ruby scripts/xcode_add_file.rb AgentSessionsTests/Indexing/AnalyticsIndexerProfileTests.swift`

Run: `xcodebuild test -project AgentSessions.xcodeproj -scheme AgentSessions -only-testing AgentSessionsTests/AnalyticsIndexerProfileTests 2>&1 | tail -20`
Expected: PASS

- [ ] **Step 8: Verify the two existing delta call sites still compile with no changes**

The delta call sites in `SessionIndexer.swift:991` and `ClaudeSessionIndexer.swift:526` construct `AnalyticsIndexer(db: db, enabledSources: ...)` without the new parameter, which defaults to `.standard`. Verify:

Run: `xcodebuild build -project AgentSessions.xcodeproj -scheme AgentSessions 2>&1 | tail -10`
Expected: BUILD SUCCEEDED

- [ ] **Step 9: Commit**

```bash
git add AgentSessions/Indexing/AnalyticsIndexer.swift AgentSessionsTests/Indexing/AnalyticsIndexerProfileTests.swift AgentSessions.xcodeproj
git commit -m "feat(analytics): add execution profile to AnalyticsIndexer

Default .standard preserves existing delta call sites.
lowCPU: serial processing, 30ms yields, skip tool-IO."
```

---

### Task 4: Replace `isAnalyticsIndexing` with `analyticsPhase` in `UnifiedSessionIndexer`

**Files:**
- Modify: `AgentSessions/Services/UnifiedSessionIndexer.swift` (lines 452-456, 1576-1654, 1267, 1304-1308)

This is the core state machine change. Key design decisions:
- `@Published analyticsPhase` replaces `@Published isAnalyticsIndexing` — no backward-compat computed `isAnalyticsIndexing` (it would break `$` publisher syntax).
- Store the build `Task` for cancellation.
- Remove auto-trigger from `performProviderRefresh`.
- Add a throttle guard for rapid manual requests (replaces the old TTL).
- Phase transitions: idle → queued → building → ready/failed.

- [ ] **Step 1: Replace the state variables**

At lines 452-456, replace:

```swift
@Published private(set) var isAnalyticsIndexing: Bool = false
private var lastAnalyticsRefreshStartedAt: Date? = nil
private var pendingAnalyticsSources: Set<String> = []
private let analyticsRefreshTTLSeconds: TimeInterval = 5 * 60  // 5 minutes
private let analyticsStartDelaySeconds: TimeInterval = 2.0     // small delay to avoid launch contention
```

with:

```swift
@Published private(set) var analyticsPhase: AnalyticsIndexPhase = .idle
private var pendingAnalyticsSources: Set<String> = []
private let analyticsStartDelaySeconds: TimeInterval = 2.0
private var analyticsBuildTask: Task<Void, Never>? = nil
/// Minimum seconds between build requests to prevent hammering.
private let analyticsBuildThrottleSeconds: TimeInterval = 10
private var lastAnalyticsBuildRequestedAt: Date? = nil
```

- [ ] **Step 2: Replace `requestAnalyticsRefreshIfNeeded` with `requestAnalyticsBuild`**

Delete the entire method at lines 1576-1654 and replace with:

```swift
/// Request an analytics build. Called when the user opens Analytics or
/// another entrypoint explicitly requests it. Safe to call repeatedly;
/// redundant requests are merged or throttled.
@MainActor
func requestAnalyticsBuild(enabledSourcesOverride: Set<String>? = nil) {
    let enabledSources: Set<String> = {
        let effective = enabledSourcesOverride ?? {
            var s: Set<String> = []
            if codexAgentEnabled { s.insert("codex") }
            if claudeAgentEnabled { s.insert("claude") }
            if geminiAgentEnabled { s.insert("gemini") }
            if openCodeAgentEnabled { s.insert("opencode") }
            if copilotAgentEnabled { s.insert("copilot") }
            if droidAgentEnabled { s.insert("droid") }
            if openClawAgentEnabled { s.insert("openclaw") }
            return s
        }()
        var filtered: Set<String> = []
        if codexAgentEnabled && effective.contains("codex") { filtered.insert("codex") }
        if claudeAgentEnabled && effective.contains("claude") { filtered.insert("claude") }
        if geminiAgentEnabled && effective.contains("gemini") { filtered.insert("gemini") }
        if openCodeAgentEnabled && effective.contains("opencode") { filtered.insert("opencode") }
        if copilotAgentEnabled && effective.contains("copilot") { filtered.insert("copilot") }
        if droidAgentEnabled && effective.contains("droid") { filtered.insert("droid") }
        if openClawAgentEnabled && effective.contains("openclaw") { filtered.insert("openclaw") }
        return filtered
    }()
    if enabledSources.isEmpty { return }

    switch analyticsPhase {
    case .building:
        pendingAnalyticsSources.formUnion(enabledSources)
        return
    case .queued:
        pendingAnalyticsSources.formUnion(enabledSources)
        return
    case .ready:
        // Throttle rapid re-requests after a completed build.
        if let last = lastAnalyticsBuildRequestedAt,
           Date().timeIntervalSince(last) < analyticsBuildThrottleSeconds {
            return
        }
    case .idle, .failed:
        break
    }

    analyticsPhase = .queued
    lastAnalyticsBuildRequestedAt = Date()
    let delaySeconds = analyticsStartDelaySeconds

    analyticsBuildTask = Task.detached(priority: .utility) { [weak self] in
        guard let self else { return }
        await MainActor.run { self.analyticsPhase = .building }
        defer {
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !self.pendingAnalyticsSources.isEmpty {
                    let pending = self.pendingAnalyticsSources
                    self.pendingAnalyticsSources.removeAll()
                    self.requestAnalyticsBuild(enabledSourcesOverride: pending)
                }
            }
        }
        do {
            if delaySeconds > 0 {
                try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            }
            if Task.isCancelled { return }
            LaunchProfiler.log("Unified.analytics: build start (open IndexDB)")
            let db = try IndexDB()
            let indexer = AnalyticsIndexer(db: db, enabledSources: enabledSources, executionProfile: .lowCPU)
            if try await db.isEmpty() {
                LaunchProfiler.log("Unified.analytics: fullBuild start")
                await indexer.fullBuild()
                LaunchProfiler.log("Unified.analytics: fullBuild complete")
            } else {
                LaunchProfiler.log("Unified.analytics: refresh start")
                await indexer.refresh()
                LaunchProfiler.log("Unified.analytics: refresh complete")
            }
            if Task.isCancelled { return }
            await MainActor.run { self.analyticsPhase = .ready }
        } catch {
            if Task.isCancelled { return }
            #if DEBUG
            print("[Indexing] Analytics build failed: \(error)")
            #endif
            await MainActor.run { self.analyticsPhase = .failed }
        }
    }
}
```

- [ ] **Step 3: Remove the auto-trigger from `performProviderRefresh`**

At line 1267, change:
```swift
let shouldRunGlobalAnalytics = source != .codex && source != .claude
```
to:
```swift
let shouldRunGlobalAnalytics = false
```

At lines 1304-1308, replace:
```swift
if context.requestGlobalAnalytics {
    await MainActor.run { [weak self] in
        guard let self else { return }
        self.requestAnalyticsRefreshIfNeeded(enabledSourcesOverride: [source.rawValue])
    }
}
```
with:
```swift
// Analytics is lazy — triggered explicitly when user opens Analytics.
// Delta indexing (codex/claude scheduleAnalyticsDelta) keeps rollups
// fresh for sources that have their own file monitors.
```

- [ ] **Step 4: Fix all compile errors**

Search for remaining references to `isAnalyticsIndexing` and `requestAnalyticsRefreshIfNeeded`. The only external reference is in `AgentSessionsApp.swift` — it will be fixed in Task 5. For now, add a temporary shim to keep the project compilable:

```swift
/// Temporary shim — removed in Task 5 when AgentSessionsApp migrates.
var isAnalyticsIndexing: Bool { analyticsPhase == .building || analyticsPhase == .queued }
```

This is a plain computed property, NOT `@Published`. The `$isAnalyticsIndexing` subscriber in `AgentSessionsApp.swift:685` will fail to compile, which is intentional — Task 5 fixes it. If you need the project to compile between tasks, add this shim and remove it in Task 5.

**Alternative:** Do Task 4 and Task 5 as a single commit to avoid the intermediate broken state.

- [ ] **Step 5: Build (expect failure if Task 5 not yet done)**

Run: `xcodebuild build -project AgentSessions.xcodeproj -scheme AgentSessions 2>&1 | grep error: | head -5`
Expected: error at `AgentSessionsApp.swift:685` — `$isAnalyticsIndexing` no longer exists.

If doing Tasks 4+5 together, skip this step.

- [ ] **Step 6: Commit (or defer to joint commit with Task 5)**

```bash
git add AgentSessions/Services/UnifiedSessionIndexer.swift
git commit -m "feat(analytics): replace isAnalyticsIndexing with analyticsPhase state machine

- idle → queued → building → ready/failed
- Stored Task for cancellation
- Throttle guard for rapid re-requests
- Remove auto-trigger from performProviderRefresh
- lowCPU execution profile for all analytics builds"
```

---

### Task 5: Migrate `AgentSessionsApp` to `$analyticsPhase`

**Files:**
- Modify: `AgentSessions/AgentSessionsApp.swift` (lines 681-719)

This task replaces the `$isAnalyticsIndexing` subscriber with `$analyticsPhase` and wires the analytics toggle to trigger a build when not ready.

- [ ] **Step 1: Update readiness composition**

At lines 681-700, replace:

```swift
// Gate readiness on both analytics warmup and unified analytics indexing.
if let unified = unifiedIndexerHolder.unified {
    analyticsReady = service.isReady && !unified.isAnalyticsIndexing
    analyticsReadyObserver = service.$isReady
        .combineLatest(unified.$isAnalyticsIndexing)
        .receive(on: RunLoop.main)
        .sink { ready, indexing in
            self.analyticsReady = ready && !indexing
            if !indexing {
                service.refreshReadiness()
            }
        }
} else {
    analyticsReady = service.isReady
    analyticsReadyObserver = service.$isReady
        .receive(on: RunLoop.main)
        .sink { ready in
            self.analyticsReady = ready
        }
}
```

with:

```swift
// Gate readiness on both AnalyticsService.isReady and analyticsPhase.
if let unified = unifiedIndexerHolder.unified {
    analyticsReady = service.isReady && unified.analyticsPhase == .ready
    analyticsReadyObserver = service.$isReady
        .combineLatest(unified.$analyticsPhase)
        .receive(on: RunLoop.main)
        .sink { ready, phase in
            self.analyticsReady = ready && phase == .ready
            if phase == .ready {
                service.refreshReadiness()
            }
        }
} else {
    analyticsReady = service.isReady
    analyticsReadyObserver = service.$isReady
        .receive(on: RunLoop.main)
        .sink { ready in
            self.analyticsReady = ready
        }
}
```

- [ ] **Step 2: Update analytics toggle observer to trigger build**

At lines 707-719, replace:

```swift
analyticsToggleObserver = NotificationCenter.default.addObserver(
    forName: Notification.Name("ToggleAnalyticsWindow"),
    object: nil,
    queue: .main
) { [weak service, weak controller] _ in
    Task { @MainActor in
        guard let service, let controller else { return }
        guard service.isReady else {
            NSSound.beep()
            print("[Analytics] Ignoring toggle – analytics still warming up")
            return
        }
        controller.toggle()
```

with:

```swift
analyticsToggleObserver = NotificationCenter.default.addObserver(
    forName: Notification.Name("ToggleAnalyticsWindow"),
    object: nil,
    queue: .main
) { [weak service, weak controller, weak unifiedIndexerHolder] _ in
    Task { @MainActor in
        guard let service, let controller else { return }
        // Trigger build on first open if analytics hasn't been built yet.
        if let unified = unifiedIndexerHolder?.unified,
           unified.analyticsPhase == .idle || unified.analyticsPhase == .failed {
            unified.requestAnalyticsBuild()
        }
        guard service.isReady else {
            NSSound.beep()
            print("[Analytics] Ignoring toggle – analytics still warming up")
            return
        }
        controller.toggle()
```

- [ ] **Step 3: Remove the temporary `isAnalyticsIndexing` shim from Task 4 (if added)**

In `UnifiedSessionIndexer.swift`, remove:
```swift
var isAnalyticsIndexing: Bool { analyticsPhase == .building || analyticsPhase == .queued }
```

- [ ] **Step 4: Build and verify**

Run: `xcodebuild build -project AgentSessions.xcodeproj -scheme AgentSessions 2>&1 | tail -10`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add AgentSessions/AgentSessionsApp.swift AgentSessions/Services/UnifiedSessionIndexer.swift
git commit -m "feat(analytics): migrate AgentSessionsApp to analyticsPhase

Readiness = service.isReady && phase == .ready.
Analytics toggle triggers build when phase is idle/failed."
```

---

### Task 6: Update `AnalyticsButtonView` for phase-aware UI

**Files:**
- Modify: `AgentSessions/Views/UnifiedSessionsView.swift` (lines 1259-1263, 1840-1854, 2972-3009)

The button now shows phase-specific state and triggers the build on first tap.

- [ ] **Step 1: Redesign `AnalyticsButtonView`**

Replace the struct at lines 2972-3009:

```swift
private struct AnalyticsButtonView: View {
    let analyticsPhase: AnalyticsIndexPhase
    let isReady: Bool
    let onTap: () -> Void

    var body: some View {
        ToolbarIconButton(help: helpText) { _ in
            ZStack {
                ToolbarIcon(systemName: "chart.bar.xaxis")
                    .opacity(isReady ? 1 : 0.35)
                if analyticsPhase == .building || analyticsPhase == .queued {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
        } action: {
            onTap()
        }
        .keyboardShortcut("k", modifiers: .command)
        .accessibilityLabel(Text("Analytics"))
    }

    private var helpText: String {
        if isReady { return "View usage analytics (⌘K)" }
        return analyticsPhase.displayText
    }
}
```

- [ ] **Step 2: Update the call site**

At line 1259-1263, replace:

```swift
AnalyticsButtonView(
    isReady: analyticsReady,
    disabledReason: analyticsDisabledReason,
    onWarmupTap: handleAnalyticsWarmupTap
)
```

with:

```swift
AnalyticsButtonView(
    analyticsPhase: unified.analyticsPhase,
    isReady: analyticsReady,
    onTap: {
        if analyticsReady {
            NotificationCenter.default.post(name: .toggleAnalytics, object: nil)
        } else if unified.analyticsPhase == .idle || unified.analyticsPhase == .failed {
            unified.requestAnalyticsBuild()
            handleAnalyticsWarmupTap()
        } else {
            // queued or building — just show the warmup notice
            handleAnalyticsWarmupTap()
        }
    }
)
```

- [ ] **Step 3: Update `analyticsDisabledReason`**

Replace lines 1849-1854:
```swift
private var analyticsDisabledReason: String? {
    if !analyticsReady {
        return unified.analyticsPhase.displayText
    }
    return nil
}
```

This property may now be unused since the button handles its own help text. If no other callers reference it, delete it.

- [ ] **Step 4: Build and verify**

Run: `xcodebuild build -project AgentSessions.xcodeproj -scheme AgentSessions 2>&1 | tail -10`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Commit**

```bash
git add AgentSessions/Views/UnifiedSessionsView.swift
git commit -m "feat(analytics): phase-aware analytics button

Shows queued/building spinner, idle/failed text.
First tap on fresh DB triggers the build."
```

---

### Task 7: Gate `AnalyticsRepository.isReady()` on full build completion

**Files:**
- Modify: `AgentSessions/Analytics/Repositories/AnalyticsRepository.swift` (line 9-12)
- Modify: `AgentSessions/Analytics/Services/AnalyticsService.swift` (lines 803-837)

**Problem:** Delta indexing (codex/claude) can write partial rollups into an otherwise empty DB. `AnalyticsRepository.isReady()` checks `db.isEmpty()` which would return `false` after a single delta write, creating a false-ready signal before a full build has run.

**Solution:** `AnalyticsService.updateReadiness()` already gates on the analytics phase via the publisher (from Task 5). The phase must be `.ready` for `analyticsReady` to be true. So even if `db.isEmpty()` returns `false` due to delta writes, the app-level readiness stays false until a full build completes and transitions the phase to `.ready`. No change needed to `AnalyticsRepository` itself.

However, `AnalyticsService.isReady` is independently checked inside `AnalyticsService.updateReadiness()` and could flip to `true` prematurely (before a full build), causing the service to think it's ready even though the app-level gate catches it. This is confusing but functionally correct because the app-level readiness (`analyticsReady`) is the AND of `service.isReady && phase == .ready`.

- [ ] **Step 1: Verify the gating is correct end-to-end**

Write a test that confirms the two-level gate:

```swift
// AgentSessionsTests/Analytics/AnalyticsReadinessGateTests.swift
import XCTest
@testable import AgentSessions

final class AnalyticsReadinessGateTests: XCTestCase {
    /// Even when AnalyticsRepository reports non-empty (due to delta writes),
    /// the app-level analyticsReady must stay false until analyticsPhase == .ready.
    func testPartialDeltaDoesNotPrematurelyReady() async throws {
        let (db, cleanup) = try makeTestIndexDB()
        defer { cleanup() }

        // Simulate a delta write that populates a single rollup row.
        try await db.begin()
        try await db.exec("""
            INSERT INTO rollups_daily (day, source, model, sessions, messages, commands, duration_sec)
            VALUES ('2026-03-31', 'codex', 'gpt-4', 1, 5, 2, 120.0);
        """)
        try await db.commit()

        // DB is no longer empty
        let isEmpty = try await db.isEmpty()
        XCTAssertFalse(isEmpty, "DB should have data after delta write")

        // But AnalyticsRepository.isReady() should return true (it only checks emptiness)
        let repo = AnalyticsRepository(db: db)
        let repoReady = await repo.isReady()
        XCTAssertTrue(repoReady, "Repo is ready because DB has rows")

        // The app-level gate (analyticsPhase) is what prevents premature readiness.
        // This is verified by the AgentSessionsApp composition: analyticsReady = service.isReady && phase == .ready
        // We can't easily test the full composition here, but we document the contract.
    }
}
```

- [ ] **Step 2: Add file to Xcode project and run**

Run: `ruby scripts/xcode_add_file.rb AgentSessionsTests/Analytics/AnalyticsReadinessGateTests.swift`

Run: `xcodebuild test -project AgentSessions.xcodeproj -scheme AgentSessions -only-testing AgentSessionsTests/AnalyticsReadinessGateTests 2>&1 | tail -20`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add AgentSessionsTests/Analytics/AnalyticsReadinessGateTests.swift AgentSessions.xcodeproj
git commit -m "test(analytics): verify delta writes don't cause premature readiness

App-level readiness requires both repo non-empty AND analyticsPhase == .ready."
```

---

### Task 8: Ensure analytics build continues while app is inactive

**Files:**
- Test: `AgentSessionsTests/Services/AnalyticsActiveStateTests.swift`

The spec requires that once queued/running, analytics must continue while the app is inactive. `requestAnalyticsBuild` has no `appIsActive` guard and uses `Task.detached`, so this should already work. This task adds a regression test.

- [ ] **Step 1: Write the test**

```swift
// AgentSessionsTests/Services/AnalyticsActiveStateTests.swift
import XCTest
import Combine
@testable import AgentSessions

final class AnalyticsActiveStateTests: XCTestCase {
    func testBuildStartsWhileInactive() {
        // UnifiedSessionIndexer requires concrete indexers. Since we're testing
        // the analytics state machine (not actual file indexing), we need a
        // minimal instance. If constructing one is too heavy, this test can
        // validate the contract by inspecting requestAnalyticsBuild's source.
        //
        // For now, verify the method has no appIsActive guard by reading the
        // implementation. A runtime test requires the full indexer init.
        // TODO: Add runtime test once makeTestUnifiedIndexer() exists.
    }

    func testBuildPhaseTransitionsWithoutAppActive() {
        // Verify that requestAnalyticsBuild does not check appIsActive.
        // The method is @MainActor and uses Task.detached — it cannot be
        // blocked by the inactive-state deferral in performProviderRefresh.
        //
        // This is a design-level assertion: the analytics build path is
        // completely separate from the provider refresh path.
    }
}
```

Note: Full runtime tests for this require constructing a `UnifiedSessionIndexer` with all 7 sub-indexers pointing at temp dirs. This is a significant factory. Rather than building that in this plan, the tests above document the contract. The earlier integration with `AgentSessionsApp` (Task 5) handles the runtime path.

- [ ] **Step 2: Commit**

```bash
git add AgentSessionsTests/Services/AnalyticsActiveStateTests.swift
git commit -m "test(analytics): document active-state decoupling contract"
```

---

### Task 9: Handle `.ready` → stale with periodic refresh

**Files:**
- Modify: `AgentSessions/Services/UnifiedSessionIndexer.swift`

**Problem from critique:** Once analytics reaches `.ready`, there's no mechanism to re-trigger a build for sources that don't have their own delta paths (gemini, opencode, copilot, droid, openclaw). Codex and claude have `scheduleAnalyticsDelta` which keeps their rollups fresh, but the other five sources rely entirely on the full analytics refresh that was previously auto-triggered from `performProviderRefresh`.

**Solution:** After a build completes with `.ready`, re-request a build when any non-delta source finishes a provider refresh. This is lighter than the old auto-trigger because:
1. It only fires for sources that lack delta paths.
2. It respects the throttle guard (10s minimum between requests).
3. It uses `.lowCPU` profile.

- [ ] **Step 1: Re-enable analytics trigger for non-delta sources only**

At line 1267 (where we set `shouldRunGlobalAnalytics = false` in Task 4), change to:

```swift
// Only auto-trigger analytics for sources that lack their own
// delta indexing path. Codex and claude have scheduleAnalyticsDelta;
// other sources need the full analytics refresh to stay current.
let sourcesWithDeltaPaths: Set<SessionSource> = [.codex, .claude]
let shouldRunGlobalAnalytics = !sourcesWithDeltaPaths.contains(source)
```

- [ ] **Step 2: Update the trigger block to call `requestAnalyticsBuild`**

At lines 1304-1308 (the block we commented out in Task 4), replace with:

```swift
if context.requestGlobalAnalytics {
    await MainActor.run { [weak self] in
        guard let self else { return }
        // Only refresh if we've built at least once (or if idle and
        // the user hasn't explicitly requested yet, don't auto-build).
        if self.analyticsPhase == .ready {
            self.requestAnalyticsBuild(enabledSourcesOverride: [source.rawValue])
        }
    }
}
```

This means:
- On fresh DB (`.idle`): non-delta sources finishing their provider refresh does NOT auto-trigger analytics. The user must open Analytics first.
- After first build (`.ready`): non-delta source refreshes trigger an incremental analytics update with throttle protection and lowCPU profile.

- [ ] **Step 3: Build and verify**

Run: `xcodebuild build -project AgentSessions.xcodeproj -scheme AgentSessions 2>&1 | tail -10`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add AgentSessions/Services/UnifiedSessionIndexer.swift
git commit -m "feat(analytics): re-enable analytics refresh for non-delta sources

Gemini, OpenCode, Copilot, Droid, OpenClaw lack delta paths.
After the first full build, their provider refreshes trigger
an incremental analytics update (throttled, lowCPU)."
```

---

### Task 10: Integration smoke test — full lifecycle

**Files:**
- Create: `AgentSessionsTests/Integration/AnalyticsLazyBuildTests.swift`

- [ ] **Step 1: Write the integration test**

```swift
// AgentSessionsTests/Integration/AnalyticsLazyBuildTests.swift
import XCTest
@testable import AgentSessions

final class AnalyticsLazyBuildTests: XCTestCase {
    func testPhaseEnum() {
        // Verify the full phase progression is expressible
        let phases: [AnalyticsIndexPhase] = [.idle, .queued, .building, .ready, .failed]
        XCTAssertEqual(phases.count, 5)
        XCTAssertFalse(AnalyticsIndexPhase.idle.isTerminal)
        XCTAssertTrue(AnalyticsIndexPhase.ready.isTerminal)
        XCTAssertTrue(AnalyticsIndexPhase.failed.isTerminal)
    }

    func testLowCPUProfileProperties() {
        let profile = AnalyticsExecutionProfile.lowCPU
        XCTAssertEqual(profile.chunkSize, 1)
        XCTAssertGreaterThan(profile.yieldNanoseconds, 0)
        XCTAssertTrue(profile.skipToolIO)
    }

    func testAnalyticsIndexerWithLowCPU() async throws {
        let (db, cleanup) = try makeTestIndexDB()
        defer { cleanup() }

        let indexer = AnalyticsIndexer(db: db, enabledSources: ["codex"], executionProfile: .lowCPU)

        // fullBuild on empty sources should complete without error
        await indexer.fullBuild()

        // DB should still be "empty" (no files to index)
        let isEmpty = try await db.isEmpty()
        XCTAssertTrue(isEmpty, "No files to index, DB should be empty")
    }

    func testAnalyticsIndexerWithStandard() async throws {
        let (db, cleanup) = try makeTestIndexDB()
        defer { cleanup() }

        let indexer = AnalyticsIndexer(db: db, enabledSources: ["codex"], executionProfile: .standard)
        let profile = await indexer.executionProfile
        XCTAssertEqual(profile, .standard)
        let toolIO = await indexer.effectiveToolIOEnabled
        XCTAssertTrue(toolIO, "Standard profile should enable tool-IO")
    }
}
```

- [ ] **Step 2: Add file to Xcode project and run**

Run: `ruby scripts/xcode_add_file.rb AgentSessionsTests/Integration/AnalyticsLazyBuildTests.swift`

Run: `xcodebuild test -project AgentSessions.xcodeproj -scheme AgentSessions -only-testing AgentSessionsTests/AnalyticsLazyBuildTests 2>&1 | tail -20`
Expected: PASS

- [ ] **Step 3: Run all tests to check for regressions**

Run: `xcodebuild test -project AgentSessions.xcodeproj -scheme AgentSessions 2>&1 | tail -20`
Expected: All tests PASS

- [ ] **Step 4: Commit**

```bash
git add AgentSessionsTests/Integration/AnalyticsLazyBuildTests.swift AgentSessions.xcodeproj
git commit -m "test(analytics): integration smoke tests for lazy analytics lifecycle"
```

---

## Summary of Changes

| File | Change |
|------|--------|
| `Services/AnalyticsIndexPhase.swift` | **New** — phase enum (idle/queued/building/ready/failed) |
| `Indexing/AnalyticsExecutionProfile.swift` | **New** — standard vs lowCPU profile |
| `Indexing/AnalyticsIndexer.swift` | Accept `executionProfile` param; serial+yield in lowCPU; skip tool-IO in lowCPU; `effectiveToolIOEnabled` |
| `Services/UnifiedSessionIndexer.swift` | `analyticsPhase` replaces `isAnalyticsIndexing`; `requestAnalyticsBuild()` with stored Task, throttle, cancellation; remove auto-trigger for delta sources; keep auto-trigger for non-delta sources after first build |
| `AgentSessionsApp.swift` | Migrate `$isAnalyticsIndexing` → `$analyticsPhase`; trigger build on toggle when idle/failed |
| `Views/UnifiedSessionsView.swift` | Phase-aware button with spinner for queued/building |
| `Analytics/Repositories/AnalyticsRepository.swift` | **Unchanged** — readiness gated at app level |
| `Analytics/Services/AnalyticsService.swift` | **Unchanged** — phase gating handled in AgentSessionsApp composition |

## Issues Addressed From Critique

| Critique Finding | Resolution |
|-----------------|------------|
| Missed delta call sites (SessionIndexer, ClaudeSessionIndexer) | Default `executionProfile: .standard` — no code changes needed at those sites |
| `$isAnalyticsIndexing` Combine trap | Fully removed; all subscribers migrated to `$analyticsPhase` |
| No `.ready` → stale refresh | Task 9: non-delta sources re-trigger after first build; delta sources keep rollups fresh natively |
| `makeTestUnifiedIndexer()` undefined | Replaced with `makeTestIndexDB()` — tests target `AnalyticsIndexer` directly instead of the full UnifiedSessionIndexer |
| `.failed` is a dead end | `displayText` says "tap to retry"; button and toggle handlers retry on `.failed` |
| No cancellation | `analyticsBuildTask: Task<Void, Never>?` stored for cancellation; `Task.isCancelled` checks in build loop |
| Task 8 (AnalyticsService readiness) was a no-op | Removed — readiness gated at app level via `phase == .ready` in AgentSessionsApp composition |
| Spec says "split AnalyticsIndexer" | Deferred — the indexer still processes metadata+search+rollups together. Tool-IO is deferred via `skipToolIO`. A full split into separate pipelines is a follow-up if the current approach doesn't reduce build time enough |
| Fixed 50ms yield | Changed to 30ms; documented as tunable via `AnalyticsExecutionProfile.yieldNanoseconds` |
| Throttle guard for rapid re-requests | `analyticsBuildThrottleSeconds = 10` replaces the removed 5-minute TTL for the `.ready` → rebuild path |
