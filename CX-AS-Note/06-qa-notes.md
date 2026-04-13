# Q&A Notes

- [DATE] Question:
  - Answer:
  - Follow-up action:

- [2026-02-13] Question: Should we keep active-session-only fast refresh, or update more sessions?
  - Answer:
    - Support partial: prioritize the currently viewed transcript session, but do not isolate freshness to that one only.
    - Decision: implement a hybrid refresh model:
      - High-frequency updates for the focused session only.
      - Lower-frequency updates for recent/visible non-focused sessions so the list remains current.
    - User-facing summary:
      - High-frequency focused monitoring improves responsiveness while editing/reading one transcript.
      - Non-focused updates reduce stale UI in the session list and improve confidence when monitoring multiple runs.
  - Follow-up action:
    - Add a non-focused Codex/Claude cadence path for recent/visible sessions (separate from full background/full-reconcile cadence).
    - Keep existing focused-session monitor semantics unchanged for depth-first reading.
    - Add telemetry for:
      - monitor interval per session category,
      - number of non-focused sessions updated per cycle,
      - freshness lag observed in list row timestamps.

- [2026-02-13] Question: Codex session `rollout-2026-02-12T21-02-20-019c5560-e857-7392-85db-6d7f80583e5e` and other active sessions do not appear or do not reflect updates until relaunch.
  - **Status: Fixed (2026-04-12)**
  - Answer:
    - Was a Codex indexer refresh/lifecycle issue — active sessions stayed in lightweight form (`events.isEmpty`) after refresh, leaving list/search stale until cold restart.
  - Resolution: Fixed in indexing path; sessions now correctly receive full parse on monitor-driven updates when active/visible.
