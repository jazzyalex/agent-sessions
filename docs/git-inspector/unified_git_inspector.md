# Unified Git/Session Inspector Analysis

## Critical Insight: Two Features, One Problem

### Claude Code's Proposal: Historical Git View
**Focus:** What was the git state when the session was created?
- Data: Session file metadata (branch, commit hash, cwd at session start)
- Performance: Zero overhead (read from file)
- Use case: "What context was this agent working in?"

### Your Proposal: Live Session Inspector  
**Focus:** What is the current git state if I resume now?
- Data: Live git commands (current branch, dirty status, behind/ahead)
- Performance: ~50ms local queries
- Use case: "Is it safe to resume? What changed?"

### The Real Need: BOTH Together

Users actually want to know:
1. **What was the session context?** (historical)
2. **What is it now?** (current)  
3. **What changed?** (comparison) ← This is the killer feature

---

## Unified Design: "Session Git Inspector"

### Core Concept
Show BOTH historical snapshot AND current state, highlighting differences.

```
┌─────────────────────────────────────────────────────┐
│  Git Context: analyze codebase for optimization     │
├─────────────────────────────────────────────────────┤
│                                                     │
│  WHEN SESSION WAS CREATED (2h ago)                 │
│  Branch:      feature/perf-improvements            │
│  Commit:      2f8a9c1 "feat: improve indexing"     │
│  Status:      Clean                                 │
│  Behind:      2 commits (at session start)         │
│                                                     │
│  ───────────────────────────────────────────────   │
│                                                     │
│  CURRENT STATE                                      │
│  Branch:      feature/perf-improvements ✓ Same     │
│  Commit:      2f8a9c1 ✓ No new commits             │
│  Status:      ⚠️ Dirty (3 files changed)           │
│  Behind:      ↓ 2 commits (cached 45m ago)         │
│                                                     │
│  ───────────────────────────────────────────────   │
│                                                     │
│  ⚠️ RESUME SAFETY CHECK                             │
│  • Branch unchanged ✓                              │
│  • No new commits locally ✓                        │
│  • Uncommitted changes detected ⚠️                  │
│                                                     │
│  💡 Recommendation: Review changes before resuming │
│                                                     │
│  [View Changes] [Resume Anyway] [Open Dir]         │
└─────────────────────────────────────────────────────┘
```

This gives users:
- ✓ Historical context (from session file)
- ✓ Current state (from live git)
- ✓ Safety analysis (comparison)
- ✓ Actionable recommendation

---

## Data Sources Strategy

### Tier 1: Session File (Always Available, Instant)
```swift
struct HistoricalGitContext {
    let branchAtStart: String?      // From session.repoDisplay or events
    let commitAtStart: String?      // Codex: from metadata, Claude: parse events
    let cwdAtStart: String          // From session.cwd
    let wasClean: Bool?             // Codex: from metadata
    let sessionCreated: Date        // From session.modifiedAt
}
```

**Extraction logic:**
- Codex: `session.payload.git.branch`, `session.payload.git.commit_hash`
- Claude: Parse first few events for working directory mentions
- Gemini: Graceful degradation (show "Git info not available")

### Tier 2: Live Local Git (Fast, ~50ms)
```swift
struct CurrentGitContext {
    let branchNow: String?          // git rev-parse --abbrev-ref HEAD
    let commitNow: String?          // git rev-parse HEAD
    let isDirty: Bool               // git status --porcelain
    let dirtyFiles: [String]        // List of modified files
    let lastCommitMessage: String?  // git log -1 --pretty=%s
}
```

### Tier 3: Cached Remote (Instant, may be stale)
```swift
struct RemoteContext {
    let behindCount: Int?           // git rev-list --count origin/main...HEAD
    let aheadCount: Int?            
    let lastFetchTime: Date?        // From git reflog
}
```

### Tier 4: Live Remote (Optional, 200ms-2s)
User-triggered refresh button to run `git fetch origin`.

---

## Comparison Logic

