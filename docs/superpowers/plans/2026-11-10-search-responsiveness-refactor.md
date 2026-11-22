# Search and responsiveness implementation plan

Date: 2026-11-10. Status: ready after independent review; no implementation executed.

Normative contracts: [refactor specification](../specs/2026-11-10-search-responsiveness-refactor.md).
Measurement protocol: [profiling specification](../specs/2026-11-10-search-responsiveness-profiling.md).
The spec's E1-E12 identify current source evidence; filenames below are implementation
targets, not claims that proposed types or tests already exist.

## Execution boundary and ordering

This packet is documentation only. Implementation, builds, tests, instrumentation execution,
and live profiling require a later implementation/profiling request. Work in the authorized
current checkout; preserve unrelated dirty files. Do not create a branch/worktree or commit
without explicit authorization. Capture HEAD plus the full relevant working-tree diff and
untracked source hashes: HEAD alone does not describe the current code.

Dependency order: P0 -> P1 -> P2; P0 -> P3 -> P4 -> P5 -> P6; P0 -> P7 -> P8.
P4 prepares migration scheduling/identity only; P5 supplies bounded adapters and activates
the new format versions after migration ingestion is switched to those adapters.
P2, P6 and P8 join at P9. Implement sequentially unless later instructions authorize parallel
coding with nonoverlapping ownership. Each phase has a reviewable completion gate.

## P0. Pin the implementation baseline and fixtures

- Inventory current diff and test declarations; read latest handover and current spec anchors.
- Record dirty source hashes and build configuration in a future run manifest. Use immutable
  exported snapshots for comparisons; no branch/worktree creation is implied.
- Add deterministic synthetic fixtures for the acceptance matrix, especially delayed credentials,
  >8 KiB Claude output, cross-event Boolean queries, provisional hydration, old-format rows,
  and same-size same-count transcript replacement. Do not embed private session content.
- Preserve existing tests. Record added/removed test names, not only execution totals.

Gate: every spec acceptance family maps to a fixture/test owner; no runtime measurements
claimed from old reports. E1-E12 and the registry are rechecked against the implementation tree.

## P1. Asynchronous credential service

Targets: `ClaudeManualWebCookie.swift`, `ClaudeCloudSessionCatalog.swift`,
`ClaudeCloudLiveModel.swift`, `ClaudeUsageSourceManager.swift`, `PreferencesView+Usage.swift`.
Proposed new service belongs under `AgentSessions/ClaudeStatus/ClaudeOAuth/`.

- Preserve paste extraction; add typed Security read/write/delete outcomes.
- Implement one physical Security queue, async waiters, same-epoch read coalescing,
  mutation ordering, and credential revision notifications as spec section 3 requires.
- Migrate every manual-cookie caller, including presence checks and user-triggered tests.
- Add request/enablement/credential revision checks before fetch and every publication.
- Make pending Preferences mutation state explicit and keep UI responsive.

Tests: extend `AgentSessionsTests/ClaudeOAuth/ClaudeManualWebCookieTests.swift` and
`ClaudeCloudEnableGateTests.swift`; add focused service/catalog race tests with fake Security
and network providers. Test both success and error completions after invalidation.

Gate: K1-K5 deterministic tests pass, with no real Keychain access in tests. A cancelled waiter
does not incorrectly complete another waiter or allow overlapping physical Security calls.

## P2. Credential-bound clients and caches

Targets: `ClaudeCloudAPIClient.swift`, `ClaudeWebUsageClient.swift`, `ClaudeUsageSnapshotStore.swift`,
`ClaudeLimitSnapshot` and their usage/catalog owners.

- Bind org IDs, response caches, and pending cache writes to the service's credential epoch.
- Remove the app flow's dependency on an unowned shared response cache; preserve any external
  cache file. Use process-local response cache at the existing TTL, separate from OAuth data.
- Make mutation invalidation trigger a fresh request after physical mutation completion;
  avoid lost refreshes behind `inFlight` and obsolete completions clearing newer work.
