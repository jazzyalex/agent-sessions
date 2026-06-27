# Claude Code Archived Sessions: Visibility & Restore

**Date:** 2026-06-26
**Status:** Design — revised after staff review (overlay architecture; restore gated off-by-default to preserve read-only positioning)

## Problem

Claude Code Desktop ("Code" tab) lets a user archive a session (right-click -> Archive) and also
**auto-archives** sessions in the background (an `AutoArchiveEngine` sweeps roughly every few
minutes; see anthropics/claude-code#59449). But the app provides **no way to view or restore**
archived Code sessions:

- The default session list/search uses `includeArchived: false`.
- The "Archived" sidebar filter does not render Code sessions (anthropics/claude-code#24534).
- There is **no Unarchive/Restore UI** — confirmed in the app bundle (only an `unarchive` IPC
  method, fired implicitly on reopen; no user-facing control). Many open issues confirm this:
  #62428, #50042, #24534, #43304, #41303, #41070, #30869, #46631.
- The community workaround is to hand-edit the metadata JSON and set `isArchived:false`.

Agent Sessions (AS) already **shows** these sessions (it reads the CLI transcript) and tags them
`desk` (from the transcript's `entrypoint: "claude-desktop"` field), but it has **no idea they are
archived** and offers no restore. By contrast, AS fully handles Codex Desktop archived sessions
(italic + archivebox pill, archived-only filter).

This project closes that gap for Claude: **(UC1) see which sessions are archived**, and
**(UC2) restore an archived session to normal** so it returns to the Claude Desktop list.

## Key facts (verified on disk + in the app bundle)

Storage is split across two trees, joined only by `cliSessionId`:

| Role | Path | Relevant fields |
|------|------|-----------------|
| Transcript (what AS reads/shows) | `~/.claude/projects/<proj>/<cliSessionId>.jsonl` | internal `sessionId == <cliSessionId>`, `entrypoint: "claude-desktop"` |
| Status sidecar (holds archive flag) | `~/Library/Application Support/Claude/claude-code-sessions/<workspace>/<group>/local_<id>.json` | `cliSessionId`, `isArchived`, `autoArchiveExempt`, `title`, `titleSource`, ... |

The transcript has **no** co-located sidecar; AS's existing transcript-adjacent reader
(`ClaudeDesktopSessionMetadataReader.metadataFileCandidates`, `SessionDiscovery.swift:380`) requires
a `local_`-prefixed path component and so never fires for `~/.claude/projects/...` transcripts. The
archived bit is therefore never read today (Break A). Even the metadata that *is* read elsewhere
drops `isArchived` (Break B).

Write semantics observed in the app bundle:

- **Archive** (manual right-click and auto-sweep): sets `isArchived = true` only, then tears down
  the live session. Nothing is deleted — transcript and sidecar remain intact.
- **Unarchive** (on reopen/startup): sets `isArchived = false` **and** `autoArchiveExempt = true`,
  then emits an `unarchived` event. The `autoArchiveExempt` flag is what stops the sweep from
  immediately re-archiving the session.

-> A correct restore is the exact inverse of the app's own unarchive: set `isArchived:false` **and**
`autoArchiveExempt:true`. Flipping `isArchived` alone is fragile (the sweep can undo it).

## Architecture

**Overlay map, not stored-on-`Session`** (revised after staff review — see "Why overlay" below).
Once per Claude index cycle, scan the `claude-code-sessions/` tree, build a
`cliSessionId -> ArchiveRecord` map, and hold it as published state on the Claude indexer / unified
model. The pill, filter, and restore action consult this map by the session's **already-persisted**
`codexInternalSessionIDHint` (which, for Code-tab sessions, equals the transcript filename UUID ==
`cliSessionId`). Nothing is written onto `Session`; no DB schema change. The tree is small (tens of
small JSON files) and refreshes with the normal index cycle.

```
claude-code-sessions/**/local_*.json --scan once--> overlay: [cliSessionId -> {isArchived, autoArchiveExempt, sidecarPath}]
                                                            |   (published on indexer / unified model)
Session.codexInternalSessionIDHint  --join key------------- +  (== filename UUID == cliSessionId; persisted, survives hydration)
                                                            v
                      +---------------------------+---------------------------+
                      v                           v                           v
          pill: .desktop(isArchived: overlay)   archived-only filter     Restore action (UC2)
                                                                       (mutates overlay -> optimistic)
```

### Why overlay (and not fields on `Session`)

Codex's `isArchivedCodexDesktopSession` is **path-derived** from `filePath` (`Session.swift:295`),
so it needs no persistence — the path is already in the DB. Claude's flag lives in a *separate* file
and **cannot** be re-derived from a persisted `Session`. The common render path is DB hydration, not
fresh parse (`ClaudeSessionIndexer.hydrateFromIndexDBIfAvailable`, ~`:221`/`:635`), and only
file-stat-changed transcripts get re-parsed. A flag stamped on `Session` at parse time would
therefore be:

- **dropped on hydration** — `session_meta` / `SessionMetaRow` has no such column, so every hydrated
  session would read `false`; and
- **clobbered by merges** — `Session` fields are `let`; the indexer's merge/reload rebuilds
  (`ClaudeSessionIndexer` ~`:362`, ~`:881`, `:690`; `SessionMetaRepository.fetchSessions`) re-list
  fields and reset any not hand-threaded, undoing the optimistic flip with a visible flicker.

Storing it properly would mean a SQLite migration + threading the field through ~15 rebuild sites.
The overlay avoids all of that because the **join key is already persisted**
(`codexInternalSessionIDHint`, written by `sessionMetaRow(from:)` ~`SessionIndexer.swift:1114`).

### Read-only positioning & the write gate (REQUIRED)

AS is marketed as a **local, read-only** viewer. UC2 (restore) is the only feature that writes —
and it writes into *another app's* data store. To preserve the product promise, the write capability
is **opt-in, OFF by default**, behind an Advanced preference. The split:

- **UC1 (tag + archived-only filter) — pure read, always on.** No gate. Never writes.
- **UC2 (restore) — write, gated.** Disabled unless the user explicitly enables it.

Default behavior (gate OFF): AS never modifies any Claude file. The Restore affordance is visible but
**disabled**, with help text pointing to the setting — so the capability is discoverable without
breaking read-only by default. No code path can write the sidecar while the gate is off.

**Preference:** `PreferencesKey.Advanced.allowClaudeArchiveRestore` (Bool, default `false`), surfaced
in the **Advanced** pane (alongside `enableGitInspector` / `includeOpenClawDeletedSessions` in
`PreferencesView+General.swift` Advanced section, sidebar case `.advanced`). Warning copy, e.g.:

> **Allow restoring archived Claude sessions** (off by default)
> Agent Sessions is otherwise read-only. Enabling this lets it modify Claude Desktop's session
> metadata to un-archive a session. Best done while Claude Desktop is quit, since Claude may
> overwrite the change. Your transcripts are never altered.

The restore service asserts the gate is on before writing (defense in depth — UI disables, service
refuses).

### Components

1. **Archive/sidecar reader** — extend the existing
   `AgentSessions/ClaudeStatus/ClaudeDesktopSessionTitles.swift`, which **already** enumerates
   `claude-code-sessions/**/local_*.json` and joins by `cliSessionId` (`:17-48`). Add a method that
   returns full records instead of only titles:
   - `ClaudeDesktopSidecarRecord { title: String?, isArchived: Bool, autoArchiveExempt: Bool, sidecarPath: String, modifiedAt: Date }`
   - `static func records(root:) -> [String: ClaudeDesktopSidecarRecord]` (last-writer-wins by mtime,
     same as today). The existing `map()` becomes a thin wrapper deriving titles from records, so the
     runway loader (`ClaudeRunwaySnapshotLoader.swift:20`) keeps working.
   - **Do not** build a new parallel scanner.

2. **Overlay state** — the Claude indexer builds the records map once per refresh (before the
   per-file scan) and publishes it (e.g. `@Published var claudeArchive: [String: ClaudeDesktopSidecarRecord]`
   on the unified model). A helper resolves a session:
   ```swift
   func claudeArchiveRecord(for session: Session) -> ClaudeDesktopSidecarRecord? {
       guard session.source == .claude, let key = session.codexInternalSessionIDHint else { return nil }
       return claudeArchive[key]
   }
   func isArchivedClaudeDesktop(_ session: Session) -> Bool { claudeArchiveRecord(for: session)?.isArchived == true }
   ```
   No change to `Session`, `CodingKeys`, equality, the DB, or any rebuild site.

3. **Tag** (`Views/UnifiedSessionsView.swift`, `claudeDesktopSurfacePill` ~`:2439`) — the row passes
   the overlay-derived bool into the pill: `.desktop(isArchived: unified.isArchivedClaudeDesktop(session))`
   instead of bare `.desktop()`. Reuses the existing archived pill styling (italic + archivebox
   accent, `:2476-2522`). The static pill builder gains one `isArchived` parameter for the Claude
   branch; no new pill code.

4. **Archived-only filter (optional / trimmable — see Scope)** — implemented as a **post-filter on
   the overlay** in the unified model, *not* in the persisted-`Session` `FilterEngine` predicate (the
   engine has no access to the sidecar data). A lightweight Claude toggle drives it. This is
   deliberately cheaper than full Codex parity: the Codex archived toggle is fused into a bespoke
   `CodexSegmentedPill` (`:1464`) with a `Filters.archivedCodexDesktopOnly` field threaded through ~6
   `Filters(...)` sites; we avoid that by intersecting the published list with the overlay's archived
   set when the toggle is on.

5. **Restore service** — new file `Services/ClaudeArchiveRestore.swift`:
   ```
   restore(sidecarPath:) throws
     - precondition: PreferencesKey.Advanced.allowClaudeArchiveRestore == true, else throw .disabled
     - read JSON (preserve ALL keys), set isArchived=false, autoArchiveExempt=true
     - write with Data.write(to: originalPath, options: .atomic)
   ```
   AS is **unsandboxed** (`AgentSessions.entitlements` has no `app-sandbox` key — "developer tool that
   needs full file system access"), and already writes outside its container via
   `SessionArchiveManager` (`.atomic` + `moveItem`, `:310/:899/:911`), so this is consistent with
   existing practice. New Swift file -> register with `scripts/xcode_add_file.rb` (per agents.md).

6. **Restore UI** — per-session only, gated:
   - Session row right-click context menu -> **Restore from Archive**, in the single-selection block
     (`UnifiedSessionsView.swift:938`), shown for archived Claude sessions
     (`unified.isArchivedClaudeDesktop(session)`). **Enabled** iff the Advanced gate is on; when off,
     the item is **disabled** with help text "Enable 'Allow restoring archived Claude sessions' in
     Preferences -> Advanced" (discoverable, but no write).
   - (A transcript-detail-header button was considered but deferred: `TranscriptPlainView` has no
     `UnifiedSessionIndexer` reference, so it can't read the overlay/optimistic state without
     uncertain environment plumbing. The context menu fully delivers per-session restore; the header
     button is a possible later follow-up.)
   - On invoke (gate on): confirm dialog (see Data flow), call restore, then **mutate the overlay
     entry** (`claudeArchive[key].isArchived = false`) — a single map mutation that updates the tag and
     drops the row from the archived filter immediately, with no `Session` rebuild.

## Data flow (restore)

0. **Gate check:** Restore is only actionable if `PreferencesKey.Advanced.allowClaudeArchiveRestore`
   is on (off by default). Otherwise the action is disabled and AS writes nothing.
1. User selects an archived Claude session -> **Restore from Archive**.
2. Confirm dialog: *"Restore this session in Claude Desktop? If the session is open in Claude it may
   overwrite this change immediately; otherwise quit and reopen Claude to see it back in the list."*
3. `ClaudeArchiveRestore.restore(sidecarPath:)` rewrites the sidecar (`isArchived:false`,
   `autoArchiveExempt:true`) atomically, preserving all other keys.
4. AS mutates the overlay entry -> tag clears, row leaves the archived filter (optimistic; no struct
   rebuild to clobber it).
5. Next index cycle re-reads the sidecar (now `false`) and reconciles the overlay.

## Error handling & concurrency

- **Claude running (clobber risk):** chosen behavior is "write anyway + warn" (not "require quit").
  Dialog warns about *immediate* overwrite if the session is currently open in Claude, not only
  "until restart" — Claude holds sessions in an in-memory map and re-saves them, and the
  `AutoArchiveEngine` sweeps every few minutes (the `autoArchiveExempt:true` we write mirrors the
  app's own unarchive specifically to survive that sweep).
- **Atomic write:** `Data.write(to:options:.atomic)` over the original path — never truncate-in-place,
  to avoid corrupting Claude's metadata on a crash/partial write.
- **Preserve unknown keys:** sidecar has many fields (`sessionSettings`, `enabledMcpTools`,
  `bridgeSessionIds`, ...). Parse -> mutate two keys -> re-serialize; do not reconstruct from a schema.
- **No sidecar / no join:** pure-CLI Claude sessions (no overlay entry) get no archived state and no
  Restore action.
- **Sidecar disappeared between scan and restore:** surface a clear error; never create a new file.

## Testing

- **Reader:** `records(root:)` joins by `cliSessionId`, returns correct
  `isArchived`/`autoArchiveExempt`/`sidecarPath`/`title`; last-writer-wins by mtime; ignores
  non-`local_` files. `map()` wrapper still returns titles.
- **Overlay resolution:** a `Session` whose `codexInternalSessionIDHint` matches an archived record ->
  `isArchivedClaudeDesktop == true`; non-matching -> `false`; nil hint -> `false`.
- **Restore:** read-modify-write sets both flags, preserves all other keys, writes atomically; errors
  when sidecar missing; does not create a file.
- **Pill:** archived overlay entry -> archived pill variant; absent/false -> plain `desk`.
- **Filter:** archived-only post-filter narrows Claude results and leaves other agents visible.
- **Write gate:** with `allowClaudeArchiveRestore == false` (default), the restore service throws
  `.disabled` and writes nothing; the UI action is disabled. With it `true`, restore writes. Assert
  no sidecar mutation occurs in the default-off case.
- **Fixtures:** add a `claude-code-sessions`-style sidecar fixture (`local_*.json` with
  `isArchived:true`) + a matching transcript under `Resources/Fixtures/` — none exist today.

## Out of scope (YAGNI)

- Bulk / "restore all" (auto-archive pile-ups) — per-session only for v1.
- Generalizing a single source-agnostic "archived" model across Codex + Claude — keep parallel,
  pattern-matched paths; a future unification is possible but not required here.
- Any archive *action* in AS (AS reads/restores; archiving stays Claude's job).
- Cowork (non-Code) archived chats.

## v1 scope (decided)

All three ship in v1:

- **Tag** (UC1, read-only, always on) — overlay-driven archived pill.
- **Archived-only filter** (UC1, read-only, always on) — lightweight overlay post-filter + toggle.
- **Restore** (UC2, write, **opt-in / off by default**) — gated behind
  `PreferencesKey.Advanced.allowClaudeArchiveRestore`.

The read/write split is the load-bearing design decision: visibility never writes, so AS stays
read-only out of the box; restore is the single, explicitly-enabled exception.

## References

- App bundle: `/Applications/Claude.app/Contents/Resources/app.asar` — `archiveSession`,
  `unarchiveSession`, `AutoArchiveEngine`, `isArchived`, `autoArchiveExempt`.
- Existing scanner to extend: `AgentSessions/ClaudeStatus/ClaudeDesktopSessionTitles.swift`.
- Entitlements (unsandboxed): `AgentSessions/AgentSessions.entitlements`.
- Advanced prefs (gate goes here): `PreferencesKey.Advanced` (`PreferencesConstants.swift:126`),
  Advanced pane (`PreferencesView+General.swift:236`, sidebar case `PreferencesView.swift:1103`).
- Issues: anthropics/claude-code #62428, #50042, #24534, #43304, #41303, #41070, #30869, #46631,
  #59449 (auto-archive interval).