```swift
struct SafetyCheck {
    enum Status {
        case safe           // Same branch, no changes
        case caution        // Same branch, uncommitted changes
        case warning        // Different branch or new commits
        case unknown        // Can't determine (no git access)
    }
    
    let status: Status
    let messages: [String]
    let recommendation: String
}

func analyzeSafety(historical: HistoricalGitContext, 
                   current: CurrentGitContext) -> SafetyCheck {
    var messages: [String] = []
    var status: SafetyCheck.Status = .safe
    
    // Check branch
    if historical.branchAtStart != current.branchNow {
        status = .warning
        messages.append("⚠️ Branch changed: \(historical.branchAtStart ?? "unknown") → \(current.branchNow ?? "unknown")")
    } else {
        messages.append("✓ Branch unchanged: \(current.branchNow ?? "unknown")")
    }
    
    // Check commits
    if historical.commitAtStart != current.commitNow {
        status = .warning
        messages.append("⚠️ New commits since session start")
    } else {
        messages.append("✓ No new commits")
    }
    
    // Check dirty state
    if current.isDirty {
        if status == .safe { status = .caution }
        messages.append("⚠️ \(current.dirtyFiles.count) uncommitted changes")
    } else {
        messages.append("✓ Working tree clean")
    }
    
    let recommendation: String
    switch status {
    case .safe:
        recommendation = "Safe to resume - no changes detected"
    case .caution:
        recommendation = "Review uncommitted changes before resuming"
    case .warning:
        recommendation = "Caution: Git state has changed significantly"
    case .unknown:
        recommendation = "Unable to verify safety - proceed with caution"
    }
    
    return SafetyCheck(status: status, messages: messages, recommendation: recommendation)
}
```

---

## UI Progression (Unified Phases)

### Phase 1: Quick Tooltip (Historical + Status Indicator)
**Trigger:** Hover over session row (200ms delay)
**Data:** Session file only (instant, no git queries)

```
┌─────────────────────────────────┐
│ Session Git Context             │
├─────────────────────────────────┤
│ Branch: feature/perf            │
│ Commit: 2f8a9c1 (2h ago)        │
│ Status: Was clean               │
│                                 │
│ ⚠️ Current state unknown        │
│ Click for live comparison       │
│                                 │
│ [Show Details →]                │
└─────────────────────────────────┘
```

**Implementation:** 
- Zero overhead (just read session file)
- Works for all sessions (Codex, Claude with git, old sessions)
- Gracefully degrades for Gemini
- Claude Code's "Session-Only View" but with CTA to inspector

### Phase 2: Context Menu Action
**Trigger:** Right-click session → "Show Git Context"
**Data:** Session file + live git queries

Opens inspector sheet showing:
- Historical snapshot (from session)
- Current state (from git)
- Safety comparison
- Quick actions

### Phase 3: Inspector Sheet/Window
**Trigger:** Click "Show Details" in tooltip, or context menu action
**Data:** Full historical + current + comparison

```
┌──────────────────────────────────────────────────────────┐
│  🔍 Git Context Inspector                                │
│                                                          │
│  analyze codebase for optimization                       │
│  Claude Code · 529 messages · 2h ago                     │
├──────────────────────────────────────────────────────────┤
│                                                          │
│  📸 SNAPSHOT AT SESSION START                            │
│  ┌────────────────────────────────────────────────────┐ │
│  │ Branch:  feature/perf-improvements                 │ │
│  │ Commit:  2f8a9c1 "feat: improve indexing"          │ │
│  │ Status:  Clean                                     │ │
│  │ Behind:  2 commits                                 │ │
│  │ Created: 2 hours ago                               │ │
│  └────────────────────────────────────────────────────┘ │
│                                                          │
│  🔴 CURRENT STATE                                        │
│  ┌────────────────────────────────────────────────────┐ │
│  │ Branch:  feature/perf-improvements ✓ Same          │ │
│  │ Commit:  2f8a9c1 ✓ No new commits                  │ │
│  │ Status:  ⚠️ Dirty (3 files)                        │ │
│  │          • SessionIndexer.swift (modified)         │ │
│  │          • Session.swift (modified)                │ │
│  │          • SessionTests.swift (added)              │ │
│  │ Behind:  ↓ 2 commits (cached 45m ago) [Refresh]   │ │
│  └────────────────────────────────────────────────────┘ │
│                                                          │
│  ⚡️ RESUME SAFETY CHECK                                 │
│  ┌────────────────────────────────────────────────────┐ │
│  │ Status: ⚠️ CAUTION                                 │ │
│  │                                                    │ │
│  │ • ✓ Branch unchanged                              │ │
│  │ • ✓ No new commits locally                        │ │
│  │ • ⚠️ 3 uncommitted changes detected               │ │
│  │                                                    │ │
│  │ 💡 Recommendation:                                 │ │
│  │ Review uncommitted changes before resuming.       │ │
│  │ Agent may conflict with your work.                │ │
│  └────────────────────────────────────────────────────┘ │
│                                                          │
│  ┌────────────────────────────────────────────────────┐ │
│  │ [View Uncommitted Changes]  [Resume Session]       │ │
│  │ [Open Directory]  [Copy Branch]  [Git Status]      │ │
│  └────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────┘
```

