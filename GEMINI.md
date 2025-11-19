# Gemini Code Assistant Context

This document provides context for the Gemini Code Assistant to understand the codebase.

## Project Overview

This project is a native macOS application named "Agent Sessions". It provides a unified interface for browsing, searching, and resuming sessions from three different AI command-line tools: Codex CLI, Claude Code, and Gemini CLI.

The application is built using **Swift** and **SwiftUI**. It is a local-first application, meaning it reads session data directly from the local filesystem without any cloud integration. The core functionality revolves around indexing and displaying session data from different sources in a unified user interface.

Key features include:
- Unified session browser for Codex, Claude, and Gemini CLIs.
- Full-text search across all sessions.
- Ability to resume Codex and Claude sessions.
- Usage tracking for Codex and Claude.
- An analytics dashboard to visualize AI coding patterns.
- A Git Context Inspector for Codex sessions.

The application is structured as a standard Xcode project (`AgentSessions.xcodeproj`). The main application logic is written in Swift, and the UI is built with SwiftUI.

## Building and Running

The project is built and run using Xcode and the `xcodebuild` command-line tool.

### Building

To build the project, run the following command in the root directory:

```sh
xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

This will build the application in the `DerivedData` directory. A successful build will create an `AgentSessions.app` bundle.

### Testing

To run the unit tests, use the following command:

```sh
xcodebuild test -scheme AgentSessionsLogicTests -destination 'platform=macOS'
```

## Development Conventions

- The project uses SwiftUI for the user interface.
- The codebase is written in Swift.
- The project follows standard Swift and SwiftUI conventions.
- The project uses `XCTest` for unit testing.
- The project uses `.swiftlint.yml` for linting.
- Continuous integration is set up using GitHub Actions (`.github/workflows/ci.yml`).
