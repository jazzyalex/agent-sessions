# Cursor ACP Subagent Hierarchy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Attach Cursor JSONL subtask rows to an ACP parent only when the ACP root explicitly references the child's transcript path, then render the relationship through the existing collapsible hierarchy.

**Architecture:** Add a result-bearing ACP parser API that extracts only the bounded root protobuf field-18 resource paths. Apply a normalized path-to-parent map after lightweight hydration (including cache hits), using a field-preserving `Session` relationship copy and fail-closed conflict rules; let `SubagentHierarchyBuilder` continue to own flattening and collapse behavior.

**Tech Stack:** Swift, SwiftUI, SQLite3, XCTest, existing `Session`/`SubagentHierarchyBuilder`/`SessionIndexingEngine` infrastructure.

---

### Task 1: Define ACP parse result and bounded path extraction

**Files:**
- Modify: `AgentSessions/Services/CursorSessionParser.swift` (`CursorACPStoreReader`)
- Test: `AgentSessionsTests/CursorSessionParserTests.swift`

- [ ] **Step 1: Add failing result/API tests**

  Extend the synthetic ACP store fixture helper to encode root field 18 resource paths and add tests that:

  - accept `agent-transcripts/<rootUUID>/<rootUUID>.jsonl` as the root layout but do not treat it as a child;
  - accept `agent-transcripts/<parentUUID>/subagents/<childUUID>.jsonl` with distinct valid UUIDs;
  - ignore field-18 paths with wrong UUID layout, non-JSONL extensions, relative paths, and paths placed only in tool/blob payloads;
  - assert `parseResult(at:)` returns a `Session` plus referenced normalized path set while `parse(at:)` remains session-only compatible.

  Run: `xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -destination 'platform=macOS' -only-testing:AgentSessionsTests/CursorSessionParserTests test CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO`

  Expected: FAIL because the result type and path extraction do not exist.

- [ ] **Step 2: Implement the bounded result type and extractor**

  Add `CursorACPParseResult` with the parsed session and referenced transcript paths. Keep `parse(at:)` as a wrapper. Decode only repeated root field 18 wire-type-2 values, validate the two exact path layouts, and normalize lexically without symlink resolution. Keep all existing schema/root/turn validation and sensitive-payload exclusion unchanged.

- [ ] **Step 3: Run parser tests**

  Run the command from Step 1.

  Expected: PASS, including unknown-schema and incomplete-graph regressions.

- [ ] **Step 4: Commit**

  ```bash
  git add AgentSessions/Services/CursorSessionParser.swift AgentSessionsTests/CursorSessionParserTests.swift
  git commit -m "feat: expose explicit Cursor ACP transcript references"
  ```

### Task 2: Add field-preserving relationship mutation

**Files:**
- Modify: `AgentSessions/Model/Session.swift`
- Test: `AgentSessionsTests/SessionParserTests.swift` or a focused new `AgentSessionsTests/SessionRelationshipTests.swift`

- [ ] **Step 1: Write the failing copy-preservation test**

  Construct a Cursor session populated with events, model, project metadata, titles, surface/originator fields, lightweight counts, favorite/runtime flags, and existing relationship metadata. Assert the relationship-copy helper changes only `parentSessionID`, `subagentType`, and `relationshipKind` while preserving every other field.

  Run: `xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -destination 'platform=macOS' -only-testing:AgentSessionsTests/SessionRelationshipTests test CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO`

  Expected: FAIL because no helper exists.

- [ ] **Step 2: Implement a dedicated relationship-copy helper**

  Add an internal/publicly testable helper on `Session` that returns a copy with relationship fields changed and all immutable metadata/events plus runtime state preserved. Do not reconstruct sessions at call sites with partial initializers.

- [ ] **Step 3: Run the focused test**

  Expected: PASS with equality checks for all relevant fields.

- [ ] **Step 4: Commit**

  ```bash
  git add AgentSessions/Model/Session.swift AgentSessionsTests/SessionRelationshipTests.swift
  git commit -m "refactor: preserve Cursor session metadata when linking"
  ```

### Task 3: Apply explicit associations after fresh or cached hydration

**Files:**
- Modify: `AgentSessions/Services/CursorSessionIndexer.swift`
- Modify: `AgentSessions/Cursor/CursorSourceDescriptor.swift` (route full ACP parsing through the result API where required)
- Test: `AgentSessionsTests/CursorSessionParserTests.swift` and/or `AgentSessionsTests/SessionParserTests.swift`

