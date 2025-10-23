Energy and Performance

Overview
- Scope: Phase 1 performance hardening and follow‑up search/UI tweaks to improve responsiveness and reduce CPU spikes without changing user‑visible behavior or data formats.
- Outcome: Significant improvements in typing responsiveness, search fluidity, large session loading, and general UI smoothness. Energy badge still appears during sustained heavy operations but clears more quickly than before.

What We Changed (Guarded by Feature Flags)
- Interactive filter avoids transcript generation
  - Only uses cached transcript in the list filter path; otherwise scans raw fields (title, repo, user/event text).
  - Deep search (global, transcript‑aware) remains unchanged and may still generate transcripts when needed.

- Work priority demotion
  - Heavy/background work demoted from `.userInitiated` to `.utility` where appropriate (filter pipelines, indexing, parsing, search orchestration) to be more cooperative with the system scheduler.

- Throttled UI progress updates
  - Indexing progress publishes are coalesced to ≤ ~10 Hz to reduce main‑thread churn.
  - Search progress updates (small/large phases) are throttled similarly; large‑phase result appends are batched.

- Be polite while the user types
  - Background transcript pre‑warm yields and backs off briefly during typing bursts.
  - Interactive filter debounce increased modestly to reduce redundant recomputes.
  - Deep search starts are debounced in the unified toolbar while typing; Enter still triggers immediately.

- Coalesced list resorting (where applicable)
  - Unified sessions list preserves view‑model order when the sort descriptor did not change to avoid unnecessary re‑sorting in the view.

- Off‑main transcript building for large sessions
  - Transcript rendering in the transcript pane uses cached text when available; otherwise builds off the main thread and applies results on the main thread to avoid stalls.

Feature Flags (defaults: ON)
- `filterUsesCachedTranscriptOnly`
- `lowerQoSForHeavyWork`
- `throttleIndexingUIUpdates`
- `gatePrewarmWhileTyping`
- `increaseFilterDebounce`
- `coalesceListResort`
- `throttleSearchUIUpdates`
- `coalesceSearchResults`
- `increaseDeepSearchDebounce`
- `offloadTranscriptBuildInView`

Location: see `AgentSessions/Support/FeatureFlags.swift`.

What Improved
- Sessions list typing and filtering remain smooth even with thousands of sessions.
- Large session opening no longer beachballs; transcript builds are non‑blocking.
- Search and sorting are noticeably faster and feel more responsive.
- Energy badge clears faster after heavy operations complete.

What Did Not Change (By Design)
- Functional behavior, persisted formats, and public APIs are unchanged.
- Deep search still performs genuine work (file reads/parsing); energy usage during these operations is expected.

Energy Badge: Current Behavior
- The battery menu may still show “Using Significant Energy” during sustained heavy operations such as:
  - Reading/parsing large files
  - Sorting by session name across large datasets
  - Running deep searches or full refreshes
- Observed behavior: the badge now clears more quickly after the operation finishes.

Why The Badge May Still Appear
- The system’s metric reflects aggregate CPU + disk I/O + wakeups over a sliding window. Even at `.utility` QoS, sustained file I/O and parsing can exceed the threshold temporarily.
- The app is foreground/active (App Nap does not apply), and the badge can linger for a short period even as the app idles.

Potential Future Options (Low Risk)
- Reduce incidental overhead
  - Gate nonessential logging in Release builds; rate‑limit prints during indexing/search.
  - Cache formatter instances (date parsing) in parsers to cut CPU churn.

- Finer pacing of heavy work
  - Increase search debounce further during typing bursts (e.g., 350–400 ms) while keeping Enter immediate.
  - Reduce progress/result flush cadence to ~6–8 Hz during long phases.
  - Slightly longer cooperative yields (e.g., 15–20 ms) between large items.

- Adaptive behavior
  - On battery or Low Power Mode, prefer `.background` QoS and skip transcript pre‑warm entirely.
  - Freeze secondary resorting while search is running; reapply once per phase or on completion.

- UI micro‑batching (only if needed)
  - For extremely large transcripts, optionally render/apply in chunks at a low cadence to minimize single‑frame work.

Validation Tips
- Activity Monitor → Energy tab: observe Energy Impact during sustained search.
- Instruments → Energy Log / Time Profiler: confirm work distribution and throttle effects.
- Console: ensure logging volume is minimal in Release.

Rollback Strategy
- All changes are controlled via `FeatureFlags`. Toggle any flag to revert to prior behavior without code removal.

## Open Issue: Energy Spikes During Search/Refresh

- **Observed**: Energy Diagnostics reports “Very High” impact and 15–24 wakes/sec while a foreground search or manual refresh is running. Battery menu may surface the “Using Significant Energy” warning briefly, though the app remains responsive and beachballs do not appear.
- **Repro**: Launch AgentSessions with a large corpus (≈1.7k sessions), trigger a unified search (e.g., `dmg`) or run `Cmd + R` refresh immediately afterward. Inspect Activity Monitor → Energy or Instruments → Energy Log.
- **Root Causes (current hypothesis)**:
  - Sequential parsing of large sessions during the search “large” phase.
  - Transcript generation when cached data is missing.
  - Concurrent background work (provider refresh, analytics refresh) overlapping with the user-initiated search.
- **Impact**: Perceived energy usage may concern battery-sensitive users even though responsiveness is acceptable.
- **Status**: Non-blocking; monitor user feedback. Revisit during indexing/search roadmap (FTS, auto-refresh) or sooner if complaints increase.

### Quick Mitigations Worth Considering

1. **Pause background refresh while a search is active** — gate provider/analytics refresh tasks until search completes to avoid overlapping heavy work.
2. **Battery-optimized search mode** — optional preference that lengthens cooperative yields and defers large-file parsing unless the user opens the session, reducing short-term wake spikes.
3. **Adaptive debounce** — increase unified search’s debounce interval automatically when the dataset is large to cut redundant launches and associated parsing.

These items require modest effort and can be scheduled independently of the larger analytics roadmap.
