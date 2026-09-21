# DeepSeek Harness Session Source Implementation Plan

**Date:** 2026-09-18
**Status:** Implementation in progress; owner decisions 1A-9A recorded 2026-09-18
**Target repository:** `/Users/alexm/Repository/Codex-History`
**Reference implementation inspected:** `/Users/alexm/Repository/deepseek-harness` at `ddefc45fbc7f8e46dd73185e68295696d1297887` (`dsh-v0.1.6-alpha.2`)
**Agent Sessions authority inspected:** `e29459355123a411dedaddf17ce81db4b77d5fcf`

## Outcome

Add a read-only **DeepSeek Harness** source to Agent Sessions that discovers local DSH session directories, selects the newest generation, reads plain JSONL and concatenated Zstandard frames, normalizes released formats v0 through v3, and maps the result into Agent Sessions without changing DSH-owned files.

The first release is deliberately a history browser, not a DSH client:

- Include local browsing, full-text search, ordinary transcript analytics, DSH subagent hierarchy, and Agent Sessions' own snapshot/archive operation.
- Exclude resume, live following, DSH archive-state mirroring, attachment-byte extraction, quota/cost telemetry, and generic fork-lineage UI.
- Reject a session when its selected artifact has a torn physical tail, a corrupt complete frame, a required unknown event, a failed historical migration, or an unsupported future format. Do not publish a recovered prefix as if it were complete.
- Preserve the last successfully indexed Agent Sessions row when a later refresh of the same logical session fails.

This is the smallest scope that can make a defensible compatibility claim. It does not turn a best-effort parse into an apparently complete transcript.

## Release decision: ship in 5.5

The PREP and planning prompt name Agent Sessions 5.2. That version has already shipped, as have 5.3 and 5.4 (`docs/CHANGELOG.md:12`, `docs/CHANGELOG.md:24`, `docs/CHANGELOG.md:75`). The project currently sets `MARKETING_VERSION = 5.4` (`AgentSessions.xcodeproj/project.pbxproj:3597`, `AgentSessions.xcodeproj/project.pbxproj:3668`), and `.cline` already uses `versionIntroduced: "5.4"` (`AgentSessions/Model/SessionSource.swift:80`). The source guide explicitly says a new source must use the real upcoming release and must never be attached to an already shipped release (`docs/adding-a-session-source.md:58-71`).

The owner selected **5.5** on 2026-09-18. Use `versionIntroduced: "5.5"`, put release-facing copy under the 5.5 unreleased section, and add a metadata test that prevents the source from being attributed to an already shipped release.

## Current-source reconciliation

The table below is the authority for implementation. “Confirmed” means the claim matches the inspected source. “Stale” means current source contradicts or narrows the PREP/draft claim. “Inferred” is a composition of separately confirmed facts and must not be promoted to a universal DSH rule. “Unresolved” requires evidence or an owner decision before release.

