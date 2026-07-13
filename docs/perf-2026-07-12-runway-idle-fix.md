# Perf: Runway/QM idle-rescan fix (branch perf/instant-2026-07-12)

**Date:** 2026-07-12 overnight session. **State:** uncommitted in this worktree; full suite green (1,544 tests, 0 failures, 3 skipped); fix verified by Release-build re-profiling.

## What was wrong (measured, W8 follow-up)
With any Quota Meter / cockpit surface visible, the app held **25–41% CPU indefinitely at idle** (313% multi-core bursts, ~2,000 ctx-switches/s). Root cause: the 5s runway refresh re-read (head 96KB + tail 256KB, token parser tail up to 1MB) and re-parsed every in-window session file every cycle with no cross-cycle cache. A 0.8s shimmer timer added ~75 wakeups/min even when nothing animated.

## The fix
1. **Per-file parse cache** `RunwayFileParseCache<Value>` keyed by `RunwayFileSignature(mtime, size)` — caches only bytes-derived, now-independent artifacts; all now-dependent aggregation (active windows, staleness decay, burn spans, Codex `?? now` capture fallbacks) recomputed each cycle via finalize(now:). Output byte-identical for any (disk, now). Applied to Claude scanner/token parser and Codex scanner/rate-limit/token parsers. Caches pruned to the current in-window path set.
2. **Shimmer ticker** (`RunwayShimmerTicker`) runs only while a row is actively burning; honors Reduce Motion. Zero idle wakeups.
3. Two independent 5s `clockTimer`s coalesced into `HUDSharedClock.fiveSecond`.
4. Interactive filter recompute moved off `.utility` ingest queue to `.userInitiated` (`FeatureFlags.interactiveFilterRecomputeQueue`), debounce 0.28s → 0.08s (discrete toggles only; typing uses the separate `$query` pipeline).
5. Date-cell relative/absolute strings memoized per (id, modifiedAt, minute) — `DateCellStrings`.
6. `Session.hasToolCallEvent` precomputed in both initializers (no schema change); `hasCommandsOnly` filter no longer scans event arrays.

## Verification
- Full suite in this worktree: **1,544 tests, 0 failures** (`xcodebuild … -parallel-testing-enabled NO test`, .deriveddata-test).
- Release re-profile (same methodology as the audit, own instance only): idle CPU with QM active **10.0/12.3/13.1/8.3/8.5% (median ~11%)** vs 25.4–41.3% before; runway sample weight **~800 per 10s vs ~60,000** (≈75×); `ClaudeRunwayTokenActivityParser` hot frames **absent**; refresh confirmed still running (residual = designed stat sweep + now-aggregation; files genuinely change every cycle in a live-agent environment). Memory flat 166–246MB over 8 min.
- Remaining periodic ~30% bursts (~every 60s) are pre-existing search re-ingest + presence probing of actively-changing files — out of scope here (audit bottleneck #2/#3).

## Gotcha for future refactors
The two "circular reference" compile errors were NOT the nested-generic shape: inside the new cache trailing closure, unqualified `metadata(from: url)` bound to the **later local** `let metadata = parse.metadata` (closure capture scope), cycling type inference. Fix: `Self.metadata(from: url)`.

## Known deferred (from the audit, not this branch)
- DB full-wipe migration markers (DB.swift:379–438) force a full re-index after some updates — prefer scoped/backfill migrations (flagged as a separate task).
- Cold-launch ingest window needs a clean single-instance re-measure before acting.