- Cover manual-cookie and legacy-cookie cache namespaces without changing fallback policy.
- Carry snapshot ownership through the manager, persisted store, displayed state and
  missing-five-hour-window merge. Reject legacy unowned restoration and cross-owner merges;
  web process/epoch snapshots cannot restore after restart. A stale store save must not
  overwrite current owned data. Preserve OAuth/tmux acquisition/priority, while declining
  window merges that lack same-owner evidence.

Gate: K6 and A->B/Remove/restart fixtures pass; seed persisted A, then start with B and a payload
missing its five-hour window. Neither client/model cache hits, persisted restore/merge, stale
errors nor delayed store saves cross ownership. Run focused credential/usage tests and a
mandatory build before presenting code.

## P3. Canonical query and searchable-source extraction

Targets: `FilterEngine.swift`, `SessionSearchTextBuilder.swift`, provider semantic decoders,
`ToolTextBlockNormalizer.swift` only where needed to separate shared extraction from display.
Proposed types: `SearchQuery`, `SearchTextSegment`, source extraction diagnostics.

- Implement spec section 4's query parser/tokenizer and streaming session predicate.
- Make metadata lexing quote-aware and pin the spec's expected AST examples, punctuation
  atoms, prefix rules and unicode61 tokenizer equivalence. Do not reuse the existing
  Swift-lowercase matcher as an unverified substitute.
- Define field boundaries, bounded chunk overlap for phrases, accumulated term truth, and
  three-valued negative evaluation. Never tokenize/concatenate an entire session for Return.
- Factor semantic extraction from provider readers; preserve output/errors and provenance.
- Switch sampled builders to the canonical segments without enlarging budgets.
- Generate FTS candidate queries from the same AST; reject unsupported query syntax explicitly.
- Keep in-session Find's behavior unchanged and do not expose new list-query syntax there.

Tests: extend `ToolTextBlockNormalizerTests.swift`, `ToolTextBlockNormalizerRegressionTests.swift`,
`SearchIngestTests.swift`, and matcher tests; add independent expected-result fixtures for
canonical extraction/query semantics and SQLite tokenization conformance.

Gate: extraction/query acceptance rows pass across provider fixtures; display/copy snapshots
remain unchanged except separately approved behavior. Sampled misses are expected; invented
complete negatives and omitted-source placeholders are not.

## P4. Prepare reliable migration and identity lookup

Targets: `SearchIngestService.swift`, `Indexing/DB.swift`, `FeatureFlags.swift`,
`SearchCoordinator.swift`, `SessionMetaRepository.swift`, relevant source descriptors.

- Track required format readiness independently from regular file cooldowns; invalidate
  aggregate-clean state until all required rows are handled. Persist progress through row versions.
- Atomically upsert text plus FTS for successful rows. Keep old rows provisional on failure.
- Prepare both new format versions but do not activate them until P5's bounded adapter gate.
  Optional Tool I/O is rebuilt when enabled, not forced on.
- Reuse existing provider-ID hints; add cheap aliases only where missing. Merge exact ID
  results after eligibility filtering and before FTS capacity in both coordinator routes.
- Test colliding source IDs and distinguish own versus parent identity.

Gate: migration scheduling with fake adapters and identity cases pass, including the
old-file/recent-ingest cooldown scenario. Restarts reconstruct pending work; no database reset
is needed. Real migration resource/cancellation acceptance belongs to P5. Identity
queries do not invoke full parsers. Help uses actual 30-day/8-MiB older-row retention constants.

## P5. Revision-aware bounded source scanners

Targets: `SearchSessionStore.swift`, `SessionSourceDescriptor.swift`, `SessionSourceRegistry.swift`,
`JSONLReader.swift`, source readers, and existing file/DB revision helpers.

- Add typed scan capabilities and results from spec section 5 without changing parser behavior
  for unrelated transcript consumers. Reuse semantic decoding, not display text.
- Add shared admission ownership: one Return permit and one background ingest/migration
  permit across providers, with coalesced kicks and permit release only after worker cleanup.
  Async actor reentrancy must not multiply scans or bypass the aggregate 128-MiB payload cap.
- Stream Codex/Claude fields and page database records under source-consistent snapshots.
  Handle compressed and companion-file layouts explicitly; bound decompressed data.