| PREP claim | Status | Current evidence | Implementation consequence |
|---|---|---|---|
| The current logical session format is v3. | Confirmed | `packages/core/session/src/types.ts:66-88`; `docs/session-format-status.md:16-35` | Accept physical versions 0-3 and normalize to the v3 logical model. Reject versions above 3. |
| Released migrations are v0→v1→v2→v3. | Confirmed | `packages/session/session-format-catalog/src/generated.ts:1-30`; `docs/persistence-changes/historical-formats/README.md:23-41` | Port adjacent migrations in order. Never jump directly from an old physical shape to the Agent Sessions model. |
| DSH home precedence is configured value, then nonblank `DSH_HOME`, then `~/.dsh`. | Confirmed | `packages/util/home-paths/src/index.ts:57-100`, `packages/util/home-paths/src/index.ts:113-123`; boot wiring at `packages/boot/app-boot/src/index.ts:201-220` | Agent Sessions preference override wins, then inherited `DSH_HOME`, then `~/.dsh`. Empty or whitespace-only environment values are ignored. Do not read DSH `.env` files. |
| Normal bundled sessions live under `$DSH_HOME/sessions`. | Confirmed | `packages/bundle/base/cordis.patch.yml:117-120`; `packages/bundle/sdk-minimal/cordis.patch.yml:154-158` | Scan `<resolved-home>/sessions`. Label this the bundled default, not a guarantee for arbitrary custom profiles. |
| `./.sessions` is a shipped TUI default. | Stale | No shipped TUI session profile was found; the inspected CLI is a profile launcher (`apps/cli/src/args.ts:1-16`, `apps/cli/src/args.ts:130-168`). | Do not scan `./.sessions` and do not claim TUI provenance from a path. Custom roots remain out of v1 unless the user supplies the sessions-root override. |
| A session is stored in a lossy project-key directory and a reversibly encoded opaque session-id directory. | Confirmed | `SessionId` accepts an opaque string (`packages/core/session/src/types.ts:19-29`); `encodeSegment` is reversible but `projectKey` is intentionally lossy (`packages/session/session-persistence-jsonl/src/format.ts:195-267`) | Discovery walks candidate `sessions/<project-key>/<encoded-session-id>/` directories, then validates the header-derived canonical path. Do not require UUID syntax and do not decode a project key for display. |
| Generation 0 is `session.jsonl`; later generations are `session.vN.jsonl`. | Confirmed | `packages/session/session-format/src/filename.ts:5-17` | Treat the session directory, not a generation file, as the logical identity. Select the highest valid generation number. |
| Compression adds `.zstd`. | Confirmed | `logSuffix` returns `.jsonl.zstd` and `compressionSuffix` returns `.zstd` (`packages/session/session-persistence-jsonl/src/format.ts:33-58`) | Recognize canonical `.jsonl` and `.jsonl.zstd` forms only. Reject `.zst`, uppercase, temporary, leading-zero, and explicit-v0 filename variants. |
| Mixed plain/zstd artifacts anywhere under the same configured root are invalid. | Confirmed | `packages/session/session-persistence-jsonl/src/index.ts:1390-1395`, `packages/session/session-persistence-jsonl/src/index.ts:1528-1541`, `packages/session/session-persistence-jsonl/src/index.ts:1563-1597` | Determine the root's encoding before publishing sessions, including artifacts in different session directories. A mismatch fails that root refresh; do not silently choose one encoding. |
| Legacy flat files directly inside a project directory are unsupported. | Confirmed | `packages/session/session-persistence-jsonl/src/index.ts:1517-1525`, `packages/session/session-persistence-jsonl/src/index.ts:1543-1555`, `packages/session/session-persistence-jsonl/src/index.ts:1593-1597` | Report a root compatibility issue for `<root>/<project>/<encoded-id>.jsonl[.zstd]`. Never reinterpret it as the current directory layout. |
| The highest generation is authoritative and old generations are immutable. | Confirmed | selection at `packages/session/session-persistence-jsonl/src/index.ts:1368-1404`; immutability at `packages/session/session-persistence-jsonl/README.md:74-82`; successor publication at `packages/session/session-persistence-jsonl/src/index.ts:495-665` | Re-evaluate the parent directory on every stat/parse so a newly published generation supersedes the old one without changing logical identity. Never edit or delete any generation. |
| Physical identity includes filename version, header id/cwd, root encoding, and canonical path. | Confirmed | filename/header version check at `packages/session/session-persistence-jsonl/src/index.ts:1033-1060`; canonical path verification at `packages/session/session-persistence-jsonl/src/index.ts:1435-1463` | Require generation-number/header-version agreement and recompute `generationLogPath(root, cwd, id, version, compression)`. Accept only that path or the same physical file. |
| A read overlapping appends needs a stable snapshot. | Confirmed | `readStableJsonlFile` stats before and after, retries once, then returns the second read's committed pre-read prefix (`packages/session/session-persistence-jsonl/src/generation.ts:244-278`); persistence uses it at `packages/session/session-persistence-jsonl/src/index.ts:550`, `packages/session/session-persistence-jsonl/src/index.ts:706-707` | Port bounded stable-read semantics for plain and compressed artifacts, then recheck selected generation before publication. Periodic complete reparse must not mistake an active append for corruption. |
| v3 headers include id, creation time, optional cwd/parent, seeded state, and optional origin metadata. | Confirmed | `packages/core/session/src/types.ts:93-130`; physical header validation at `packages/session/session-persistence-jsonl/src/format.ts:82-185` | Validate identity and header invariants before mapping. Use `createdAt` as milliseconds since Unix epoch. Do not resurrect removed historical header fields. |
| Current physical events are envelopes with `type`, `seq`, `time`, `data`, and `ignorable`. | Confirmed | `packages/core/session/src/types.ts:411-493` | Require continuous valid sequence semantics after normalization. Skip only unknown events explicitly marked ignorable; refuse unknown required events. |
| Current core events include turn, step, messages, assistant attempts, tool calls/results, request header/context, and seed completion. | Confirmed | `packages/core/session/src/types.ts:269-406` | Build an explicit event-disposition table. Every known event is rendered, mapped to metadata, or intentionally ignored with a test. |
| Old formats can contain physical packed text/reasoning/tool-call chunks; current v3 embeds streams in assistant messages. | Confirmed | `packages/session/session-format-v0-to-v1/src/codec.ts:21-48`, `packages/session/session-format-v0-to-v1/src/codec.ts:203-295`; current assistant stream definitions at `packages/llm/llm/src/assistant-stream.ts:19-47` | Fold old chunks during migration. Do not render both chunks and their final message. Current v3 assistant streams are embedded in assistant-message payloads, not separate physical rows. |
| Content blocks include text, reasoning, images/files, tool results, and related structured data. | Confirmed | `packages/llm/llm/src/types.ts:60-137`; message structures at `packages/llm/llm/src/message.ts:98-168`, `packages/llm/llm/src/message.ts:213-267` | Render text/reasoning/tool content. Represent attachment references with deterministic metadata placeholders; do not resolve external bytes in v1. |
| Surface replacement and source-event provenance matter. | Confirmed | `packages/core/session/src/types.ts:411-493`; sequence-range rules at `packages/core/session/src/seq-ranges.ts:18-67`; v3 provenance admission at `packages/session/session-format-v2-to-v3/src/payload.ts:265-312` | Validate and preserve `surfaceOp` and `sourceEventSeqs` in raw metadata. Do not invent a single parent event when the source records a range. Transcript history remains chronological; replacement operations get explicit metadata rather than silently deleting durable history. |
| Zstandard files are concatenated independent frames, normally one frame per append. | Confirmed | writer at `packages/session/session-persistence-jsonl/src/index.ts:1206-1227`; frame scanner at `packages/session/session-persistence-jsonl/src/zstd.ts:15-104` | The decoder must enumerate frame boundaries and decode frames independently. One-shot decompression and magic-byte splitting are not acceptable. |
| The first Zstandard frame contains exactly one newline-terminated header record. | Confirmed | `packages/session/session-persistence-jsonl/src/index.ts:74-79`, enforced during read at `packages/session/session-persistence-jsonl/src/index.ts:903-915` | Reject an empty first frame, a non-newline-terminated header, or a first frame containing any event row. |
| DSH can recover complete records from a torn final raw line or Zstandard frame. | Confirmed | raw recovery at `packages/session/session-persistence-jsonl/src/index.ts:690-767`; framed recovery at `packages/session/session-persistence-jsonl/src/index.ts:889-973`; per-frame fallback at `packages/session/session-persistence-jsonl/src/zstd-public-decoder.ts:9-39` | V1 rejects both. It may identify complete raw records before a torn line, but for compressed input it records only complete prior frames plus `tornStart`; it does not claim DSH's partial-frame plaintext recovery. |
| A complete Zstandard frame ending in a torn JSONL record is corruption, not a recoverable torn frame. | Confirmed | `packages/session/session-persistence-jsonl/src/index.ts:915-934` | Reject it. Tests must distinguish this case from an actually incomplete final frame. |
| Historical migration is an in-memory read operation; persisted migration publishes a successor rather than overwriting the source. | Confirmed | `packages/session/session-persistence-jsonl/src/index.ts:336-387`, `packages/session/session-persistence-jsonl/src/index.ts:495-665`; `docs/architecture.md:119-125` | Agent Sessions performs normalization in memory only. It never invokes DSH migration writes and never publishes a successor. |
| Migration codecs have recoverable and strict semantic behavior. | Confirmed | v0/v1 at `packages/session/session-format-v0-to-v1/src/codec.ts:70-135`; v1/v2 at `packages/session/session-format-v1-to-v2/src/codec.ts:75-129`; v2/v3 at `packages/session/session-format-v2-to-v3/src/codec.ts:20-60` | Port both result classification and validation. Agent Sessions v1 uses strict publication: any recovery classification prevents publication. |
| Fully decoded logs can still end with an interrupted turn that DSH repairs semantically on resume. | Confirmed | repair model at `packages/core/session/src/repair.ts:21-134`; agent-loop use at `packages/core/agent-loop/src/index.ts:853-915` | For browsing, synthesize display-only interrupted-turn closure metadata after successful complete-file decoding. Never write the repair to DSH storage. |
| Subagents are expressed through `parentSession`, origin, delegation depth, and preset. | Confirmed | header at `packages/core/session/src/types.ts:93-130`; depth at `packages/subagent/subagent/src/depth.ts:28-35`; child creation at `packages/subagent/subagent/src/child-agent.ts:42-51`, `packages/subagent/subagent/src/child-agent.ts:139-156` | Only subagent-origin sessions enter Agent Sessions' parent hierarchy. Map preset to subtype when present. |
| Seeded forks also carry a parent id. | Confirmed | fork creation at `packages/core/session/src/index.ts:1236-1312` | Do not map a non-subagent fork parent to `Session.parentSessionID`; Agent Sessions currently interprets every such parent as a subagent (`AgentSessions/Model/Session.swift:108-181`, `AgentSessions/Services/SubagentHierarchyBuilder.swift:68-117`). Preserve fork provenance as DSH metadata and keep the fork as a root. |
| Archive state is not stored in the session log. | Confirmed | workspace spec at `packages/workspace/workspace/src/spec.ts:43-75`; archive operations at `packages/workspace/workspace/src/index.ts:226-277` | Do not infer upstream archive state from session artifacts. DSH archive mirroring is out of v1. |
| The default bundled archive file is `$DSH_HOME/storages/workspace.json`. | Inferred | base storage root/routing at `packages/bundle/base/cordis.patch.yml:148-163`; single-unit filename at `packages/storage/storage-json/src/single-unit.ts:1-49`; configurable routing at `packages/storage/storage-domain/src/index.ts:46-118` | This inference applies only to the normal base bundle. Do not read the file in v1; custom storage backends make a global assumption unsafe. |
| A DSH log has enough information to identify the launch surface. | Stale | persisted headers carry origin/subagent data but no reliable Web/ACP/headless/Desktop discriminator (`packages/core/session/src/types.ts:93-130`) | Set ordinary root surface to unknown. Never infer a surface from the project path, profile name, or CLI presence. |
| Resume behavior is common across DSH surfaces. | Stale | headless restrictions at `packages/bundle/headless/src/index.ts:166-228`; Web controller at `packages/api/session-controller/src/agent.ts:407-494`; ACP at `packages/acp/acp/src/index.ts:239-289`; Desktop caveat at `apps/desktop/README.md:36-69` | `supportsResume = false`. Do not expose Resume or Copy Resume Command in v1. |
| Headless `--session-id` is a suitable Agent Sessions resume path. | Stale | option at `packages/bundle/headless/src/startup.ts:38-52`; one-shot constraints and task requirement at `packages/bundle/headless/src/index.ts:166-228` | Do not generate a headless command. It is not a general interactive resume contract. |
| Live following can be implemented by tailing the selected file. | Stale | immutable successor generations and per-append Zstandard frames (`packages/session/session-persistence-jsonl/src/index.ts:495-665`, `packages/session/session-persistence-jsonl/src/index.ts:1206-1227`); protocol history/following at `packages/api/session-controller/src/history.ts:41-239` | V1 uses periodic discovery and complete reparse only. `supportsLiveIngestion = false`. Protocol-native live ingestion is a separate project. |
| Attachment bytes are self-contained in the session JSONL. | Stale | message blocks carry attachment identity/metadata rather than guaranteed inline bytes (`packages/llm/llm/src/types.ts:72-101`) | No extraction, preview, or arbitrary path following. Render a placeholder with safe metadata only. |
| The installed `dsh` binary and real private corpus have been checked. | Owner decision | The owner selected a small opt-in sanitized specimen set plus a shape/type inventory, while explicitly withholding authorization to inspect `~/.dsh`. | Do not inspect private DSH state. Accept only specimens the owner separately supplies or exports through an approved sanitizer, and keep the evidence limitation visible until they pass. |
| A bundled Swift Zstandard decoder is already available. | Owner decision | The owner selected official Zstandard 1.5.7 vendored source, pinned by source-archive SHA-256 under its BSD license. | Replace the temporary remote Swift package with a local C target containing only required decompression/common sources, wrap it narrowly, and support arm64 and x86_64 without Homebrew, subprocesses, or runtime library discovery. |

