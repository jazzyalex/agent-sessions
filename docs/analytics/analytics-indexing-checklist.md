# Analytics Indexing Checklist

Purpose: Validate that the Analytics window reads from the new indexing pipeline (ingest + rollups) correctly, quickly, and reliably. This checklist focuses only on indexing behavior and data parity, not layout/visual polish.

## Scope
- Ingestion: first-run full scan, incremental appends, error handling
- Rollups: daily/hourly aggregates used by dashboard and heatmap
- Queries: date ranges, agent filter, time series, heatmap, summary
- Publishing: background compute, main-thread delivery, refresh behavior
- Performance: time budgets and resource usage

Out of scope: theme, spacing, window sizing, toolbar visuals

## Setup
- Build a Debug app with Analytics enabled
- Prepare a small test corpus and a medium corpus (see Data Sets)
- Ensure Preferences date/time locale is the same across runs

## Acceptance (High Level)
- [ ] First-run scan indexes all inputs and renders Analytics without pressing Refresh
- [ ] Subsequent launches index only appended bytes and update Analytics automatically
- [ ] “Today” includes sessions with events occurring today (even if session started earlier)
- [ ] Time series, summary, breakdown, and heatmap are consistent and additive (no double counting)
- [ ] Updates are published on the main thread without freezing UI

## Data Sets
- Minimal: 20–50 sessions across 3 agents, including a few with events today
- Edge: sessions spanning midnight and week/month boundaries; empty sessions; mixed sources
- Medium: 5–10k messages (enough to measure performance but quick to iterate)

## First‑Run Ingestion
- [ ] Launch Analytics with an empty index; verify a single full scan occurs
- [ ] Progress indicator reflects work (optional) and settles cleanly
- [ ] Analytics renders automatically when ingestion completes (no manual Refresh)
- [ ] No duplicate rows; counts in summary match the sum of time series and breakdown

## Incremental Ingestion
- [ ] Append new messages to existing logs; verify only new bytes are read
- [ ] Analytics updates within expected latency (see Performance)
- [ ] No double counting for partially written lines or truncated files
- [ ] Edits to past logs: affected rollups are corrected (either immediately or via background sweep)

## Rollups Correctness
- Summary
  - [ ] Sessions/messages/commands equal filtered totals derived from raw events for the current period
  - [ ] Previous‑period deltas match recomputation over the prior window
- Time Series
  - [ ] Bucket alignment matches range granularity (hour/day/week/month)
  - [ ] Sum of agent series equals the total series for each bucket
- Heatmap
  - [ ] Day of week mapping is correct (Mon–Sun) and matches local calendar
  - [ ] Hour buckets (3‑hour buckets) correctly assign events and most‑active label aligns with max bucket
- Agent Filter
  - [ ] “All Agents” equals the sum of individual agents for each metric
  - [ ] Per‑agent filters agree with raw data for that agent only

## Date Ranges
- [ ] Today: start at local startOfDay(now); sessions spanning midnight contribute only post‑midnight activity
- [ ] Last 7/30/90 Days: inclusive of start boundary, exclusive of end (now) for consistency
- [ ] All Time: no start bound; aggregation granularity set to month (or implementation default)
- [ ] Custom (if enabled later): respects explicit bounds; clipping applied consistently

## Refresh Behavior
- [ ] onAppear triggers calculation; UI shows snapshot without manual action
- [ ] When ingestion finishes, published results invalidate and refresh visible widgets
- [ ] Manual Refresh (toolbar) is idempotent; no duplicate work or flicker

## Error Handling
- [ ] Malformed JSON/partial lines are skipped with metrics logged (no crash)
- [ ] Large messages (e.g., base64) are ignored or summarized; index contains only searchable text and metadata
- [ ] Index migration/rebuild path exists: a “Reindex” action clears and repopulates deterministically

## Performance Targets (Debug, Medium Corpus)
- [ ] First‑run ingest completes within acceptable time (data‑dependent; record baseline)
- [ ] Subsequent incremental updates visible in < 1–2 s after file append
- [ ] Dashboard compute from rollups: < 30 ms typical on refresh
- [ ] UI remains responsive during ingestion (no noticeable blocking on the main thread)
- [ ] Memory stable; no unbounded growth during long runs

## Parity Checks (if legacy path still available)
- [ ] For a fixed snapshot of logs, legacy in‑memory analytics and new index‑backed analytics match within rounding
- [ ] Differences > 1% flagged and investigated (usually boundary clipping or timezone)

## Instrumentation To Collect During QA
- [ ] Ingest: rows/sec, batches/commit, skipped lines count
- [ ] Rollups: per‑range compute time, bucket counts vs. totals
- [ ] UI: time from data change → published snapshot → rendered
- [ ] Errors: counts and top causes (malformed, truncated, permission)

## Regression Matrix
- [ ] Empty corpus: UI shows empty states without errors
- [ ] Single agent only: totals reflect that agent, filters behave sane
- [ ] Mixed timezone timestamps (if present): local‑time bucketing remains correct
- [ ] App relaunch during ongoing ingestion: index remains consistent; no corruption

## Out Of Scope For This Checklist
- Visual theming, paddings, window size, toolbar appearance
- Search/FTS behavior (covered separately)

