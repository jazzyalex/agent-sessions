# Cockpit Live Sessions Subsystem Analysis

Based on the handoff summary and codebase inspection, here is the analysis of the two persistent issues and the proposed fixes.

## Issue 1: Ghost Active Codex CLI session still appears in Cockpit

**Root Cause:**
Sub-agents (which have `kind == "subagent"`) often write presence files to the registry. When a Codex CLI session abruptly exits, the sub-agent's presence file may be left behind. Currently, `CockpitView.shouldHideUnresolvedPresencePlaceholder` keeps *any* unresolved row that has a `sessionId` or `sessionLogPath`. Because sub-agents inherit or generate these fields, they bypass the hide-filter and render as standalone "ghost" rows in the Cockpit. 

**Proposed Fix:**
Update the unresolved presence filter to explicitly discard rows corresponding to sub-agents. 

In `AgentSessions/Views/CockpitView.swift`, modify `shouldHideUnresolvedPresencePlaceholder`:
```swift
    static func func shouldHideUnresolvedPresencePlaceholder(_ presence: CodexActivePresence,
                                                             resolvedSession: Session?,
                                                             hasWorkspaceMatch: Bool) -> Bool {
        guard resolvedSession == nil else { return false }
        
        // ADDED: Filter out sub-agents to prevent ghost rows
        if presence.kind == "subagent" { return true }

        let hasSessionID = presence.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        // ... (rest of the function remains the same)
```

## Issue 2: Claude sessions that are actually active still show as open

**Root Cause:**
The misclassification of active Claude sessions as "open" stems from a combination of terminal metadata constraints and heuristic fallbacks:

1. **Premature iTerm Probing Rejection:** 
   `CodexActiveSessionsModel.canAttemptITerm2Focus` strictly requires `termProgram` to be either empty or contain `"iterm"`. If a user runs Claude inside a terminal multiplexer like `tmux`, `termProgram` is set to `"tmux"`. This causes `canAttemptITerm2Focus` to return `false`, completely skipping the AppleScript iTerm tail capture that could have accurately determined the active state.
   
2. **Ambiguous Tail Fallback:**
   Even if the iTerm tail is captured, `classifyGenericITermTail` expects specific busy markers (e.g., "working", "generating"). If Claude's output doesn't match these exactly, it returns `nil` and delegates to the `mtime` heuristic.
   
3. **MTime Heuristic Defaulting to Open:**
   If the log path is missing or unreadable (`sessionLogPath == nil`), `heuristicLiveStateFromLogMTime` immediately defaults to `.openIdle`. For Claude sessions, the log path might not be properly populated in the registry file, leading to a permanent "open" state when terminal probing fails or is skipped.

**Proposed Fix:**

1. **Relax Terminal Probing Restrictions:**
   In `AgentSessions/Services/CodexActiveSessionsModel.swift`, modify `canAttemptITerm2Focus` so it does not strictly reject based on `termProgram`. If a `tty` is available, we should allow the probe to attempt finding the window in iTerm2, since AppleScript will safely return "not found" if it isn't an iTerm2 TTY.
   ```swift
   nonisolated static func canAttemptITerm2Focus(itermSessionId: String?, tty: String?, termProgram: String?) -> Bool {
       if let guid = itermSessionGuid(from: itermSessionId), !guid.isEmpty { return true }
       guard let tty = tty?.trimmingCharacters(in: .whitespacesAndNewlines), !tty.isEmpty else { return false }
       
       // Relax the termProgram check to allow multiplexers like tmux
       let term = (termProgram ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
       if term.contains("iterm") { return true }
       
       // Return true instead of `term.isEmpty` to always allow TTY-based fallback probing
       return true 
   }
   ```

2. **Improve Claude State Heuristic Fallback:**
   In `classifyLiveStates`, if the state is unresolved (and the heuristic returned `.openIdle` due to missing `sessionLogPath`), we could optionally check the `mtime` of `presence.sourceFilePath` (the registry dotfile) as a proxy for activity, since Claude updates this dotfile frequently when active. However, just relaxing the iTerm probe should resolve the majority of false `.openIdle` cases for users running inside iTerm2 (even via tmux). If Claude is running in a different terminal (e.g. Ghostty), `sessionLogPath` must be reliably provided by the Claude CLI to allow the `mtime` heuristic to work.

---
*Analysis completed as requested without modifying any source code in the repository.*

## Follow-up Status (2026-04-12)

- Issue 1 (Ghost active Codex subagent rows): **Fixed**
- Issue 2 (Claude sessions showing as open when active): **Fixed**
- Issue 3 (New session not recognized until first prompt): **Fixed**

## Additional Known Issue (2026-02-28)

### Issue 3: New session after agent restart is not recognized until first user prompt

**Observed Behavior:**
- Repro sequence:
  1. Work in session A.
  2. Stop agent (for example `Ctrl+C`).
  3. Start agent again from terminal, creating session B.
  4. Do not send a prompt yet.
- Current result:
  - Agent Sessions often still treats session A as current/live and does not promote session B.
  - After the first user prompt in session B, classification snaps into expected behavior:
    - session A moves to past,
    - session B becomes active or idle.

**Scope:**
- Reproducible with both Codex and Claude session flows.
- Appears to be a startup / first-event session-identity transition gap rather than a steady-state classifier issue.

**Hypothesis (for future investigation):**
- A newly spawned terminal agent process without a first user event may not yet expose enough durable join signals (`session_id`, log-path ownership/write activity, prompt metadata) for deterministic session handoff from A to B.
- The first prompt creates the first unambiguous session-specific signal, allowing the join/classifier to correct state.

**Investigation Notes to Capture Next:**
- Presence payload before/after first prompt for A and B (`sessionId`, `sessionLogPath`, `workspaceRoot`, `tty`, `pid`, `lastSeenAt`).
- iTerm probe metadata before/after first prompt (`is processing`, `is at shell prompt`, tail excerpt).
- Process-to-session join evidence before/after first prompt (`lsof`/`ps` mapping for both sessions).
