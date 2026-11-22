# Search and responsiveness profiling specification

Date: 2026-11-10. Status: ready after Sol Max review; no profiling run performed.

Depends on the [refactor specification](2026-11-10-search-responsiveness-refactor.md)
and [implementation plan](../plans/2026-11-10-search-responsiveness-refactor.md).
All thresholds below are proposed acceptance requirements, not observed measurements.
Executing this protocol requires a later profiling request. Implementation and synthetic tests are now authorized; live measurement remains deferred.

## 1. Questions and limits

Q1: Does credential delay block main, cross an epoch, or cause concurrent retry fan-out?
Q2: Does Return produce correct results for the supported grammar with honest coverage,
bounded memory, and responsive cancellation while migration/discovery are active?
Q3: Which interval delays opening session `01a0e10e-4ff2-7f80-9a41-65eb91364db4`:
queueing, source hydration, snapshot derivation, main-thread application, or later readiness?
Q4: Does shared presentation derivation remove repeated work without stale content, slower
first content, navigation regressions, or increased retained memory?

The [historical review](../../reviews/2026-11-10-syntax-highlighting-live-review.md)
did not capture the reported large-session loading interval. Its idle sample is not a
baseline. Do not attribute the delay to highlighting, role counts, or Keychain without a
correlated trace. The existing component test explicitly excludes parsing (spec E12).

## 2. Build, input and process identity

Before each comparison record: HEAD, dirty patch hash, untracked source hashes, binary hash,
bundle path/version, architecture, Xcode/OS versions, optimization/build settings, machine,
display/window geometry, appearance, query/filter/settings snapshot, process PID and start
time, source fingerprints, provider registry and scanner capability versions.

Use native arm64 optimized Release for acceptance. Produce a standalone build in
`.deriveddata-manual` with approved Xcode cache access. The exact future command is:

```sh
xcodebuild -project AgentSessions.xcodeproj -scheme AgentSessions -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath .deriveddata-manual ONLY_ACTIVE_ARCH=YES build
```

Use the resulting `Release/AgentSessions.app`, never a test-re-signed bundle. Record command
and stdout. Freeze baseline and candidate into distinct immutable exported source/binary
artifacts so one build cannot overwrite the other. An export is not permission to change HEAD,
create a worktree, or modify unrelated files. Use identical compiler conditions in both.
Component benchmarks requiring `ENABLE_TESTABILITY`/DEBUG conditions get their own manifest;
their timings cannot substitute for the production Release app.

Use synthetic, deterministic fixtures first. For the reported session, resolve and verify
provider ID, title and file/storage identity before using it in a later authorized live run.
Record physical bytes, event/message/block counts, hydration state and fingerprint; “8,000
messages” alone is not an input identity. Preserve source files and original app DB. Synthetic
migration/search tests use temporary databases, not the user's live search index.

Use per-window appearance where possible. If system appearance is changed, restore System
at run end. UI automation is only allowed if separately requested; manual interactions plus
in-process traces suffice. Run only the intended app instance; never kill an ambiguous PID.

## 3. Event schema and measured boundaries

Use a monotonic clock and paired spans. Every event carries run ID, operation ID, parent ID,
source-qualified session identity, content/storage revision, hydration completeness,
presentation generation, credential epoch where relevant, and timestamp. Record only opaque
identities, counts, durations and typed statuses; no credentials, source text, queries or
private paths in exported telemetry. A local restricted manifest may map opaque input IDs.

Required transcript events:

1. selection accepted; queued parse requested; worker started;
2. tail read begin/end; provisional hydration published;
3. full read/decode begin/end; full hydration published;
4. snapshot begin/end with child spans for coalescing, digests, invocation/turn/anchor indexes;
5. marker/group/count derivation begin/end with cache hit/miss and append/full mode;
6. presentation published; table apply begin/end; layout/display completion;
7. first **matching-identity/revision** visible content; full-content presentation visible;
8. Find-ready and image-ready, each independently timed or explicitly not requested.

First-content latency is selection -> first readable content belonging to the selected session,
including a correctly labelled provisional tail. Full-ready latency ends only after full-source
hydration and its corresponding presentation is displayed. A retained previous-session row
never counts. If source coverage is incomplete, record partial-ready instead of full-ready.
Table apply timing alone is not display latency. A source-changing run retains its evidence
but is analysed separately from stable-input latency runs.

Required credential spans: service wait, physical read/write/delete, coalesced-waiter count,
mutation accepted/completed, cache lookup/write, network begin/end, publication accepted/rejected.
Do not log token values or raw Security query dictionaries. Network timing is separate from
Security latency and tested using fake network responses for causal isolation.

Required search spans/counters: request accepted, eligible count, Instant first publication,
scan queued/started, source revision checks/retries, physical/decoded bytes, records visited,
omission reasons, extractor/matcher time, provisional/verified results, peak retained payload,
cancel requested/worker acknowledged, terminal status and final exact coverage counters.
Record migration pending/current/failed counts and time to converge after each kick/restart.

