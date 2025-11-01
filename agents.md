# Agents Guidelines

## Build & Review Discipline
- Do not ask the user to “confirm” or “if it looks good” until the code compiles locally with zero build errors.
- After making changes that affect Swift sources or Xcode integration, validate by building the active scheme.
- If the project cannot be built in your environment, clearly state what prevented the build, and provide the exact file and line references you validated.

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

**Prerequisites**
```bash
gem install xcodeproj
```

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

Add multiple files (example from GitInspector):
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
