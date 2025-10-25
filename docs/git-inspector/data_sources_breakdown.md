# Data Sources: Session Files vs CLI Tools

## What's Available from Session Files (No CLI Needed)

### ✅ Codex Sessions
From `session.payload.git` metadata:
```json
{
  "branch": "feature/perf-improvements",
  "commit_hash": "2f8a9c1d...",
  "is_clean": true,
  "uncommitted_changes": []
}
```

**Available Data:**
- ✓ Branch name at session start
- ✓ Commit hash at session start
- ✓ Whether working tree was clean
- ✓ List of uncommitted files (if any)
- ✓ Working directory (cwd)

### ⚠️ Claude Sessions
From events parsing:
```json
{
  "cwd": "/Users/alexm/Repository/project",
  "events": [
    {
      "type": "tool_call",
      "content": "Running in /Users/alexm/Repository/project..."
    }
  ]
}
```

**Available Data:**
- ✓ Working directory (cwd)
- ~ Branch name (sometimes mentioned in events, not guaranteed)
- ✗ Commit hash (not stored)
- ✗ Clean status (not stored)

### ❌ Gemini Sessions
**Available Data:**
- ✓ Working directory (maybe)
- ✗ No git metadata

---

## What Requires CLI Tools (Git Commands)

### 🔴 Current State Section (All requires git CLI)

**To show current branch:**
```bash
git rev-parse --abbrev-ref HEAD
# Output: feature/perf-improvements
```

**To show current commit:**
```bash
git rev-parse HEAD
# Output: 2f8a9c1d8e7f6a5b4c3d2e1f0a9b8c7d6e5f4a3b
```

**To check if working tree is dirty:**
```bash
git status --porcelain
# Output:
#  M src/file.swift
# ?? temp.txt
```

**To list changed files:**
```bash
git status --porcelain
# Parse output: M = modified, A = added, D = deleted, ?? = untracked
```

**To check behind/ahead (cached, no network):**
```bash
git rev-list --left-right --count origin/main...HEAD
# Output: 2	3
# Means: 2 behind, 3 ahead
```

**To get last commit message:**
```bash
git log -1 --pretty=%s
# Output: feat: improve indexing
```

### Network Operations (Optional, User-Triggered)

**To refresh remote status:**
```bash
git fetch origin --prune
# Then re-check behind/ahead
```

---

## Summary: What You Can Build Without CLI

### Phase 0: Historical Only (No CLI)
Show snapshot from session files:
- Branch at session start (Codex only)
- Commit at session start (Codex only)
- Whether it was clean (Codex only)
- Working directory (all agents)

**Limitation:** No current state, no comparison, no safety check.

### Phase 1+: Full Inspector (Requires CLI)
Show historical + current + comparison:
- All of Phase 0 PLUS
- Current branch, commit, dirty status (git CLI)
- Comparison between then and now
- Safety recommendations

---

## Recommended Strategy

### For MVP (Minimum Viable Product):
1. **Extract historical data from session files** (no CLI)
   - Works great for Codex
   - Partial for Claude
   - Skip for Gemini
   
2. **Add git CLI queries for current state**
   - Only run when inspector is opened
   - Cache results for 60 seconds
   - Gracefully handle errors (repo deleted, no git, etc.)

3. **Enable comparison only when both are available**
   - If historical data exists AND git CLI works → show full comparison
   - If only historical exists → show "Current state unavailable"
   - If only current exists → show "Session didn't capture git state"

### Error Handling

**Scenario: Repository deleted since session**
```
📸 Snapshot at Session Start
Branch: feature/perf
Commit: 2f8a9c1

❌ Current State Unavailable
Repository no longer exists at:
/Users/alexm/Repository/project

[Show Session Files] [Close]
```

**Scenario: No git in working directory**
```
📸 Snapshot at Session Start
Working Dir: /Users/alexm/Repository/project

ℹ️ Current State Unavailable
This directory is not a git repository.

[Open Directory] [Close]
```

**Scenario: Session has no git metadata**
```
ℹ️ Git Information Not Available
This session type doesn't capture git metadata.

🔴 Current State (Live)
Branch: feature/perf
Commit: 2f8a9c1
Status: Clean

[Open Directory] [Close]
```

---

## Performance Considerations

### Session File Reading (Instant)
- Already in memory via SessionIndexer
- Just extract properties
- Zero overhead

### Git CLI Queries (~50-100ms total)
```swift
// Run these in parallel
async let branch = shell("git rev-parse --abbrev-ref HEAD")
async let commit = shell("git rev-parse HEAD")
async let status = shell("git status --porcelain")

// Wait for all
let (b, c, s) = await (branch, commit, status)

// Total time: ~50ms (not 3x sequential)
```

### Caching Strategy
```swift
actor GitStatusCache {
    private var cache: [String: (status: GitStatus, timestamp: Date)] = [:]
    private let cacheLifetime: TimeInterval = 60 // 1 minute
    
    func getStatus(for cwd: String) async -> GitStatus? {
        // Check cache first
        if let cached = cache[cwd],
           Date().timeIntervalSince(cached.timestamp) < cacheLifetime {
            return cached.status
        }
        
        // Query git and cache
        let status = await queryGit(cwd: cwd)
        cache[cwd] = (status, Date())
        return status
    }
}
```

---

## Decision: Do You Need CLI?

### If You Want Just Historical View:
**NO CLI NEEDED** ✅
- Read from session files only
- Instant, zero overhead
- Limited value (no current state)

### If You Want Full Inspector:
**YES, NEED GIT CLI** ✅
- Historical from session files
- Current from git commands
- Comparison + safety check
- Much higher value

**Recommendation: Build full inspector with git CLI.**
The marginal cost of adding git queries is small (~50ms), but the value is 10x higher.
