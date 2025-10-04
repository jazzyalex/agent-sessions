# Codex History v2 Draft Notes

## Highlights
- New **Open Session in Folder** context action reveals the raw `.jsonl` in Finder, even when hidden files are suppressed, giving users a safe path to archive or delete massive transcripts outside the app.
- Messages column now reports estimated file size (e.g., `110MB`) for lazy-loaded sessions, pinpointing high-volume logs without forcing a full parse.
- Usage strips gained tighter layout and consistent tooltips so consumption data is easier to scan.
- Preferences toggles for hiding low-message sessions and other filters now apply instantly, reducing the need to refresh manually.
- Global search and unified toolbar buttons include descriptive help text, making advanced filters (like `repo:` and `path:`) discoverable.

## Quality of Life
- Unified and standalone sessions views expose session Finder reveal and working directory actions with explanatory tooltips.
- Tooltips across Preferences, search bars, and context menus follow clear single-sentence guidance for faster onboarding.
- Build pipeline verified to ensure new UI affordances ship without regressions (`xcodebuild` Debug target).

## Notes for Release Copy
- Call out that the app remains read-only—Finder reveal empowers users to manage large files themselves.
- Mention that size estimates appear for "Many" sessions from earlier builds to help with cleanup.
- Encourage users to use the new quick filters (repo/path) highlighted in the updated tooltips.
