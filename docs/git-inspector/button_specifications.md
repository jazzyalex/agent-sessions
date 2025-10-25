# Git Inspector Button Specifications

Complete specification for every interactive element in the Git Context Inspector.

---

## Button Grid (6 buttons)

### 1. "📋 View Changes" Button

**Purpose:** Show detailed git diff of uncommitted changes

**Behavior:**
```
IF currentStatus.isDirty == true:
    → Open diff viewer showing uncommitted changes
ELSE:
    → Button is disabled (grayed out)
    → Tooltip: "No uncommitted changes"
```

**Implementation Options:**

**Option A: Terminal (Simple)**
```swift
func viewChanges() {
    guard let cwd = session.cwd else { return }
    
    // Open Terminal and run git diff
    let script = """
    tell application "Terminal"
        activate
        do script "cd '\(cwd)' && git diff --color=always | less -R"
    end tell
    """
    
    NSAppleScript(source: script)?.executeAndReturnError(nil)
}
```

**Option B: External Tool (Better UX)**
```swift
func viewChanges() {
    guard let cwd = session.cwd else { return }
    
    // Try to open in user's preferred diff tool
    // Priority: Fork > Tower > GitKraken > Terminal
    if let forkURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.DanPristupov.Fork") {
        openInFork(cwd: cwd)
    } else if let towerURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.fournova.Tower3") {
        openInTower(cwd: cwd)
    } else {
        // Fallback to terminal
        openInTerminal(cwd: cwd, command: "git diff")
    }
}
```

**Option C: Built-in Diff View (Most Work)**
```swift
struct DiffViewerSheet: View {
    let diff: String
    
    var body: some View {
        ScrollView {
            Text(diff)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
        .frame(width: 800, height: 600)
        .navigationTitle("Git Diff")
    }
}

func viewChanges() async {
    guard let cwd = session.cwd else { return }
    
    let diff = await shell("git diff", cwd: cwd)
    showSheet(DiffViewerSheet(diff: diff ?? "No changes"))
}
```

**Recommended:** Option B (External Tool) with Option A (Terminal) as fallback

**UI States:**
- Enabled: When `currentStatus.isDirty == true`
- Disabled: When working tree is clean
- Loading: While fetching diff (spinner on button)

**Data Sources:**
- `currentStatus.isDirty` - determines if button is enabled
- `currentStatus.dirtyFiles` - list of changed files
- `git diff` command - actual diff content

---

### 2. "📂 Open Directory" Button

**Purpose:** Open the session's working directory in Finder

**Behavior:**
```
IF session.cwd exists on disk:
    → Open directory in Finder
    → Inspector remains open
ELSE:
    → Show alert: "Directory not found: {cwd}"
    → Offer "Show Session Files" as alternative
```

**Implementation:**
```swift
func openDirectory() {
    guard let cwd = session.cwd else {
        showAlert("No directory associated with this session")
        return
    }
    
    let url = URL(fileURLWithPath: cwd)
    
    // Check if directory exists
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory),
       isDirectory.boolValue {
        // Open in Finder
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: cwd)
    } else {
        // Directory doesn't exist
        showAlert(
            title: "Directory Not Found",
            message: "The directory no longer exists:\n\(cwd)",
            actions: [
                ("Show Session Files", showSessionFiles),
                ("Cancel", nil)
            ]
        )
    }
}

func showSessionFiles() {
    let sessionURL = session.fileURL
    NSWorkspace.shared.activateFileViewerSelecting([sessionURL])
}
```

