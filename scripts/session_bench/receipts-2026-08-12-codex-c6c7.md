# Receipt: Codex C6/C7 verification (pinned artifact set, 2026-08-12)

Query: this script (`receipt_codex_c6c7.py`), verbatim — per line,
parse JSON; count payload.type=='reasoning' items and those whose
payload.summary contains a summary_text entry with non-empty text;
count lines containing sub_agent_activity / parent_thread_id.

The artifact set is pinned by filename and full SHA-256. The raw
files are private local session data; identity and query are
published so the counts are auditable on inspection. Two artifacts were
live (still-appending) sessions when hashed; the counts correspond exactly
to the hashed snapshots — if a file has since grown, its hash will no
longer match, which is the receipt working as intended.

- `rollout-2026-08-04T15-53-48-019fcefb-aeea-7742-a996-f4592d74b216.jsonl`
  sha256: `77def89773341cc16614f1dd8c0fa2300ba3f4d9eb68a0892e1ffecabb1cd2f1`
  reasoning 1228, with summary_text 403, sub_agent_activity 119, parent_thread_id 16
- `rollout-2026-08-12T15-55-10-019ff82f-cd39-70b3-ad41-bccc319db101.jsonl`
  sha256: `256dea01c3f743f615fa57fc4f13f2db8301863cdf11dfaa30a4b1df9e2fc5d8`
  reasoning 650, with summary_text 290, sub_agent_activity 31, parent_thread_id 0
- `rollout-2026-08-12T21-52-24-019ff976-dd87-7f02-aa7f-087e68271e97.jsonl`
  sha256: `fcfc771c73457d2bccc097da160a961f80ebdff760ec1bf85e9013fcf11853f6`
  reasoning 9, with summary_text 4, sub_agent_activity 13, parent_thread_id 7
- `rollout-2026-08-12T21-52-28-019ff976-ebd9-7de2-bf1c-6a70938001d3.jsonl`
  sha256: `3f2a186ccc8703a410921ad894858624b77f5ae915006dd49a6d67b43eb07314`
  reasoning 9, with summary_text 3, sub_agent_activity 19, parent_thread_id 11
- `rollout-2026-08-12T21-52-31-019ff976-f98d-7343-80c7-cd82e2af7234.jsonl`
  sha256: `977fb2c1ad31b9a1bf27169e002a1f74c34da432922c1888c1c0a0fd0a6c6cc5`
  reasoning 19, with summary_text 1, sub_agent_activity 16, parent_thread_id 8

Totals: reasoning items 1,915, with non-empty summary_text 701 (36%), sub_agent_activity lines 198, parent_thread_id lines 42.
