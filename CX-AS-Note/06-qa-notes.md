# Q&A Notes

- [DATE] Question:
  - Answer:
  - Follow-up action:

- [2026-02-13] Question: Codex session `rollout-2026-02-12T21-02-20-019c5560-e857-7392-85db-6d7f80583e5e` and other active sessions do not appear or do not reflect updates until relaunch.
  - Answer:
    - This is a likely Codex indexer refresh/lifecycle issue, not a data-loss issue.
    - Relevant flow: `SessionIndexer.refresh` <- `UnifiedSessionIndexer.requestProviderRefresh` <- UI `Re-scan/Refresh`.
    - High-priority things to check when reproducing:
      - Compare `trigger` at refresh callsites:
        - `SessionIndexer.refresh(...)` manual/relaunch uses `trigger: .manual` at entry.
        - `SessionDiscovery.discoverDelta(...)` and `CodexSessionDiscovery.discoverRecentSessionFiles(dayWindow: 3)` define what files are rescanned for incremental monitor paths.
      - Confirm logs for changed/new file discovery:
        - `SessionIndexer.refresh` prints `Found X total files, Y changed/new, Z removed`.
        - If `changed/new == 0` while session file size/mod time definitely changed, delta windowing may be stale.
      - Check whether stale sessions remain lightweight (`events.isEmpty`) after refresh:
        - `SessionIndexer.parseFile` uses lightweight metadata first.
        - `FilterEngine.sessionMatches` returns `false` for text search when `session.events.isEmpty` (unless query is empty).
      - Verify full-session parse fallback is happening when needed:
        - `SessionIndexer.reloadSession(id:force:true)` should run on selected/focused session, but unselected active sessions rely on scan cadence.
    - Current hypothesis:
      - Refresh UI can leave active sessions in a cached lightweight state, so updates land in file but not in searchable/fully-loaded session data until a cold start repopulates/rehydrates index state.
  - Follow-up action:
    - Add debug logging around:
      - refresh callsite (source + trigger + mode),
      - delta scope (`recent` vs `full`) + number of candidates for Codex,
      - lightweight vs full parse decisions,
      - and whether transcript cache prewarm runs for updated active sessions.
