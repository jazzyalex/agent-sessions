# Agents Guidelines

## Build & Review Discipline
- Do not ask the user to “confirm” or “if it looks good” until the code compiles locally with zero build errors.
- After making changes that affect Swift sources or Xcode integration, validate by building the active scheme.
- If the project cannot be built in your environment, clearly state what prevented the build, and provide the exact file and line references you validated.

## Instructions for Codex CLI

### Explain Before Coding (Non-Breaking Flow)
ALWAYS explain your plan before making ANY code changes, but continue automatically unless interrupted:

1. **Print your plan FIRST** - State what you'll change and why
2. **Then proceed immediately** - Start coding right away (user can press ESC during explanation to cancel)
3. **No waiting/prompting** - Don't ask "Should I proceed?" or wait for explicit approval unless you see words "plan mode ++" or "plan mode++" in a prompt
4. **Do not stop after the plan** - If you say you are proceeding, you must actually begin the implementation in the same turn (tool calls / edits). If you cannot proceed (blocked, need clarification), say so explicitly instead of implying you will continue.

### Format
```
I'll make the following changes:
- File X: Add/modify Y because Z
- File A: Remove B because C

[Immediately proceed with code changes - user has ESC window during explanation]

- Edited file.swift...
```

### Flow Pattern
**Correct:** Explain what will be done → Code → Results

### Examples of What NOT to Do
❌ Don't: Start with "• Edited file.swift..." before explaining
❌ Don't: Ask "Should I proceed?" or wait for confirmation
❌ Don't: Begin analyzing/thinking without stating the plan upfront

### Examples of What TO Do
✅ Do: "I'll tighten probe detection by requiring Probe WD for /status sessions and limiting marker matching. This reduces false positives." [then immediately start coding]
✅ Do: State the approach clearly, then flow directly into implementation
✅ Do: Give user the ESC window by printing plan first, but maintain momentum

### Special Mode
When user says "plan mode++" - ONLY provide the plan and stop. Wait for explicit approval before coding.

This applies to ALL coding requests. The explanation is for transparency and ESC opportunity, not for breaking flow.

### Significant change gating (must build before presenting)
Treat a change as “significant” and always run a build locally before presenting results when any of the following are true:
- Added, moved, or renamed any Swift file (app or tests).
- Modified more than ~40 lines of Swift across the app, or touched 2+ top‑level areas (e.g., Views + Services, Model + Views).
- Introduced or changed concurrency boundaries (actors, Task, async/await), or cross‑module interactions.
- Altered window/layout/toolbar structure or target membership (PBXBuildFile/target Sources).
- Changed build settings, target configuration, Info.plist, or added resources.

It is acceptable to present without building for clearly minor edits, for example:
- One‑line fixes that do not affect types/signatures, string/label copy changes, comment/doc updates, or pure Markdown/JSON assets.
- In case of doubt, prefer to build.

Suggested build steps
- Xcode: Product → Build (active scheme).
- CLI: `xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug build` (or use your configured build task).

## Conventional Commits and Trailers
- Use Conventional Commits for every commit (feat, fix, docs, chore, etc.).
- Include trailers in the commit body:
  - `Tool: Cursor|Codex|Xcode|Manual|Claude|Figma`
  - `Model: <model-id>`
  - `Why: <1 line if behavior/structure changed>`

## User‑Visible Changes
- If you change user‑visible behavior or UI, add:
  - A bullet under `[Unreleased]` in `docs/CHANGELOG.md`.
  - A 1–2 bullet note in `docs/summaries/YYYY-MM.md`.

## Documentation Style
- **Never use emoji** in user-facing documentation, including:
  - README.md
  - GitHub release notes
  - CHANGELOG.md
  - Other user-facing documentation
- Use clear, concise language without emoji decoration.

## Xcode Project Hygiene
- When adding/moving/renaming Swift files (app or tests), ensure they are added to `AgentSessions.xcodeproj` with both a `PBXFileReference` and a `PBXBuildFile` in the correct target. Missing entries will break builds with "Cannot find … in scope".

## Adding New Swift Files to Xcode Project
When creating new Swift files, use the tested Ruby script to add them to the Xcode project:


**Script Location**
`scripts/xcode_add_file.rb` - Adds a Swift file to a target with proper PBXFileReference and PBXBuildFile entries.

**Usage Examples**

Add file to main app target under GitInspector group:
```bash
./scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessions \
  AgentSessions/GitInspector/Models/InspectorKeys.swift \
  AgentSessions/GitInspector/Models
```

Add file to test target:
```bash
./scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessionsTests \
  AgentSessionsTests/GitInspectorViewModelTests.swift \
  AgentSessionsTests
```

