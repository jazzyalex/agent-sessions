# Receipt: Codex C6/C7 verification (2026-08-12)

Query: parse each line as JSON; count payload.type=='reasoning' items and
those whose payload.summary contains a summary_text entry with non-empty
text; count lines containing sub_agent_activity / parent_thread_id.
Artifact set: the 5 most-recently-modified rollout files under
~/.codex/sessions at query time (filenames pin the exact set):

- `rollout-2026-08-12T21-52-24-019ff976-dd87-7f02-aa7f-087e68271e97.jsonl` (sha256:fcfc771c73457d2b…): reasoning 9, with summary_text 4, sub_agent_activity 13, parent_thread_id lines 7
- `rollout-2026-08-12T21-52-28-019ff976-ebd9-7de2-bf1c-6a70938001d3.jsonl` (sha256:3f2a186ccc8703a4…): reasoning 9, with summary_text 3, sub_agent_activity 19, parent_thread_id lines 11
- `rollout-2026-08-12T21-52-31-019ff976-f98d-7343-80c7-cd82e2af7234.jsonl` (sha256:977fb2c1ad31b9a1…): reasoning 19, with summary_text 1, sub_agent_activity 16, parent_thread_id lines 8
- `rollout-2026-08-04T15-53-48-019fcefb-aeea-7742-a996-f4592d74b216.jsonl` (sha256:33096d80812e8478…): reasoning 1221, with summary_text 401, sub_agent_activity 115, parent_thread_id lines 12
- `rollout-2026-08-12T15-55-10-019ff82f-cd39-70b3-ad41-bccc319db101.jsonl` (sha256:1a166d0c50ac0242…): reasoning 541, with summary_text 260, sub_agent_activity 24, parent_thread_id lines 0

Totals: reasoning items 1799, with non-empty summary_text 669 (37%), sub_agent_activity lines 187, parent_thread_id lines 38.