## V1 product contract

### Included

- Bundled-default and user-overridden DSH sessions-root discovery.
- Format versions 0, 1, 2, and 3 through ordered normalization.
- Plain JSONL and concatenated Zstandard frames.
- Highest-generation selection and immutable-generation awareness.
- User, system, assistant, reasoning, tool-call, tool-result, request-context, turn, and step history.
- DSH subagent hierarchy when the header explicitly establishes subagent origin.
- Full-text search over safe rendered content.
- Existing Agent Sessions analytics that can be derived from normalized events, such as message/tool counts, duration, and model labels when present.
- Agent Sessions snapshot/archive support, copying a filtered manifest of canonical generation siblings so the logical history stays together without sweeping future unknown session-local files.
- Source health, indexing errors, and deterministic failure messages.

### Excluded

- Any write to `$DSH_HOME`, DSH session files, storage domains, or successor generations.
- Resume or command generation for CLI, Web, SDK, ACP, headless, Desktop, or custom profiles.
- Live protocol following or raw file tailing.
- Mirroring DSH's archived/unarchived workspace state.
- Attachment-byte lookup, image preview, file opening, or arbitrary path traversal.
- DSH-native query composition.
- Cost, quota, context-window, or provider telemetry claims not independently verified from persisted data.
- Generic fork-lineage UI. Seeded forks remain independently listed roots.
- Publishing torn-tail prefixes. The decoder reports the classification internally, but the indexer fails closed.
- Automatic discovery of custom profile roots. Users can point the source at one explicit sessions root.

### User-facing compatibility statement

Use this wording until evidence expands:

> Reads local DeepSeek Harness session formats v0-v3 from the bundled directory layout, including plain and Zstandard-compressed histories. Custom required event extensions and incomplete or corrupt tails are reported but not shown as complete sessions.

Do not say “all DSH sessions,” “lossless,” “live,” “resumable,” or “archive-aware.”

## Identity, discovery, and reload behavior

The logical artifact is the **session directory**. A generation file is only its current physical representation.

1. Resolve the sessions root from the explicit Agent Sessions preference, then inherited `DSH_HOME/sessions`, then `~/.dsh/sessions`.
2. Inspect only direct real project directories and their direct real session directories. Match DSH's `Dirent.isDirectory()` behavior by skipping all directory symlinks, including symlinks whose target remains inside the root.
3. Treat directory names as candidates, not identities. Do not require UUID syntax, and do not attempt to reverse the lossy project key.
4. Classify encoding across every recognized artifact under the configured root. If plain and Zstandard artifacts coexist where DSH refuses them, fail the root refresh.
5. Parse only exact canonical generation filenames. Select the numerically highest generation, not lexicographic order or modification time, and require its generation number to equal the physical header version.
6. Obtain stable bytes with pre-stat → read → post-stat, retry once when identity changes, and on a second overlapping append use only the committed pre-read prefix or return a retryable failure. Apply the same rule before raw or Zstandard decoding.
7. Validate the header, then recompute the canonical generation path from configured root + header cwd + header id + stored version + root compression. Require the selected path to equal that path or resolve to the same physical file. This validates both the lossy project key and reversible encoded id without guessing either from display text.
8. Use the opaque DSH header id as the stable Agent Sessions id. If the same id resolves from multiple project directories, report an ambiguity and publish neither copy until the collision is resolved.
9. Add a source-agnostic directory-artifact revision seam containing at least `selectedURL`, a deterministic manifest revision, and the selected file's real `SessionFileStat`. Do not overload the current two-field `SessionFileStat` (`mtime`, `size`) with encoded generation or sibling data (`AgentSessions/Services/SessionDiscovery.swift:12-40`).
10. In focused/provider reload, rescan the parent and select the highest generation. After parsing, rescan once more before publication; if the selected generation changed during the parse, discard the result and retry through normal refresh scheduling.
11. Record the selected physical file in `Session.filePath`, while archive and logical cache identity remain directory-scoped.
12. In search ingest, treat the `FileRef.path` as an immutable anchor for that ingest attempt. If parent rescan selects another generation, return a **stale anchor** result without modifying the existing search document. Let the refreshed source row create a new `FileRef` for the new path and retry.

Failure behavior is transactional:

- Initial discovery failure: omit the affected session and report one bounded indexing issue.
- Refresh failure after a successful parse: retain the last healthy row and search document; attach the new indexing issue; do not replace content with a partial parse.
- Root-shape failure: retain the previous successful root snapshot and report the root issue.
- Stale search anchor: leave the existing FTS document unchanged and schedule ingestion from the refreshed row's new anchor.
- Successful complete reconciliation: commit source rows/session metadata first, then run the existing asynchronous search-ingest phase. Do not promise one transaction across provider storage and the search database; each phase must remain internally transactional and failure-preserving (`AgentSessions/Services/UnifiedSessionIndexer.swift:1646-1648`, `AgentSessions/Search/SearchIngestService.swift:577-599`).

## End-to-end data flow

```text
preference / DSH_HOME / ~/.dsh
            |
            v
sessions-root validation
            |
            v
project-dir -> session-dir -> generation manifest
                              |
                              v
                   highest-generation selection
                              |
                    stable physical snapshot
                              |
                     +--------+--------+
                     |                 |
                 raw JSONL       concatenated zstd
                     |          frame scan + decode
                     +--------+--------+
                              |
                    physical record reader
                              |
       canonical identity/header/envelope/seq validation
                              |
                 v0 -> v1 -> v2 -> v3
                              |
                  normalized DSH events
                              |
       disposition + content + relationship mapping
                              |
                   Agent Sessions Session
                     /        |         \
                  list    transcript    FTS/analytics
```

No stage writes back to the source. A successful generation change replaces the source row projection transactionally; search follows through the existing second phase. A stale generation anchor changes neither phase and is retried from the newly selected URL.

## Normalization and mapping rules

### Header and relationships

- `id` → `Session.id` after path/header identity validation.
- `createdAt` → `Session.startTime` using milliseconds, with a range check.
- `cwd` → `Session.projectPath`; absent cwd is valid and becomes nil.
- `origin == "subagent"` or a source-confirmed subagent origin plus `parentSession` → `parentSessionID`, relationship `.subagent`, and subtype from `agentPreset` or `subagent`.
- `parentSession` without subagent origin → DSH fork metadata only. Do not set `parentSessionID`.
- `isSeeded`, fork parent, delegation depth, preset, and inherited-cut metadata remain available in the raw header/meta projection.
- Ordinary DSH roots use no asserted launch surface. Subagents use the existing subagent relationship semantics, not a fabricated Web/CLI surface.

### Title and summary

- Title uses the first nonblank direct-human user text after normalization.
- Plugin-injected context, request context, system messages, attachment-only blocks, and seed metadata cannot become the title.
- If no direct-human text exists, use a deterministic fallback derived from project display label and creation time, never raw attachment data.
- Summary uses the first safe direct-human text excerpt and follows the existing redaction/truncation path.

