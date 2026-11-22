# Search and responsiveness refactor specification

Date: 2026-11-10. Status: ready for implementation planning use after Sol Max review;
implementation has not started. The implementation plan records review evidence and limits.

Companions: [implementation plan](../plans/2026-11-10-search-responsiveness-refactor.md),
[profiling specification](2026-11-10-search-responsiveness-profiling.md).

## 1. Scope and evidence boundary

The requested deliverable is a code-grounded specification and plan for list search,
the Claude cloud Keychain stall, and slow opening of a roughly 8,000-message session.
This planning pass does not authorize implementation or live profiling. No product
code, tests, runtime data, credentials, or user settings are changed by this packet.
No new feature flags, branches, worktrees, commits, or publication are part of it.

Evidence was read from current `main`, HEAD `042d2aef`, including existing uncommitted
changes. Line anchors describe that checkout and must be refreshed before implementation.
Historical runtime observations are in the two reports below; they were not reproduced.
The large-session root cause remains unknown. This specification makes no speedup claim.

| ID | Verified code or retained evidence | Consequence |
|---|---|---|
| E1 | `AgentSessions/ClaudeCloud/ClaudeCloudSessionCatalog.swift:97,115-149`; `AgentSessions/ClaudeStatus/ClaudeOAuth/ClaudeManualWebCookie.swift:84-114` | Main-actor catalog synchronously reaches Security; enabled state is not checked after network suspension. |
| E2 | `AgentSessions/Views/Preferences/PreferencesView+Usage.swift:714-746`; `AgentSessions/ClaudeCloud/ClaudeCloudLiveModel.swift:131-141` | UI reads/writes credentials synchronously; Save/Remove does not invalidate an in-flight catalog request. |
| E3 | `AgentSessions/ClaudeCloud/ClaudeCloudAPIClient.swift:86`; `AgentSessions/ClaudeStatus/ClaudeOAuth/ClaudeWebUsageClient.swift:68-74,114` | Organization/usage caches are not bound to a credential revision. |
| E3a | `AgentSessions/ClaudeStatus/ClaudeOAuth/ClaudeUsageSourceManager.swift:412-420,1360-1364,1590-1600`; `AgentSessions/ClaudeStatus/ClaudeOAuth/ClaudeUsageSnapshotStore.swift:26-43` | Persisted and in-memory usage snapshots can be restored or merged after client cache invalidation. |
| E4 | `AgentSessions/Services/ClaudeSessionParser.swift:652-656,1334`; `AgentSessions/Services/ToolTextBlockNormalizer.swift:238-251`; `AgentSessions/Search/SessionSearchTextBuilder.swift:273,374` | Sanitized raw JSON can displace real output; runtime tool errors can reside in `text`. |
| E5 | `AgentSessions/Search/SearchCoordinator.swift:505,619-624,938-963`; `AgentSessions/Services/FilterEngine.swift:634-675` | Return coverage depends on extra preference and command estimates; exact field matching differs from concatenated FTS. |
| E6 | `AgentSessions/Search/SearchSessionStore.swift:50-56`; `AgentSessions/Search/SearchCoordinator.swift:1217-1247`; `AgentSessions/Utilities/JSONLReader.swift:116-163` | Nonempty hydration is reused, hit results retain parsed sessions, and the reader can omit data without a typed coverage result. |
| E7 | `AgentSessions/Search/SearchIngestService.swift:324-342,430,511-519,668-678`; `AgentSessions/Support/FeatureFlags.swift:51-67` | Required format rebuilds can be deferred by cooldown then hidden by the aggregate shortcut. |
| E8 | `AgentSessions/Search/SearchCoordinator.swift:459,1069`; `AgentSessions/Model/Session.swift:931-970`; `AgentSessions/Services/SessionIndexer.swift:3058`; `AgentSessions/Indexing/SessionMetaRepository.swift:60` | Identity matching needs a coordinator path; lightweight provider-ID hints already exist and should be reused. |
| E9 | `AgentSessions/Services/TranscriptDerivedState.swift:32-41,169-199,400-406,528-560` | Snapshot work is already off main, grouping is main-actor cached work, and the key is not a full content revision. |
| E10 | `AgentSessions/Views/TranscriptPlainView.swift:1414-1425`; `AgentSessions/Views/TranscriptTelemetryView.swift:606-617`; `AgentSessions/Views/TranscriptBlockListView.swift:388,1460,1595` | Marker computation repeats whole-block work; missing supplied groups invoke a synchronous fallback. |
| E11 | `AgentSessions/Services/SessionIndexer.swift:519,582-605`; `AgentSessions/Support/FeatureFlags.swift:92-133`; `AgentSessions/Views/TranscriptBlockListView.swift:351` | Tail-first hydration and windowing exist; previous-session rows may remain until a valid new snapshot lands. |
| E12 | `AgentSessionsTests/TranscriptToolCorpusCheckTests.swift:1792-1843` | Existing open benchmark excludes parse and bypasses production asynchronous ownership. |

