# Cursor ACP Strong Parent–Subagent Association

## Status

Approved design; implementation in progress.

### Evidence revision (2026-09-19)

Inspection of Cursor's persisted chat stores showed that ACP-created
subtasks are written as top-level transcript directories rather than under
`agent-transcripts/<parent>/subagents/<child>.jsonl`. The child chat store's
hex-encoded `meta` record contains a validated lineage object:

```json
{"subagentInfo":{"parentAgentId":"<parent>","rootParentAgentId":"<root>","toolCallId":"<tool-call>","typeName":"<type>"}}
```

This metadata is now the authoritative association source. The existing
field-18 nested transcript-path association remains a compatibility fallback.

## Goal

Recognize and present Cursor ACP parent sessions together with only those Cursor JSONL subtask sessions that are explicitly referenced by the ACP persisted store.

The first phase deliberately does not infer relationships from shared project paths, timestamps, titles, or filename patterns alone.

## Evidence boundary

Cursor ACP persisted sessions are stored at `~/.cursor/acp-sessions/<uuid>/store.db` with `meta.json`. The current read-only ACP reader decodes the root turn graph and creates one `.acp` `Session`, but it does not expose the root record's local transcript/resource paths. Cursor JSONL transcripts are discovered separately under `~/.cursor/projects/**/agent-transcripts/**/*.jsonl`; their first user content may begin with a `<timestamp>` marker, but that marker is not a parent identifier.

The accepted parent-child evidence is either a validated child chat-store
`subagentInfo.parentAgentId`, or an exact, normalized nested transcript path
present in the ACP root record's persisted resource/path fields. A transcript
that merely shares `cwd`, project, time range, title, or a timestamp-prefixed
first prompt with an ACP row remains unresolved and is not attached.

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

The ACP reader should expose a backward-compatible `parseResult(at:) -> CursorACPParseResult?` value containing the ACP `Session` and a set of referenced transcript paths; the existing `parse(at:) -> Session?` remains as a thin session-only wrapper for call sites that do not need associations. All callers that need relationships (`CursorSessionIndexer`, full-path reload, and source-descriptor parsing) use `parseResult`. The indexer owns applying that association to already-parsed transcript sessions, so parsing remains read-only and the generic hierarchy builder remains source-agnostic.

## Architecture and flow

1. `CursorACPStoreReader` validates the existing ACP schema and root graph as it does today. `CursorChatMetaReader` additionally decodes validated child-store `subagentInfo` metadata without reading message blobs.
2. The accepted path-bearing field is the observed root protobuf message's repeated field **18**, wire type 2, whose value is a UTF-8 resource path. Extraction is bounded to field 18 on the validated root message only; it does not recursively scan turn, step, tool, raw JSON, or blob payloads. Two exact layouts are recognized: a root transcript `agent-transcripts/<rootUUID>/<rootUUID>.jsonl` (both UUID tokens are the same), and a child transcript `agent-transcripts/<parentUUID>/subagents/<childUUID>.jsonl` (the UUID tokens are valid but intentionally different). Only the second layout can produce a child association; a root transcript reference identifies the ACP session's own transcript and is ignored for parent assignment. Relative paths, `.`/`..` paths, arbitrary strings, tool payloads, encrypted blobs, and non-JSONL resources are ignored in phase one.
3. `CursorSessionIndexer` builds a child-session-ID-to-parent-set lookup from validated chat metadata, restricted to parent IDs represented by indexed ACP rows. It also retains a normalized absolute-path-to-parent-set fallback lookup from ACP results. Normalization standardizes repeated separators and `.`/`..` lexically, never follows symlinks, and uses the host's case-sensitive path comparison semantics.
4. Association runs after `SessionIndexingEngine.hydrateOrScan` returns, regardless of whether sessions came from fresh parsing or the persisted lightweight cache, and after Cursor metadata merge makes DB-only rows available but before sorting/publishing. Matching transcript or DB-only sessions receive the explicit parent ID, subagent type, and relationship kind through a relationship-copy helper.
5. `SubagentHierarchyBuilder` resolves the parent ID and produces the existing parent-first, collapsible row structure.
6. `SessionRowsBuilder` / title-row rendering expose the ACP relationship without removing the existing ACP pill from the parent. A linked child uses the existing generic `sub` marker plus a localized/accessibility label such as `ACP subagent`; it must not display the internal value `cursor-acp-subagent` as user-facing text.