Track main-thread stalls using a monotonic heartbeat plus Time Profiler/hang samples during
the actual interval. Capture peak/settled physical footprint and allocation categories.
Instrumented/uninstrumented component runs estimate recorder overhead; if median overhead
exceeds 2%, use lower-overhead counters/spans or report separate absolute timings. Do not
subtract a guessed overhead from results.

## 4. Scenario matrix

| ID | Fixture / state | Required actions and evidence |
|---|---|---|
| C1 | Fake Security read delayed 2 seconds | Launch/refresh, service main work while waiting; concurrent catalog/usage/Preferences reads; one physical read. |
| C2 | Delayed credential/network A, persisted A snapshot | Save B, Remove, disable/re-enable, restart, missing-five-hour B payload, delayed store save, cancel one waiter, failed mutation; zero obsolete network starts/publications/cache writes/restores/window merges. |
| C3 | Real Keychain, later live authorization only | Launch and Preferences open; observe actual wait without changing credentials solely to manufacture a stall. |
| S1 | Output-only oracle fixture | Head/middle/tail, >8 KiB Claude, runtime errors, Unicode, literal markers, structured/mixed outputs; compare exact expected session IDs. |
| S2 | Query semantics oracle | Cross-event AND, field-local phrase, chunk split, punctuation atoms, quoted metadata text, OR, prefix, negative-only, unsampled NOT, invalid/dangling syntax, source/meta filters and ID collisions. |
| S3 | Coverage states | Indexed/current, stale, unindexed, provisional hydration, same-size replacement, WAL update, companion replacement, malformed/oversize/read error and source changes twice. |
| S4 | Scale/cancel | 100/1,000/10,000 sessions, fixed total query witnesses and then all-hit common query; high-fanout objects/arrays, deep nesting, huge single tokens, compressed expansion; cancel during reading/decoding/matching; supersede rapidly; concurrent provider kicks; DB-unavailable/stale/unindexed rapid typing starts no parser. |
| S5 | Migration | Old-format file modified yesterday but indexed one minute ago; repeated kick, restart, failing/oversize row, cancellation during extraction, optional index disabled/enabled; measure convergence and retained payload. |
| T1 | Exact reported large session | Cold process and warm reselection; distinguish queue, provisional/full paint and later readiness. |
| T2 | Size/shape controls | 1k/8k/32k events with equal-size messages; separate 8k fixtures with huge outputs, many tiny outputs, long tool inputs, no telemetry, many markers, images. |
| T3 | Interaction | Scroll, load older window, Find, expand/collapse, Context, all role masks, preamble/review-card/projection toggles, tools/errors navigation, same-size edit, live append, rapid A-B-A. |
| T4 | Background load | Settled index versus active migration/discovery; same input and settings; record worker activity and queue waits. |
| T5 | Presentation variants | Telemetry/image arrival, both appearances, narrow/wide window; verify old rows cannot satisfy first paint or role-count assertions. |

All provider fixtures must be synthetic/current-format and cover every registered source.
Unsupported historical variants remain separate coverage cases. For file/DB fixtures, an
independent expected-result manifest defines truth; do not generate expected hits with the
same matcher/extractor under test. Every known omission must produce the expected reason.

## 5. Repetition and analysis

Run 20 baseline and 20 candidate measurements for each primary T1 cold-process/warm condition
and T4 settled/active condition. Interleave five ABBA blocks per condition, repeated twice,
so each variant has 20 samples; randomize which variant is A per condition and record order.
Cold process means a newly started app with stated app cache state; it does not mean cold
filesystem cache. Do not flush system caches or modify user data to simulate cold storage.

Run 20 repetitions per variant for S4 primary sizes and cancellation positions; deterministic
correctness cases need one complete pass plus targeted interleavings, not repeated timing for
every assertion. Run T2/T3 diagnostic strata at least five times initially and expand any
regressing stratum to 20 before accepting it. C1/C2 use deterministic barriers rather than
sleep-based race tests. C3 is observational and has no guaranteed delay to reproduce.

Report raw samples, median, nearest-rank p95, maximum, and paired/interleaved ratios. Twenty
samples make p95 coarse: show it as descriptive, not a precise population estimate. Keep all
slow samples. Prespecify invalid runs as wrong binary/input, missing required span, or changed
fixture; retain them with reason and rerun. Background machine load is recorded, not a reason
to discard an inconvenient result. If baseline/candidate variability prevents a decision,
mark inconclusive and repeat the same predeclared comparison; do not move thresholds.

## 6. Acceptance gates

