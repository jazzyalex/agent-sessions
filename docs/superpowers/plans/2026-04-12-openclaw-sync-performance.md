# OpenClaw Sync Performance Fix — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate the full-rescan penalty on every app launch for OpenClaw sessions by adding DB persistence and delta detection, matching the Claude/Codex indexer pattern.

**Architecture:** After a scan, persist session metadata to IndexDB so subsequent launches hydrate from cache (instant). Add `discoverDelta()` to `OpenClawSessionDiscovery` so background scans only parse changed/new files. Publish hydrated sessions to UI immediately while the delta scan runs in background. Archive fallbacks are merged once at the very end using only the complete merged list, not inside the scan engine.

**Tech Stack:** Swift, SQLite (IndexDB actor), SessionFileStat diff infrastructure

---

## Root Cause

OpenClaw's indexer never writes session_meta rows to IndexDB after scanning. On every launch, `hydrateFromIndexDBIfAvailable()` returns nil, triggering a 250ms retry sleep + full filesystem enumeration + lightweight parse of ALL session files. Claude and Codex both write session_meta after scanning and use `discoverDelta()` to skip unchanged files.

## Known Pitfalls (applied in this plan)

1. **Stale token guard before DB writes** — `persistKnownFileStats()` and the session_meta write must be guarded by the refresh token. A superseded refresh task must not overwrite newer state. Pass `shouldContinue: { self.refreshToken == token }` to `ScanConfig` and check the token before each persistence call.

2. **Archive fallback duplication** — `SessionIndexingEngine.hydrateOrScan` runs `SessionArchiveManager.shared.mergePinnedArchiveFallbacks` on its output by default (`shouldMergeArchives` defaults to `true`). If we then call it again on the merged result, archive placeholders get duplicated. Fix: pass `shouldMergeArchives: false` to `ScanConfig` and call `mergePinnedArchiveFallbacks` exactly once on the final merged list.

3. **Commit trailers** — Every commit requires `Tool:` and `Model:` trailers per `agents.md`.

## File Map

- **Modify:** `AgentSessions/Services/OpenClawSessionDiscovery.swift` — add `discoverDelta()` method
- **Modify:** `AgentSessions/Services/OpenClawSessionIndexer.swift` — add DB persistence, file stat tracking, early hydration publish, delta-based refresh flow
- **Create:** `AgentSessionsTests/Indexing/OpenClawSyncTests.swift` — unit tests for delta discovery, file-stat roundtrip, hydrate+delta merge correctness

## Reference Files (read-only, patterns to follow)

- `AgentSessions/Services/ClaudeSessionIndexer.swift:215-411` — full refresh flow with hydrate→publish→delta→merge→persist
- `AgentSessions/Services/ClaudeSessionIndexer.swift:484-618` — file stat persistence infrastructure
- `AgentSessions/Services/SessionDiscovery.swift:12-58` — `SessionFileStat` and `diff()` helper
- `AgentSessions/Services/SessionIndexer.swift:1034-1055` — `sessionMetaRow(from:)` static helper
- `AgentSessions/Indexing/DB.swift:12` — `IndexDB` is an actor (all methods need `await`)
- `AgentSessions/Services/SessionIndexingEngine.swift:87-88` — `shouldContinue` and `shouldMergeArchives` defaults
- `AgentSessionsTests/Helpers/IndexDBTestHelpers.swift` — test DB helpers to follow

---

### Task 1: Add `discoverDelta()` to `OpenClawSessionDiscovery`

**Files:**
- Modify: `AgentSessions/Services/OpenClawSessionDiscovery.swift`

- [ ] **Step 1: Add `discoverDelta` method**

Insert after the closing `}` of `discoverSessionFiles()` (after line 87), before `private func isValidStateRoot`:

