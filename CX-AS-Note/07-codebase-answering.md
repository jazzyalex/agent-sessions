# Codebase Answering Notes

- [DATE] Topic:
  - Key path/command:
  - Important nuance:
  - Reusable response snippet:

- [2026-02-13] Topic: Refresh policy for active vs non-focused sessions
  - Key path/command:
    - `UnifiedSessionIndexer.refreshFocusedCodexSession(reason:)`
    - `UnifiedSessionIndexer.refreshMode(for:trigger:)`
    - `UnifiedSessionIndexer.checkForNewSessions(establishBaselineIfNeeded:)`
    - `SessionIndexer.refresh(mode:trigger:executionProfile:)`
  - Important nuance:
    - Current design appears to optimize for focused-session freshness and background polling elsewhere.
    - The approved direction is a hybrid: keep focused transcript at high-frequency while adding periodic updates for recent/visible non-focused sessions.
    - This balances responsiveness for the session being read with acceptable freshness in the list.
  - Reusable response snippet:
    - "The user experience should be hybrid: focused sessions stay on a fast monitor path, and non-focused sessions get a slower refresh path so the list can still feel live. This avoids the “single-session only” staleness problem while preserving resource predictability."

- [2026-02-13] Topic: Codex session list/search stale until app relaunch
  - Key path/command:
    - `SessionIndexer.refresh(mode:trigger:executionProfile:)`
    - `UnifiedSessionIndexer.refreshMode(for:trigger:)`
    - `CodexSessionDiscovery.discoverDelta(previousByPath:scope:)`
    - `SessionIndexer.parseFile(at:)` (lightweight path)
    - `SessionIndexer.lightweightSession(from:size:mtime:)`
    - `SessionIndexer.reloadSession(id:force:reason:)`
    - `FilterEngine.sessionMatches(_:)` and `FilterEngine.filterSessions`
  - Important nuance:
    - Manual refresh is not always a true full re-parse; it can still land in lightweight-only parsing depending on delta mode and existing cache.
    - Lightweight Codex entries (`events.isEmpty`) are intentionally not searchable by text unless transcript cache is available.
    - If an actively-writing file is not surfacing in results, the first thing to verify is whether it is treated as unchanged by delta stats (`SessionFileStat`) or remains lightweight in-memory after update.
  - Reusable response snippet:
    - "I found a likely indexing/lifecycle mismatch: refresh path confirms the path is being scanned, but sessions can stay in lightweight form (`events.isEmpty`) while still growing, so list/search behavior can lag. We should confirm whether the file was discovered as changed and whether the refreshed in-memory session became full parsed. If not, the next fix is to force a full parse path for monitor-driven updates when a session is active/visible."