### Event disposition

Create a checked-in table in code with one disposition for every frozen known event type:

- `turn/start`, `turn/end`, `step/start`, `step/end` → lifecycle/meta events and duration inputs.
- `user/message`, `system/message`, `assistant/message` → message events. Embedded assistant streams are metadata/provenance, not duplicate transcript rows.
- `assistant/attempt` → diagnostic metadata only. It committed no model-visible surface message (`packages/core/session/src/types.ts:330-335`), so its stream never contributes assistant transcript text, title, FTS, message counts, token totals, or surface reconstruction.
- Assistant-message `tool-call` block + matching `tool/call` event → exactly one Agent Sessions tool-call item keyed by `callId`. The message block owns model-request provenance; the event supplies recorded-start sequence/log metadata. A `tool/result` pairs to that item by call id. Preserve unmatched records explicitly, but never emit both durable representations as two invocations (`packages/core/session/src/repair.ts:54-72`, `packages/llm/llm/src/types.ts:103-119`).
- `request/header` → model/provider/reasoning metadata. The latest valid request header wins for list-level model fields.
- `request/context` → request-context meta; injected context is not direct-human content.
- `session/end-seed` → seed-boundary meta.
- Known first-party extension events → explicit per-type dispositions derived from the frozen catalog.
- Unknown `ignorable: true` → skip from rendered output but retain type/seq in diagnostics.
- Unknown required event → reject the session.

Historical packed assistant chunks are folded before disposition. A final assistant message is rendered once. `sourceEventSeqs` and `surfaceOp` are validated and retained in event raw data. The chronological transcript keeps durable history; replacement operations appear as compact metadata rather than erasing prior records from the history browser.

### Content blocks

- Text → plain transcript text.
- Reasoning → reasoning event/content using the existing Agent Sessions rendering convention.
- Tool result content → nested text and safe structured summaries; cap pathological payload size before UI construction.
- Image/file/attachment reference → placeholder containing only source-provided type, display name, media type, and size when present.
- Never open attachment paths, resolve content ids, or load bytes in v1.
- Preserve unrendered structured payload in bounded raw JSON for inspection, subject to existing secret redaction.

### Model, tokens, analytics, and search

- Model/provider fields use the latest valid request header, then the latest assistant-message source metadata as a fallback.
- Persist token usage only when the normalized event carries source-defined numeric usage (`packages/llm/llm/src/types.ts:154-176`). Do not manufacture missing prompt/completion splits.
- Existing analytics may count normalized user/assistant/tool events and calculate duration from valid timestamps.
- Cost and quota features remain unavailable unless a separate persisted-data audit proves their meaning.
- Set the descriptor's required telemetry verdict to `.allUnavailable("DeepSeek Harness telemetry not yet audited")` in v1. This does not prevent ordinary `Session.model` or source-recorded event usage from rendering; it prevents those fields from being promoted into unverified product telemetry (`AgentSessions/Model/SessionSourceDescriptor.swift:228`, `AgentSessions/Cline/ClineSourceDescriptor.swift:38`).
- Search indexes direct-human text, assistant text, reasoning according to existing privacy settings, and rendered tool content. It excludes attachment ids/paths, injected request context, and raw diagnostic JSON.
- Superseded history remains searchable because this product is a history browser; replacement metadata explains the source operation.

## Zstandard dependency and recovery design

### Required decoder shape

The owner selected official Zstandard **1.5.7** as a pinned, in-process decoder that ships inside the app. Implement it as a small local package under `ThirdParty/DSHZstd/` with:

- a C target containing the pinned upstream Zstandard decompression/common sources and license;
- a narrow Swift wrapper that scans frame headers, returns exact frame byte ranges, decompresses one complete frame at a time, enforces the exact-one-header-line first frame, and reports the start offset of a truncated final frame;
- explicit compressed-size, decompressed-size, frame-count, and expansion-ratio limits;
- deterministic errors containing frame ordinal and byte offset, but no private content.

Record the upstream source-archive URL and SHA-256, selected BSD license and copied notices, exact included source list, arm64/x86_64 support, and a reproducible update procedure. The temporary remote `facebook/zstd` Swift-package reference is not the approved shipping shape and must be removed.

Forbidden implementations:

- invoking Homebrew or `/usr/bin` helpers;
- using `Process` to run `zstd`;
- discovering a dynamic library at runtime;
- splitting on Zstandard magic bytes;
- assuming one frame per file;
- feeding a concatenated file to a one-shot API without recovering frame boundaries and validation results.

### V1 recovery policy

The reader must distinguish:

1. complete valid frames/records — publish after semantic validation;
2. truncated final raw record — classify as recoverable upstream, reject for Agent Sessions v1;
3. truncated final Zstandard frame with earlier complete frames — report the complete-prior-frame boundary and `tornStart`, then reject for v1; do not claim recovery of records emitted inside the incomplete frame because the v1 decoder does not implement partial-frame decompression;
4. complete frame containing a torn JSONL record — corruption, reject;
5. checksum/frame/JSON corruption before the final tail — corruption, reject;
6. first frame that is not exactly one newline-terminated header record — corruption, reject;
7. fully decoded log ending inside a semantic turn — display the complete persisted history and add a display-only interrupted-turn closure derived from DSH repair semantics.

This conservative choice is intentional. Publishing a recovered prefix requires a persistent and obvious incomplete-state marker in list, transcript, search, export, and archive views. Agent Sessions does not currently have that generic contract. Add it in a separate plan before relaxing v1.

## Historical migration strategy

Implement a source-specific intermediate representation backed by validated JSON values, then port the frozen adjacent transformations from:

- `packages/session/session-format-v0-to-v1/src/`
- `packages/session/session-format-v1-to-v2/src/`
- `packages/session/session-format-v2-to-v3/src/`

Each stage must:

1. decode only its declared physical version;
2. enforce header identity and sequence invariants;
3. apply the source's payload validation, relationship, disposition, and source-range rules;
4. produce the exact next logical version;
5. preserve unknown ignorable envelopes without rendering them;
6. fail on unknown required events or unsupported extension semantics;
7. never mutate the physical file.

Do not write a single permissive “accept any JSON with text” parser. Do not duplicate historical and current rendering paths. All versions converge on one v3-normalized event stream before Agent Sessions mapping.

The port is accepted only after differential fixtures compare the Swift normalized output with canonical expected v3 JSON produced from the pinned DSH source. Where TypeScript validators accept a first-party extension, the Swift port must either match it or explicitly fail and narrow the compatibility statement.

## Archive and resume decisions

### Agent Sessions archive/snapshot

Extend the existing Agent Sessions archive capability with a generic source-owned archive-entry filter, then archive a filtered DSH session-directory manifest:

- archive root: selected generation's parent session directory;
- primary relative path: selected generation filename;
- archive entry filter: accept only canonical regular generation siblings for the root's selected encoding; reject symlinks, non-regular files, noncanonical names, opposite-encoding artifacts, and future unknown session-local files;
- copied content: every accepted immutable generation sibling and no unaudited metadata;
- restore/open behavior: rescan the archived directory and choose its highest generation.

The protocol expansion is required: current `ArchiveUnit` carries only `root`, `isDirectory`, and `primaryRelativePath` (`AgentSessions/Model/SessionSourceDescriptor.swift:77-112`), while `SessionArchiveManager` recursively manifests every regular file below a directory (`AgentSessions/Services/SessionArchiveManager.swift:767-814`). Add a filter/manifest closure used consistently by size estimation, stable snapshot validation, and copying; preserve existing retry/stability behavior around the filtered set. Do not include the project directory, sibling sessions, DSH workspace storage, attachment stores, or files reached through symlinks.

This is independent of DSH's own archive flag. All DSH logs remain discoverable in v1 regardless of `$DSH_HOME/storages/workspace.json`.

### Resume

Set `supportsResume`, `supportsCopyResumeCommand`, and every surface-specific resume capability to false. Return no command. Keep all generic resume switches exhaustive, but route DSH to the unsupported path. Do not show disabled surface choices that imply future compatibility.

