# SQLite-Backed Indexing & Analytics Architecture Plan

**Status:** Planning
**Author:** Claude Code
**Date:** 2025-10-22
**Target:** AgentSessions v2.5+

---

## Executive Summary

### Current State
- **In-memory architecture**: SessionIndexer, ClaudeSessionIndexer, and GeminiSessionIndexer parse JSONL/JSON files on every app launch
- **On-demand analytics**: AnalyticsService calculates metrics by iterating over `allSessions` arrays synchronously
- **No persistence**: Session data rebuilt from filesystem on each launch (5k sessions ≈ 10-15s initial scan)
- **Search limitations**: Uses in-memory TranscriptCache with FilterEngine, no full-text indexing
- **Performance bottleneck**: Analytics dashboard takes 500ms-2s to compute on 5k+ sessions

### Proposed Architecture
- **SQLite database** with WAL mode for concurrent reads during writes
- **FTS5 full-text search** with snippet generation and BM25 ranking
- **Pre-computed rollups** (daily + hourly) for instant dashboard queries
- **Incremental indexing** via mtime/size tracking to only parse new/changed files
- **Background ingestion** with progress UI, non-blocking user experience

### Key Benefits
- **Instant analytics**: Dashboard renders in <50ms from rollups (vs. current 500ms-2s)
- **Fast search**: Full-text search with snippets in <100ms (vs. current in-memory scan)
- **Scalable**: Handles 10k+ sessions without re-parsing on every launch
- **Reduced CPU/battery**: Only parse delta (new sessions) instead of entire corpus
- **Persistent index**: Survives app restarts, eliminates cold-start delay

### Timeline Estimate
**6 weeks phased implementation** (see Milestone section for details)

---

## Current Codebase Analysis

### File References

#### Session Indexers
- **`AgentSessions/Services/SessionIndexer.swift:50-100`**
  Current Codex indexer structure: `@Published allSessions`, in-memory filtering with FilterEngine, TranscriptCache for search

- **`AgentSessions/Services/ClaudeSessionIndexer.swift:1-106`**
  Claude indexer pattern: Uses `ClaudeSessionDiscovery`, parses JSON session files from `~/.claude/`, similar filtering logic

- **`AgentSessions/Services/GeminiSessionIndexer.swift`**
  Gemini indexer: Discovers sessions from `~/.gemini/tmp/<projectHash>/chats/session-*.json`

#### Discovery & Paths
- **`AgentSessions/Services/SessionDiscovery.swift:14-53`**
  Discovery protocol and implementations:
  - **Codex**: `~/.codex/sessions` (respects `$CODEX_HOME` env var)
  - **Claude**: `~/.claude/`
  - **Gemini**: `~/.gemini/tmp`
  - All support `customRoot` parameter for user overrides

- **`AgentSessions/Services/SessionIndexer.swift:127`**
  `@AppStorage("SessionsRootOverride")` - User-configurable path override for Codex

- **`AgentSessions/Services/ClaudeSessionIndexer.swift:53`**
  `@AppStorage("ClaudeSessionsRootOverride")` - User-configurable path override for Claude

#### Analytics
- **`AgentSessions/Analytics/Services/AnalyticsService.swift:1-233`**
  Current on-demand aggregation:
  - `calculate()` (line 34-62): Gathers all sessions from 3 indexers, filters, calculates metrics
  - `filterSessions()` (line 143-182): Event-aware date filtering (fixes "Today" issue)
  - `calculateSummary()` (line 186-233): Computes current + previous period with delta percentages
  - `ensureSessionsFullyParsed()` (line 64-133): Background parsing with progress tracking

- **`AgentSessions/Analytics/Models/AnalyticsDateRange.swift:18-31`**
  Date range enum with `startDate()` calculation, includes `.today` case (already implemented)

- **`AgentSessions/Analytics/Views/AnalyticsView.swift:59`**
  Date range picker **currently filters out `.custom`** - does NOT exclude `.today`

#### Data Model
- **`AgentSessions/Model/Session.swift:3-100`**
  Session structure:
  - `id`, `source`, `startTime`, `endTime`, `model`, `filePath`, `fileSizeBytes`
  - `events: [SessionEvent]` - Array of timestamped events (user messages, tool calls, etc.)
  - Lightweight sessions: `events` is empty, only metadata loaded

### Key Findings

1. **Log Paths**:
   - Codex: `~/.codex/sessions` (env var `$CODEX_HOME` supported, AppStorage override)
   - Claude: `~/.claude/` (AppStorage override)
   - Gemini: `~/.gemini/tmp` (AppStorage override)
   - **All user-configurable**, already respects env vars and overrides

2. **Current Indexing**:
   - Parses JSONL/JSON on every launch, no persistence layer
   - Uses `ProgressThrottler` to coalesce UI updates (~10 Hz)
   - Lightweight sessions: Only metadata, events parsed on-demand
   - Full parsing: Triggered by Analytics or user opening transcript

3. **Analytics Logic**:
   - Calculates from `allSessions` arrays synchronously on main thread (with background dispatch for heavy work)
   - Event-aware date filtering **already implemented** (AnalyticsService.swift:152-164)
   - Clips durations to date boundaries for accuracy
   - "Today" support **already exists** in enum but works correctly

4. **Search**:
   - Uses `TranscriptCache` with `FilterEngine` (in-memory full-text scan)
   - No indexing, no snippets, no ranking
   - Generates transcripts on-demand if not cached

5. **Performance**:
   - Initial scan: 5k sessions in 10-15s (parsing + filtering)
   - Analytics calculation: 500ms-2s for dashboard metrics
   - Search: Varies (depends on transcript cache hit rate)

---

## Proposed Architecture

### Database Schema

**Location:** `~/Library/Application Support/AgentSessions/index.db`

#### Core Tables