- [ ] **Step 1: Add failing association tests**

  Add pure/indexer-facing tests for:

  - one ACP parent and one matching child path → child becomes `parentSessionID = cursor-acp:<uuid>`, `subagentType = cursor-acp-subagent`, `.subagent`;
  - a timestamp-prefixed JSONL without an ACP reference remains unassociated;
  - same-parent repeated references deduplicate;
  - two ACP parents referencing one child remain unresolved, even when one raw path-derived parent UUID matches;
  - an existing raw path-derived parent UUID matching the sole ACP candidate is upgraded to the namespaced ACP ID;
  - conflicting authoritative metadata is preserved;
  - association is applied to sessions returned from `hydrateOrScan` cache as well as freshly parsed sessions;
  - removing a referenced transcript on a later scan leaves no dangling child row.

- [ ] **Step 2: Implement normalized path lookup and fail-closed association**

  Build a normalized-path-to-`Set<String>` parent map from all ACP parse results. Apply it after `hydrateOrScan` returns and before Cursor metadata merge/sort. Require exactly one candidate before any upgrade; handle raw path-derived parent UUID matching as specified; use the field-preserving helper.

- [ ] **Step 3: Update full parse call sites**

  Preserve `Session?` descriptor contracts by using the result API internally and returning `.session` where a full parser closure needs only a session. Ensure reload/search paths do not lose the relationship metadata.

- [ ] **Step 4: Run targeted tests**

  Run the Cursor parser and session parser test subsets.

  Expected: PASS; no existing ACP parser or hierarchy regressions.

- [ ] **Step 5: Commit**

  ```bash
  git add AgentSessions/Services/CursorSessionIndexer.swift AgentSessions/Cursor/CursorSourceDescriptor.swift AgentSessionsTests/CursorSessionParserTests.swift AgentSessionsTests/SessionParserTests.swift
  git commit -m "feat: link explicitly referenced Cursor ACP subtasks"
  ```

### Task 4: Render ACP-backed child relationship

**Files:**
- Modify: `AgentSessions/Services/SessionRowsBuilder.swift`
- Modify: `AgentSessions/Views/UnifiedSessionsView.swift` only if the existing generic sub marker needs an ACP-specific accessibility/help string
- Test: `AgentSessionsTests/SessionRowDisplayTests.swift` and `AgentSessionsTests/SessionRowsBuilderTests.swift`

- [ ] **Step 1: Add failing UI/pill tests**

  Assert the ACP parent retains the `acp` surface pill. Assert a linked child gets the generic `sub` marker and localized/accessibility text indicating an ACP subagent, while the internal value `cursor-acp-subagent` is never rendered literally. Assert hierarchy indentation and child count use the existing builder metadata.

- [ ] **Step 2: Implement the smallest rendering change**

  Reuse the existing `SubagentHierarchyBuilder` and generic sub marker. Add only the ACP-specific accessibility/help mapping needed for `cursor-acp-subagent`; do not add new table columns or duplicate hierarchy connections.

- [ ] **Step 3: Run row tests**

  Expected: PASS, including existing Cursor/Claude/Codex surface-pill tests.

- [ ] **Step 4: Commit**

  ```bash
  git add AgentSessions/Services/SessionRowsBuilder.swift AgentSessions/Views/UnifiedSessionsView.swift AgentSessionsTests/SessionRowDisplayTests.swift AgentSessionsTests/SessionRowsBuilderTests.swift
  git commit -m "feat: show Cursor ACP subagent hierarchy"
  ```

### Task 5: Full verification and documentation

**Files:**
- Modify: `README.md` or `docs/guides/cursor-agent-local-history.html` only if the existing ACP capability matrix needs the new explicit-association boundary documented
- Test: existing full AgentSessionsTests suite

- [ ] **Step 1: Run focused regression suite**

  Run parser, indexer, hierarchy, row, and source-registry tests.

- [ ] **Step 2: Run full build and test**

  ```bash
  xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug -destination 'platform=macOS' -derivedDataPath .deriveddata-acp-subagents CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
  xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -destination 'platform=macOS' -derivedDataPath .deriveddata-acp-subagents -only-testing:AgentSessionsTests test CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
  ```

- [ ] **Step 3: Run repository checks**

  Run `git diff --check` and the localization validation commands required by the current CI baseline.

- [ ] **Step 4: Review the resulting UI with a real ACP store**

  Use a read-only local Cursor fixture or the existing local ACP store to verify one parent row, its ACP pill, expandable child count, and nested child rows. Do not commit real transcripts or databases.

- [ ] **Step 5: Commit documentation if needed**

  ```bash
  git add README.md docs/guides/cursor-agent-local-history.html
  git commit -m "docs: describe explicit Cursor ACP subagent links"
  ```