Revisit only after separate end-to-end experiments prove one surface's public resume contract, including cwd, active-session collision, subagent/fork restrictions, profile/preset semantics, and authentication/runtime state.

### Surface decision matrix

“Browse” below means Agent Sessions may read a compatible artifact from the configured sessions root; it does not mean the persisted header proves which surface created it.

| DSH surface | Browse in v1 | Resume in v1 | Archive behavior | Evidence and decision |
|---|---|---|---|---|
| Headless | Yes, when it writes the supported layout | No | Filtered canonical-generation snapshot only; ignore DSH workspace archive state | Headless accepts `--session-id` (`packages/bundle/headless/src/startup.ts:38-52`) but imposes preset, origin, parent, cwd, task, and live-session constraints (`packages/bundle/headless/src/index.ts:166-291`). It is not a generic interactive resume command. |
| Web/API | Yes | No | Same filtered snapshot; no upstream archive mirroring | Resume/adoption is controller state with cwd/subagent checks (`packages/api/session-controller/src/agent.ts:407-494`), and history following is protocol-owned (`packages/api/session-controller/src/history.ts:41-239`). A local file reader cannot reproduce that contract. |
| SDK/client-server | Yes, when composed with the supported persistence root | No | Same filtered snapshot | The client opens a named handle and starts/owns a subprocess (`packages/sdk/client/src/api.ts:100-114`, `packages/sdk/client/README.md:48`); the server creates live agents by session id (`packages/sdk/server/src/server.ts:259-290`). That is an application protocol, not a safe standalone resume command for Agent Sessions. |
| ACP | Yes | No | Same filtered snapshot | ACP applies persisted-exists, non-subagent/non-fork, directory, and active-session rules (`packages/acp/acp/src/index.ts:239-289`). V1 does not embed an ACP client. |
| Desktop | Yes, for compatible persisted logs | No | Same filtered snapshot | Desktop documents a reserved profile boundary (`apps/desktop/README.md:36-69`) and resumes its existing Web document through application IPC (`apps/desktop/src/main.ts:332`). Agent Sessions has no public external invocation contract. |
| Custom/out-of-tree TUI or profile | Only through an explicit sessions-root override when the layout and format validate | No | Same filtered snapshot within that configured root | No shipped generic TUI resume contract was established from the checkout. Do not scan guessed relative roots or infer behavior from profile names. |

No row gets DSH-native archive/unarchive UI in v1. The separate Agent Sessions snapshot operation is available for every successfully parsed row.

## Files and integration points

Use the repository's standard source shape (`docs/adding-a-session-source.md:81-189`) and keep DSH-specific logic out of generic services except where an exhaustive source switch is required.

### Required generic seams

Make the current path-based contract generation-aware without encoding logical data into `mtime` or `size`:

```swift
struct SessionArtifactRevision: Equatable {
    let selectedURL: URL
    let manifestRevision: String
    let physicalStat: SessionFileStat
}
```

Add an optional descriptor closure such as `artifactRevision(anchorURL) -> SessionArtifactRevision?`. Existing file-backed sources default to `selectedURL == anchorURL`, a deterministic revision derived from the truthful physical stat, and the current `SessionFileStat`. DSH rescans the session directory, returns its highest selected generation, and hashes a canonical manifest of recognized sibling names plus their truthful physical stats.

Extend the search `FileRef` with the optional manifest revision. For a DSH ingest, resolve before parsing and require `selectedURL == FileRef.path`; resolve again after parsing and require the same selected URL and manifest revision. Either mismatch returns a distinct stale-anchor outcome before any database write. This avoids writing `session.filePath = g1` with g0's freshness values while preserving the existing two-phase provider/search design.

Add an optional archive-manifest closure to `ArchiveCapability`, such as `relativeEntries(archiveRoot, primaryRelativePath) -> [String]?`. Existing directory-backed sources retain the current all-regular-files default. DSH returns sorted canonical generation relative paths only. `SessionArchiveManager` validates containment and regular-file identity for each returned entry, then uses that same list for size, stable snapshot comparison, and copy. No later enumeration may widen the source-provided manifest.

### New production files

Create under `AgentSessions/DeepSeekHarness/`:

- `DeepSeekHarnessSettings.swift` — preference keys, resolved home/sessions root, and override validation.
- `DeepSeekHarnessSourceDescriptor.swift` — source metadata, root discovery, parse closures, directory-artifact revision, filtered archive manifest, explicit unavailable telemetry, and no-resume contract.
- `DeepSeekHarnessDiscovery.swift` — bounded real-directory walk, exact filename parsing, root-wide encoding consistency, highest-generation selection, canonical header-path validation, collisions, and directory-artifact revisions.
- `DeepSeekHarnessArtifactReader.swift` — bounded stable-snapshot reads, size-limited raw JSONL record reading, framed-reader orchestration, and post-parse selection recheck.
- `DeepSeekHarnessZstdFrameReader.swift` — frame enumeration, independent decompression, limits, and tail classification.
- `DeepSeekHarnessFormatTypes.swift` — physical header/envelope and normalized intermediate types.
- `DeepSeekHarnessHistoricalNormalizer.swift` — ordered v0→v1→v2→v3 transformations and strict validation.
- `DeepSeekHarnessSessionParser.swift` — normalized event dispositions, content mapping, titles, relationships, raw metadata, and lightweight/full parse modes.
- `DeepSeekHarnessSessionIndexer.swift` — transactional reconciliation, last-healthy preservation, focused-directory reload, and bounded issues.
- `DeepSeekHarnessPreferencesPane.swift` — enable toggle, resolved root, override field, availability/status, and compatibility copy.

If the Zstandard spike selects vendored upstream code, add its package below `ThirdParty/DSHZstd/` with license/notices and isolate it behind `DeepSeekHarnessZstdFrameReader`.

### New test files

Create under `AgentSessionsTests/DeepSeekHarness/`:

- `DeepSeekHarnessDiscoveryTests.swift`
- `DeepSeekHarnessZstdFrameReaderTests.swift`
- `DeepSeekHarnessHistoricalNormalizerTests.swift`
- `DeepSeekHarnessSessionParserTests.swift`
- `DeepSeekHarnessSessionIndexerTests.swift`
- `DeepSeekHarnessSourceDescriptorTests.swift`
- `DeepSeekHarnessFixtureParityTests.swift`

Add sanitized/generated fixtures under `AgentSessionsTests/Resources/Fixtures/stage0/agents/deepseek-harness/` with a manifest containing source commit, physical format, generation, encoding, expected outcome, generator command, and SHA-256. No fixture may come from `~/.dsh` or contain a real prompt, cwd, credential, username, host, or attachment.

### Existing files that need semantic edits