Path normalization must be deterministic: standardize absolute paths, resolve `.` and `..`, and compare path strings without following symlinks or using basename-only matching. Missing or malformed path values are ignored.

## Failure handling and safety

- Unknown ACP schemas, malformed stores, incomplete graphs, and unreadable sidecars continue to reject the ACP row as they do today.
- A malformed or non-transcript resource path is ignored; it cannot attach an unrelated session.
- Repeated references from the same ACP parent are deduplicated and remain a single association.
- The lookup stores a set of candidate ACP parent IDs per normalized path. A path referenced by multiple distinct ACP parents is ambiguous; it remains unresolved and no parent is chosen.
- The existing Cursor path parser may already assign a raw parent UUID for the `agent-transcripts/<parentUUID>/subagents/<childUUID>.jsonl` layout. Ambiguity is checked first: the raw-parent namespace upgrade is allowed only when the normalized path has exactly one candidate ACP parent ID. When that sole candidate equals the raw parent UUID, the ACP association is an authoritative namespace upgrade: replace the raw parent key with `cursor-acp:<uuid>` and use the ACP child relationship. When it differs, preserve the existing inferred parent metadata and mark the ACP reference unresolved rather than overwriting it. Other authoritative non-ACP parent metadata also wins. An identical ACP association is idempotent.
- Stale references to missing transcript files have no effect; when a referenced file disappears on rescan, its child row disappears through normal discovery and no dangling row is synthesized.
- The reader remains read-only: no Cursor files, stores, or metadata are written or deleted.
- Tool arguments/results, reasoning, attachments, and encrypted payloads remain outside the index.

## Testing requirements

Add focused fixtures and tests for:

1. ACP root field-18 extraction from a synthetic store containing one valid root transcript path and one valid `subagents/<childUUID>.jsonl` path, while a matching-looking path in a tool/blob payload is ignored.
2. Path normalization and rejection tests for both accepted layouts, relative paths, `.`/`..`, repeated separators, symlink non-following, non-JSONL paths, mismatched root UUIDs, and host path case semantics.
3. Indexer association of a matching JSONL `Session` with the ACP parent ID and internal `cursor-acp-subagent` type, while the user-facing badge is generic `sub` with ACP accessibility text.
4. The same association when the transcript session comes from the persisted lightweight cache returned by `hydrateOrScan`.
5. A timestamp-prefixed JSONL session with no ACP reference remaining unassociated.
6. Repeated same-parent references deduplicating; cross-parent references remaining unresolved rather than arbitrarily attached.
7. The actual discovered `subagents/<childUUID>.jsonl` path-derived raw parent UUID being upgraded to `cursor-acp:<parentUUID>` when it matches the sole ACP candidate, while a conflicting non-ACP parent remains unchanged.
8. Two ACP stores referencing the same child path remaining unresolved even when one candidate happens to match the child's raw path-derived parent UUID.
9. Two child-store metadata records for the same child with conflicting `parentAgentId` values remain unresolved; malformed or incomplete `subagentInfo` is ignored.
9. Relationship-copy tests asserting events, surface/originator, model, project metadata, titles, and all other immutable `Session` fields are preserved.
10. Existing hierarchy flattening, collapse behavior, ACP parent pill, and no-sensitive-payload tests continuing to pass.

## Non-goals

- No same-project/time-window heuristic.
- No attempt to reconstruct relationships from transcript prose or tool-call text.
- No ACP `session/load` or resume support.
- No redesign of the session list or generic hierarchy subsystem.
- No decoding or indexing of sensitive tool payloads.