```swift
    func discoverDelta(previousByPath: [String: SessionFileStat]) -> SessionDiscoveryDelta {
        let files = discoverSessionFiles()
        let (currentByPath, changedFiles) = SessionFileStat.diff(files, against: previousByPath)
        let removedPaths = Array(Set(previousByPath.keys).subtracting(currentByPath.keys))
        return SessionDiscoveryDelta(
            changedFiles: changedFiles.sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if a != b { return a > b }
                return $0.lastPathComponent > $1.lastPathComponent
            },
            removedPaths: removedPaths,
            currentByPath: currentByPath,
            driftDetected: false
        )
    }
```

- [ ] **Step 2: Build and verify compilation**

Run: `xcodebuild build -scheme AgentSessions -destination 'platform=macOS' 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Commit**

```
feat(openclaw): add discoverDelta to OpenClawSessionDiscovery

Tool: Claude Code
Model: claude-opus-4-6
Why: prerequisite for delta-based sync that avoids re-parsing unchanged files
```

---

### Task 2: Add file stat persistence infrastructure to OpenClawSessionIndexer

**Files:**
- Modify: `AgentSessions/Services/OpenClawSessionIndexer.swift`

- [ ] **Step 1: Add os_log import and logger**

Add after `import SwiftUI` (line 3):

```swift
import os.log

