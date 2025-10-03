# Claude Code Resume Integration (Spec)

## Purpose
Enable “Resume in Claude” from a selected Claude Code session in Agent Sessions. This spec covers CLI behavior, command construction, launcher design, settings, fallbacks, and QA.

## Summary
- Primary path: resume by session ID using the Claude CLI.
- Fallback path: continue the most recent session in the session’s working directory.
- Launcher opens Terminal (or iTerm2) and executes a single, quoted command line.
- Coordinator probes CLI capabilities, picks the safest strategy, and surfaces clear errors.

## CLI Flags and Behavior
- Resume by ID: `claude --resume "<session-id>"` (short: `-r`).
- Continue most recent (cwd‑scoped): `claude --continue` (short: `-c`).
- Update CLI: `claude update`.

Notes
- Both resume and continue start interactive sessions. Passing an inline prompt is supported but not required for our flow.
- Some CLI versions may differ in help text or long/short flag exposure. The coordinator should probe at runtime.

References
- CLI usage: Anthropic Claude Code documentation (CLI reference).

## Session Data Sources
- `sessionId`: Extract from the Claude session JSONL (preferred). If absent, fall back to filename UUID where applicable.
- `cwd`: Use the `cwd` field in events to set the working directory for the shell before launching the CLI.

## Command Builder
Inputs
- `sessionID: String?`
- `cwd: URL?` (preferred when available)
- `binaryPath: String?` (defaults to `claude` when nil)
- `mode: resumeByID | continueMostRecent | interactivePicker` (target strategy)

Output
- `commandString: String` suitable for `sh -lc` in Terminal/iTerm.

Rules
- Always `cd` first when a working directory is known: `cd "<cwd>";`.
- Prefer resume by ID when `sessionID` is non‑empty and CLI supports it: `claude --resume "<id>"`.
- If resume is unavailable/undesired, construct continue: `claude --continue`.
- Quote all dynamic values with a safe shell‑escape. Treat `sessionID` as opaque.
- Do not inject additional flags by default; keep the command minimal and predictable.

Examples
- Resume by ID: `cd "/Users/alexm/Repo"; claude --resume "06cc67e8-9cc6-4537-83a9-ce36374a4c31"`
- Continue most recent: `cd "/Users/alexm/Repo"; claude --continue`

## Launcher (macOS)
Terminal.app
- Use AppleScript to open a new window/tab and run: `do script "<commandString>"` then `activate`.
- Example AppleScript: `tell application "Terminal" to do script "<command>"` followed by `tell application "Terminal" to activate`.

iTerm2 (optional)
- If enabled in preferences, use iTerm2 AppleScript to create a new window and send the command to the current session.

## Coordinator
Responsibilities
- Probe: run `claude --version` (and `--help`) to detect availability of `--resume`/`-r` and `--continue`/`-c`.
- Strategy: choose one of `resumeByID` → `continueMostRecent` → `interactivePicker` based on capability, settings, and inputs.
- Build: delegate to Command Builder with resolved binary path and cwd.
- Launch: invoke the Launcher to open Terminal/iTerm with the command.
- Report: return a structured result indicating strategy used and any error.

Fallback Logic (default)
1) If `sessionID` is present and `--resume` is available, use resume by ID.
2) If (1) fails or `--resume` is unavailable, use `--continue` with the session’s `cwd`.
3) If neither is viable, launch with no arguments (interactive usage) or show a copyable command to run manually.

Error Handling
- Missing CLI: present guidance to install or set a custom binary path; include a “Test” button to re‑probe.
- Known‑bad versions: detect by parsing `--version` output and switch to `--continue` with a short note.
- Non‑zero exit when probing: surface stderr and provide a copyable fallback command.

## Settings
Keys
- `claudeResume.binaryPath: String?` (nil ⇒ `claude` on PATH)
- `claudeResume.preferITerm: Bool` (default false)
- `claudeResume.fallbackPolicy: enum { resumeThenContinue, resumeOnly }` (default `resumeThenContinue`)
- `claudeResume.defaultWorkingDirectory: URL?` (used when a session lacks `cwd`)

UI
- Preferences → Claude Code Resume
  - Binary path override with “Test” button (runs `--version`).
  - Toggle: “Use iTerm2 instead of Terminal”.
  - Toggle: “If resume fails, try continue in cwd”.
  - Default working directory chooser.

## UI Wiring
- Toolbar: add “Resume in Claude” when a session is selected.
- Context menu: “Resume in Claude” on session rows.
- Command menu: shortcut (match Codex).
- Transcript toolbar: add the same action when a session is loaded.

## Security and Robustness
- Shell‑escape `cwd` and `sessionID` to avoid injection.
- Handle paths with spaces and unicode.
- If `cwd` does not exist, still open Terminal and print a clear message; do not silently switch directories.

## Compatibility Notes
- Resume by ID and continue are supported by recent Claude CLI builds; probe rather than hard‑coding assumptions.
- A regression has been reported in at least one release where `--resume` starts a new session instead of resuming. Use the fallback policy when this is detected.

## QA Checklist
- Resume by ID (valid ID) launches and attaches to the correct session.
- Resume by ID (invalid ID) falls back to continue when the preference allows it.
- Continue works when `cwd` is present; shows an actionable error when `cwd` is missing.
- Missing CLI shows guidance and respects binary path override.
- Version probe distinguishes supported vs. unsupported flags and applies fallback.
- Terminal and iTerm2 launchers both run the same built command.

## Future Enhancements
- Optional single‑shot prompt on resume for immediate follow‑ups (disabled by default).
- Headless/automation mode (e.g., stream JSON output) as a power‑user option in preferences.

## References
- Anthropic Claude Code – CLI Reference: https://docs.anthropic.com/en/docs/claude-code/cli-usage
- Anthropic Claude Code – Getting Started: https://docs.anthropic.com/en/docs/claude-code/getting-started
- Resume regression report (community issue): https://github.com/anthropics/claude-code/issues/3188
- SDK Sessions (session identifiers background): https://docs.claude.com/en/docs/claude-code/sdk/sdk-sessions
