# Plan: repair Codex weekly Runway calibration

Status: core correction completed and validated 2026-09-08. Broader multi-account and complete-root evidence work remains in the parent backlog. Implements the [specification](../specs/2026-09-08-codex-weekly-calibration-integrity.md).
Baseline: main `9ad98b6886603969bf0404674ee1d67947a1b60c`, inspected 2026-09-08. Recheck the working tree before implementation; current Astra pricing/test edits belong to another task.

## 1. Reconcile the incident before choosing a fix

Read `PROGRESS.md` if present and the newest `RepoHandover.md`, then capture current HEAD, relevant diffs and existing test names. Preserve the existing price-table and test changes.

Build a local, deterministic diagnostic replay of the actual Swift paths, with fixed quota observations, cutoff, scope, root inventory and price snapshot. Keep production preferences isolated. Use synthetic or sanitized minimal fixtures in the repository; retain raw transcripts only as local input. Capture the existing `/tmp/agentsessions-wkcal.log` evidence before relying on a file that may be overwritten.

For the incident interval, report per-file/event inclusion, timestamp, model, cumulative delta versus `last_token_usage`, request pricing, duplicate status, and exclusion reason. Compare bootstrap's $4.4226856 with the live calibration's implied $8.8106; verify whether their membership really is nested. Check the three-file discovery result against files actually eligible at the historical cutoff, including archive moves. Historical filesystem state may be unrecoverable; label that limit.

**Exit:** a minimal failing fixture reproduces the demonstrated cause, or the unresolved cause is explicitly isolated with a failing consistency assertion. Do not bake 4.8%/h, a 4× correction, or the smaller denominator into expected results. The earlier replay omitted the bootstrap midpoint.

## 2. Establish common Codex usage events

Inspect `CodexTelemetryAccumulator.swift`, `CodexRunwayModel.swift` and their fixtures. Extract/reuse the smallest normalization component that can serve historical and append ingestion. Retain cumulative-family precedence, preceding-model chronology, normalized fresh/cache/output components and safe request-context attribution.

Add stable event identity and explicit incomplete/ambiguous outcomes. Define first-request, reset, truncation, duplicate, partial-tail and multiple-request-delta behavior. Separate raw normalized events from pricing, using the existing immutable price snapshot. Do not change unrelated telemetry presentation.

**Tests:** component-by-component cumulative/per-request disagreement; first request counted once; incremental/cumulative twins; two events at one timestamp; repeated unchanged records; old/new model boundaries; counter decrease; partial baseline; request-tier boundary at 272,000/272,001; unresolved multi-request pricing. Test supported legacy families separately.

**Exit:** both consumers use the same event/accounting rule, and a common fixture yields identical normalized totals.

## 3. Repair the live ledger's interval semantics

In `WeeklyQuotaCalibration.swift`, separate event-time cost storage from poll coverage. Ingest newly discovered events once, preserve original timestamps, and track which intervals were fully observed. Late arrivals invalidate or recompute affected evidence; events older than retention cannot be injected into the current interval. Repeated scans must remain idempotent.

Resolve discovery coverage in the caller in `CodexRunwayModel.swift`: active-row membership alone is insufficient proof that all chargeable work was seen. Keep display selection separate from calibration coverage. Bound reads and carry explicit gaps forward.

**Tests:** late discovery before anchor; event exactly at either boundary; sleep/restart gaps; task completion between polls; more sessions than the visible/scanner cap; out-of-order arrivals; stable total across different poll schedules. Preserve Claude's incremental ledger behavior with dedicated tests.

**Exit:** changing poll timing cannot move already-timestamped spend between quota intervals.

## 4. Repair historical scan coverage and pricing

In `WeeklyQuotaBootstrap.swift`, use normalized events, explicit observation cutoff and one immutable price snapshot. Replace the forward-looking model seed and substring-based semantic acceptance with structured envelope checks. Stop silently treating unreadable or unresolved candidates as harmless exclusions.

Enumerate the supported configured roots/archive sources and deduplicate moved files using durable identities. Record coverage and exclusions. If full historical coverage cannot be established, produce an unusable candidate or a bounded paired-observation candidate; do not invent missing spend. Preserve account/window provenance constraints rather than summing every local file.

**Tests:** appended data after cutoff; preserved-mtime discovery limitations; moved/duplicated archive; unreadable file; malformed relevant record; missing/conflicting anchor/account; different weekly slots; unsupported model; price refresh during scan; bounded scan exhaustion.

**Exit:** historical and incremental replay agree over exactly the same proven event set and interval.

## 5. Make candidate selection and persistence enforce consistency

