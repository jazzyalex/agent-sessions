# Receipt: Codex C6/C7 verification (pinned artifact set, 2026-08-12)

Query: this script (`receipt_codex_c6c7.py`), verbatim — per line,
parse JSON; count payload.type=='reasoning' records and those whose
payload.summary contains a summary_text entry with non-empty text;
count records with payload.type=='sub_agent_activity' and records
whose payload carries a parent_thread_id KEY. Structured fields
only — text that merely mentions a field name does not count.

The artifact set is pinned by filename and full SHA-256. The raw
files are private local session data; identity and query are
published so the counts are auditable on inspection. Byte snapshots of
the five files, exactly as hashed here, are archived locally (private)
so these counts remain reproducible even though the live session files
keep growing; public archival of sanitized copies is part of the
receipts-repo / 1.0 milestone. This is an identity-plus-local-archive
receipt, not yet a publicly reproducible one.

- `rollout-2026-08-04T15-53-48-019fcefb-aeea-7742-a996-f4592d74b216.jsonl`
  sha256: `8c2d2215ca53e4555fc42f50699e017965c0eff39d5d2820e2150663f4c1a843`
  reasoning 1247, with summary_text 406, sub_agent_activity records 104, parent_thread_id-keyed records 0
- `rollout-2026-08-12T15-55-10-019ff82f-cd39-70b3-ad41-bccc319db101.jsonl`
  sha256: `e3ed4fb99b4c4cc5b179bc963d532ce42e733874090be1658c90af90fc02a914`
  reasoning 670, with summary_text 298, sub_agent_activity records 35, parent_thread_id-keyed records 0
- `rollout-2026-08-12T21-52-24-019ff976-dd87-7f02-aa7f-087e68271e97.jsonl`
  sha256: `fcfc771c73457d2bccc097da160a961f80ebdff760ec1bf85e9013fcf11853f6`
  reasoning 9, with summary_text 4, sub_agent_activity records 7, parent_thread_id-keyed records 1
- `rollout-2026-08-12T21-52-28-019ff976-ebd9-7de2-bf1c-6a70938001d3.jsonl`
  sha256: `3f2a186ccc8703a410921ad894858624b77f5ae915006dd49a6d67b43eb07314`
  reasoning 9, with summary_text 3, sub_agent_activity records 9, parent_thread_id-keyed records 1
- `rollout-2026-08-12T21-52-31-019ff976-f98d-7343-80c7-cd82e2af7234.jsonl`
  sha256: `977fb2c1ad31b9a1bf27169e002a1f74c34da432922c1888c1c0a0fd0a6c6cc5`
  reasoning 19, with summary_text 1, sub_agent_activity records 9, parent_thread_id-keyed records 1

Totals: reasoning records 1,954, with non-empty summary_text 712 (36%), sub_agent_activity records 164, parent_thread_id-keyed records 3.