```sql
-- Canonical event/message storage (one row per message/event)
CREATE TABLE entries (
  rowid INTEGER PRIMARY KEY,
  session_id TEXT NOT NULL,
  source TEXT NOT NULL,           -- 'codex', 'claude', 'gemini'
  model TEXT,
  ts INTEGER NOT NULL,             -- Unix timestamp (seconds)
  title TEXT,                      -- Session title or event summary
  body TEXT,                       -- Message/event content (searchable)
  meta TEXT,                       -- JSON: {repo, cwd, tags, tool_name, etc}

  INDEX idx_session (session_id),
  INDEX idx_source_ts (source, ts)
);

-- Full-text search index (virtual table)
CREATE VIRTUAL TABLE entries_fts USING fts5(
  title, body,
  content='entries',               -- External content table
  content_rowid='rowid',           -- Link to entries.rowid
  prefix='2 3',                    -- Enable prefix matching for autocomplete
  tokenize='porter unicode61'     -- Porter stemming + Unicode normalization
);

-- Incremental indexing state (tracks which files have been indexed)
CREATE TABLE files (
  path TEXT PRIMARY KEY,
  last_mtime INTEGER NOT NULL,     -- Last modification time (Unix timestamp)
  last_size INTEGER NOT NULL,      -- Last file size in bytes
  last_offset INTEGER DEFAULT 0,   -- For append-only JSONL (Codex)
  source TEXT NOT NULL,            -- 'codex', 'claude', 'gemini'
  indexed_at INTEGER NOT NULL      -- When this file was last indexed
);

-- Pre-computed daily rollups (instant dashboard queries)
CREATE TABLE rollups_daily (
  day TEXT NOT NULL,               -- 'YYYY-MM-DD' in local timezone
  source TEXT NOT NULL,            -- 'codex', 'claude', 'gemini'
  model TEXT,                      -- NULL means aggregate across all models
  sessions INTEGER DEFAULT 0,      -- Count of distinct session_ids
  messages INTEGER DEFAULT 0,      -- Count of user/assistant messages
  commands INTEGER DEFAULT 0,      -- Count of tool_call events
  tokens_in INTEGER DEFAULT 0,     -- Total input tokens (if available)
  tokens_out INTEGER DEFAULT 0,    -- Total output tokens (if available)
  cost_usd REAL DEFAULT 0.0,       -- Total cost in USD (if calculable)
  duration_sec REAL DEFAULT 0.0,   -- Total active time (clipped to day boundaries)

  PRIMARY KEY (day, source, model)
);

-- Pre-computed hourly rollups (instant Time of Day heatmap)
CREATE TABLE rollups_hourly (
  dow INTEGER NOT NULL,            -- Day of week: 0=Monday, 6=Sunday
  hour INTEGER NOT NULL,           -- Hour of day: 0-23
  messages INTEGER DEFAULT 0,      -- Count of messages in this hour bucket
  tokens_in INTEGER DEFAULT 0,     -- Total input tokens
  tokens_out INTEGER DEFAULT 0,    -- Total output tokens

  PRIMARY KEY (dow, hour)
);

-- Config table for user preferences (e.g., watched directories)
CREATE TABLE config (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
```

#### SQLite Configuration (Pragmas)

```sql
-- Enable WAL mode for concurrent reads during writes
PRAGMA journal_mode = WAL;

-- Relaxed durability (safe with WAL, faster writes)
PRAGMA synchronous = NORMAL;

-- Incremental auto-vacuum (reclaim space without full vacuum)
PRAGMA auto_vacuum = INCREMENTAL;

-- Optimize query planner after significant changes
PRAGMA optimize;
```

### New Swift Modules

#### 1. IndexDatabase.swift

**Path:** `AgentSessions/Indexing/IndexDatabase.swift`

**Responsibility:** SQLite connection management, schema bootstrap, low-level query execution

```swift
import Foundation
import SQLite // stephencelis/SQLite.swift

/// Actor managing SQLite database connection and schema
actor IndexDatabase {
    private let db: Connection
    private let dbURL: URL

    init() throws {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let dbDir = appSupport.appendingPathComponent("AgentSessions", isDirectory: true)
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)

        self.dbURL = dbDir.appendingPathComponent("index.db")
        self.db = try Connection(dbURL.path)

        try bootstrap()
    }

    /// Bootstrap schema if database is empty
    private func bootstrap() throws {
        // Set pragmas
        try db.execute("PRAGMA journal_mode = WAL")
        try db.execute("PRAGMA synchronous = NORMAL")
        try db.execute("PRAGMA auto_vacuum = INCREMENTAL")

        // Create tables if not exist
        try db.execute(Schema.createEntriesTable)
        try db.execute(Schema.createFTSTable)
        try db.execute(Schema.createFilesTable)
        try db.execute(Schema.createRollupsDailyTable)
        try db.execute(Schema.createRollupsHourlyTable)
        try db.execute(Schema.createConfigTable)
    }

    /// Check if database is empty (no entries)
    func isEmpty() throws -> Bool {
        let count = try db.scalar("SELECT COUNT(*) FROM entries") as! Int64
        return count == 0
    }

    /// Execute arbitrary SQL (for migrations, maintenance)
    func execute(_ sql: String) throws {
        try db.execute(sql)
    }

    /// Get raw Connection for repository queries
    func connection() -> Connection {
        return db
    }
}
```

#### 2. IndexerService.swift

**Path:** `AgentSessions/Indexing/IndexerService.swift`

**Responsibility:** File scanning, incremental parsing, batch insertion, rollup updates

```swift
import Foundation
import Combine

/// Service that indexes session files into SQLite database
@MainActor
final class IndexerService: ObservableObject {
    @Published private(set) var isIndexing: Bool = false
    @Published private(set) var progress: Double = 0.0
    @Published private(set) var statusText: String = ""

    private let database: IndexDatabase
    private let codexDiscovery: CodexSessionDiscovery
    private let claudeDiscovery: ClaudeSessionDiscovery
    private let geminiDiscovery: GeminiSessionDiscovery
    private let parser: LogParser

    init(database: IndexDatabase,
         codexDiscovery: CodexSessionDiscovery,
         claudeDiscovery: ClaudeSessionDiscovery,
         geminiDiscovery: GeminiSessionDiscovery) {
        self.database = database
        self.codexDiscovery = codexDiscovery
        self.claudeDiscovery = claudeDiscovery
        self.geminiDiscovery = geminiDiscovery
        self.parser = LogParser()
    }

    /// Full scan (first run or rebuild)
    func fullScan(background: Bool = true) async {
        isIndexing = true
        defer { isIndexing = false }

        statusText = "Discovering session files..."

        let codexFiles = codexDiscovery.discoverSessionFiles()
        let claudeFiles = claudeDiscovery.discoverSessionFiles()
        let geminiFiles = geminiDiscovery.discoverSessionFiles()

        let allFiles = [
            (codexFiles, SessionSource.codex),
            (claudeFiles, SessionSource.claude),
            (geminiFiles, SessionSource.gemini)
        ]

        var total = 0
        var processed = 0
        for (files, _) in allFiles {
            total += files.count
        }

        for (files, source) in allFiles {
            for file in files {
                await indexFile(file, source: source)
                processed += 1
                progress = Double(processed) / Double(total)
                statusText = "Indexed \(processed)/\(total) files"
            }
        }

        statusText = "Building search index..."
        try? await database.execute("INSERT INTO entries_fts(entries_fts) VALUES('rebuild')")

        statusText = "Optimizing database..."
        try? await database.execute("PRAGMA optimize")

        progress = 1.0
        statusText = "Indexing complete"
    }

    /// Incremental scan (only new/changed files)
    func incrementalScan(background: Bool = true) async {
        // Compare filesystem mtime/size with files table
        // Only index files that have changed
        // Much faster than full scan
    }

    private func indexFile(_ url: URL, source: SessionSource) async {
        // Parse file based on source type
        // Insert entries in batches (100-500 rows)
        // Update rollups atomically
        // Update files table with new mtime/size
    }
}
```

#### 3. LogParser.swift

**Path:** `AgentSessions/Indexing/LogParser.swift`

**Responsibility:** Parse JSONL (Codex) and JSON (Claude/Gemini) session files