- `AgentSessions/Model/SessionSource.swift` — add `.deepseekHarness` with durable raw value `deepseek-harness`, display name `DeepSeek Harness`, short name `DSH`, badge `DS`, and `versionIntroduced: "5.5"`.
- `AgentSessions/Model/SessionSourceRegistry.swift` — register the descriptor in the intended source order.
- `AgentSessions/Model/SessionSourceDescriptor.swift` — required generic expansion for directory-artifact revision/selected-URL state and source-owned archive-entry filtering; keep the new seams optional for existing sources.
- `AgentSessions/Services/SessionDiscovery.swift` — keep physical `SessionFileStat` truthful; add a separate source-agnostic directory-artifact revision type only if it does not live beside the descriptor.
- `AgentSessions/Services/SessionArchiveManager.swift` — consume the descriptor's archive-entry filter for manifesting, size calculation, stability checks, and copying without changing existing sources' default all-regular-files behavior.
- `AgentSessions/Services/SessionProviderCatalog.swift` — build the DSH runtime and preserve explicit typed-indexer and file-backed identity capability semantics.
- `AgentSessions/Services/UnifiedSessionIndexer.swift` — add include/enablement state, tool-evidence filtering, concrete indexer reload, and focused reconciliation without weakening error retention for other sources.
- `AgentSessions/Utilities/CodexSessionImagePayload.swift`, `AgentSessions/Utilities/ImageBrowserIndexCache.swift`, and `AgentSessions/Views/TranscriptPlainView.swift` — add explicit DSH no-image handling for v1.
- `AgentSessions/Views/UnifiedSessionsView.swift` — make copy-resume, resume eligibility, launch, include binding, focused reload, and transcript-host handling exhaustive; all three resume paths return unsupported.
- `AgentSessions/Services/SubagentHierarchyBuilder.swift` — no DSH-specific inference; add regression coverage proving seeded forks stay roots while explicit DSH subagents nest.
- `AgentSessions/Model/Session.swift` — add explicit DSH housekeeping behavior and preserve authoritative lightweight cwd/title according to the source contract.
- `AgentSessions/Services/AgentUpdateService.swift` — return no update-feed profile for DSH unless a separately verified update contract is added.
- `AgentSessions/Views/PreferencesView.swift` and preference navigation/bindings — add the DSH pane and reload trigger.
- `AgentSessions/Views/Preferences/PreferencesView+General.swift` and a new `PreferencesView+DeepSeekHarness.swift` — add enablement binding and the source-specific pane.
- `AgentSessions/Onboarding/Views/FirstRunSetupView.swift` and `AgentSessions/Onboarding/Models/WhatsNewCatalog.swift` — add availability and release teaser only after the release version is resolved.
- `AgentSessions/Views/UnifiedSessionsView.swift`, row/badge helpers, source filters, source menus, and colors — add exhaustive DSH presentation using `#4D6BFE` through the adaptive-brand system. Treat it as a source accent, not a protocol fact or partnership claim.
- `AgentSessions/Analytics/Models/AnalyticsDateRange.swift` and `AgentSessions/Analytics/Views/AnalyticsView.swift` — add the dedicated DSH filter and enablement binding; expose only normalized generic analytics.
- `AgentSessions/Search/SearchIngestService.swift` and `AgentSessions/Search/SessionSearchTextBuilder.swift` — use the safe rendered-content policy, reject stale generation anchors without changing FTS, and preserve the existing internally transactional search phase rather than claiming cross-system atomicity.
- `AgentSessions.xcodeproj/project.pbxproj` — add every Swift/test/resource file and any local package product using the repository script where applicable.
- `docs/adding-a-session-source.md` — document directory-scoped generation artifacts, framed compression, and fail-closed incomplete tails if implementation adds reusable lessons.
- `README.md`, `docs/CHANGELOG.md`, and `docs/summaries/YYYY-MM.md` — add user-visible source support and the exact limitations under the resolved upcoming release, not 5.2.
- `scripts/agent_watch.py`, `docs/agent-support/agent-support-matrix.yml`, `docs/agent-support/public-agents.json`, and format-tracker fixtures — add DSH at pinned verified versions only after all compatibility gates pass.

Before editing, use the guide's switch inventory (`docs/adding-a-session-source.md:427-476`) and sentinel-test guidance (`docs/adding-a-session-source.md:504-533`) to generate an exact current checklist. In particular, update `SessionSourceRegistryTests`, `SessionProviderCatalogTests`, `TranscriptHostCoverageTests`, `SessionSourceKeyStabilityTests`, `AnalyticsIndexerTests`, `ViewRegistryDerivationTests`, `KimiIntegrationSurfaceTests`, `NewProviderDiscoverabilityTests`, and `WhatsNewCatalogTests`. The file names above are integration targets, not permission to blindly copy stale line numbers.

## Implementation sequence

### Task 0 — Resolve release and dependency blockers

- [ ] Owner selects the actual next unreleased Agent Sessions version.
- [ ] Vendor official Zstandard 1.5.7; document the source-archive SHA-256, BSD license/notices, exact decompression/common source list, arm64/x86_64 support, and update procedure.
- [ ] Route `#4D6BFE` through the adaptive-brand system and document that it is a source accent, not a protocol fact or endorsement claim.
- [ ] Decide whether sanitized real specimens can be provided. If not, record the evidence limitation in release notes and compatibility docs.
- [ ] Freeze both repository commits in the fixture manifest and plan execution checklist.

**Gate:** No `SessionSource` registration or decoder code lands until the release and dependency choices are recorded.

### Task 1 — Build the fixture and parity corpus

- [ ] Add a generator in the DSH reference checkout or a temporary ignored work area that uses the pinned codecs to produce synthetic v0-v3 records without private data.
- [ ] Produce plain and independently framed Zstandard variants.
- [ ] Produce canonical normalized-v3 JSON expected files.
- [ ] Add malformed fixtures by byte-level derivation with the derivation documented in the manifest.
- [ ] Verify every committed fixture hash and scan it for home paths, usernames, tokens, and realistic prompt text.

**Gate:** Fixture provenance and expected outcomes are reviewable without access to the sibling repository.

### Task 2 — Implement bounded framed input

- [ ] Add the pinned decoder and notices.
- [ ] Implement pre-stat/read/post-stat stable snapshots with one retry and a committed-prefix or retryable-failure result for a second overlapping append.
- [ ] Implement exact Zstandard frame scanning and independent decompression.
- [ ] Require the first decoded frame to contain exactly one newline-terminated header record.
- [ ] Add compressed/decompressed byte, expansion-ratio, frame-count, JSON-line, nesting, and event-count limits.
- [ ] Implement raw JSONL and framed-record readers with byte offsets.
- [ ] Classify torn-final-frame, torn-final-line, corrupt-frame, checksum, invalid UTF-8, and invalid JSON separately; for an incomplete Zstandard frame report only complete prior frames plus `tornStart`, not recovered records from inside the frame.
- [ ] Ensure logs contain only path-safe identifiers and offsets, never transcript content.

**Gate:** All decoder tests pass under Address Sanitizer or the closest available memory-safety configuration for the C boundary, and no external executable/library is required on a clean machine.

### Task 3 — Implement discovery and logical generation identity

- [ ] Resolve root precedence and root override.
- [ ] Skip all project/session directory symlinks and enforce containment for every opened file.
- [ ] Parse exact canonical generation names without imposing UUID syntax or decoding project keys.
- [ ] Detect project-level legacy flat artifacts and root-wide encoding mismatch, including mismatches across different session directories.
- [ ] Select the highest numeric generation.
- [ ] Require filename generation to equal header version and recompute the canonical path from root, header cwd/id, version, and encoding.
- [ ] Detect duplicate session ids across project directories.
- [ ] Add the directory-artifact revision seam; keep the selected file's physical `mtime`/`size` truthful and store manifest revision separately.
- [ ] Recheck selected generation after parse and discard/retry when a successor appeared during the read.
- [ ] Enforce bounded traversal and cancellation.

**Gate:** A newly added successor generation invalidates the existing row without touching the older file; malformed unrelated files do not widen the scan.

### Task 4 — Port validation and historical normalization

- [ ] Add physical header/envelope decoders for v0-v3.
- [ ] Port adjacent migrations in separate functions/modules.
- [ ] Port sequence, source-range, relationship, disposition, and payload validations used by the frozen catalog.
- [ ] Fold historical assistant chunks exactly once.
- [ ] Validate embedded v3 assistant streams without rendering deltas twice.
- [ ] Implement required-unknown refusal and ignorable-unknown skip.
- [ ] Compare normalized output byte-for-byte after canonical JSON ordering against expected fixture output.

**Gate:** Every accepted historical fixture produces the same semantic v3 object as the pinned DSH implementation; every intentionally unsupported required extension fails explicitly.

### Task 5 — Map normalized sessions

- [ ] Implement title, project, timestamp, model, token, event, and content mappings.
- [ ] Implement explicit event dispositions.
- [ ] Add attachment placeholders and redaction/size limits.
- [ ] Map explicit subagents and keep seeded forks as roots.
- [ ] Add display-only interrupted-turn closure for fully decoded semantic interruptions.
- [ ] Implement lightweight and full parse modes from the same normalizer.
- [ ] Preserve safe bounded raw metadata for diagnostics.
- [ ] Keep every `assistant/attempt` stream diagnostic-only and excluded from transcript, title, FTS, counts, tokens, and surface projection.
- [ ] Deduplicate assistant `tool-call` blocks and `tool/call` events by call id into one rendered/countable tool invocation.

