# Agents Guidelines

Shared playbook for every agent working in this repo (Claude, Codex, Cursor, Xcode, etc.).
Write like a person: plain words, short sentences, no filler, no emoji. If a rule here
needs decoding, that's a bug — fix the wording.

## Marketing / promo
All marketing, promo, and growth work goes through `Marketing/STATUS.md` — read it first,
update it last. It indexes the detail files (goals, star log, angles, launch kits).
Agents draft; the owner posts from their own accounts. `Marketing/` is gitignored and
local to this machine.

## Build & review discipline
- Don't ask the user to "confirm if it looks good" until the code builds with zero errors.
- After changing Swift sources or Xcode project files, build the active scheme.
- If you can't build in your environment, say exactly why and list the file:line
  references you did verify.

**When a build is mandatory before presenting:** you added/moved/renamed any Swift file;
changed more than ~40 Swift lines or touched two or more top-level areas (say, Views +
Services); touched concurrency (actors, Task, async/await); changed window/toolbar/layout
structure or target membership; changed build settings, Info.plist, or resources.
Skipping the build is fine only for clearly minor edits — one-liners that don't touch
types or signatures, copy changes, comments, plain Markdown/JSON. In doubt, build.

Build commands:
- Xcode: Product → Build.
- CLI: `xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug build`

## Tests
Use the stable wrapper: `./scripts/xcode_test_stable.sh`. It isolates test artifacts in
`.deriveddata-tests`, which avoids intermittent nested-code-signature failures.

Equivalent direct command:
`xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .deriveddata-tests -parallel-testing-enabled NO clean test`

Keep that derived-data path **relative**. It once read `"$PWD/.deriveddata-tests"`, someone
copied it into a context that didn't expand `$PWD`, and a literal `$PWD/` directory sat in
the repo root unnoticed for four months. Relative can't fail that way.