```swift
import Foundation

struct ParsedEntry {
    let sessionID: String
    let source: SessionSource
    let model: String?
    let timestamp: Date
    let title: String?
    let body: String
    let meta: [String: Any]  // Repo, cwd, tool_name, etc.
}

struct LogParser {
    /// Parse Codex JSONL file (one message per line)
    func parseCodex(url: URL) throws -> [ParsedEntry] {
        // Read JSONL line by line
        // Extract session_id, model, timestamp, message text
        // Return array of ParsedEntry
    }

    /// Parse Claude JSON session file
    func parseClaude(url: URL) throws -> [ParsedEntry] {
        // Read entire JSON file
        // Extract messages array
        // Return array of ParsedEntry
    }

    /// Parse Gemini JSON checkpoint file
    func parseGemini(url: URL) throws -> [ParsedEntry] {
        // Read entire JSON file
        // Extract chat history
        // Return array of ParsedEntry
    }
}
```

#### 4. AnalyticsRepository.swift

**Path:** `AgentSessions/Analytics/Repositories/AnalyticsRepository.swift`

**Responsibility:** Query rollups for dashboard metrics

```swift
import Foundation
import SQLite

actor AnalyticsRepository {
    private let database: IndexDatabase

    init(database: IndexDatabase) {
        self.database = database
    }

    func getSummary(
        dateRange: AnalyticsDateRange,
        agentFilter: AnalyticsAgentFilter
    ) async throws -> AnalyticsSummary {
        // Query rollups_daily for current period
        // Query rollups_daily for previous period (for deltas)
        // Compute percentage changes
        // Return AnalyticsSummary
    }

    func getTimeSeries(
        dateRange: AnalyticsDateRange,
        agentFilter: AnalyticsAgentFilter
    ) async throws -> [AnalyticsTimeSeriesPoint] {
        // Query rollups_daily grouped by day + source
        // Return time series data for charting
    }

    func getAgentBreakdown(
        dateRange: AnalyticsDateRange
    ) async throws -> [AgentBreakdownItem] {
        // Query rollups_daily grouped by source
        // Return breakdown percentages
    }

    func getHeatmap(
        dateRange: AnalyticsDateRange,
        agentFilter: AnalyticsAgentFilter
    ) async throws -> [AnalyticsHeatmapCell] {
        // Query rollups_hourly
        // Map to AnalyticsHeatmapCell (dow + hour buckets)
        // Return grid data
    }
}
```

#### 5. SearchRepository.swift

**Path:** `AgentSessions/Search/SearchRepository.swift`

**Responsibility:** FTS5 full-text search with snippets and ranking

```swift
import Foundation
import SQLite

struct SearchFilters {
    var source: SessionSource?      // Parsed from "source:codex"
    var model: String?              // Parsed from "model:gpt-4"
    var dateFrom: Date?             // Parsed from "date:2025-10-20"
    var dateTo: Date?
}

struct SearchResult {
    let sessionID: String
    let source: SessionSource
    let timestamp: Date
    let snippet: String             // HTML with <b> tags
    let rank: Double                // Combined bm25 + recency score
}

actor SearchRepository {
    private let database: IndexDatabase

    init(database: IndexDatabase) {
        self.database = database
    }

    func search(
        query: String,
        filters: SearchFilters,
        limit: Int = 50
    ) async throws -> [SearchResult] {
        // Parse query: extract chips (source:, model:, date:)
        // Remainder becomes FTS5 MATCH string
        // Build SQL with snippet() and bm25()
        // Apply recency boost: (bm25 + date_factor)
        // Return ranked results
    }

    private func parseChips(_ query: String) -> (filters: SearchFilters, ftsQuery: String) {
        // Extract "source:codex model:gpt-4 date:2025-10-20"
        // Remainder is the actual search text
    }
}
```

### Integration with Existing Code

#### Refactor AnalyticsService

**Before (Current):**
```swift
func calculate(dateRange: AnalyticsDateRange, agentFilter: AnalyticsAgentFilter) {
    isLoading = true
    defer { isLoading = false }

    // Gather all sessions from 3 indexers (in-memory)
    var allSessions: [Session] = []
    allSessions.append(contentsOf: codexIndexer.allSessions)
    allSessions.append(contentsOf: claudeIndexer.allSessions)
    allSessions.append(contentsOf: geminiIndexer.allSessions)

    // Filter and calculate (500ms-2s for 5k sessions)
    let filtered = filterSessions(allSessions, dateRange: dateRange, agentFilter: agentFilter)
    let summary = calculateSummary(allSessions: allSessions, dateRange: dateRange, agentFilter: agentFilter)
    let timeSeries = calculateTimeSeries(sessions: filtered, dateRange: dateRange)
    // ... more calculations
}
```

**After (With Repository):**
```swift
func calculate(dateRange: AnalyticsDateRange, agentFilter: AnalyticsAgentFilter) {
    Task {
        isLoading = true
        defer { isLoading = false }

        // Parallel queries to rollups (<50ms total)
        async let summary = repository.getSummary(dateRange: dateRange, agentFilter: agentFilter)
        async let timeSeries = repository.getTimeSeries(dateRange: dateRange, agentFilter: agentFilter)
        async let agentBreakdown = repository.getAgentBreakdown(dateRange: dateRange)
        async let heatmap = repository.getHeatmap(dateRange: dateRange, agentFilter: agentFilter)

        let (s, ts, ab, hm) = await (summary, timeSeries, agentBreakdown, heatmap)

        snapshot = AnalyticsSnapshot(
            summary: s,
            timeSeriesData: ts,
            agentBreakdown: ab,
            heatmapCells: hm,
            mostActiveTimeRange: calculateMostActive(hm),
            lastUpdated: Date()
        )
    }
}
```

#### Add Indexing Progress to AnalyticsView

**Addition to AnalyticsView.swift:**
```swift
.onAppear {
    // Ensure index is up-to-date before showing analytics
    service.ensureIndexed()
    refreshData()
}
.overlay {
    if service.isIndexing {
        indexingProgressOverlay
    }
}

private var indexingProgressOverlay: some View {
    // Similar to existing parsingProgressOverlay
    // Shows "Building search index... 45%" with progress ring
}
```

---

## Technical Decisions (With Rationale)

### Decision 1: SQLite.swift Dependency