**Gate:** No event is silently dropped unless its disposition is documented and tested; packed/embedded assistant content appears once.

### Task 6 — Integrate transactional indexing and the descriptor

- [ ] Add the source descriptor with no resume/live/attachment capabilities and explicit `.allUnavailable("DeepSeek Harness telemetry not yet audited")` telemetry.
- [ ] Implement initial scan, focused reload, and periodic complete reconciliation.
- [ ] Preserve last healthy projection on a failed refresh.
- [ ] Preserve the current two-phase row-then-search architecture; make stale anchors leave old FTS untouched and retry from the refreshed selected URL.
- [ ] Add the generic archive-entry filter seam and implement filtered canonical-generation snapshots with the existing stable snapshot/retry behavior.
- [ ] Add availability/status reporting for absent roots, invalid roots, unsupported versions, and decode failures.

**Gate:** A failed new generation cannot erase or partially replace the previous healthy Agent Sessions copy, and no DSH-owned byte changes during the suite.

### Task 7 — Complete product surfaces and switch exhaustiveness

- [ ] Add `SessionSource`, registry, filters, menu, icon/badge/color, preferences, onboarding, analytics, search, housekeeping, image, update-profile, and resume switch arms.
- [ ] Add the sessions-root override UI with resolved-path explanation.
- [ ] Ensure source toggling cancels work and clears/rebuilds only DSH projections as current source semantics require.
- [ ] Add accessibility labels and VoiceOver-readable failure/status text.
- [ ] Add release copy under the unreleased 5.5 section.

**Gate:** Sentinel tests prove no source switch or user-facing picker omits DSH, while resume/live controls stay absent.

### Task 8 — Documentation, monitoring, and release evidence

- [ ] Update `README.md`, the changelog, monthly summary, source guide, support matrix, public-agents data, compatibility statement, and known limitations.
- [ ] Add DSH to format monitoring with the exact verified DSH tag/commit and fixture hashes.
- [ ] Record sanitized test logs, full suite totals, build result, and manual QA matrix.
- [ ] Record unresolved real-corpus coverage as a release limitation or block release until sanitized specimens pass.

**Gate:** The release note says exactly what was proven and does not imply resume, live, attachment, archive-state, or arbitrary-plugin support.

## Required fixture matrix

| Fixture | Encoding/generation | Expected result |
|---|---|---|
| Minimal v0 session | plain g0 | Normalize v0→v1→v2→v3; render one user and one assistant message. |
| Minimal v1 session | plain g0 | Normalize v1→v2→v3. |
| Minimal v2 session | plain g0 | Normalize v2→v3. |
| Minimal v3 session | plain g0 | Decode directly. |
| V3 concatenated frames | zstd g0 | Enumerate/decode every frame; match plain semantic output. |
| Canonical compressed filenames | zstd g0/g1 | Accept `session.jsonl.zstd` and `session.v1.jsonl.zstd`; reject `.zst`, `session.v0`, leading-zero, uppercase, and temporary variants. |
| Exact first header frame | zstd g0 | Accept one newline-terminated header record; reject empty, unterminated, and header-plus-event first frames. |
| Multiple generations | plain g0/g2/g10 | Select g10 numerically; logical identity remains unchanged. |
| Successor appears during focused reload | plain g0 then g1 | Logical stat changes and full parse reselects g1. |
| Successor appears after search `FileRef` creation | plain g0 then g1 | g0 ingest returns stale anchor without FTS mutation; refreshed g1 row creates a new `FileRef` and succeeds. |
| Successor appears during parse | both | Post-parse selection check discards the stale result and schedules retry. |
| Plain append during read | plain | Stable-read retry or committed-prefix policy avoids a false torn/corrupt verdict. |
| Zstandard-frame append during read | zstd | Stable-read retry or committed-prefix policy avoids decoding a half-observed append. |
| Same-session plain/Zstandard mismatch | mixed | Root refresh fails; previous healthy snapshot remains. |
| Cross-session root encoding mismatch | mixed in separate session directories | Root refresh fails; root encoding is not inferred per session. |
| Legacy project-level flat artifact | plain and zstd | `<root>/<project>/<encoded-id>.jsonl[.zstd]` produces a root compatibility issue and is never ingested as current layout. |
| No-cwd session | plain | Session is listed with nil project path and no resume action. |
| Opaque non-UUID session id | both | Encode and validate successfully; no UUID gate exists. |
| Lossy project-key collision candidate | both | Header cwd and canonical recomputation determine identity; project key is never decoded for display. |
| Filename/header version mismatch | both | Reject before migration. |
| Canonical path mismatch for header cwd/id | both | Reject unless the selected path is the same physical file as the recomputed canonical path. |
| Explicit subagent | both | Nest beneath parent; preserve depth/preset. |
| Seeded fork with parent | both | Keep as root; preserve fork metadata; do not label subagent. |
| Packed v0 assistant chunks | both | Fold and render final assistant content once. |
| V0 steering/retry/compaction/message normalization | both | Match pinned DSH canonical v3 output, including generated identities and renamed event shapes. |
| V1 packed-run collapse with all reference families | both | Renumber and remap `sourceEventSeqs`, replacement ranges, command source seq, compaction shadow ranges/seqs, and title message seqs exactly. |
| V1 reference into consumed chunk | both | Reject at the adjacent migration with the pinned DSH failure class. |
| V2 initial and changed system-prompt promotion | both | Insert/replace protected system heads and remap every downstream reference exactly. |
| V2 code-mode/PTC renames | both | Match `code`→`ptc`, dispatch-event, and `tools-code-mode`→`tools-ptc` canonical output. |
| Embedded v3 assistant stream | both | Validate provenance; render final message once, no delta duplicates. |
| Failed `assistant/attempt` followed by successful message | both | Attempt stream remains diagnostic-only; only the successful assistant message is visible, searchable, and countable. |
| Surface replacement and source ranges | both | Validate ranges and preserve replacement metadata. |
| Tool call represented in message block and log event | both | Produce exactly one tool invocation keyed by call id and one paired result; retain both provenance sources without duplicate counts. |
| Unmatched tool records | both | Preserve unmatched call/result evidence explicitly without inventing a pair. |
| Attachment references | both | Show metadata placeholder; no filesystem/network access. |
| Unknown ignorable event | both | Skip rendering and record diagnostic disposition. |
| Unknown required event | both | Reject session and retain last healthy indexed copy. |
| Future v4 header | both | Reject with supported-version message. |
| Invalid header/path id mismatch | both | Reject before content mapping. |
| Historical migration payload/disposition failure | both | Reject at the exact adjacent migration stage; do not attempt a later-version parser. |
| Sequence gap/duplicate/reversal | both | Reject with seq evidence. |
| Truncated raw final line | plain | Classify recoverable prefix but do not publish in v1. |
| Truncated final Zstandard frame | zstd | Report complete-prior-frame boundary plus `tornStart`; do not claim records from inside the incomplete frame and do not publish. |
| Complete frame with torn JSONL record | zstd | Classify corruption and reject. |
| Corruption in a nonfinal frame | zstd | Reject; never continue after it. |
| Fully decoded interrupted turn | both | Publish complete persisted events plus display-only interruption closure. |
| Duplicate id under two projects | both | Publish neither ambiguous copy and surface one bounded issue. |
| In-root and escaping project/session symlinks | either | Skip both; discovery follows real directory entries only. |
| Decompression bomb limits | zstd | Abort at configured limit with stable error and bounded memory. |
| DSH archived id present in default workspace state | either | Session remains visible; v1 ignores upstream archive state. |
| Filtered directory archive snapshot | multi-generation plus unknown/symlink entries | Copy only canonical generation siblings, exclude unknown/nonregular/symlink entries, and reopen the highest archived generation. |

Every accepted semantic fixture needs lightweight-parse, full-parse, FTS, archive-round-trip where applicable, and deterministic-repeat coverage.

