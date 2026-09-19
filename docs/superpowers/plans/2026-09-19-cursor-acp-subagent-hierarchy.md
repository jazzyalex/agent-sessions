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

  Extend the synthetic ACP store fixture helper to encode root field 18 resource paths using a protobuf varint key encoder (field 18's key is 146, so the helper must not take a `UInt8`) and add tests that:

  - accept absolute `/.../agent-transcripts/<rootUUID>/<rootUUID>.jsonl` as the root layout but do not treat it as a child;
  - accept absolute `/.../agent-transcripts/<parentUUID>/subagents/<childUUID>.jsonl` with distinct valid UUIDs;
  - ignore field-18 paths with wrong UUID layout, non-JSONL extensions, relative paths, and paths placed only in tool/blob payloads;
  - assert `parseResult(at:)` returns a `Session` plus referenced normalized path set while `parse(at:)` remains session-only compatible.

  Run: `xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -destination 'platform=macOS' -only-testing:AgentSessionsTests/CursorSessionParserTests test CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO`

  Expected: FAIL because the result type and path extraction do not exist.

- [ ] **Step 2: Implement the bounded result type and extractor**

  Add `CursorACPParseResult` with the parsed session and referenced transcript paths. Keep `parse(at:)` as a wrapper. Decode only repeated root field 18 wire-type-2 values, validate the two exact absolute-path layouts, and normalize lexically without symlink resolution. Exclude the root self-reference from the child-reference set (or make the association resolver ignore it). Keep all existing schema/root/turn validation and sensitive-payload exclusion unchanged.

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
- Test: Create `AgentSessionsTests/SessionRelationshipTests.swift`

- [ ] **Step 1: Write the failing copy-preservation test**

  Construct a Cursor session populated with `id`, `source`, start/end dates, model, file path/size, event count/events, project metadata, titles, surface/originator fields, lightweight counts, favorite/runtime flags, deleted state, and existing relationship metadata. Assert the relationship-copy helper changes only `parentSessionID`, `subagentType`, and `relationshipKind` while preserving every enumerated field.

  Run: `xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -destination 'platform=macOS' -only-testing:AgentSessionsTests/SessionRelationshipTests test CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO`

  Expected: FAIL because no helper exists.

- [ ] **Step 2: Implement a dedicated relationship-copy helper**

  Add an internal/publicly testable helper on `Session` that returns a copy with relationship fields changed and all immutable metadata/events plus runtime state preserved: `id`, `source`, start/end dates, model, file path/size, event count/events, `isHousekeeping`, `hasToolCallEvent`, lightweight cwd/repo/title/commands, custom title, Codex IDs/origin/source/surface, origin/source/surface, reasoning effort, deleted state, `isFavorite`, and `isPartiallyHydrated` must all survive. Do not reconstruct sessions at call sites with partial initializers.

  Because `SessionRelationshipTests.swift` is new, register it with `./scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessionsTests AgentSessionsTests/SessionRelationshipTests.swift AgentSessionsTests` before running the focused test.

- [ ] **Step 3: Run the focused test**

  Expected: PASS with equality checks for all relevant fields.

- [ ] **Step 4: Commit**

  ```bash
  git add AgentSessions/Model/Session.swift AgentSessionsTests/SessionRelationshipTests.swift
  git commit -m "refactor: preserve Cursor session metadata when linking"
  ```

### Task 3: Apply explicit associations after fresh or cached hydration

**Files:**
- Create: `AgentSessions/Services/CursorACPSubagentAssociation.swift` (pure path lookup, conflict resolution, and relationship application)
- Modify: `AgentSessions/Services/CursorSessionIndexer.swift`
- Modify: `AgentSessions/Cursor/CursorSourceDescriptor.swift` (route full ACP parsing through the result API where required)
- Do not modify: `AgentSessions/Services/SessionIndexer.swift`; the association resolver consumes the existing `hydrateOrScan` result without changing shared hydration behavior. If implementation proves a shared seam is unavoidable, stop and revise this plan before editing that file.
- Test: Create `AgentSessionsTests/CursorACPSubagentAssociationTests.swift`; extend `AgentSessionsTests/CursorSessionParserTests.swift` and its `CursorSessionParserTests`/`CursorSessionIndexerTests` classes

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

  Build a normalized-path-to-`Set<String>` parent map from all ACP parse results before the JSONL hydration call. After `SessionIndexingEngine.hydrateOrScan` returns (whether fresh or cached), pass the returned sessions through the pure association resolver before Cursor metadata merge/sort. Require exactly one candidate before any upgrade; handle raw path-derived parent UUID matching as specified; use the field-preserving helper. Rebuild the map and re-associate from the current discovery set on every full reconciliation so stale references cannot leave dangling children. The cache-path test must call the resolver with a cached session set directly; the stale-reference test must exercise a refresh mode that actually reconciles/removes missing files, not a cache-only fast path.

  Normalize only absolute paths with `URL(fileURLWithPath:).standardizedFileURL.path`; never call `resolvingSymlinksInPath`, never lower-case, and compare the resulting path strings exactly. The extractor rejects relative resource values before normalization.

  Register the new production service and its test with `./scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessions AgentSessions/Services/CursorACPSubagentAssociation.swift AgentSessions/Services` and the corresponding `AgentSessionsTests/CursorACPSubagentAssociationTests.swift` path before building.

- [ ] **Step 3: Update full parse and reload call sites**

  Preserve `Session?` descriptor contracts by using the result API internally and returning `.session` where a full parser closure needs only a session. Update `CursorSessionIndexer.reloadSession` at its direct `CursorSessionParser.parseFileFull` call site so the reloaded session merges/preserves the previously associated relationship and all metadata. Ensure search paths do not lose relationship metadata.

- [ ] **Step 4: Run targeted tests**

  Register the new association test with `./scripts/xcode_add_file.rb AgentSessions.xcodeproj AgentSessionsTests AgentSessionsTests/CursorACPSubagentAssociationTests.swift AgentSessionsTests` and run the exact focused set:

  ```bash
  xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -destination 'platform=macOS' -only-testing:AgentSessionsTests/CursorSessionParserTests -only-testing:AgentSessionsTests/CursorSessionIndexerTests -only-testing:AgentSessionsTests/CursorACPSubagentAssociationTests test CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
  ```

  Include the cache-only resolver test and a full-reconciliation stale-file test.

  Expected: PASS; no existing ACP parser or hierarchy regressions.

- [ ] **Step 5: Commit**

  ```bash
  git add AgentSessions/Services/CursorACPSubagentAssociation.swift AgentSessions/Services/CursorSessionIndexer.swift AgentSessions/Cursor/CursorSourceDescriptor.swift AgentSessionsTests/CursorACPSubagentAssociationTests.swift AgentSessionsTests/CursorSessionParserTests.swift AgentSessionsTests/SessionParserTests.swift
  git commit -m "feat: link explicitly referenced Cursor ACP subtasks"
  ```

### Task 4: Render ACP-backed child relationship

**Files:**
- Modify: `AgentSessions/Services/SessionRowsBuilder.swift` if surface-pill logic needs the ACP child relationship
- Modify: `AgentSessions/Views/UnifiedSessionsView.swift` (`WorkflowSubagentBadge.displayLabel` and nested-row accessibility/help rendering)
- Test: `AgentSessionsTests/SessionRowDisplayTests.swift` (including the direct `WorkflowSubagentBadge.displayLabel` assertion) and `AgentSessionsTests/SessionRowsBuilderTests.swift`

- [ ] **Step 1: Add failing UI/pill tests**

  Assert `WorkflowSubagentBadge.displayLabel(for: "cursor-acp-subagent")` returns the generic user-facing `sub` label. Assert the ACP parent retains the `acp` surface pill. Assert a linked child gets the generic `sub` marker and localized/accessibility text indicating an ACP subagent, while the internal value is never rendered literally. Assert hierarchy indentation and child count use the existing builder metadata.

- [ ] **Step 2: Implement the smallest rendering change**

  Reuse the existing `SubagentHierarchyBuilder` and generic sub marker. Add an explicit `cursor-acp-subagent` mapping in `WorkflowSubagentBadge.displayLabel` (for example `sub`) plus the ACP-specific accessibility/help text; do not add new table columns or duplicate hierarchy connections.

- [ ] **Step 3: Run row tests**

  Expected: PASS, including existing Cursor/Claude/Codex surface-pill tests.

- [ ] **Step 4: Commit**

  ```bash
  git add AgentSessions/Services/SessionRowsBuilder.swift AgentSessions/Views/UnifiedSessionsView.swift AgentSessionsTests/SessionRowDisplayTests.swift AgentSessionsTests/SessionRowsBuilderTests.swift
  git commit -m "feat: show Cursor ACP subagent hierarchy"
  ```

### Task 5: Full verification and documentation

**Files:**
- Modify: `docs/guides/cursor-agent-local-history.html` to document the explicit-path-only ACP subagent association boundary
- Test: existing full AgentSessionsTests suite

- [ ] **Step 1: Run focused regression suite**

  Run parser, indexer, hierarchy, row, and source-registry tests.

- [ ] **Step 2: Run full build and test**

  ```bash
  xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug -destination 'platform=macOS' -derivedDataPath .deriveddata-localization CODE_SIGNING_ALLOWED=NO build
  ./scripts/xcode_test_stable.sh
  xcrun xcresulttool get test-results summary --path .deriveddata-tests/Logs/Test/Run-*.xcresult
  ```

  Review the result-bundle test count against the pre-change revision and explain any delta. The stable wrapper enforces macOS arm64, relative `.deriveddata-tests`, and disabled parallel testing.

- [ ] **Step 3: Run repository checks**

  Run the exact CI checks: `git diff --check`, `python3 -m unittest scripts.tests.test_validate_localization_catalogs`, `python3 scripts/validate_localization_catalogs.py`, and after the Debug build, `python3 scripts/validate_localization_catalogs.py --extraction-root .deriveddata-localization/Build/Intermediates.noindex/AgentSessions.build/Debug/AgentSessions.build/Objects-normal`. Also run `scripts/check_deploy_drift.sh` and `python3 scripts/check_docs_publish.py`.

- [ ] **Step 4: Review the resulting UI with a real ACP store**

  Use a read-only local Cursor fixture or the existing local ACP store to verify one parent row, its ACP pill, expandable child count, and nested child rows. Do not commit real transcripts or databases.

- [ ] **Step 5: Commit documentation**

  ```bash
  git add docs/guides/cursor-agent-local-history.html
  git commit -m "docs: describe explicit Cursor ACP subagent links"
  ```
