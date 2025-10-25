# Launch Prompt: Unified Git Context Inspector

## Overview
Build a **unified git inspector** that shows both historical session context (from session files) AND current git state (from CLI), with intelligent comparison to help users safely resume sessions.

## The Problem
Users juggling multiple CLI agent sessions need to know:
1. What git context was the agent working in?
2. What's the current git state?
3. Has anything changed? Is it safe to resume?

Currently: No way to see this information.

## The Solution: Git Context Inspector

### Phase 1: Hover Tooltip (Historical Only)
- **Trigger:** Hover over session row (200ms delay)
- **Data:** Extract from session file (instant, no CLI)
- **Shows:**
  - Branch name at session start
  - Commit hash (first 7 chars)
  - Whether working tree was clean
  - Timestamp: "2 hours ago"
  - CTA: "Click for live comparison"

### Phase 2: Inspector Window (Historical + Live + Comparison)
- **Trigger:** Double-click session row OR context menu "Show Git Context"
- **Data:** Session file + git CLI queries
- **Shows:** Three sections:
  1. 📸 **Snapshot at Session Start** - from session file
  2. 🔴 **Current State (Live)** - from git commands
  3. ⚡️ **Resume Safety Check** - intelligent comparison

## Architecture

### Data Model
```swift
// Phase 1: Extract from session files
struct HistoricalGitContext {
    let branch: String?
    let commit: String?
    let wasClean: Bool?
    let cwd: String
    let timestamp: Date
}

extension Session {
    var historicalGitContext: HistoricalGitContext? {
        // For Codex: read from session.payload.git
        // For Claude: parse events for branch mentions
        // For Gemini: return nil
    }
}

// Phase 2: Query git CLI
struct CurrentGitStatus {
    let branch: String?
    let commit: String?
    let isDirty: Bool
    let dirtyFiles: [GitFileStatus]
    let lastCommitMessage: String?
}

struct GitFileStatus {
    let path: String
    let status: FileChangeType // M, A, D, ??
}

enum FileChangeType: String {
    case modified = "M"
    case added = "A"
    case deleted = "D"
    case untracked = "??"
}

// Phase 3: Compare and analyze
struct SafetyCheck {
    enum Status {
        case safe       // Same branch, no changes
        case caution    // Same branch, uncommitted changes
        case warning    // Different branch or new commits
        case unknown    // Can't determine
    }
    
    let status: Status
    let checks: [CheckResult]
    let recommendation: String
}

struct CheckResult {
    let icon: String  // ✓ or ⚠️
    let message: String
    let passed: Bool
}
```

### Git Queries (Phase 2)
```swift
actor GitStatusCache {
    func getStatus(for cwd: String) async -> CurrentGitStatus {
        // Run in parallel (async let)
        async let branch = shell("git rev-parse --abbrev-ref HEAD", cwd: cwd)
        async let commit = shell("git rev-parse HEAD", cwd: cwd)
        async let status = shell("git status --porcelain", cwd: cwd)
        async let message = shell("git log -1 --pretty=%s", cwd: cwd)
        
        let (b, c, s, m) = await (branch, commit, status, message)
        
        return CurrentGitStatus(
            branch: b?.trimmingCharacters(in: .whitespaces),
            commit: c?.trimmingCharacters(in: .whitespaces),
            isDirty: !(s?.isEmpty ?? true),
            dirtyFiles: parseGitStatus(s),
            lastCommitMessage: m?.trimmingCharacters(in: .whitespaces)
        )
    }
    
    private func parseGitStatus(_ output: String?) -> [GitFileStatus] {
        guard let output = output, !output.isEmpty else { return [] }
        return output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            let status = String(parts[0]).trimmingCharacters(in: .whitespaces)
            let path = String(parts[1]).trimmingCharacters(in: .whitespaces)
            guard let type = FileChangeType(rawValue: status) else { return nil }
            return GitFileStatus(path: path, status: type)
        }
    }
}
```

