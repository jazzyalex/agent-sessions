**Claude Code Usage Probe Project & Cleanup**

**0. Context**

Agent Sessions (AS) periodically runs a small Claude Code session (“usage probe”) to fetch current limits and usage data. Claude stores every session inside `~/.claude/projects/...`, so these probe runs clutter the user’s session history with tiny “probe” sessions.

AS cannot disable Claude logging, but it can:
- Funnel all probe sessions into a dedicated Claude project.
- Hide those sessions inside AS.
- Offer user-controlled deletion of the dedicated project on demand or automatically.

This document defines probe behavior, identification of the probe project, UI exposure, and cleanup routines. Implementation details follow the rules below; no code appears in this spec.

**1. Goals / Non-Goals**

Goals
1. Prevent probe sessions from appearing in AS session lists, analytics, or UI.
2. Allow users to optionally delete probe sessions from disk.
3. Guarantee AS never modifies non-probe Claude projects.
4. Keep cleanup actions explicit and user-controlled through Preferences.

Non-Goals
- No changes to how Claude Code logs sessions.
- No deletion or modification of user-created Claude projects.
- No requirement to clean up when safety checks fail; in that case do nothing.

**2. Terminology**

- Probe session: A minimal Claude Code chat run by AS to obtain usage and limits.
- Probe working directory (Probe WD): Dedicated filesystem directory AS uses for probes.
- Claude projects root: `~/.claude/projects`.
- Probe project: The single Claude project under `~/.claude/projects` mapped to the Probe WD.
- Cleanup: Deleting the probe project folder (and nothing else) under `~/.claude/projects`.

**3. High-Level Design**

1. AS runs usage probes from a dedicated working directory (Probe WD) inside its app support folder.
2. Claude maps that directory to a single project under `~/.claude/projects`; that becomes the probe project.
3. AS parses probe responses for usage data and filters those sessions out of the UI.
4. Preferences exposes a Cleanup Settings block so users can:
   - Do nothing (default).
   - Trigger manual cleanup.
   - Enable automatic cleanup on startup or exit.
5. Cleanup is limited to the probe project and executes only when safety checks confirm exclusive probe usage.

**4. Probe Behavior**

**4.1 Dedicated Probe Working Directory**
- Create a directory, for example:
  - macOS: `~/Library/Application Support/AgentSessions/ClaudeProbeProject`.
- The directory is created when missing and reserved solely for usage probes.

**4.2 Running a Probe**
1. Determine whether the probe data is stale (see §8).
2. If stale:
   - Invoke Claude Code with Probe WD as the current working directory.
   - Navigate directly to `/usage` command (no user messages sent to preserve usage limits).
3. Parse the usage screen output to extract usage percentages and reset times.
4. Store the last successful probe timestamp and parsed data in AS's store.
5. Claude logs these sessions to the probe project; AS's import/indexer filters them from user-visible surfaces by working directory path matching.

**5. Identifying the Probe Project**

AS must map Probe WD to a single Claude project directory.

**5.1 Project Metadata Assumption**
- Claude stores project metadata under `~/.claude/projects/<project-id>/project.json` (or equivalent) that records the project’s root path.
- If metadata lacks the Probe WD path, disable cleanup and show an explanatory error.

**5.2 Discovery Process**
On first cleanup attempt (or when needed):
1. Enumerate subdirectories under `~/.claude/projects`.
2. For each project, read its metadata file.
3. Match the recorded root path to Probe WD.
4. When matched, persist the folder name as `probeProjectId`.
5. If no match exists, do not attempt deletion. User-initiated cleanup reports “No probe project found. Run a usage probe first.”
6. If metadata cannot be parsed, treat cleanup as unsupported and display a clear preference note.

**6. Cleanup Settings (Preferences UI)**

**6.1 Settings Block**
Preferences → Claude / Limits section adds a block titled “Claude Usage Probe Sessions”:
- Radio buttons:
  1. Don’t delete probe sessions (default).
  2. Delete probe sessions only when I click “Delete now”.
  3. Auto-delete probe sessions on app startup/exit.
- Show a `[ Delete probe sessions now ]` button when the selected mode allows cleanup.
- Provide explanatory text, e.g. “Agent Sessions runs tiny Claude Code sessions in a dedicated project to estimate usage limits. You can remove those probe sessions here. This never affects your normal Claude projects.”

**6.2 Behavior**
- Don’t delete: never attempt cleanup; button disabled or hidden.
- Delete only when I click: cleanup runs solely on button press; no automatic cleanup.
- Auto-delete: cleanup runs once per app lifecycle (startup or exit) and the button remains available for on-demand cleanup.
- On failure, show a concise error and avoid aggressive retries.

**6.3 Automatic Cleanup Timing**
- Prefer running on startup after preferences load and paths resolve, ensuring stale projects disappear early.
- Alternatively, run on exit before termination.
- Regardless of timing, execute at most once per run and only in Auto-delete mode.

**7. Cleanup Logic & Safety**

Cleanup deletes the probe project directory only when safe.

**7.1 Preconditions**
1. Cleanup mode permits deletion (manual or automatic).
2. `probeProjectId` is known or discoverable (per §5).
3. Probe project directory exists at `~/.claude/projects/<probeProjectId>`.
4. If any check fails, abort cleanup and surface a clear user message when applicable.

**7.2 Safety Validation**
1. Inspect session storage (e.g., JSONL files) inside the project.
2. Validate sessions are from the probe working directory and match the probe project path.
3. Safety checks: confirm sessions are tiny (≤5 events), contain no tool calls, and have only user/assistant events.
4. If any session fails validation, cancel deletion and notify the user: "Probe project appears to contain non-probe sessions; cleanup skipped to avoid data loss."
5. Note: Probe sessions send no user messages (only `/usage` command), so they should be minimal.

**7.3 Deletion Action**
1. When validation passes, delete the entire probe project directory.
2. Never touch other directories under `~/.claude/projects`.
3. Leave Probe WD intact; Claude will recreate the project on the next probe.
4. Retain `probeProjectId` in settings for reuse or rediscovery.
5. If deletion fails (permissions or I/O), show an error and stop without retry loops.

**8. Probe Frequency / Staleness Control**

Limit probe frequency to reduce session clutter even without cleanup.

**8.1 Preference (Optional but Recommended)**
- Add controls under Claude / Limits:
  - Checkbox: “Enable automatic limits refresh using Claude Code probes.”
  - Numeric field or slider for “Minimum time between probes” (default 30–60 minutes).

**8.2 Logic**
1. Store `lastProbeSuccessTime` and `lastProbeResult`.
2. Automatic mode runs probes only when `now - lastProbeSuccessTime` exceeds the minimum interval; otherwise reuse cached data.
3. User-triggered “Refresh limits now” always runs a probe immediately.

**9. Interaction with Session Import / Analytics**

- When importing Claude sessions, skip those from the probe project or mark them as `systemUtility` and hide them from session lists, project views, and analytics.
- Optionally add a debug toggle to expose system sessions; default is invisible.

**10. Error Handling & UX Notes**

- Metadata missing or unreadable: disable cleanup and explain that Claude project structure changed.
- Safety validation fails: disable cleanup for that project and show a warning about potential non-probe content.
- Filesystem or permission errors: surface a brief error and stop.
- AS communicates clearly that it never touches normal Claude projects—only the dedicated probe project when the user authorizes cleanup and safety checks pass.