**Key Features:**
1. **Historical Section** - From session file (instant)
2. **Current Section** - Live git queries (~50-100ms)
3. **Comparison Section** - Safety analysis
4. **Actions** - Contextual based on status

---

## Implementation Strategy

### Step 1: Extend Session Model (1 day)
```swift
extension Session {
    var historicalGitContext: HistoricalGitContext? {
        // Extract from session file
        // Works for Codex (has full git metadata)
        // Partial for Claude (parse events)
        // Nil for Gemini
    }
}

struct HistoricalGitContext {
    let branch: String?
    let commit: String?
    let cwd: String
    let wasClean: Bool?
    let timestamp: Date
    
    static func extract(from session: Session) -> Self? {
        guard let cwd = session.cwd else { return nil }
        
        // Codex: direct metadata access
        if session.agent == .codex {
            return extractFromCodex(session)
        }
        
        // Claude: parse events
        if session.agent == .claude {
            return extractFromClaude(session)
        }
        
        // Gemini: not available
        return nil
    }
}
```

### Step 2: Live Git Queries (1 day)
```swift
actor GitStatusCache {
    private var cache: [String: CachedGitStatus] = [:]
    
    struct CachedGitStatus {
        let branch: String?
        let commit: String?
        let isDirty: Bool
        let dirtyFiles: [String]
        let timestamp: Date
        
        var isStale: Bool {
            Date().timeIntervalSince(timestamp) > 60 // 1 minute
        }
    }
    
    func getStatus(for cwd: String) async -> CachedGitStatus? {
        // Check cache
        if let cached = cache[cwd], !cached.isStale {
            return cached
        }
        
        // Query git
        let status = await queryGit(cwd: cwd)
        cache[cwd] = status
        return status
    }
    
    private func queryGit(cwd: String) async -> CachedGitStatus {
        async let branch = shell("git rev-parse --abbrev-ref HEAD", cwd: cwd)
        async let commit = shell("git rev-parse HEAD", cwd: cwd)
        async let statusOutput = shell("git status --porcelain", cwd: cwd)
        
        let (b, c, s) = await (branch, commit, statusOutput)
        
        return CachedGitStatus(
            branch: b,
            commit: c,
            isDirty: !(s?.isEmpty ?? true),
            dirtyFiles: parseGitStatus(s),
            timestamp: Date()
        )
    }
}
```

### Step 3: Safety Comparison (1 day)
```swift
struct GitSafetyAnalyzer {
    static func analyze(
        historical: HistoricalGitContext?,
        current: CachedGitStatus?
    ) -> SafetyCheck {
        // Implementation from above
    }
}
```

### Step 4: UI Components (2-3 days)

**A. Tooltip (Phase 1)**
```swift
struct SessionGitTooltip: View {
    let session: Session
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let historical = session.historicalGitContext {
                Text("Branch: \(historical.branch ?? "unknown")")
                Text("Commit: \(historical.commit?.prefix(7) ?? "unknown")")
                Text("At session start: \(historical.timestamp.relative)")
                
                Divider()
                
                Text("⚡️ Click for live comparison")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Git info not available")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }
}
```

**B. Inspector Sheet (Phase 2-3)**
```swift
struct GitInspectorSheet: View {
    let session: Session
    @State private var currentStatus: CachedGitStatus?
    @State private var isLoadingCurrent = false
    
    var body: some View {
        VStack(spacing: 24) {
            // Historical section
            if let historical = session.historicalGitContext {
                HistoricalSection(context: historical)
            }
            
            // Current section
            if let current = currentStatus {
                CurrentSection(status: current)
            }
            
            // Comparison section
            if let historical = session.historicalGitContext,
               let current = currentStatus {
                SafetySection(
                    check: GitSafetyAnalyzer.analyze(
                        historical: historical, 
                        current: current
                    )
                )
            }
            
            // Actions
            ActionsSection(session: session)
        }
        .task {
            await loadCurrentStatus()
        }
    }
}
```