### Safety Analysis
```swift
struct GitSafetyAnalyzer {
    static func analyze(
        historical: HistoricalGitContext?,
        current: CurrentGitStatus?
    ) -> SafetyCheck {
        guard let historical = historical,
              let current = current else {
            return SafetyCheck(
                status: .unknown,
                checks: [],
                recommendation: "Unable to verify safety - git information unavailable"
            )
        }
        
        var checks: [CheckResult] = []
        var status: SafetyCheck.Status = .safe
        
        // Check 1: Branch unchanged
        let branchSame = historical.branch == current.branch
        checks.append(CheckResult(
            icon: branchSame ? "✓" : "⚠️",
            message: branchSame 
                ? "Branch unchanged (still on \(current.branch ?? "unknown"))"
                : "Branch changed: \(historical.branch ?? "?") → \(current.branch ?? "?")",
            passed: branchSame
        ))
        if !branchSame { status = .warning }
        
        // Check 2: No new commits
        let commitSame = historical.commit?.prefix(7) == current.commit?.prefix(7)
        checks.append(CheckResult(
            icon: commitSame ? "✓" : "⚠️",
            message: commitSame
                ? "No new commits since session start"
                : "New commits detected",
            passed: commitSame
        ))
        if !commitSame { status = .warning }
        
        // Check 3: Working tree clean
        checks.append(CheckResult(
            icon: current.isDirty ? "⚠️" : "✓",
            message: current.isDirty
                ? "\(current.dirtyFiles.count) uncommitted changes detected"
                : "Working tree clean",
            passed: !current.isDirty
        ))
        if current.isDirty && status == .safe { status = .caution }
        
        // Generate recommendation
        let recommendation: String
        switch status {
        case .safe:
            recommendation = "Safe to resume - no changes detected"
        case .caution:
            recommendation = "Review uncommitted changes before resuming. The agent may conflict with your work. Consider committing or stashing changes first."
        case .warning:
            recommendation = "Caution: Git state has changed significantly. Review changes carefully before resuming."
        case .unknown:
            recommendation = "Unable to verify safety - proceed with caution"
        }
        
        return SafetyCheck(status: status, checks: checks, recommendation: recommendation)
    }
}
```

## UI Components

### 1. Tooltip View (Phase 1)
```swift
struct SessionGitTooltip: View {
    let session: Session
    
    var body: some View {
        if let git = session.historicalGitContext {
            VStack(alignment: .leading, spacing: 6) {
                Text("Branch: \(git.branch ?? "unknown")")
                Text("Commit: \(git.commit?.prefix(7) ?? "unknown")")
                Text(git.wasClean == true ? "Was clean" : "Had changes")
                Text("\(git.timestamp.relative)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                Divider()
                
                Text("⚡️ Click for live comparison")
                    .font(.caption2)
                    .foregroundStyle(.blue)
            }
        } else {
            Text("Git info not available")
                .foregroundStyle(.secondary)
        }
    }
}
```

### 2. Inspector Sheet (Phase 2)
```swift
struct GitInspectorSheet: View {
    let session: Session
    @State private var currentStatus: CurrentGitStatus?
    @State private var safetyCheck: SafetyCheck?
    @State private var isLoading = true
    
    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header
                InspectorHeader(session: session)
                
                // Historical Section
                if let git = session.historicalGitContext {
                    HistoricalSection(context: git)
                    ComparisonDivider()
                }
                
                // Current Section
                if let current = currentStatus {
                    CurrentSection(status: current)
                    ComparisonDivider()
                } else if isLoading {
                    ProgressView("Loading current git state...")
                }
                
                // Safety Section
                if let safety = safetyCheck {
                    SafetySection(check: safety)
                }
                
                // Actions
                ActionsSection(session: session, currentStatus: currentStatus)
            }
            .padding()
        }
        .frame(width: 680, height: 800)
        .task {
            await loadCurrentStatus()
        }
    }
    
    private func loadCurrentStatus() async {
        isLoading = true
        defer { isLoading = false }
        
        guard let cwd = session.cwd else { return }
        
        let cache = GitStatusCache.shared
        currentStatus = await cache.getStatus(for: cwd)
        
        safetyCheck = GitSafetyAnalyzer.analyze(
            historical: session.historicalGitContext,
            current: currentStatus
        )
    }
}
```

