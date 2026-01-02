# Contributing

## Build
1. macOS version: <min version>
2. Xcode version: <version>
3. Open `AgentSessions.xcodeproj` (or .xcworkspace)
4. Build and run the `AgentSessions` target.

## Project structure
- Parsers: <path>
- Session sources registry: <path>
- Search/index: <path>
- UI: <path>

## Adding a new agent source
1. Add a new SessionSource case.
2. Implement parser + discovery.
3. Add fixtures under <path>.
4. Add/adjust tests (if any).

## Pull requests
- Keep PRs focused.
- Include a short “before/after” note and test plan.
