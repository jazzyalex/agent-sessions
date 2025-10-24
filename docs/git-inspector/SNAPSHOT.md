# Git Inspector Snapshot (local)

- Total Codex session files scanned: 145
- Sample size: 145 (most recent)
- Historical metadata present (payload.git in first 5 lines): 72/145
- Sessions with cwd in payload: 109/145
- Of those, cwd contains a .git directory: 73/109

Notes
- Historical data exists for roughly half of recent sessions; reading the first JSONL line is sufficient to extract it.
- Current state is available for any session whose cwd still points to a valid git repo (~67% of sessions with cwd).
- The inspector should therefore support both “historical+current” and “current-only” paths for good coverage.