---

## Comparison: Combined vs Separate

### ❌ If We Build Them Separately

**Claude Code's Feature:**
- Historical git view only
- Right-click → sheet with session metadata
- User sees: "Branch was X when session started"
- Limited value: doesn't answer "can I resume safely?"

**Your Feature:**
- Live git view only  
- Tooltip + inspector with current state
- User sees: "Branch is X, has uncommitted changes"
- Missing context: doesn't show what changed since session

**Result:**
- Two incomplete features
- Confusing UX (which one to use?)
- Duplicated code (two sheet views, two context menu items)

### ✅ If We Combine Them

**Unified Feature:**
- Shows historical AND current
- Single right-click → comprehensive inspector
- User sees: "Branch was X, now is Y, here's what changed"
- Answers both questions: "What was the context?" AND "Is it safe to resume?"

**Result:**
- One complete feature
- Clear UX (one source of truth)
- Shared code (one data model, one inspector view)
- Higher value (comparison is the killer feature)

---

## Recommended Implementation Plan

### Phase 1: Foundation (Week 1)
- Extend Session model with `historicalGitContext`
- Extraction logic for Codex/Claude/Gemini
- Unit tests for extraction

### Phase 2: Live Queries (Week 1)
- GitStatusCache actor
- Local git command wrappers
- Caching strategy

### Phase 3: Safety Analysis (Week 1)
- GitSafetyAnalyzer
- Comparison logic
- Recommendation engine

### Phase 4: Basic UI (Week 2)
- Hover tooltip showing historical snapshot
- Context menu item: "Show Git Context"
- Simple sheet with historical + current sections

### Phase 5: Full Inspector (Week 2-3)
- Comprehensive inspector sheet
- Safety check section with visual indicators
- Quick actions (resume, view changes, open dir)
- Remote status (cached + refresh button)

### Phase 6: Polish (Week 3)
- Error handling (repo deleted, permissions, etc.)
- Empty states (no git info available)
- Keyboard shortcuts
- Help text and onboarding

---

## Key Decisions

### ✅ Do This
1. **Combine features** - Historical + Live in one inspector
2. **Start simple** - Tooltip with historical, expand to inspector
3. **Cache aggressively** - 60s cache for git queries
4. **Graceful degradation** - Work for Codex, partial for Claude, skip for Gemini
5. **Show timestamps** - Make it clear when data is from
6. **Safety recommendations** - Help users decide if it's safe to resume

### ❌ Don't Do This
1. Auto-fetch on app launch (battery/network)
2. Show live data in tooltip (keep it instant)
3. Block UI on git queries (async everything)
4. Build two separate features
5. Permanent inspector panel (not needed initially)
6. Force git info for Gemini (accept limitation)

---

## Risk Mitigation

### Risk: User expects live data in tooltip
**Solution:** Clear label "At session start" + CTA to inspector for current state

### Risk: Git queries slow on large repos
**Solution:** 
- 60s cache
- Async/non-blocking
- Timeout (500ms max per query)

### Risk: Session file doesn't have git info
**Solution:** 
- Graceful degradation
- Show "Git info not available" message
- Still show current state if cwd exists

### Risk: Two competing sources of truth
**Solution:** 
- Single unified inspector
- Clear labels: "Historical" vs "Current"
- Timestamps for everything

---

## Success Metrics

**Phase 1 Success:**
- 50% of users hover to see historical git context
- Zero performance impact on session list

**Phase 2-3 Success:**
- 30% of users open inspector before resuming sessions
- 80% accuracy in safety recommendations
- Sub-100ms load time for inspector

**Long-term Success:**
- Fewer "accidental resume on wrong branch" incidents
- Users report confidence in resuming old sessions
- Feature becomes expected baseline

---

## Conclusion

**Recommendation: Build ONE unified feature, not two separate ones.**

The winning approach:
1. Start with Claude Code's "Session-Only View" as Phase 1 (historical tooltip)
2. Extend it with your "Live Inspector" as Phase 2-3 (current state + comparison)
3. Result: Complete Git Context Inspector that answers both questions

This gives users:
- ✓ Historical context (what was the session about?)
- ✓ Current state (what's changed?)
- ✓ Safety analysis (is it safe to resume?)
- ✓ Actionable recommendations

Single source of truth, no duplicate code, higher value than either feature alone.