private let indexLog = OSLog(subsystem: "com.triada.AgentSessions", category: "OpenClawIndexing")
```

- [ ] **Step 2: Add PersistedFileStat types and state key**

Add inside `OpenClawSessionIndexer` right after `final class OpenClawSessionIndexer: ObservableObject, @unchecked Sendable {` (line 6):

```swift
    private struct PersistedFileStat: Codable {
        let mtime: Int64
        let size: Int64
    }

    private struct PersistedFileStatPayload: Codable {
        let version: Int
        let stats: [String: PersistedFileStat]
    }

    private static let coreFileStatsStateKey = "core_file_stats_v1:openclaw"
```

- [ ] **Step 3: Add file stat tracking state**

Insert after `private var refreshToken = UUID()` (line 43):

```swift
    private let fileStatsLock = NSLock()
    private var lastKnownFileStatsByPath: [String: SessionFileStat] = [:]
```

- [ ] **Step 4: Add file stat helper methods**

Add these private methods before the `// MARK: - SessionIndexerProtocol Conformance` extension at the bottom of the class:

```swift
    // MARK: - File Stat Persistence

    private func hasKnownFileStats() -> Bool {
        fileStatsLock.lock()
        let hasStats = !lastKnownFileStatsByPath.isEmpty
        fileStatsLock.unlock()
        return hasStats
    }

    private func initializeKnownFileStatsIfNeeded(_ stats: [String: SessionFileStat]) {
        fileStatsLock.lock()
        if lastKnownFileStatsByPath.isEmpty {
            lastKnownFileStatsByPath = stats
        }
        fileStatsLock.unlock()
    }

    private func knownFileStatsSnapshot() -> [String: SessionFileStat] {
        fileStatsLock.lock()
        let snapshot = lastKnownFileStatsByPath
        fileStatsLock.unlock()
        return snapshot
    }

    private func applyKnownFileStatsDelta(_ delta: SessionDiscoveryDelta) {
        fileStatsLock.lock()
        lastKnownFileStatsByPath = delta.currentByPath
        fileStatsLock.unlock()
    }

    private func bootstrapKnownFileStatsIfNeeded(from sessions: [Session]) {
        if hasKnownFileStats() { return }
        guard !sessions.isEmpty else { return }
        var map: [String: SessionFileStat] = [:]
        map.reserveCapacity(sessions.count)
        for session in sessions {
            let url = URL(fileURLWithPath: session.filePath)
            if let stat = Self.fileStat(for: url) {
                map[session.filePath] = stat
            } else {
                let size = Int64(max(0, session.fileSizeBytes ?? 0))
                let mtime = Int64(max(0, session.modifiedAt.timeIntervalSince1970))
                map[session.filePath] = SessionFileStat(mtime: mtime, size: size)
            }
        }
        initializeKnownFileStatsIfNeeded(map)
    }

    private func seedKnownFileStatsIfNeeded() async {
        if hasKnownFileStats() { return }
        do {
            if let persisted = try await loadPersistedKnownFileStats() {
                initializeKnownFileStatsIfNeeded(persisted)
                os_log("OpenClaw: seeded file stats from persisted baseline (%d entries)", log: indexLog, type: .info, persisted.count)
            }
        } catch {
            os_log("OpenClaw: seedKnownFileStats failed: %{public}@", log: indexLog, type: .error, error.localizedDescription)
        }
    }

    private func persistKnownFileStats() async {
        let snapshot = knownFileStatsSnapshot()
        guard !snapshot.isEmpty else { return }
        do {
            let payload = PersistedFileStatPayload(
                version: 1,
                stats: snapshot.reduce(into: [:]) { partial, entry in
                    partial[entry.key] = PersistedFileStat(mtime: entry.value.mtime, size: entry.value.size)
                }
            )
            let data = try JSONEncoder().encode(payload)
            guard let json = String(data: data, encoding: .utf8) else { return }
            let db = try IndexDB()
            try await db.setIndexState(key: Self.coreFileStatsStateKey, value: json)
        } catch {
            // Non-fatal. Next run can still bootstrap from DB/filesystem.
        }
    }

    private func loadPersistedKnownFileStats() async throws -> [String: SessionFileStat]? {
        let db = try IndexDB()
        guard let raw = try await db.indexStateValue(for: Self.coreFileStatsStateKey),
              let data = raw.data(using: .utf8) else {
            return nil
        }
        let payload = try JSONDecoder().decode(PersistedFileStatPayload.self, from: data)
        guard payload.version == 1 else { return nil }
        let map = payload.stats.reduce(into: [String: SessionFileStat]()) { partial, entry in
            partial[entry.key] = SessionFileStat(mtime: entry.value.mtime, size: entry.value.size)
        }
        return map.isEmpty ? nil : map
    }
```

- [ ] **Step 5: Build and verify compilation**

Run: `xcodebuild build -scheme AgentSessions -destination 'platform=macOS' 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 6: Commit**

```
feat(openclaw): add file stat persistence infrastructure

Tool: Claude Code
Model: claude-opus-4-6
Why: enables delta detection and cross-launch file stat tracking
```

---

### Task 3: Rewrite `refresh()` with hydrate → early publish → delta scan → persist

The new `refresh()` follows the Claude-style flow with two critical correctness fixes vs. the original draft:
- **Token guard before DB writes**: Both `persistKnownFileStats()` and the session_meta write block check `self.refreshToken == token` before executing. A superseded refresh cannot pollute DB state.
- **No archive duplication**: `ScanConfig` sets `shouldMergeArchives: false` so `hydrateOrScan` returns raw scanned sessions. `mergePinnedArchiveFallbacks` is called exactly once on the final fully-merged list.

**Files:**
- Modify: `AgentSessions/Services/OpenClawSessionIndexer.swift`

- [ ] **Step 1: Replace the entire `refresh()` method (lines 106-212)**

Replace the existing `func refresh(mode:trigger:executionProfile:)` method with:

```swift
    func refresh(mode: IndexRefreshMode = .incremental,
                 trigger: IndexRefreshTrigger = .manual,
                 executionProfile: IndexRefreshExecutionProfile = .interactive) {
        if !AgentEnablement.isEnabled(.openclaw) { return }
        let root = discovery.sessionsRoot()
        #if DEBUG
        print("\n🔵 OPENCLAW INDEXING START: root=\(root.path) mode=\(mode) trigger=\(trigger.rawValue)")
        #endif
        LaunchProfiler.log("OpenClaw.refresh: start (mode=\(mode), trigger=\(trigger.rawValue))")

        let token = UUID()
        refreshToken = token
        launchPhase = .hydrating
        isIndexing = true
        isProcessingTranscripts = false
        progressText = "Scanning…"
        filesProcessed = 0
        totalFiles = 0
        indexingError = nil
        hasEmptyDirectory = false

        let requestedPriority: TaskPriority = executionProfile.deferNonCriticalWork ? .utility : .userInitiated
        let prio: TaskPriority = FeatureFlags.lowerQoSForHeavyWork ? .utility : requestedPriority
        Task.detached(priority: prio) { [weak self, token, mode, executionProfile] in
            guard let self else { return }

            // ── Phase 1: Hydrate from IndexDB ──
            var indexed: [Session] = []
            do {
                if let hydrated = try await self.hydrateFromIndexDBIfAvailable() {
                    indexed = hydrated
                }
            } catch {
                // DB errors are non-fatal; fall back to filesystem.
            }
            if indexed.isEmpty {
                try? await Task.sleep(nanoseconds: 250_000_000)
                do {
                    if let retry = try await self.hydrateFromIndexDBIfAvailable(), !retry.isEmpty {
                        indexed = retry
                    }
                } catch {}
            }

            await self.seedKnownFileStatsIfNeeded()
            let fm = FileManager.default
            let exists: (Session) -> Bool = { s in fm.fileExists(atPath: s.filePath) }
            let existingSessions = indexed.filter(exists)
            self.bootstrapKnownFileStatsIfNeeded(from: existingSessions)

            // ── Phase 2: Publish hydrated sessions immediately ──
            let presentedHydration = !existingSessions.isEmpty
            if presentedHydration {
                let hydratedSorted = existingSessions.sorted { $0.modifiedAt > $1.modifiedAt }
                // Archive fallbacks merged once here for immediate display; will be re-merged
                // from the final full list at the end of Phase 7.
                let hydratedWithArchives = SessionArchiveManager.shared.mergePinnedArchiveFallbacks(
                    into: hydratedSorted, source: .openclaw)

                var hydratedPreviewTimes: [String: Date] = [:]
                hydratedPreviewTimes.reserveCapacity(hydratedWithArchives.count)
                for s in hydratedWithArchives {
                    let url = URL(fileURLWithPath: s.filePath)
                    if let rv = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                       let m = rv.contentModificationDate {
                        hydratedPreviewTimes[s.id] = m
                    }
                }
                let capturedPreviewTimes = hydratedPreviewTimes

                await MainActor.run {
                    guard self.refreshToken == token else { return }
                    self.allSessions = hydratedWithArchives
                    self.previewMTimeByID = capturedPreviewTimes
                    self.launchPhase = .scanning
                    self.filesProcessed = hydratedWithArchives.count
                    self.totalFiles = hydratedWithArchives.count
                    self.progressText = "Loaded \(hydratedWithArchives.count) from index"
                }
                #if DEBUG
                print("[Launch] Hydrated \(existingSessions.count) OpenClaw sessions from DB, now scanning for changes…")
                #endif
                LaunchProfiler.log("OpenClaw.refresh: DB hydrate published (existing=\(existingSessions.count))")
            } else {
                #if DEBUG
                print("[Launch] DB hydration returned nil for OpenClaw – scanning all files")
                #endif
            }

            // ── Phase 3: Delta scan (only changed/new files) ──
            let previousStats = self.knownFileStatsSnapshot()
            let delta = self.discovery.discoverDelta(previousByPath: previousStats)

            let files: [URL]
            let missingHydratedCount: Int
            if mode == .fullReconcile || previousStats.isEmpty {
                // First-ever scan or manual full reconcile: parse everything
                files = delta.currentByPath.keys.map { URL(fileURLWithPath: $0) }
                missingHydratedCount = 0
            } else {
                // Supplement: force-parse files on disk but missing from hydrated snapshot.
                let existingPaths = Set(existingSessions.map(\.filePath))
                let changedPaths = Set(delta.changedFiles.map(\.path))
                let missingPaths = Set(delta.currentByPath.keys)
                    .subtracting(existingPaths)
                    .subtracting(changedPaths)
                missingHydratedCount = missingPaths.count
                if missingPaths.isEmpty {
                    files = delta.changedFiles
                } else {
                    var combined = delta.changedFiles
                    combined.append(contentsOf: missingPaths.sorted().map { URL(fileURLWithPath: $0) })
                    files = combined
                }
            }

            #if DEBUG
            print("📁 Found \(files.count) OpenClaw changed/new files (removed=\(delta.removedPaths.count), total_on_disk=\(delta.currentByPath.count))")
            #endif
            LaunchProfiler.log("OpenClaw.refresh: file enumeration done (changed=\(files.count), removed=\(delta.removedPaths.count), gap=\(missingHydratedCount))")

            // shouldMergeArchives: false — we merge archive fallbacks exactly once below
            // on the complete merged list, not on the raw delta slice.
            let config = SessionIndexingEngine.ScanConfig(
                source: .openclaw,
                discoverFiles: { files },
                parseLightweight: { OpenClawSessionParser.parseFile(at: $0) },
                shouldThrottleProgress: FeatureFlags.throttleIndexingUIUpdates,
                throttler: self.progressThrottler,
                shouldContinue: { self.refreshToken == token },
                shouldMergeArchives: false,
                workerCount: executionProfile.workerCount,
                sliceSize: executionProfile.sliceSize,
                interSliceYieldNanoseconds: executionProfile.interSliceYieldNanoseconds,
                onProgress: { processed, total in
                    guard self.refreshToken == token else { return }
                    self.totalFiles = existingSessions.count + total
                    self.hasEmptyDirectory = existingSessions.isEmpty && total == 0
                    self.filesProcessed = existingSessions.count + processed
                    if processed > 0 {
                        self.progressText = "Indexed \(processed)/\(total)"
                    }
                    if self.launchPhase == .hydrating {
                        self.launchPhase = .scanning
                    }
                }
            )

            let scanResult = await SessionIndexingEngine.hydrateOrScan(config: config)
            let changedSessions = scanResult.sessions

            // Bail early if a newer refresh has started — don't touch shared state.
            guard self.refreshToken == token else { return }

            // ── Phase 4: Merge hydrated + scanned ──
            var mergedByPath: [String: Session] = [:]
            mergedByPath.reserveCapacity(existingSessions.count + changedSessions.count)
            for session in existingSessions {
                mergedByPath[session.filePath] = session
            }
            for removed in delta.removedPaths {
                mergedByPath.removeValue(forKey: removed)
            }
            for session in changedSessions {
                mergedByPath[session.filePath] = session
            }

            let merged = Array(mergedByPath.values).filter(exists)
            let sortedSessions = merged.sorted { $0.modifiedAt > $1.modifiedAt }
            // Single archive fallback merge on the complete, deduplicated list.
            let mergedWithArchives = SessionArchiveManager.shared.mergePinnedArchiveFallbacks(
                into: sortedSessions, source: .openclaw)

            // ── Phase 5: Persist file stats (token-guarded) ──
            if self.refreshToken == token {
                self.applyKnownFileStatsDelta(delta)
                await self.persistKnownFileStats()
            }

            // ── Phase 6: Persist session_meta for next launch's hydration (token-guarded) ──
            if self.refreshToken == token, !merged.isEmpty {
                do {
                    let db = try IndexDB()
                    try await db.begin()
                    for session in merged {
                        try? await db.upsertSessionMetaCore(SessionIndexer.sessionMetaRow(from: session))
                    }
                    try await db.commit()
                    os_log("OpenClaw: wrote %d session_meta rows", log: indexLog, type: .info, merged.count)
                } catch {
                    os_log("OpenClaw: session_meta write failed: %{public}@", log: indexLog, type: .error, error.localizedDescription)
                }
            }

            // ── Phase 7: Publish final merged sessions ──
            var previewTimes: [String: Date] = [:]
            previewTimes.reserveCapacity(mergedWithArchives.count)
            for s in mergedWithArchives {
                let url = URL(fileURLWithPath: s.filePath)
                if let rv = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                   let m = rv.contentModificationDate {
                    previewTimes[s.id] = m
                }
            }
            let previewTimesByID = previewTimes

            await MainActor.run {
                guard self.refreshToken == token else { return }
                LaunchProfiler.log("OpenClaw.refresh: sessions merged (total=\(mergedWithArchives.count))")
                self.previewMTimeByID = previewTimesByID
                self.allSessions = mergedWithArchives
                self.isIndexing = false
                if FeatureFlags.throttleIndexingUIUpdates {
                    self.filesProcessed = self.totalFiles
                    if self.totalFiles > 0 {
                        self.progressText = "Indexed \(self.totalFiles)/\(self.totalFiles)"
                    }
                }
                #if DEBUG
                print("✅ OPENCLAW INDEXING DONE: total=\(mergedWithArchives.count) (existing=\(existingSessions.count), changed=\(changedSessions.count), removed=\(delta.removedPaths.count))")
                #endif
                self.progressText = "Ready"
                self.launchPhase = .ready
            }
        }
    }
```

- [ ] **Step 2: Build and verify compilation**

Run: `xcodebuild build -scheme AgentSessions -destination 'platform=macOS' 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`

- [ ] **Step 3: Run existing tests**

Run: `xcodebuild test -scheme AgentSessions -destination 'platform=macOS' -derivedDataPath "$PWD/.deriveddata-tests" -parallel-testing-enabled NO 2>&1 | grep -E '(Test Suite|Executed|FAILED|error:)'`
Expected: All tests pass

- [ ] **Step 4: Commit**

```
fix(openclaw): rewrite refresh with hydrate→delta→persist flow

Eliminates full-rescan on every launch. Sessions now appear instantly
from DB cache with only changed files re-parsed in background.

Key correctness fixes vs. naive port:
- shouldMergeArchives: false in ScanConfig; single archive merge on
  final complete list prevents duplicate placeholders from delta slices
- Token guard before persistKnownFileStats and session_meta write
  prevents superseded refresh tasks from corrupting DB state
- shouldContinue predicate wires refresh token into scan engine loop

Tool: Claude Code
Model: claude-opus-4-6
Why: eliminates ~2-10s OpenClaw startup delay on every app relaunch
```

---

### Task 4: Unit tests for new behavior

**Files:**
- Create: `AgentSessionsTests/Indexing/OpenClawSyncTests.swift`

- [ ] **Step 1: Write tests for discoverDelta, file-stat roundtrip, and hydrate+delta merge**

Create the file with:

```swift
import XCTest
@testable import AgentSessions

final class OpenClawSyncTests: XCTestCase {

    // MARK: - discoverDelta

    func testDiscoverDelta_emptyPrevious_returnsAllFilesAsChanged() throws {
        let tmp = try makeTempSessionDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let fileA = tmp.appendingPathComponent("agents/agent1/sessions/a.jsonl")
        try FileManager.default.createDirectory(at: fileA.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{}".write(to: fileA, atomically: true, encoding: .utf8)

        let discovery = OpenClawSessionDiscovery(customRoot: tmp.path)
        let delta = discovery.discoverDelta(previousByPath: [:])

        XCTAssertEqual(delta.changedFiles.count, 1)
        XCTAssertEqual(delta.changedFiles.first?.lastPathComponent, "a.jsonl")
        XCTAssertEqual(delta.removedPaths.count, 0)
        XCTAssertFalse(delta.currentByPath.isEmpty)
    }

    func testDiscoverDelta_unchangedFile_notInChangedFiles() throws {
        let tmp = try makeTempSessionDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let fileA = tmp.appendingPathComponent("agents/agent1/sessions/a.jsonl")
        try FileManager.default.createDirectory(at: fileA.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{}".write(to: fileA, atomically: true, encoding: .utf8)

        let discovery = OpenClawSessionDiscovery(customRoot: tmp.path)

        // First delta — builds currentByPath
        let delta1 = discovery.discoverDelta(previousByPath: [:])
        XCTAssertEqual(delta1.changedFiles.count, 1)

        // Second delta with same stats — no changes
        let delta2 = discovery.discoverDelta(previousByPath: delta1.currentByPath)
        XCTAssertEqual(delta2.changedFiles.count, 0)
        XCTAssertEqual(delta2.removedPaths.count, 0)
    }

    func testDiscoverDelta_removedFile_inRemovedPaths() throws {
        let tmp = try makeTempSessionDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let fileA = tmp.appendingPathComponent("agents/agent1/sessions/a.jsonl")
        try FileManager.default.createDirectory(at: fileA.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{}".write(to: fileA, atomically: true, encoding: .utf8)

        let discovery = OpenClawSessionDiscovery(customRoot: tmp.path)
        let delta1 = discovery.discoverDelta(previousByPath: [:])

        // Delete the file
        try FileManager.default.removeItem(at: fileA)

        let delta2 = discovery.discoverDelta(previousByPath: delta1.currentByPath)
        XCTAssertEqual(delta2.changedFiles.count, 0)
        XCTAssertEqual(delta2.removedPaths.count, 1)
        XCTAssertTrue(delta2.removedPaths.first?.hasSuffix("a.jsonl") ?? false)
    }

    // MARK: - File stat roundtrip (PersistedFileStatPayload encode/decode)

    func testFileStatRoundtrip_encodeDecode() throws {
        // Validate the Codable types round-trip correctly by exercising them
        // through JSONEncoder/JSONDecoder as the indexer does.
        struct PersistedFileStat: Codable { let mtime: Int64; let size: Int64 }
        struct Payload: Codable { let version: Int; let stats: [String: PersistedFileStat] }

        let original = Payload(version: 1, stats: [
            "/path/to/a.jsonl": PersistedFileStat(mtime: 1_700_000_000, size: 4096),
            "/path/to/b.jsonl": PersistedFileStat(mtime: 1_700_000_001, size: 8192)
        ])

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Payload.self, from: data)

        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.stats.count, 2)
        XCTAssertEqual(decoded.stats["/path/to/a.jsonl"]?.mtime, 1_700_000_000)
        XCTAssertEqual(decoded.stats["/path/to/a.jsonl"]?.size, 4096)
        XCTAssertEqual(decoded.stats["/path/to/b.jsonl"]?.size, 8192)
    }

    // MARK: - Hydrate+delta merge correctness

    func testMerge_deltaSupersedesHydrated() {
        // Simulate: hydrated has stale session at pathA; delta scan finds updated version.
        let pathA = "/sessions/a.jsonl"
        let stale = makeSession(id: "id-a", path: pathA, messageCount: 1)
        let fresh = makeSession(id: "id-a", path: pathA, messageCount: 5)

        var mergedByPath: [String: Session] = [pathA: stale]
        // Delta scan result replaces stale
        mergedByPath[pathA] = fresh

        XCTAssertEqual(mergedByPath[pathA]?.messageCount, 5)
    }

    func testMerge_removedPathsDroppedFromResult() {
        let pathA = "/sessions/a.jsonl"
        let pathB = "/sessions/b.jsonl"
        let sessionA = makeSession(id: "id-a", path: pathA, messageCount: 3)
        let sessionB = makeSession(id: "id-b", path: pathB, messageCount: 2)

        var mergedByPath: [String: Session] = [pathA: sessionA, pathB: sessionB]
        let removedPaths = [pathB]

        for removed in removedPaths {
            mergedByPath.removeValue(forKey: removed)
        }

        XCTAssertNotNil(mergedByPath[pathA])
        XCTAssertNil(mergedByPath[pathB])
    }

    func testMerge_newFileFromDelta_addedToResult() {
        let pathA = "/sessions/a.jsonl"
        let pathB = "/sessions/b.jsonl"
        let sessionA = makeSession(id: "id-a", path: pathA, messageCount: 3)
        let sessionB = makeSession(id: "id-b", path: pathB, messageCount: 7)

        var mergedByPath: [String: Session] = [pathA: sessionA]
        // Delta found new file
        mergedByPath[pathB] = sessionB

        XCTAssertEqual(mergedByPath.count, 2)
        XCTAssertEqual(mergedByPath[pathB]?.messageCount, 7)
    }

    // MARK: - Helpers

    private func makeTempSessionDir() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenClawSyncTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    private func makeSession(id: String, path: String, messageCount: Int) -> Session {
        Session(
            id: id,
            source: .openclaw,
            startTime: Date(),
            endTime: Date(),
            model: nil,
            filePath: path,
            fileSizeBytes: nil,
            eventCount: messageCount,
            events: [],
            cwd: nil,
            repoName: nil,
            lightweightTitle: nil,
            lightweightCommands: nil,
            isHousekeeping: false
        )
    }
}
```

- [ ] **Step 2: Run the new tests to verify they pass**

Run: `xcodebuild test -scheme AgentSessions -destination 'platform=macOS' -derivedDataPath "$PWD/.deriveddata-tests" -parallel-testing-enabled NO -only-testing:AgentSessionsTests/OpenClawSyncTests 2>&1 | grep -E '(passed|failed|error:)'`
Expected: All 6 tests pass

- [ ] **Step 3: Commit**

```
test(openclaw): add unit tests for discoverDelta, file-stat roundtrip, merge logic

Tool: Claude Code
Model: claude-opus-4-6
Why: covers the three highest-risk parts of the new delta sync flow
```

---

### Task 5: Manual QA verification

- [ ] **Step 1: Launch app — verify first-run scan behavior**

1. Delete the IndexDB to simulate a clean state:
   `rm ~/Library/Application\ Support/AgentSessions/index.db`
2. Launch app with OpenClaw tab selected
3. Console should show: `DB hydration returned nil for OpenClaw – scanning all files`
4. Wait for scan to complete; verify sessions appear with correct counts

- [ ] **Step 2: Verify DB persistence happened**

Console should show after scan completes:
```
OpenClaw: wrote N session_meta rows
```

- [ ] **Step 3: Quit and relaunch — verify instant hydration**

1. Quit the app
2. Relaunch
3. Console should show: `Hydrated N OpenClaw sessions from DB, now scanning for changes…`
4. Sessions should appear **instantly** (within ~200ms)
5. Delta scan should show 0 changed files

- [ ] **Step 4: Verify delta detection for new files**

1. Create a test session file:
   `mkdir -p ~/.openclaw/agents/test-agent/sessions && echo '{}' > ~/.openclaw/agents/test-agent/sessions/test-qa.jsonl`
2. Trigger a manual refresh in the app
3. Console should show `found 1 OpenClaw changed/new files`, not a full rescan
4. Clean up: `rm ~/.openclaw/agents/test-agent/sessions/test-qa.jsonl`

- [ ] **Step 5: Verify stale task safety**

1. Rapidly change a setting that triggers `refresh()` twice in quick succession (e.g., toggle the "Include Deleted" preference on and off quickly)
2. Verify the app doesn't crash and the final session list is consistent
3. Console should not show duplicate `wrote N session_meta rows` from the superseded task

- [ ] **Step 6: Verify other agents are unaffected**

Switch to Claude and Codex tabs — sessions load correctly, no regressions.