| Gate | Requirement |
|---|---|
| G1 Credential correctness | All K1-K6 pass; zero Security calls on main; maximum one physical Security operation; zero stale publication/cache write. |
| G2 Search truth | All independent oracle IDs/predicates correct; no incomplete source counted complete; all current provider fixtures complete. |
| G3 Search resources | One active exhaustive worker plus at most one background ingestion/migration worker across providers; retained payload <=64 MiB per scan and <=128 MiB total; no full parsed Sessions in hit results; snippet cap 512 UTF-16 units. Physical footprint may exceed payload budget and is reported separately. |
| G4 Cancellation | On local nonblocking fixtures, p95 <=100 ms and maximum <=250 ms from cancel to worker acknowledgment; no obsolete publication. OS-blocked I/O is reported separately and never described as cancelled work that freed its worker. |
| G5 Migration | Repeated kicks/restart converge all valid fixture rows to current versions; pending/failed rows prevent aggregate-clean; bounded adapters satisfy G3/G4 resource/cancellation limits; no fixed wall-time gate substitutes for completion. |
| G6 Derivation | Unchanged-key UI updates cause zero marker/group/count recomputations; empty markers scan zero blocks; production apply never builds missing groups synchronously. |
| G7 Relative latency | For T1/T4 first-content and full-ready, candidate median <=1.05x baseline and p95 <=1.10x; any failing stratum fails the gate. Same inputs/conditions required. |
| G8 Interaction | On stable local fixtures, main-thread attributable work per interaction p95 <=50 ms, maximum <=100 ms; new-session content identity and navigation are correct. OS scheduling gaps are recorded separately. |
| G9 Memory | T1/T4 peak and settled footprint <=1.10x baseline; S4 result retention grows with lightweight metadata, not matched transcript bytes. Keep allocation evidence rather than infer boundedness from one RSS reading. |

G7 is a non-regression gate, not proof that the slow-open complaint is fixed. Closing that
backlog item additionally requires a captured baseline loading interval and identified dominant
work. After baseline diagnosis and before P8 candidate implementation or timing, pin the affected user-visible metric (selection to
first-content or selection to full-ready) and the baseline evidence for that choice in the
manifest. Require at least 20% lower median on that metric in the affected condition, both
metrics satisfying G7, and an observed responsive interaction sequence in the same session.
Do not select the improvement metric after seeing candidate results. If the baseline does
not reproduce the complaint, report not reproduced and leave
the item open. A clean cache/correctness refactor may ship separately with that limitation.

The absolute timing/budget thresholds are design targets. If feasibility fails, document the
failure and revise the design through review before implementation is called complete. Do not
silently reduce corpus coverage, suppress work, or omit slow samples to pass.

## 7. Evidence bundle and closure report

Write future run artifacts under a timestamped task-specific directory in
`scripts/probe_scan_output/`. Include manifest, source/binary/input hashes, exact commands,
raw JSONL spans, counters, sample/allocation artifacts, XCResult path and summary, per-case
correctness oracle results, table of G1-G9, invalid-run ledger, and comparison script/version.
Keep credentials/private text out of artifacts. Do not delete source sessions, app caches,
Keychain items, or existing evidence as setup/cleanup.

A report must distinguish: code correctness passed; component benchmark passed; production
latency passed; real Keychain observation available/unavailable; large-open issue closed/open.
Record tests skipped and test-name inventory delta. Restore any altered appearance to System.
No green component benchmark, idle profile, or historical report closes a production gate.


## 9. Implemented recorder and deferred run handoff

The in-process recorder is `AgentSessions/Services/SearchResponsivenessMetrics.swift`.
It is disabled unless the process receives exactly `--benchmark-search-responsiveness`
or `AGENTSESSIONS_BENCHMARK_SEARCH_RESPONSIVENESS=1`. It keeps at most 100,000 events,
reserves paired terminal events, hashes identity/revision values with a per-run salt,
and records overflow explicitly. An overflowed run is not an acceptance result.
`SearchResponsivenessMetrics.shared.export(to:)` is an explicit caller-requested JSONL
export; it rejects disabled runs and open spans. Nothing exports on a normal app launch.
The future diagnostic harness/debugger must request that API after its workload terminates;
no harness launch or export against the owner's corpus was performed in this task.

Production hooks cover selection, Codex/Claude hydration, shared snapshot/presentation,
AppKit apply/display, requested Find/images, discovery, credential I/O/network/publication,
search request/scan ownership, source coverage and migration counts. See the implementation
ledger for source anchors and deterministic validation. Other providers' hydration stages
must be explicitly marked unavailable by a future cross-provider opening benchmark; their
source-search scan stages are instrumented. Diagnostic charged payload is an algorithmic
bound/counter, not a measured RSS value. Measure RSS/allocations separately as required above.

The user authorized P8 implementation while withholding live profiling. Therefore the
baseline-selected production metric could not be pinned before implementation. The
immutable P0 source export remains the baseline; pin the metric from that baseline before
candidate timing and record this ordering exception. No claimed improvement is inferred
from the implementation, synthetic fixtures, or historical idle samples.