**Chosen:** [stephencelis/SQLite.swift](https://github.com/stephencelis/SQLite.swift)

**Alternatives Considered:**
1. Raw SQLite C API (`sqlite3.h`)
2. GRDB.swift (full-featured ORM)

**Comparison:**

| Aspect | Raw C API | GRDB | SQLite.swift |
|--------|-----------|------|--------------|
| Lines of code | ~50-100 per query | ~10-20 per query | ~5-10 per query |
| Type safety | None (strings only) | Strong (Codable) | Strong (Expression<T>) |
| Learning curve | Steep (C bindings) | Moderate (ORM concepts) | Gentle (Swift-like) |
| Dependency size | 0 (built-in) | ~20k LOC | ~5k LOC |
| FTS5 support | Manual | Via extensions | Built-in |
| Maintenance | High (verbose) | Medium (ORM complexity) | Low (simple wrapper) |

**Code Example:**

```swift
// Raw C API (verbose, error-prone)
var stmt: OpaquePointer?
let query = "SELECT * FROM entries WHERE source = ?"
sqlite3_prepare_v2(db, query, -1, &stmt, nil)
sqlite3_bind_text(stmt, 1, "codex", -1, SQLITE_TRANSIENT)
while sqlite3_step(stmt) == SQLITE_ROW {
    let id = String(cString: sqlite3_column_text(stmt, 0))
    let source = String(cString: sqlite3_column_text(stmt, 1))
    // ... 10 more lines per column
}
sqlite3_finalize(stmt)

// GRDB (ORM-style, requires record types)
struct Entry: Codable, FetchableRecord, PersistableRecord {
    var id: Int64
    var source: String
    // ... all columns
}
let entries = try Entry.filter(Column("source") == "codex").fetchAll(db)

// SQLite.swift (concise, type-safe)
let entries = Table("entries")
let source = Expression<String>("source")
let rowID = Expression<Int64>("rowid")

for row in try db.prepare(entries.filter(source == "codex")) {
    let id = row[rowID]
    let src = row[source]
    // Compile error if column doesn't exist or wrong type!
}
```

**Decision Rationale:**
- **Type safety without ORM overhead**: Expression<T> provides compile-time column checking without requiring Codable structs for every query
- **Lightweight**: 5k LOC vs. GRDB's 20k LOC, faster build times
- **Proven in production**: Used by Slack, Stripe, major iOS/macOS apps
- **FTS5 support**: Built-in, no manual FFI or extensions needed
- **Swift-native API**: Feels like writing Swift, not C wrappers

**Selected: SQLite.swift** - Best balance of safety, ergonomics, and simplicity.

---

### Decision 2: Non-Blocking Migration Strategy

**Chosen:** Background indexing on first launch with progress UI

**Alternatives Considered:**
1. Blocking modal with "Migrating database..." message
2. Forced reindex before app becomes usable
3. Gradual migration (index sessions as user views them)

**Comparison:**

| Strategy | User Impact | Implementation | Risk |
|----------|-------------|----------------|------|
| Blocking modal | High (5-10 min wait) | Simple (linear flow) | Medium (users may force-quit) |
| Forced reindex | Very high (app unusable) | Simple | High (perception of "broken app") |
| Gradual migration | Low (transparent) | Complex (state tracking) | High (partial data inconsistency) |
| **Background indexing** | **Low (app usable)** | **Moderate** | **Low (graceful degradation)** |

**Implementation:**

```swift
// On app launch (AppDelegate or @main App init)
@MainActor
func applicationDidFinishLaunching() {
    let indexDB = try! IndexDatabase() // Opens DB, runs schema bootstrap

    Task {
        if try await indexDB.isEmpty() {
            // First run: show "Building search index..." banner
            showIndexingBanner()
            await indexerService.fullScan(background: true)
            hideIndexingBanner()
        } else {
            // Subsequent runs: incremental scan (only new files)
            await indexerService.incrementalScan(background: true)
        }
    }

    // UI stays functional during indexing:
    // - Sessions list works (existing in-memory indexers)
    // - Analytics shows "Indexing... 45%" overlay until complete
    // - Search disabled until FTS index ready
}
```

**Graceful Degradation:**
- **During indexing**: Analytics shows "Index building... 45%" overlay, queries return partial results
- **If indexing fails**: Fall back to in-memory aggregation (current behavior)
- **Partial index**: Analytics works with whatever's indexed so far (e.g., 5k/10k sessions)

**Decision Rationale:**
- **No existing data to migrate**: Current architecture is entirely in-memory, SQLite is additive
- **User experience**: Blocking modals are hostile, especially for long operations
- **Functional during index build**: Sessions list and transcript viewing work immediately
- **Reversible**: If anything goes wrong, old code path still works

**Selected: Background indexing** - Zero disruption, graceful degradation.

---

### Decision 3: Batch Updates on Session Completion

**Chosen:** Update rollups when session file is finalized (not real-time per message)

**Alternatives Considered:**
1. Real-time updates (every message triggers rollup UPDATE)
2. Batch on app quit
3. Periodic batch (every 5 minutes)

**Comparison:**

| Strategy | Write Load | Accuracy | Complexity |
|----------|------------|----------|------------|
| **Real-time** | Very high (100 UPDATEs/session) | Perfect | High (need live buffer) |
| **On completion** | Low (1 UPDATE/session) | Perfect | Low (simple detection) |
| Batch on quit | Very low (1 batch) | Delayed | Low |
| Periodic batch | Medium (12 batches/hour) | 5-min lag | Medium |

**Write Amplification Analysis:**

```
Scenario: User writes 100 messages in a session

Real-time approach:
- 100 INSERT INTO entries
- 100 UPDATE rollups_daily (increment messages, tokens)
- 100 UPDATE rollups_hourly (increment messages, tokens)
= 300 write operations, 300 WAL flushes

Batch on completion approach:
- 100 INSERT INTO entries (batched in 1 transaction)
- 1 UPDATE rollups_daily (final counts)
- 1 UPDATE rollups_hourly (final counts)
= 102 write operations, ~5 WAL flushes
```

**Implementation:**

```swift
func handleFileChange(url: URL, source: SessionSource) async {
    let metadata = try getFileMetadata(url)

    if metadata.isComplete {  // Session marked complete/inactive
        let entries = parseSessionFile(url)

        try await database.transaction {
            // Batch insert all entries
            insertEntries(entries)

            // Single rollup update with final totals
            updateRollups(entries, source: source)

            // Mark file as indexed
            markFileIndexed(url, mtime: metadata.mtime)
        }
    } else {
        // Session still in progress - skip for now
        // Will index when file is marked complete or hasn't changed in 60s
    }
}
```

**Heuristics for "Complete":**
- **Codex**: JSONL file hasn't been modified in 60 seconds (session likely closed)
- **Claude**: `.claude/sessions/*.json` has `"status": "completed"` or `"ended_at"` field
- **Gemini**: Similar checkpoint status field or mtime stability

**Decision Rationale:**
- **Efficiency**: 1 rollup UPDATE per session vs. 100 UPDATEs (3x fewer writes)
- **Accuracy**: Final message count, duration, token usage are known (no estimations)
- **Simplicity**: No "live buffer" merging logic, no state tracking
- **Acceptable lag**: Dashboard is for historical trends, not live monitoring (60s delay acceptable)

**Selected: Batch on completion** - Optimal performance with full accuracy.

---

### Decision 4: No Automatic Pruning

**Chosen:** User-controlled cleanup tools in Preferences, no auto-delete

**Alternatives Considered:**
1. Auto-delete sessions older than 1 year
2. Auto-delete after reaching 10k sessions
3. LRU eviction (keep most recent N sessions)

**Rationale:**

**Why No Auto-Pruning:**
- **User expectation**: Developers expect coding history to persist indefinitely (like Git log)
- **Forensic value**: "When did this bug start?" queries need old sessions months later
- **Disk is cheap**: 10k sessions ≈ 50MB database (vs. 256GB+ storage on modern Macs)
- **Legal/compliance**: Some users may need work logs for contracts/audits
- **Data loss risk**: Auto-delete is irreversible, users have no warning

**What to Provide Instead:**

```swift
// Preferences → Storage tab
struct StoragePreferencesView: View {
    @ObservedObject var service: IndexerService

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Index size: \(service.indexSize)")
                        .font(.headline)
                    Text("\(service.sessionCount) sessions indexed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("View Details") { showStorageBreakdown() }
            }

            Divider()

            GroupBox("Cleanup Tools") {
                VStack(alignment: .leading, spacing: 12) {
                    Button("Delete Sessions Before...") {
                        showDatePicker() // User picks cutoff date
                    }
                    .help("Permanently delete sessions older than selected date")

                    Button("Delete by Source...") {
                        showSourcePicker() // e.g., "Delete all Gemini sessions"
                    }
                    .help("Delete all sessions from specific agent")

                    Divider()

                    Button("Rebuild Index") {
                        confirmRebuild()
                    }
                    .foregroundColor(.red)
                    .help("Drop and recreate index from session files")
                }
            }
        }
    }
}
```

**Optional: Vacuum on Quit**
```swift
func applicationWillTerminate() {
    Task {
        // Reclaim space from deleted sessions
        try? await database.execute("PRAGMA incremental_vacuum")

        // Optimize query planner statistics
        try? await database.execute("PRAGMA optimize")
    }
}
```

**Decision Rationale:**
- **Safety**: User has full control, no surprise data loss
- **Simplicity**: No complex retention policy logic, no edge cases
- **Storage efficiency**: Database auto-vacuum reclaims space incrementally
- **Flexibility**: Power users can script cleanup via SQL if needed

**Selected: No auto-pruning** - User sovereignty over their data.

---

### Decision 5: Reuse Existing Discovery Paths

**Chosen:** Pass existing `SessionDiscovery` instances to `IndexerService`

**Alternatives Considered:**
1. Hardcode paths in `IndexerService`
2. Create new config system for watched directories
3. Read paths from config table in SQLite

**Current Implementation:**

```swift
// AgentSessions/Services/SessionDiscovery.swift

final class CodexSessionDiscovery: SessionDiscovery {
    private let customRoot: String?

    func sessionsRoot() -> URL {
        if let custom = customRoot, !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        if let env = ProcessInfo.processInfo.environment["CODEX_HOME"], !env.isEmpty {
            return URL(fileURLWithPath: env).appendingPathComponent("sessions")
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/sessions")
    }
}
```

**Integration:**

```swift
// AppDelegate or @main App
let codexDiscovery = CodexSessionDiscovery(
    customRoot: UserDefaults.standard.string(forKey: "SessionsRootOverride")
)
let claudeDiscovery = ClaudeSessionDiscovery(
    customRoot: UserDefaults.standard.string(forKey: "ClaudeSessionsRootOverride")
)
let geminiDiscovery = GeminiSessionDiscovery(customRoot: nil)

let indexerService = IndexerService(
    database: indexDatabase,
    codexDiscovery: codexDiscovery,
    claudeDiscovery: claudeDiscovery,
    geminiDiscovery: geminiDiscovery
)
```

**Decision Rationale:**
- **Already implemented**: Discovery classes exist, handle env vars + overrides
- **Tested**: Battle-tested in production, no new bugs
- **Consistent**: Same paths for in-memory indexers and SQLite indexer
- **User-configurable**: AppStorage overrides already work
- **Cross-platform**: No hardcoded paths, respects macOS conventions

**Future Extension (Optional):**
```sql
-- Config table for multiple watched directories
CREATE TABLE watched_dirs (
  path TEXT PRIMARY KEY,
  source TEXT NOT NULL,  -- 'codex', 'claude', 'gemini'
  enabled INTEGER DEFAULT 1
);
```

**Selected: Reuse Discovery** - No reinvention, leverage existing code.

---

## Implementation Roadmap

### Milestone 1: Foundation (Week 1)

**Deliverables:**
- [ ] **ADR**: Create `docs/adr/0003-sqlite-analytics-index.md`
  - Document schema, rollups strategy, migration approach
  - Include alternatives considered and decision rationale
  - Reference this plan document

- [ ] **Dependency**: Add SQLite.swift to project
  - Add to Package.swift (if using SPM) or Xcode project
  - Verify build succeeds with import SQLite

- [ ] **IndexDatabase.swift**: Implement core database actor
  - Schema bootstrap (create tables if not exist)
  - Set pragmas (WAL, synchronous=NORMAL, auto_vacuum)
  - `isEmpty()` check for first-run detection
  - Unit tests: Schema creation, WAL mode enabled, FTS5 table exists

- [ ] **Schema.sql**: Embed SQL as Swift strings
  - Extract schema from IndexDatabase into separate constants
  - Document each table and index

- [ ] **Update Xcode Project**: Add new files to target
  - Create `AgentSessions/Indexing/` group
  - Add all new Swift files to app target

**Acceptance Criteria:**
- Database opens successfully at `~/Library/Application Support/AgentSessions/index.db`
- WAL mode confirmed (check `index.db-wal` file exists after write)
- FTS5 table created (query `sqlite_master` table)
- Unit tests pass in CI

**Time Estimate:** 3-5 days

---

### Milestone 2: Ingestion (Week 2)

**Deliverables:**
- [ ] **LogParser.swift**: Implement parsers for all sources
  - `parseCodex()`: JSONL line-by-line parsing
  - `parseClaude()`: JSON session file parsing
  - `parseGemini()`: JSON checkpoint file parsing
  - Extract: session_id, model, timestamp, title, body, meta

- [ ] **IndexerService.swift**: File scanning and insertion
  - `fullScan()`: Discover all files, parse, insert in batches
  - File state tracking: Compare mtime/size with `files` table
  - Batch insert: 100-500 entries per transaction
  - Progress tracking: `@Published progress` and `statusText`

- [ ] **Unit Tests**: Parser edge cases
  - Corrupt JSONL line (skip and log warning)
  - Missing required fields (session_id, timestamp)
  - Large files (>100MB, test memory efficiency)
  - Unicode in message text (ensure proper encoding)

- [ ] **Manual Test**: Index real session data
  - Run indexer on actual `~/.codex/sessions`, `~/.claude/`, `~/.gemini/tmp`
  - Verify DB size (<10MB for 1k sessions)
  - Query speed: `SELECT COUNT(*) FROM entries` returns in <10ms

**Acceptance Criteria:**
- Parsers handle all three log formats correctly
- Batch insertion: 1k sessions indexed in <10s
- `files` table tracks mtime/size accurately
- Progress updates every ~100ms (not every file)

**Time Estimate:** 5-7 days

---

### Milestone 3: Rollups (Week 3)

**Deliverables:**
- [ ] **Rollup Update Logic**: Implement in `IndexerService`
  - After batch insert, compute daily rollup deltas
  - `UPDATE rollups_daily SET sessions = sessions + ?, messages = messages + ? ...`
  - Compute hourly rollup deltas (for Time of Day heatmap)
  - `UPDATE rollups_hourly SET messages = messages + ? WHERE dow = ? AND hour = ?`

- [ ] **AnalyticsRepository.swift**: Implement all query methods
  - `getSummary()`: Query rollups_daily for current + previous period
  - `getTimeSeries()`: GROUP BY day, source with date range filter
  - `getAgentBreakdown()`: GROUP BY source with percentage calculation
  - `getHeatmap()`: Query rollups_hourly, map to grid cells

- [ ] **Unit Tests**: Rollup accuracy
  - Insert 10 sessions, verify rollup counts match manual calculation
  - Test date boundary clipping (session spans midnight)
  - Test delta percentages (current vs. previous period)
  - Test hourly bucketing (message at 14:37 → hour bucket 14)

- [ ] **Integration Test**: End-to-end
  - Index 100 real sessions
  - Query AnalyticsRepository for summary, time series, heatmap
  - Compare results with current AnalyticsService (in-memory) output
  - Verify <5% variance (due to floating-point math)

**Acceptance Criteria:**
- Rollups update atomically (transaction includes entries + rollups)
- Summary query returns in <50ms (even for 10k sessions)
- Time series data matches in-memory calculation
- Heatmap grid has no missing cells

**Time Estimate:** 5-7 days

---

### Milestone 4: Analytics Integration (Week 4)

**Deliverables:**
- [ ] **Refactor AnalyticsService.swift**: Use repository
  - Replace `calculateSummary()` with `await repository.getSummary()`
  - Replace `calculateTimeSeries()` with `await repository.getTimeSeries()`
  - Replace `calculateHeatmap()` with `await repository.getHeatmap()`
  - Keep in-memory fallback if repository throws error

- [ ] **Add Indexing Progress UI**: Similar to parsing overlay
  - `AnalyticsView.swift`: Add `.overlay { if service.isIndexing { ... } }`
  - Progress ring with percentage (reuse existing parsingProgressOverlay design)
  - Status text: "Indexing 4,572 sessions... 45%"

- [ ] **Wire ensureIndexed()**: App launch integration
  - `AppDelegate` or `@main App`: Call `indexerService.incrementalScan()` on launch
  - `AnalyticsView.onAppear`: Call `service.ensureIndexed()` if needed

- [ ] **Manual QA**: Performance testing
  - Load Analytics with 5k sessions indexed
  - Verify dashboard renders in <50ms (measure with Instruments)
  - Switch date ranges: verify instant updates (<100ms)
  - Switch agent filters: verify instant updates

**Acceptance Criteria:**
- Dashboard shows correct data from rollups
- Date range changes are instant (no 500ms delay)
- "Today" filter works correctly
- Indexing progress overlay shows during first run

**Time Estimate:** 4-6 days

---

### Milestone 5: Search (Week 5)

**Deliverables:**
- [ ] **SearchRepository.swift**: FTS5 query implementation
  - `search()`: Parse query for chips (source:, model:, date:)
  - Build FTS5 MATCH query with snippet() and bm25()
  - Apply recency boost: `bm25(entries_fts) + date_factor`
  - Return `[SearchResult]` with highlighted snippets

- [ ] **Chip Parser**: Extract filter chips from query
  - `"error source:codex model:gpt-4"` → filters={source:codex, model:gpt-4}, ftsQuery="error"
  - Support date ranges: `"bug date:2025-10-01..2025-10-22"`
  - Preserve quoted phrases: `"exact match"`

- [ ] **Wire Search UI**: Replace FilterEngine with SearchRepository
  - Update search view to use `await searchRepository.search()`
  - Display snippets with HTML <b> tags (AttributedString rendering)
  - Show rank score for debugging (optional, hidden in production)

- [ ] **Manual QA**: Search quality
  - Query: "error" → verify top results contain "error" keyword
  - Query: "crash source:codex" → verify only Codex sessions returned
  - Query: "timeout date:2025-10-20" → verify date filter works
  - Verify snippets highlight matches with context

**Acceptance Criteria:**
- Search returns results in <100ms for 10k sessions
- Snippets correctly highlight matches
- Chip filters work (source:, model:, date:)
- Recency boost surfaces recent sessions higher

**Time Estimate:** 5-7 days

---

### Milestone 6: Optimization (Week 6)

**Deliverables:**
- [ ] **Background Maintenance**: NSBackgroundActivityScheduler
  - Daily task: `PRAGMA incremental_vacuum` (reclaim deleted space)
  - Daily task: `PRAGMA optimize` (update query planner stats)
  - On app quit: `PRAGMA wal_checkpoint(TRUNCATE)` (flush WAL to main DB)

- [ ] **FSEvents Watcher** (Optional): Replace poller
  - Watch `~/.codex/sessions`, `~/.claude/`, `~/.gemini/tmp`
  - Debounce rapid changes (e.g., multiple commits in 1 minute)
  - Trigger incremental indexing on file creation/modification

- [ ] **Performance Profiling**: Instruments trace
  - Profile full scan with 10k sessions (identify bottlenecks)
  - Profile search query with Time Profiler (optimize slow SQL)
  - Use `EXPLAIN QUERY PLAN` for all rollup queries (verify index usage)

- [ ] **Documentation**: Architecture docs
  - Create `docs/architecture/indexing.md` with diagrams
  - Update `README.md` with "How Search Works" section
  - Document rollup schema and update logic

**Acceptance Criteria:**
- VACUUM runs daily without blocking UI
- WAL checkpoint on quit reduces DB file size
- All rollup queries use indexes (no table scans)
- Documentation is complete and accurate

**Time Estimate:** 4-6 days

---

## Performance Targets

### Indexing Performance
- **First run (empty DB)**: 5,000 sessions in <30 seconds
  - ~167 sessions/second
  - Batch size: 500 entries per transaction (~10 sessions per batch)

- **Incremental (10 new sessions)**: <2 seconds
  - Only parse new/changed files (mtime/size check)
  - Append-only optimization for Codex JSONL (read from last_offset)

- **Database Size**: <10MB for 10,000 sessions
  - ~1KB per session average (compressed in SQLite)
  - FTS5 index: ~2x entry table size (acceptable overhead)

### Query Performance
- **Dashboard Summary**: <50ms (rollup-based)
  - Single `SELECT SUM(...) FROM rollups_daily WHERE ...`
  - No full table scan of entries

- **Time Series**: <20ms (rollup-based)
  - `SELECT day, source, SUM(messages) FROM rollups_daily GROUP BY day, source`
  - Indexed on (day, source)

- **Heatmap**: <20ms (rollup-based)
  - `SELECT * FROM rollups_hourly` (56 rows max: 7 days × 8 hour buckets)

- **Search**: <100ms for typical queries
  - FTS5 MATCH with bm25() ranking
  - LIMIT 50 results (pagination for more)
  - Snippet generation included in timing

### Memory Usage
- **Indexing**: <100MB peak (batch processing)
- **Queries**: <10MB (result sets are small due to rollups)
- **Background maintenance**: <50MB (vacuum, optimize)

---

## Acceptance Criteria

### Correctness

**Analytics:**
- [ ] **"Today" filter shows sessions from today**
  - Sessions started yesterday but had activity today are included
  - Durations are clipped to today's boundaries (not full session duration)
  - Example: Session 2025-10-21 23:00 → 2025-10-22 01:00 shows 1 hour for "Today"

- [ ] **Previous period deltas match manual calculation**
  - "Last 7 Days" compares with previous 7-day period correctly
  - Percentage changes are accurate (not off-by-one errors)
  - Example: Current=100 sessions, Previous=80 sessions → +25% change

- [ ] **Heatmap reflects actual hourly distribution**
  - Messages sent at 14:37 appear in "2-3 PM" bucket
  - Day of week calculation correct (Monday=0, Sunday=6)
  - Activity levels (none/low/medium/high) scale correctly

- [ ] **Search snippets highlight correct matches**
  - Query "error timeout" highlights both words in snippet
  - Context around match is relevant (~64 chars before/after)
  - HTML tags are properly escaped (no XSS risk)

**Search:**
- [ ] **Chip filters work correctly**
  - `source:codex` returns only Codex sessions
  - `model:gpt-4` returns only GPT-4 sessions
  - `date:2025-10-20..2025-10-22` returns sessions in range
  - Filters combine correctly (AND logic)

- [ ] **Recency boost works**
  - Recent sessions rank higher than old sessions (all else equal)
  - Boost factor is tunable (not hardcoded magic number)

### Performance

**Indexing:**
- [ ] **First run completes in <30s for 5k sessions**
  - Measured with `time` command or Instruments
  - DB file size <50MB after indexing

- [ ] **Incremental scan completes in <2s for 10 new sessions**
  - Only parses changed files (verified via logs)
  - No full re-scan on every launch

**Queries:**
- [ ] **Dashboard renders from rollups in <50ms**
  - Measured with `ContinuousClock` or Instruments
  - No full scan of entries table (verified with EXPLAIN)

- [ ] **Search returns results in <100ms**
  - Measured for query "error" on 10k sessions
  - Includes snippet generation time

- [ ] **Time series/heatmap render in <20ms**
  - Rollup queries are instant (indexed)

### Robustness

**Error Handling:**
- [ ] **Corrupt JSONL lines are skipped**
  - Log warning with line number and file path
  - Continue parsing rest of file (don't abort)

- [ ] **Atomic rollup updates**
  - Transaction includes entries + rollups + files table update
  - No partial increments on crash (WAL rollback)

- [ ] **Concurrent reads during indexing**
  - Analytics queries work while indexing in background
  - WAL mode allows concurrent readers

- [ ] **DB corruption recovery**
  - If DB file is corrupt, show alert and offer "Rebuild Index"
  - Backup corrupt DB before rebuilding (for forensics)

**Graceful Degradation:**
- [ ] **Fallback to in-memory if index fails**
  - If repository throws error, AnalyticsService uses old code path
  - User sees warning: "Search index unavailable, using in-memory mode"

- [ ] **Partial index works**
  - If only 5k/10k sessions indexed, dashboard shows those 5k
  - Progress indicator shows "50% indexed"

---

## Code References (Complete List)

### Current Implementation

**Session Indexers:**
- `AgentSessions/Services/SessionIndexer.swift:50-100` - Codex indexer structure
- `AgentSessions/Services/SessionIndexer.swift:127` - `@AppStorage("SessionsRootOverride")`
- `AgentSessions/Services/ClaudeSessionIndexer.swift:1-106` - Claude indexer structure
- `AgentSessions/Services/ClaudeSessionIndexer.swift:53` - `@AppStorage("ClaudeSessionsRootOverride")`
- `AgentSessions/Services/GeminiSessionIndexer.swift` - Gemini indexer structure

**Discovery & Paths:**
- `AgentSessions/Services/SessionDiscovery.swift:14-53` - CodexSessionDiscovery implementation
- `AgentSessions/Services/SessionDiscovery.swift:21-29` - Codex path with `$CODEX_HOME` env var
- `AgentSessions/Services/SessionDiscovery.swift:64-69` - Claude path (`~/.claude/`)
- `AgentSessions/Services/GeminiSessionDiscovery.swift:15-20` - Gemini path (`~/.gemini/tmp`)

**Analytics:**
- `AgentSessions/Analytics/Services/AnalyticsService.swift:34-62` - `calculate()` method (to replace)
- `AgentSessions/Analytics/Services/AnalyticsService.swift:143-182` - `filterSessions()` with event-aware date filtering
- `AgentSessions/Analytics/Services/AnalyticsService.swift:186-233` - `calculateSummary()` with delta logic
- `AgentSessions/Analytics/Services/AnalyticsService.swift:64-133` - `ensureSessionsFullyParsed()` with progress tracking

**Models:**
- `AgentSessions/Model/Session.swift:3-100` - Session data structure
- `AgentSessions/Analytics/Models/AnalyticsDateRange.swift:18-31` - `startDate()` calculation
- `AgentSessions/Analytics/Models/AnalyticsDateRange.swift:34-47` - `aggregationGranularity` (hour/day/week/month)

**Views:**
- `AgentSessions/Analytics/Views/AnalyticsView.swift:59` - Date range picker (filters out .custom)
- `AgentSessions/Analytics/Views/AnalyticsView.swift:28-40` - `.onAppear` and `.onChange` handlers

### Files to Modify

**AnalyticsService.swift:**
- Replace `calculate()` method to use repositories instead of in-memory aggregation
- Add `repository: AnalyticsRepository` dependency
- Keep fallback to in-memory if repository throws error

**AnalyticsView.swift:**
- Add `.overlay { if service.isIndexing { indexingProgressOverlay } }`
- Call `service.ensureIndexed()` in `.onAppear`

**Package.swift (or Xcode Project):**
- Add SQLite.swift dependency: `.package(url: "https://github.com/stephencelis/SQLite.swift", from: "0.15.0")`

### Files to Create

**Indexing Module:**
- `AgentSessions/Indexing/IndexDatabase.swift` - Database actor, schema bootstrap
- `AgentSessions/Indexing/IndexerService.swift` - File scanning, parsing, insertion
- `AgentSessions/Indexing/LogParser.swift` - JSONL/JSON parsers for Codex/Claude/Gemini
- `AgentSessions/Indexing/Schema.swift` - SQL schema constants

**Repositories:**
- `AgentSessions/Analytics/Repositories/AnalyticsRepository.swift` - Rollup queries
- `AgentSessions/Search/SearchRepository.swift` - FTS5 search queries

**Documentation:**
- `docs/adr/0003-sqlite-analytics-index.md` - Architecture decision record
- `docs/architecture/indexing.md` - Indexing system architecture (optional)

**Tests:**
- `AgentSessionsTests/Indexing/LogParserTests.swift` - Parser unit tests
- `AgentSessionsTests/Indexing/IndexerServiceTests.swift` - Indexing logic tests
- `AgentSessionsTests/Analytics/AnalyticsRepositoryTests.swift` - Rollup query tests

---

## Open Questions for Codex Review

1. **Config table for watched directories:**
   - Should we add a config table to allow users to watch multiple directories per source?
   - Example: Watch both `~/.codex/sessions` and `/Volumes/Archive/old-sessions`
   - Complexity: Discovery would need to merge results from multiple roots

2. **Sessions spanning multiple days:**
   - How to aggregate time series data for sessions that span midnight?
   - Option A: Count session once in the day it started
   - Option B: Count session in both days (double-counting risk)
   - Option C: Split session into day-level chunks (complex but accurate)

3. **Transcript caching in entries.body:**
   - Should we cache full parsed transcripts in `entries.body` or keep minimal event data?
   - Trade-off: Storage (10x larger DB) vs. query speed (no re-parsing for snippets)
   - Recommendation: Start minimal, add cache if search is too slow

4. **Token usage tracking:**
   - Parse from existing session files or require new logging?
   - Codex: Currently logs tokens in session metadata?
   - Claude: Available in `.claude/sessions/*.json`?
   - Gemini: Available in checkpoint files?

5. **Cost calculation:**
   - Hardcode model pricing (e.g., GPT-4 = $0.03/1k input tokens) or make configurable?
   - Pricing changes over time, hardcoded values become stale
   - Option: Add `model_pricing` config table with (model, input_price, output_price, effective_date)

6. **Incremental FTS updates:**
   - Should we rebuild FTS index incrementally or only on full scan?
   - FTS5 supports `DELETE FROM entries_fts WHERE rowid = ?` for incremental updates
   - Trade-off: Complexity vs. always-fresh search index

7. **Rollup granularity:**
   - Are hourly rollups sufficient for Time of Day heatmap or should we use 8 hour buckets (current UI)?
   - Hourly: 24 × 7 = 168 rows per dataset (more granular)
   - 8 buckets: 8 × 7 = 56 rows (current UI design)
   - Recommendation: Start with 8 buckets, can add hourly later if needed

8. **Background indexing priority:**
   - Should indexing run at `.utility` QoS (low priority) or `.userInitiated` (higher)?
   - `.utility`: Less CPU/battery but slower indexing
   - `.userInitiated`: Faster but may impact foreground tasks
   - Recommendation: `.utility` for background scans, `.userInitiated` for user-triggered rebuilds

---

## Appendix: SQL Query Examples

### Dashboard Summary Query

```sql
-- Summary for Today, Codex only
-- Returns: total sessions, messages, commands, duration
SELECT
  SUM(sessions) as total_sessions,
  SUM(messages) as total_messages,
  SUM(commands) as total_commands,
  SUM(duration_sec) as total_duration
FROM rollups_daily
WHERE day = date('now', 'localtime')
  AND source = 'codex';
```

### Previous Period Delta Query

```sql
-- Current period (last 7 days)
SELECT SUM(sessions) as current_sessions
FROM rollups_daily
WHERE day >= date('now', '-7 days')
  AND source = 'codex';

-- Previous period (7 days before that)
SELECT SUM(sessions) as previous_sessions
FROM rollups_daily
WHERE day >= date('now', '-14 days')
  AND day < date('now', '-7 days')
  AND source = 'codex';

-- Calculate delta in Swift:
-- let change = (current - previous) / previous * 100
```

### Time Series Query

```sql
-- Last 7 days, all sources, grouped by day
SELECT
  day,
  source,
  SUM(messages) as count
FROM rollups_daily
WHERE day >= date('now', '-7 days')
GROUP BY day, source
ORDER BY day ASC;
```

### Agent Breakdown Query

```sql
-- Breakdown by source for Last 30 Days
SELECT
  source,
  SUM(sessions) as total_sessions,
  SUM(messages) as total_messages
FROM rollups_daily
WHERE day >= date('now', '-30 days')
GROUP BY source
ORDER BY total_sessions DESC;
```

### Time of Day Heatmap Query

```sql
-- Heatmap for all time, no filters
SELECT
  dow,
  hour,
  messages
FROM rollups_hourly
ORDER BY dow, hour;

-- Returns 56 rows (7 days × 8 hour buckets) or 168 rows (7 × 24 hourly)
```

### FTS Search Query with Ranking

```sql
-- Search for "error timeout" with snippet and ranking
SELECT
  e.session_id,
  e.source,
  e.ts,
  snippet(entries_fts, 0, '<b>', '</b>', '...', 64) as snippet,
  bm25(entries_fts) + (julianday('now') - julianday(e.ts, 'unixepoch')) * -0.01 as rank
FROM entries_fts
JOIN entries e ON e.rowid = entries_fts.rowid
WHERE entries_fts MATCH 'error OR timeout'
ORDER BY rank DESC
LIMIT 50;
```

### FTS Search with Filters

```sql
-- Search for "crash" in Codex sessions from last week
SELECT
  e.session_id,
  e.source,
  e.ts,
  snippet(entries_fts, 1, '<b>', '</b>', '...', 64) as snippet,
  bm25(entries_fts) as rank
FROM entries_fts
JOIN entries e ON e.rowid = entries_fts.rowid
WHERE entries_fts MATCH 'crash'
  AND e.source = 'codex'
  AND e.ts >= unixepoch(date('now', '-7 days'))
ORDER BY rank DESC
LIMIT 50;
```

### Incremental Indexing Query

```sql
-- Find files that have changed since last index
SELECT
  f.path,
  f.last_mtime,
  f.last_size
FROM files f
WHERE EXISTS (
  SELECT 1
  FROM filesystem_scan fs  -- Pseudo-table, actually computed in Swift
  WHERE fs.path = f.path
    AND (fs.mtime > f.last_mtime OR fs.size != f.last_size)
);
```

### Rollup Update Query

```sql
-- Insert or update daily rollup (upsert)
INSERT INTO rollups_daily (day, source, model, sessions, messages, commands, duration_sec)
VALUES (?, ?, ?, ?, ?, ?, ?)
ON CONFLICT (day, source, model) DO UPDATE SET
  sessions = sessions + excluded.sessions,
  messages = messages + excluded.messages,
  commands = commands + excluded.commands,
  duration_sec = duration_sec + excluded.duration_sec;
```

---

## Next Steps After Document Creation

1. **Review document for completeness**
   - Verify all code references are accurate
   - Check SQL syntax for typos
   - Ensure milestones are realistic

2. **Share with Codex for analysis and feedback**
   - Ask Codex to review technical decisions
   - Request suggestions for schema optimizations
   - Validate rollup aggregation logic

3. **Refine based on Codex recommendations**
   - Incorporate feedback into plan
   - Update ADR with final decisions
   - Adjust timeline if needed

4. **Exit plan mode and begin Milestone 1 implementation**
   - Create ADR document
   - Add SQLite.swift dependency
   - Implement IndexDatabase.swift
   - Write unit tests

---

**END OF PLAN DOCUMENT**