Add explicit interval/scope/coverage/precision metadata and the contained-interval invariant. Compare costs only when intervals, root/account membership, accounting and price revision permit comparison. Reject inconsistent candidates before ranking by numerator conditioning. Do not assume the live path wins automatically.

Apply precision-aware bounds; withhold a numeric rate when the measured movement is indistinguishable from endpoint quantization. Preserve a still-valid compatible alternative where available. Add a shared Codex evidence revision to both live and bootstrap persistence and enforce it in restore, best-cache migration, fallback and asynchronous completion. Canonicalize reset jitter in keys and preserve true resets.

**Tests:** full-window cost below contained cost; larger-but-incomplete candidate; compatible fallback; no valid candidate; rounded versus exact endpoints; old live/bootstrap payloads; A→B→A account change; source/root/price changes; jitter versus reset; scope switch during scan; cold restart; Claude provenance rejection remains intact.

**Exit:** old or contradictory evidence cannot surface as a weekly number through any selection path.

## 6. Explain the estimate and record the fix

Update the weekly rate/help text in `AgentCockpitHUDView.swift` to identify an estimate of recent pace. Retain measuring/quiet/idle/unavailable distinctions and the existing five-minute calculation. Use the localization workflow for any added strings. Keep calibration details in local diagnostics, including selection origin, interval, cost, precision bounds and rejection reason, without raw account IDs or prompt content.

Add the behavior change under `[Unreleased]` in `docs/CHANGELOG.md` and `docs/summaries/2026-09.md`. Update the existing backlog entry with what this implementation actually closes; retain broader unfinished items.

**Tests:** estimated-rate formatting, fallback state transitions, no stale numeric rate after invalidation, and preservation of 5h/token/dollar modes. Do not assert the raw account percentage changes because local calibration changes.

## 7. Verify and deliver

Run focused existing calibration/bootstrap/parser suites and new reconciliation cases first, using isolated test preferences. Then run the stable full suite with `./scripts/xcode_test_stable.sh`. Inspect the wrapper before running: the current file expands `${PWD}/.deriveddata-tests`, while repository guidance requires the relative `.deriveddata-tests`; use the documented equivalent direct invocation if necessary rather than silently modifying unrelated test infrastructure.

Read total/passed/skipped/failed counts from the actual new `.xcresult` with `xcrun xcresulttool get test-results summary --path <result-bundle>`. Compare pre/post test names, not only total counts. Record concurrent test changes separately.

Build the active scheme after Swift/project changes:

```sh
xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug build
```

If new Swift files are needed, register each with `scripts/xcode_add_file.rb` using the repository's documented target/group arguments. Use the host's configured Xcode access rules; distinguish cache-access failures from source failures.

Finally replay the frozen incident through the repaired Swift path. Report normalized totals, rejected/accepted candidates, selected ratio/provenance and resulting rate over time. Establish whether the exact screenshot's historical state is reproducible; an approximate reconstructed rate is not a screenshot match. Reuse the existing Sol/Astra pricing test for the 2.5× arithmetic expectation and extend it only if needed.

Deliver the patch, concrete cause, validation evidence and remaining uncertainty. A running-app relaunch or visual UI QA requires the corresponding user request; never launch the test-signed app. Commit, push and release remain separate owner actions.

## Completion gate

The fix is complete when the incident's accounting failure has a reproducible regression, both ingestion paths agree for shared intervals, inconsistent/legacy candidates are excluded across restart and fallback, weekly rows explain their estimated meaning, and the build/test/replay evidence passes. A lower displayed number alone is not completion.

## Implementation result

The confirmed unsafe paths are closed: cumulative counters are authoritative in both Codex ingestion paths; bootstrap stops at the quota observation; model attribution is chronological; live spend stays at event time; weekly anchors, stable event identity, poll gaps and scanner caps are enforced; contradictory nested denominators are withheld; and revision-6 persistence rejects prior Codex evidence. Numeric weekly rates render without a prefix, and the HUD tooltip explains the five-minute extrapolation.

Validation passed 239 focused tests and the clean full suite (2,651 total, 2,648 passed, 3 skipped, 0 failed), followed by a successful standalone Debug build. Test-method inventory increased by sixteen relative to HEAD: fifteen net methods belong to this correction, and one pre-existing Astra pricing test belongs to the owner's concurrent changes. One existing calibration test was renamed and strengthened; no test method was deleted without replacement.

The historical filesystem and in-memory selection at screenshot time are not recoverable, so the exact $4.4226856 versus implied $8.8106 event set cannot be replayed byte-for-byte. The contained-interval regression represents that inconsistency and now returns no calibration. Full archive/root provenance, multi-account attribution, bounded quantization and request-level immutable quote evidence remain open in `docs/backlog.md`; they are not required to prevent this confirmed contradiction from displaying a confident rate.