## Swift/macOS QA
- If a QA script forces macOS Appearance to Dark, set it back to System when done.
- Relaunching the app to test a change is two commands — don't hunt for a "run" skill:
  `killall AgentSessions 2>/dev/null; open .deriveddata-manual/Build/Products/Debug/AgentSessions.app`
  (that's the output of a manual build with `-derivedDataPath .deriveddata-manual`).
  Never launch an app bundle from a derived-data path that ran `xcodebuild test` — test
  runs re-sign the bundle and it launches invisible.
- Use UI automation (computer-use, screenshots) only when explicitly asked.
- Codex Desktop sandbox note: `xcodebuild`, SwiftPM, and XCTest need Xcode's cache
  directories (DerivedData, ModuleCache, SourcePackages, simulator caches), which sit
  outside the workspace sandbox. Request approved Xcode access up front for those runs.
  If a run fails purely because the sandbox blocked a cache path, rerun the same command
  with access and report it as a sandbox retry — not a code or test failure. Approve
  narrow command prefixes (the canonical build/test commands, the test wrapper), never
  broad "anything Xcode-ish" rules.

## How to work (explain, then go)
State what you're about to change and why in two or three bullets, then immediately do
it. The explanation gives the user an ESC window — it is not a request for permission.
Don't ask "should I proceed?"; don't start editing before saying what you're doing;
don't stall.

Exception: if the user says **"plan mode++"**, deliver the plan only and wait for
explicit approval.

## Git: branches, worktrees, commits
- **Never create, switch, rename, or delete a branch or worktree without explicit user
  approval.** That includes `checkout -b`, `switch -c`, `branch -d/-D`, `worktree add`.
- This working tree may be shared by several concurrent agent sessions; moving `HEAD`
  moves it for all of them. Work on the current branch. If isolation seems warranted,
  propose it and wait.
- Commits and pushes are user-initiated only.
- Use Conventional Commits (feat, fix, docs, chore, …) with trailers in the body:
  `Tool: Cursor|Codex|Xcode|Manual|Claude|Figma`, `Model: <model-id>`,
  `Why: <one line, if behavior or structure changed>`.

## User-visible changes
If you change behavior or UI the user can see, add a bullet under `[Unreleased]` in
`docs/CHANGELOG.md` and a one-or-two-bullet note in `docs/summaries/YYYY-MM.md`.

## Writing style (docs and reports)
- No emoji anywhere user-facing: README, release notes, CHANGELOG, docs.
- Every claim in an audit, plan, or report needs evidence — file paths, line numbers, or
  exact output. If something is unverified, label it a hypothesis outright
  ("Hypothesis: X may cause Y because Z"). Don't hedge verified facts with "likely" or
  "seems to", and don't state guesses as facts.

## Backlog (`docs/backlog.md`)
- Deferred work gets an entry — follow the "How to read this file" legend at the top,
  including the stamp line (`> **open** · sev: … · urg: … · verified …`).
- Severity = what breaks. Urgency = time pressure. Keep them separate.
- `verified` is the date the entry was last checked against the code, not when it was
  filed. Re-verify before acting on an old date, and update the stamp when you do.
- Closing an entry = collapse it to a two-line tombstone (date, commit, test) or delete
  it if GitHub/CHANGELOG already records it. Never move entries to a second file.

## Adding Swift files to the Xcode project
Every new Swift file needs a `PBXFileReference` and a `PBXBuildFile` in the right target,
or the build fails with "Cannot find … in scope". Use the script — argument order is
PROJECT TARGET FILE GROUP:

```bash
./scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessions \
  AgentSessions/Feature/NewFile.swift AgentSessions/Feature
# test target:
./scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessionsTests \
  AgentSessionsTests/NewFileTests.swift AgentSessionsTests
```

A correct run adds exactly 4 lines to project.pbxproj per file. Build afterwards to
verify. If you ever edit project.pbxproj by hand instead: run
`xcodebuild -resolvePackageDependencies -project AgentSessions.xcodeproj -scheme AgentSessions`,
then build; if resolution reports "Missing package product", the pbxproj is corrupted —
restore from git and use the script.

## UI/UX (HIG-aligned)
- Content that can exceed window height goes in a vertical `ScrollView`; keep footer and
  action controls outside the scroll so they stay visible.
- Use the shared spacing tokens and dynamic system colors. No ad-hoc paddings.
- For subtle visual changes, find the layer that actually paints the pixels before
  editing — a nearby palette, token, or model value is not automatically the one in use.
  Trace modifiers, `NSViewRepresentable`s, layout managers, drawing overrides, and cached
  attributed strings as needed, then patch that layer and check the diff lands there.

## Safety & execution
- Prefer `Process` with an argument list over shelling out. Use timeouts; surface errors
  inline and clearly.
- No network operations without an explicit user action and clear UX around it.
- No feature flags, rollout gates, or kill switches unless the user asked for them in
  the current request. When unsure, implement directly and note the risk in the summary.

## Remote doc/header fetches
Delegate remote documentation or API inspection to a sub-agent so the main session stays
responsive. Hard timeout: 20 seconds per attempt. On timeout, cancel and fall back —
local repo docs first, then one narrower remote source. No unbounded retries; if the
fallback also fails, say so and continue with local reasoning.

## Search & deletion safety
These rules prevent regex over-matching and accidental data loss.

**Searching:**
- Default to literal search: `rg -nF "[MY_MARKER v1]" "$ROOT" -g '**/*.jsonl'`.
  Remember `[] () . + ? | ^ $` are regex metacharacters — `-F` sidesteps all of that.
- Quote every variable: `grep -F -- "$needle" "$file"`, never `grep $needle $file`.
- Scope with roots and globs; never scan `$HOME` blindly.
- Sample before trusting: `rg -nF "$MARK" | head -20`, then open a couple of hits.
- For any non-trivial match set, count by match reason (marker-only / path-only / both)
  with a few sample paths per bucket, and save the manifest.

**Deleting (all rules apply):**
1. Dry-run by default — print counts, sample paths, and the exact command before doing
   anything.
2. Require two independent signals per file (e.g. marker AND working directory); one
   grep hit is never enough.
3. Execution needs `--execute` plus a typed confirmation containing the exact count
   ("delete 22 files").
4. Deleting more than 20 items? Print a random sample of 20 with the evidence fields
   first.
5. Restrict to an explicit root; refuse `/`, `$HOME`, or an empty `$ROOT`. Use
   `find … -print0 | xargs -0`. Never `rm -rf` an interpolated path without printing
   and pausing.
6. Save a timestamped manifest of everything scheduled for deletion (plus stdout) to an
   audit folder such as `scripts/probe_scan_output/`. Prefer quarantine-then-delete over
   direct hard deletes.
7. Repo scripts that match-and-delete need positive and negative fixtures proving the
   matcher is literal, and CI should fail if a pattern change unexpectedly widens matches.