Historical context: [tool-output diagnosis](../../reviews/2026-11-10-tool-output-search.md),
[live review](../../reviews/2026-11-10-syntax-highlighting-live-review.md), and
[backlog](../../backlog.md#transcript-ui). Counts and timings there are historical,
not current measurements or implementation acceptance evidence.

## 2. Product contract

These are proposed behavior requirements, not descriptions of current behavior.

1. UI work never synchronously waits for the app's Claude manual-cookie Security calls.
2. Save, Remove, disabling, and session switches cannot publish results from obsolete work.
3. Pasting a full known session ID finds eligible sessions without loading their transcripts.
4. Typing provides sampled Instant results. Return validates session text and reports actual
   coverage; it never labels skipped/unreadable data as a completed negative search.
5. Search does not retain a parsed library or concatenate entire sessions to evaluate a query.
6. Transcript toolbar and table consume one consistent presentation revision. Repeated UI
   updates with unchanged inputs do not recompute markers, groups, or role counts.

Keep existing source/date/repository/path/project/archive/side-chat eligibility filters.
Identity matching never bypasses these filters or enabled-provider selection. In-session
Find remains a separate navigation operation; this work does not change its highlight grammar.

## 3. Credential boundary

### 3.1 Ownership and API

Introduce an app-owned asynchronous credential service around the existing manual-cookie
store. Its serialized state owns a monotonic in-process `CredentialEpoch`, pending reads,
and mutation ordering. A dedicated serial Dispatch queue performs blocking Security calls;
an actor merely wrapping a synchronous Security call is not sufficient isolation from a
cooperative executor. Resume async callers by continuation; never wait on a semaphore on main.

Operations return typed outcomes: present credential, absent, storage error, superseded,
or cancelled waiter. Never conflate a Keychain error with deletion. Key material remains
memory/Keychain-only and never enters telemetry, logs, filenames, or persistent cache keys.
No long-lived plaintext credential cache is required; coalesce only overlapping reads in
the same epoch. Clear retained material when a flight finishes or is invalidated.

All manual-cookie callers migrate: catalog, web usage manager, Preferences presence check,
Save/Remove, and the user-triggered test. The change does not move OAuth/tmux or Safari
authentication into this service. Preserve those source policies; legacy-cookie usage must
also use a separate account cache namespace when it reaches the web client.

### 3.2 Mutation and publication rules

Accepting Save/Remove immediately advances the epoch and invalidates old results. Serialize
the physical mutation after any uninterruptible Security operation already in flight.
Reads queued after the mutation cannot join an earlier read. Reject invalid pasted input
before accepting a mutation. On a storage failure, report failure, keep the new epoch, and
read actual storage again; do not claim that Save/Remove succeeded or resurrect old responses.

Every consumer captures `(credentialEpoch, enablementGeneration, requestGeneration)`.
Validate all three before starting a network request and before applying success, error,
or cache writes after every suspension. Disable advances enablement generation immediately,
clears feature rows, and suppresses pending fetch/publication. A later re-enable starts new
work even if the old request is finishing. An obsolete completion cannot clear a newer
request's in-flight flag. Mutation notification must schedule a current refresh after the
physical write completes, not be lost to the existing `inFlight` guard (E2).

Only one physical Security operation runs at a time. A cancelled waiter may finish promptly,
but cancellation/timeout does not pretend to stop `SecItemCopyMatching`. No retry fan-out.
Preferences shows pending/error state without blocking the window or allowing unbounded
queued writes; disable conflicting Save/Remove controls until the current mutation finishes.

### 3.3 Account caches

Cloud and web-usage clients tag organization and response state with the credential epoch.
Invalidation applies to both cached values and in-flight cache writes, including failures.
Replace the unowned shared web-usage response-cache path for the app's manual-cookie flow
with process-local epoch-keyed response caching at the existing TTL. Do not delete or
rewrite an external statusline cache. A process restart starts empty; it cannot trust an
old response without validated account ownership. The legacy-cookie path uses its own
source/credential epoch and must not import unowned responses either (E3).

Ownership extends through `ClaudeLimitSnapshot`, `ClaudeUsageSnapshotStore`, the usage
manager's `lastOAuthSnapshot`, published UI state, and missing-five-hour-window merging
(E3a). Tag web snapshots with a process-instance ID plus credential epoch; persisted web
snapshots are not eligible for restore after restart. On mutation clear web-derived displayed
and remembered snapshots, and reject old asynchronous store saves as well as client writes.
Only merge windows with identical validated ownership. No web-to-OAuth/tmux merge is allowed
without independently established same-account identity; source priority and acquisition
policies stay unchanged. A source label alone is not ownership evidence.

Legacy mixed usage snapshots without ownership are ineligible for restore/merge until fresh
owned evidence replaces them; do not delete their files as migration. OAuth's existing
token-scoped client cache remains separate; restored OAuth/model snapshots must carry its
validated ownership before use. Tmux snapshots with unknown account ownership remain
source-local and cannot supply windows to web snapshots. A missing window stays unavailable
when ownership cannot be established; do not fill it with a previous account's data.

### 3.4 Credential acceptance

K1: delayed read permits main-actor work; main never enters Security.
K2: Save B/Remove during read A or network A rejects every A completion/cache write.
K3: disable during either wait prevents fetch or publication; disable/re-enable cannot
revive old work. K4: storage errors remain errors; failed mutations trigger a fresh read.
K5: simultaneous catalog/usage/Preferences reads coalesce within an epoch, not across one.
K6: org and usage data from A cannot be served for B, including after app restart, persisted
snapshot restoration, transient fallback, missing-window merging, and delayed store saves.

## 4. Search text and query contract

### 4.1 Semantic fields, independent of display

Introduce `SearchTextSegment` with source identity, event identity, field kind, text,
and typed extraction/omission provenance. Supported field kinds are title, repository,
user/assistant/message text, tool name, input, output, and tool error. Retain existing
intentional exclusions such as DeepSeek injected user metadata (builder E4), documenting
them in the adapter contract. No blanket raw-JSON dump becomes searchable.

One source-aware extractor feeds sampled indexing and exhaustive matching. Factor reusable
semantic extraction from provider readers; do not maintain a second divergent parser of
tool content. For Claude, prefer preserved event output/error text to sanitized raw JSON;
structured data decoding must preserve content order, stdout/stderr, and runtime errors.
Do not discard legitimate source text merely because it resembles `[OMITTED ...]`.
Internal omission provenance comes from reader/parser status, never string recognition alone.
Keep ToolTextBlockNormalizer's display behavior separate from this contract (E4).

### 4.2 Query semantics

Use one quote-aware lexer for metadata and content, replacing the existing metadata parser's
unconditional `repo:`/`path:` recognition where necessary (`FilterEngine.swift:713-715`).
Whole-quoted metadata-looking text is literal content. `path:"foo bar"` is a metadata operator
with a quoted value; `"path:foo"` is a phrase. Dangling/empty metadata values are errors.
Preserve explicit UI-filter precedence over query metadata and the last-value-wins rule for
repeated repo/path operators; unquoted `#side` sets the side-chat filter. Compile the remaining
text once into a typed `SearchQuery`. Specify this grammar for list search:

- Unquoted whitespace-separated terms are ANDed across fields/events of one session.
- Quoted phrases are contiguous tokens within one semantic field. They cannot cross
  event/field boundaries or omitted regions. A streaming chunk boundary is not a field boundary.
- Explicit case-insensitive AND, OR, NOT are supported; NOT binds to the following term or
  phrase, AND binds more tightly than OR. Binary `a NOT b` means `a AND NOT b`.
- Explicit trailing `*` means a prefix on the last token of the preceding atom/phrase.
  An unquoted punctuation-bearing atom tokenizes as one contiguous token phrase; whitespace
  separates atoms with AND. Automatic prefix applies only to that atom's final token when
  it has at least three Unicode scalars and the query has no explicit Boolean operator.
  Quoted atoms and terms in explicit Boolean expressions have no automatic prefix. Prefix
  matching never changes the preceding tokens of a multi-token atom into prefixes.
- Parentheses, NEAR, column selectors, misplaced operators, and unclosed quotes produce an
  actionable unsupported/invalid-query result. They are not silently reinterpreted as a hit
  or empty result. Literal operator words remain searchable when quoted.
- Case/diacritic/token boundaries are SQLite FTS5 `unicode61` with its default options,
  matching current DB configuration (`Indexing/DB.swift:448-453,494-499`). One adapter exposes
  those semantics to indexing and exhaustive matching; do not substitute Swift lowercase/
  CharacterSet rules. Prefer the SQLite tokenizer API; if unavailable on a supported build,
  require a verified equivalent before completing this phase, not a silent alternate matcher.
  Conformance fixtures cover decomposed accents, non-ASCII case, underscores and punctuation.
  No path may silently substitute substring matching. Query size is capped at 8 KiB UTF-8
  and 128 term/phrase nodes; excess is an explicit validation error.

An atom that yields no tokens is invalid; an all-metadata query remains a metadata filter.
Examples (`prefix(x)` means prefix matching of one canonical token):

| Input | Expected content predicate / metadata |
|---|---|
| `alpha beta` | `prefix(alpha) AND prefix(beta)`, possibly in different fields |
| `alpha AND beta` | exact token `alpha AND beta`, possibly in different fields |
| `foo_bar` or `foo-bar` | field-local phrase `[foo, prefix(bar)]` |
| `"foo bar"` | field-local exact phrase `[foo, bar]` |
| `"foo bar"*` | field-local phrase `[foo, prefix(bar)]` |
| `alpha NOT beta` | exact alpha and no exact beta in the covered session |
| `"path:needle"` | field-local phrase `[path, needle]`; no path filter |
| `path:"my repo" alpha` | path filter `my repo`; content `prefix(alpha)` |
| `path:` or `***` | validation error; not a completed empty search |

This deliberately resolves the current implicit-phrase versus FTS-AND discrepancy (E5/E6).
Add user-facing help and release notes for that behavior change. In-session Find is unchanged.
Compile FTS candidates from the same AST. For unsupported FTS translation or negative-only
expressions, Instant reports that Return is required; do not invent an empty definitive result.
FTS remains a candidate mechanism: index sampling cannot prove absence or a NOT predicate.

### 4.3 Identity lookup

Normalize exact complete IDs by trimming whitespace and normalizing UUID case. Match app ID
and provider-owned ID aliases; never a parent ID. Use source-qualified `SessionKey` for
dedupe; return every eligible collision. Match before FTS LIMIT in both indexed and legacy
coordinator routes, and in the fallback matcher. No prefix-ID expansion is required.

The identity shortcut applies only when the entire remaining free-text query is one complete
ID (optionally quoted), with no Boolean/content expression. A known alias selects an explicit
metadata-lookup mode: Return validates metadata eligibility and does not scan unrelated session
content. Unknown IDs can fall through to ordinary content search. `ID NOT beta` is not this
shortcut and must not bypass query validation or content coverage rules.

Reuse persisted hints and provider metadata already carried by discovery/hydration (E8).
For Codex use own internal hint, then validated rollout filename UUID; for Claude use its
provider hint or validated session filename. Other adapters expose authoritative IDs only.
Do not invoke the event-scanning `codexInternalSessionID` getter while typing. Missing alias
metadata can be backfilled through existing hydration; do not parse on the search keystroke.

## 5. Exhaustive search execution

### 5.1 Request and coverage types

A `SearchRequest` captures run ID, query AST, eligible session identities, and filter snapshot.
The eligible set is fixed at request start; later discoveries belong to the next request.
Each adapter captures its source revision when scanned; this is not a cross-library atomic
snapshot. Report this contract in help rather than claiming a single global instant.

`SearchScanResult` contains a lightweight hit reference, source revision, outcome
(`match`, `noMatch`, `unknown`), coverage, and byte/record counters. Coverage reasons include
complete, sourceChanged, unavailable, unsupportedFormat, malformedRecord, omittedRecord,
resourceLimit, cancelled. Multiple reasons may coexist. Do not return parsed `Session.events`.

Use three-valued evaluation over segment evidence. Positive terms can be witnessed in an
incomplete scan, but absent terms and negative predicates cannot be proved from missing data.
A session is verified only when the query truth is established and its revision is stable;
the library is fully searched only when every eligible session has complete coverage.
Do not hide the incomplete-coverage count just because a positive hit was established.

Return revalidates sampled hits as well as scanning misses. Instant rows remain visibly
provisional until resolved; a contradicted NOT hit is removed. Known exact identity matches
are metadata results and remain valid within eligibility; they need no content parse solely
to prove the identity. Content-search coverage accounting stays separate from this shortcut.
Zero verified hits plus unresolved sessions must say incomplete, not “no matches.”

Instant uses eligible lightweight metadata/identities and available sampled indexes only.
It never inherits the current no-FTS, unindexed or stale-row full-parse fallback (E5/E6).
If DB/index data is unavailable or stale, show metadata results plus an incomplete/indexing
state and offer Return. No transcript file read, full parser, or exhaustive scan is started
by typing; this applies during cold index warmup and query replacement as well.

### 5.2 Source revisions and adapter obligations

Reuse existing source revision helpers where sufficient; extend them rather than creating
unrelated notions of currency. File identity includes canonical path, device/inode, size,
nanosecond mtime/ctime, and parser format revision. Stat the opened descriptor before/after
the exact read; confirm path still names that descriptor. Detect replace/append/truncate and
retry once, then report sourceChanged. Metadata-preserving hostile rewrites are outside this
local-history contract; equal size alone never proves freshness.

DB sources use a consistent read transaction and provider session revision/identity, not
the global database file's mtime. Companion-file sources capture/check every participating
file. Compressed sources account for physical and decompressed bytes separately.
Cached hydration is reusable only with full-hydration status, a matching revision, and typed
coverage provenance; old nonempty events without that evidence must be rescanned (E6).

Every registry source must declare a scanner and coverage behavior. Codex/Claude JSONL and
database-backed sources need streaming/paged semantic readers for large records/libraries.
Other adapters may reuse a bounded event parser while being upgraded, but must report a
resource limit if its input cannot be safely bounded. No silent unsupported default.
Registry conformance tests enumerate `SessionSource.allCases`, not a hand-maintained count.
An adapter may report unsupported historical format; a normal current fixture for each
registered provider must produce complete coverage before the search refactor ships.

### 5.3 Resource bounds and cancellation

Initial implementation constants, to be tested rather than treated as measurements:

- One active exhaustive session scan per request, one exhaustive request process-wide;
  cancelling/replacing waits for the old worker to release before starting another.
- One additional process-wide background ingestion/migration scan permit, shared across
  sources and actor reentrancy. A common admission owner holds permits through read, decode,
  extraction and cleanup; suspension does not release them. Thus at most two source scans
  and 128 MiB scanner-owned retained payload are live across these search operations.
  Return has its reserved permit; background kicks coalesce per source rather than fan out.
  Cancellation retains a permit until the physical worker exits, including blocked I/O.
- 64 KiB read chunks, 8 MiB decoded record limit, 64 MiB scanner-owned retained payload
  budget. Oversized/unsafe shapes report resourceLimit or omittedRecord; no unbounded parse.
  For whole-file adapters, limit input to 8 MiB and validate decompression/nesting bounds
  before constructing the full object. Larger supported sessions use streaming readers.
  A whole-object decoder that cannot bound expansion/container allocation must be replaced
  with incremental decoding for that adapter; an input-size check alone is not a memory bound.
  The bounded fallback rejects nesting deeper than 64 and more than 65,536 decoded nodes per
  record before creating the object tree. Charge string expansion and container capacity to
  the payload budget before allocation. If an existing decoder cannot meet those conditions,
  use a streaming decoder; catching an allocation failure afterward is not an implementation.
- Reader, decoder, and matcher observe cancellation at chunk/record/token checkpoints;
  token work checks at least every 4,096 tokens and every 64 KiB traversed within a single
  token/string. High-fanout container decoding has checkpoints between nodes. No claim of
  interrupting an OS read.
- Keep only query state, current bounded record/field state, and a bounded snippet of at
  most 512 UTF-16 units per hit. Do not keep complete-field token arrays or a growing list
  of parsed Sessions. Reuse lightweight index metadata for row rendering.
- Publish result/progress batches at most 10 Hz, flush final counters exactly, and keep
  stale-run checks on every publication. No unbounded detached per-session task fan-out.

Counters include eligible, complete, incomplete by reason, verified matches, unresolved,
bytes read, and cancelled. A later run rescans unresolved sources; completion does not
schedule an automatic retry loop. Typing cancels a Return scan and starts Instant only.
Esc stops scanning while retaining already shown results with a cancelled/partial label.

### 5.4 Index migration

Keep main index and optional Tool I/O byte/character budgets and enablement defaults unchanged.
Change extraction and query tokenization under new format versions (currently 5 and 1, E7).
Required format migration is an explicit per-source pending obligation, bypassing ordinary
unchanged-file cooldowns. A source cannot become aggregate-clean while required work is
pending, failed, or deferred. Persist progress through row format versions; reconstruct the
pending set on restart. Atomically replace each text/FTS row after successful extraction.
Do not drop/rebuild the entire database or mark a failed row current.

Migration and ordinary ingestion consume the bounded semantic segment adapters from section
5.2, not the current unconditional full-Session parse. Keep bounded sampling buffers within
the existing index budgets. Where evenly spaced middle sampling requires an event count,
use an authoritative count for the captured revision or a bounded-memory first counting pass
followed by extraction over that same validated revision. Both passes observe cancellation
and reader coverage; neither accumulates event arrays. Do not activate format versions until
these adapters and the migration cancellation/resource tests are ready. Reader failures and
resource omissions are deferred/failed migration obligations, distinct from intentional index
sampling; they cannot silently mark a row format-current.

Old-format rows may serve only provisional Instant results until replaced. Make format
readiness and ingestion scheduling agree; the version bump must invalidate in-memory clean
aggregate state as well as row readiness. Optional Tool I/O migration runs only when that
index is enabled; enabling it later rebuilds old versions. Exhaustive search remains usable
while migration is active. Fix help to match actual retention constants (E7).

## 6. Transcript presentation ownership

Preserve parsing off main, tail-first hydration, 400-block rendering windows, and existing
append-extension behavior (E9/E11). This is a derivation refactor, not a new transcript parser.

Introduce an explicit content revision assigned by the hydration/publication owner whenever
content is replaced, appended, or changes from provisional to full. Include source identity,
storage revision, and hydration completeness. Same-count/same-size updates must change it.
Do not obtain correctness by hashing every transcript inside SwiftUI body evaluation.

`PresentationKey` combines content revision, all semantic `DerivedSettings` (including
skipAgentsPreamble, reviewCardsEnabled and includeMessageContext/projection mode), Context
setting, active role-filter mask, telemetry revision, image boundary revision, and locale/
time-format inputs used by marker strings. Inputs are immutable
snapshots captured on their owner. Stale telemetry/images from another session cannot join
a new key. Derive blocks, markers, message groups, and role navigation counts off main and
publish them as one consistent `TranscriptPresentation`. Keep row counts/filter effects
consistent with current Tools/Errors/User/Agent navigation semantics.

Use dependency-specific subkeys inside the owner: a role-mask change recomputes navigation
projection/counts from cached stop indexes, not markers or message groups whose inputs are
unchanged. If a filter combination needs whole-stream work to obtain exact displayed stops,
do that projection off main. Preamble or projection-mode changes invalidate the snapshot
inputs they actually affect. Test every role-mask combination against emitted row/navigation
semantics; a cached raw role count is not a substitute for the displayed stop count.

Markers return an empty map immediately when changes are empty. Reuse one marker map for
toolbar/table. Cache grouping once per relevant revision; unchanged marker calls do not
currently imply a full grouping rebuild, and the refactor must preserve that optimization.
Move append extension with its previous immutable index into the worker and check publication
generation afterward. No separate caller may rebuild groups synchronously in production.

Retain the previous consistent presentation while a new one computes; show pending selection
state and do not attribute old rows/role counts to the new session. Only apply a bundle whose
identity and revision match the requested selection. A missing async grouping result is not
permission to use `BlockTableController`'s synchronous fallback (E10). Keep that fallback
only for explicit component tests, or require a complete bundle at the production API.

If telemetry/images arrive later, derive a new consistent presentation; content first paint
need not wait for unrelated background scans. Track first content, full hydration, Find-ready,
and image-ready separately in the profiling specification. Cancel/supersede work without
publishing partial combinations. Whole-session snapshot coalescing remains a profiling
candidate; no broader parser/scheduler change is justified by this specification alone.

## 7. Required acceptance matrix

| Family | Required cases and assertions |
|---|---|
| Credentials | K1-K6; failed Save/Delete; cancel one of two read waiters; disable/re-enable; A success/error after B; pending physical read does not spawn retries. |
| Extraction | Claude output above 8 KiB preserved; mixed stdout/stderr; errors in text; literal omission-like text retained; Cursor/Droid equivalent structures; source exclusions retained. |
| Query | Cross-field AND, same-field phrase, split-chunk phrase, unsampled NOT contradiction, OR, explicit prefix, Unicode/diacritics, punctuation atoms, quoted metadata-looking text, invalid/dangling syntax, pure-negative query, metadata operators. |
| Identity | Indexed/unindexed/stale/capacity-limited search; Codex internal versus app ID; Claude UUID; parent excluded; source collision; metadata filters; no parser invocation. |
| Coverage | Full/current hydration reuse; provisional/stale hydration rescanned; source changes once/twice; DB WAL update; companion replacement; oversize/malformed/read-error/cancel each visible. |
| Resources | Common-query hits grow lightweight metadata only; one Return plus one global ingest worker; concurrent provider kicks obey total budget; DB-unavailable/stale/unindexed rapid typing starts no parser; high-fanout objects/arrays, nesting, huge single tokens and compressed expansion obey allocation/cancel bounds; exact final progress; old-run publications rejected. |
| Migration | Unchanged old file with recent ingestion time; expiry/repeated kick; failure/retry; restart; optional index disabled then enabled; no premature aggregate clean. |
| Presentation | Same-size same-count edit; A-B-A; provisional-to-full; live append; Context; all role masks; preamble/review-card/projection mode; telemetry/image late arrival; locale change; no sync fallback; unchanged-key no-op. |

The implementation plan names existing test families to extend. The profiling specification
defines performance thresholds; this acceptance table defines correctness. All provider
capability gaps and failed gates remain explicit. No backlog entry is closed by writing this
specification or by a clean document review.