## What You Need to Design/Decide

### 1. UI/UX Decisions
- [ ] **Tooltip delay:** 200ms hover or instant?
- [ ] **Inspector as sheet or window?** Sheet (modal) vs separate window (can stay open)
- [ ] **Context menu placement:** Top-level or in submenu?
- [ ] **Keyboard shortcut?** e.g., ⌘I when session selected

### 2. Error Handling
- [ ] **Repo deleted:** Show graceful message, disable "Resume" button
- [ ] **No git in directory:** Show "Not a git repository" message
- [ ] **Git command timeout:** Max 500ms per query, show "Timed out" if slower
- [ ] **Permission errors:** Handle "Permission denied" gracefully

### 3. Edge Cases
- [ ] **Very long branch names:** Truncate with ellipsis
- [ ] **Many dirty files (100+):** Show count + scrollable list with max height
- [ ] **Detached HEAD state:** Show commit hash instead of branch name
- [ ] **Worktrees:** Detect and show worktree path
- [ ] **Submodules:** Detect and indicate in UI

### 4. Performance
- [ ] **Cache lifetime:** 60 seconds reasonable?
- [ ] **Parallel queries:** Use async let for all git commands
- [ ] **Background refresh:** Should inspector auto-refresh every N seconds?

### 5. Feature Flags
- [ ] **Gradual rollout:** Ship Phase 1 (tooltip) first, Phase 2 later?
- [ ] **User preference:** "Always show git tooltip" setting?

## Files to Reference

I'm providing these analysis documents:
1. `unified_git_inspector.md` - Full architecture and rationale
2. `data_sources_breakdown.md` - What needs CLI vs session files
3. `button_specifications.md` - Detailed button behavior specs
4. `inspector_screenshot.html` - Visual mockup for reference

## Success Criteria

### Phase 1 (Tooltip)
- [ ] Tooltip shows for Codex sessions with git metadata
- [ ] Gracefully handles Claude/Gemini (shows partial or "unavailable")
- [ ] Zero performance impact on session list
- [ ] <200ms to show tooltip

### Phase 2 (Inspector)
- [ ] Shows historical + current + comparison
- [ ] Git queries complete in <100ms
- [ ] Safety recommendations are accurate (manual testing)
- [ ] All buttons work as specified
- [ ] Error handling covers all edge cases

### Phase 3 (Polish)
- [ ] Works offline (cached git refs)
- [ ] Keyboard shortcuts
- [ ] Accessibility (VoiceOver support)
- [ ] Help text / onboarding

## Open Questions for You

1. **Inspector as sheet or separate window?** 
   - Sheet: Modal, blocks main window, but simpler
   - Window: Can stay open while working, but more complex

2. **Should "View Changes" button open diff viewer or external tool?**
   - Built-in diff view (more work)
   - Launch Terminal with `git diff` (simpler)

3. **Do we want remote fetch refresh button?**
   - Adds complexity
   - Network operation in UI
   - But useful for checking if behind origin

4. **Should this be Codex-only initially?**
   - Codex has full git metadata
   - Claude is partial
   - Gemini has none

## Timeline Estimate

- **Phase 1 (Tooltip):** 2-3 days
  - Session model extension: 0.5 day
  - Tooltip UI: 0.5 day
  - Testing/polish: 1 day

- **Phase 2 (Inspector):** 4-5 days
  - Git CLI integration: 1 day
  - Current status queries: 1 day
  - Safety analyzer: 1 day
  - Inspector UI: 1 day
  - Testing/polish: 1 day

- **Phase 3 (Polish):** 2-3 days
  - Error handling: 1 day
  - Button implementations: 1 day
  - Accessibility: 0.5 day
  - Documentation: 0.5 day

**Total: 8-11 days** for full implementation

## Next Steps

1. Review this prompt and analysis docs
2. Decide on open questions (inspector type, button behaviors, etc.)
3. Start with Phase 1 (tooltip) - smallest, highest value
4. Get user feedback before building Phase 2
5. Iterate based on real usage

Let me know what you decide on the open questions and I'll start implementation!