## Validation and acceptance gates

### Automated tests

- Unit-test every fixture and boundary above.
- Add descriptor contract tests for raw value, display names, default enablement, capability flags, root precedence, and resolved release version.
- Add registry/sentinel tests following `docs/adding-a-session-source.md:504-533`.
- Add hierarchy regressions proving explicit subagents nest and forks do not.
- Add transactional-index tests proving failed refresh preserves the prior row and search document.
- Add the stale-anchor race test proving a successor published after `FileRef` creation cannot write the new path with the old generation's freshness token.
- Add stable-read race tests for overlapping plain appends, Zstandard frame appends, and successor publication during parse.
- Add descriptor tests asserting the explicit unavailable telemetry verdict and the filtered archive capability.
- Add a read-only invariant test: hash fixture/source tree before and after index/archive-read operations, excluding the Agent Sessions archive destination, and require identical DSH source hashes.
- Add deterministic normalization tests across repeated runs.
- Add concurrency/cancellation tests for source disable and root changes.
- Add decoder fuzz or property tests for frame-boundary/truncation classifications.

Run the canonical suite with:

```bash
./scripts/xcode_test_stable.sh
xcrun xcresulttool get test-results summary --path .deriveddata-tests/Logs/Test/Run-*.xcresult
```

Record the total from the result bundle. If the count drops, explain it and diff relevant test-name inventories as required by `AGENTS.md`.

### Build

This work adds many Swift files, resources, a dependency boundary, and cross-cutting source switches, so a clean Debug build is mandatory:

```bash
xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Debug build
```

If the implementation uses a local package, first verify dependency resolution and that a clean machine does not need Homebrew Zstandard.

For target membership, run `scripts/xcode_add_file.rb` once per new production and test Swift file with all four arguments, then verify each run adds exactly four project-file lines as documented at `docs/adding-a-session-source.md:545-564`. Confirm the fixture resources and local package product appear in the intended build phases. Run `xcodebuild -resolvePackageDependencies` before the clean build if a package is added; any missing package product is a project-file failure, not a parser failure.

### Manual QA

Use only generated/sanitized roots:

1. Launch with no DSH root and verify clear unavailable status with no errors elsewhere.
2. Enable DSH with plain fixtures; verify list, source filter, transcript, search, analytics, hierarchy, and accessibility labels.
3. Repeat with Zstandard fixtures on a machine where the `zstd` executable is absent from `PATH`.
4. Add a successor generation while the app is open; verify periodic/focused reload selects it and the row identity stays stable.
5. Introduce a broken successor; verify the last healthy transcript remains and the issue is visible.
6. Verify no Resume or Copy Resume Command action appears anywhere.
7. Archive a multi-generation session through Agent Sessions and reopen the snapshot.
8. Verify an attachment fixture produces a placeholder and no filesystem/network access.
9. Verify DSH workspace archive state does not hide sessions.
10. Compare representative normalized transcript output with the canonical expected v3 JSON.

### Release acceptance

Ship only when all are true:

- The actual `versionIntroduced` is resolved and is not a shipped version.
- The Zstandard dependency review, licenses, clean-machine build, and architecture tests pass.
- The full fixture matrix passes for plain and compressed cases.
- Required first-party event vocabulary coverage is enumerated; unsupported required extensions fail closed.
- No test-count decrease is unexplained.
- Build and full stable test suite pass.
- Manual QA passes with sanitized fixtures.
- Documentation states the exact v1 exclusions.
- README, support matrix, public-agents data, changelog, and monthly summary state the same capability boundary.
- The descriptor reports DSH telemetry unavailable; ordinary rendered model/usage fields are not advertised as audited telemetry.
- Archive snapshots contain only canonical generation files selected by the audited filter.
- No source file, generation, workspace state, or attachment store is modified.
- Real-corpus validation is either completed with sanitized specimens or explicitly recorded as an evidence limitation accepted by the owner.

## Risks and controls

| Risk | Consequence | Control |
|---|---|---|
| Zstandard C boundary or decompression bomb | Crash or excessive resource use | Pinned code, narrow wrapper, byte/frame/ratio limits, sanitizer/fuzz tests, no subprocess. |
| Format drift or plugin augmentation | Incorrect transcript | Pinned catalog, explicit dispositions, unknown-required refusal, monitoring before max-version bump. |
| New generation arrives without old-file mtime changing | Stale display | Directory-artifact revision and parent rescan on every parse. |
| Successor appears after search anchor creation | New path stored with old freshness token | Separate selected URL/manifest revision from physical stat; stale-anchor ingest makes no FTS change and retries from the refreshed row. |
| Append overlaps periodic read | Healthy active session misclassified as torn/corrupt | Port bounded pre/read/post stable snapshot semantics and recheck selection before publish. |
| Opaque id or lossy project key is guessed from directory text | Valid sessions omitted or wrong paths trusted | Treat directories as candidates and validate the exact header-derived canonical path; no UUID gate or project-key decoding. |
| Partial/corrupt tail looks complete | Misleading history | V1 rejects all physical tail recovery and preserves last healthy projection. |
| Fork mistaken for subagent | False hierarchy | Require explicit subagent origin; keep seeded forks as roots. |
| Injected context becomes title/search content | Privacy and relevance error | Direct-human source filter for titles; exclude request context from FTS. |
| Attachment reference escapes root | Private-file access | Metadata placeholder only; never resolve or open attachments. |
| Future unknown file appears in a session directory | Archive captures unaudited/private content | Required archive-entry filter admits canonical regular generation siblings only. |
| Tool call exists in message content and durable event | Duplicate transcript row/count | Deduplicate by call id; message block owns request provenance and log event owns recorded-start metadata. |
| DSH archive-state path differs by profile | Incorrect visibility | Ignore upstream archive state in v1. |
| Resume command targets wrong surface/profile | Failed or destructive workflow | No resume capability in v1. |
| Cross-root duplicate session id | Row collision | Detect ambiguity and publish neither copy. |
| Stale 5.2 instruction | False release history | Pinned 5.5 introduction metadata and regression test. |
| Synthetic corpus misses real-world data | Compatibility overclaim | Narrow wording, sanitized specimen gate/waiver, tracked evidence gap. |

## Resolved owner decisions and remaining evidence gates

The owner selected **1A through 9A** on 2026-09-18:

1. Ship DSH in Agent Sessions 5.5.
2. Vendor official Zstandard 1.5.7 decompression/common C sources, pinned by archive SHA-256 under the BSD license, and support arm64 and x86_64 through a narrow local wrapper.
3. Claim broad v0-v3 support only when the generated first-party catalog gives every event an explicit tested Swift disposition. Automatically narrow to core events if any first-party extension remains unsupported.
4. Accept a small opt-in sanitized specimen set plus a shape/type inventory. This is not authorization to inspect `~/.dsh`; specimens must be separately supplied or exported through an approved local sanitizer.
5. Keep recovered prefixes invisible and reject incomplete artifacts in v1.
6. Ignore upstream DSH archive state and show every otherwise-valid session.
7. Expose no DSH resume capability in v1.
8. Preserve fork provenance as metadata, keep forks as roots, and do not overload `parentSessionID`.
9. Use `#4D6BFE` through Agent Sessions' adaptive-brand system as a source accent, without implying endorsement or partnership.

The remaining gates are evidence and verification work, not product decisions: complete catalog/disposition parity, verify the pinned Zstandard archive/checksum/license/source list and both architectures, and validate any separately supplied sanitized specimens before making a real-corpus compatibility claim.

## Definition of done

The work is done when a clean Agent Sessions install can index sanitized plain and compressed DSH v0-v3 fixtures from the supported directory layout, show accurate complete history and explicit subagent relationships, search the safe rendered content, survive concurrent appends, successor generations, stale search anchors, and failed refreshes without losing the last healthy projection, archive only an audited filtered generation manifest, and do all of that without writing to DSH storage or implying unsupported resume/live/archive-state/attachment behavior.

Anything weaker must ship with a narrower compatibility statement or remain unreleased.
