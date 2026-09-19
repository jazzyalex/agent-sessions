# Cursor ACP Strong Parent–Subagent Association

## Status

Approved design; implementation not started.

## Goal

Recognize and present Cursor ACP parent sessions together with only those Cursor JSONL subtask sessions that are explicitly referenced by the ACP persisted store.

The first phase deliberately does not infer relationships from shared project paths, timestamps, titles, or filename patterns alone.

## Evidence boundary

Cursor ACP persisted sessions are stored at `~/.cursor/acp-sessions/<uuid>/store.db` with `meta.json`. The current read-only ACP reader decodes the root turn graph and creates one `.acp` `Session`, but it does not expose the root record's local transcript/resource paths. Cursor JSONL transcripts are discovered separately under `~/.cursor/projects/**/agent-transcripts/**/*.jsonl`; their first user content may begin with a `<timestamp>` marker, but that marker is not a parent identifier.

The only accepted parent-child evidence in this phase is an exact, normalized transcript path present in the ACP root record's persisted resource/path fields. A transcript that merely shares `cwd`, project, time range, or title with an ACP row remains unresolved and is not attached.

## User-visible behavior

- ACP parent rows retain the `acp` surface pill.
- Explicitly associated JSONL subtasks remain separate rows nested beneath their ACP parent through the existing `SubagentHierarchyBuilder`.
- Nested rows retain their message count, size, title, and transcript content.
- Associated child rows are marked as subagents and identify the relationship as ACP-backed.
- Parents show the existing disclosure control and child count.
- Timestamp-prefixed JSONL sessions without an explicit ACP path reference remain ordinary Cursor rows and are not given an ACP marker.
- Existing non-Cursor and non-ACP subagent relationships are unchanged.

## Data model

Reuse the existing `Session` relationship fields; no schema migration is required:

- ACP parent: `surface = .acp`, `relationshipKind = .root`, ID `cursor-acp:<uuid>`.
- Associated child: original Cursor transcript ID and path, `parentSessionID = cursor-acp:<uuid>`, `subagentType = "cursor-acp-subagent"`, and `relationshipKind = .subagent`.

The ACP reader should return the ACP session together with a set of normalized transcript paths (or an equivalent value object). The indexer owns applying that association to already-parsed transcript sessions, so parsing remains read-only and the generic hierarchy builder remains source-agnostic.

## Architecture and flow

1. `CursorACPStoreReader` validates the existing ACP schema and root graph as it does today.
2. While decoding the root record, it extracts only path-shaped values that resolve to `agent-transcripts/.../*.jsonl` resources. It must not decode tool payloads, encrypted blobs, or arbitrary text as relationships.
3. `CursorSessionIndexer` builds a normalized absolute-path lookup from the ACP result(s), keyed to the parent session ID.
4. After JSONL lightweight parsing and before sorting/publishing, matching transcript sessions receive the explicit parent ID, subagent type, and relationship kind.
5. `SubagentHierarchyBuilder` resolves the parent ID and produces the existing parent-first, collapsible row structure.
6. `SessionRowsBuilder` / title-row rendering expose the ACP relationship without removing the existing ACP pill from the parent.

Path normalization must be deterministic: standardize absolute paths, resolve `.` and `..`, and compare path strings without following symlinks or using basename-only matching. Missing or malformed path values are ignored.

## Failure handling and safety

- Unknown ACP schemas, malformed stores, incomplete graphs, and unreadable sidecars continue to reject the ACP row as they do today.
- A malformed or non-transcript resource path is ignored; it cannot attach an unrelated session.
- Multiple ACP stores referencing the same transcript are treated as ambiguous and must not silently choose a parent. The child remains unresolved unless the implementation can prove a unique parent.
- The reader remains read-only: no Cursor files, stores, or metadata are written or deleted.
- Tool arguments/results, reasoning, attachments, and encrypted payloads remain outside the index.

## Testing requirements

Add focused fixtures and tests for:

1. ACP root path extraction from a synthetic store containing one valid transcript path.
2. Absolute-path normalization and rejection of unrelated/non-JSONL paths.
3. Indexer association of a matching JSONL `Session` with the ACP parent ID and `cursor-acp-subagent` type.
4. A timestamp-prefixed JSONL session with no ACP reference remaining unassociated.
5. Duplicate references from two ACP stores remaining unresolved rather than arbitrarily attached.
6. Existing hierarchy flattening, collapse behavior, and source-pill tests continuing to pass.

## Non-goals

- No same-project/time-window heuristic.
- No attempt to reconstruct relationships from transcript prose or tool-call text.
- No ACP `session/load` or resume support.
- No redesign of the session list or generic hierarchy subsystem.
- No decoding or indexing of sensitive tool payloads.