Add multiple files:
```bash
./scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessions \
  AgentSessions/GitInspector/Utilities/ColorExtensions.swift \
  AgentSessions/GitInspector/Utilities

./scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessions \
  AgentSessions/GitInspector/Views/StatusHeroSection.swift \
  AgentSessions/GitInspector/Views
```

**Verification**
Always build after adding files to verify they're properly integrated:
```bash
xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions \
  -configuration Debug -destination 'platform=macOS' build
```

**CRITICAL: After ANY modification to project.pbxproj**
If you modify `AgentSessions.xcodeproj/project.pbxproj` directly (NOT using the Ruby script):
1. **ALWAYS** resolve package dependencies first:
   ```bash
   xcodebuild -resolvePackageDependencies -project AgentSessions.xcodeproj -scheme AgentSessions
   ```
2. **THEN** verify the build succeeds:
   ```bash
   xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug build
   ```
3. If package resolution fails or reports "Missing package product", the project.pbxproj was corrupted. Restore from git and use the Ruby script instead.

## UI/UX Rules (HIG‑Aligned)
- If content may exceed the window height, place the main content in a vertical `ScrollView` and keep footer/action controls outside the scroll region so actions remain visible.
- Use the shared spacing tokens and dynamic system colors. Avoid ad‑hoc paddings; prefer consistent section spacing and card padding.

## Safety & Execution
- Avoid shelling out when a safe `Process` + argument list is possible. Use timeouts and clear, inline error messages for failures.
- Never run network operations without an explicit user action and clear UX affordances.


## Pattern Search & Deletion Safety (General)

When you search logs, filenames, or code and when you build scripts that might rename/move/delete files, follow these rules. They exist to prevent over‑matching (regex accidents) and accidental data loss.

### Search rules (use literals by default)
- Prefer ripgrep (`rg`) with fixed‑string mode for markers/tokens:
  - `rg -nF "[MY_MARKER v1]" path -g '**/*.jsonl'`
- If you must use regex: escape or anchor and include a quick test.
  - Brackets `[]`, `()`, `.`, `+`, `?`, `|`, `^`, `$` are metacharacters.
  - For JSON keys, match with quotes and minimal context: `rg -n '"key"\s*:\s*"value"'`.
- Always quote variables to prevent globbing and word‑splitting in shell:
  - `grep -F -- "$needle" "$file"` (not `grep $needle $file`).
- Scope searches with globs and roots; never scan `$HOME` blindly:
  - `rg -nF "$MARK" "$ROOT" -g '**/*.jsonl'`.
- Verify with a small sample before proceeding:
  - `rg -nF "$MARK" | head -n 20` and open a couple of files.

### Counting and classification
- Produce a brief “confusion matrix” for any non‑trivial match set:
  - Count by reason (e.g., `marker_only`, `path_only`, `both`).
  - Show 3 sample paths per bucket.
- Save manifests for later review (plain text or JSONL).

### Deletion / purge rules (must follow all)
1) Dry‑run by default
   - Every destructive script starts in dry‑run and prints counts, sample paths, and the exact command it would run.

2) Two‑signal match for deletion
   - Require at least two independent signals (e.g., marker AND working directory) before deleting. A single grep hit is insufficient.

3) Typed confirmation with exact count
   - To proceed, user must pass `--execute` and type a confirmation string that includes the count (e.g., `delete 22 files`).

4) Random sample preview for large sets
   - If deleting >20 items, print a random sample of 20 with the fields that justify deletion (e.g., first user line, cwd) before confirmation.

5) Narrow scope and guard rails
   - Restrict deletes to an explicit root; refuse to run on `/`, `$HOME`, or a missing/empty `$ROOT`.
   - Use `find ... -print0 | xargs -0` to handle spaces/newlines safely.
   - Never run `rm -rf` on interpolated paths without printing and pausing first.

6) Logging and rollback aids
   - Save a timestamped manifest of everything scheduled for deletion (and a copy of stdout) to `scripts/probe_scan_output/` or a similar audit folder.
   - Prefer moving to a quarantine folder first (with timestamp) when feasible; hard‑delete only after a second confirmation.

7) Tests / fixtures (for repo scripts)
   - Add positive and negative fixtures that prove the matcher is literal when required (e.g., markers with `[]`).
   - In CI, fail if expanding the pattern increases matches against the fixture corpus unexpectedly.

### Quick shell snippets (safe patterns)
- Literal marker search in JSONL:
  - `rg -nF "[AS_MARKER v1]" "$ROOT" -g '**/*.jsonl' | cut -d: -f1 | sort -u`
- JSON key/value search (escaped quotes):
  - `rg -n '"(cwd|project)"\s*:\s*".*MyProbeDir' "$ROOT" -g '**/*.jsonl'`
- Null‑safe deletion (dry‑run):
  - `find "$ROOT" -type f -name '*.jsonl' -print0 | xargs -0 -n100 echo rm -v` (prints planned deletes)