**UI States:**
- Always enabled (even if directory doesn't exist, we show error)
- No loading state needed

**Data Sources:**
- `session.cwd` - directory path
- `FileManager` - check if path exists

**Edge Cases:**
- Directory deleted: Show error with "Show Session Files" option
- Path is file not directory: Show error
- Permission denied: System handles this (shows Permission Denied dialog)

---

### 3. "🌿 Copy Branch" Button

**Purpose:** Copy current branch name to clipboard

**Behavior:**
```
IF currentStatus.branch exists:
    → Copy branch name to clipboard
    → Show brief success indicator (checkmark animation)
    → Auto-dismiss after 1 second
ELSE:
    → Copy historical branch (if available)
    → Show "Copied historical branch (session may be outdated)"
```

**Implementation:**
```swift
func copyBranch() {
    let branchToCopy: String?
    let message: String
    
    if let currentBranch = currentStatus?.branch {
        branchToCopy = currentBranch
        message = "Copied: \(currentBranch)"
    } else if let historicalBranch = session.historicalGitContext?.branch {
        branchToCopy = historicalBranch
        message = "Copied historical branch: \(historicalBranch)"
    } else {
        showAlert("No branch information available")
        return
    }
    
    guard let branch = branchToCopy else { return }
    
    // Copy to clipboard
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(branch, forType: .string)
    
    // Show success feedback
    showToast(message, duration: 1.5, icon: "checkmark.circle.fill")
}
```

**UI States:**
- Enabled: When branch info is available (current or historical)
- Disabled: When no branch info exists
- Success feedback: Brief checkmark overlay

**Data Sources:**
- `currentStatus.branch` (preferred)
- `session.historicalGitContext.branch` (fallback)

**User Feedback:**
```swift
struct ToastView: View {
    let message: String
    let icon: String
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.green)
            Text(message)
                .font(.subheadline)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .transition(.scale.combined(with: .opacity))
    }
}
```

---

### 4. "🔄 Refresh Status" Button

**Purpose:** Re-query git to get latest current state

**Behavior:**
```
WHEN clicked:
    1. Show loading spinner on button
    2. Clear cached git status for this repo
    3. Re-run all git queries (branch, commit, status, etc.)
    4. Update "Current State" section
    5. Re-compute safety check
    6. Show success feedback
    7. Update "Last refreshed: just now" timestamp
```

**Implementation:**
```swift
@State private var isRefreshing = false
@State private var lastRefreshTime: Date?

func refreshStatus() async {
    guard let cwd = session.cwd else { return }
    
    isRefreshing = true
    defer { isRefreshing = false }
    
    // Clear cache
    await GitStatusCache.shared.invalidate(for: cwd)
    
    // Re-query
    currentStatus = await GitStatusCache.shared.getStatus(for: cwd)
    
    // Re-analyze safety
    safetyCheck = GitSafetyAnalyzer.analyze(
        historical: session.historicalGitContext,
        current: currentStatus
    )
    
    lastRefreshTime = Date()
    
    // Show feedback
    showToast("Status refreshed", duration: 1, icon: "checkmark.circle")
}
```

**Button Appearance:**
```swift
Button(action: { Task { await refreshStatus() } }) {
    HStack(spacing: 6) {
        if isRefreshing {
            ProgressView()
                .scaleEffect(0.7)
        } else {
            Image(systemName: "arrow.clockwise")
        }
        Text("Refresh Status")
    }
}
.disabled(isRefreshing)
```

**UI States:**
- Normal: Shows 🔄 icon
- Refreshing: Shows spinner, button disabled
- Just refreshed: Brief checkmark animation

**Data Sources:**
- All git CLI commands (re-run)
- Updates `currentStatus` and `safetyCheck`

**Optional Enhancement: Auto-refresh timestamp**
```swift
VStack {
    CurrentSection(status: currentStatus)
    
    if let lastRefresh = lastRefreshTime {
        Text("Last refreshed: \(lastRefresh.relative)")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
```

---

### 5. "📊 Git Status" Button

**Purpose:** Open Terminal and run `git status` for detailed view

**Behavior:**
```
WHEN clicked:
    → Open Terminal in session's working directory
    → Run "git status -vv" (verbose, shows branch tracking)
    → Inspector remains open
```

**Implementation:**
```swift
func showGitStatus() {
    guard let cwd = session.cwd else { return }
    
    let script = """
    tell application "Terminal"
        activate
        do script "cd '\(cwd)' && git status -vv"
    end tell
    """
    
    if let appleScript = NSAppleScript(source: script) {
        var error: NSDictionary?
        appleScript.executeAndReturnError(&error)
        
        if let error = error {
            showAlert("Failed to open Terminal: \(error)")
        }
    }
}
```

**Alternative: iTerm2 Support**
```swift
func showGitStatus() {
    guard let cwd = session.cwd else { return }
    
    // Try iTerm2 first, fallback to Terminal
    if isITermInstalled() {
        openInITerm(cwd: cwd, command: "git status -vv")
    } else {
        openInTerminal(cwd: cwd, command: "git status -vv")
    }
}

func isITermInstalled() -> Bool {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2") != nil
}
```

**UI States:**
- Always enabled (will show error if git not available)
- No loading state

**Data Sources:**
- `session.cwd` - working directory
- System: Terminal.app or iTerm2.app

**Edge Cases:**
- No git: Terminal opens but shows "git: command not found"
- Permission denied: Terminal shows error
- Directory deleted: Terminal shows "No such file or directory"

---

### 6. "⚠️ Resume Anyway" Button

**Purpose:** Resume session despite safety warnings

**Appearance:**
- Red/danger styling (white text on red background)
- Only enabled when safety check shows caution/warning
- If status is "safe", button is disabled

**Behavior:**
```
IF safetyCheck.status == .safe:
    → Button disabled, text: "✓ Safe to Resume"
ELSE:
    → Button enabled, text: "⚠️ Resume Anyway"
    → On click: Show confirmation dialog
    → If confirmed: Resume session
```

**Implementation:**
```swift
func resumeSession() {
    guard let cwd = session.cwd else { return }
    
    // Check safety status
    guard let safety = safetyCheck else {
        directResume()
        return
    }
    
    switch safety.status {
    case .safe:
        // Just resume
        directResume()
        
    case .caution:
        // Show warning, allow continue
        showConfirmation(
            title: "Uncommitted Changes Detected",
            message: "This session has uncommitted changes. Resuming may cause conflicts.\n\n\(safety.recommendation)",
            confirmLabel: "Resume Anyway",
            confirmAction: directResume
        )
        
    case .warning:
        // Show stronger warning
        showConfirmation(
            title: "Git State Changed",
            message: "The git state has changed significantly since this session:\n\n" +
                     safety.checks.map { $0.message }.joined(separator: "\n") +
                     "\n\n\(safety.recommendation)",
            confirmLabel: "Resume Anyway",
            confirmStyle: .destructive,
            confirmAction: directResume
        )
        
    case .unknown:
        // Generic warning
        showConfirmation(
            title: "Unable to Verify Safety",
            message: "Git information is unavailable. Proceed with caution.",
            confirmLabel: "Resume",
            confirmAction: directResume
        )
    }
}

func directResume() {
    // Close inspector
    dismiss()
    
    // Trigger resume action (existing AgentSessions functionality)
    if session.agent == .codex {
        resumeCodexSession(session)
    } else if session.agent == .claude {
        resumeClaudeSession(session)
    }
}
```

**Confirmation Dialog:**
```swift
struct SafetyConfirmationDialog: View {
    let title: String
    let message: String
    let confirmAction: () -> Void
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            
            Text(title)
                .font(.headline)
            
            Text(message)
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            
            HStack(spacing: 12) {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                
                Button("Resume Anyway") {
                    confirmAction()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
        .padding(24)
        .frame(width: 400)
    }
}
```

**Button States:**
```swift
var resumeButtonConfig: (label: String, style: ButtonStyle, enabled: Bool) {
    guard let safety = safetyCheck else {
        return ("Resume", .primary, true)
    }
    
    switch safety.status {
    case .safe:
        return ("✓ Safe to Resume", .primary, true)
    case .caution:
        return ("⚠️ Resume Anyway", .danger, true)
    case .warning:
        return ("⚠️ Resume Anyway", .danger, true)
    case .unknown:
        return ("Resume", .primary, true)
    }
}
```

**Data Sources:**
- `safetyCheck.status` - determines button appearance
- `session.agent` - determines how to resume
- Session resume functionality (existing in AgentSessions)

---

## Additional UI Elements

### Timestamp Display (in Current State section)

**Shows:** Last time git status was queried

```swift
HStack {
    Text("Last checked: \(lastRefreshTime?.relative ?? "just now")")
        .font(.caption)
        .foregroundStyle(.secondary)
    
    if let time = lastRefreshTime,
       Date().timeIntervalSince(time) > 300 { // 5 minutes
        Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .help("Status may be stale, consider refreshing")
    }
}
```

---

### Remote Status Refresh (Optional Enhancement)

**Additional button in Current State section:**

```swift
Button("Fetch Remote") {
    Task { await fetchRemote() }
}
.disabled(isFetching)

func fetchRemote() async {
    guard let cwd = session.cwd else { return }
    
    isFetching = true
    defer { isFetching = false }
    
    // Run git fetch
    let result = await shell("git fetch origin --prune", cwd: cwd)
    
    if result != nil {
        // Success - refresh status
        await refreshStatus()
        showToast("Remote status updated", duration: 2)
    } else {
        // Failed
        showAlert("Failed to fetch remote. Check network connection.")
    }
}
```

**Shows in UI:**
```
Behind Origin: ↓ 2 commits (cached 45m ago) [Refresh Remote]
                                              ^^^^^^^^^^^^^^
                                              This button
```

---

## Keyboard Shortcuts

**Inspector Window:**
- `⌘W` - Close inspector
- `⌘R` - Refresh status
- `⌘D` - View changes (if available)
- `⌘O` - Open directory
- `⌘Return` - Resume (with safety check)

**Implementation:**
```swift
.keyboardShortcut("r", modifiers: .command)  // Refresh
.keyboardShortcut("d", modifiers: .command)  // Diff
.keyboardShortcut("o", modifiers: .command)  // Open
.keyboardShortcut(.return, modifiers: .command)  // Resume
```

---

## Error States

### Git Not Available
```
ℹ️ Git Not Available
Unable to query git status. Is git installed?

[Install Git] [Close]
```

### Repository Deleted
```
❌ Repository Not Found
The directory no longer exists:
/Users/alexm/Repository/project

📸 Historical snapshot is still available above.

[Show Session Files] [Close]
```

### Permission Denied
```
⚠️ Permission Denied
Unable to access git repository.

[Open Directory] [Close]
```

---

## Summary: Data Sources

| Button | Data Source | Network? | Cached? |
|--------|-------------|----------|---------|
| View Changes | `git diff` | No | No (always fresh) |
| Open Directory | `session.cwd` + FileManager | No | N/A |
| Copy Branch | `currentStatus.branch` or historical | No | Yes (60s) |
| Refresh Status | All git commands | No | Clears cache |
| Git Status | Terminal (git status -vv) | No | N/A |
| Resume Anyway | Safety check + resume logic | No | N/A |

**Key Insight:** ALL buttons work without network. Even "behind origin" uses cached refs. Only "Fetch Remote" (optional) requires network.