- Upgrade remaining registered providers to complete normal-current-fixture coverage, using
  bounded adapters where necessary. Maintain an adapter capability table in the implementation
  report generated from the registry; no unverified provider may silently claim complete.
- Expose skipped/oversize/malformed/read-error status from reader to result. Add cancellation
  checkpoints and resource accounting before full allocation, not only after parsing.
- Capture pre/post source revision and permit one sourceChanged retry. Do not trust nonempty
  hydration without full/currency/coverage provenance.
- Switch `SearchIngestService`'s full-parse path to the same bounded segment adapters before
  activating format versions. Build sampled index text with bounded buffers; count then
  rescan a stable source if middle sampling needs a reliable event count. Both passes expose
  cancellation, bytes and coverage. Do not mark reader omissions as successful migration.
- Activate the format versions only after adapter and ingestion integration tests pass.

Tests: extend `JSONLReader` tests, source reader tests, `SearchIngestTests.swift`, and
`SessionSourceRegistryTests.swift`; add store/scanner tests for stale/provisional hydration,
WAL-only changes, companion replacement, read failures and cancellation.

Gate: one complete current fixture per registered provider, typed incomplete historical cases,
no retained parsed hit payloads, bounds verified under adversarial large input. Uninterruptible
OS I/O is reported separately from cooperative cancellation; it does not spawn another worker.
Migration tests also cancel inside oversized/long-source processing, verify incomplete rows
remain pending, and prove bounded retention across ordinary ingest and required rebuilds.

## P6. Integrate Return, coverage UI, and bounded results

Targets: `SearchCoordinator.swift`, `UnifiedSessionsView.swift`,
`PreferencesView+General.swift`, localization resources.

- Return creates a stable eligible identity set and revalidates Instant hits as well as misses.
  Remove dependence on the advanced deep-output preference and estimated tool-call count for
  this explicit action. Typing remains sampled; existing index enablement defaults stay intact.
- Remove legacy full-parser fallback from every Instant route, including missing DB, cold
  warmup, stale rows and unindexed sources. Use metadata plus available sampled indexes;
  visibly report incomplete/indexing state and offer Return. Test rapid typing in each state.
- Use lightweight result references and bounded snippets. Do not call `store.updateSession`
  with exhaustive-search payloads or publish parsed event arrays as result rows.
- Publish verified/provisional/unknown states, exact final progress, and cancellation status.
  Negative hits contradicted by full evidence disappear; errors do not become no-match.
- Replacing a query cancels the worker; no stale result can publish. Esc preserves results
  already shown with a partial label. Explain supported query grammar and per-source revisions.

Gate: end-to-end fixtures cover indexed/stale/unindexed rows, NOT/AND differences, no-hit with
incomplete sources, repeated cancellation, and thousands of common-query hits. Memory grows
with lightweight hit metadata, not total matched transcript bytes. No “fully searched” label
appears until every eligible session has complete coverage.

## P7. Production-path instrumentation and baseline

Targets: existing `SessionInfoMetrics.swift` and transcript/search timing hooks, plus a focused
diagnostic recorder and fixtures. Reuse existing instrumentation conventions; no product flag
or new background service. Detailed diagnostics are enabled only by a benchmark invocation.

- Implement the event schema and identity checks in the profiling specification.
- Establish baseline manifests before changing presentation ownership. Existing component
  benchmarks remain separate from production-path measurements.
- Baseline production measurements use P0's exported pre-refactor source with identical
  diagnostic hooks only, not an accidentally mixed post-P1/P6 build. Pin the diagnosed
  first-content/full-ready improvement metric before P8 candidate changes or timing.
- Execute measurements only in a later authorized profiling run; creating instrumentation
  does not authorize app launches or private-corpus access in this documentation task.

Gate: synthetic runs prove event pairing, no stale-session first paint, no secret/content logs,
and that diagnostic overhead is measured. Missing stages are explicit, never zero-duration.

## P8. Shared transcript presentation

Targets: `TranscriptDerivedState.swift`, `TranscriptPlainView.swift`,
`TranscriptBlockListView.swift`, `TranscriptTelemetryView.swift`, hydration publication owners.

- Carry explicit content revision/fullness from hydration into derived state; reuse provider
  revision infrastructure where correct. Cover all publisher paths, not just cold selection.
- Introduce immutable presentation input/output bundles and worker generation checks.
- Share markers, groups, and navigation counts; fast-return empty marker changes. Preserve
  cached append extension and row/window identities.
- Include all semantic DerivedSettings/projection mode and role masks in owner inputs;
  use dependency-specific subkeys so role toggles reuse markers/groups and project stop
  counts correctly. Check every role-mask combination and preamble/projection toggles.
- Make production table apply require complete groups; do not trigger fallback while waiting.
- Publish consistent bundles and keep prior content clearly associated with its prior identity.
  Context, locale, telemetry/image and same-size edits must invalidate the right inputs.

Tests: extend `TranscriptDerivedStateTests.swift`, `TranscriptTelemetryPresentationTests.swift`,
`TranscriptBlockWindowingTests.swift`, and role/navigation/grouping tests. Use existing
`TranscriptToolCorpusCheckTests.testMessageOpenPerformance` only as a component check.

Gate: presentation acceptance matrix passes; unchanged UI updates perform no derivation;
no new main-actor whole-stream build; existing tail-first and append behavior preserved.
Do not claim the 8,000-message opening complaint resolved until the profiling gate is met.

## P9. Integration, reporting, and closure

- Mandatory build after Swift/project changes. Add new Swift files using
  `./scripts/xcode_add_file.rb AgentSessions.xcodeproj TARGET FILE GROUP` and verify membership.
- With approved Xcode cache access, use the canonical build and stable test wrapper:
  `xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug build`
  and `./scripts/xcode_test_stable.sh`. Read totals from the actual XCResult bundle using
  `xcrun xcresulttool get test-results summary --path <recorded-bundle>`.
- Record test-name inventory before/after; explain all removals/skips. Do not infer coverage
  preservation from green totals alone. Run localization validation for changed user strings.
- Complete the separately authorized profiling specification; distinguish failed gates from
  unavailable evidence. Never launch a test-re-signed app for live acceptance.
- Update `docs/CHANGELOG.md` under Unreleased and `docs/summaries/YYYY-MM.md` for implemented
  user-visible behavior. Update backlog evidence and close only independently proven items.

Gate: correctness and profiling reports link exact source/binary/input manifests and show
pass/fail for every acceptance ID. Any unresolved large-open cause remains open in the backlog.
No deployment or commit is implied by this plan.

## Review ledger

- First Sol Max review of the chat plan: five material revisions required. This packet adds
  bounded revision-aware scanning (sections 4-5/P3/P5/P6), credential mutation/cache invalidation
  (section 3/P1/P2), migration obligations (5.4/P4), sampled-hit revalidation (5.1/P6), and explicit
  presentation revisions (section 6/P8). It also separates production timing from component timing.
- Completed-document Sol Max review (`gpt-6.1-sol`, maximum reasoning): revised to cover
  persisted/model usage snapshot ownership, bounded ingestion before version activation,
  complete presentation inputs, parser-free Instant fallback, shared scanner admission,
  quote-aware unicode61 query grammar, enforceable decoder bounds and a baseline-selected
  slow-open improvement metric. All substantive findings were incorporated in the three files.
- Final bounded Sol Max reread: **READY; no remaining substantive P1/P2 document blockers.**
  This verdict covers the contracts and plan, not implementation correctness or performance.
- Mechanical Luna Max review (`gpt-6-luna`, maximum reasoning): companion/source/test links,
  benchmark symbol, phase dependencies, acceptance mappings and ABBA arithmetic checked;
  no concrete documentation defects found. No source or runtime mutations by either reviewer.
- Parent final check: all three documents have no trailing whitespace and balanced code
  fences. Only these three new documents were written by this task; existing dirty code and
  documentation were preserved. No builds, product tests, databases, UI or profiling were run.

Document readiness means the contracts and sequence are coherent and reviewed. It does not
mean the implementation, performance gates, or owner QA have passed.
